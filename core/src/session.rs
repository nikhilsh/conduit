use serde::{Deserialize, Serialize};

use super::{ChatEvent, ConversationItem, PreviewInfo, SessionStatus};
use crate::conversation::item_from_chat_event;

/// Stable session summary exposed through UniFFI.
///
/// The transport emits transient `status` / `view_event` frames; mobile shells
/// can fold them into this session summary and the richer view state below.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct ProjectSession {
    pub id: String,
    pub name: String,
    pub assistant: String,
    pub branch: Option<String>,
    pub preview: Option<PreviewInfo>,
    /// Per-agent reasoning effort label ("low" / "medium" / "high").
    /// Threaded from the harness so the project header pill renders
    /// the actual setting instead of a hardcoded "medium".
    #[serde(default)]
    pub reasoning_effort: Option<String>,
    /// Absolute working directory the agent was spawned into.
    /// Surfaced in SessionInfo and the path label under the pill.
    #[serde(default)]
    pub cwd: Option<String>,
    /// RFC3339Nano timestamp when the harness session was created.
    #[serde(default)]
    pub started_at: Option<String>,
    /// RFC3339Nano timestamp of the most recent PTY byte received
    /// from the agent process. Used for "last activity N min ago".
    #[serde(default)]
    pub last_activity_at: Option<String>,
    /// Human-readable label set by `rename_session` (protocol §3.3).
    /// Surfaced to mobile shells as a preferred title — when present,
    /// iOS/Android prefer it over `name` (which usually carries the
    /// workspace folder). `None` until the user runs a rename.
    #[serde(default)]
    pub display_name: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize, Default, PartialEq, Eq)]
pub struct TerminalViewState {
    pub rows: u16,
    pub cols: u16,
    pub scrollback: Vec<u8>,
    pub has_snapshot: bool,
}

#[derive(Debug, Clone, Serialize, Deserialize, Default, PartialEq, Eq)]
pub struct ChatViewState {
    pub events: Vec<ChatEvent>,
    pub conversation: Vec<ConversationItem>,
}

#[derive(Debug, Clone, Serialize, Deserialize, Default, PartialEq, Eq)]
pub struct BrowserViewState {
    pub preview: Option<PreviewInfo>,
}

/// Reducer-friendly per-session state that keeps the three mobile views in one
/// place. The current public client API does not return this directly yet, but
/// this is the model the callbacks naturally update toward.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct ProjectSessionState {
    pub session: ProjectSession,
    pub status: Option<SessionStatus>,
    pub terminal: TerminalViewState,
    pub chat: ChatViewState,
    pub browser: BrowserViewState,
    pub exited: bool,
    pub exit_code: Option<i32>,
}

impl ProjectSessionState {
    pub fn new(session: ProjectSession) -> Self {
        Self {
            browser: BrowserViewState {
                preview: session.preview.clone(),
            },
            session,
            status: None,
            terminal: TerminalViewState::default(),
            chat: ChatViewState::default(),
            exited: false,
            exit_code: None,
        }
    }

    pub fn apply_status(&mut self, status: SessionStatus) {
        self.session.id = status.session.clone();
        self.session.assistant = status.assistant.clone();
        if let Some(name) = status.session_name.clone() {
            self.session.name = name;
        }
        // `display_name` (protocol §3.3) is the user-supplied label set
        // via `rename_session`. Surface it on `ProjectSession` as a
        // distinct field so mobile titles can prefer the rename while
        // keeping `name` (workspace folder) intact for path display.
        // The wire mirrors it via `display_name` and also re-emits the
        // legacy `session_name` for older clients — read `display_name`
        // first, fall back to the legacy mirror for resilience.
        if status.display_name.is_some() {
            self.session.display_name = status.display_name.clone();
        } else if status.session_name.is_some() {
            self.session.display_name = status.session_name.clone();
        }
        if let Some(preview) = status.preview.clone() {
            self.session.preview = Some(preview.clone());
            self.browser.preview = Some(preview);
        }
        // Carry the optional info-sheet fields through. apply_status is
        // called on every `status` frame, so the last one wins — exactly
        // what we want for last_activity_at (it ticks forward) and for
        // any later config change to reasoning_effort.
        if status.reasoning_effort.is_some() {
            self.session.reasoning_effort = status.reasoning_effort.clone();
        }
        if status.cwd.is_some() {
            self.session.cwd = status.cwd.clone();
        }
        if status.started_at.is_some() {
            self.session.started_at = status.started_at.clone();
        }
        if status.last_activity_at.is_some() {
            self.session.last_activity_at = status.last_activity_at.clone();
        }
        self.terminal.rows = status.rows;
        self.terminal.cols = status.cols;
        self.status = Some(status);
    }

    pub fn apply_snapshot(&mut self, scrollback: Vec<u8>) {
        self.terminal.scrollback = scrollback;
        self.terminal.has_snapshot = true;
    }

    pub fn push_chat_event(&mut self, event: ChatEvent) {
        let next_idx = self.chat.conversation.len();
        self.chat
            .conversation
            .push(item_from_chat_event(&event, next_idx));
        self.chat.events.push(event);
    }

    pub fn set_preview(&mut self, preview: PreviewInfo) {
        self.session.preview = Some(preview.clone());
        self.browser.preview = Some(preview);
    }

    pub fn mark_exited(&mut self, code: i32) {
        self.exited = true;
        self.exit_code = Some(code);

        if let Some(status) = self.status.as_mut() {
            status.phase = "exited".to_string();
            if code != 0 {
                status.health = "dead".to_string();
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn push_chat_event_builds_typed_conversation_item() {
        let session = ProjectSession {
            id: "s1".to_string(),
            name: "s1".to_string(),
            assistant: "claude".to_string(),
            branch: None,
            preview: None,
            reasoning_effort: None,
            cwd: None,
            started_at: None,
            last_activity_at: None,
            display_name: None,
        };
        let mut state = ProjectSessionState::new(session);
        state.push_chat_event(ChatEvent {
            role: "tool".to_string(),
            content: "running cargo test".to_string(),
            ts: "2026-05-18T00:00:00Z".to_string(),
            files: vec![],
        });
        assert_eq!(state.chat.events.len(), 1);
        assert_eq!(state.chat.conversation.len(), 1);
        let item = &state.chat.conversation[0];
        assert_eq!(item.role, "tool");
        assert_eq!(item.kind, "tool");
        assert_eq!(item.status, "running");
    }
}
