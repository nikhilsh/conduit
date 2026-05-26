//! End-to-end protocol round-trip tests.
//!
//! Stands up a tiny in-process WebSocket server, drives `transport::connect`
//! from the public API with a recording delegate, and asserts that the
//! broker's wire-format frames (`status`, `view_event { view: "chat" }`)
//! produce the expected `SweKittyDelegate` callbacks.
//!
//! This is the **real test harness** for the wire protocol: changing the
//! shape of a frame on either side without updating both will fail here.
//! Until this existed, drift between core and broker only showed up when
//! a user opened the app on a fresh build and noticed missing data.

use std::collections::HashMap;
use std::sync::{Arc, Mutex};
use std::time::Duration;

use futures_util::{SinkExt, StreamExt};
use swe_kitty_core::{
    transport, ChatEvent, ConnectionHealth, PreviewInfo, SessionStatus, SweKittyDelegate,
};
use tokio::net::TcpListener;
use tokio_tungstenite::tungstenite::Message;

/// One recorded `on_view_event` call: (session_id, kind, payload).
type ViewEventRecord = (String, String, HashMap<String, String>);

/// Records every delegate call so tests can assert on the post-hoc shape.
#[derive(Default)]
struct RecordingDelegate {
    statuses: Mutex<Vec<SessionStatus>>,
    chats: Mutex<Vec<(String, ChatEvent)>>,
    healths: Mutex<Vec<(String, ConnectionHealth)>>,
    disconnects: Mutex<Vec<String>>,
    view_events: Mutex<Vec<ViewEventRecord>>,
}

impl SweKittyDelegate for RecordingDelegate {
    fn on_pty_data(&self, _session_id: String, _data: Vec<u8>) {}
    fn on_chat_event(&self, session_id: String, event: ChatEvent) {
        self.chats.lock().unwrap().push((session_id, event));
    }
    fn on_preview_ready(&self, _session_id: String, _preview: PreviewInfo) {}
    fn on_status(&self, status: SessionStatus) {
        self.statuses.lock().unwrap().push(status);
    }
    fn on_snapshot(&self, _session_id: String, _gunzipped: Vec<u8>) {}
    fn on_exit(&self, _session_id: String, _code: i32) {}
    fn on_disconnected(&self, reason: String) {
        self.disconnects.lock().unwrap().push(reason);
    }
    fn on_connection_health(&self, session_id: String, health: ConnectionHealth) {
        self.healths.lock().unwrap().push((session_id, health));
    }
    fn on_view_event(&self, session_id: String, kind: String, payload: HashMap<String, String>) {
        self.view_events
            .lock()
            .unwrap()
            .push((session_id, kind, payload));
    }
}

/// Spawns a minimal WS server that accepts ONE connection on /ws/<anything>,
/// invokes `script` with the established websocket, then closes. Returns
/// (endpoint_url, server_join_handle).
async fn spawn_test_server<F, Fut>(script: F) -> (String, tokio::task::JoinHandle<()>)
where
    F: FnOnce(tokio_tungstenite::WebSocketStream<tokio::net::TcpStream>) -> Fut + Send + 'static,
    Fut: std::future::Future<Output = ()> + Send,
{
    let listener = TcpListener::bind("127.0.0.1:0").await.expect("bind");
    let addr = listener.local_addr().expect("local_addr");
    let endpoint = format!("ws://{}", addr);

    let handle = tokio::spawn(async move {
        let (stream, _) = listener.accept().await.expect("accept");
        let ws = tokio_tungstenite::accept_async(stream)
            .await
            .expect("ws handshake");
        script(ws).await;
    });

    (endpoint, handle)
}

/// Waits up to `timeout` for `cond` to return true, polling every 10ms.
/// Lets the test assert "by now the delegate should have seen X" without
/// guessing a sleep duration that's both reliable and fast.
async fn wait_until<F>(timeout: Duration, mut cond: F) -> bool
where
    F: FnMut() -> bool,
{
    let start = std::time::Instant::now();
    while start.elapsed() < timeout {
        if cond() {
            return true;
        }
        tokio::time::sleep(Duration::from_millis(10)).await;
    }
    cond()
}

#[tokio::test]
async fn status_frame_round_trips_to_delegate() {
    let (endpoint, server) = spawn_test_server(|mut ws| async move {
        // Send a status frame the moment the client connects, then
        // hang so the test client doesn't see EOF and treat that as
        // a fault.
        let frame = serde_json::json!({
            "type": "status",
            "session": "s-test",
            "assistant": "claude",
            "phase": "running",
            "health": "healthy",
            "rows": 40,
            "cols": 120,
            "yolo": false,
            "session_name": "demo",
            "reasoning_effort": "high",
            "cwd": "/tmp/work",
        });
        ws.send(Message::Text(frame.to_string())).await.unwrap();
        // Hold the connection open so the worker stays subscribed.
        let _ = ws.next().await;
    })
    .await;

    let delegate = Arc::new(RecordingDelegate::default());
    let _handle = transport::connect(
        endpoint,
        "s-test".into(),
        "claude".into(),
        "test-token".into(),
        transport::SpawnOverride::default(),
        delegate.clone(),
    )
    .await
    .expect("connect");

    let got = wait_until(Duration::from_secs(2), || {
        !delegate.statuses.lock().unwrap().is_empty()
    })
    .await;
    assert!(got, "delegate never received the status frame");

    let statuses = delegate.statuses.lock().unwrap();
    assert_eq!(statuses.len(), 1);
    let s = &statuses[0];
    assert_eq!(s.session, "s-test");
    assert_eq!(s.assistant, "claude");
    assert_eq!(s.phase, "running");
    assert_eq!(s.health, "healthy");
    assert_eq!(s.rows, 40);
    assert_eq!(s.cols, 120);
    assert_eq!(s.session_name.as_deref(), Some("demo"));
    assert_eq!(s.reasoning_effort.as_deref(), Some("high"));
    assert_eq!(s.cwd.as_deref(), Some("/tmp/work"));

    server.abort();
}

#[tokio::test]
async fn view_event_chat_round_trips_to_delegate() {
    let (endpoint, server) = spawn_test_server(|mut ws| async move {
        // First send a status so the worker considers itself
        // healthy, then a chat view_event.
        let status = serde_json::json!({
            "type": "status",
            "session": "s-chat",
            "assistant": "claude",
            "phase": "running",
            "health": "healthy",
            "rows": 24,
            "cols": 80,
            "yolo": false,
        });
        ws.send(Message::Text(status.to_string())).await.unwrap();

        let chat = serde_json::json!({
            "type": "view_event",
            "view": "chat",
            "event": {
                "role": "assistant",
                "content": "hello from the broker",
                "ts": "2026-05-21T08:00:00Z",
                "files": [],
            },
        });
        ws.send(Message::Text(chat.to_string())).await.unwrap();
        let _ = ws.next().await;
    })
    .await;

    let delegate = Arc::new(RecordingDelegate::default());
    let _handle = transport::connect(
        endpoint,
        "s-chat".into(),
        "claude".into(),
        "test-token".into(),
        transport::SpawnOverride::default(),
        delegate.clone(),
    )
    .await
    .expect("connect");

    let got = wait_until(Duration::from_secs(2), || {
        !delegate.chats.lock().unwrap().is_empty()
    })
    .await;
    assert!(got, "delegate never received the chat event");

    let chats = delegate.chats.lock().unwrap();
    assert_eq!(chats.len(), 1);
    let (sid, ev) = &chats[0];
    assert_eq!(sid, "s-chat");
    assert_eq!(ev.role, "assistant");
    assert_eq!(ev.content, "hello from the broker");
    assert_eq!(ev.ts, "2026-05-21T08:00:00Z");

    server.abort();
}

#[tokio::test]
async fn view_event_status_agent_login_round_trips_to_delegate() {
    // Regression: the broker emits agent_login_* as view_event with
    // view:"status" and a non-ChatEvent `event` body. Before the core
    // accepted a raw `event`, this whole envelope failed ChatEvent
    // deserialization and was dropped — so OAuth login never advanced.
    let (endpoint, server) = spawn_test_server(|mut ws| async move {
        let status = serde_json::json!({
            "type": "status", "session": "s-oauth", "assistant": "codex",
            "phase": "running", "health": "healthy", "rows": 24, "cols": 80, "yolo": false,
        });
        ws.send(Message::Text(status.to_string())).await.unwrap();

        let login = serde_json::json!({
            "type": "view_event",
            "session": "s-oauth",
            "view": "status",
            "event": {
                "agent_login_url": {
                    "provider": "openai",
                    "url": "https://auth.openai.com/authorize?x=1",
                    "loopback_port": 8123,
                    "session_token": "tok-abc",
                }
            },
        });
        ws.send(Message::Text(login.to_string())).await.unwrap();
        let _ = ws.next().await;
    })
    .await;

    let delegate = Arc::new(RecordingDelegate::default());
    let _handle = transport::connect(
        endpoint,
        "s-oauth".into(),
        "codex".into(),
        "test-token".into(),
        transport::SpawnOverride::default(),
        delegate.clone(),
    )
    .await
    .expect("connect");

    let got = wait_until(Duration::from_secs(2), || {
        !delegate.view_events.lock().unwrap().is_empty()
    })
    .await;
    assert!(got, "delegate never received the agent_login view_event");

    let events = delegate.view_events.lock().unwrap();
    assert_eq!(events.len(), 1);
    let (sid, kind, payload) = &events[0];
    assert_eq!(sid, "s-oauth");
    assert_eq!(kind, "agent_login_url");
    assert_eq!(payload.get("provider").map(String::as_str), Some("openai"));
    assert_eq!(
        payload.get("url").map(String::as_str),
        Some("https://auth.openai.com/authorize?x=1")
    );
    // Numbers are stringified (no quotes) so the platform can parse them.
    assert_eq!(
        payload.get("loopback_port").map(String::as_str),
        Some("8123")
    );
    assert_eq!(
        payload.get("session_token").map(String::as_str),
        Some("tok-abc")
    );

    server.abort();
}

#[tokio::test]
async fn connection_reports_healthy_on_open() {
    let (endpoint, server) = spawn_test_server(|mut ws| async move {
        let _ = ws.next().await; // keep open
    })
    .await;

    let delegate = Arc::new(RecordingDelegate::default());
    let _handle = transport::connect(
        endpoint,
        "s-health".into(),
        "claude".into(),
        "test-token".into(),
        transport::SpawnOverride::default(),
        delegate.clone(),
    )
    .await
    .expect("connect");

    // The transport emits `Connected` synchronously inside connect()
    // (before returning), so by the time we get here at least one
    // health event must be recorded.
    let healths = delegate.healths.lock().unwrap();
    assert!(
        healths
            .iter()
            .any(|(_, h)| matches!(h, ConnectionHealth::Connected)),
        "no Connected event recorded: {:?}",
        healths
    );

    server.abort();
}
