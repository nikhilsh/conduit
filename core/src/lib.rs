//! swe-kitty-core: the shared Rust client for the swe-kitty mobile apps.
#![allow(clippy::empty_line_after_doc_comments)]

pub mod transport;
pub mod views;

use std::collections::HashMap;
use std::future::Future;
use std::sync::Arc;

use once_cell::sync::Lazy;
use parking_lot::Mutex;
use thiserror::Error;
use tokio::runtime::Runtime;
use tokio::sync::oneshot;
use uuid::Uuid;

pub use views::{
    ChatEvent, PreviewInfo, ProjectSession, ProjectSessionState, SessionStatus, ViewEventFile,
};

uniffi::include_scaffolding!("swe_kitty_core");

/// Our own multi-thread tokio runtime with full I/O + timer support.
///
/// UniFFI's async bridge polls our futures on a runtime it controls,
/// which historically did not have the I/O reactor enabled — touching
/// `tokio::net` or `tokio::time` from there panicked with
/// "no reactor running". We sidestep that by bouncing every async
/// method body onto this runtime via [`run_on_core`].
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
    inner: Arc<Inner>,
}

struct Inner {
    endpoint: String,
    token: String,
    handles: Mutex<HashMap<String, transport::SessionHandle>>,
    sessions: Arc<Mutex<HashMap<String, ProjectSessionState>>>,
    delegate: Mutex<Option<Arc<dyn SweKittyDelegate>>>,
}

impl SweKittyClient {
    pub fn new(endpoint: String, bearer_token: String) -> Self {
        Self {
            inner: Arc::new(Inner {
                endpoint,
                token: bearer_token,
                handles: Mutex::new(HashMap::new()),
                sessions: Arc::new(Mutex::new(HashMap::new())),
                delegate: Mutex::new(None),
            }),
        }
    }

    pub async fn connect(&self, delegate: Box<dyn SweKittyDelegate>) -> Result<(), SweKittyError> {
        // Pure store of the delegate — no network work yet. Real socket
        // setup happens on the first session.
        *self.inner.delegate.lock() = Some(Arc::from(delegate));
        Ok(())
    }

    pub fn disconnect(&self) {
        let handles: Vec<_> = self
            .inner
            .handles
            .lock()
            .drain()
            .map(|(_, handle)| handle)
            .collect();
        for handle in handles {
            handle.close();
        }
        *self.inner.delegate.lock() = None;
    }

    pub async fn create_session(
        &self,
        assistant: String,
        branch: Option<String>,
    ) -> Result<String, SweKittyError> {
        let inner = Arc::clone(&self.inner);
        run_on_core(async move {
            let session_id = Uuid::new_v4().to_string();
            inner
                .open_session(session_id.clone(), assistant, branch)
                .await?;
            Ok(session_id)
        })
        .await
    }

    pub async fn join_session(
        &self,
        session_id: String,
        assistant: Option<String>,
    ) -> Result<(), SweKittyError> {
        let inner = Arc::clone(&self.inner);
        run_on_core(async move {
            inner
                .open_session(
                    session_id,
                    assistant.unwrap_or_else(|| "claude".to_string()),
                    None,
                )
                .await
        })
        .await
    }

    pub async fn send_input(&self, session_id: String, data: Vec<u8>) -> Result<(), SweKittyError> {
        let handle = self.inner.lookup_handle(&session_id)?;
        run_on_core(async move { handle.send_input(data).await }).await
    }

    pub async fn send_chat(&self, session_id: String, msg: String) -> Result<(), SweKittyError> {
        let handle = self.inner.lookup_handle(&session_id)?;
        run_on_core(async move {
            handle
                .send_json(&serde_json::json!({
                    "type": "chat",
                    "from": "mobile",
                    "msg": msg,
                }))
                .await
        })
        .await
    }

    pub async fn resize(
        &self,
        session_id: String,
        rows: u16,
        cols: u16,
    ) -> Result<(), SweKittyError> {
        let handle = self.inner.lookup_handle(&session_id)?;
        run_on_core(async move { handle.resize(rows, cols).await }).await
    }

    pub async fn switch_agent(
        &self,
        session_id: String,
        assistant: String,
    ) -> Result<(), SweKittyError> {
        let handle = self.inner.lookup_handle(&session_id)?;
        run_on_core(async move {
            handle
                .send_json(&serde_json::json!({
                    "type": "switch_agent",
                    "assistant": assistant,
                }))
                .await
        })
        .await
    }

    pub async fn exit_session(&self, session_id: String) -> Result<(), SweKittyError> {
        let inner = Arc::clone(&self.inner);
        run_on_core(async move {
            let handle = inner
                .handles
                .lock()
                .remove(&session_id)
                .ok_or_else(|| SweKittyError::UnknownSession(session_id.clone()))?;
            let _ = handle
                .send_json(&serde_json::json!({ "type": "exit" }))
                .await;
            handle.close();
            inner.sessions.lock().remove(&session_id);
            Ok(())
        })
        .await
    }

    pub fn get_session(&self, session_id: String) -> Result<ProjectSession, SweKittyError> {
        self.inner
            .sessions
            .lock()
            .get(&session_id)
            .map(|state| state.session.clone())
            .ok_or(SweKittyError::UnknownSession(session_id))
    }

    pub fn list_sessions(&self) -> Vec<ProjectSession> {
        self.inner
            .sessions
            .lock()
            .values()
            .map(|state| state.session.clone())
            .collect()
    }
}

impl Inner {
    async fn open_session(
        self: Arc<Self>,
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

/// Run `fut` on the swe-kitty-core tokio runtime and await its result
/// from any caller, including ones that don't have a tokio context.
///
/// The returned future itself only touches a oneshot channel and the
/// runtime handle, both of which are runtime-agnostic.
async fn run_on_core<F, T>(fut: F) -> T
where
    F: Future<Output = T> + Send + 'static,
    T: Send + 'static,
{
    let (tx, rx) = oneshot::channel();
    CORE_RUNTIME.spawn(async move {
        let _ = tx.send(fut.await);
    });
    rx.await.expect("swe-kitty-core runtime task cancelled")
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
