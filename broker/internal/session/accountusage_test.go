package session

import (
	"context"
	"net/http"
	"testing"
	"time"
)

func TestParseAccountUsage(t *testing.T) {
	// Verbatim shape from GET /api/oauth/usage.
	body := `{"five_hour":{"utilization":30.0,"resets_at":"2026-05-31T09:10:00+00:00"},` +
		`"seven_day":{"utilization":66.5,"resets_at":"2026-06-04T10:00:00+00:00"},` +
		`"seven_day_opus":null,"extra_usage":{"is_enabled":true,"used_credits":40.0}}`
	u, err := parseAccountUsage([]byte(body))
	if err != nil {
		t.Fatalf("parseAccountUsage: %v", err)
	}
	if !u.HasUsage {
		t.Fatal("HasUsage should be true")
	}
	if u.FiveHourPct != 30.0 {
		t.Errorf("FiveHourPct = %v, want 30", u.FiveHourPct)
	}
	if u.SevenDayPct != 66.5 {
		t.Errorf("SevenDayPct = %v, want 66.5", u.SevenDayPct)
	}
	if u.FiveHourResetsAt != "2026-05-31T09:10:00+00:00" {
		t.Errorf("FiveHourResetsAt = %q", u.FiveHourResetsAt)
	}
	if u.SevenDayResetsAt != "2026-06-04T10:00:00+00:00" {
		t.Errorf("SevenDayResetsAt = %q", u.SevenDayResetsAt)
	}
}

func TestParseAccountUsageMalformed(t *testing.T) {
	if _, err := parseAccountUsage([]byte("not json")); err == nil {
		t.Fatal("expected error on malformed body")
	}
}

func TestFetchAccountUsage(t *testing.T) {
	home := writeCreds(t, "tok-abc123456789", time.Now().Add(time.Hour).UnixMilli())
	var gotReq http.Request
	do := fakeDoer(t, 200,
		`{"five_hour":{"utilization":12.5,"resets_at":"R5"},"seven_day":{"utilization":80,"resets_at":"R7"}}`,
		&gotReq)

	u, err := fetchAccountUsage(context.Background(), do, home)
	if err != nil {
		t.Fatalf("fetchAccountUsage: %v", err)
	}
	if u.FiveHourPct != 12.5 || u.SevenDayPct != 80 {
		t.Errorf("unexpected usage: %+v", u)
	}
	// Request shape: a GET to the usage endpoint with the OAuth beta header.
	if gotReq.Method != http.MethodGet {
		t.Errorf("method = %s, want GET", gotReq.Method)
	}
	if gotReq.URL.String() != accountUsageURL {
		t.Errorf("url = %s, want %s", gotReq.URL.String(), accountUsageURL)
	}
	if gotReq.Header.Get("anthropic-beta") != oauthBeta {
		t.Errorf("missing oauth beta header")
	}
	if gotReq.Header.Get("authorization") == "" {
		t.Errorf("missing authorization header")
	}
}

func TestFetchAccountUsageNoToken(t *testing.T) {
	// No .claude/.credentials.json in this HOME → clean error, doer untouched.
	do := func(*http.Request) (*http.Response, error) {
		t.Fatal("httpDo must not be called when the token is unavailable")
		return nil, nil
	}
	if _, err := fetchAccountUsage(context.Background(), do, t.TempDir()); err == nil {
		t.Fatal("expected error when credentials are missing")
	}
}

func TestFetchAccountUsageHTTPError(t *testing.T) {
	home := writeCreds(t, "tok-abc123456789", time.Now().Add(time.Hour).UnixMilli())
	do := fakeDoer(t, 401, `{"error":"unauthorized"}`, nil)
	if _, err := fetchAccountUsage(context.Background(), do, home); err == nil {
		t.Fatal("expected error on non-200 status")
	}
}
