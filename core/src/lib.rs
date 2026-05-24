//! swe-kitty-core: the shared Rust client for the swe-kitty mobile apps.
#![allow(clippy::empty_line_after_doc_comments)]

pub mod conversation;
pub mod discovery;
pub mod saved;
pub mod ssh;
pub mod store;
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

pub use store::{SessionLifecycleCore, SessionStoreCore};
pub use transport::ConnectionHealth;
pub use views::{
    BrowserViewState, ChatEvent, ChatViewState, ConversationItem, PreviewInfo, ProjectSession,
    ProjectSessionState, SessionStatus, TerminalViewState, ViewEventFile,
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
    fn on_connection_health(&self, session_id: String, health: ConnectionHealth);
    /// A typed `view_event` the core doesn't model as its own delegate
    /// call — currently the broker's `view:"status"` sub-events
    /// (`agent_login_url` / `_complete` / `_failed`, see
    /// docs/PLAN-AGENT-OAUTH.md "Approach v2"). `kind` is the sub-event
    /// key; `payload` is its inner object flattened to string values
    /// (numbers/bools stringified). The platform routes by `kind`.
    fn on_view_event(&self, session_id: String, kind: String, payload: HashMap<String, String>);
}

pub use ssh::{SshAuth, SshBootstrapResult, SshCredentials, SshError};

/// Platform callback for SSH host-key TOFU. The platform layer
/// implements this and pops up an "accept/reject this server
/// fingerprint" sheet; the boolean it returns gates the rest of the
/// handshake.
pub trait SshHostKeyDelegate: Send + Sync {
    fn accept_host_key(&self, fingerprint: String) -> bool;
}

/// UniFFI-visible entry point for the SSH bootstrap. Drives
/// [`ssh::ssh_bootstrap`] on the core tokio runtime via `run_on_core`
/// so the caller doesn't need to be inside a tokio context.
pub async fn ssh_bootstrap(
    credentials: SshCredentials,
    pre_allocated_token: String,
    anthropic_api_key: String,
    openai_api_key: String,
    image_ref: Option<String>,
    host_key_delegate: Box<dyn SshHostKeyDelegate>,
) -> Result<SshBootstrapResult, SshError> {
    let delegate: Arc<dyn SshHostKeyDelegate> = Arc::from(host_key_delegate);
    let cb: ssh::HostKeyCallback = Arc::new(move |fp: String| {
        let delegate = Arc::clone(&delegate);
        Box::pin(async move { delegate.accept_host_key(fp) })
    });
    run_on_core(ssh::ssh_bootstrap(
        credentials,
        pre_allocated_token,
        anthropic_api_key,
        openai_api_key,
        image_ref,
        cb,
    ))
    .await
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

    /// Called by the apps when the host OS signals that the network
    /// path probably changed — Wi-Fi↔LTE handoff, app foreground after
    /// a long suspend, VPN flap. Every per-session worker drops its
    /// current socket and re-enters the reconnect loop, so we don't
    /// sit on a half-open TCP waiting for the kernel to surface the
    /// failure.
    pub fn notify_network_change(&self) {
        let handles: Vec<_> = self.inner.handles.lock().values().cloned().collect();
        for handle in handles {
            handle.nudge();
        }
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

    /// Upload a file to the session's `<workspace>/uploads/<session>/<filename>`
    /// by encoding a 0x01 binary frame. See `transport::SessionHandle::send_file`
    /// for the wire layout. The broker sanitizes the filename server-side
    /// and emits a tool view_event when the file lands.
    pub async fn send_file(
        &self,
        session_id: String,
        filename: String,
        mime: String,
        payload: Vec<u8>,
    ) -> Result<(), SweKittyError> {
        let handle = self.inner.lookup_handle(&session_id)?;
        run_on_core(async move {
            handle
                .send_file(&session_id, &filename, &mime, &payload)
                .await
        })
        .await
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

    /// Ship a per-user agent OAuth credential to the broker over the
    /// existing authenticated WS (docs/PLAN-AGENT-OAUTH.md §D.1, Stage 2).
    ///
    /// The broker's `set_agent_credentials` handler keys the stored
    /// blob by the bearer token's identity, not per-session — but the
    /// WS itself is session-scoped (`/ws/<session_id>`), so this method
    /// picks any active session handle to carry the control frame. The
    /// broker then routes it through the identity-scoped credentials
    /// store regardless of which session WS delivered it.
    ///
    /// `credential_json` is the provider-native blob (verbatim
    /// `~/.codex/auth.json` for openai, `~/.claude/.credentials.json`
    /// for anthropic). We parse it here only to embed it inline in the
    /// outbound envelope (so the wire `credential` field is a JSON
    /// object, not a stringified blob).
    ///
    /// Returns `NotConnected` if no session is live yet — the caller
    /// (iOS / Android) is responsible for retrying once a session
    /// exists. The plan accepts this trade-off (PLAN §D.1: phone-driven
    /// refresh is "the user re-runs the OAuth flow → sends a new
    /// set_agent_credentials"), and the explicit "Sync to broker" UI
    /// surfaces failures so the user can retry after pairing.
    pub async fn set_agent_credentials(
        &self,
        provider: String,
        credential_json: String,
    ) -> Result<(), SweKittyError> {
        let handle = self.inner.any_handle()?;
        let credential: serde_json::Value = serde_json::from_str(&credential_json)?;
        run_on_core(async move {
            handle
                .send_json(&serde_json::json!({
                    "type": "set_agent_credentials",
                    "provider": provider,
                    "kind": "oauth",
                    "credential": credential,
                }))
                .await
        })
        .await
    }

    /// Begin a per-user agent OAuth login (docs/PLAN-AGENT-OAUTH.md
    /// "Approach v2"). The broker spawns the agent CLI's own `login`
    /// subcommand, parses the authorize URL + loopback port from its
    /// stdout, and ferries progress back over the WS as `agent_login_*`
    /// view-events the delegate surfaces (consumed iOS-side by
    /// `AgentLoginCoordinator`). Like `set_agent_credentials`, the flow
    /// is identity-scoped rather than session-scoped, so we carry the
    /// control frame over any live session WS. Returns `NotConnected`
    /// if no session is live yet.
    pub async fn start_agent_login(&self, provider: String) -> Result<(), SweKittyError> {
        let handle = self.inner.any_handle()?;
        run_on_core(async move {
            handle
                .send_json(&serde_json::json!({
                    "type": "start_agent_login",
                    "provider": provider,
                }))
                .await
        })
        .await
    }

    /// Hand the loopback redirect back to the broker so it can complete
    /// the agent CLI's OAuth exchange. `session_token` is the opaque
    /// handle the broker emitted in its `agent_login_started`
    /// view-event; `query_string` is the raw `code=…&state=…` the
    /// on-device loopback server captured from the redirect.
    pub async fn agent_login_callback(
        &self,
        session_token: String,
        query_string: String,
    ) -> Result<(), SweKittyError> {
        let handle = self.inner.any_handle()?;
        run_on_core(async move {
            handle
                .send_json(&serde_json::json!({
                    "type": "agent_login_callback",
                    "session_token": session_token,
                    "query_string": query_string,
                }))
                .await
        })
        .await
    }

    /// Abort an in-flight agent login (the user dismissed the sheet).
    /// The broker tears down the spawned `login` subprocess keyed by
    /// `session_token`. Idempotent broker-side, so a cancel for an
    /// already-finished flow is harmless.
    pub async fn cancel_agent_login(&self, session_token: String) -> Result<(), SweKittyError> {
        let handle = self.inner.any_handle()?;
        run_on_core(async move {
            handle
                .send_json(&serde_json::json!({
                    "type": "cancel_agent_login",
                    "session_token": session_token,
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

    pub fn list_conversation_items(
        &self,
        session_id: String,
    ) -> Result<Vec<ConversationItem>, SweKittyError> {
        self.inner
            .sessions
            .lock()
            .get(&session_id)
            .map(|state| state.chat.conversation.clone())
            .ok_or(SweKittyError::UnknownSession(session_id))
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
                reasoning_effort: None,
                cwd: None,
                started_at: None,
                last_activity_at: None,
                display_name: None,
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

    /// Pick any active session handle. Used for connection-scoped
    /// control frames whose semantics aren't tied to a particular
    /// session — today just `set_agent_credentials`, which the broker
    /// keys by bearer-token identity (PLAN-AGENT-OAUTH §D.1).
    fn any_handle(&self) -> Result<transport::SessionHandle, SweKittyError> {
        self.handles
            .lock()
            .values()
            .next()
            .cloned()
            .ok_or(SweKittyError::NotConnected)
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

    fn on_connection_health(&self, session_id: String, health: ConnectionHealth) {
        self.delegate.on_connection_health(session_id, health);
    }

    fn on_view_event(&self, session_id: String, kind: String, payload: HashMap<String, String>) {
        self.delegate.on_view_event(session_id, kind, payload);
    }
}
