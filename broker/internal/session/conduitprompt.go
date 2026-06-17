package session

import (
	"log"
	"os"
	"path/filepath"
	"strings"

	"github.com/nikhilsh/conduit/broker/internal/kb"
)

// This file is PART A of the "harness bootstrap" marquee feature: a concise
// "conduit-awareness" system-prompt addendum that tells the spawned agent it
// runs UNDER Conduit and how to USE the affordances Conduit gives it (preview
// reverse-proxy on $PORT, the uploads dir, the AskUserQuestion tappable cards,
// the .conduit/memory store).
//
// It is a SINGLE source string (one Go builder) so claude and codex share the
// exact wording. The two agents inject it differently — see the asymmetry note
// below and docs/PLAN-HARNESS-BOOTSTRAP.md:
//
//   - claude: appended to the existing --append-system-prompt (merged with the
//     askUserQuestionNudge into one flag value — see claudeStreamCommand).
//   - codex:  codex has no clean append-system-prompt flag, so the awareness is
//     written as a managed section in the workspace's AGENTS.md, which codex
//     reads natively from cwd (covers both the app-server and the exec backend).

// conduitAwarenessEnv is the kill-switch env var. Default is ON; set it to a
// falsey value ("0", "off", "false", "no") to disable injection without a code
// change (review-safety off-ramp — see the PR body / PLAN doc).
const conduitAwarenessEnv = "CONDUIT_HARNESS_AWARENESS"

// conduitAwarenessEnabled reports whether the conduit-awareness prompt should
// be injected. Default ON; a falsey kill-switch value turns it off. An empty
// or unset value (and any non-falsey value) is treated as ON.
func conduitAwarenessEnabled() bool {
	switch strings.ToLower(strings.TrimSpace(os.Getenv(conduitAwarenessEnv))) {
	case "0", "off", "false", "no", "disable", "disabled":
		return false
	default:
		return true
	}
}

// conduitAwarenessPrompt returns the conduit-awareness addendum. It is a plain
// string with no agent-specific framing so it reads correctly whether it lands
// in claude's --append-system-prompt or codex's AGENTS.md. Kept deliberately
// terse: every line is an affordance the agent can act on, not marketing.
//
// IMPORTANT: keep this ASCII-only (no curly quotes / em-dashes) — it is passed
// verbatim on a command line for claude.
func conduitAwarenessPrompt() string {
	return strings.Join([]string{
		"You are running inside Conduit, which lets the user drive and watch you from a phone. Use these affordances:",
		"- Dev servers / previews: bind any HTTP server you start to the port in the $PORT environment variable (also exposed as $CONDUIT_PREVIEW_PORT). Conduit reverse-proxies it so the user can open a live preview on their phone. Do not hardcode a different port if you want the user to see it.",
		"- Files the user sends you arrive under the relative path uploads/<session>/ in your working directory; reference attachments from there.",
		"- Interactive choices: when you need the user to pick between options or answer before continuing, use the AskUserQuestion tool. Conduit renders it as tappable cards and waits for the answer; a plain-text question does not pause your turn and may be missed.",
		"- Offering options is always a question: whenever you would present a choice as a numbered or bulleted list in your reply (e.g. \"1. Fix the bug 2. Add a feature 3. Review the code\"), ask it through AskUserQuestion instead so each option is a tappable card. A choice written as prose renders as plain text the user must retype, not buttons they can tap.",
		"- Durable notes/handoff for this project live under .conduit/memory/. Use them to persist context across sessions rather than assuming the user re-explains.",
	}, "\n")
}

// agentsMDSectionBegin / agentsMDSectionEnd fence the managed conduit-awareness
// block inside a project's AGENTS.md so it can be idempotently inserted and
// replaced without clobbering the user's own content.
const (
	agentsMDSectionBegin = "<!-- BEGIN CONDUIT AWARENESS (managed by Conduit) -->"
	agentsMDSectionEnd   = "<!-- END CONDUIT AWARENESS (managed by Conduit) -->"
)

// conduitAwarenessAgentsMDSection renders the fenced markdown block written
// into a codex workspace's AGENTS.md.
func conduitAwarenessAgentsMDSection() string {
	return agentsMDSectionBegin + "\n\n" +
		"## Running under Conduit\n\n" +
		conduitAwarenessPrompt() + "\n\n" +
		agentsMDSectionEnd
}

// upsertConduitAwarenessSection returns AGENTS.md content with the managed
// conduit-awareness block inserted or replaced. If the existing content already
// carries a fenced block, it is swapped in place (so re-spawns and prompt
// edits don't accumulate stale copies); otherwise the block is appended. An
// empty `existing` yields just the section. The result is byte-identical across
// re-spawns once the wording is stable (idempotent), so the workspace's git
// status doesn't churn on every reconnect.
func upsertConduitAwarenessSection(existing string) string {
	section := conduitAwarenessAgentsMDSection()
	begin := strings.Index(existing, agentsMDSectionBegin)
	if begin >= 0 {
		// Replace the existing fenced block in place.
		endIdx := strings.Index(existing[begin:], agentsMDSectionEnd)
		if endIdx >= 0 {
			end := begin + endIdx + len(agentsMDSectionEnd)
			return existing[:begin] + section + existing[end:]
		}
		// Begin marker without an end (corrupted) — replace from begin to EOF.
		return existing[:begin] + section
	}
	trimmed := strings.TrimRight(existing, "\n")
	if trimmed == "" {
		return section + "\n"
	}
	return trimmed + "\n\n" + section + "\n"
}

// isCodexProtocol reports whether a backend protocol is one of codex's (which
// take the AGENTS.md injection path rather than claude's --append-system-prompt).
func isCodexProtocol(protocol string) bool {
	return protocol == "codex-app-server" || protocol == "codex-exec"
}

// injectConduitAwarenessAgentsMD writes/updates the managed conduit-awareness
// block in <workspace>/AGENTS.md. It reads any existing AGENTS.md, upserts the
// fenced block (idempotent — re-spawns and reconnects don't accumulate copies
// or churn git status once the wording is stable), and writes it back. A
// missing workspace dir is a no-op (returns nil). Used for codex, which reads
// AGENTS.md from its cwd natively.
func (s *Session) injectConduitAwarenessAgentsMD() error {
	dir := s.workspaceDir
	if strings.TrimSpace(dir) == "" {
		return nil
	}
	path := filepath.Join(dir, "AGENTS.md")
	existing := ""
	if b, err := os.ReadFile(path); err == nil {
		existing = string(b)
	} else if !os.IsNotExist(err) {
		return err
	}
	updated := upsertConduitAwarenessSectionWithKB(existing, dir)
	if updated == existing {
		return nil // already current — skip the write (no git churn)
	}
	return os.WriteFile(path, []byte(updated), 0o644)
}

// logConduitAwarenessInjected drops the Telemetry-breadcrumb-equivalent log
// line when the awareness prompt is injected for a session. The broker has no
// direct Sentry client (that lives in the apps), so a structured log line is
// the on-box breadcrumb; it records the agent + the injection mechanism so a
// "the agent didn't know about $PORT" report is diagnosable from box logs.
func logConduitAwarenessInjected(sessionID, agent, mechanism string) {
	log.Printf("session %s: conduit-awareness injected (agent=%s mechanism=%s)", sessionID, agent, mechanism)
}

// kbSection builds the "Knowledge base" section of the conduit-awareness
// prompt for the given workspace directory. It is included only when the
// workspace has a knowledge/INDEX.md file (the self-gate).
//
// It uses os.Executable() to embed the absolute path to the broker binary so
// the agent can invoke conduit-broker kb commands regardless of PATH.
//
// Returns ("", false) when the workspace has no knowledge/INDEX.md (gate OFF).
// Returns (section, true) when the section was built successfully.
func kbSection(workspaceDir string) (string, bool) {
	if workspaceDir == "" {
		return "", false
	}
	// Phase 3a (flag ON): KB is active if the workspace has ANY source —
	// tracked entries, box-local entries, OR ingestable docs ("useful day one
	// on any repo"). Injection spans all three, clearly labeled by origin.
	if kb.ExperimentalEnabled() {
		return kbSectionExperimental(workspaceDir)
	}

	// Flag OFF (default): byte-identical to Phase 1/2 — inject only when the
	// workspace has a tracked knowledge/INDEX.md.
	indexPath := filepath.Join(workspaceDir, "knowledge", "INDEX.md")
	b, err := os.ReadFile(indexPath)
	if err != nil {
		// No INDEX.md -- KB gate is OFF for this workspace.
		return "", false
	}
	indexContent := truncateKBIndex(string(b))

	brokerBin := brokerExecutable()
	var sb strings.Builder
	sb.WriteString("Knowledge base: this workspace has a knowledge/ directory. Before non-trivial work, consult it.\n")
	sb.WriteString("- Search: ")
	sb.WriteString(brokerBin)
	sb.WriteString(" kb search <query>\n")
	sb.WriteString("- Read an entry: ")
	sb.WriteString(brokerBin)
	sb.WriteString(" kb get <slug>\n")
	sb.WriteString("- Add a new finding: ")
	sb.WriteString(brokerBin)
	sb.WriteString(" kb add --title \"...\" --tags \"tag1,tag2\" --body \"...\"\n")
	sb.WriteString("- When you learn something durable (a footgun, a decision, a wire fact), add it.\n")
	sb.WriteString("\nCurrent knowledge/INDEX.md:\n")
	sb.WriteString("```\n")
	sb.WriteString(indexContent)
	if !strings.HasSuffix(indexContent, "\n") {
		sb.WriteString("\n")
	}
	sb.WriteString("```")
	return sb.String(), true
}

// kbSectionExperimental builds the KB section for the flag-ON (Phase 3a) path.
// It gates on kb.SourceExists (any of tracked / box-local / ingestable docs)
// and injects a merged, origin-labeled index. It also runs ingest as part of
// the refresh so registered-source pointers exist and the box-local gitignore
// is in place — never touching any user-authored file. Returns ("", false)
// when the workspace has no KB source at all.
func kbSectionExperimental(workspaceDir string) (string, bool) {
	// Refresh registered-source pointers (pointers only; never edits sources)
	// and ensure the box-local store is gitignored. Best-effort: a failure here
	// must never suppress an otherwise-present KB.
	if _, err := kb.Ingest(workspaceDir); err != nil {
		log.Printf("kb: ingest refresh failed for %s: %v (continuing)", workspaceDir, err)
	}
	if !kb.SourceExists(workspaceDir) {
		return "", false
	}
	merged := kb.MergedIndexForWorkspace(workspaceDir)
	if len(merged) == 0 {
		return "", false
	}
	indexContent := truncateKBIndex(kb.RenderMergedIndex(merged))

	brokerBin := brokerExecutable()
	var sb strings.Builder
	sb.WriteString("Knowledge base: this workspace has indexed knowledge (tracked entries, box-local notes, and pointers into existing docs). Before non-trivial work, consult it.\n")
	sb.WriteString("- Search: ")
	sb.WriteString(brokerBin)
	sb.WriteString(" kb search <query>\n")
	sb.WriteString("- Read an entry: ")
	sb.WriteString(brokerBin)
	sb.WriteString(" kb get <slug>\n")
	sb.WriteString("- Add a finding (saved box-local, NOT committed): ")
	sb.WriteString(brokerBin)
	sb.WriteString(" kb add --title \"...\" --tags \"tag1,tag2\" --body \"...\"\n")
	sb.WriteString("- Share a box-local finding with the team (commit it): ")
	sb.WriteString(brokerBin)
	sb.WriteString(" kb promote <slug>\n")
	sb.WriteString("- Origin column: tracked = shared in repo; box-local = private to this box; source-pointer = an existing doc (read it, do not assume conduit owns it).\n")
	sb.WriteString("\nKnowledge index (merged):\n")
	sb.WriteString("```\n")
	sb.WriteString(indexContent)
	if !strings.HasSuffix(indexContent, "\n") {
		sb.WriteString("\n")
	}
	sb.WriteString("```")
	return sb.String(), true
}

// truncateKBIndex caps the index content to MaxIndexLines/MaxIndexBytes.
// Mirrors the logic in the kb package to avoid a circular import.
const (
	maxKBIndexLines = 120
	maxKBIndexBytes = 4096
)

func truncateKBIndex(raw string) string {
	if len(raw) <= maxKBIndexBytes {
		if strings.Count(raw, "\n") <= maxKBIndexLines {
			return raw
		}
	}
	lines := strings.Split(raw, "\n")
	var kept []string
	total := 0
	truncated := false
	for i, line := range lines {
		if i >= maxKBIndexLines {
			truncated = true
			break
		}
		if total+len(line)+1 > maxKBIndexBytes {
			truncated = true
			break
		}
		kept = append(kept, line)
		total += len(line) + 1
	}
	result := strings.Join(kept, "\n")
	if truncated {
		result += "\n[INDEX truncated]"
	}
	return result
}

// brokerExecutable returns the absolute path to the running broker binary,
// or "conduit-broker" as a fallback when os.Executable() fails.
func brokerExecutable() string {
	if exe, err := os.Executable(); err == nil && exe != "" {
		return exe
	}
	return "conduit-broker"
}

// conduitAwarenessPromptWithKB returns the conduit-awareness addendum
// including the KB section when the workspace has a knowledge/INDEX.md.
// Same as conduitAwarenessPrompt() when the KB gate is OFF.
func conduitAwarenessPromptWithKB(workspaceDir string) string {
	base := conduitAwarenessPrompt()
	section, ok := kbSection(workspaceDir)
	if !ok {
		return base
	}
	return base + "\n- " + section
}

// claudeAppendSystemPromptForWorkspace is like claudeAppendSystemPrompt but
// includes the KB section when the workspace has a knowledge/INDEX.md.
func claudeAppendSystemPromptForWorkspace(workspaceDir string) string {
	if !conduitAwarenessEnabled() {
		return askUserQuestionNudge
	}
	return askUserQuestionNudge + "\n\n" + conduitAwarenessPromptWithKB(workspaceDir)
}

// conduitAwarenessAgentsMDSectionWithKB renders the fenced markdown block
// written into a codex workspace's AGENTS.md, including the KB section when
// the workspace has a knowledge/INDEX.md.
func conduitAwarenessAgentsMDSectionWithKB(workspaceDir string) string {
	prompt := conduitAwarenessPromptWithKB(workspaceDir)
	return agentsMDSectionBegin + "\n\n" +
		"## Running under Conduit\n\n" +
		prompt + "\n\n" +
		agentsMDSectionEnd
}

// upsertConduitAwarenessSectionWithKB returns AGENTS.md content with the
// managed conduit-awareness block (including KB section) inserted or replaced.
// Delegates to conduitAwarenessAgentsMDSectionWithKB for the section content.
func upsertConduitAwarenessSectionWithKB(existing, workspaceDir string) string {
	section := conduitAwarenessAgentsMDSectionWithKB(workspaceDir)
	begin := strings.Index(existing, agentsMDSectionBegin)
	if begin >= 0 {
		endIdx := strings.Index(existing[begin:], agentsMDSectionEnd)
		if endIdx >= 0 {
			end := begin + endIdx + len(agentsMDSectionEnd)
			return existing[:begin] + section + existing[end:]
		}
		return existing[:begin] + section
	}
	trimmed := strings.TrimRight(existing, "\n")
	if trimmed == "" {
		return section + "\n"
	}
	return trimmed + "\n\n" + section + "\n"
}
