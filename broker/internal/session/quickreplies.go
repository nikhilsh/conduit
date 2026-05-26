package session

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"time"
)

// AI-generated contextual quick replies (task #233). When a Claude
// assistant turn completes, we kick off a BEST-EFFORT, async one-shot
// `claude -p` against a cheap model that returns up to 4 short tap-able
// user replies tailored to the latest assistant message. The result is
// emitted as a `view:"quick_replies"` view_event the apps render as the
// composer chips, replacing the old client-side heuristic.
//
// Design invariants:
//   - Non-blocking: generation runs in its own goroutine off the
//     stream-reader. It never delays or gates the real assistant turn.
//   - Best-effort: any error / timeout / malformed model output emits
//     nothing — the apps simply show no chips, exactly as today when the
//     heuristic found nothing.
//   - Config-gated: SWE_KITTY_AI_QUICKREPLIES=0 disables it entirely
//     (default ON).
//   - Credential-race safe: the interactive session and the one-shot
//     share the same ephemeral $HOME, whose `.claude/.credentials.json`
//     both processes could rotate concurrently on a refresh-token
//     expiry. We sidestep that by running the one-shot against a COPY of
//     the session's `.claude` creds in a throwaway temp HOME (removed
//     after the call). The one-shot's refresh — if any — lands in the
//     copy and is discarded, so it can never invalidate the live
//     session's token.

// quickReplyModel is the cheap/fast model the one-shot uses. Haiku is the
// cheapest Claude tier and more than capable of "suggest 4 short replies";
// the call is read-only context with a tiny output budget.
const quickReplyModel = "haiku"

// quickReplyTimeout caps the one-shot. The chips are a nicety, not the
// turn, so we bail fast rather than let a slow model linger; on timeout
// we emit nothing.
const quickReplyTimeout = 8 * time.Second

// maxQuickReplies is the hard cap on chips, matching the apps' render
// budget. We trim anything the model over-produces.
const maxQuickReplies = 4

// quickRepliesEnabled reports whether AI quick-reply generation is on.
// Default ON; SWE_KITTY_AI_QUICKREPLIES=0 (or "false"/"off") disables it.
func quickRepliesEnabled() bool {
	switch strings.ToLower(strings.TrimSpace(os.Getenv("SWE_KITTY_AI_QUICKREPLIES"))) {
	case "0", "false", "off", "no":
		return false
	default:
		return true
	}
}

// quickReplyGenerator produces AI quick replies for a session's completed
// assistant turns. It captures everything the one-shot needs (the claude
// binary, the session's ephemeral HOME for the cred copy, the session
// env, the worktree dir, and the publish sink) so the stream reader can
// fire generation without reaching back into the Session.
//
// nil is a valid generator: every method tolerates a nil receiver and
// no-ops, so non-claude backends (codex, TUI scrape) and the disabled
// path don't have to branch.
type quickReplyGenerator struct {
	sessionID    string
	binary       string   // adapter.Command[0], e.g. "claude"
	agentHomeDir string   // session ephemeral $HOME (source of the cred copy)
	env          []string // session commandEnv (HOME overridden per-call)
	dir          string   // session worktree
	publish      func([]byte)
}

// newQuickReplyGenerator builds a generator for a claude stream-json
// session, or returns nil when generation can't / shouldn't run (feature
// disabled, no ephemeral HOME to copy creds from, or missing publish).
// Returning nil keeps the call sites branch-free.
func newQuickReplyGenerator(sessionID, binary, agentHomeDir, dir string, env []string, publish func([]byte)) *quickReplyGenerator {
	if !quickRepliesEnabled() || agentHomeDir == "" || publish == nil || binary == "" {
		return nil
	}
	return &quickReplyGenerator{
		sessionID:    sessionID,
		binary:       binary,
		agentHomeDir: agentHomeDir,
		env:          env,
		dir:          dir,
		publish:      publish,
	}
}

// Generate runs one best-effort generation for a completed assistant
// turn and, on success, publishes a quick_replies view_event. lastText is
// the assistant's latest message; forMessageID ties the chips to that
// message so the app can drop them when a newer turn arrives. Runs
// synchronously — callers spawn it in a goroutine (see kickoff).
func (g *quickReplyGenerator) Generate(lastText, forMessageID string) {
	if g == nil {
		return
	}
	lastText = strings.TrimSpace(lastText)
	if lastText == "" {
		return
	}
	ctx, cancel := context.WithTimeout(context.Background(), quickReplyTimeout)
	defer cancel()

	replies, err := g.invoke(ctx, lastText)
	if err != nil || len(replies) == 0 {
		// Best-effort: stay silent on any failure. Log to stderr so a
		// persistent misconfiguration is debuggable, but never surface
		// it to the user.
		if err != nil {
			fmt.Fprintf(os.Stderr, "session %s: quick-reply generation: %v\n", g.sessionID, err)
		}
		return
	}
	g.publishReplies(replies, forMessageID)
}

// kickoff fires Generate in a goroutine so the stream reader never
// blocks. nil-safe.
func (g *quickReplyGenerator) kickoff(lastText, forMessageID string) {
	if g == nil {
		return
	}
	go g.Generate(lastText, forMessageID)
}

// invoke runs the one-shot `claude -p` against a throwaway copy of the
// session's creds and returns the parsed replies. The copy is the
// credential-race mitigation (see the type doc): the live session keeps
// its own `.credentials.json`; the one-shot rotates a discardable copy.
func (g *quickReplyGenerator) invoke(ctx context.Context, lastText string) ([]string, error) {
	tmpHome, err := os.MkdirTemp("", "swk-qr-home-")
	if err != nil {
		return nil, fmt.Errorf("mkdtemp: %w", err)
	}
	defer os.RemoveAll(tmpHome)

	if err := copyClaudeCreds(g.agentHomeDir, tmpHome); err != nil {
		return nil, fmt.Errorf("copy creds: %w", err)
	}

	argv := quickReplyCommand(g.binary)
	cmd := exec.CommandContext(ctx, argv[0], argv[1:]...)
	cmd.Env = withHomeOverride(g.env, tmpHome)
	cmd.Dir = g.dir
	cmd.Stdin = strings.NewReader(quickReplyPrompt(lastText))

	var stdout, stderr bytes.Buffer
	cmd.Stdout = &stdout
	cmd.Stderr = &stderr
	if err := cmd.Run(); err != nil {
		if ctx.Err() != nil {
			return nil, fmt.Errorf("timeout after %s", quickReplyTimeout)
		}
		return nil, fmt.Errorf("%w (stderr: %s)", err, strings.TrimSpace(stderr.String()))
	}
	return parseQuickReplies(stdout.String()), nil
}

// publishReplies marshals and emits the quick_replies view_event.
func (g *quickReplyGenerator) publishReplies(replies []string, forMessageID string) {
	payload, err := json.Marshal(map[string]any{
		"type": "view_event",
		"view": "quick_replies",
		"event": map[string]any{
			"session_id":     g.sessionID,
			"replies":        replies,
			"for_message_id": forMessageID,
		},
	})
	if err != nil {
		return
	}
	g.publish(payload)
}

// quickReplyCommand builds the one-shot argv: a plain `claude -p` with the
// cheap model and a text output format. No stream-json here — we want a
// single short blob we can JSON-parse, not an event stream.
func quickReplyCommand(binary string) []string {
	return []string{
		binary,
		"-p",
		"--model", quickReplyModel,
		"--output-format", "text",
	}
}

// quickReplyPrompt is the tight instruction handed to the one-shot on
// stdin. It asks for a bare JSON array of <=4 very short reply strings and
// pins the role so the model writes replies the *user* would tap, not more
// assistant prose.
func quickReplyPrompt(lastAssistant string) string {
	var b strings.Builder
	b.WriteString("You generate quick-reply suggestions for a coding-assistant chat app. ")
	b.WriteString("Below is the assistant's latest message to the user. ")
	b.WriteString("Suggest up to 4 SHORT replies (each at most ~4 words) the USER might tap to respond. ")
	b.WriteString("They must read as something the user would say back, be genuinely useful for THIS message, ")
	b.WriteString("and move the conversation forward (e.g. answer a question it asked, approve/decline a proposal, ask for detail). ")
	b.WriteString("Respond with ONLY a compact JSON array of strings, nothing else. ")
	b.WriteString("If no useful replies fit, respond with [].\n\n")
	b.WriteString("Assistant message:\n")
	b.WriteString(lastAssistant)
	return b.String()
}

// parseQuickReplies extracts the reply strings from the model's raw
// output. It tolerates prose around the JSON (e.g. a leading "Here you
// go:" or a ```json fence) by scanning for the first balanced top-level
// `[ ... ]` and parsing that. Returns up to maxQuickReplies trimmed,
// non-empty strings; returns nil on any failure so the caller emits
// nothing.
func parseQuickReplies(raw string) []string {
	arr := extractFirstJSONArray(raw)
	if arr == "" {
		return nil
	}
	var items []string
	if err := json.Unmarshal([]byte(arr), &items); err != nil {
		// The model may have produced an array of objects or mixed
		// types; fall back to a permissive decode that keeps the string
		// elements.
		var loose []any
		if json.Unmarshal([]byte(arr), &loose) != nil {
			return nil
		}
		for _, v := range loose {
			if s, ok := v.(string); ok {
				items = append(items, s)
			}
		}
	}
	out := make([]string, 0, maxQuickReplies)
	seen := map[string]struct{}{}
	for _, s := range items {
		s = strings.TrimSpace(s)
		if s == "" {
			continue
		}
		if _, dup := seen[s]; dup {
			continue
		}
		seen[s] = struct{}{}
		out = append(out, s)
		if len(out) >= maxQuickReplies {
			break
		}
	}
	if len(out) == 0 {
		return nil
	}
	return out
}

// extractFirstJSONArray returns the substring of s spanning the first
// top-level `[` to its matching `]`, honouring brackets inside strings.
// Returns "" when no balanced array is found.
func extractFirstJSONArray(s string) string {
	start := strings.IndexByte(s, '[')
	if start < 0 {
		return ""
	}
	depth := 0
	inStr := false
	escaped := false
	for i := start; i < len(s); i++ {
		c := s[i]
		if inStr {
			switch {
			case escaped:
				escaped = false
			case c == '\\':
				escaped = true
			case c == '"':
				inStr = false
			}
			continue
		}
		switch c {
		case '"':
			inStr = true
		case '[':
			depth++
		case ']':
			depth--
			if depth == 0 {
				return s[start : i+1]
			}
		}
	}
	return ""
}

// copyClaudeCreds copies the session's claude credential files from its
// ephemeral $HOME into a throwaway dst home, so the one-shot authenticates
// without touching (or racing on a refresh of) the live session's
// `.credentials.json`. Missing files are skipped — an unauthenticated
// one-shot just fails the generation, which is a clean no-op.
func copyClaudeCreds(srcHome, dstHome string) error {
	files := []struct {
		rel  string
		mode os.FileMode
	}{
		{filepath.Join(".claude", ".credentials.json"), 0o600},
		{".claude.json", 0o600},
	}
	anyCopied := false
	for _, f := range files {
		src := filepath.Join(srcHome, f.rel)
		data, err := os.ReadFile(src)
		if err != nil {
			if os.IsNotExist(err) {
				continue
			}
			return err
		}
		dst := filepath.Join(dstHome, f.rel)
		if err := os.MkdirAll(filepath.Dir(dst), 0o700); err != nil {
			return err
		}
		if err := os.WriteFile(dst, data, f.mode); err != nil {
			return err
		}
		anyCopied = true
	}
	if !anyCopied {
		return fmt.Errorf("no claude credentials in %s", srcHome)
	}
	return nil
}

// withHomeOverride returns a copy of env with HOME (and any leading
// duplicate) set to home. The one-shot must point at the throwaway cred
// copy, not the session's ephemeral home.
func withHomeOverride(env []string, home string) []string {
	out := make([]string, 0, len(env)+1)
	for _, kv := range env {
		if strings.HasPrefix(kv, "HOME=") {
			continue
		}
		out = append(out, kv)
	}
	return append(out, "HOME="+home)
}
