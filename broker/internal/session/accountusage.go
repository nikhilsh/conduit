package session

import (
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"time"
)

// Account-level usage (task: /usage). Distinct from the per-session token/cost
// usage in usage.go: this is the Claude SUBSCRIPTION usage — the 5-hour rolling
// window and the weekly (7-day) window — exactly what the Claude Code CLI's own
// `/usage` command shows. It is account-global, not per-session, but we fetch +
// surface it through the session a client is viewing (its Session Info card) so
// it rides the same OAuth token + status-frame path everything else uses.
//
// Source: GET https://api.anthropic.com/api/oauth/usage — a dedicated read-only
// endpoint authorized by the same Claude Code OAuth token aigen.go reads. It
// costs NO quota (unlike reading the ratelimit headers off a /v1/messages call),
// so it's safe to fire on connect and on an explicit refresh.

// accountUsageURL is the OAuth-authorized account-usage endpoint.
const accountUsageURL = "https://api.anthropic.com/api/oauth/usage"

// accountUsageTimeout caps the fetch — like the aigen niceties, a slow/absent
// response is a clean no-op, never a stall.
const accountUsageTimeout = 8 * time.Second

// AccountUsage is the subscription-usage snapshot surfaced in the status frame.
// Utilization is a percentage (0–100, as the endpoint reports it); ResetsAt is
// the ISO-8601 window-reset instant, passed through verbatim for the client to
// format. HasUsage is false until a fetch has succeeded at least once.
type AccountUsage struct {
	FiveHourPct      float64
	FiveHourResetsAt string
	SevenDayPct      float64
	SevenDayResetsAt string
	HasUsage         bool
}

// accountUsageResponse mirrors the /api/oauth/usage JSON. Only the two windows
// the feature surfaces are modeled; the endpoint also returns model-specific
// (seven_day_opus/sonnet) and extra-usage/credit fields we ignore for now.
type accountUsageResponse struct {
	FiveHour struct {
		Utilization float64 `json:"utilization"`
		ResetsAt    string  `json:"resets_at"`
	} `json:"five_hour"`
	SevenDay struct {
		Utilization float64 `json:"utilization"`
		ResetsAt    string  `json:"resets_at"`
	} `json:"seven_day"`
}

// fetchAccountUsage makes one GET to the account-usage endpoint with the
// session's OAuth token. Read-only on credentials (same invariant as aigen.go):
// it only READS the access token and never spawns a process that could rotate
// it. Best-effort — any error is the caller's cue to leave the cache untouched.
func fetchAccountUsage(ctx context.Context, do httpDoFunc, agentHomeDir string) (AccountUsage, error) {
	token, err := readClaudeOAuthToken(agentHomeDir)
	if err != nil {
		return AccountUsage{}, err
	}
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, accountUsageURL, nil)
	if err != nil {
		return AccountUsage{}, fmt.Errorf("build request: %w", err)
	}
	req.Header.Set("authorization", "Bearer "+token)
	req.Header.Set("anthropic-version", anthropicVersion)
	req.Header.Set("anthropic-beta", oauthBeta)

	resp, err := do(req)
	if err != nil {
		if ctx.Err() != nil {
			return AccountUsage{}, fmt.Errorf("timeout: %w", ctx.Err())
		}
		return AccountUsage{}, fmt.Errorf("account usage: %w", err)
	}
	defer resp.Body.Close()
	raw, err := io.ReadAll(io.LimitReader(resp.Body, 1<<20))
	if err != nil {
		return AccountUsage{}, fmt.Errorf("read response: %w", err)
	}
	if resp.StatusCode != http.StatusOK {
		return AccountUsage{}, fmt.Errorf("account usage: status %d", resp.StatusCode)
	}
	return parseAccountUsage(raw)
}

// parseAccountUsage lifts the two windows out of the endpoint body.
func parseAccountUsage(raw []byte) (AccountUsage, error) {
	var r accountUsageResponse
	if err := json.Unmarshal(raw, &r); err != nil {
		return AccountUsage{}, fmt.Errorf("parse account usage: %w", err)
	}
	return AccountUsage{
		FiveHourPct:      r.FiveHour.Utilization,
		FiveHourResetsAt: r.FiveHour.ResetsAt,
		SevenDayPct:      r.SevenDay.Utilization,
		SevenDayResetsAt: r.SevenDay.ResetsAt,
		HasUsage:         true,
	}, nil
}

// AccountUsage returns the cached subscription-usage snapshot.
func (s *Session) AccountUsage() AccountUsage {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.accountUsage
}

// RefreshAccountUsage fetches the latest subscription usage and, on success,
// caches it and re-broadcasts the status frame so the Session Info usage card
// updates live (on connect and on an explicit client refresh). Best-effort: a
// fetch error leaves the previous snapshot in place and broadcasts nothing.
// Exported because the ws package calls it on connect + on the refresh message.
func (s *Session) RefreshAccountUsage() {
	// Account usage is fetched from the Claude OAuth usage endpoint; only
	// claude sessions can ever populate it. Skip the doomed fetch for
	// codex/other agents (the clients hide the card for non-claude too), so a
	// codex session never blocks on a request that can't succeed.
	if s.Assistant != "claude" {
		return
	}
	do := s.accountUsageDo
	if do == nil {
		do = http.DefaultClient.Do
	}
	ctx, cancel := context.WithTimeout(context.Background(), accountUsageTimeout)
	defer cancel()
	u, err := fetchAccountUsage(ctx, do, s.agentHomeDir)
	if err != nil {
		return
	}
	s.mu.Lock()
	s.accountUsage = u
	s.mu.Unlock()
	s.broadcastStatus()
}
