//! WebSocket transport for swe-kitty-core.
//!
//! Implements the binary-tag demux from `docs/WEBSOCKET-PROTOCOL.md`
//! §2.1 (0x00 resize / 0x01 upload / 0x02 snapshot / 0xFF escape / else
//! raw PTY) and the JSON control envelopes from §3, then surfaces each
//! event to the supplied delegate.
//!
//! ## Reconnection
//!
//! A drop on a transient network blip should not require user action.
//! `connect()` opens the first socket synchronously (so auth failures
//! surface to the create-session call) and then hands control to a
//! per-session worker task. The worker owns the outbound `mpsc::Receiver`
//! and the WebSocket; when the socket dies it retries
//! `RECONNECT_MAX_ATTEMPTS` times with `RECONNECT_DELAY` between attempts.
//! During reconnect the outbound channel is kept alive so messages
//! issued from the UI land on the new socket. A 401 during reconnect
//! is treated as terminal — the harness rotated its in-memory bearer
//! and the user has to re-pair.
//!
//! The pong deadline guards half-open sockets: if no pong (or any
//! other message) arrives within `PONG_DEADLINE`, the worker closes
//! the current socket so the reconnect loop can take over instead of
//! waiting for TCP to surface the error.

use std::io::Read;
use std::sync::Arc;
use std::time::Duration;

use flate2::read::GzDecoder;
use futures_util::{SinkExt, StreamExt};
use parking_lot::Mutex;
use serde::Deserialize;
use tokio::net::TcpStream;
use tokio::sync::{mpsc, oneshot, Notify};
use tokio::time::Instant;
use tokio_tungstenite::tungstenite::client::IntoClientRequest;
use tokio_tungstenite::tungstenite::http::{HeaderValue, StatusCode};
use tokio_tungstenite::tungstenite::{Error as WsError, Message};
use tokio_tungstenite::{connect_async, MaybeTlsStream, WebSocketStream};
use url::Url;

use crate::views::{ChatEvent, PreviewInfo, SessionStatus, ViewEventFile};
use crate::{SweKittyDelegate, SweKittyError};

const TAG_RESIZE: u8 = 0x00;
const TAG_UPLOAD: u8 = 0x01;
const TAG_SNAPSHOT: u8 = 0x02;
const TAG_ESCAPE: u8 = 0xFF;
const HEARTBEAT_INTERVAL: Duration = Duration::from_secs(30);
const PONG_DEADLINE: Duration = Duration::from_secs(60);
const RECONNECT_DELAY: Duration = Duration::from_secs(1);
const RECONNECT_MAX_ATTEMPTS: u32 = 5;
const WS_REDIRECT_MAX_HOPS: usize = 3;

/// Observable per-session connection state surfaced via
/// [`SweKittyDelegate::on_connection_health`]. Apps render this in their
/// status banner so a transient blip looks like "Reconnecting (2/5)…"
/// rather than "Offline".
#[derive(Clone, Debug)]
pub enum ConnectionHealth {
    Connected,
    Connecting { attempt: u32, max_attempts: u32 },
    Disconnected { reason: String, auth: bool },
}

/// A live websocket attached to one session. Cheap to clone; cloning
/// shares the underlying writer, shutdown signal, and network-change
/// nudge.
#[derive(Clone)]
pub struct SessionHandle {
    tx: mpsc::Sender<Message>,
    shutdown: Arc<Mutex<Option<oneshot::Sender<()>>>>,
    nudge: Arc<Notify>,
}

impl SessionHandle {
    /// Signal the worker to stop. Idempotent across clones.
    pub fn close(&self) {
        if let Some(sender) = self.shutdown.lock().take() {
            let _ = sender.send(());
        }
        let _ = self.tx.try_send(Message::Close(None));
    }

    /// Force the worker to drop its current socket and re-enter the
    /// reconnect loop. Used by the apps when the OS signals a network
    /// path change (Wi-Fi↔LTE handoff, foreground transition, etc.) so
    /// we don't sit on a half-open TCP waiting for the kernel to surface
    /// the failure.
    pub fn nudge(&self) {
        self.nudge.notify_one();
    }

    pub async fn send_input(&self, data: Vec<u8>) -> Result<(), SweKittyError> {
        let bytes = if data.first().is_some_and(|b| is_reserved_tag(*b)) {
            let mut v = Vec::with_capacity(data.len() + 1);
            v.push(TAG_ESCAPE);
            v.extend_from_slice(&data);
            v
        } else {
            data
        };
        self.tx
            .send(Message::Binary(bytes))
            .await
            .map_err(|e| SweKittyError::Connection(e.to_string()))
    }

    pub async fn resize(&self, rows: u16, cols: u16) -> Result<(), SweKittyError> {
        let mut buf = [TAG_RESIZE, 0, 0, 0, 0];
        buf[1..3].copy_from_slice(&rows.to_be_bytes());
        buf[3..5].copy_from_slice(&cols.to_be_bytes());
        self.tx
            .send(Message::Binary(buf.to_vec()))
            .await
            .map_err(|e| SweKittyError::Connection(e.to_string()))
    }

    /// Encode and send a 0x01 file-upload frame on this session.
    ///
    /// Wire layout (see docs/WEBSOCKET-PROTOCOL.md §2.1, sweswe-parity):
    ///
    /// ```text
    /// 0x01
    /// u32 LE session_id_length
    /// session_id_bytes
    /// u32 LE filename_length
    /// filename_bytes
    /// u32 LE mime_length
    /// mime_bytes
    /// file_bytes…
    /// ```
    ///
    /// The broker validates that `session_id` matches the WS path's
    /// bound session and sanitizes `filename` (no '..', no absolute
    /// paths, no path separators) before landing the bytes under
    /// `<workspace>/uploads/<session_id>/<filename>`.
    pub async fn send_file(
        &self,
        session_id: &str,
        filename: &str,
        mime: &str,
        bytes: &[u8],
    ) -> Result<(), SweKittyError> {
        let frame = encode_upload_frame(session_id, filename, mime, bytes);
        self.tx
            .send(Message::Binary(frame))
            .await
            .map_err(|e| SweKittyError::Connection(e.to_string()))
    }

    pub async fn send_json(&self, v: &serde_json::Value) -> Result<(), SweKittyError> {
        let s = serde_json::to_string(v)?;
        self.send_message(Message::Text(s)).await
    }

    async fn send_message(&self, message: Message) -> Result<(), SweKittyError> {
        self.tx
            .send(message)
            .await
            .map_err(|e| SweKittyError::Connection(e.to_string()))
    }
}

type WsStream = WebSocketStream<MaybeTlsStream<TcpStream>>;

/// Open a WebSocket session against the harness and spawn a worker that
/// keeps it alive across transient drops.
///
/// Callers must arrange for this future to be polled on a tokio runtime
/// with the I/O and time reactors enabled (in practice: the
/// `swe-kitty-core` runtime via the `run_on_core` helper in `lib.rs`).
pub async fn connect(
    endpoint: String,
    session_id: String,
    assistant: String,
    token: String,
    delegate: Arc<dyn SweKittyDelegate>,
) -> Result<SessionHandle, SweKittyError> {
    // First connect is synchronous from the caller's POV so auth
    // failures surface to the create-session UX. Subsequent reconnects
    // happen in the background.
    let ws = open_ws(&endpoint, &session_id, &assistant, &token).await?;

    let (tx, rx) = mpsc::channel::<Message>(64);
    let (shutdown_tx, shutdown_rx) = oneshot::channel::<()>();
    let shutdown = Arc::new(Mutex::new(Some(shutdown_tx)));
    let nudge = Arc::new(Notify::new());

    delegate.on_connection_health(session_id.clone(), ConnectionHealth::Connected);

    tokio::spawn(session_worker(WorkerArgs {
        endpoint,
        session_id,
        assistant,
        token,
        initial_ws: Some(ws),
        rx,
        shutdown_rx,
        nudge: Arc::clone(&nudge),
        delegate,
    }));

    Ok(SessionHandle {
        tx,
        shutdown,
        nudge,
    })
}

struct WorkerArgs {
    endpoint: String,
    session_id: String,
    assistant: String,
    token: String,
    initial_ws: Option<WsStream>,
    rx: mpsc::Receiver<Message>,
    shutdown_rx: oneshot::Receiver<()>,
    nudge: Arc<Notify>,
    delegate: Arc<dyn SweKittyDelegate>,
}

/// Long-lived worker for one session. Owns the outbound channel,
/// the shutdown signal, and the WebSocket lifecycle.
async fn session_worker(mut args: WorkerArgs) {
    let mut current_ws = args.initial_ws.take();
    let mut shutdown_rx = args.shutdown_rx;

    loop {
        // Acquire (or re-acquire) a live WebSocket.
        let ws = match current_ws.take() {
            Some(ws) => ws,
            None => {
                match reconnect(
                    &args.endpoint,
                    &args.session_id,
                    &args.assistant,
                    &args.token,
                    &args.delegate,
                    &mut shutdown_rx,
                )
                .await
                {
                    ReconnectOutcome::Reconnected(ws) => *ws,
                    ReconnectOutcome::AuthExpired => {
                        let reason = "authentication failed".to_string();
                        args.delegate.on_connection_health(
                            args.session_id.clone(),
                            ConnectionHealth::Disconnected {
                                reason: reason.clone(),
                                auth: true,
                            },
                        );
                        args.delegate.on_disconnected(reason);
                        return;
                    }
                    ReconnectOutcome::Exhausted => {
                        let reason =
                            format!("reconnect failed after {RECONNECT_MAX_ATTEMPTS} attempts");
                        args.delegate.on_connection_health(
                            args.session_id.clone(),
                            ConnectionHealth::Disconnected {
                                reason: reason.clone(),
                                auth: false,
                            },
                        );
                        args.delegate.on_disconnected(reason);
                        return;
                    }
                    ReconnectOutcome::ShutdownRequested => {
                        return;
                    }
                }
            }
        };

        // Drive the socket until it dies, the user closes us out, the
        // pong deadline fires, or the host signals a network change.
        let outcome = drive_socket(
            ws,
            &mut args.rx,
            &mut shutdown_rx,
            &args.nudge,
            &args.delegate,
            &args.session_id,
        )
        .await;

        match outcome {
            DriveOutcome::ClientClose => {
                return;
            }
            DriveOutcome::Disconnected(reason) => {
                args.delegate.on_connection_health(
                    args.session_id.clone(),
                    ConnectionHealth::Disconnected {
                        reason: reason.clone(),
                        auth: false,
                    },
                );
                // Loop back to reconnect.
            }
        }
    }
}

enum ReconnectOutcome {
    Reconnected(Box<WsStream>),
    AuthExpired,
    Exhausted,
    ShutdownRequested,
}

async fn reconnect(
    endpoint: &str,
    session_id: &str,
    assistant: &str,
    token: &str,
    delegate: &Arc<dyn SweKittyDelegate>,
    shutdown_rx: &mut oneshot::Receiver<()>,
) -> ReconnectOutcome {
    for attempt in 1..=RECONNECT_MAX_ATTEMPTS {
        delegate.on_connection_health(
            session_id.to_string(),
            ConnectionHealth::Connecting {
                attempt,
                max_attempts: RECONNECT_MAX_ATTEMPTS,
            },
        );

        // Wait before retrying so we don't hammer the server. Skipping
        // the wait on attempt 1 would just slam right after a drop and
        // is unlikely to succeed anyway.
        let sleep = tokio::time::sleep(RECONNECT_DELAY);
        tokio::pin!(sleep);
        tokio::select! {
            _ = &mut sleep => {}
            _ = &mut *shutdown_rx => { return ReconnectOutcome::ShutdownRequested; }
        }

        match open_ws(endpoint, session_id, assistant, token).await {
            Ok(ws) => {
                delegate.on_connection_health(session_id.to_string(), ConnectionHealth::Connected);
                return ReconnectOutcome::Reconnected(Box::new(ws));
            }
            Err(SweKittyError::Auth) => {
                return ReconnectOutcome::AuthExpired;
            }
            Err(_) => {
                // Try again until we hit MAX_ATTEMPTS.
            }
        }
    }
    ReconnectOutcome::Exhausted
}

enum DriveOutcome {
    ClientClose,
    Disconnected(String),
}

async fn drive_socket(
    ws: WsStream,
    rx: &mut mpsc::Receiver<Message>,
    shutdown_rx: &mut oneshot::Receiver<()>,
    nudge: &Arc<Notify>,
    delegate: &Arc<dyn SweKittyDelegate>,
    session_id: &str,
) -> DriveOutcome {
    let (mut writer, mut reader) = ws.split();
    let mut snap = SnapshotReassembler::new();
    let mut heartbeat = tokio::time::interval(HEARTBEAT_INTERVAL);
    heartbeat.tick().await; // consume the immediate tick
    let mut last_inbound = Instant::now();

    loop {
        tokio::select! {
            biased;
            _ = &mut *shutdown_rx => {
                let _ = writer.send(Message::Close(None)).await;
                let _ = writer.close().await;
                return DriveOutcome::ClientClose;
            }
            _ = nudge.notified() => {
                // OS told us the network path probably changed. Don't
                // wait for TCP to surface a half-open; force-close and
                // reconnect immediately.
                let _ = writer.close().await;
                return DriveOutcome::Disconnected("network change".to_string());
            }
            outbound = rx.recv() => {
                let Some(msg) = outbound else {
                    // SessionHandle dropped — also a clean shutdown.
                    let _ = writer.send(Message::Close(None)).await;
                    let _ = writer.close().await;
                    return DriveOutcome::ClientClose;
                };
                let is_close = matches!(msg, Message::Close(_));
                if let Err(e) = writer.send(msg).await {
                    return DriveOutcome::Disconnected(format!("send: {e}"));
                }
                if is_close {
                    let _ = writer.close().await;
                    return DriveOutcome::ClientClose;
                }
            }
            inbound = reader.next() => {
                let Some(item) = inbound else {
                    return DriveOutcome::Disconnected("eof".to_string());
                };
                last_inbound = Instant::now();
                match item {
                    Ok(Message::Binary(payload)) => {
                        if let Err(e) = handle_binary(session_id, delegate, &mut snap, payload) {
                            return DriveOutcome::Disconnected(e.to_string());
                        }
                    }
                    Ok(Message::Text(text)) => {
                        if let Err(e) = handle_text(session_id, delegate, &mut writer, &text).await {
                            return DriveOutcome::Disconnected(e.to_string());
                        }
                    }
                    Ok(Message::Ping(p)) => {
                        if let Err(e) = writer.send(Message::Pong(p)).await {
                            return DriveOutcome::Disconnected(format!("pong: {e}"));
                        }
                    }
                    Ok(Message::Pong(_)) | Ok(Message::Frame(_)) => {}
                    Ok(Message::Close(_)) => {
                        return DriveOutcome::Disconnected("closed by server".to_string());
                    }
                    Err(e) => {
                        return DriveOutcome::Disconnected(e.to_string());
                    }
                }
            }
            _ = heartbeat.tick() => {
                if last_inbound.elapsed() > PONG_DEADLINE {
                    // Server hasn't said anything in too long; assume
                    // the socket is half-open and force a reconnect.
                    let _ = writer.close().await;
                    return DriveOutcome::Disconnected("pong deadline".to_string());
                }
                let ping = serde_json::json!({ "type": "ping" }).to_string();
                if let Err(e) = writer.send(Message::Text(ping)).await {
                    return DriveOutcome::Disconnected(format!("ping: {e}"));
                }
            }
        }
    }
}

async fn open_ws(
    endpoint: &str,
    session_id: &str,
    assistant: &str,
    token: &str,
) -> Result<WsStream, SweKittyError> {
    let base = normalize_ws_endpoint(endpoint)?;
    let mut target = build_initial_ws_url(&base, session_id, assistant, token)?;
    let mut hops = 0usize;

    loop {
        let mut request = target
            .as_str()
            .into_client_request()
            .map_err(|e| SweKittyError::Connection(e.to_string()))?;
        request.headers_mut().insert(
            "Authorization",
            HeaderValue::from_str(&format!("Bearer {token}"))
                .map_err(|e| SweKittyError::Connection(e.to_string()))?,
        );

        match connect_async(request).await {
            Ok((ws, _resp)) => return Ok(ws),
            Err(WsError::Http(response)) if response.status() == StatusCode::UNAUTHORIZED => {
                return Err(SweKittyError::Auth);
            }
            Err(WsError::Http(response))
                if is_redirect_status(response.status()) && hops < WS_REDIRECT_MAX_HOPS =>
            {
                let location = response
                    .headers()
                    .get("Location")
                    .and_then(|h| h.to_str().ok())
                    .ok_or_else(|| {
                        SweKittyError::Connection(format!(
                            "HTTP error: {} (missing redirect location)",
                            response.status()
                        ))
                    })?;
                // Honour the redirect Location verbatim — do NOT re-append
                // /ws/{session_id} to it. The previous shape lost track of
                // whether the Location already contained the ws path and
                // ended up requesting /ws/abc/ws/abc on the next hop, which
                // the upstream proxy bounced again until we hit hop limit
                // and surfaced "HTTP error: 302 Found" (Sentry APPLE-IOS-3).
                target = redirect_to_ws_url(&target, location, token)?;
                hops += 1;
                continue;
            }
            Err(WsError::Http(response)) => {
                return Err(SweKittyError::Connection(format!(
                    "HTTP error: {}",
                    response.status()
                )));
            }
            Err(e) => return Err(SweKittyError::Connection(e.to_string())),
        }
    }
}

fn build_initial_ws_url(
    base: &Url,
    session_id: &str,
    assistant: &str,
    token: &str,
) -> Result<Url, SweKittyError> {
    let raw = format!(
        "{}/ws/{}?assistant={}&token={}",
        base.as_str().trim_end_matches('/'),
        session_id,
        urlencode(assistant),
        urlencode(token),
    );
    Url::parse(&raw).map_err(|e| SweKittyError::Connection(e.to_string()))
}

/// Resolve `location` relative to the previous target ws URL, then translate
/// http(s) into ws(s) and make sure the bearer token still rides in the
/// query string (some upstream proxies strip headers across a redirect).
fn redirect_to_ws_url(current: &Url, location: &str, token: &str) -> Result<Url, SweKittyError> {
    let mut next = current
        .join(location)
        .map_err(|e| SweKittyError::Connection(e.to_string()))?;
    match next.scheme() {
        "http" => next
            .set_scheme("ws")
            .map_err(|_| SweKittyError::Connection("invalid ws redirect scheme".to_string()))?,
        "https" => next
            .set_scheme("wss")
            .map_err(|_| SweKittyError::Connection("invalid wss redirect scheme".to_string()))?,
        "ws" | "wss" => {}
        other => {
            return Err(SweKittyError::Connection(format!(
                "unsupported redirect scheme: {other}"
            )))
        }
    }
    // Preserve any pre-existing query the server sent us (e.g. an auth
    // cookie hint); if the redirect dropped the `token=` query we put there,
    // splice it back in so the next hop can still authenticate.
    let has_token = next
        .query_pairs()
        .any(|(k, _)| k.eq_ignore_ascii_case("token"));
    if !has_token {
        next.query_pairs_mut().append_pair("token", token);
    }
    Ok(next)
}

fn normalize_ws_endpoint(endpoint: &str) -> Result<Url, SweKittyError> {
    let mut parsed = Url::parse(endpoint).map_err(|e| SweKittyError::Connection(e.to_string()))?;
    match parsed.scheme() {
        "http" => parsed
            .set_scheme("ws")
            .map_err(|_| SweKittyError::Connection("invalid ws endpoint scheme".to_string()))?,
        "https" => parsed
            .set_scheme("wss")
            .map_err(|_| SweKittyError::Connection("invalid wss endpoint scheme".to_string()))?,
        "ws" | "wss" => {}
        other => {
            return Err(SweKittyError::Connection(format!(
                "unsupported endpoint scheme: {other}"
            )))
        }
    }
    parsed.set_query(None);
    parsed.set_fragment(None);
    Ok(parsed)
}

fn is_redirect_status(status: StatusCode) -> bool {
    matches!(
        status,
        StatusCode::MOVED_PERMANENTLY
            | StatusCode::FOUND
            | StatusCode::TEMPORARY_REDIRECT
            | StatusCode::PERMANENT_REDIRECT
    )
}

fn handle_binary(
    session_id: &str,
    delegate: &Arc<dyn SweKittyDelegate>,
    snap: &mut SnapshotReassembler,
    payload: Vec<u8>,
) -> Result<(), SweKittyError> {
    if payload.is_empty() {
        return Ok(());
    }
    match payload[0] {
        TAG_RESIZE | TAG_UPLOAD => Ok(()),
        TAG_SNAPSHOT => {
            if let Some(gunzipped) = snap.push(&payload)? {
                delegate.on_snapshot(session_id.to_string(), gunzipped);
            }
            Ok(())
        }
        TAG_ESCAPE => {
            delegate.on_pty_data(session_id.to_string(), payload[1..].to_vec());
            Ok(())
        }
        _ => {
            delegate.on_pty_data(session_id.to_string(), payload);
            Ok(())
        }
    }
}

async fn handle_text(
    session_id: &str,
    delegate: &Arc<dyn SweKittyDelegate>,
    writer: &mut futures_util::stream::SplitSink<WsStream, Message>,
    text: &str,
) -> Result<(), SweKittyError> {
    #[derive(Deserialize)]
    struct Envelope {
        #[serde(rename = "type")]
        ty: String,
        #[serde(default)]
        session: Option<String>,
        #[serde(default)]
        assistant: Option<String>,
        #[serde(default)]
        phase: Option<String>,
        #[serde(default)]
        health: Option<String>,
        #[serde(default)]
        rows: Option<u16>,
        #[serde(default)]
        cols: Option<u16>,
        #[serde(default)]
        yolo: Option<bool>,
        #[serde(default)]
        preview: Option<PreviewInfo>,
        #[serde(default)]
        session_name: Option<String>,
        #[serde(default)]
        viewers: Option<u32>,
        #[serde(default)]
        reasoning_effort: Option<String>,
        #[serde(default)]
        cwd: Option<String>,
        #[serde(default)]
        started_at: Option<String>,
        #[serde(default)]
        last_activity_at: Option<String>,
        #[serde(default)]
        display_name: Option<String>,
        #[serde(default)]
        code: Option<i32>,
        #[serde(default)]
        view: Option<String>,
        #[serde(default)]
        event: Option<ChatEvent>,
        #[serde(default)]
        from: Option<String>,
        #[serde(default)]
        msg: Option<String>,
        #[serde(default)]
        ts: Option<String>,
    }
    let env: Envelope = match serde_json::from_str(text) {
        Ok(v) => v,
        Err(_) => return Ok(()),
    };
    match env.ty.as_str() {
        "status" => {
            let status = SessionStatus {
                session: env.session.unwrap_or_else(|| session_id.to_string()),
                assistant: env.assistant.unwrap_or_default(),
                phase: env.phase.unwrap_or_else(|| "running".to_string()),
                health: env.health.unwrap_or_else(|| "healthy".to_string()),
                rows: env.rows.unwrap_or(40),
                cols: env.cols.unwrap_or(120),
                yolo: env.yolo.unwrap_or(false),
                preview: env.preview.clone(),
                session_name: env.session_name,
                viewers: env.viewers,
                reasoning_effort: env.reasoning_effort,
                cwd: env.cwd,
                started_at: env.started_at,
                last_activity_at: env.last_activity_at,
                display_name: env.display_name,
            };
            delegate.on_status(status);
            if let Some(p) = env.preview {
                delegate.on_preview_ready(session_id.to_string(), p);
            }
        }
        "chat" => {
            if let Some(msg) = env.msg {
                delegate.on_chat_event(
                    session_id.to_string(),
                    ChatEvent {
                        role: env.from.unwrap_or_else(|| "user".to_string()),
                        content: msg,
                        ts: env.ts.unwrap_or_default(),
                        files: Vec::<ViewEventFile>::new(),
                    },
                );
            }
        }
        "exit" => {
            delegate.on_exit(session_id.to_string(), env.code.unwrap_or(0));
        }
        "view_event" => {
            if let (Some(view), Some(ev)) = (env.view, env.event) {
                if view == "chat" {
                    delegate.on_chat_event(session_id.to_string(), ev);
                }
            }
        }
        "ping" => {
            writer
                .send(Message::Text(
                    serde_json::json!({ "type": "pong" }).to_string(),
                ))
                .await
                .map_err(|e| SweKittyError::Connection(e.to_string()))?;
        }
        "pong" => {}
        _ => {}
    }
    Ok(())
}

struct SnapshotReassembler {
    gz_buf: Vec<u8>,
    expected_idx: u16,
}

impl SnapshotReassembler {
    fn new() -> Self {
        Self {
            gz_buf: Vec::new(),
            expected_idx: 0,
        }
    }

    fn push(&mut self, frame: &[u8]) -> Result<Option<Vec<u8>>, SweKittyError> {
        if frame.len() < 5 || frame[0] != TAG_SNAPSHOT {
            return Ok(None);
        }
        let idx = u16::from_be_bytes([frame[1], frame[2]]);
        let total = u16::from_be_bytes([frame[3], frame[4]]);
        if idx != self.expected_idx {
            self.gz_buf.clear();
            self.expected_idx = 0;
            return Err(SweKittyError::Protocol(format!(
                "snapshot chunk out of order: expected {} got {}",
                self.expected_idx, idx
            )));
        }
        self.gz_buf.extend_from_slice(&frame[5..]);
        self.expected_idx += 1;
        if self.expected_idx >= total {
            let mut out = Vec::new();
            let mut dec = GzDecoder::new(self.gz_buf.as_slice());
            dec.read_to_end(&mut out)
                .map_err(|e| SweKittyError::Protocol(e.to_string()))?;
            self.gz_buf.clear();
            self.expected_idx = 0;
            Ok(Some(out))
        } else {
            Ok(None)
        }
    }
}

fn is_reserved_tag(b: u8) -> bool {
    matches!(b, TAG_RESIZE | TAG_UPLOAD | TAG_SNAPSHOT | TAG_ESCAPE)
}

/// Encode a 0x01 file-upload frame. Pure function so unit tests can
/// pin the byte layout without spinning up a websocket. Length fields
/// are u32 little-endian (matches the broker's parseUploadFrame).
fn encode_upload_frame(session_id: &str, filename: &str, mime: &str, bytes: &[u8]) -> Vec<u8> {
    let sid = session_id.as_bytes();
    let name = filename.as_bytes();
    let mime_b = mime.as_bytes();
    let total = 1 + 4 + sid.len() + 4 + name.len() + 4 + mime_b.len() + bytes.len();
    let mut out = Vec::with_capacity(total);
    out.push(TAG_UPLOAD);
    let append_lp = |out: &mut Vec<u8>, s: &[u8]| {
        out.extend_from_slice(&(s.len() as u32).to_le_bytes());
        out.extend_from_slice(s);
    };
    append_lp(&mut out, sid);
    append_lp(&mut out, name);
    append_lp(&mut out, mime_b);
    out.extend_from_slice(bytes);
    out
}

fn urlencode(s: &str) -> String {
    // tiny URL encoder — only what's needed for the query string values
    // we send (bearer tokens are URL-safe base64; assistant names are
    // [a-z]+). Avoid pulling a 30 KB crate for this.
    let mut out = String::with_capacity(s.len());
    for b in s.bytes() {
        match b {
            b'-' | b'_' | b'.' | b'~' | b'0'..=b'9' | b'A'..=b'Z' | b'a'..=b'z' => {
                out.push(b as char)
            }
            _ => out.push_str(&format!("%{:02X}", b)),
        }
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;
    use flate2::write::GzEncoder;
    use flate2::Compression;
    use std::io::Write;

    #[test]
    fn snapshot_reassembles_in_order() {
        let mut e = GzEncoder::new(Vec::new(), Compression::default());
        e.write_all(b"hello world from snapshot").unwrap();
        let gz = e.finish().unwrap();

        // Split into two chunks to exercise multi-chunk path.
        let mid = gz.len() / 2;
        let (a, b) = gz.split_at(mid);
        let frame0 = build_snap_frame(0, 2, a);
        let frame1 = build_snap_frame(1, 2, b);

        let mut r = SnapshotReassembler::new();
        assert!(r.push(&frame0).unwrap().is_none());
        let out = r.push(&frame1).unwrap().unwrap();
        assert_eq!(out, b"hello world from snapshot");
    }

    #[test]
    fn snapshot_out_of_order_discards() {
        let frame1 = build_snap_frame(1, 2, b"x");
        let mut r = SnapshotReassembler::new();
        assert!(r.push(&frame1).is_err());
        assert_eq!(r.expected_idx, 0); // reset
    }

    #[test]
    fn reserved_tag_check() {
        for b in [0x00u8, 0x01, 0x02, 0xFF] {
            assert!(is_reserved_tag(b));
        }
        for b in [b'a', b'h', 0x10, 0x7F] {
            assert!(!is_reserved_tag(b));
        }
    }

    fn build_snap_frame(idx: u16, total: u16, gz: &[u8]) -> Vec<u8> {
        let mut v = vec![TAG_SNAPSHOT];
        v.extend_from_slice(&idx.to_be_bytes());
        v.extend_from_slice(&total.to_be_bytes());
        v.extend_from_slice(gz);
        v
    }

    #[test]
    fn redirect_http_to_https_does_not_duplicate_ws_path() {
        // Reproduces Sentry APPLE-IOS-3: client opens
        // ws://harness.example.com/ws/abc and the reverse proxy 302s to
        // https://harness.example.com/ws/abc. The fix must NOT re-append
        // /ws/abc on the next hop.
        let base = normalize_ws_endpoint("ws://harness.example.com").unwrap();
        let initial = build_initial_ws_url(&base, "abc", "claude", "tok").unwrap();
        assert_eq!(
            initial.as_str(),
            "ws://harness.example.com/ws/abc?assistant=claude&token=tok"
        );
        let next = redirect_to_ws_url(
            &initial,
            "https://harness.example.com/ws/abc?assistant=claude&token=tok",
            "tok",
        )
        .unwrap();
        assert_eq!(next.scheme(), "wss");
        assert_eq!(next.host_str(), Some("harness.example.com"));
        assert_eq!(next.path(), "/ws/abc");
        assert!(next.as_str().contains("token=tok"));
        // Critical: no duplicated /ws/abc/ws/abc.
        assert_eq!(next.as_str().matches("/ws/abc").count(), 1);
    }

    #[test]
    fn redirect_relative_location_resolves_against_target() {
        let base = normalize_ws_endpoint("https://example.com").unwrap();
        let initial = build_initial_ws_url(&base, "s1", "claude", "t").unwrap();
        let next = redirect_to_ws_url(&initial, "/ws/s1/", "t").unwrap();
        assert_eq!(next.scheme(), "wss");
        assert_eq!(next.path(), "/ws/s1/");
        assert_eq!(next.as_str().matches("/ws/s1").count(), 1);
    }

    #[test]
    fn redirect_preserves_token_when_proxy_strips_it() {
        let base = normalize_ws_endpoint("wss://example.com").unwrap();
        let initial = build_initial_ws_url(&base, "s1", "claude", "secret").unwrap();
        // Proxy returns a Location without the original token query.
        let next = redirect_to_ws_url(
            &initial,
            "https://example.com/ws/s1?assistant=claude",
            "secret",
        )
        .unwrap();
        assert!(next.as_str().contains("token=secret"));
    }

    #[test]
    fn encode_upload_frame_layout() {
        // Pin the byte layout: 0x01 tag, then three u32-LE length-prefixed
        // strings, then the raw body bytes. The broker's parseUploadFrame
        // is the symmetric reader; if either side drifts the round-trip
        // test on the broker side fails first, but pinning the encoder
        // here surfaces the regression at the boundary it actually owns.
        let sid = "abc";
        let name = "hi.txt";
        let mime = "text/plain";
        let body = b"hello";
        let frame = encode_upload_frame(sid, name, mime, body);

        // Tag byte.
        assert_eq!(frame[0], TAG_UPLOAD);

        // session_id LP block.
        let mut off = 1;
        let sid_len = u32::from_le_bytes(frame[off..off + 4].try_into().unwrap()) as usize;
        off += 4;
        assert_eq!(sid_len, sid.len());
        assert_eq!(&frame[off..off + sid_len], sid.as_bytes());
        off += sid_len;

        // filename LP block.
        let name_len = u32::from_le_bytes(frame[off..off + 4].try_into().unwrap()) as usize;
        off += 4;
        assert_eq!(name_len, name.len());
        assert_eq!(&frame[off..off + name_len], name.as_bytes());
        off += name_len;

        // mime LP block.
        let mime_len = u32::from_le_bytes(frame[off..off + 4].try_into().unwrap()) as usize;
        off += 4;
        assert_eq!(mime_len, mime.len());
        assert_eq!(&frame[off..off + mime_len], mime.as_bytes());
        off += mime_len;

        // body bytes — everything remaining.
        assert_eq!(&frame[off..], body);
        assert_eq!(frame.len(), off + body.len());
    }

    #[test]
    fn redirect_keeps_existing_token_in_location() {
        let base = normalize_ws_endpoint("ws://example.com").unwrap();
        let initial = build_initial_ws_url(&base, "s1", "claude", "old").unwrap();
        let next = redirect_to_ws_url(
            &initial,
            "ws://example.com/ws/s1?assistant=claude&token=fresh",
            "old",
        )
        .unwrap();
        // The Location's token wins; we don't append a second one.
        assert_eq!(next.as_str().matches("token=").count(), 1);
        assert!(next.as_str().contains("token=fresh"));
    }
}
