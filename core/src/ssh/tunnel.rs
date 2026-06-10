//! Owned, stoppable SSH local-forward tunnel.
//!
//! After `ssh_bootstrap` runs the remote bootstrap, the russh session is kept
//! alive and a localhost `TcpListener` forwards every accepted connection into
//! a `direct-tcpip` channel to the broker port on the box. [`SshTunnel`] wraps
//! that listener + the russh `Handle` in an `Arc`-backed object the app holds:
//!
//! - `local_port()` — the loopback port the WebSocket transport dials.
//! - `is_alive()` — false once the SSH session died or `stop()` ran.
//! - `stop()` — best-effort SSH disconnect + abort the accept loop + release
//!   the listener. Idempotent; also runs on drop.
//!
//! The accept loop and a lightweight liveness watcher are the only spawned
//! tasks; both exit on the cancellation `Notify` so nothing leaks.

use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Arc;
use std::time::Duration;

use russh::client::Handle;
use tokio::net::TcpListener;
use tokio::sync::Notify;
use tokio::task::JoinHandle;

use super::connect::RusshClientHandler;
use super::port_forward;

/// How often the liveness watcher polls `Handle::is_closed()`. Cheap
/// non-blocking check; this only bounds how fast a silently-dead session
/// trips the listener teardown (the app's WS reconnect usually notices the
/// dead loopback dial first).
const LIVENESS_POLL: Duration = Duration::from_secs(5);

/// Shared russh session handle type used across the SSH module.
pub(super) type SshHandle = Arc<tokio::sync::Mutex<Handle<RusshClientHandler>>>;

/// An owned localhost→broker SSH forward. UniFFI exposes this as an opaque
/// object; the app keeps a strong reference for the lifetime of the pairing
/// and calls `stop()` on logout / teardown.
pub struct SshTunnel {
    handle: SshHandle,
    local_port: u16,
    /// Set once `stop()` (or drop) has run, so `is_alive()` reports dead even
    /// before the russh I/O loop has fully torn down.
    stopped: AtomicBool,
    /// Fires to wake + exit the accept loop and the liveness watcher.
    cancel: Arc<Notify>,
    accept_task: std::sync::Mutex<Option<JoinHandle<()>>>,
    watcher_task: std::sync::Mutex<Option<JoinHandle<()>>>,
}

impl SshTunnel {
    /// Spawn the accept loop + liveness watcher over an already-bound
    /// listener, returning the owned handle. `remote_port` is the broker port
    /// inside the SSH session.
    pub(super) fn spawn(
        handle: SshHandle,
        listener: TcpListener,
        local_port: u16,
        remote_port: u16,
    ) -> Arc<Self> {
        let cancel = Arc::new(Notify::new());

        let accept_handle = Arc::clone(&handle);
        let accept_cancel = Arc::clone(&cancel);
        let accept_task = tokio::spawn(async move {
            run_accept_loop(
                accept_handle,
                listener,
                accept_cancel,
                local_port,
                remote_port,
            )
            .await;
        });

        let watch_handle = Arc::clone(&handle);
        let watch_cancel = Arc::clone(&cancel);
        let watcher_task = tokio::spawn(async move {
            run_liveness_watcher(watch_handle, watch_cancel).await;
        });

        Arc::new(SshTunnel {
            handle,
            local_port,
            stopped: AtomicBool::new(false),
            cancel,
            accept_task: std::sync::Mutex::new(Some(accept_task)),
            watcher_task: std::sync::Mutex::new(Some(watcher_task)),
        })
    }

    /// The loopback port the WebSocket transport dials
    /// (`ws://127.0.0.1:<local_port>`).
    pub fn local_port(&self) -> u16 {
        self.local_port
    }

    /// True while the SSH session is up and `stop()` hasn't run. The app
    /// polls / observes this; a `false` here means "the tunnel is gone — the
    /// transport's loopback dials will fail, re-pair".
    pub fn is_alive(&self) -> bool {
        if self.stopped.load(Ordering::Acquire) {
            return false;
        }
        // try_lock: we never want is_alive() to block on a busy session lock;
        // if it's momentarily held by an open-channel call the session is by
        // definition still alive, so assume alive on contention.
        match self.handle.try_lock() {
            Ok(h) => !h.is_closed(),
            Err(_) => true,
        }
    }

    /// Best-effort clean teardown. Idempotent: safe to call multiple times and
    /// from `Drop`. Wakes the accept loop + watcher (which then exit and
    /// release the listener), aborts them as a backstop, and fires an SSH
    /// `disconnect` on a detached task (the call is async; we don't block the
    /// FFI thread on it).
    pub fn stop(&self) {
        if self.stopped.swap(true, Ordering::AcqRel) {
            return; // already stopped
        }
        self.cancel.notify_waiters();

        if let Some(t) = self.accept_task.lock().unwrap().take() {
            t.abort();
        }
        if let Some(t) = self.watcher_task.lock().unwrap().take() {
            t.abort();
        }

        // SSH-level disconnect is async; detach it so stop() stays sync for
        // the FFI getter shape. If the runtime is gone this just no-ops.
        let handle = Arc::clone(&self.handle);
        if let Ok(rt) = tokio::runtime::Handle::try_current() {
            rt.spawn(async move {
                let h = handle.lock().await;
                let _ = h
                    .disconnect(russh::Disconnect::ByApplication, "client stop", "")
                    .await;
            });
        }
    }
}

impl Drop for SshTunnel {
    fn drop(&mut self) {
        // A dropped handle must never leak the accept loop / watcher.
        self.stopped.store(true, Ordering::Release);
        self.cancel.notify_waiters();
        if let Some(t) = self.accept_task.lock().unwrap().take() {
            t.abort();
        }
        if let Some(t) = self.watcher_task.lock().unwrap().take() {
            t.abort();
        }
    }
}

/// Accept loop: each accepted localhost connection gets its own
/// `direct-tcpip` channel to the broker port, proxied by `proxy_connection`.
/// Exits on cancel (stop/drop) or when `accept()` errors (listener dropped).
async fn run_accept_loop(
    handle: SshHandle,
    listener: TcpListener,
    cancel: Arc<Notify>,
    local_port: u16,
    remote_port: u16,
) {
    loop {
        let (sock, peer) = tokio::select! {
            _ = cancel.notified() => break,
            res = listener.accept() => match res {
                Ok(v) => v,
                Err(_) => break,
            },
        };

        // Hold the session lock only for the open-channel call — the returned
        // Channel<Msg> is independent and proxy_connection drives it without
        // re-locking, so concurrent forwarded connections don't serialize.
        let guard = handle.lock().await;
        let channel = match guard
            .channel_open_direct_tcpip("127.0.0.1", remote_port as u32, "127.0.0.1", 0)
            .await
        {
            Ok(c) => c,
            Err(_) => {
                // Session is probably dead; drop this connection. The liveness
                // watcher will trip teardown shortly.
                drop(guard);
                drop(sock);
                continue;
            }
        };
        drop(guard);
        tokio::spawn(port_forward::proxy_connection(
            sock,
            channel,
            peer,
            local_port,
            remote_port,
        ));
    }
}

/// Poll the russh handle; on first `is_closed()` fire the cancel so the accept
/// loop exits and the listener is released. Also exits if cancelled first
/// (stop/drop). No busy loop — sleeps `LIVENESS_POLL` between checks.
async fn run_liveness_watcher(handle: SshHandle, cancel: Arc<Notify>) {
    loop {
        let closed = {
            match handle.try_lock() {
                Ok(h) => h.is_closed(),
                Err(_) => false, // busy ⇒ alive
            }
        };
        if closed {
            cancel.notify_waiters();
            break;
        }
        tokio::select! {
            _ = cancel.notified() => break,
            _ = tokio::time::sleep(LIVENESS_POLL) => {}
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::atomic::AtomicU32;
    use tokio::io::AsyncWriteExt;
    use tokio::net::TcpStream;

    // The accept loop is generic enough that we test its lifecycle without
    // russh by exercising the cancel/teardown contract directly: bind a
    // listener, spawn a loop that just counts accepts and exits on cancel,
    // then assert it stops and releases the port. This mirrors
    // run_accept_loop's control flow (select! accept vs cancel) without
    // needing a live SSH Handle, which can't be constructed in a unit test.

    async fn counting_accept_loop(
        listener: TcpListener,
        cancel: Arc<Notify>,
        count: Arc<AtomicU32>,
    ) {
        loop {
            tokio::select! {
                _ = cancel.notified() => break,
                res = listener.accept() => match res {
                    Ok((sock, _)) => {
                        count.fetch_add(1, Ordering::SeqCst);
                        drop(sock);
                    }
                    Err(_) => break,
                },
            }
        }
    }

    #[tokio::test]
    async fn accept_loop_exits_on_cancel_and_releases_port() {
        let (listener, port) = port_forward::bind_random_local().await.unwrap();
        let cancel = Arc::new(Notify::new());
        let count = Arc::new(AtomicU32::new(0));

        let loop_cancel = Arc::clone(&cancel);
        let loop_count = Arc::clone(&count);
        let task = tokio::spawn(counting_accept_loop(listener, loop_cancel, loop_count));

        // One connection gets accepted.
        let mut c = TcpStream::connect(("127.0.0.1", port)).await.unwrap();
        c.write_all(b"x").await.unwrap();
        // Give the loop a tick to count it.
        tokio::task::yield_now().await;
        tokio::time::sleep(Duration::from_millis(20)).await;
        assert_eq!(count.load(Ordering::SeqCst), 1);

        // Cancel → loop exits → port released.
        cancel.notify_waiters();
        // The task should finish promptly.
        tokio::time::timeout(Duration::from_secs(2), task)
            .await
            .expect("accept loop did not exit after cancel")
            .unwrap();

        // Port is free again: a fresh bind on it should now succeed.
        let rebind = TcpListener::bind(("127.0.0.1", port)).await;
        assert!(rebind.is_ok(), "port not released after cancel: {rebind:?}");
    }

    #[tokio::test]
    async fn cancel_notify_is_idempotent() {
        // notify_waiters with no waiters is a no-op and multiple fires are
        // safe — this guards the stop()/drop double-fire path.
        let cancel = Arc::new(Notify::new());
        cancel.notify_waiters();
        cancel.notify_waiters();
        // A waiter registered after the fires must still be wakeable by a
        // subsequent fire (notify_waiters does not latch).
        let c2 = Arc::clone(&cancel);
        let waiter = tokio::spawn(async move { c2.notified().await });
        tokio::task::yield_now().await;
        cancel.notify_waiters();
        tokio::time::timeout(Duration::from_secs(2), waiter)
            .await
            .expect("waiter not woken")
            .unwrap();
    }
}
