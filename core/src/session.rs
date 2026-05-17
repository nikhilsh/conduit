use serde::{Deserialize, Serialize};

use super::{ChatEvent, PreviewInfo, SessionStatus};

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
