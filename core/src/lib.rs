//! conduit-core: the shared Rust client for the conduit mobile apps.
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
    BrowserViewState, ChatEvent, ChatViewState, ConversationItem, PlanStep, PreviewInfo,
    ProjectSession, ProjectSessionState, SessionStatus, TerminalViewState, ViewEventFile,
};

uniffi::include_scaffolding!("conduit_core");

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
        .thread_name("conduit-core")
        .build()
        .expect("failed to build conduit-core tokio runtime")
});

#[derive(Debug, Error)]
pub enum ConduitError {
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

impl From<serde_json::Error> for ConduitError {
    fn from(error: serde_json::Error) -> Self {
        Self::Json(error.to_string())
    }
}

pub trait ConduitDelegate: Send + Sync {
    fn on_pty_data(&self, session_id: String, data: Vec<u8>);
    fn on_chat_event(&self, session_id: String, event: ChatEvent);
    fn on_preview_ready(&self, session_id: String, preview: PreviewInfo);
    fn on_status(&self, status: SessionStatus);
    fn on_snapshot(&self, session_id: String, gunzipped: Vec<u8>);
    fn on_exit(&self, session_id: String, code: i32);
    fn on_disconnected(&self, reason: String);
    fn on_connection_health(&self, session_id: String, health: ConnectionHealth);
    /// The broker confirmed receipt of a chat message the app sent with the
    /// given `client_msg_id`. Only then may the app treat the message as
    /// durably delivered (remove it from its resend outbox, flip the bubble
    /// from in-flight to solid). Emitted from the `"chat_ack"` inbound frame.
    fn on_chat_delivered(&self, session_id: String, client_msg_id: String);
    /// A typed `view_event` the core doesn't model as its own delegate
    /// call — currently the broker's `view:"status"` sub-events
    /// (`agent_login_url` / `_complete` / `_failed`, see
    /// docs/PLAN-AGENT-OAUTH.md "Approach v2"). `kind` is the sub-event
    /// key; `payload` is its inner object flattened to string values
    /// (numbers/bools stringified). The platform routes by `kind`.
    fn on_view_event(&self, session_id: String, kind: String, payload: HashMap<String, String>);
}

pub use ssh::{
    SshAuth, SshBootstrapResult, SshCredentials, SshError, SshTunnel, SshTunnelBootstrap,
};

/// Platform callback for SSH host-key TOFU. The platform layer
/// implements this and pops up an "accept/reject this server
/// fingerprint" sheet; the boolean it returns gates the rest of the
/// handshake.
pub trait SshHostKeyDelegate: Send + Sync {
    fn accept_host_key(&self, fingerprint: String) -> bool;
}

/// Per-phase progress callback for the SSH bootstrap flow. Emitted as
/// each stage is entered so the app can surface granular status rather
/// than a frozen "Starting server…". The `phase` tag matches the UDL
/// comments; `detail` carries phase-specific context (host:port, local
/// port, or a raw stderr line from the bootstrap script).
pub trait SshProgressDelegate: Send + Sync {
    fn on_progress(&self, phase: String, detail: Option<String>);
}

/// A no-op [`SshProgressDelegate`] used when the caller doesn't care
/// about progress (cli-driver example, tests, legacy codepath).
struct NoopProgress;
impl SshProgressDelegate for NoopProgress {
    fn on_progress(&self, _phase: String, _detail: Option<String>) {}
}

/// UniFFI-visible entry point for the SSH bootstrap. Drives
/// [`ssh::ssh_bootstrap`] on the core tokio runtime via `run_on_core`
/// so the caller doesn't need to be inside a tokio context.
#[allow(clippy::too_many_arguments)]
pub async fn ssh_bootstrap(
    credentials: SshCredentials,
    pre_allocated_token: String,
    anthropic_api_key: String,
    openai_api_key: String,
    image_ref: Option<String>,
    app_version: Option<String>,
    host_key_delegate: Box<dyn SshHostKeyDelegate>,
    progress_delegate: Option<Box<dyn SshProgressDelegate>>,
) -> Result<SshBootstrapResult, SshError> {
    let hk_delegate: Arc<dyn SshHostKeyDelegate> = Arc::from(host_key_delegate);
    let cb: ssh::HostKeyCallback = Arc::new(move |fp: String| {
        let d = Arc::clone(&hk_delegate);
        Box::pin(async move { d.accept_host_key(fp) })
    });
    let progress: Arc<dyn SshProgressDelegate> = progress_delegate
        .map(|d| Arc::from(d) as Arc<dyn SshProgressDelegate>)
        .unwrap_or_else(|| Arc::new(NoopProgress));
    run_on_core(ssh::ssh_bootstrap(
        credentials,
        pre_allocated_token,
        anthropic_api_key,
        openai_api_key,
        image_ref,
        app_version,
        cb,
        progress,
    ))
    .await
}

/// UniFFI entry point for the **tunneled** SSH bootstrap. Same flow as
/// [`ssh_bootstrap`] but returns the owned [`SshTunnel`] so the app controls
/// the forward's lifecycle (hold the handle, observe `is_alive()`, `stop()` on
/// logout). This is the path the apps should adopt — see
/// `docs/PLAN-SSH-TUNNEL.md`.
#[allow(clippy::too_many_arguments)]
pub async fn ssh_bootstrap_tunneled(
    credentials: SshCredentials,
    pre_allocated_token: String,
    anthropic_api_key: String,
    openai_api_key: String,
    image_ref: Option<String>,
    app_version: Option<String>,
    host_key_delegate: Box<dyn SshHostKeyDelegate>,
    progress_delegate: Option<Box<dyn SshProgressDelegate>>,
) -> Result<SshTunnelBootstrap, SshError> {
    let hk_delegate: Arc<dyn SshHostKeyDelegate> = Arc::from(host_key_delegate);
    let cb: ssh::HostKeyCallback = Arc::new(move |fp: String| {
        let d = Arc::clone(&hk_delegate);
        Box::pin(async move { d.accept_host_key(fp) })
    });
    let progress: Arc<dyn SshProgressDelegate> = progress_delegate
        .map(|d| Arc::from(d) as Arc<dyn SshProgressDelegate>)
        .unwrap_or_else(|| Arc::new(NoopProgress));
    run_on_core(ssh::ssh_bootstrap_tunneled(
        credentials,
        pre_allocated_token,
        anthropic_api_key,
        openai_api_key,
        image_ref,
        app_version,
        cb,
        progress,
    ))
    .await
}

pub struct ConduitClient {
    inner: Arc<Inner>,
}

struct Inner {
    endpoint: String,
    token: String,
    handles: Mutex<HashMap<String, transport::SessionHandle>>,
    sessions: Arc<Mutex<HashMap<String, ProjectSessionState>>>,
    delegate: Mutex<Option<Arc<dyn ConduitDelegate>>>,
}

impl ConduitClient {
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

    pub async fn connect(&self, delegate: Box<dyn ConduitDelegate>) -> Result<(), ConduitError> {
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

    /// Open a brand-new session. `reasoning_effort` / `model` are optional
    /// per-session overrides for the fork-onto-a-different-model path: when
    /// present they ride to the broker as `reasoning_effort=` / `model=`
    /// query params on the WS connect, and the broker applies them to the
    /// spawned agent's CLI flags. Empty / None = the adapter's defaults
    /// unchanged (the normal create path).
    /// `device_id` is the stable per-install UUID of the calling device; it
    /// rides to the broker as `device_id=` so the broker records this device
    /// as the session owner for targeted push routing.
    #[allow(clippy::too_many_arguments)]
    pub async fn create_session(
        &self,
        assistant: String,
        branch: Option<String>,
        reasoning_effort: Option<String>,
        model: Option<String>,
        cwd: Option<String>,
        permission_mode: Option<String>,
        fast_mode: Option<bool>,
        device_id: Option<String>,
    ) -> Result<String, ConduitError> {
        let inner = Arc::clone(&self.inner);
        run_on_core(async move {
            let session_id = Uuid::new_v4().to_string();
            inner
                .open_session(
                    session_id.clone(),
                    assistant,
                    branch,
                    reasoning_effort,
                    model,
                    cwd,
                    permission_mode,
                    fast_mode,
                    device_id,
                )
                .await?;
            Ok(session_id)
        })
        .await
    }

    pub async fn join_session(
        &self,
        session_id: String,
        assistant: Option<String>,
    ) -> Result<(), ConduitError> {
        let inner = Arc::clone(&self.inner);
        run_on_core(async move {
            inner
                .open_session(
                    session_id,
                    assistant.unwrap_or_else(|| "claude".to_string()),
                    None,
                    None,
                    None,
                    None,
                    None,
                    None,
                    None, // device_id: join does not target a specific device
                )
                .await
        })
        .await
    }

    pub async fn send_input(&self, session_id: String, data: Vec<u8>) -> Result<(), ConduitError> {
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
    ) -> Result<(), ConduitError> {
        let handle = self.inner.lookup_handle(&session_id)?;
        run_on_core(async move {
            handle
                .send_file(&session_id, &filename, &mime, &payload)
                .await
        })
        .await
    }

    pub async fn send_chat(
        &self,
        session_id: String,
        msg: String,
        client_msg_id: String,
    ) -> Result<(), ConduitError> {
        let handle = self.inner.lookup_handle(&session_id)?;
        run_on_core(async move {
            handle
                .send_json(&serde_json::json!({
                    "type": "chat",
                    "from": "mobile",
                    "msg": msg,
                    "client_msg_id": client_msg_id,
                }))
                .await
        })
        .await
    }

    /// Stop the agent's current turn (the composer Stop button) without ending
    /// the session. The broker interrupts the running turn backend-specifically
    /// (claude stream-json interrupt control_request / codex turn-interrupt /
    /// codex-exec kill); a no-op there when nothing is running. Fire-and-forget
    /// on the wire — the turn winding down arrives via the normal chat/status
    /// stream (e.g. an interrupted turn ends and the typing indicator clears).
    pub async fn stop_turn(&self, session_id: String) -> Result<(), ConduitError> {
        let handle = self.inner.lookup_handle(&session_id)?;
        run_on_core(async move {
            handle
                .send_json(&serde_json::json!({
                    "type": "stop",
                    "session": session_id,
                }))
                .await
        })
        .await
    }

    /// On-demand /usage: ask the broker to re-fetch the account-level Claude
    /// subscription usage (5-hour + weekly windows) and re-broadcast it on the
    /// status frame. Backs the "refresh" button in the Session Info usage card.
    /// Fire-and-forget on the wire — the fresh numbers arrive via `on_status`.
    pub async fn refresh_account_usage(&self, session_id: String) -> Result<(), ConduitError> {
        let handle = self.inner.lookup_handle(&session_id)?;
        run_on_core(async move {
            handle
                .send_json(&serde_json::json!({
                    "type": "account_usage",
                    "session": session_id,
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
    ) -> Result<(), ConduitError> {
        let handle = self.inner.lookup_handle(&session_id)?;
        run_on_core(async move { handle.resize(rows, cols).await }).await
    }

    pub async fn switch_agent(
        &self,
        session_id: String,
        assistant: String,
    ) -> Result<(), ConduitError> {
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
    ) -> Result<(), ConduitError> {
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
    pub async fn start_agent_login(&self, provider: String) -> Result<(), ConduitError> {
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
    ) -> Result<(), ConduitError> {
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
    pub async fn cancel_agent_login(&self, session_token: String) -> Result<(), ConduitError> {
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

    pub async fn exit_session(&self, session_id: String) -> Result<(), ConduitError> {
        let inner = Arc::clone(&self.inner);
        run_on_core(async move {
            let handle = inner
                .handles
                .lock()
                .remove(&session_id)
                .ok_or_else(|| ConduitError::UnknownSession(session_id.clone()))?;
            let _ = handle
                .send_json(&serde_json::json!({ "type": "exit" }))
                .await;
            handle.close();
            inner.sessions.lock().remove(&session_id);
            Ok(())
        })
        .await
    }

    pub fn get_session(&self, session_id: String) -> Result<ProjectSession, ConduitError> {
        self.inner
            .sessions
            .lock()
            .get(&session_id)
            .map(|state| state.session.clone())
            .ok_or(ConduitError::UnknownSession(session_id))
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
    ) -> Result<Vec<ConversationItem>, ConduitError> {
        self.inner
            .sessions
            .lock()
            .get(&session_id)
            .map(|state| state.chat.conversation.clone())
            .ok_or(ConduitError::UnknownSession(session_id))
    }
}

impl Inner {
    #[allow(clippy::too_many_arguments)]
    async fn open_session(
        self: Arc<Self>,
        session_id: String,
        assistant: String,
        branch: Option<String>,
        reasoning_effort: Option<String>,
        model: Option<String>,
        cwd: Option<String>,
        permission_mode: Option<String>,
        fast_mode: Option<bool>,
        device_id: Option<String>,
    ) -> Result<(), ConduitError> {
        let delegate = self
            .delegate
            .lock()
            .clone()
            .ok_or(ConduitError::NotConnected)?;
        if self.handles.lock().contains_key(&session_id) {
            return Ok(());
        }

        // Normalize empty strings to None so a blank override never leaks
        // into the WS query string as `reasoning_effort=` / `cwd=`.
        let reasoning_effort = reasoning_effort.filter(|s| !s.trim().is_empty());
        let model = model.filter(|s| !s.trim().is_empty());
        let cwd = cwd.filter(|s| !s.trim().is_empty());
        let permission_mode = permission_mode.filter(|s| !s.trim().is_empty());
        let device_id = device_id.filter(|s| !s.trim().is_empty());

        self.sessions.lock().insert(
            session_id.clone(),
            ProjectSessionState::new(ProjectSession {
                id: session_id.clone(),
                name: branch.clone().unwrap_or_else(|| session_id.clone()),
                assistant: assistant.clone(),
                branch,
                preview: None,
                // Seed the chosen effort so the agent pill reflects the
                // fork's effort immediately; the broker's status frame
                // confirms / corrects it once the agent spawns.
                reasoning_effort: reasoning_effort.clone(),
                // Seed the chosen cwd so the session row shows the project
                // folder immediately; the broker's status frame confirms it.
                cwd: cwd.clone(),
                started_at: None,
                last_activity_at: None,
                display_name: None,
                total_input_tokens: None,
                total_output_tokens: None,
                total_cached_tokens: None,
                total_cost_usd: None,
                context_used_tokens: None,
                context_window_tokens: None,
                // Outcome stats arrive via the broker's status frame.
                ..Default::default()
            }),
        );

        let handle = transport::connect(
            self.endpoint.clone(),
            session_id.clone(),
            assistant.clone(),
            self.token.clone(),
            transport::SpawnOverride {
                reasoning_effort,
                model,
                cwd,
                permission_mode,
                fast_mode,
                device_id,
            },
            Arc::new(ClientDelegate {
                sessions: Arc::clone(&self.sessions),
                delegate,
            }),
        )
        .await?;
        self.handles.lock().insert(session_id, handle);
        Ok(())
    }

    fn lookup_handle(&self, session_id: &str) -> Result<transport::SessionHandle, ConduitError> {
        self.handles
            .lock()
            .get(session_id)
            .cloned()
            .ok_or_else(|| ConduitError::UnknownSession(session_id.to_string()))
    }

    /// Pick any active session handle. Used for connection-scoped
    /// control frames whose semantics aren't tied to a particular
    /// session — today just `set_agent_credentials`, which the broker
    /// keys by bearer-token identity (PLAN-AGENT-OAUTH §D.1).
    fn any_handle(&self) -> Result<transport::SessionHandle, ConduitError> {
        self.handles
            .lock()
            .values()
            .next()
            .cloned()
            .ok_or(ConduitError::NotConnected)
    }
}

/// Run `fut` on the conduit-core tokio runtime and await its result
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
    rx.await.expect("conduit-core runtime task cancelled")
}

struct ClientDelegate {
    sessions: Arc<Mutex<HashMap<String, ProjectSessionState>>>,
    delegate: Arc<dyn ConduitDelegate>,
}

impl ConduitDelegate for ClientDelegate {
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

    fn on_chat_delivered(&self, session_id: String, client_msg_id: String) {
        self.delegate.on_chat_delivered(session_id, client_msg_id);
    }

    fn on_view_event(&self, session_id: String, kind: String, payload: HashMap<String, String>) {
        self.delegate.on_view_event(session_id, kind, payload);
    }
}
