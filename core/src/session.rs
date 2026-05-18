use serde::{Deserialize, Serialize};

use super::{ChatEvent, ConversationItem, PreviewInfo, SessionStatus};

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
        if let Some(preview) = status.preview.clone() {
            self.session.preview = Some(preview.clone());
            self.browser.preview = Some(preview);
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
            .push(ConversationItem::from_chat_event(&event, next_idx));
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

impl ConversationItem {
    fn from_chat_event(event: &ChatEvent, idx: usize) -> Self {
        let role = normalized_role(&event.role);
        let kind = classify_kind(&role, &event.content);
        let status = classify_status(&event.content);
        Self {
            id: format!("{}-{}", event.ts, idx),
            role,
            kind,
            status,
            content: event.content.clone(),
            ts: event.ts.clone(),
            files: event.files.clone(),
        }
    }
}

fn normalized_role(role: &str) -> String {
    match role.to_ascii_lowercase().as_str() {
        "user" => "user".to_string(),
        "assistant" => "assistant".to_string(),
        "tool" => "tool".to_string(),
        _ => "system".to_string(),
    }
}

fn classify_kind(role: &str, content: &str) -> String {
    if looks_like_pending_input(content) {
        return "pending_input".to_string();
    }
    if role == "tool" {
        if looks_like_diff(content) {
            return "diff".to_string();
        }
        return "tool".to_string();
    }
    if role == "assistant" || role == "user" {
        return "message".to_string();
    }
    "system".to_string()
}

fn classify_status(content: &str) -> String {
    let lower = content.to_ascii_lowercase();
    if lower.contains("running") {
        "running".to_string()
    } else if lower.contains("failed") || lower.contains("error") || lower.contains("exception") {
        "failed".to_string()
    } else if lower.contains("pending") || lower.contains("waiting") {
        "pending".to_string()
    } else {
        "done".to_string()
    }
}

fn looks_like_diff(text: &str) -> bool {
    text.lines()
        .any(|line| line.starts_with('+') || line.starts_with('-') || line.starts_with("@@"))
}

fn looks_like_pending_input(text: &str) -> bool {
    let lower = text.to_ascii_lowercase();
    lower.contains("request_user_input")
        || (lower.contains("pending") && lower.contains("input"))
        || (lower.contains("select") && lower.contains("option"))
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

    #[test]
    fn tool_diff_becomes_diff_item() {
        let event = ChatEvent {
            role: "tool".to_string(),
            content: "@@ -1 +1 @@\n-old\n+new".to_string(),
            ts: "2026-05-18T00:00:00Z".to_string(),
            files: vec![],
        };
        let item = ConversationItem::from_chat_event(&event, 0);
        assert_eq!(item.kind, "diff");
    }

    #[test]
    fn pending_input_is_classified() {
        let event = ChatEvent {
            role: "assistant".to_string(),
            content: "request_user_input: please select one option".to_string(),
            ts: "2026-05-18T00:00:00Z".to_string(),
            files: vec![],
        };
        let item = ConversationItem::from_chat_event(&event, 0);
        assert_eq!(item.kind, "pending_input");
    }
}
