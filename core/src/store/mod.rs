//! Shared session-store reducer.
//!
//! Today the iOS `SessionStore.swift` and Android `SessionStore.kt`
//! independently implement the same shape: ingest a `ChatEvent` /
//! `SessionStatus` / `exit` callback from the Rust transport, fold it into
//! some per-session maps, derive a few cross-session aggregates. That's
//! reducer-shaped logic living on both platforms — exactly what
//! `docs/PLAN-2026-05-19.md` §3.1 flags as the bleed we need to stop.
//!
//! `SessionStore` is the clean-room Rust port of that surface. It owns a
//! map of `session_id -> ProjectSessionState` and exposes one method per
//! existing Swift/Kotlin entry point:
//!
//! - [`SessionStore::apply_chat`]      — `onChatEvent` / `ingestChat`
//! - [`SessionStore::apply_status`]    — `onStatus`    / `ingestStatus`
//! - [`SessionStore::apply_exit`]      — `onExit`      / `ingestExit`
//! - [`SessionStore::apply_preview`]   — `onPreviewReady` / `ingestPreview`
//! - [`SessionStore::apply_snapshot`]  — `onSnapshot`     / `ingestSnapshot`
//! - [`SessionStore::apply_pty_data`]  — `onPtyData`      / `ingestPtyData`
//! - [`SessionStore::apply_lifecycle`] — `sessionLifecycle[id] = …`
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
//! `SessionStore` is the *public* reducer surface. Once the apps migrate to
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
pub enum SessionLifecycle {
    Creating,
    Live,
    Exited(i32),
    FailedToStart(String),
}

/// Shared reducer over `ProjectSessionState`s, addressable by session id.
///
/// Thread-safe (interior mutability via `parking_lot::Mutex`) because
/// UniFFI callbacks land on arbitrary worker threads on both platforms.
/// The store is the single writer per session id; readers can clone the
/// snapshot out under the lock.
pub struct SessionStore {
    inner: Arc<Mutex<Inner>>,
}

#[derive(Default)]
struct Inner {
    sessions: HashMap<String, ProjectSessionState>,
    lifecycle: HashMap<String, SessionLifecycle>,
}

impl Default for SessionStore {
    fn default() -> Self {
        Self::new()
    }
}

impl SessionStore {
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
            .or_insert(SessionLifecycle::Live);
    }

    /// Drop a session entirely. Used by `exit_session` after the server
    /// has acknowledged the close.
    pub fn forget_session(&self, session_id: &str) {
        let mut inner = self.inner.lock();
        inner.sessions.remove(session_id);
        inner.lifecycle.remove(session_id);
    }

    /// Fold a `ChatEvent` into the per-session conversation log.
    ///
    /// Returns the resulting [`ProjectSessionState`] snapshot — callers
    /// that need only the typed log can also use
    /// [`SessionStore::conversation`].
    ///
    /// **Idempotency:** if the same (role, content, ts) triplet has already
    /// been appended, the event is dropped. This matches the apps'
    /// `refreshConversation` fingerprint dedup against `local-*` items and
    /// guards against the broker replaying a frame after a reconnect.
    pub fn apply_chat(&self, session_id: &str, event: ChatEvent) -> Option<ProjectSessionState> {
        let mut inner = self.inner.lock();
        let state = inner.sessions.get_mut(session_id)?;
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
            })
        });
        state.apply_status(status);
        // A status frame implies the session is at least live (the apps'
        // `ingestStatus` also flips lifecycle from `creating` -> `live`).
        let entry = inner
            .lifecycle
            .entry(session_id.clone())
            .or_insert(SessionLifecycle::Live);
        if matches!(entry, SessionLifecycle::Creating) {
            *entry = SessionLifecycle::Live;
        }
        inner.sessions.get(&session_id).cloned().unwrap()
    }

    /// Fold an `on_exit` callback: marks the session exited and stamps the
    /// stored status' phase/health, matching the iOS `ingestExit`.
    pub fn apply_exit(&self, session_id: &str, code: i32) -> Option<ProjectSessionState> {
        let mut inner = self.inner.lock();
        let snapshot = {
            let state = inner.sessions.get_mut(session_id)?;
            state.mark_exited(code);
            state.clone()
        };
        inner
            .lifecycle
            .insert(session_id.to_string(), SessionLifecycle::Exited(code));
        Some(snapshot)
    }

    /// Fold an explicit lifecycle update — used by the apps when they
    /// optimistically mark a session `Creating` / `FailedToStart` from
    /// their own create-session code path, before the server has
    /// confirmed.
    pub fn apply_lifecycle(&self, session_id: &str, lifecycle: SessionLifecycle) {
        let mut inner = self.inner.lock();
        inner.lifecycle.insert(session_id.to_string(), lifecycle);
    }

    /// Fold a `preview_ready` frame.
    pub fn apply_preview(
        &self,
        session_id: &str,
        preview: PreviewInfo,
    ) -> Option<ProjectSessionState> {
        let mut inner = self.inner.lock();
        let state = inner.sessions.get_mut(session_id)?;
        state.set_preview(preview);
        Some(state.clone())
    }

    /// Replace per-session terminal scrollback with an authoritative
    /// snapshot (the broker sends one on join).
    pub fn apply_snapshot(
        &self,
        session_id: &str,
        gunzipped: Vec<u8>,
    ) -> Option<ProjectSessionState> {
        let mut inner = self.inner.lock();
        let state = inner.sessions.get_mut(session_id)?;
        state.apply_snapshot(gunzipped);
        Some(state.clone())
    }

    /// Append PTY bytes to the per-session scrollback.
    pub fn apply_pty_data(&self, session_id: &str, data: Vec<u8>) -> Option<ProjectSessionState> {
        let mut inner = self.inner.lock();
        let state = inner.sessions.get_mut(session_id)?;
        state.terminal.scrollback.extend_from_slice(&data);
        Some(state.clone())
    }

    // -- Read-only accessors --

    /// Snapshot of the full state for a session.
    pub fn get(&self, session_id: &str) -> Option<ProjectSessionState> {
        self.inner.lock().sessions.get(session_id).cloned()
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
    pub fn conversation(&self, session_id: &str) -> Vec<ConversationItem> {
        self.inner
            .lock()
            .sessions
            .get(session_id)
            .map(|s| s.chat.conversation.clone())
            .unwrap_or_default()
    }

    /// Lifecycle for one session, if any.
    pub fn lifecycle(&self, session_id: &str) -> Option<SessionLifecycle> {
        self.inner.lock().lifecycle.get(session_id).cloned()
    }

    /// Whether the store currently tracks this session.
    pub fn contains(&self, session_id: &str) -> bool {
        self.inner.lock().sessions.contains_key(session_id)
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
        }
    }

    #[test]
    fn apply_chat_user_message() {
        let store = SessionStore::new();
        store.register_session(project("s1"));
        let snap = store
            .apply_chat("s1", chat("user", "hello", "2026-05-21T00:00:00Z"))
            .expect("session registered");
        assert_eq!(snap.chat.events.len(), 1);
        assert_eq!(snap.chat.conversation.len(), 1);
        assert_eq!(snap.chat.conversation[0].role, "user");
        assert_eq!(snap.chat.conversation[0].kind, "message");
    }

    #[test]
    fn apply_chat_assistant_message() {
        let store = SessionStore::new();
        store.register_session(project("s1"));
        let snap = store
            .apply_chat("s1", chat("assistant", "thinking…", "2026-05-21T00:00:01Z"))
            .unwrap();
        assert_eq!(snap.chat.conversation[0].role, "assistant");
        assert_eq!(snap.chat.conversation[0].kind, "message");
    }

    #[test]
    fn apply_chat_idempotent() {
        let store = SessionStore::new();
        store.register_session(project("s1"));
        let ev = chat("user", "same line", "2026-05-21T00:00:00Z");
        store.apply_chat("s1", ev.clone()).unwrap();
        store.apply_chat("s1", ev.clone()).unwrap();
        store.apply_chat("s1", ev).unwrap();
        let snap = store.get("s1").unwrap();
        assert_eq!(snap.chat.events.len(), 1, "duplicates should be dropped");
        assert_eq!(snap.chat.conversation.len(), 1);
    }

    #[test]
    fn apply_chat_unknown_session_is_none() {
        let store = SessionStore::new();
        let result = store.apply_chat("nope", chat("user", "x", "t"));
        assert!(result.is_none());
    }

    #[test]
    fn apply_status_reasoning_effort_threaded_through() {
        let store = SessionStore::new();
        let snap = store.apply_status(status("s1", "live", Some("high")));
        assert_eq!(snap.session.reasoning_effort.as_deref(), Some("high"));
        assert_eq!(snap.session.assistant, "claude");
        // status also flips lifecycle to Live
        assert_eq!(store.lifecycle("s1"), Some(SessionLifecycle::Live));
    }

    #[test]
    fn apply_status_creates_session_if_missing() {
        let store = SessionStore::new();
        assert!(!store.contains("s2"));
        store.apply_status(status("s2", "live", Some("medium")));
        assert!(store.contains("s2"));
    }

    #[test]
    fn apply_status_promotes_creating_to_live() {
        let store = SessionStore::new();
        store.register_session(project("s1"));
        store.apply_lifecycle("s1", SessionLifecycle::Creating);
        store.apply_status(status("s1", "live", None));
        assert_eq!(store.lifecycle("s1"), Some(SessionLifecycle::Live));
    }

    #[test]
    fn apply_exit_marks_state_and_lifecycle() {
        let store = SessionStore::new();
        store.register_session(project("s1"));
        store.apply_status(status("s1", "live", None));
        let snap = store.apply_exit("s1", 42).unwrap();
        assert!(snap.exited);
        assert_eq!(snap.exit_code, Some(42));
        assert_eq!(snap.status.as_ref().unwrap().phase, "exited");
        assert_eq!(snap.status.as_ref().unwrap().health, "dead");
        assert_eq!(store.lifecycle("s1"), Some(SessionLifecycle::Exited(42)));
    }

    #[test]
    fn apply_exit_zero_keeps_status_health() {
        let store = SessionStore::new();
        store.register_session(project("s1"));
        store.apply_status(status("s1", "live", None));
        let snap = store.apply_exit("s1", 0).unwrap();
        assert!(snap.exited);
        // Zero exit leaves the original `green` health alone (only non-zero
        // promotes to `dead`).
        assert_eq!(snap.status.as_ref().unwrap().health, "green");
    }

    #[test]
    fn apply_preview_updates_browser_and_session() {
        let store = SessionStore::new();
        store.register_session(project("s1"));
        let snap = store
            .apply_preview(
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
        let store = SessionStore::new();
        store.register_session(project("s1"));
        store.apply_pty_data("s1", b"old data".to_vec());
        let snap = store
            .apply_snapshot("s1", b"authoritative scrollback".to_vec())
            .unwrap();
        assert_eq!(snap.terminal.scrollback, b"authoritative scrollback");
        assert!(snap.terminal.has_snapshot);
    }

    #[test]
    fn apply_pty_data_appends() {
        let store = SessionStore::new();
        store.register_session(project("s1"));
        store.apply_pty_data("s1", b"hello ".to_vec());
        let snap = store.apply_pty_data("s1", b"world".to_vec()).unwrap();
        assert_eq!(snap.terminal.scrollback, b"hello world");
    }

    #[test]
    fn ordering_status_then_chat_then_exit() {
        let store = SessionStore::new();
        store.register_session(project("s1"));
        store.apply_status(status("s1", "live", Some("high")));
        store.apply_chat("s1", chat("user", "go", "2026-05-21T00:00:00Z"));
        store.apply_chat("s1", chat("assistant", "done", "2026-05-21T00:00:01Z"));
        let snap = store.apply_exit("s1", 0).unwrap();
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
        let store = SessionStore::new();
        store.register_session(project("s1"));
        store.apply_chat("s1", chat("assistant", "early msg", "2026-05-21T00:00:00Z"));
        store.apply_status(status("s1", "live", Some("medium")));
        let snap = store.get("s1").unwrap();
        assert_eq!(snap.chat.conversation.len(), 1);
        assert_eq!(snap.session.reasoning_effort.as_deref(), Some("medium"));
    }

    #[test]
    fn ordering_status_for_unknown_session_then_chat() {
        // The opposite race: status arrives first for a session the
        // platform layer hasn't registered yet. The store synthesizes
        // the placeholder; a subsequent chat then folds in.
        let store = SessionStore::new();
        store.apply_status(status("s3", "live", None));
        store
            .apply_chat("s3", chat("user", "first", "2026-05-21T00:00:00Z"))
            .expect("session synthesized by apply_status");
        let snap = store.get("s3").unwrap();
        assert_eq!(snap.chat.conversation.len(), 1);
    }

    #[test]
    fn apply_chat_files_carried_through() {
        let store = SessionStore::new();
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
        let snap = store.apply_chat("s1", event).unwrap();
        assert_eq!(snap.chat.conversation[0].files.len(), 1);
        assert_eq!(snap.chat.conversation[0].files[0].path, "src/foo.rs");
        assert_eq!(snap.chat.conversation[0].tool_name.as_deref(), Some("Edit"));
    }

    #[test]
    fn forget_session_drops_state_and_lifecycle() {
        let store = SessionStore::new();
        store.register_session(project("s1"));
        store.apply_chat("s1", chat("user", "hi", "ts"));
        assert!(store.contains("s1"));
        store.forget_session("s1");
        assert!(!store.contains("s1"));
        assert_eq!(store.lifecycle("s1"), None);
    }

    #[test]
    fn lifecycle_overrides_persist() {
        let store = SessionStore::new();
        store.apply_lifecycle("pending-1", SessionLifecycle::Creating);
        assert_eq!(
            store.lifecycle("pending-1"),
            Some(SessionLifecycle::Creating)
        );
        store.apply_lifecycle(
            "pending-1",
            SessionLifecycle::FailedToStart("connection refused".to_string()),
        );
        assert_eq!(
            store.lifecycle("pending-1"),
            Some(SessionLifecycle::FailedToStart(
                "connection refused".to_string()
            ))
        );
    }
}
