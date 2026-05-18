//! WebSocket transport for swe-kitty-core.
//!
//! Implements the binary-tag demux from `docs/WEBSOCKET-PROTOCOL.md`
//! §2.1 (0x00 resize / 0x01 upload / 0x02 snapshot / 0xFF escape / else
//! raw PTY) and the JSON control envelopes from §3, then surfaces each
//! event to the supplied delegate.
//!
//! Snapshot frames are reassembled in-order and gunzipped before the
//! delegate sees them — apps never see the chunking.

use std::io::Read;
use std::sync::Arc;
use std::time::Duration;

use flate2::read::GzDecoder;
use futures_util::{SinkExt, StreamExt};
use serde::Deserialize;
use tokio::net::TcpStream;
use tokio::runtime::Handle;
use tokio::sync::{mpsc, Mutex};
use tokio_tungstenite::tungstenite::client::IntoClientRequest;
use tokio_tungstenite::tungstenite::http::{HeaderValue, StatusCode};
use tokio_tungstenite::tungstenite::{Error as WsError, Message};
use tokio_tungstenite::{connect_async, MaybeTlsStream, WebSocketStream};

use crate::views::{ChatEvent, PreviewInfo, SessionStatus, ViewEventFile};
use crate::{SweKittyDelegate, SweKittyError};

const TAG_RESIZE: u8 = 0x00;
const TAG_UPLOAD: u8 = 0x01;
const TAG_SNAPSHOT: u8 = 0x02;
const TAG_ESCAPE: u8 = 0xFF;
const HEARTBEAT_INTERVAL: Duration = Duration::from_secs(30);

/// A live websocket attached to one session. Cheap to clone; cloning
/// shares the underlying writer.
#[derive(Clone)]
pub struct SessionHandle {
    tx: mpsc::Sender<Message>,
}

impl SessionHandle {
    pub fn close(&self) {
        let _ = self.tx.try_send(Message::Close(None));
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

pub async fn connect(
    runtime: &Handle,
    endpoint: String,
    session_id: String,
    assistant: String,
    token: String,
    delegate: Arc<dyn SweKittyDelegate>,
) -> Result<SessionHandle, SweKittyError> {
    let join = runtime.spawn(async move {
        let url = format!(
            "{}/ws/{}?assistant={}&token={}",
            endpoint.trim_end_matches('/'),
            session_id,
            urlencode(&assistant),
            urlencode(&token),
        );
        let mut request = url
            .into_client_request()
            .map_err(|e| SweKittyError::Connection(e.to_string()))?;
        request.headers_mut().insert(
            "Authorization",
            HeaderValue::from_str(&format!("Bearer {token}"))
                .map_err(|e| SweKittyError::Connection(e.to_string()))?,
        );

        let (ws, _resp) = match connect_async(request).await {
            Ok(parts) => parts,
            Err(WsError::Http(response)) if response.status() == StatusCode::UNAUTHORIZED => {
                return Err(SweKittyError::Auth);
            }
            Err(e) => return Err(SweKittyError::Connection(e.to_string())),
        };
        let (writer, reader) = ws.split();
        let (tx, rx) = mpsc::channel::<Message>(64);
        let writer = Arc::new(Mutex::new(writer));

        tokio::spawn(writer_loop(writer, rx));
        tokio::spawn(heartbeat_loop(tx.clone()));
        tokio::spawn(reader_loop(
            reader,
            session_id,
            delegate,
            tx.clone(),
            SnapshotReassembler::new(),
        ));

        Ok(SessionHandle { tx })
    });

    match join.await {
        Ok(result) => result,
        Err(e) => Err(SweKittyError::Connection(format!(
            "runtime join failed: {e}"
        ))),
    }
}

async fn writer_loop(
    writer: Arc<Mutex<futures_util::stream::SplitSink<WsStream, Message>>>,
    mut rx: mpsc::Receiver<Message>,
) {
    while let Some(msg) = rx.recv().await {
        let mut w = writer.lock().await;
        if w.send(msg).await.is_err() {
            break;
        }
    }
}

async fn heartbeat_loop(tx: mpsc::Sender<Message>) {
    let mut ticker = tokio::time::interval(HEARTBEAT_INTERVAL);
    loop {
        ticker.tick().await;
        if tx
            .send(Message::Text(
                serde_json::json!({ "type": "ping" }).to_string(),
            ))
            .await
            .is_err()
        {
            return;
        }
    }
}

async fn reader_loop(
    mut reader: futures_util::stream::SplitStream<WsStream>,
    session_id: String,
    delegate: Arc<dyn SweKittyDelegate>,
    tx: mpsc::Sender<Message>,
    mut snap: SnapshotReassembler,
) {
    while let Some(item) = reader.next().await {
        match item {
            Ok(Message::Binary(payload)) => {
                if let Err(e) = handle_binary(&session_id, &delegate, &mut snap, payload) {
                    delegate.on_disconnected(e.to_string());
                    return;
                }
            }
            Ok(Message::Text(text)) => {
                if let Err(e) = handle_text(&session_id, &delegate, &tx, &text).await {
                    delegate.on_disconnected(e.to_string());
                    return;
                }
            }
            Ok(Message::Ping(p)) => {
                if tx.send(Message::Pong(p)).await.is_err() {
                    return;
                }
            }
            Ok(Message::Pong(_)) | Ok(Message::Frame(_)) => {}
            Ok(Message::Close(_)) => {
                delegate.on_disconnected("closed".to_string());
                return;
            }
            Err(e) => {
                delegate.on_disconnected(e.to_string());
                return;
            }
        }
    }
    delegate.on_disconnected("eof".to_string());
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
    tx: &mpsc::Sender<Message>,
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
            tx.send(Message::Text(
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
}
