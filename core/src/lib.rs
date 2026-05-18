//! swe-kitty-core: the shared Rust client for the swe-kitty mobile apps.
#![allow(clippy::empty_line_after_doc_comments)]

pub mod transport;
pub mod views;

use std::collections::HashMap;
use std::sync::Arc;

use once_cell::sync::Lazy;
use parking_lot::Mutex;
use thiserror::Error;
use tokio::runtime::Runtime;
use uuid::Uuid;

pub use views::{
    ChatEvent, PreviewInfo, ProjectSession, ProjectSessionState, SessionStatus, ViewEventFile,
};

uniffi::include_scaffolding!("swe_kitty_core");

static CORE_RUNTIME: Lazy<Runtime> = Lazy::new(|| {
    tokio::runtime::Builder::new_multi_thread()
        .enable_all()
        .thread_name("swe-kitty-core")
        .build()
        .expect("failed to build swe-kitty-core tokio runtime")
});

#[derive(Debug, Error)]
pub enum SweKittyError {
    #[error("connection: {0}")]
    Connection(String),
    #[error("auth")]
    Auth,
    #[error("protocol: {0}")]
    Protocol(String),
    #[error("json: {0}")]
    Json(String),
    #[error("not connected")]
    NotConnected,
    #[error("unknown session: {0}")]
    UnknownSession(String),
}

impl From<serde_json::Error> for SweKittyError {
    fn from(error: serde_json::Error) -> Self {
        Self::Json(error.to_string())
    }
}

pub trait SweKittyDelegate: Send + Sync {
    fn on_pty_data(&self, session_id: String, data: Vec<u8>);
    fn on_chat_event(&self, session_id: String, event: ChatEvent);
    fn on_preview_ready(&self, session_id: String, preview: PreviewInfo);
    fn on_status(&self, status: SessionStatus);
    fn on_snapshot(&self, session_id: String, gunzipped: Vec<u8>);
    fn on_exit(&self, session_id: String, code: i32);
    fn on_disconnected(&self, reason: String);
}

pub struct SweKittyClient {
    endpoint: String,
    token: String,
    handles: Mutex<HashMap<String, transport::SessionHandle>>,
    sessions: Arc<Mutex<HashMap<String, ProjectSessionState>>>,
    delegate: Mutex<Option<Arc<dyn SweKittyDelegate>>>,
}

impl SweKittyClient {
    pub fn new(endpoint: String, bearer_token: String) -> Self {
        Self {
            endpoint,
            token: bearer_token,
            handles: Mutex::new(HashMap::new()),
            sessions: Arc::new(Mutex::new(HashMap::new())),
            delegate: Mutex::new(None),
        }
    }

    pub async fn connect(&self, delegate: Box<dyn SweKittyDelegate>) -> Result<(), SweKittyError> {
        *self.delegate.lock() = Some(Arc::from(delegate));
        Ok(())
    }

    pub fn disconnect(&self) {
        let handles: Vec<_> = self
            .handles
            .lock()
            .drain()
            .map(|(_, handle)| handle)
            .collect();
        for handle in handles {
            handle.close();
        }
        *self.delegate.lock() = None;
    }

    pub async fn create_session(
        &self,
        assistant: String,
        branch: Option<String>,
    ) -> Result<String, SweKittyError> {
        let session_id = Uuid::new_v4().to_string();
        self.open_session(session_id.clone(), assistant, branch)
            .await?;
        Ok(session_id)
    }

    pub async fn join_session(
        &self,
        session_id: String,
        assistant: Option<String>,
    ) -> Result<(), SweKittyError> {
        self.open_session(
            session_id,
            assistant.unwrap_or_else(|| "claude".to_string()),
            None,
        )
        .await
    }

    pub async fn send_input(&self, session_id: String, data: Vec<u8>) -> Result<(), SweKittyError> {
        self.lookup_handle(&session_id)?.send_input(data).await
    }

    pub async fn send_chat(&self, session_id: String, msg: String) -> Result<(), SweKittyError> {
        self.lookup_handle(&session_id)?
            .send_json(&serde_json::json!({
                "type": "chat",
                "from": "mobile",
                "msg": msg,
            }))
            .await
    }

    pub async fn resize(
        &self,
        session_id: String,
        rows: u16,
        cols: u16,
    ) -> Result<(), SweKittyError> {
        self.lookup_handle(&session_id)?.resize(rows, cols).await
    }

    pub async fn switch_agent(
        &self,
        session_id: String,
        assistant: String,
    ) -> Result<(), SweKittyError> {
        self.lookup_handle(&session_id)?
            .send_json(&serde_json::json!({
                "type": "switch_agent",
                "assistant": assistant,
            }))
            .await
    }

    pub async fn exit_session(&self, session_id: String) -> Result<(), SweKittyError> {
        let handle = self
            .handles
            .lock()
            .remove(&session_id)
            .ok_or_else(|| SweKittyError::UnknownSession(session_id.clone()))?;
        let _ = handle
            .send_json(&serde_json::json!({ "type": "exit" }))
            .await;
        handle.close();
        self.sessions.lock().remove(&session_id);
        Ok(())
    }

    pub fn get_session(&self, session_id: String) -> Result<ProjectSession, SweKittyError> {
        self.sessions
            .lock()
            .get(&session_id)
            .map(|state| state.session.clone())
            .ok_or(SweKittyError::UnknownSession(session_id))
    }

    pub fn list_sessions(&self) -> Vec<ProjectSession> {
        self.sessions
            .lock()
            .values()
            .map(|state| state.session.clone())
            .collect()
    }

    async fn open_session(
        &self,
        session_id: String,
        assistant: String,
        branch: Option<String>,
    ) -> Result<(), SweKittyError> {
        let delegate = self
            .delegate
            .lock()
            .clone()
            .ok_or(SweKittyError::NotConnected)?;
        if self.handles.lock().contains_key(&session_id) {
            return Ok(());
        }

        self.sessions.lock().insert(
            session_id.clone(),
            ProjectSessionState::new(ProjectSession {
                id: session_id.clone(),
                name: branch.clone().unwrap_or_else(|| session_id.clone()),
                assistant: assistant.clone(),
                branch,
                preview: None,
            }),
        );

        let handle = transport::connect(
            CORE_RUNTIME.handle(),
            self.endpoint.clone(),
            session_id.clone(),
            assistant.clone(),
            self.token.clone(),
            Arc::new(ClientDelegate {
                sessions: Arc::clone(&self.sessions),
                delegate,
            }),
        )
        .await?;
        self.handles.lock().insert(session_id, handle);
        Ok(())
    }

    fn lookup_handle(&self, session_id: &str) -> Result<transport::SessionHandle, SweKittyError> {
        self.handles
            .lock()
            .get(session_id)
            .cloned()
            .ok_or_else(|| SweKittyError::UnknownSession(session_id.to_string()))
    }
}

struct ClientDelegate {
    sessions: Arc<Mutex<HashMap<String, ProjectSessionState>>>,
    delegate: Arc<dyn SweKittyDelegate>,
}

impl SweKittyDelegate for ClientDelegate {
    fn on_pty_data(&self, session_id: String, data: Vec<u8>) {
        if let Some(state) = self.sessions.lock().get_mut(&session_id) {
            state.terminal.scrollback.extend_from_slice(&data);
        }
        self.delegate.on_pty_data(session_id, data);
    }

    fn on_chat_event(&self, session_id: String, event: ChatEvent) {
        if let Some(state) = self.sessions.lock().get_mut(&session_id) {
            state.push_chat_event(event.clone());
        }
        self.delegate.on_chat_event(session_id, event);
    }

    fn on_preview_ready(&self, session_id: String, preview: PreviewInfo) {
        if let Some(state) = self.sessions.lock().get_mut(&session_id) {
            state.set_preview(preview.clone());
        }
        self.delegate.on_preview_ready(session_id, preview);
    }

    fn on_status(&self, status: SessionStatus) {
        if let Some(state) = self.sessions.lock().get_mut(&status.session) {
            state.apply_status(status.clone());
        }
        self.delegate.on_status(status);
    }

    fn on_snapshot(&self, session_id: String, gunzipped: Vec<u8>) {
        if let Some(state) = self.sessions.lock().get_mut(&session_id) {
            state.apply_snapshot(gunzipped.clone());
        }
        self.delegate.on_snapshot(session_id, gunzipped);
    }

    fn on_exit(&self, session_id: String, code: i32) {
        if let Some(state) = self.sessions.lock().get_mut(&session_id) {
            state.mark_exited(code);
        }
        self.delegate.on_exit(session_id, code);
    }

    fn on_disconnected(&self, reason: String) {
        self.delegate.on_disconnected(reason);
    }
}
