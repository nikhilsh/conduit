package session

import (
	"context"
	"encoding/json"
	"fmt"
	"net/http"
	"os"
	"strings"
	"time"
	"unicode/utf8"
)

// AI-generated contextual quick replies (task #233). When a Claude
// assistant turn completes, we kick off a BEST-EFFORT, async generation
// against a cheap/fast model that returns up to 4 short tap-able user
// replies tailored to the latest assistant message. The result is
// emitted as a `view:"quick_replies"` view_event the apps render as the
// composer chips, replacing the old client-side heuristic.
//
// Generation mechanism (task: broker-fast-quickreply-gen, #237). We make
// a DIRECT Anthropic Messages API call from Go using the session's
// existing Claude Code OAuth access token via the shared
// `anthropicMessages` helper (see aigen.go). A direct call returns in
// ~1-2s — fast enough to deliver chips shortly after each turn, where the
// old `claude -p` cold-start always timed out.
//
// Design invariants:
//   - Non-blocking: generation runs in its own goroutine off the
//     stream-reader. It never delays or gates the real assistant turn.
//   - Best-effort: any error / timeout / malformed model output emits
//     nothing — the apps simply show no chips, exactly as today when the
//     heuristic found nothing.
//   - Config-gated: CONDUIT_AI_QUICKREPLIES=0 disables it entirely
//     (default ON).
//   - Credential-race safe: see aigen.go.

// quickReplyTimeout is the OVERALL budget for generation, spanning one
// attempt plus (on a transient failure) one quick retry. The chips are a
// nicety, not the turn, so we still bail rather than let it linger; on
// timeout we emit nothing. The direct API call typically returns in
// ~1-2s, but live brokers saw the old tighter budget expire under model
// latency and fall back to the heuristic — this gives generous headroom
// so the AI chips actually land. See quickReplyAttemptTimeout for the
// per-attempt slice.
const quickReplyTimeout = 15 * time.Second

// quickReplyAttemptTimeout caps a SINGLE Messages API attempt. It is
// deliberately under half the overall budget so a stalled first attempt
// is abandoned with room for one retry inside quickReplyTimeout. A
// healthy call returns well under this; a call that hasn't answered by
// here is almost certainly wedged, so retrying beats waiting it out.
const quickReplyAttemptTimeout = 7 * time.Second

// quickReplyMaxTokens caps the model's output. Four short reply strings
// in a JSON array fit easily under this.
const quickReplyMaxTokens = 256

// maxQuickReplies is the hard cap on chips, matching the apps' render
// budget. We trim anything the model over-produces.
const maxQuickReplies = 4

// quickReplyContextChars caps how much of the assistant's latest message
// we feed the model. Generation only needs the TAIL of the turn — the
// last thing the assistant said is what the user is replying to — so a
// long turn (pages of prose or a big diff) is trimmed to its final chunk.
// This keeps the request small and the haiku call fast/reliable, which is
// the difference between landing the AI chips and timing out into the
// heuristic. ~2000 chars comfortably covers a normal closing paragraph or
// question while bounding the worst case.
const quickReplyContextChars = 2000

// quickRepliesEnabled reports whether AI quick-reply generation is on.
// Default ON; CONDUIT_AI_QUICKREPLIES=0 (or "false"/"off") disables it.
func quickRepliesEnabled() bool {
	return aiFeatureEnabled("CONDUIT_AI_QUICKREPLIES")
}

// aiFeatureEnabled reports whether a boolean AI-feature env flag is on.
// Default ON; "0"/"false"/"off"/"no" disable it. Shared by the
// quick-reply and title generators so the gating semantics stay identical.
func aiFeatureEnabled(envVar string) bool {
	switch strings.ToLower(strings.TrimSpace(os.Getenv(envVar))) {
	case "0", "false", "off", "no":
		return false
	default:
		return true
	}
}

// quickReplyGenerator produces AI quick replies for a session's completed
// assistant turns. It captures everything the direct API call needs (the
// session's ephemeral HOME to read the OAuth token from, and the publish
// sink) so the stream reader can fire generation without reaching back
// into the Session.
//
// nil is a valid generator: every method tolerates a nil receiver and
// no-ops, so non-claude backends (codex, TUI scrape) and the disabled
// path don't have to branch.
type quickReplyGenerator struct {
	sessionID    string
	agentHomeDir string // session ephemeral $HOME (source of the OAuth token)
	publish      func([]byte)
	// httpDo issues the Messages API request. Defaults to a real HTTP
	// client; tests inject a stub so CI never touches the network. Used only
	// by the direct-Anthropic fallback when gen is nil.
	httpDo httpDoFunc
	// gen, when set, is the provider that runs the completion (anthropicGen
	// for claude, codexGen for codex). nil = the legacy direct-Anthropic
	// path via httpDo/agentHomeDir, kept so the existing unit tests (which
	// construct the generator literal without a provider) stay byte-identical.
	gen aiGenProvider
}

// newQuickReplyGenerator builds a generator for a claude stream-json
// session, or returns nil when generation can't / shouldn't run (feature
// disabled, no ephemeral HOME to read the token from, or missing
// publish). Returning nil keeps the call sites branch-free.
//
// `binary` is accepted for call-site compatibility (the old
// implementation shelled out to it) but is no longer used: generation is
// a direct HTTP call, not a subprocess. We still gate on it being
// non-empty to preserve the original "only for a real claude backend"
// guard.
func newQuickReplyGenerator(sessionID, binary, agentHomeDir, dir string, env []string, publish func([]byte)) *quickReplyGenerator {
	_ = dir
	_ = env
	if !quickRepliesEnabled() || agentHomeDir == "" || publish == nil || binary == "" {
		return nil
	}
	return &quickReplyGenerator{
		sessionID:    sessionID,
		agentHomeDir: agentHomeDir,
		publish:      publish,
		httpDo:       http.DefaultClient.Do,
	}
}

// newQuickReplyGeneratorWithProvider builds a quick-reply generator routed
// through an explicit aiGenProvider (anthropicGen / codexGen), used by both
// backend branches of startChatBackend. Returns nil when generation is off
// or the provider/publish sink is missing — keeping the call site branch-free.
func newQuickReplyGeneratorWithProvider(sessionID string, gen aiGenProvider, publish func([]byte)) *quickReplyGenerator {
	if !quickRepliesEnabled() || gen == nil || publish == nil {
		return nil
	}
	return &quickReplyGenerator{
		sessionID: sessionID,
		publish:   publish,
		gen:       gen,
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

// invoke makes a direct Anthropic Messages API call against a fast model
// and returns the parsed replies. It gives the call one quick retry on a
// transient failure (timeout / network blip / 5xx / overloaded) so a
// single slow or hiccuping request doesn't drop us to the heuristic — the
// common cause of the chips "falling back often". Each attempt is bounded
// by quickReplyAttemptTimeout, and both attempts together stay within the
// caller's overall quickReplyTimeout ctx; we never retry a permanent
// failure (e.g. 401 expired token, malformed creds).
func (g *quickReplyGenerator) invoke(ctx context.Context, lastText string) ([]string, error) {
	prompt := quickReplyPrompt(lastText)
	var lastErr error
	for attempt := 0; attempt < 2; attempt++ {
		// Stop early if the overall budget is already spent.
		if ctx.Err() != nil {
			break
		}
		attemptCtx, cancel := context.WithTimeout(ctx, quickReplyAttemptTimeout)
		var text string
		var err error
		if g.gen != nil {
			text, err = g.gen.Complete(attemptCtx, claudeCodeSystemPrompt, prompt, quickReplyMaxTokens)
		} else {
			// Legacy direct-Anthropic path (no provider injected, e.g. unit
			// tests): byte-identical to before.
			text, err = anthropicMessages(attemptCtx, g.httpDo, g.agentHomeDir, prompt, quickReplyMaxTokens)
		}
		cancel()
		if err == nil {
			return parseQuickReplies(text), nil
		}
		lastErr = err
		if !isTransientGenError(err) {
			break
		}
	}
	return nil, lastErr
}

// isTransientGenError reports whether a generation error is worth one
// retry: a timeout, a transient network failure, or a retryable server
// status (429 / 5xx / overloaded). A definite client/auth failure (e.g. a
// 401 expired token) is permanent and not retried. We classify on the
// error string because anthropicMessages formats status into the message;
// this stays a cheap best-effort heuristic, matching the surrounding code.
func isTransientGenError(err error) bool {
	if err == nil {
		return false
	}
	msg := strings.ToLower(err.Error())
	switch {
	case strings.Contains(msg, "timeout"),
		strings.Contains(msg, "deadline exceeded"),
		strings.Contains(msg, "connection reset"),
		strings.Contains(msg, "eof"),
		strings.Contains(msg, "overloaded"),
		strings.Contains(msg, "status 429"),
		strings.Contains(msg, "status 500"),
		strings.Contains(msg, "status 502"),
		strings.Contains(msg, "status 503"),
		strings.Contains(msg, "status 504"):
		return true
	}
	return false
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

// quickReplyPrompt is the tight instruction handed to the model. It asks
// for a bare JSON array of <=4 very short reply strings and pins the role
// so the model writes replies the *user* would tap, not more assistant
// prose.
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
	b.WriteString(trimAssistantTail(lastAssistant, quickReplyContextChars))
	return b.String()
}

// trimAssistantTail caps the assistant text we feed the model to its last
// `max` characters, keeping the TAIL (what the user is actually replying
// to) rather than the head. It snaps the cut forward to the next rune
// boundary so we never split a multi-byte character, and marks the
// elision so the model knows it's seeing the end of a longer turn.
// `max <= 0` or text already within budget is returned unchanged.
func trimAssistantTail(s string, max int) string {
	if max <= 0 || len(s) <= max {
		return s
	}
	tail := s[len(s)-max:]
	// Advance to the next valid UTF-8 boundary so a mid-rune cut can't
	// produce an invalid leading byte.
	for i := 0; i < len(tail) && i < 4; i++ {
		if utf8.RuneStart(tail[i]) {
			tail = tail[i:]
			break
		}
	}
	return "[…earlier output omitted…]\n" + strings.TrimSpace(tail)
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
