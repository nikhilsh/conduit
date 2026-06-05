package session

import (
	"context"
	"encoding/base64"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"os"
	"path/filepath"
	"strings"
	"time"
)

// Codex account-level usage — the OpenAI/ChatGPT parallel to accountusage.go's
// Claude subscription usage. Codex exposes the same two-window model (a short
// "primary" window ≈ 5h and a longer "secondary" window ≈ weekly) but, unlike
// claude, it is NOT in our `codex exec --json` stream (that event set carries
// only per-turn token counts, no rate limits). Instead it lives behind a
// dedicated ChatGPT backend endpoint — exactly the source the codex CLI itself
// reads. We fetch it with the session's codex OAuth token and fold it into the
// SAME AccountUsage struct (primary→5h, secondary→weekly) so the existing
// status-frame fields + client usage card light up for codex unchanged.
//
// Source: GET https://chatgpt.com/backend-api/wham/usage, authorized by the
// codex access token in `<agentHomeDir>/.codex/auth.json` plus the
// `ChatGPT-Account-ID` header (mirrors codex-rs backend-client get_rate_limits).
// Read-only on credentials (same invariant as readClaudeOAuthToken): we only
// READ the token, never rotate it.

const codexAccountUsageURL = "https://chatgpt.com/backend-api/wham/usage"

// codexAuthDotJSON models the subset of `~/.codex/auth.json` we read. The codex
// CLI writes the full struct (auth_mode, OPENAI_API_KEY, tokens, last_refresh);
// we only need the access token + the ChatGPT account id.
type codexAuthDotJSON struct {
	Tokens struct {
		AccessToken string `json:"access_token"`
		AccountID   string `json:"account_id"`
		IDToken     string `json:"id_token"`
	} `json:"tokens"`
}

// codexUsageResponse mirrors the /wham/usage JSON (codex-rs
// RateLimitStatusPayload → RateLimitStatusDetails → RateLimitWindowSnapshot).
// `used_percent` is an integer 0–100; `reset_at` is unix epoch SECONDS.
type codexUsageResponse struct {
	RateLimit struct {
		PrimaryWindow   *codexRateWindow `json:"primary_window"`
		SecondaryWindow *codexRateWindow `json:"secondary_window"`
	} `json:"rate_limit"`
}

type codexRateWindow struct {
	UsedPercent float64 `json:"used_percent"`
	ResetAt     int64   `json:"reset_at"`
}

// readCodexAuth lifts the codex access token + ChatGPT account id out of
// `<agentHomeDir>/.codex/auth.json`. The account id is preferably the explicit
// `tokens.account_id`; when absent (common) it is the `chatgpt_account_id`
// claim inside the `id_token` JWT, which is where codex itself reads it from.
func readCodexAuth(agentHomeDir string) (token, accountID string, err error) {
	path := filepath.Join(agentHomeDir, ".codex", "auth.json")
	raw, err := os.ReadFile(path)
	if err != nil {
		return "", "", fmt.Errorf("read codex auth: %w", err)
	}
	var a codexAuthDotJSON
	if err := json.Unmarshal(raw, &a); err != nil {
		return "", "", fmt.Errorf("parse codex auth: %w", err)
	}
	token = strings.TrimSpace(a.Tokens.AccessToken)
	if token == "" {
		return "", "", fmt.Errorf("codex auth: no access token")
	}
	accountID = strings.TrimSpace(a.Tokens.AccountID)
	if accountID == "" {
		accountID = codexAccountIDFromJWT(a.Tokens.IDToken)
	}
	return token, accountID, nil
}

// codexAccountIDFromJWT pulls the `chatgpt_account_id` out of the id_token's
// `https://api.openai.com/auth` claim. Best-effort: returns "" on any decode
// failure (the ChatGPT-Account-ID header is then omitted, which the backend
// tolerates for personal accounts).
func codexAccountIDFromJWT(idToken string) string {
	parts := strings.Split(idToken, ".")
	if len(parts) < 2 {
		return ""
	}
	payload, err := base64.RawURLEncoding.DecodeString(parts[1])
	if err != nil {
		return ""
	}
	var claims struct {
		Auth struct {
			ChatGPTAccountID string `json:"chatgpt_account_id"`
		} `json:"https://api.openai.com/auth"`
	}
	if err := json.Unmarshal(payload, &claims); err != nil {
		return ""
	}
	return strings.TrimSpace(claims.Auth.ChatGPTAccountID)
}

// fetchCodexAccountUsage makes one GET to the ChatGPT usage endpoint with the
// session's codex token. Best-effort, same contract as fetchAccountUsage.
func fetchCodexAccountUsage(ctx context.Context, do httpDoFunc, agentHomeDir string) (AccountUsage, error) {
	token, accountID, err := readCodexAuth(agentHomeDir)
	if err != nil {
		return AccountUsage{}, err
	}
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, codexAccountUsageURL, nil)
	if err != nil {
		return AccountUsage{}, fmt.Errorf("build request: %w", err)
	}
	req.Header.Set("authorization", "Bearer "+token)
	if accountID != "" {
		req.Header.Set("ChatGPT-Account-ID", accountID)
	}

	resp, err := do(req)
	if err != nil {
		if ctx.Err() != nil {
			return AccountUsage{}, fmt.Errorf("timeout: %w", ctx.Err())
		}
		return AccountUsage{}, fmt.Errorf("codex usage: %w", err)
	}
	defer resp.Body.Close()
	raw, err := io.ReadAll(io.LimitReader(resp.Body, 1<<20))
	if err != nil {
		return AccountUsage{}, fmt.Errorf("read response: %w", err)
	}
	if resp.StatusCode != http.StatusOK {
		return AccountUsage{}, fmt.Errorf("codex usage: status %d", resp.StatusCode)
	}
	return parseCodexAccountUsage(raw)
}

// parseCodexAccountUsage maps the codex window snapshot onto AccountUsage:
// primary→5h, secondary→weekly. reset_at (unix seconds) is rendered to the same
// RFC3339 string shape the Claude path passes through, so the client formats
// both identically. Returns an error if neither window is present (nothing to
// show — leave the cache untouched).
func parseCodexAccountUsage(raw []byte) (AccountUsage, error) {
	var r codexUsageResponse
	if err := json.Unmarshal(raw, &r); err != nil {
		return AccountUsage{}, fmt.Errorf("parse codex usage: %w", err)
	}
	primary, secondary := r.RateLimit.PrimaryWindow, r.RateLimit.SecondaryWindow
	if primary == nil && secondary == nil {
		return AccountUsage{}, fmt.Errorf("codex usage: no rate-limit windows")
	}
	var u AccountUsage
	u.HasUsage = true
	if primary != nil {
		u.FiveHourPct = primary.UsedPercent
		u.FiveHourResetsAt = codexResetToISO(primary.ResetAt)
	}
	if secondary != nil {
		u.SevenDayPct = secondary.UsedPercent
		u.SevenDayResetsAt = codexResetToISO(secondary.ResetAt)
	}
	return u, nil
}

// codexResetToISO turns a unix-seconds reset instant into the RFC3339 string
// the client already knows how to format. Zero/negative → "" (omitted).
func codexResetToISO(unixSeconds int64) string {
	if unixSeconds <= 0 {
		return ""
	}
	return time.Unix(unixSeconds, 0).UTC().Format(time.RFC3339)
}
