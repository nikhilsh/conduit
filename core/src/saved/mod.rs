//! Saved-session store — the historical "Resume an old thread" surface.
//!
//! `ProjectSessionState` (in `crate::session`) is the *live* session model
//! the transport keeps in memory while the harness is paired. The moment
//! the harness exits — or the user switches to a different server — that
//! state is gone. The litter parity audit item **A.8** says we need a
//! separate, persistent "Sessions" screen: every thread we've ever seen
//! across every server, including the ones that have already exited.
//!
//! ### Persistence shape
//!
//! `SavedSessionStore` is a flat list of [`SavedSession`] records
//! serialized to a JSON file at a platform-provided path
//! (Application Support on iOS, `getFilesDir()` on Android). The Rust
//! crate exposes [`SavedSessionStore::load_from`] /
//! [`SavedSessionStore::save_to`] and the upsert/list helpers; the
//! iOS layer reads and writes the same JSON file directly via a Swift
//! mirror of [`SavedSession`] (no UniFFI surface yet — the v1 plan is
//! that this stays Rust-internal until both platforms ship and we know
//! the shape is stable).
//!
//! ### What gets persisted
//!
//! - `id` / `server_id` — pair uniquely identifies a session across the
//!   client's entire lifetime.
//! - `agent` / `cwd` / `first_seen` / `last_seen` / `message_count` —
//!   enough metadata to render a useful row in the "Sessions" screen
//!   without needing to dial the harness first.
//! - `summary` — the first user message truncated to 100 chars. Lets
//!   the list double as a "did I already ask about X?" search index
//!   even when the underlying server is offline.
//! - `status` — `live` while we see the session in the live store,
//!   `exited` once the harness emits an exit code, `unknown` once we
//!   load the record from disk on next launch (we can't know whether
//!   the original harness is still up without dialling).

use std::collections::HashMap;
use std::fs;
use std::path::Path;

use serde::{Deserialize, Serialize};

use crate::views::ProjectSessionState;

/// Truncation budget for the rendered summary line. Chosen to fit on a
/// single row at typical iPhone widths without word-breaking mid-glyph.
pub const SUMMARY_MAX_CHARS: usize = 100;

/// Lifecycle bucket for a saved row. Mirrors the live `SessionLifecycle`
/// (Swift) values we already render in the home list — keeping the same
/// vocabulary lets the iOS layer reuse its dot colour map.
#[derive(Debug, Clone, Default, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "lowercase")]
pub enum SavedSessionStatus {
    /// Last `upsert` saw an active session on this id.
    Live,
    /// Harness emitted an exit (clean or otherwise).
    Exited,
    /// Loaded from disk on launch; the harness hasn't been redialed yet.
    #[default]
    Unknown,
}

/// One row in the historical "Resume" screen. `id` + `server_id` together
/// identify the session; `id` alone may repeat across servers.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct SavedSession {
    pub id: String,
    pub server_id: String,
    pub agent: String,
    /// Working directory the agent was spawned into, if known. Surfaced
    /// in the row subtitle so the user can tell sibling sessions apart.
    pub cwd: Option<String>,
    /// RFC3339-ish timestamp; we treat it as opaque string at the core
    /// level and let the renderer format it relatively.
    pub first_seen: String,
    pub last_seen: String,
    pub message_count: u32,
    pub summary: String,
    #[serde(default)]
    pub status: SavedSessionStatus,
}

/// Persisted index keyed by `(server_id, session_id)`. Persisted as a
/// flat array for forward compatibility — the JSON file just contains
/// a `{"sessions":[…]}` object and nothing else, so future fields are
/// additive.
#[derive(Debug, Default, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct SavedSessionStore {
    /// Render order is not stable here — use [`list_recent`] to get a
    /// `last_seen`-descending view for the screen.
    sessions: HashMap<String, SavedSession>,
}

impl SavedSessionStore {
    pub fn new() -> Self {
        Self::default()
    }

    /// Fold a live [`ProjectSessionState`] snapshot into the saved index.
    ///
    /// - First time we've seen `(server_id, session_id)` → insert a new
    ///   row with `first_seen == last_seen == status.last_activity_at`
    ///   (or the current sentinel when the harness hasn't emitted one
    ///   yet) and `summary` derived from the first user message.
    /// - Subsequent calls → bump `last_seen`, `message_count`, refresh
    ///   `cwd` / `agent` from the latest status, and recompute the
    ///   summary if we now know the first user message.
    /// - Once `snapshot.exited` is true the row is locked into
    ///   `SavedSessionStatus::Exited` regardless of later upserts.
    pub fn upsert(&mut self, server_id: &str, snapshot: &ProjectSessionState) {
        let key = compound_key(server_id, &snapshot.session.id);
        let now = derive_last_seen(snapshot);
        let summary = derive_summary(snapshot);
        let status = derive_status(snapshot);
        let message_count = snapshot.chat.events.len() as u32;
        let agent = snapshot.session.assistant.clone();
        let cwd = snapshot.session.cwd.clone();

        match self.sessions.get_mut(&key) {
            Some(existing) => {
                // `first_seen` is sticky; everything else mirrors the latest
                // observation. Status is monotone toward `Exited` so a stale
                // `Live` upsert can't resurrect an exited row.
                existing.last_seen = pick_later(&existing.last_seen, &now);
                existing.message_count = existing.message_count.max(message_count);
                existing.agent = agent;
                existing.cwd = cwd.or(existing.cwd.clone());
                if existing.summary.is_empty() && !summary.is_empty() {
                    existing.summary = summary;
                }
                existing.status = merge_status(&existing.status, &status);
            }
            None => {
                self.sessions.insert(
                    key,
                    SavedSession {
                        id: snapshot.session.id.clone(),
                        server_id: server_id.to_string(),
                        agent,
                        cwd,
                        first_seen: now.clone(),
                        last_seen: now,
                        message_count,
                        summary,
                        status,
                    },
                );
            }
        }
    }

    /// Latest-first view, clamped to `limit`. Ties on `last_seen` are
    /// broken by `id` so test assertions are deterministic.
    pub fn list_recent(&self, limit: usize) -> Vec<SavedSession> {
        let mut out: Vec<SavedSession> = self.sessions.values().cloned().collect();
        out.sort_by(|a, b| b.last_seen.cmp(&a.last_seen).then_with(|| a.id.cmp(&b.id)));
        out.truncate(limit);
        out
    }

    /// Total count of distinct `(server_id, session_id)` pairs.
    pub fn len(&self) -> usize {
        self.sessions.len()
    }

    pub fn is_empty(&self) -> bool {
        self.sessions.is_empty()
    }

    /// Read the store from `path`. A missing file → empty store (first
    /// launch on a device). A corrupt file → empty store as well, so a
    /// broken on-disk state never bricks the "Sessions" screen.
    pub fn load_from(path: &Path) -> Self {
        let Ok(bytes) = fs::read(path) else {
            return Self::default();
        };
        serde_json::from_slice(&bytes).unwrap_or_default()
    }

    /// Atomically write the store to `path`. Creates the parent directory
    /// if it doesn't exist yet — the iOS Application Support directory
    /// is created lazily on first write.
    pub fn save_to(&self, path: &Path) -> std::io::Result<()> {
        if let Some(parent) = path.parent() {
            fs::create_dir_all(parent)?;
        }
        let bytes = serde_json::to_vec_pretty(self)
            .map_err(|err| std::io::Error::new(std::io::ErrorKind::InvalidData, err))?;
        fs::write(path, bytes)
    }
}

fn compound_key(server_id: &str, session_id: &str) -> String {
    format!("{server_id}::{session_id}")
}

fn derive_last_seen(snapshot: &ProjectSessionState) -> String {
    snapshot
        .session
        .last_activity_at
        .clone()
        .or_else(|| snapshot.session.started_at.clone())
        .or_else(|| snapshot.chat.events.last().map(|event| event.ts.clone()))
        .unwrap_or_default()
}

fn derive_summary(snapshot: &ProjectSessionState) -> String {
    let first_user = snapshot
        .chat
        .events
        .iter()
        .find(|event| event.role.eq_ignore_ascii_case("user"))
        .map(|event| event.content.as_str())
        .unwrap_or("");
    truncate_summary(first_user)
}

/// UTF-8 safe truncation. Returns a copy so the caller doesn't need to
/// reason about slice boundaries — `take(SUMMARY_MAX_CHARS)` would
/// silently pick a char boundary in the middle of a multi-byte glyph
/// if we sliced on bytes.
pub fn truncate_summary(text: &str) -> String {
    let cleaned: String = text.lines().next().unwrap_or("").trim().to_string();
    if cleaned.chars().count() <= SUMMARY_MAX_CHARS {
        return cleaned;
    }
    let head: String = cleaned.chars().take(SUMMARY_MAX_CHARS - 1).collect();
    format!("{head}…")
}

fn derive_status(snapshot: &ProjectSessionState) -> SavedSessionStatus {
    if snapshot.exited {
        SavedSessionStatus::Exited
    } else {
        SavedSessionStatus::Live
    }
}

fn merge_status(existing: &SavedSessionStatus, next: &SavedSessionStatus) -> SavedSessionStatus {
    // Exited is terminal — once we've seen it, never go back to Live /
    // Unknown. Unknown ⊏ Live ⊏ Exited (Unknown is the load-from-disk
    // default; Live tells us "we've seen it this session"; Exited is final).
    match (existing, next) {
        (SavedSessionStatus::Exited, _) => SavedSessionStatus::Exited,
        (_, SavedSessionStatus::Exited) => SavedSessionStatus::Exited,
        (SavedSessionStatus::Live, _) => SavedSessionStatus::Live,
        (_, SavedSessionStatus::Live) => SavedSessionStatus::Live,
        _ => SavedSessionStatus::Unknown,
    }
}

fn pick_later(a: &str, b: &str) -> String {
    // Both strings come from RFC3339-style timestamps the harness emits;
    // lexicographic comparison is correct for that format (fixed-width,
    // big-endian fields). Empty strings sort first so a real timestamp
    // always wins.
    if b > a {
        b.to_string()
    } else {
        a.to_string()
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::views::{ChatEvent, ProjectSession};

    fn session_with(id: &str, agent: &str, cwd: Option<&str>) -> ProjectSessionState {
        let session = ProjectSession {
            id: id.to_string(),
            name: id.to_string(),
            assistant: agent.to_string(),
            branch: None,
            preview: None,
            reasoning_effort: None,
            cwd: cwd.map(|s| s.to_string()),
            started_at: Some("2026-05-20T00:00:00Z".to_string()),
            last_activity_at: Some("2026-05-20T01:00:00Z".to_string()),
            display_name: None,
        };
        ProjectSessionState::new(session)
    }

    fn user_event(content: &str, ts: &str) -> ChatEvent {
        ChatEvent {
            role: "user".to_string(),
            content: content.to_string(),
            ts: ts.to_string(),
            files: vec![],
        }
    }

    #[test]
    fn upsert_inserts_then_updates_idempotently() {
        let mut store = SavedSessionStore::new();
        let mut snapshot = session_with("s-1", "claude", Some("/repo"));
        snapshot.push_chat_event(user_event("first ask", "2026-05-20T00:00:01Z"));

        store.upsert("server-a", &snapshot);
        store.upsert("server-a", &snapshot);
        store.upsert("server-a", &snapshot);

        assert_eq!(store.len(), 1, "repeated upserts must not duplicate");
        let row = store.list_recent(10).remove(0);
        assert_eq!(row.id, "s-1");
        assert_eq!(row.server_id, "server-a");
        assert_eq!(row.agent, "claude");
        assert_eq!(row.cwd.as_deref(), Some("/repo"));
        assert_eq!(row.summary, "first ask");
        assert_eq!(row.message_count, 1);
        assert_eq!(row.status, SavedSessionStatus::Live);
    }

    #[test]
    fn upsert_preserves_first_seen_and_advances_last_seen() {
        let mut store = SavedSessionStore::new();

        let mut early = session_with("s-1", "claude", None);
        early.session.last_activity_at = Some("2026-05-20T00:00:00Z".to_string());
        early.push_chat_event(user_event("hi", "2026-05-20T00:00:00Z"));
        store.upsert("server-a", &early);

        let mut later = session_with("s-1", "claude", None);
        later.session.last_activity_at = Some("2026-05-20T05:00:00Z".to_string());
        later.push_chat_event(user_event("hi", "2026-05-20T00:00:00Z"));
        later.push_chat_event(ChatEvent {
            role: "assistant".to_string(),
            content: "hello".to_string(),
            ts: "2026-05-20T05:00:00Z".to_string(),
            files: vec![],
        });
        store.upsert("server-a", &later);

        let row = store.list_recent(10).remove(0);
        assert_eq!(row.first_seen, "2026-05-20T00:00:00Z");
        assert_eq!(row.last_seen, "2026-05-20T05:00:00Z");
        assert_eq!(row.message_count, 2);
    }

    #[test]
    fn list_recent_orders_latest_first() {
        let mut store = SavedSessionStore::new();
        let mut older = session_with("s-old", "claude", None);
        older.session.last_activity_at = Some("2026-05-19T00:00:00Z".to_string());
        let mut newer = session_with("s-new", "codex", None);
        newer.session.last_activity_at = Some("2026-05-20T00:00:00Z".to_string());

        store.upsert("server-a", &older);
        store.upsert("server-a", &newer);

        let rows = store.list_recent(10);
        assert_eq!(rows.len(), 2);
        assert_eq!(rows[0].id, "s-new");
        assert_eq!(rows[1].id, "s-old");
    }

    #[test]
    fn list_recent_respects_limit() {
        let mut store = SavedSessionStore::new();
        for i in 0..5 {
            let mut snapshot = session_with(&format!("s-{i}"), "claude", None);
            snapshot.session.last_activity_at = Some(format!("2026-05-20T00:0{i}:00Z"));
            store.upsert("server-a", &snapshot);
        }
        assert_eq!(store.list_recent(2).len(), 2);
        assert_eq!(store.list_recent(10).len(), 5);
    }

    #[test]
    fn summary_truncated_to_budget_with_ellipsis() {
        let long = "a".repeat(250);
        let out = truncate_summary(&long);
        assert_eq!(out.chars().count(), SUMMARY_MAX_CHARS);
        assert!(out.ends_with('…'));
    }

    #[test]
    fn summary_drops_to_first_line() {
        let multi = "line one\nline two\nline three";
        assert_eq!(truncate_summary(multi), "line one");
    }

    #[test]
    fn summary_picks_first_user_message_not_assistant() {
        let mut store = SavedSessionStore::new();
        let mut snapshot = session_with("s-1", "claude", None);
        snapshot.push_chat_event(ChatEvent {
            role: "assistant".to_string(),
            content: "hello, how can I help?".to_string(),
            ts: "2026-05-20T00:00:00Z".to_string(),
            files: vec![],
        });
        snapshot.push_chat_event(user_event("please fix the build", "2026-05-20T00:00:01Z"));
        store.upsert("server-a", &snapshot);

        let row = store.list_recent(10).remove(0);
        assert_eq!(row.summary, "please fix the build");
    }

    #[test]
    fn exit_marks_status_exited_and_is_terminal() {
        let mut store = SavedSessionStore::new();
        let mut snapshot = session_with("s-1", "claude", None);
        snapshot.push_chat_event(user_event("hi", "2026-05-20T00:00:00Z"));
        store.upsert("server-a", &snapshot);

        snapshot.mark_exited(0);
        store.upsert("server-a", &snapshot);

        let row = store.list_recent(10).remove(0);
        assert_eq!(row.status, SavedSessionStatus::Exited);

        // A later (stale) "live" upsert must not revive an exited row.
        let mut stale = session_with("s-1", "claude", None);
        stale.push_chat_event(user_event("hi", "2026-05-20T00:00:00Z"));
        store.upsert("server-a", &stale);
        let row = store.list_recent(10).remove(0);
        assert_eq!(row.status, SavedSessionStatus::Exited);
    }

    #[test]
    fn same_id_different_servers_are_distinct_rows() {
        let mut store = SavedSessionStore::new();
        let snapshot = session_with("s-1", "claude", None);
        store.upsert("server-a", &snapshot);
        store.upsert("server-b", &snapshot);
        assert_eq!(store.len(), 2);
    }

    #[test]
    fn load_from_missing_file_returns_empty() {
        let tmp = std::env::temp_dir().join(format!(
            "swekitty-saved-missing-{}.json",
            uuid::Uuid::new_v4()
        ));
        let store = SavedSessionStore::load_from(&tmp);
        assert!(store.is_empty());
    }

    #[test]
    fn save_then_load_round_trips() {
        let mut store = SavedSessionStore::new();
        let mut snapshot = session_with("s-1", "claude", Some("/work"));
        snapshot.push_chat_event(user_event("hi there", "2026-05-20T00:00:00Z"));
        store.upsert("server-a", &snapshot);

        let tmp = std::env::temp_dir().join(format!(
            "swekitty-saved-rt-{}/saved-sessions.json",
            uuid::Uuid::new_v4()
        ));
        store.save_to(&tmp).expect("save_to");
        let restored = SavedSessionStore::load_from(&tmp);
        let _ = std::fs::remove_file(&tmp);

        assert_eq!(restored.len(), 1);
        let row = restored.list_recent(10).remove(0);
        assert_eq!(row.summary, "hi there");
        assert_eq!(row.cwd.as_deref(), Some("/work"));
    }
}
