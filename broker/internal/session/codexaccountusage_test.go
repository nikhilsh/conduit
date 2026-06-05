package session

import (
	"context"
	"encoding/base64"
	"encoding/json"
	"net/http"
	"os"
	"path/filepath"
	"testing"
)

// sampleCodexUsageBody is the verbatim shape from GET /backend-api/wham/usage
// (codex-rs RateLimitStatusPayload → primary/secondary RateLimitWindowSnapshot).
const sampleCodexUsageBody = `{
  "plan_type": "plus",
  "rate_limit": {
    "allowed": true,
    "limit_reached": false,
    "primary_window": {"used_percent": 42, "limit_window_seconds": 18000, "reset_after_seconds": 3600, "reset_at": 1780000000},
    "secondary_window": {"used_percent": 12, "limit_window_seconds": 604800, "reset_after_seconds": 90000, "reset_at": 1780500000}
  }
}`

func TestParseCodexAccountUsage(t *testing.T) {
	u, err := parseCodexAccountUsage([]byte(sampleCodexUsageBody))
	if err != nil {
		t.Fatalf("parseCodexAccountUsage: %v", err)
	}
	if !u.HasUsage {
		t.Fatal("HasUsage should be true")
	}
	// primary → 5h, secondary → weekly.
	if u.FiveHourPct != 42 {
		t.Errorf("FiveHourPct = %v, want 42", u.FiveHourPct)
	}
	if u.SevenDayPct != 12 {
		t.Errorf("SevenDayPct = %v, want 12", u.SevenDayPct)
	}
	// reset_at unix seconds rendered to RFC3339.
	if u.FiveHourResetsAt != codexResetToISO(1780000000) || u.FiveHourResetsAt == "" {
		t.Errorf("FiveHourResetsAt = %q", u.FiveHourResetsAt)
	}
	if u.SevenDayResetsAt == "" {
		t.Errorf("SevenDayResetsAt empty")
	}
}

func TestParseCodexAccountUsageNoWindows(t *testing.T) {
	// A payload with rate_limit present but no windows must error (nothing to
	// show) rather than emit a misleading 0% card.
	if _, err := parseCodexAccountUsage([]byte(`{"rate_limit":{}}`)); err == nil {
		t.Fatal("expected error when no windows present")
	}
	if _, err := parseCodexAccountUsage([]byte("not json")); err == nil {
		t.Fatal("expected error on malformed body")
	}
}

func TestCodexAccountIDFromJWT(t *testing.T) {
	// Build a minimal id_token: header.payload.signature where the payload
	// carries the chatgpt_account_id under the openai auth claim.
	payload := map[string]any{
		"https://api.openai.com/auth": map[string]any{
			"chatgpt_account_id": "acc-12345",
		},
	}
	pj, _ := json.Marshal(payload)
	jwt := "h." + base64.RawURLEncoding.EncodeToString(pj) + ".sig"
	if got := codexAccountIDFromJWT(jwt); got != "acc-12345" {
		t.Fatalf("codexAccountIDFromJWT = %q, want acc-12345", got)
	}
	// Garbage in → empty out (header is omitted, not an error).
	if got := codexAccountIDFromJWT("garbage"); got != "" {
		t.Fatalf("expected empty for malformed jwt, got %q", got)
	}
}

// writeCodexAuth drops a minimal `<home>/.codex/auth.json` and returns home.
func writeCodexAuth(t *testing.T, accessToken, accountID, idToken string) string {
	t.Helper()
	home := t.TempDir()
	dir := filepath.Join(home, ".codex")
	if err := os.MkdirAll(dir, 0o700); err != nil {
		t.Fatalf("mkdir: %v", err)
	}
	body := map[string]any{
		"tokens": map[string]any{
			"access_token": accessToken,
			"account_id":   accountID,
			"id_token":     idToken,
		},
	}
	raw, _ := json.Marshal(body)
	if err := os.WriteFile(filepath.Join(dir, "auth.json"), raw, 0o600); err != nil {
		t.Fatalf("write auth.json: %v", err)
	}
	return home
}

func TestFetchCodexAccountUsage(t *testing.T) {
	home := writeCodexAuth(t, "codex-tok-abc", "acc-explicit", "")
	var gotReq http.Request
	do := fakeDoer(t, 200, sampleCodexUsageBody, &gotReq)

	u, err := fetchCodexAccountUsage(context.Background(), do, home)
	if err != nil {
		t.Fatalf("fetchCodexAccountUsage: %v", err)
	}
	if u.FiveHourPct != 42 || u.SevenDayPct != 12 {
		t.Errorf("unexpected usage: %+v", u)
	}
	if gotReq.Method != http.MethodGet {
		t.Errorf("method = %s, want GET", gotReq.Method)
	}
	if gotReq.URL.String() != codexAccountUsageURL {
		t.Errorf("url = %s, want %s", gotReq.URL.String(), codexAccountUsageURL)
	}
	if gotReq.Header.Get("authorization") != "Bearer codex-tok-abc" {
		t.Errorf("authorization = %q", gotReq.Header.Get("authorization"))
	}
	// Explicit tokens.account_id wins → ChatGPT-Account-ID header set.
	if gotReq.Header.Get("ChatGPT-Account-ID") != "acc-explicit" {
		t.Errorf("ChatGPT-Account-ID = %q, want acc-explicit", gotReq.Header.Get("ChatGPT-Account-ID"))
	}
}

func TestFetchCodexAccountUsageAccountIDFromJWT(t *testing.T) {
	// No explicit account_id → derive it from the id_token JWT.
	payload, _ := json.Marshal(map[string]any{
		"https://api.openai.com/auth": map[string]any{"chatgpt_account_id": "acc-jwt"},
	})
	jwt := "h." + base64.RawURLEncoding.EncodeToString(payload) + ".sig"
	home := writeCodexAuth(t, "codex-tok", "", jwt)
	var gotReq http.Request
	do := fakeDoer(t, 200, sampleCodexUsageBody, &gotReq)
	if _, err := fetchCodexAccountUsage(context.Background(), do, home); err != nil {
		t.Fatalf("fetchCodexAccountUsage: %v", err)
	}
	if gotReq.Header.Get("ChatGPT-Account-ID") != "acc-jwt" {
		t.Errorf("ChatGPT-Account-ID = %q, want acc-jwt (from JWT)", gotReq.Header.Get("ChatGPT-Account-ID"))
	}
}

func TestFetchCodexAccountUsageNoToken(t *testing.T) {
	do := func(*http.Request) (*http.Response, error) {
		t.Fatal("httpDo must not be called when the token is unavailable")
		return nil, nil
	}
	if _, err := fetchCodexAccountUsage(context.Background(), do, t.TempDir()); err == nil {
		t.Fatal("expected error when codex auth is missing")
	}
}

func TestFetchCodexAccountUsageHTTPError(t *testing.T) {
	home := writeCodexAuth(t, "codex-tok", "acc", "")
	do := fakeDoer(t, 401, `{"error":"unauthorized"}`, nil)
	if _, err := fetchCodexAccountUsage(context.Background(), do, home); err == nil {
		t.Fatal("expected error on non-200 status")
	}
}
