//! View-facing data types carried across the UniFFI boundary into the apps.
//!
//! These records stay deliberately flat because UniFFI codegen is much easier
//! to keep stable with dictionaries than with richer tagged enums.

#[path = "session.rs"]
mod session;

pub use session::{
    BrowserViewState, ChatViewState, ProjectSession, ProjectSessionState, TerminalViewState,
};

use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct ViewEventFile {
    pub path: String,
    pub rev: String,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct PreviewInfo {
    pub port: u16,
    pub url: String,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct SessionStatus {
    pub session: String,
    pub assistant: String,
    pub phase: String,
    pub health: String,
    pub rows: u16,
    pub cols: u16,
    pub yolo: bool,
    pub preview: Option<PreviewInfo>,
    pub session_name: Option<String>,
    pub viewers: Option<u32>,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct ChatEvent {
    pub role: String,
    pub content: String,
    pub ts: String,
    #[serde(default)]
    pub files: Vec<ViewEventFile>,
}

/// Shared typed chat timeline record used by both mobile shells.
///
/// This is intentionally flat (stringly-typed role/kind/status) to keep
/// UniFFI evolution simple while we migrate away from raw event rendering.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct ConversationItem {
    pub id: String,
    pub role: String,
    pub kind: String,
    pub status: String,
    pub content: String,
    pub ts: String,
    #[serde(default)]
    pub files: Vec<ViewEventFile>,
}
