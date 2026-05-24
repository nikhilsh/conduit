//! Minimal CLI driver that exercises swe-kitty-core against a running
//! harness. Used for manual integration testing during task 002.
//!
//! Usage:
//!     cargo run --example cli-driver -- ws://localhost:1977 <bearer-token> [assistant]
//!
//! Behaviour: creates a real harness session through the Rust core,
//! forwards stdin into the PTY, prints PTY and snapshot output to
//! stdout, and exits the session on stdin EOF.

use std::io::{self, Read, Write};

use swe_kitty_core::{
    ChatEvent, ConnectionHealth, PreviewInfo, SessionStatus, SweKittyClient, SweKittyDelegate,
};
use tokio::sync::mpsc;

struct StdoutDelegate;

impl SweKittyDelegate for StdoutDelegate {
    fn on_pty_data(&self, _session_id: String, data: Vec<u8>) {
        let _ = io::stdout().write_all(&data);
        let _ = io::stdout().flush();
    }
    fn on_chat_event(&self, _session_id: String, event: ChatEvent) {
        eprintln!("[chat:{}] {}", event.role, event.content);
    }
    fn on_preview_ready(&self, _session_id: String, p: PreviewInfo) {
        eprintln!("[preview] port={} url={}", p.port, p.url);
    }
    fn on_status(&self, status: SessionStatus) {
        eprintln!(
            "[status] phase={} health={} assistant={}",
            status.phase, status.health, status.assistant
        );
    }
    fn on_snapshot(&self, _session_id: String, gunzipped: Vec<u8>) {
        eprintln!("[snapshot] {} bytes", gunzipped.len());
        let _ = io::stdout().write_all(&gunzipped);
    }
    fn on_exit(&self, _session_id: String, code: i32) {
        eprintln!("[exit] code={code}");
    }
    fn on_disconnected(&self, reason: String) {
        eprintln!("[disconnected] {reason}");
    }
    fn on_connection_health(&self, session_id: String, health: ConnectionHealth) {
        eprintln!("[health:{session_id}] {health:?}");
    }
    fn on_view_event(
        &self,
        session_id: String,
        kind: String,
        payload: std::collections::HashMap<String, String>,
    ) {
        eprintln!("[view_event:{session_id}] {kind} {payload:?}");
    }
}

#[tokio::main]
async fn main() -> Result<(), Box<dyn std::error::Error>> {
    let args: Vec<String> = std::env::args().collect();
    if args.len() < 3 {
        eprintln!("usage: cli-driver <endpoint> <bearer-token> [assistant]");
        std::process::exit(2);
    }
    let endpoint = args[1].clone();
    let token = args[2].clone();
    let assistant = args.get(3).cloned().unwrap_or_else(|| "claude".to_string());

    let client = SweKittyClient::new(endpoint, token);
    client.connect(Box::new(StdoutDelegate)).await?;

    let session_id = client.create_session(assistant.clone(), None).await?;
    eprintln!("[create_session] {session_id} assistant={assistant}");

    client.resize(session_id.clone(), 40, 120).await?;
    client
        .send_input(
            session_id.clone(),
            b"printf 'cli-driver connected\\r\\n'\\n".to_vec(),
        )
        .await?;

    let (tx, mut rx) = mpsc::unbounded_channel::<Vec<u8>>();
    let stdin_thread = std::thread::spawn(move || {
        let mut stdin = io::stdin();
        let mut buf = [0_u8; 4096];
        loop {
            match stdin.read(&mut buf) {
                Ok(0) => break,
                Ok(n) => {
                    if tx.send(buf[..n].to_vec()).is_err() {
                        break;
                    }
                }
                Err(err) if err.kind() == io::ErrorKind::Interrupted => continue,
                Err(_) => break,
            }
        }
    });

    while let Some(chunk) = rx.recv().await {
        client.send_input(session_id.clone(), chunk).await?;
    }

    let _ = stdin_thread.join();

    client.exit_session(session_id).await?;
    client.disconnect();
    Ok(())
}
