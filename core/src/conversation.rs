//! Classifier that turns raw `ChatEvent`s into typed `ConversationItem`s.
//!
//! Lives in its own module so the platform layers can stay thin: the iOS and
//! Android renderers consume the typed item directly instead of re-parsing
//! the same patterns twice. New agent dialects (Codex menus, Claude tool
//! prompts, etc.) get a single place to extend.

use crate::views::{ChatEvent, ConversationItem};

/// Build a typed conversation item from a chat event.
///
/// `idx` is the position in the conversation so items get stable ids even
/// when timestamps collide.
pub fn item_from_chat_event(event: &ChatEvent, idx: usize) -> ConversationItem {
    let role = normalized_role(&event.role);
    let tool_name = extract_tool_name(&event.content);
    let command = extract_command(&event.content);
    let exit_code = extract_exit_code(&event.content);
    let duration_ms = extract_duration_ms(&event.content);
    let diff_summary = if looks_like_diff(&event.content) {
        Some(summarize_diff(&event.content))
    } else {
        None
    };
    let kind = classify_kind(&role, &event.content, diff_summary.is_some());
    let status = classify_status(&event.content, exit_code);

    ConversationItem {
        id: format!("{}-{}", event.ts, idx),
        role,
        kind,
        status,
        content: event.content.clone(),
        ts: event.ts.clone(),
        files: event.files.clone(),
        tool_name,
        command,
        exit_code,
        duration_ms,
        diff_summary,
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

fn classify_kind(role: &str, content: &str, has_diff: bool) -> String {
    if looks_like_pending_input(content) {
        return "pending_input".to_string();
    }
    if looks_like_handoff(content) {
        return "handoff".to_string();
    }
    if looks_like_subagent(content) {
        return "subagent".to_string();
    }
    if role == "tool" {
        if has_diff {
            return "diff".to_string();
        }
        return "tool".to_string();
    }
    if role == "assistant" || role == "user" {
        return "message".to_string();
    }
    "system".to_string()
}

fn classify_status(content: &str, exit_code: Option<i32>) -> String {
    if let Some(code) = exit_code {
        return if code == 0 {
            "done".to_string()
        } else {
            "failed".to_string()
        };
    }
    let lower = content.to_ascii_lowercase();
    if lower.contains("running") || lower.contains("in progress") {
        "running".to_string()
    } else if lower.contains("failed") || lower.contains("error") || lower.contains("exception") {
        "failed".to_string()
    } else if lower.contains("pending") || lower.contains("waiting") || lower.contains("awaiting") {
        "pending".to_string()
    } else {
        "done".to_string()
    }
}

fn extract_exit_code(content: &str) -> Option<i32> {
    for raw in content.lines() {
        let line = raw.trim().to_ascii_lowercase();
        for prefix in ["exit code:", "exit code =", "exit=", "exit:"] {
            if let Some(rest) = line.strip_prefix(prefix) {
                let cleaned = rest.trim().trim_end_matches(['.', ',']).trim();
                if let Ok(code) = cleaned.parse::<i32>() {
                    return Some(code);
                }
            }
        }
    }
    None
}

fn extract_duration_ms(content: &str) -> Option<u64> {
    for raw in content.lines() {
        let line = raw.trim().to_ascii_lowercase();
        for prefix in ["duration:", "elapsed:", "took:"] {
            if let Some(rest) = line.strip_prefix(prefix) {
                if let Some(ms) = parse_duration(rest.trim()) {
                    return Some(ms);
                }
            }
        }
    }
    None
}

fn parse_duration(text: &str) -> Option<u64> {
    let cleaned = text.trim().trim_end_matches(['.', ',']);
    if let Some(num) = cleaned.strip_suffix("ms") {
        return num.trim().parse::<u64>().ok();
    }
    if let Some(num) = cleaned.strip_suffix('s') {
        let secs: f64 = num.trim().parse().ok()?;
        return Some((secs * 1000.0) as u64);
    }
    if let Some(num) = cleaned.strip_suffix("min") {
        let mins: f64 = num.trim().parse().ok()?;
        return Some((mins * 60_000.0) as u64);
    }
    cleaned.parse::<u64>().ok()
}

fn extract_command(content: &str) -> Option<String> {
    for raw in content.lines() {
        let line = raw.trim();
        let lower = line.to_ascii_lowercase();
        for prefix in ["running:", "running ", "command:", "$ ", "exec:", "bash:"] {
            if let Some(rest) = lower.strip_prefix(prefix) {
                // recover the original (non-lowercased) tail so command stays accurate
                let original_start = line.len() - rest.len();
                let cmd = line[original_start..].trim().trim_matches('`');
                if !cmd.is_empty() {
                    return Some(cmd.to_string());
                }
            }
        }
    }
    None
}

fn extract_tool_name(content: &str) -> Option<String> {
    // Match leading "<ToolName>:" on the first non-empty line — covers the
    // common "Bash: ls -la", "Edit: src/foo.rs", "Write: …" shapes the
    // Claude Code TUI emits.
    for raw in content.lines() {
        let line = raw.trim();
        if line.is_empty() {
            continue;
        }
        if let Some(colon) = line.find(':') {
            let head = &line[..colon];
            if is_plausible_tool_name(head) {
                return Some(head.to_string());
            }
        }
        return None;
    }
    None
}

fn is_plausible_tool_name(s: &str) -> bool {
    if s.is_empty() || s.len() > 32 {
        return false;
    }
    let first = s.chars().next().unwrap();
    if !first.is_ascii_uppercase() {
        return false;
    }
    s.chars().all(|c| c.is_ascii_alphanumeric() || c == '_')
}

fn looks_like_diff(text: &str) -> bool {
    let mut saw_diff_marker = false;
    for line in text.lines() {
        if line.starts_with("@@") || line.starts_with("diff --git") || line.starts_with("--- ") {
            saw_diff_marker = true;
        }
        if line.starts_with('+') && !line.starts_with("+++") {
            saw_diff_marker = true;
        }
    }
    saw_diff_marker
}

fn summarize_diff(text: &str) -> String {
    let mut files: u32 = 0;
    let mut added: u32 = 0;
    let mut removed: u32 = 0;
    for line in text.lines() {
        if line.starts_with("diff --git") || line.starts_with("+++ ") {
            files += 1;
        } else if line.starts_with('+') && !line.starts_with("+++") {
            added += 1;
        } else if line.starts_with('-') && !line.starts_with("---") {
            removed += 1;
        }
    }
    if files == 0 {
        files = 1;
    }
    format!(
        "{} file{}, +{} -{}",
        files,
        if files == 1 { "" } else { "s" },
        added,
        removed
    )
}

fn looks_like_pending_input(text: &str) -> bool {
    let lower = text.to_ascii_lowercase();
    if lower.contains("request_user_input") {
        return true;
    }
    if lower.contains("pending") && lower.contains("input") {
        return true;
    }
    if lower.contains("select") && (lower.contains("option") || lower.contains("choice")) {
        return true;
    }
    // Approval prompts: "[A]pprove [E]dit [R]eject" (Codex), "Yes/No" (Claude)
    if lower.contains("[a]pprove") || lower.contains("approve / edit / reject") {
        return true;
    }
    // Numbered menu: "1. Yes\n2. No"
    let mut numbered = 0;
    for line in text.lines() {
        let trimmed = line.trim_start();
        if trimmed
            .chars()
            .next()
            .map(|c| c.is_ascii_digit())
            .unwrap_or(false)
            && trimmed.contains(". ")
        {
            numbered += 1;
        }
    }
    numbered >= 2
}

fn looks_like_handoff(text: &str) -> bool {
    let lower = text.to_ascii_lowercase();
    (lower.contains("handing off") || lower.contains("handoff")) && lower.contains("to ")
}

fn looks_like_subagent(text: &str) -> bool {
    let lower = text.to_ascii_lowercase();
    lower.contains("subagent") || lower.contains("sub-agent") || lower.contains("spawning agent")
}

#[cfg(test)]
mod tests {
    use super::*;

    fn ev(role: &str, content: &str) -> ChatEvent {
        ChatEvent {
            role: role.to_string(),
            content: content.to_string(),
            ts: "2026-05-19T00:00:00Z".to_string(),
            files: vec![],
        }
    }

    #[test]
    fn message_from_assistant() {
        let item = item_from_chat_event(&ev("assistant", "Hello there"), 0);
        assert_eq!(item.kind, "message");
        assert_eq!(item.role, "assistant");
        assert_eq!(item.status, "done");
        assert!(item.command.is_none());
    }

    #[test]
    fn tool_call_with_command_and_exit_zero() {
        let item = item_from_chat_event(
            &ev("tool", "running: cargo test --workspace\nexit code: 0"),
            0,
        );
        assert_eq!(item.kind, "tool");
        assert_eq!(item.status, "done");
        assert_eq!(item.command.as_deref(), Some("cargo test --workspace"));
        assert_eq!(item.exit_code, Some(0));
    }

    #[test]
    fn tool_call_with_named_tool() {
        let item = item_from_chat_event(&ev("tool", "Bash: ls -la /tmp\nexit=0"), 0);
        assert_eq!(item.tool_name.as_deref(), Some("Bash"));
        // command extractor doesn't strip the tool prefix; the platform card
        // typically renders tool_name + content separately
    }

    #[test]
    fn non_zero_exit_is_failed() {
        let item = item_from_chat_event(&ev("tool", "$ make test\nexit code: 2"), 0);
        assert_eq!(item.status, "failed");
        assert_eq!(item.exit_code, Some(2));
    }

    #[test]
    fn diff_classified_with_summary() {
        let item = item_from_chat_event(
            &ev(
                "tool",
                "diff --git a/foo.rs b/foo.rs\n@@ -1 +1 @@\n-old\n+new\n+also new",
            ),
            0,
        );
        assert_eq!(item.kind, "diff");
        assert_eq!(item.diff_summary.as_deref(), Some("1 file, +2 -1"));
    }

    #[test]
    fn pending_input_request_user_input() {
        let item = item_from_chat_event(&ev("assistant", "request_user_input: please pick"), 0);
        assert_eq!(item.kind, "pending_input");
    }

    #[test]
    fn pending_input_numbered_menu() {
        let item = item_from_chat_event(
            &ev("assistant", "1. Yes\n2. Yes, don't ask again\n3. No"),
            0,
        );
        assert_eq!(item.kind, "pending_input");
    }

    #[test]
    fn pending_input_codex_approval() {
        let item = item_from_chat_event(&ev("assistant", "[A]pprove / [E]dit / [R]eject"), 0);
        assert_eq!(item.kind, "pending_input");
    }

    #[test]
    fn handoff_classified() {
        let item = item_from_chat_event(
            &ev("system", "Handing off to codex: I finished the refactor"),
            0,
        );
        assert_eq!(item.kind, "handoff");
    }

    #[test]
    fn subagent_classified() {
        let item = item_from_chat_event(
            &ev("system", "Spawning agent for parallel investigation"),
            0,
        );
        assert_eq!(item.kind, "subagent");
    }

    #[test]
    fn duration_extraction_seconds() {
        let item = item_from_chat_event(
            &ev("tool", "command: cargo build\nduration: 3.5s\nexit=0"),
            0,
        );
        assert_eq!(item.duration_ms, Some(3500));
    }

    #[test]
    fn duration_extraction_ms() {
        let item = item_from_chat_event(&ev("tool", "command: ls\nelapsed: 42ms\nexit=0"), 0);
        assert_eq!(item.duration_ms, Some(42));
    }

    #[test]
    fn unknown_role_becomes_system() {
        let item = item_from_chat_event(&ev("watchdog", "stall detected"), 0);
        assert_eq!(item.role, "system");
        assert_eq!(item.kind, "system");
    }
}
