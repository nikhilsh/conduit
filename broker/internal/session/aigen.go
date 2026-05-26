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

// Shared fast AI-generation helper (task: ai-session-titles). The
// quick-reply path (#237) proved a DIRECT Anthropic Messages API call,
// authorized by the session's existing Claude Code OAuth access token,
// returns in ~1-2s — fast enough for best-effort, per-turn niceties where
// shelling out to `claude -p` always timed out. This file extracts that
// mechanism (the HTTP call + OAuth-token read + credential-race
// mitigation) so both quick replies AND session-title generation reuse
// one code path. See quickreplies.go / titles.go for the two callers.
//
// Design invariants shared by both callers:
//   - Read-only on credentials: we only READ the access token out of the
//     session's ephemeral HOME `.claude/.credentials.json`; we never spawn
//     a process that could rotate it and never write it back. An expired
//     token is a clean no-op — the live session owns its own refresh.
//   - Best-effort: any error / timeout / malformed output is the caller's
//     cue to emit nothing.

// aiGenModel is the cheap/fast model both generators use. Haiku is the
// cheapest Claude tier and more than capable of the tiny summarize/suggest
// tasks here; each call is read-only context with a small output budget.
const aiGenModel = "claude-haiku-4-5"

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

// httpDoFunc is the injectable HTTP doer. Defaults to a real client;
// tests inject a stub so CI never touches the network.
type httpDoFunc func(*http.Request) (*http.Response, error)

// anthropicMessages makes one direct Anthropic Messages API call using the
// session's OAuth access token and returns the assistant's concatenated
// text. It never spawns a process and never writes the token, so it can't
// race the live session's credential refresh. `prompt` is the single
// user-turn content; `maxTokens` caps the model's output.
func anthropicMessages(ctx context.Context, do httpDoFunc, agentHomeDir, prompt string, maxTokens int) (string, error) {
	token, err := readClaudeOAuthToken(agentHomeDir)
	if err != nil {
		return "", err
	}

	body, err := json.Marshal(map[string]any{
		"model":      aiGenModel,
		"max_tokens": maxTokens,
		"system":     claudeCodeSystemPrompt,
		"messages": []map[string]any{
			{"role": "user", "content": prompt},
		},
	})
	if err != nil {
		return "", fmt.Errorf("marshal request: %w", err)
	}

	req, err := http.NewRequestWithContext(ctx, http.MethodPost, anthropicMessagesURL, bytes.NewReader(body))
	if err != nil {
		return "", fmt.Errorf("build request: %w", err)
	}
	req.Header.Set("content-type", "application/json")
	req.Header.Set("authorization", "Bearer "+token)
	req.Header.Set("anthropic-version", anthropicVersion)
	req.Header.Set("anthropic-beta", oauthBeta)

	resp, err := do(req)
	if err != nil {
		if ctx.Err() != nil {
			return "", fmt.Errorf("timeout: %w", ctx.Err())
		}
		return "", fmt.Errorf("messages api: %w", err)
	}
	defer resp.Body.Close()

	// Cap the read: these responses are tiny; this guards against a
	// pathological body without pulling in the whole stream.
	raw, err := io.ReadAll(io.LimitReader(resp.Body, 1<<20))
	if err != nil {
		return "", fmt.Errorf("read response: %w", err)
	}
	if resp.StatusCode != http.StatusOK {
		return "", fmt.Errorf("messages api: status %d (%s)", resp.StatusCode, strings.TrimSpace(string(raw)))
	}
	return extractMessageText(raw)
}

// readClaudeOAuthToken reads the OAuth access token out of the session's
// ephemeral HOME `.claude/.credentials.json`. It returns an error (a
// clean best-effort skip) when the file is missing, malformed, the token
// is empty, or the token has expired — in the expiry case we don't try to
// refresh: the live session owns its own refresh and a stale nicety is not
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
