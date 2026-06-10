//! Bidirectional TCP↔SSH-channel proxy.
//!
//! The mobile-side WebSocket transport connects to a local TCP listener on
//! `127.0.0.1:<local_port>`; every accept is paired with a russh
//! `direct-tcpip` channel to `127.0.0.1:<remote_port>` on the SSH peer.
//!
//! The byte-pump (`pump_bidirectional`) is factored to be generic over any
//! `AsyncRead + AsyncWrite` halves so it's unit-testable with two plain TCP
//! sockets — no russh / no real SSH server. `proxy_connection` is the thin
//! russh-specific adapter that wires a `Channel<Msg>` into the pump.

use std::net::SocketAddr;

use russh::client::Msg;
use russh::Channel;
use tokio::io::{AsyncRead, AsyncReadExt, AsyncWrite, AsyncWriteExt};
use tokio::net::{TcpListener, TcpStream};

use super::SshError;

/// Copy bytes both directions between two duplex byte streams until either
/// side's read half hits EOF (or errors). Composes two [`copy_one_way`] tasks
/// (the same per-direction worker `proxy_connection` uses), so exercising this
/// with two plain TCP sockets validates the real byte-pump without russh.
///
/// Test-only: the production `proxy_connection` can't hand us an `AsyncRead`
/// for the russh side (reads arrive as `ChannelMsg` off `wait()`), so it calls
/// `copy_one_way` directly for the local→remote half and drives the
/// remote→local half off `wait()`. This composition exists purely to unit-test
/// the shared `copy_one_way` plumbing.
#[cfg(test)]
pub(crate) async fn pump_bidirectional<AR, AW, BR, BW>(
    a_read: AR,
    a_write: AW,
    b_read: BR,
    b_write: BW,
) where
    AR: AsyncRead + Unpin + Send + 'static,
    AW: AsyncWrite + Unpin + Send + 'static,
    BR: AsyncRead + Unpin + Send + 'static,
    BW: AsyncWrite + Unpin + Send + 'static,
{
    let a2b = tokio::spawn(copy_one_way(a_read, b_write));
    let b2a = tokio::spawn(copy_one_way(b_read, a_write));
    let _ = a2b.await;
    let _ = b2a.await;
}

/// Pump one direction: read until EOF, write through, then shut the writer so
/// the peer observes the half-close.
async fn copy_one_way<R, W>(mut read: R, mut write: W)
where
    R: AsyncRead + Unpin,
    W: AsyncWrite + Unpin,
{
    let mut buf = vec![0u8; 32 * 1024];
    loop {
        match read.read(&mut buf).await {
            Ok(0) => break,
            Ok(n) => {
                if write.write_all(&buf[..n]).await.is_err() {
                    break;
                }
            }
            Err(_) => break,
        }
    }
    let _ = write.shutdown().await;
}

/// Drive the bidi copy for a single accepted connection over a russh
/// `direct-tcpip` channel. Returns once either direction closes.
pub(crate) async fn proxy_connection(
    local: TcpStream,
    mut ssh_channel: Channel<Msg>,
    peer: SocketAddr,
    local_port: u16,
    remote_port: u16,
) {
    let ssh_writer = ssh_channel.make_writer();
    let (local_read, local_write) = local.into_split();

    // The russh channel has no AsyncRead half — reads arrive as ChannelMsg
    // off `wait()`. Bridge it into an AsyncWrite sink on the local side
    // directly (rather than synthesizing an AsyncRead) so we can still reuse
    // copy_one_way for the local→remote direction.
    let l2r = tokio::spawn(copy_one_way(local_read, ssh_writer));

    let mut local_write = local_write;
    while let Some(msg) = ssh_channel.wait().await {
        match msg {
            russh::ChannelMsg::Data { ref data } if local_write.write_all(data).await.is_err() => {
                break
            }
            russh::ChannelMsg::Eof | russh::ChannelMsg::Close => break,
            _ => {}
        }
    }
    let _ = local_write.shutdown().await;
    let _ = l2r.await;
    let _ = (peer, local_port, remote_port); // touched for future trace logs
}

/// Pick a free localhost TCP port by binding to :0 and reading back the
/// kernel-allocated port. Returns the bound listener so the caller can keep it
/// (the port stays held until the listener is dropped).
pub(crate) async fn bind_random_local() -> Result<(TcpListener, u16), SshError> {
    let l = TcpListener::bind(("127.0.0.1", 0))
        .await
        .map_err(|e| SshError::PortForward(format!("bind 127.0.0.1:0: {e}")))?;
    let port = l
        .local_addr()
        .map_err(|e| SshError::PortForward(format!("local_addr: {e}")))?
        .port();
    Ok((l, port))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[tokio::test]
    async fn bind_random_local_returns_listening_port() {
        let (listener, port) = bind_random_local().await.unwrap();
        assert!(port > 0);
        let probe = TcpStream::connect(("127.0.0.1", port)).await;
        assert!(probe.is_ok(), "expected to dial the bound port: {probe:?}");
        drop(listener);
    }

    /// Stand up a localhost echo server, then put `pump_bidirectional`
    /// between a client socket and a socket connected to the echo server.
    /// Bytes the client writes should come back through the pump. No russh.
    #[tokio::test]
    async fn pump_relays_bytes_through_echo_server() {
        // Echo server: read → write back, byte for byte.
        let echo = TcpListener::bind(("127.0.0.1", 0)).await.unwrap();
        let echo_addr = echo.local_addr().unwrap();
        tokio::spawn(async move {
            if let Ok((mut sock, _)) = echo.accept().await {
                let mut buf = vec![0u8; 4096];
                loop {
                    match sock.read(&mut buf).await {
                        Ok(0) => break,
                        Ok(n) => {
                            if sock.write_all(&buf[..n]).await.is_err() {
                                break;
                            }
                        }
                        Err(_) => break,
                    }
                }
            }
        });

        // The "local" side the test acts as a client of.
        let front = TcpListener::bind(("127.0.0.1", 0)).await.unwrap();
        let front_addr = front.local_addr().unwrap();

        // The pump: front-accepted socket <-> connection to the echo server.
        tokio::spawn(async move {
            let (front_sock, _) = front.accept().await.unwrap();
            let back_sock = TcpStream::connect(echo_addr).await.unwrap();
            let (fr, fw) = front_sock.into_split();
            let (br, bw) = back_sock.into_split();
            pump_bidirectional(fr, fw, br, bw).await;
        });

        // Client drives the front; expects an echo back through the pump.
        let mut client = TcpStream::connect(front_addr).await.unwrap();
        let payload = b"hello-through-the-pump";
        client.write_all(payload).await.unwrap();
        let mut got = vec![0u8; payload.len()];
        client.read_exact(&mut got).await.unwrap();
        assert_eq!(&got, payload);
    }

    /// Half-close: once the client shuts its write half, the pump should
    /// propagate EOF so the echo server's read returns 0 and it shuts down,
    /// which closes the client's read half cleanly.
    #[tokio::test]
    async fn pump_propagates_half_close() {
        let echo = TcpListener::bind(("127.0.0.1", 0)).await.unwrap();
        let echo_addr = echo.local_addr().unwrap();
        tokio::spawn(async move {
            if let Ok((mut sock, _)) = echo.accept().await {
                let mut buf = vec![0u8; 4096];
                while let Ok(n) = sock.read(&mut buf).await {
                    if n == 0 {
                        break;
                    }
                    let _ = sock.write_all(&buf[..n]).await;
                }
            }
        });

        let front = TcpListener::bind(("127.0.0.1", 0)).await.unwrap();
        let front_addr = front.local_addr().unwrap();
        tokio::spawn(async move {
            let (front_sock, _) = front.accept().await.unwrap();
            let back_sock = TcpStream::connect(echo_addr).await.unwrap();
            let (fr, fw) = front_sock.into_split();
            let (br, bw) = back_sock.into_split();
            pump_bidirectional(fr, fw, br, bw).await;
        });

        let mut client = TcpStream::connect(front_addr).await.unwrap();
        client.write_all(b"bye").await.unwrap();
        let mut echoed = vec![0u8; 3];
        client.read_exact(&mut echoed).await.unwrap();
        assert_eq!(&echoed, b"bye");
        // Shut our write half; the read side should drain to EOF promptly.
        client.shutdown().await.unwrap();
        let mut rest = Vec::new();
        let n = client.read_to_end(&mut rest).await.unwrap();
        assert_eq!(n, 0, "expected clean EOF after half-close");
    }

    /// Large payload across the 32 KiB buffer boundary round-trips intact.
    #[tokio::test]
    async fn pump_relays_large_payload() {
        let echo = TcpListener::bind(("127.0.0.1", 0)).await.unwrap();
        let echo_addr = echo.local_addr().unwrap();
        tokio::spawn(async move {
            if let Ok((mut sock, _)) = echo.accept().await {
                let mut buf = vec![0u8; 64 * 1024];
                while let Ok(n) = sock.read(&mut buf).await {
                    if n == 0 {
                        break;
                    }
                    if sock.write_all(&buf[..n]).await.is_err() {
                        break;
                    }
                }
            }
        });

        let front = TcpListener::bind(("127.0.0.1", 0)).await.unwrap();
        let front_addr = front.local_addr().unwrap();
        tokio::spawn(async move {
            let (front_sock, _) = front.accept().await.unwrap();
            let back_sock = TcpStream::connect(echo_addr).await.unwrap();
            let (fr, fw) = front_sock.into_split();
            let (br, bw) = back_sock.into_split();
            pump_bidirectional(fr, fw, br, bw).await;
        });

        let mut client = TcpStream::connect(front_addr).await.unwrap();
        let payload: Vec<u8> = (0..200_000u32).map(|i| (i % 251) as u8).collect();
        let writer_payload = payload.clone();
        let (mut rd, mut wr) = client.split();
        let write_task = async move {
            wr.write_all(&writer_payload).await.unwrap();
            wr.shutdown().await.unwrap();
        };
        let mut got = Vec::with_capacity(payload.len());
        let read_task = rd.read_to_end(&mut got);
        let (_, read_res) = tokio::join!(write_task, read_task);
        read_res.unwrap();
        assert_eq!(got.len(), payload.len());
        assert_eq!(got, payload);
    }
}
