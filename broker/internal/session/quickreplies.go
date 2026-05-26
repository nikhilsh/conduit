package session

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"os"
	"path/filepath"
	"strings"
	"time"
)

// AI-generated contextual quick replies (task #233). When a Claude
// assistant turn completes, we kick off a BEST-EFFORT, async generation
// against a cheap/fast model that returns up to 4 short tap-able user
// replies tailored to the latest assistant message. The result is
// emitted as a `view:"quick_replies"` view_event the apps render as the
// composer chips, replacing the old client-side heuristic.
//
// Generation mechanism (task: broker-fast-quickreply-gen). The original
// implementation (#234) shelled out to a one-shot headless
// `claude -p --model haiku`. That ALWAYS timed out: the `claude` CLI
// cold-start (process spawn + OAuth handshake + model load) blows past
// any sane budget, so the feature was effectively dead and every turn
// fell back to the apps' generic heuristic.
//
// Instead we now make a DIRECT Anthropic Messages API call from Go using
// the session's existing Claude Code OAuth access token (read from the
// ephemeral HOME's `.claude/.credentials.json`). Claude Code OAuth tokens
// authorize the raw `POST https://api.anthropic.com/v1/messages` endpoint
// when sent as `Authorization: Bearer <accessToken>` alongside the
// `anthropic-beta: oauth-2025-04-20` and `anthropic-version` headers and
// the Claude Code system prompt. A direct call returns in ~1-2s — fast
// enough to deliver chips shortly after each turn.
//
// Design invariants:
//   - Non-blocking: generation runs in its own goroutine off the
//     stream-reader. It never delays or gates the real assistant turn.
//   - Best-effort: any error / timeout / malformed model output emits
//     nothing — the apps simply show no chips, exactly as today when the
//     heuristic found nothing.
//   - Config-gated: SWE_KITTY_AI_QUICKREPLIES=0 disables it entirely
//     (default ON).
//   - Credential-race safe: we only READ the access token out of the
//     session's `.claude/.credentials.json`; we never spawn a process
//     that could rotate it, and we never write it back. An expired token
//     is a clean no-op (best-effort skip) — the live session owns its own
//     refresh.

// quickReplyModel is the cheap/fast model the generation uses. Haiku is
// the cheapest Claude tier and more than capable of "suggest 4 short
// replies"; the call is read-only context with a tiny output budget.
const quickReplyModel = "claude-haiku-4-5"

// quickReplyTimeout caps the HTTP call. The chips are a nicety, not the
// turn, so we bail rather than let a slow request linger; on timeout we
// emit nothing. The direct API call typically returns in ~1-2s, so this
// is comfortably generous.
const quickReplyTimeout = 12 * time.Second

// quickReplyMaxTokens caps the model's output. Four short reply strings
// in a JSON array fit easily under this.
const quickReplyMaxTokens = 256

// maxQuickReplies is the hard cap on chips, matching the apps' render
// budget. We trim anything the model over-produces.
const maxQuickReplies = 4

// anthropicMessagesURL is the raw Messages API endpoint the OAuth token
// authorizes.
const anthropicMessagesURL = "https://api.anthropic.com/v1/messages"

// anthropicVersion / oauthBeta are the headers the Claude Code OAuth flow
// requires on a direct Messages API call. Without the oauth beta the API
// rejects a Bearer-token request.
const (
	anthropicVersion = "2023-06-01"
	oauthBeta        = "oauth-2025-04-20"
)

// claudeCodeSystemPrompt mirrors the system prompt Claude Code sends.
// OAuth-token requests are scoped to the Claude Code product; pinning the
// identity keeps the request shape consistent with what the token was
// issued for.
const claudeCodeSystemPrompt = "You are Claude Code, Anthropic's official CLI for Claude."

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
	// client; tests inject a stub so CI never touches the network.
	httpDo func(*http.Request) (*http.Response, error)
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

// invoke reads the session's OAuth access token, makes a direct Anthropic
// Messages API call against a fast model, and returns the parsed replies.
// It never spawns a process and never writes the token, so it can't race
// the live session's credential refresh.
func (g *quickReplyGenerator) invoke(ctx context.Context, lastText string) ([]string, error) {
	token, err := readClaudeOAuthToken(g.agentHomeDir)
	if err != nil {
		return nil, err
	}

	body, err := json.Marshal(map[string]any{
		"model":      quickReplyModel,
		"max_tokens": quickReplyMaxTokens,
		"system":     claudeCodeSystemPrompt,
		"messages": []map[string]any{
			{"role": "user", "content": quickReplyPrompt(lastText)},
		},
	})
	if err != nil {
		return nil, fmt.Errorf("marshal request: %w", err)
	}

	req, err := http.NewRequestWithContext(ctx, http.MethodPost, anthropicMessagesURL, bytes.NewReader(body))
	if err != nil {
		return nil, fmt.Errorf("build request: %w", err)
	}
	req.Header.Set("content-type", "application/json")
	req.Header.Set("authorization", "Bearer "+token)
	req.Header.Set("anthropic-version", anthropicVersion)
	req.Header.Set("anthropic-beta", oauthBeta)

	resp, err := g.httpDo(req)
	if err != nil {
		if ctx.Err() != nil {
			return nil, fmt.Errorf("timeout after %s", quickReplyTimeout)
		}
		return nil, fmt.Errorf("messages api: %w", err)
	}
	defer resp.Body.Close()

	// Cap the read: a quick-reply response is tiny; this guards against a
	// pathological body without pulling in the whole stream.
	raw, err := io.ReadAll(io.LimitReader(resp.Body, 1<<20))
	if err != nil {
		return nil, fmt.Errorf("read response: %w", err)
	}
	if resp.StatusCode != http.StatusOK {
		return nil, fmt.Errorf("messages api: status %d (%s)", resp.StatusCode, strings.TrimSpace(string(raw)))
	}
	text, err := extractMessageText(raw)
	if err != nil {
		return nil, err
	}
	return parseQuickReplies(text), nil
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

// readClaudeOAuthToken reads the OAuth access token out of the session's
// ephemeral HOME `.claude/.credentials.json`. It returns an error (a
// clean best-effort skip) when the file is missing, malformed, the token
// is empty, or the token has expired — in the expiry case we don't try to
// refresh: the live session owns its own refresh and a stale chip is not
// worth touching the shared credential.
func readClaudeOAuthToken(agentHomeDir string) (string, error) {
	path := filepath.Join(agentHomeDir, ".claude", ".credentials.json")
	data, err := os.ReadFile(path)
	if err != nil {
		return "", fmt.Errorf("read credentials: %w", err)
	}
	var creds struct {
		ClaudeAiOauth struct {
			AccessToken string `json:"accessToken"`
			ExpiresAt   int64  `json:"expiresAt"`
		} `json:"claudeAiOauth"`
	}
	if err := json.Unmarshal(data, &creds); err != nil {
		return "", fmt.Errorf("parse credentials: %w", err)
	}
	tok := strings.TrimSpace(creds.ClaudeAiOauth.AccessToken)
	if tok == "" {
		return "", fmt.Errorf("no oauth access token in credentials")
	}
	// expiresAt is epoch milliseconds. Treat a token within 30s of expiry
	// as expired so we don't fire a request that races the boundary.
	if exp := creds.ClaudeAiOauth.ExpiresAt; exp > 0 {
		if time.Now().Add(30*time.Second).UnixMilli() >= exp {
			return "", fmt.Errorf("oauth access token expired")
		}
	}
	return tok, nil
}

// extractMessageText pulls the assistant text out of a Messages API
// response: it concatenates every `text` block in `content`. Returns an
// error when the body isn't a parseable message or carries no text.
func extractMessageText(raw []byte) (string, error) {
	var msg struct {
		Content []struct {
			Type string `json:"type"`
			Text string `json:"text"`
		} `json:"content"`
	}
	if err := json.Unmarshal(raw, &msg); err != nil {
		return "", fmt.Errorf("parse messages response: %w", err)
	}
	var b strings.Builder
	for _, c := range msg.Content {
		if c.Type == "text" {
			b.WriteString(c.Text)
		}
	}
	out := b.String()
	if strings.TrimSpace(out) == "" {
		return "", fmt.Errorf("empty message content")
	}
	return out, nil
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
