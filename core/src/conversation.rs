//! Classifier that turns raw `ChatEvent`s into typed `ConversationItem`s.
//!
//! Lives in its own module so the platform layers can stay thin: the iOS and
//! Android renderers consume the typed item directly instead of re-parsing
//! the same patterns twice. New agent dialects (Codex menus, Claude tool
//! prompts, etc.) get a single place to extend.

use crate::views::{ChatEvent, ConversationItem, PlanStep};

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
    let kind = classify_kind(
        &role,
        &event.content,
        diff_summary.is_some(),
        tool_name.as_deref(),
    );
    let status = classify_status(&event.content, exit_code);
    // Strip the internal pending-input sentinel from the user-visible
    // content (it's only a classification signal); the apps then never
    // need to know about it.
    let display_content = strip_pending_sentinel(&event.content);
    let pending_options = if kind == "pending_input" {
        extract_pending_options(&display_content)
    } else {
        Vec::new()
    };

    // Tier 1: handoff from→to / TASK / result, parsed from `content` only
    // when the item is classified as a handoff. Left None otherwise.
    let handoff = if kind == "handoff" {
        parse_handoff(&event.content)
    } else {
        HandoffParts::default()
    };

    // Tier 3: parse the checklist when the item is a plan.
    let plan_steps = if kind == "plan" {
        parse_plan_steps(&event.content)
    } else {
        Vec::new()
    };

    ConversationItem {
        id: format!("{}-{}", event.ts, idx),
        role,
        kind,
        status,
        content: display_content,
        ts: event.ts.clone(),
        files: event.files.clone(),
        tool_name,
        command,
        exit_code,
        duration_ms,
        diff_summary,
        pending_options,
        source_agent: handoff.source,
        target_agent: handoff.target,
        task_text: handoff.task,
        result_summary: handoff.result,
        plan_steps,
    }
}

fn extract_pending_options(text: &str) -> Vec<String> {
    let mut opts: Vec<String> = Vec::new();
    let mut push = |s: &str| {
        let trimmed = s.trim().trim_matches(['.', ',', ' ', '`']).to_string();
        if trimmed.is_empty() {
            return;
        }
        if !opts.iter().any(|o| o.eq_ignore_ascii_case(&trimmed)) {
            opts.push(trimmed);
        }
    };

    for raw in text.lines() {
        let line = raw.trim();
        if line.is_empty() {
            continue;
        }

        // Numbered menu: "1. Yes" / "2) No"
        if let Some(rest) = strip_numbered_prefix(line) {
            push(rest);
            continue;
        }

        // Bullet list: "- option" / "* option"
        if let Some(rest) = line.strip_prefix("- ").or_else(|| line.strip_prefix("* ")) {
            push(rest);
            continue;
        }

        // "option: foo" / "choice: foo"
        let lower = line.to_ascii_lowercase();
        for prefix in ["option:", "choice:"] {
            if let Some(rest) = lower.strip_prefix(prefix) {
                let orig_start = line.len() - rest.len();
                push(&line[orig_start..]);
            }
        }

        // Codex-style "[A]pprove / [E]dit / [R]eject"
        if line.contains("[A]") || line.contains("[E]") || line.contains("[R]") {
            for part in line.split('/') {
                let cleaned = part.trim();
                if cleaned.starts_with('[') {
                    push(cleaned);
                }
            }
        }
    }

    opts.truncate(8);
    opts
}

fn strip_numbered_prefix(line: &str) -> Option<&str> {
    let mut end = 0;
    let mut saw_digit = false;
    for (i, c) in line.char_indices() {
        if c.is_ascii_digit() {
            saw_digit = true;
            end = i + c.len_utf8();
            continue;
        }
        if !saw_digit {
            return None;
        }
        // Accept "N. " or "N) "
        if c == '.' || c == ')' {
            let after = &line[end + c.len_utf8()..];
            if let Some(stripped) = after.strip_prefix(' ') {
                return Some(stripped);
            }
            if after.is_empty() {
                return Some("");
            }
            return None;
        }
        return None;
    }
    None
}

fn normalized_role(role: &str) -> String {
    match role.to_ascii_lowercase().as_str() {
        "user" => "user".to_string(),
        "assistant" => "assistant".to_string(),
        "tool" => "tool".to_string(),
        _ => "system".to_string(),
    }
}

fn classify_kind(role: &str, content: &str, has_diff: bool, tool_name: Option<&str>) -> String {
    if looks_like_pending_input(content) {
        return "pending_input".to_string();
    }
    if looks_like_plan(content, tool_name) {
        return "plan".to_string();
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
    // Tier 3: a transient agent-swap state that precedes "running". Only
    // emitted for unambiguous swap phrasing; everything else falls through
    // to the existing vocabulary unchanged.
    if looks_like_swapping(&lower) {
        "swapping".to_string()
    } else if lower.contains("running") || lower.contains("in progress") {
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

/// The deterministic marker the broker prepends to a GENUINE interactive
/// question (a real AskUserQuestion tool call, where the agent is actually
/// blocked waiting). Byte-identical to the broker's `pendingInputSentinel`.
/// The apps strip it before display.
pub const PENDING_INPUT_SENTINEL: &str = "[[conduit:needs-input]]";

/// Remove the leading pending-input sentinel line (and any stray
/// occurrences) from content destined for display. No-op when absent.
fn strip_pending_sentinel(text: &str) -> String {
    if !text.contains(PENDING_INPUT_SENTINEL) {
        return text.to_string();
    }
    text.lines()
        .filter(|line| line.trim() != PENDING_INPUT_SENTINEL)
        .collect::<Vec<_>>()
        .join("\n")
}

/// Whether a chat message is a genuine "needs your input" prompt — the
/// agent is BLOCKED waiting on the user.
///
/// Decided ONLY by explicit, deterministic markers, never by guessing
/// from text shape. The old heuristics (`select`+`option/choice` anywhere,
/// or any two short numbered lines) produced both failures the user hit
/// (device feedback, round 4): assistant prose merely *discussing* options
/// rendered as a "NEEDS YOUR INPUT" card, and a prose numbered question
/// implied the agent was blocked when it had ended its turn — only the
/// AskUserQuestion *tool* blocks (via the broker's control protocol). So a
/// card now means the agent is genuinely waiting: true iff the broker
/// tagged it (AskUserQuestion sentinel) or it's a real codex approval
/// prompt. Plain numbered / "select" prose renders as a normal message.
fn looks_like_pending_input(text: &str) -> bool {
    if text.contains(PENDING_INPUT_SENTINEL) {
        return true;
    }
    let lower = text.to_ascii_lowercase();
    // Legacy explicit marker some adapters emit.
    if lower.contains("request_user_input") {
        return true;
    }
    // Codex approval prompts: a real blocked state with a distinctive,
    // non-prose shape (no AskUserQuestion tool on that path). The multi-
    // select " (select all that apply)" marker no longer needs its own
    // rule — every AskUserQuestion (single- AND multi-select) now carries
    // the deterministic sentinel handled above.
    if lower.contains("[a]pprove") || lower.contains("approve / edit / reject") {
        return true;
    }
    false
}

fn looks_like_handoff(text: &str) -> bool {
    let lower = text.to_ascii_lowercase();
    (lower.contains("handing off") || lower.contains("handoff")) && lower.contains("to ")
}

/// Mirror of the client `isNeonPlanShaped` gate (Android `NeonComponents.kt`,
/// iOS `ConduitChatView`): a tool name containing "todo"/"plan", or content
/// with a markdown checkbox line (`- [ ]` / `- [x]`). Kept in lock-step so
/// core and the shells agree on what counts as a plan.
fn looks_like_plan(content: &str, tool_name: Option<&str>) -> bool {
    if let Some(name) = tool_name {
        let lower = name.to_ascii_lowercase();
        if lower.contains("todo") || lower.contains("plan") {
            return true;
        }
    }
    content.lines().any(|line| checkbox_state(line).is_some())
}

/// Parse the `state` of a markdown checkbox line, returning the rest of the
/// line as the step text. `[x]`/`[X]` → done, `[ ]` → todo. Returns `None`
/// for non-checkbox lines.
fn checkbox_state(line: &str) -> Option<(&'static str, &str)> {
    let trimmed = line.trim_start();
    let rest = trimmed
        .strip_prefix("- ")
        .or_else(|| trimmed.strip_prefix("* "))
        .or_else(|| trimmed.strip_prefix('-'))
        .or_else(|| trimmed.strip_prefix('*'))?;
    let rest = rest.trim_start();
    let inner = rest.strip_prefix('[')?;
    let mark = inner.chars().next()?;
    let after = inner.strip_prefix(mark)?.strip_prefix(']')?;
    let state = match mark {
        'x' | 'X' => "done",
        ' ' => "todo",
        _ => return None,
    };
    Some((state, after.trim()))
}

fn parse_plan_steps(content: &str) -> Vec<PlanStep> {
    content
        .lines()
        .filter_map(checkbox_state)
        .filter(|(_, text)| !text.is_empty())
        .map(|(state, text)| PlanStep {
            text: text.to_string(),
            state: state.to_string(),
        })
        .collect()
}

/// True for unambiguous agent-swap phrasing. Deliberately narrow so it
/// doesn't shadow the generic running/done states for ordinary content.
fn looks_like_swapping(lower: &str) -> bool {
    lower.contains("swapping agent")
        || lower.contains("swapping to ")
        || lower.contains("swapping in ")
        || lower.contains("switching agent")
        || lower.contains("agent swap")
}

#[derive(Default)]
struct HandoffParts {
    source: Option<String>,
    target: Option<String>,
    task: Option<String>,
    result: Option<String>,
}

/// Best-effort parse of a `handoff` item's structured fields from `content`.
///
/// Two shapes are supported and combined:
///   * The HANDOFF-OUT brief HTML (`data-section="handoff"`): `From: X` /
///     `To: Y` lines drive source/target, and the `handoff-body` text
///     becomes `result`.
///   * Free-text "… to Y: <instruction>" phrasing: `target` is the first
///     word after " to ", `source` is the first word of the message when it
///     reads like an agent name, and the post-colon tail is the `task`.
fn parse_handoff(content: &str) -> HandoffParts {
    let mut parts = HandoffParts::default();

    // Structured HANDOFF-OUT brief, if present.
    for raw in content.lines() {
        let line = strip_tags(raw);
        let lower = line.to_ascii_lowercase();
        if parts.source.is_none() {
            if let Some(rest) = lower.strip_prefix("from:") {
                let name = first_agent_word(&line[line.len() - rest.len()..]);
                if !name.is_empty() {
                    parts.source = Some(name);
                }
            }
        }
        if parts.target.is_none() {
            if let Some(rest) = lower.strip_prefix("to:") {
                let name = first_agent_word(&line[line.len() - rest.len()..]);
                if !name.is_empty() {
                    parts.target = Some(name);
                }
            }
        }
    }
    if content.contains("data-section=\"handoff\"")
        || content.contains("data-fill=\"handoff-body\"")
    {
        if let Some(body) = extract_handoff_body(content) {
            parts.result = Some(body);
        }
    }

    // Free-text "X … to Y: <task>" fallback for fields not already filled.
    if parts.target.is_none() {
        if let Some(r) = content.to_ascii_lowercase().find(" to ") {
            let name = first_agent_word(&content[r + 4..]);
            if !name.is_empty() {
                parts.target = Some(name);
            }
        }
    }
    if parts.source.is_none() {
        let first = first_agent_word(content);
        // Skip the leading verb in "Handing off to …" style messages.
        if !first.is_empty() && !is_handoff_verb(&first) {
            parts.source = Some(first);
        }
    }
    // Only parse a free-text TASK when this isn't an HTML brief: a brief's
    // body prose can contain incidental " to " phrases that would yield a
    // bogus task. A brief carries its detail in `result` instead.
    if parts.task.is_none() && parts.result.is_none() {
        if let Some(task) = task_after_target(content) {
            parts.task = Some(task);
        }
    }

    parts
}

/// First identifier-ish token (letters/digits/-/_) of `s`, skipping any
/// leading non-alphanumeric noise. Mirrors the iOS `firstWord` helper.
fn first_agent_word(s: &str) -> String {
    s.chars()
        .skip_while(|c| !(c.is_ascii_alphanumeric()))
        .take_while(|c| c.is_ascii_alphanumeric() || *c == '-' || *c == '_')
        .collect()
}

fn is_handoff_verb(word: &str) -> bool {
    matches!(
        word.to_ascii_lowercase().as_str(),
        "handing" | "handoff" | "handoff-out" | "switching" | "swapping"
    )
}

/// The delegated instruction: text after the first colon that follows the
/// " to <target>" phrase. `None` when there is no such colon or it is empty.
fn task_after_target(content: &str) -> Option<String> {
    let lower = content.to_ascii_lowercase();
    let to_pos = lower.find(" to ")?;
    let after_to = &content[to_pos + 4..];
    let colon = after_to.find(':')?;
    let tail = after_to[colon + 1..].trim();
    if tail.is_empty() {
        None
    } else {
        Some(tail.to_string())
    }
}

/// Extract the human text of the `<section data-section="handoff">` (or its
/// `handoff-body`) with tags removed and whitespace collapsed.
fn extract_handoff_body(content: &str) -> Option<String> {
    let start = content
        .find("data-fill=\"handoff-body\"")
        .or_else(|| content.find("data-section=\"handoff\""))?;
    let region = &content[start..];
    // Stop at the closing section/div tag when present so we don't sweep in
    // unrelated trailing markup.
    let end = region
        .find("</section>")
        .or_else(|| region.rfind("</div>"))
        .unwrap_or(region.len());
    let text = strip_tags(&region[..end]);
    let collapsed = text.split_whitespace().collect::<Vec<_>>().join(" ");
    if collapsed.is_empty() {
        None
    } else {
        Some(collapsed)
    }
}

/// Remove HTML tags from a line, leaving the text content.
fn strip_tags(line: &str) -> String {
    let mut out = String::with_capacity(line.len());
    let mut in_tag = false;
    for c in line.chars() {
        match c {
            '<' => in_tag = true,
            '>' => in_tag = false,
            _ if !in_tag => out.push(c),
            _ => {}
        }
    }
    out.trim().to_string()
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

    /// A bare numbered list in PROSE is NO LONGER a pending-input card.
    /// The agent isn't blocked — it just wrote a list. (Deterministic
    /// fix: cards come only from the broker sentinel / real approvals.)
    #[test]
    fn bare_numbered_prose_is_a_message_not_pending() {
        let item = item_from_chat_event(
            &ev("assistant", "1. Yes\n2. Yes, don't ask again\n3. No"),
            0,
        );
        assert_eq!(item.kind, "message");
    }

    /// The false-positive the user hit: prose DISCUSSING options must not
    /// render as a needs-input card.
    #[test]
    fn prose_mentioning_select_options_is_not_pending() {
        let item = item_from_chat_event(
            &ev(
                "assistant",
                "the multi-select options rendered as plain text instead of tappable choices",
            ),
            0,
        );
        assert_eq!(item.kind, "message");
    }

    #[test]
    fn pending_input_codex_approval() {
        let item = item_from_chat_event(&ev("assistant", "[A]pprove / [E]dit / [R]eject"), 0);
        assert_eq!(item.kind, "pending_input");
    }

    /// The exact shape the broker emits for an AskUserQuestion tool_use
    /// (broker/internal/session/claudechat.go askUserQuestionContent):
    /// the sentinel line + question + numbered menu must classify as
    /// pending_input, expose the labels as options, and the sentinel must
    /// be STRIPPED from the displayed content.
    #[test]
    fn pending_input_ask_user_question_broker_shape() {
        let item = item_from_chat_event(
            &ev(
                "assistant",
                "[[conduit:needs-input]]\nProceed with the merge?\n1. Merge now\n2. Hold off",
            ),
            0,
        );
        assert_eq!(item.kind, "pending_input");
        assert_eq!(item.pending_options, vec!["Merge now", "Hold off"]);
        assert!(
            !item.content.contains(PENDING_INPUT_SENTINEL),
            "sentinel must be stripped from display content: {:?}",
            item.content
        );
        assert!(item.content.starts_with("Proceed with the merge?"));
    }

    /// A multi-select AskUserQuestion (with descriptive labels) classifies
    /// via the broker's deterministic sentinel — even though its labels are
    /// long and the question merely says "(select all that apply)". The
    /// options are extracted as tappable choices.
    #[test]
    fn pending_input_multiselect_via_sentinel() {
        let item = item_from_chat_event(
            &ev(
                "assistant",
                "[[conduit:needs-input]]\n\
                 Which fixes should I implement next? (select all that apply)\n\
                 1. Fix the non-destructive working-tree checkpoint snapshot mechanism\n\
                 2. Garbage-collect the accumulated dead checkpoint stashes from the repo",
            ),
            0,
        );
        assert_eq!(item.kind, "pending_input");
        assert_eq!(item.pending_options.len(), 2);
    }

    /// The SAME multi-select question text WITHOUT the broker sentinel —
    /// i.e. the agent wrote it as prose — is now a plain message (the
    /// "(select all that apply)" phrase alone no longer fabricates a card).
    #[test]
    fn prose_select_all_that_apply_is_message() {
        let item = item_from_chat_event(
            &ev(
                "assistant",
                "Which fixes should I implement next? (select all that apply)\n\
                 1. Fix the checkpoint mechanism\n2. GC dead stashes",
            ),
            0,
        );
        assert_eq!(item.kind, "message");
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

    #[test]
    fn pending_options_numbered_menu() {
        let item = item_from_chat_event(
            &ev(
                "assistant",
                "[[conduit:needs-input]]\nWhich one?\n1. Yes\n2. Yes, don't ask again\n3. No",
            ),
            0,
        );
        assert_eq!(item.kind, "pending_input");
        assert_eq!(
            item.pending_options,
            vec![
                "Yes".to_string(),
                "Yes, don't ask again".to_string(),
                "No".to_string()
            ]
        );
    }

    #[test]
    fn pending_options_bullets() {
        let item = item_from_chat_event(
            &ev(
                "assistant",
                "request_user_input: pick one\n- Run\n- Skip\n- Cancel",
            ),
            0,
        );
        assert_eq!(
            item.pending_options,
            vec!["Run".to_string(), "Skip".to_string(), "Cancel".to_string()]
        );
    }

    #[test]
    fn pending_options_codex_approval() {
        let item = item_from_chat_event(&ev("assistant", "[A]pprove / [E]dit / [R]eject"), 0);
        assert!(item.pending_options.iter().any(|o| o.contains("[A]")));
        assert!(item.pending_options.iter().any(|o| o.contains("[E]")));
        assert!(item.pending_options.iter().any(|o| o.contains("[R]")));
    }

    #[test]
    fn pending_options_empty_when_not_pending() {
        let item = item_from_chat_event(&ev("assistant", "Just a message"), 0);
        assert!(item.pending_options.is_empty());
    }

    #[test]
    fn pending_input_ignores_prose_mentioning_pending_and_input() {
        // Regression (device feedback): an ordinary explanation that happens to
        // mention the identifier `dropPendingInputEchoes` (substrings "pending" +
        // "input") and uses a long numbered list must NOT become a pending-input
        // card with bogus tappable options.
        let content = "Two key clarifications:\n\
            1. `dropPendingInputEchoes` doesn't exist anywhere in the code or history, so the frame names are mis-symbolicated.\n\
            2. The latest hang is on 0.0.115, so it's current.";
        let item = item_from_chat_event(&ev("assistant", content), 0);
        assert_eq!(item.kind, "message");
        assert!(item.pending_options.is_empty());
    }

    #[test]
    fn handoff_free_text_source_target_task() {
        let item = item_from_chat_event(
            &ev(
                "system",
                "claude handing off to codex: finish wiring session.rs to transport",
            ),
            0,
        );
        assert_eq!(item.kind, "handoff");
        assert_eq!(item.source_agent.as_deref(), Some("claude"));
        assert_eq!(item.target_agent.as_deref(), Some("codex"));
        assert_eq!(
            item.task_text.as_deref(),
            Some("finish wiring session.rs to transport")
        );
        assert!(item.result_summary.is_none());
    }

    #[test]
    fn handoff_skips_leading_verb_as_source() {
        // "Handing off to codex: …" — first word is the verb, not an agent.
        let item = item_from_chat_event(
            &ev("system", "Handing off to codex: I finished the refactor"),
            0,
        );
        assert_eq!(item.kind, "handoff");
        assert!(item.source_agent.is_none());
        assert_eq!(item.target_agent.as_deref(), Some("codex"));
        assert_eq!(item.task_text.as_deref(), Some("I finished the refactor"));
    }

    #[test]
    fn handoff_html_brief_result_and_agents() {
        let content = r#"Handoff brief
<section data-section="handoff">
  <p data-fill="handoff-from">From: claude</p>
  <p data-fill="handoff-to">To: codex</p>
  <div data-fill="handoff-body"><p>Finished transport.rs; next was going to wire session.rs to it. Watch the ping/pong timer.</p></div>
</section>"#;
        let item = item_from_chat_event(&ev("system", content), 0);
        assert_eq!(item.kind, "handoff");
        assert_eq!(item.source_agent.as_deref(), Some("claude"));
        assert_eq!(item.target_agent.as_deref(), Some("codex"));
        // The brief's body becomes the result; the incidental " to " inside
        // "going to wire" must NOT leak into task_text.
        assert!(item.task_text.is_none());
        let result = item.result_summary.expect("result parsed");
        assert!(result.contains("Finished transport.rs"));
        assert!(result.contains("ping/pong timer"));
    }

    #[test]
    fn plan_kind_from_checkbox_list() {
        let item = item_from_chat_event(
            &ev(
                "assistant",
                "Plan:\n- [x] scaffold module\n- [ ] wire the classifier\n* [ ] write tests",
            ),
            0,
        );
        assert_eq!(item.kind, "plan");
        assert_eq!(item.plan_steps.len(), 3);
        assert_eq!(item.plan_steps[0].text, "scaffold module");
        assert_eq!(item.plan_steps[0].state, "done");
        assert_eq!(item.plan_steps[1].text, "wire the classifier");
        assert_eq!(item.plan_steps[1].state, "todo");
        assert_eq!(item.plan_steps[2].state, "todo");
    }

    #[test]
    fn plan_kind_from_tool_name() {
        let item = item_from_chat_event(&ev("tool", "TodoWrite: updating the task list"), 0);
        assert_eq!(item.kind, "plan");
        // No checkbox lines → no parsed steps, but still classified as a plan.
        assert!(item.plan_steps.is_empty());
    }

    #[test]
    fn non_plan_has_empty_plan_steps() {
        let item = item_from_chat_event(&ev("assistant", "- a plain bullet\n- another"), 0);
        assert_ne!(item.kind, "plan");
        assert!(item.plan_steps.is_empty());
    }

    #[test]
    fn status_swapping_from_swap_phrasing() {
        let item = item_from_chat_event(&ev("system", "Swapping agent: claude → codex"), 0);
        assert_eq!(item.status, "swapping");
    }
}

#[cfg(test)]
mod device_repro_tests {
    use super::*;
    fn ev(role: &str, content: &str) -> ChatEvent {
        ChatEvent {
            role: role.into(),
            content: content.into(),
            ts: "t".into(),
            files: vec![],
        }
    }

    // Device repro (IMG_0408-0410): a `gh pr create` Bash tool call whose
    // PR-body prose contained "Selection prefers $PORT" + "sessionOptions"
    // tripped the OLD `select && option/choice` heuristic → a bogus
    // "NEEDS YOUR INPUT" card on a tool call. The deterministic classifier
    // (no sentinel present) must treat it as an ordinary tool item.
    #[test]
    fn gh_pr_create_body_is_not_pending_input() {
        let content = "Bash: gh pr create --base main --head fix/x --body \"# Why\n\
            The Browser tab showed up pointing at an unrelated process.\n\
            Root causes:\n\
            Phantom tab: the old rule advertised a preview.\n\
            Selection prefers $PORT, else the lowest non-$PORT port.\n\
            Fix $PORT delivery: pass it via sessionOptions to the agent.\"";
        // Sanity: the old heuristic WOULD have matched (select + option).
        let lower = content.to_ascii_lowercase();
        assert!(
            lower.contains("select") && lower.contains("option"),
            "repro must contain the old trigger words"
        );
        // New classifier: no sentinel / approval marker → NOT pending.
        assert!(
            !looks_like_pending_input(content),
            "must not be a needs-input card"
        );
        let item = item_from_chat_event(&ev("tool", content), 0);
        assert_ne!(item.kind, "pending_input");
    }
}
