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

// Not `Eq`: total_cost_usd is an f64 (cost has no exact integer form).
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
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
    /// Per-agent reasoning effort ("low" / "medium" / "high") read
    /// from the agent toml. The pill in the project header tracks
    /// this so users can see what they're paying for at a glance.
    #[serde(default)]
    pub reasoning_effort: Option<String>,
    /// Absolute working directory the agent was spawned into.
    #[serde(default)]
    pub cwd: Option<String>,
    /// RFC3339Nano timestamp the harness session was created.
    #[serde(default)]
    pub started_at: Option<String>,
    /// RFC3339Nano timestamp of the most recent PTY byte from the
    /// agent. Useful for "last seen N min ago" in the info sheet.
    #[serde(default)]
    pub last_activity_at: Option<String>,
    /// Human-readable session label set by `rename_session` (protocol
    /// §3.3). Mirrors `session_name` over the wire; carried as a
    /// separate field so UIs can prefer the user-supplied label while
    /// keeping the original `session.name` (typically the workspace
    /// folder) intact for path display.
    #[serde(default)]
    pub display_name: Option<String>,
    /// Per-session token/cost usage (cumulative across turns) + a
    /// point-in-time context gauge. Populated from each turn's usage event
    /// (claude `result` / codex `turn.completed`). `total_cost_usd` and
    /// `context_window_tokens` are claude-only (codex reports neither).
    #[serde(default)]
    pub total_input_tokens: Option<u64>,
    #[serde(default)]
    pub total_output_tokens: Option<u64>,
    #[serde(default)]
    pub total_cached_tokens: Option<u64>,
    #[serde(default)]
    pub total_cost_usd: Option<f64>,
    /// The latest turn's prompt size (input + cached) — current context
    /// occupancy, not a lifetime sum.
    #[serde(default)]
    pub context_used_tokens: Option<u64>,
    /// The model's max context window (e.g. 1_000_000), for the % gauge.
    #[serde(default)]
    pub context_window_tokens: Option<u64>,
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
/// Stringly-typed `role`/`kind`/`status` for cheap UniFFI evolution; the
/// optional structured fields are populated by `crate::conversation` and
/// let the platform tool-call / diff / pending-input cards render without
/// re-parsing the content blob.
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
    #[serde(default)]
    pub tool_name: Option<String>,
    #[serde(default)]
    pub command: Option<String>,
    #[serde(default)]
    pub exit_code: Option<i32>,
    #[serde(default)]
    pub duration_ms: Option<u64>,
    #[serde(default)]
    pub diff_summary: Option<String>,
    /// Detected reply options for `kind == "pending_input"` items —
    /// numbered menus ("1. Yes / 2. No"), bullet lists, Codex
    /// "[A]pprove / [E]dit / [R]eject", etc. Empty when no menu detected.
    #[serde(default)]
    pub pending_options: Vec<String>,
}
