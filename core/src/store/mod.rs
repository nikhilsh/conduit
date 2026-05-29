//! Shared session-store reducer.
//!
//! Today the iOS `SessionStore.swift` and Android `SessionStore.kt`
//! independently implement the same shape: ingest a `ChatEvent` /
//! `SessionStatus` / `exit` callback from the Rust transport, fold it into
//! some per-session maps, derive a few cross-session aggregates. That's
//! reducer-shaped logic living on both platforms — exactly what
//! `docs/PLAN-2026-05-19.md` §3.1 flags as the bleed we need to stop.
//!
//! `SessionStoreCore` is the clean-room Rust port of that surface. It owns a
//! map of `session_id -> ProjectSessionState` and exposes one method per
//! existing Swift/Kotlin entry point:
//!
//! - [`SessionStoreCore::apply_chat`]      — `onChatEvent` / `ingestChat`
//! - [`SessionStoreCore::apply_status`]    — `onStatus`    / `ingestStatus`
//! - [`SessionStoreCore::apply_exit`]      — `onExit`      / `ingestExit`
//! - [`SessionStoreCore::apply_preview`]   — `onPreviewReady` / `ingestPreview`
//! - [`SessionStoreCore::apply_snapshot`]  — `onSnapshot`     / `ingestSnapshot`
//! - [`SessionStoreCore::apply_pty_data`]  — `onPtyData`      / `ingestPtyData`
//! - [`SessionStoreCore::apply_lifecycle`] — `sessionLifecycle[id] = …`
//!
//! All reducer methods are pure with respect to the store: they take
//! `&self` (the inner state is behind a `Mutex`), mutate the per-session
//! `ProjectSessionState`, and return the resulting snapshot to the caller.
//! Replaying the same event twice is a no-op for the conversation log and
//! lifecycle (idempotency tests in `core/tests/store_reducer.rs`).
//!
//! ### Why a separate type from `SweKittyClient`
//!
//! `SweKittyClient` ([`crate::SweKittyClient`]) owns the network + delegate
//! plumbing and *internally* updates its own `HashMap<String,
//! ProjectSessionState>` via [`ClientDelegate`](crate::ClientDelegate). That
//! map is a private detail of the client today.
//!
//! `SessionStoreCore` is the *public* reducer surface. Once the apps migrate to
//! call into it, the client's private map gets replaced by a reference to
//! the same store, removing the dual-write entirely. This first PR ships
//! the store as a parallel, opt-in path: existing call sites are unchanged.

use std::collections::HashMap;
use std::sync::Arc;

use parking_lot::Mutex;

use crate::views::{
    ChatEvent, ConversationItem, PreviewInfo, ProjectSession, ProjectSessionState, SessionStatus,
};

/// Per-session lifecycle, mirroring the Swift `SessionLifecycle` /
/// Kotlin `SessionLifecycle` sealed class. Carried separately from
/// [`ProjectSessionState`] because the placeholder ("creating") state
/// exists before the server has reported a real session.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum SessionLifecycleCore {
    Creating,
    Live,
    Exited { code: i32 },
    FailedToStart { reason: String },
}

/// Shared reducer over `ProjectSessionState`s, addressable by session id.
///
/// Thread-safe (interior mutability via `parking_lot::Mutex`) because
/// UniFFI callbacks land on arbitrary worker threads on both platforms.
/// The store is the single writer per session id; readers can clone the
/// snapshot out under the lock.
pub struct SessionStoreCore {
    inner: Arc<Mutex<Inner>>,
}

#[derive(Default)]
struct Inner {
    sessions: HashMap<String, ProjectSessionState>,
    lifecycle: HashMap<String, SessionLifecycleCore>,
}

impl Default for SessionStoreCore {
    fn default() -> Self {
        Self::new()
    }
}

impl SessionStoreCore {
    pub fn new() -> Self {
        Self {
            inner: Arc::new(Mutex::new(Inner::default())),
        }
    }

    /// Register a brand-new session (placeholder lifecycle).
    ///
    /// Mirrors the apps' `sessionLifecycle[pendingID] = .creating` write
    /// after a successful `create_session` round-trip.
    pub fn register_session(&self, session: ProjectSession) {
        let mut inner = self.inner.lock();
        inner
            .sessions
            .entry(session.id.clone())
            .or_insert_with(|| ProjectSessionState::new(session.clone()));
        inner
            .lifecycle
            .entry(session.id.clone())
            .or_insert(SessionLifecycleCore::Live);
    }

    /// Drop a session entirely. Used by `exit_session` after the server
    /// has acknowledged the close.
    pub fn forget_session(&self, session_id: String) {
        let mut inner = self.inner.lock();
        inner.sessions.remove(&session_id);
        inner.lifecycle.remove(&session_id);
    }

    /// Fold a `ChatEvent` into the per-session conversation log.
    ///
    /// Returns the resulting [`ProjectSessionState`] snapshot — callers
    /// that need only the typed log can also use
    /// [`SessionStoreCore::conversation`].
    ///
    /// **Idempotency:** if the same (role, content, ts) triplet has already
    /// been appended, the event is dropped. This matches the apps'
    /// `refreshConversation` fingerprint dedup against `local-*` items and
    /// guards against the broker replaying a frame after a reconnect.
    pub fn apply_chat(&self, session_id: String, event: ChatEvent) -> Option<ProjectSessionState> {
        let mut inner = self.inner.lock();
        let state = inner.sessions.get_mut(&session_id)?;
        if state.chat.events.iter().any(|prev| {
            prev.role == event.role && prev.content == event.content && prev.ts == event.ts
        }) {
            return Some(state.clone());
        }
        state.push_chat_event(event);
        Some(state.clone())
    }

    /// Fold a `SessionStatus` frame: updates the session header (assistant,
    /// session name, reasoning effort, cwd, last_activity_at), preview,
    /// terminal rows/cols. Inserts a placeholder `ProjectSessionState` if
    /// the session isn't registered yet — the broker can race `on_status`
    /// ahead of our local `register_session`.
    pub fn apply_status(&self, status: SessionStatus) -> ProjectSessionState {
        let mut inner = self.inner.lock();
        let session_id = status.session.clone();
        let state = inner.sessions.entry(session_id.clone()).or_insert_with(|| {
            ProjectSessionState::new(ProjectSession {
                id: session_id.clone(),
                name: status
                    .session_name
                    .clone()
                    .unwrap_or_else(|| session_id.clone()),
                assistant: status.assistant.clone(),
                branch: None,
                preview: status.preview.clone(),
                reasoning_effort: status.reasoning_effort.clone(),
                cwd: status.cwd.clone(),
                started_at: status.started_at.clone(),
                last_activity_at: status.last_activity_at.clone(),
                display_name: status
                    .display_name
                    .clone()
                    .or_else(|| status.session_name.clone()),
                total_input_tokens: status.total_input_tokens,
                total_output_tokens: status.total_output_tokens,
                total_cached_tokens: status.total_cached_tokens,
                total_cost_usd: status.total_cost_usd,
                context_used_tokens: status.context_used_tokens,
                context_window_tokens: status.context_window_tokens,
            })
        });
        state.apply_status(status);
        // A status frame implies the session is at least live (the apps'
        // `ingestStatus` also flips lifecycle from `creating` -> `live`).
        let entry = inner
            .lifecycle
            .entry(session_id.clone())
            .or_insert(SessionLifecycleCore::Live);
        if matches!(entry, SessionLifecycleCore::Creating) {
            *entry = SessionLifecycleCore::Live;
        }
        inner.sessions.get(&session_id).cloned().unwrap()
    }

    /// Fold an `on_exit` callback: marks the session exited and stamps the
    /// stored status' phase/health, matching the iOS `ingestExit`.
    pub fn apply_exit(&self, session_id: String, code: i32) -> Option<ProjectSessionState> {
        let mut inner = self.inner.lock();
        let snapshot = {
            let state = inner.sessions.get_mut(&session_id)?;
            state.mark_exited(code);
            state.clone()
        };
        inner
            .lifecycle
            .insert(session_id, SessionLifecycleCore::Exited { code });
        Some(snapshot)
    }

    /// Fold an explicit lifecycle update — used by the apps when they
    /// optimistically mark a session `Creating` / `FailedToStart` from
    /// their own create-session code path, before the server has
    /// confirmed.
    pub fn apply_lifecycle(&self, session_id: String, lifecycle: SessionLifecycleCore) {
        let mut inner = self.inner.lock();
        inner.lifecycle.insert(session_id, lifecycle);
    }

    /// Fold a `preview_ready` frame.
    pub fn apply_preview(
        &self,
        session_id: String,
        preview: PreviewInfo,
    ) -> Option<ProjectSessionState> {
        let mut inner = self.inner.lock();
        let state = inner.sessions.get_mut(&session_id)?;
        state.set_preview(preview);
        Some(state.clone())
    }

    /// Replace per-session terminal scrollback with an authoritative
    /// snapshot (the broker sends one on join).
    pub fn apply_snapshot(
        &self,
        session_id: String,
        gunzipped: Vec<u8>,
    ) -> Option<ProjectSessionState> {
        let mut inner = self.inner.lock();
        let state = inner.sessions.get_mut(&session_id)?;
        state.apply_snapshot(gunzipped);
        Some(state.clone())
    }

    /// Append PTY bytes to the per-session scrollback.
    pub fn apply_pty_data(&self, session_id: String, data: Vec<u8>) -> Option<ProjectSessionState> {
        let mut inner = self.inner.lock();
        let state = inner.sessions.get_mut(&session_id)?;
        state.terminal.scrollback.extend_from_slice(&data);
        Some(state.clone())
    }

    // -- Read-only accessors --

    /// Snapshot of the full state for a session.
    pub fn get(&self, session_id: String) -> Option<ProjectSessionState> {
        self.inner.lock().sessions.get(&session_id).cloned()
    }

    /// All sessions, cloned out for the caller.
    pub fn sessions(&self) -> Vec<ProjectSession> {
        self.inner
            .lock()
            .sessions
            .values()
            .map(|s| s.session.clone())
            .collect()
    }

    /// Typed conversation log for one session.
    pub fn conversation(&self, session_id: String) -> Vec<ConversationItem> {
        self.inner
            .lock()
            .sessions
            .get(&session_id)
            .map(|s| s.chat.conversation.clone())
            .unwrap_or_default()
    }

    /// Lifecycle for one session, if any.
    pub fn lifecycle(&self, session_id: String) -> Option<SessionLifecycleCore> {
        self.inner.lock().lifecycle.get(&session_id).cloned()
    }

    /// Whether the store currently tracks this session.
    pub fn contains(&self, session_id: String) -> bool {
        self.inner.lock().sessions.contains_key(&session_id)
    }
}

/// Test-only ergonomic shims so the existing test suite can still pass
/// `&str` session ids — the public methods now take `String` to match
/// the UniFFI-generated FFI surface (which marshals UDL `string` to
/// owned `String`).
#[cfg(test)]
impl SessionStoreCore {
    fn apply_chat_str(&self, session_id: &str, event: ChatEvent) -> Option<ProjectSessionState> {
        self.apply_chat(session_id.to_string(), event)
    }
    fn apply_exit_str(&self, session_id: &str, code: i32) -> Option<ProjectSessionState> {
        self.apply_exit(session_id.to_string(), code)
    }
    fn apply_lifecycle_str(&self, session_id: &str, lifecycle: SessionLifecycleCore) {
        self.apply_lifecycle(session_id.to_string(), lifecycle)
    }
    fn apply_preview_str(
        &self,
        session_id: &str,
        preview: PreviewInfo,
    ) -> Option<ProjectSessionState> {
        self.apply_preview(session_id.to_string(), preview)
    }
    fn apply_snapshot_str(
        &self,
        session_id: &str,
        gunzipped: Vec<u8>,
    ) -> Option<ProjectSessionState> {
        self.apply_snapshot(session_id.to_string(), gunzipped)
    }
    fn apply_pty_data_str(&self, session_id: &str, data: Vec<u8>) -> Option<ProjectSessionState> {
        self.apply_pty_data(session_id.to_string(), data)
    }
    fn get_str(&self, session_id: &str) -> Option<ProjectSessionState> {
        self.get(session_id.to_string())
    }
    fn lifecycle_str(&self, session_id: &str) -> Option<SessionLifecycleCore> {
        self.lifecycle(session_id.to_string())
    }
    fn contains_str(&self, session_id: &str) -> bool {
        self.contains(session_id.to_string())
    }
    fn forget_session_str(&self, session_id: &str) {
        self.forget_session(session_id.to_string())
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::views::ViewEventFile;

    fn project(id: &str) -> ProjectSession {
        ProjectSession {
            id: id.to_string(),
            name: id.to_string(),
            assistant: "claude".to_string(),
            branch: None,
            preview: None,
            reasoning_effort: None,
            cwd: None,
            started_at: None,
            last_activity_at: None,
            display_name: None,
            total_input_tokens: None,
            total_output_tokens: None,
            total_cached_tokens: None,
            total_cost_usd: None,
            context_used_tokens: None,
            context_window_tokens: None,
        }
    }

    fn chat(role: &str, content: &str, ts: &str) -> ChatEvent {
        ChatEvent {
            role: role.to_string(),
            content: content.to_string(),
            ts: ts.to_string(),
            files: vec![],
        }
    }

    fn status(session: &str, phase: &str, effort: Option<&str>) -> SessionStatus {
        SessionStatus {
            session: session.to_string(),
            assistant: "claude".to_string(),
            phase: phase.to_string(),
            health: "green".to_string(),
            rows: 24,
            cols: 80,
            yolo: false,
            preview: None,
            session_name: None,
            viewers: None,
            reasoning_effort: effort.map(|s| s.to_string()),
            cwd: None,
            started_at: None,
            last_activity_at: None,
            display_name: None,
            total_input_tokens: None,
            total_output_tokens: None,
            total_cached_tokens: None,
            total_cost_usd: None,
            context_used_tokens: None,
            context_window_tokens: None,
        }
    }

    #[test]
    fn apply_chat_user_message() {
        let store = SessionStoreCore::new();
        store.register_session(project("s1"));
        let snap = store
            .apply_chat_str("s1", chat("user", "hello", "2026-05-21T00:00:00Z"))
            .expect("session registered");
        assert_eq!(snap.chat.events.len(), 1);
        assert_eq!(snap.chat.conversation.len(), 1);
        assert_eq!(snap.chat.conversation[0].role, "user");
        assert_eq!(snap.chat.conversation[0].kind, "message");
    }

    #[test]
    fn apply_chat_assistant_message() {
        let store = SessionStoreCore::new();
        store.register_session(project("s1"));
        let snap = store
            .apply_chat_str("s1", chat("assistant", "thinking…", "2026-05-21T00:00:01Z"))
            .unwrap();
        assert_eq!(snap.chat.conversation[0].role, "assistant");
        assert_eq!(snap.chat.conversation[0].kind, "message");
    }

    #[test]
    fn apply_chat_idempotent() {
        let store = SessionStoreCore::new();
        store.register_session(project("s1"));
        let ev = chat("user", "same line", "2026-05-21T00:00:00Z");
        store.apply_chat_str("s1", ev.clone()).unwrap();
        store.apply_chat_str("s1", ev.clone()).unwrap();
        store.apply_chat_str("s1", ev).unwrap();
        let snap = store.get_str("s1").unwrap();
        assert_eq!(snap.chat.events.len(), 1, "duplicates should be dropped");
        assert_eq!(snap.chat.conversation.len(), 1);
    }

    #[test]
    fn apply_chat_unknown_session_is_none() {
        let store = SessionStoreCore::new();
        let result = store.apply_chat_str("nope", chat("user", "x", "t"));
        assert!(result.is_none());
    }

    #[test]
    fn apply_status_reasoning_effort_threaded_through() {
        let store = SessionStoreCore::new();
        let snap = store.apply_status(status("s1", "live", Some("high")));
        assert_eq!(snap.session.reasoning_effort.as_deref(), Some("high"));
        assert_eq!(snap.session.assistant, "claude");
        // status also flips lifecycle to Live
        assert_eq!(store.lifecycle_str("s1"), Some(SessionLifecycleCore::Live));
    }

    #[test]
    fn apply_status_creates_session_if_missing() {
        let store = SessionStoreCore::new();
        assert!(!store.contains_str("s2"));
        store.apply_status(status("s2", "live", Some("medium")));
        assert!(store.contains_str("s2"));
    }

    #[test]
    fn apply_status_promotes_creating_to_live() {
        let store = SessionStoreCore::new();
        store.register_session(project("s1"));
        store.apply_lifecycle_str("s1", SessionLifecycleCore::Creating);
        store.apply_status(status("s1", "live", None));
        assert_eq!(store.lifecycle_str("s1"), Some(SessionLifecycleCore::Live));
    }

    #[test]
    fn apply_exit_marks_state_and_lifecycle() {
        let store = SessionStoreCore::new();
        store.register_session(project("s1"));
        store.apply_status(status("s1", "live", None));
        let snap = store.apply_exit_str("s1", 42).unwrap();
        assert!(snap.exited);
        assert_eq!(snap.exit_code, Some(42));
        assert_eq!(snap.status.as_ref().unwrap().phase, "exited");
        assert_eq!(snap.status.as_ref().unwrap().health, "dead");
        assert_eq!(
            store.lifecycle_str("s1"),
            Some(SessionLifecycleCore::Exited { code: 42 })
        );
    }

    #[test]
    fn apply_exit_zero_keeps_status_health() {
        let store = SessionStoreCore::new();
        store.register_session(project("s1"));
        store.apply_status(status("s1", "live", None));
        let snap = store.apply_exit_str("s1", 0).unwrap();
        assert!(snap.exited);
        // Zero exit leaves the original `green` health alone (only non-zero
        // promotes to `dead`).
        assert_eq!(snap.status.as_ref().unwrap().health, "green");
    }

    #[test]
    fn apply_preview_updates_browser_and_session() {
        let store = SessionStoreCore::new();
        store.register_session(project("s1"));
        let snap = store
            .apply_preview_str(
                "s1",
                PreviewInfo {
                    port: 5173,
                    url: "http://127.0.0.1:5173".to_string(),
                },
            )
            .unwrap();
        assert_eq!(snap.browser.preview.as_ref().unwrap().port, 5173);
        assert_eq!(snap.session.preview.as_ref().unwrap().port, 5173);
    }

    #[test]
    fn apply_snapshot_replaces_scrollback() {
        let store = SessionStoreCore::new();
        store.register_session(project("s1"));
        store.apply_pty_data_str("s1", b"old data".to_vec());
        let snap = store
            .apply_snapshot_str("s1", b"authoritative scrollback".to_vec())
            .unwrap();
        assert_eq!(snap.terminal.scrollback, b"authoritative scrollback");
        assert!(snap.terminal.has_snapshot);
    }

    #[test]
    fn apply_pty_data_appends() {
        let store = SessionStoreCore::new();
        store.register_session(project("s1"));
        store.apply_pty_data_str("s1", b"hello ".to_vec());
        let snap = store.apply_pty_data_str("s1", b"world".to_vec()).unwrap();
        assert_eq!(snap.terminal.scrollback, b"hello world");
    }

    #[test]
    fn ordering_status_then_chat_then_exit() {
        let store = SessionStoreCore::new();
        store.register_session(project("s1"));
        store.apply_status(status("s1", "live", Some("high")));
        store.apply_chat_str("s1", chat("user", "go", "2026-05-21T00:00:00Z"));
        store.apply_chat_str("s1", chat("assistant", "done", "2026-05-21T00:00:01Z"));
        let snap = store.apply_exit_str("s1", 0).unwrap();
        assert!(snap.exited);
        assert_eq!(snap.chat.conversation.len(), 2);
        assert_eq!(snap.session.reasoning_effort.as_deref(), Some("high"));
    }

    #[test]
    fn ordering_out_of_order_chat_then_status() {
        // The broker can ship chat ahead of status if the websocket
        // ordering hiccups; the store should still register the session
        // (because chat targeted an existing one) and the late status
        // should just refresh metadata.
        let store = SessionStoreCore::new();
        store.register_session(project("s1"));
        store.apply_chat_str("s1", chat("assistant", "early msg", "2026-05-21T00:00:00Z"));
        store.apply_status(status("s1", "live", Some("medium")));
        let snap = store.get_str("s1").unwrap();
        assert_eq!(snap.chat.conversation.len(), 1);
        assert_eq!(snap.session.reasoning_effort.as_deref(), Some("medium"));
    }

    #[test]
    fn ordering_status_for_unknown_session_then_chat() {
        // The opposite race: status arrives first for a session the
        // platform layer hasn't registered yet. The store synthesizes
        // the placeholder; a subsequent chat then folds in.
        let store = SessionStoreCore::new();
        store.apply_status(status("s3", "live", None));
        store
            .apply_chat_str("s3", chat("user", "first", "2026-05-21T00:00:00Z"))
            .expect("session synthesized by apply_status");
        let snap = store.get_str("s3").unwrap();
        assert_eq!(snap.chat.conversation.len(), 1);
    }

    #[test]
    fn apply_chat_files_carried_through() {
        let store = SessionStoreCore::new();
        store.register_session(project("s1"));
        let event = ChatEvent {
            role: "tool".to_string(),
            content: "Edit: src/foo.rs\nexit=0".to_string(),
            ts: "2026-05-21T00:00:00Z".to_string(),
            files: vec![ViewEventFile {
                path: "src/foo.rs".to_string(),
                rev: "abc123".to_string(),
            }],
        };
        let snap = store.apply_chat_str("s1", event).unwrap();
        assert_eq!(snap.chat.conversation[0].files.len(), 1);
        assert_eq!(snap.chat.conversation[0].files[0].path, "src/foo.rs");
        assert_eq!(snap.chat.conversation[0].tool_name.as_deref(), Some("Edit"));
    }

    #[test]
    fn forget_session_drops_state_and_lifecycle() {
        let store = SessionStoreCore::new();
        store.register_session(project("s1"));
        store.apply_chat_str("s1", chat("user", "hi", "ts"));
        assert!(store.contains_str("s1"));
        store.forget_session_str("s1");
        assert!(!store.contains_str("s1"));
        assert_eq!(store.lifecycle_str("s1"), None);
    }

    #[test]
    fn lifecycle_overrides_persist() {
        let store = SessionStoreCore::new();
        store.apply_lifecycle_str("pending-1", SessionLifecycleCore::Creating);
        assert_eq!(
            store.lifecycle_str("pending-1"),
            Some(SessionLifecycleCore::Creating)
        );
        store.apply_lifecycle_str(
            "pending-1",
            SessionLifecycleCore::FailedToStart {
                reason: "connection refused".to_string(),
            },
        );
        assert_eq!(
            store.lifecycle_str("pending-1"),
            Some(SessionLifecycleCore::FailedToStart {
                reason: "connection refused".to_string(),
            })
        );
    }
}
