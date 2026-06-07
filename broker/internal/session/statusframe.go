package session

import (
	"encoding/json"
	"net"
	"strconv"
	"time"
)

// StatusPayload builds the `type:"status"` frame clients fold into their
// SessionStatus (health / phase + cwd / usage / outcome / etc.).
//
// It lives in the session package — not ws — so the same frame can be
// BROADCAST on a state change (e.g. usage accumulating when a turn completes),
// not only sent once on connect. Historically the payload was built inline in
// the ws connect handler, which meant token/cost usage (and the OutcomeChips
// stats) only ever reached a client at connect time: a turn that finished
// while you were watching grew the totals broker-side but never updated the
// usage card live. Centralising it here lets `accumulateUsage` re-broadcast.
//
// `viewers` is the current subscriber count; the connect path bumps it by one
// for the client that is about to subscribe (see ws.sendStatus).
func (s *Session) StatusPayload() map[string]any {
	st := s.Status()
	reason := st.ReasonCode
	if reason == "" {
		reason = "ok"
	}
	rows, cols := s.Dimensions()
	if rows == 0 {
		rows = 40
	}
	if cols == 0 {
		cols = 120
	}
	payload := map[string]any{
		"type":        "status",
		"session":     s.ID,
		"viewers":     s.SubscriberCount(),
		"rows":        rows,
		"cols":        cols,
		"assistant":   s.Assistant,
		"yolo":        false,
		"health":      st.Health,
		"phase":       st.Phase,
		"reason_code": reason,
		"ts":          time.Now().UTC().Format(time.RFC3339Nano),
	}
	if cwd := s.WorkspaceDir(); cwd != "" {
		payload["cwd"] = cwd
	}
	if !st.StartedAt.IsZero() {
		payload["started_at"] = st.StartedAt.Format(time.RFC3339Nano)
	}
	if !st.LastOutput.IsZero() {
		payload["last_activity_at"] = st.LastOutput.Format(time.RFC3339Nano)
	}
	if effort := s.ReasoningEffort(); effort != "" {
		payload["reasoning_effort"] = effort
	}
	if name := s.DisplayName(); name != "" {
		payload["session_name"] = name
		payload["display_name"] = name
	}
	// preview — the per-session dev-server surface (WEBSOCKET-PROTOCOL.md §3.2).
	// The agent binds $PORT; the app loads the proxied URL in its Browser tab.
	if pv := previewPayload(s.previewPort, s.ID); pv != nil {
		payload["preview"] = pv
	}
	if u := s.Usage(); u.HasUsage {
		payload["total_input_tokens"] = u.InputTokens
		payload["total_output_tokens"] = u.OutputTokens
		payload["total_cached_tokens"] = u.CachedTokens
		if u.CostUSD > 0 {
			payload["total_cost_usd"] = u.CostUSD
		}
		if u.ContextUsedTokens > 0 {
			payload["context_used_tokens"] = u.ContextUsedTokens
		}
		if u.ContextWindowTokens > 0 {
			payload["context_window_tokens"] = u.ContextWindowTokens
		}
	}
	if o := s.Outcome(); o.HasGit {
		payload["lines_added"] = o.LinesAdded
		payload["lines_removed"] = o.LinesRemoved
		payload["commits"] = o.Commits
		if o.HasPR {
			payload["pr_number"] = o.PRNumber
			payload["pr_state"] = o.PRState
		}
	}
	if a := s.AccountUsage(); a.HasUsage {
		payload["account_5h_pct"] = a.FiveHourPct
		payload["account_5h_resets_at"] = a.FiveHourResetsAt
		payload["account_7d_pct"] = a.SevenDayPct
		payload["account_7d_resets_at"] = a.SevenDayResetsAt
	}
	return payload
}

// statusFrameJSON marshals StatusPayload for broadcast via PublishText.
func (s *Session) statusFrameJSON() []byte {
	b, _ := json.Marshal(s.StatusPayload())
	return b
}

// broadcastStatus pushes a fresh status frame to every subscriber. Called when
// session state that the clients render changes outside the connect path
// (e.g. usage accumulating on turn completion) so the usage card / OutcomeChips
// update live instead of only on reconnect.
func (s *Session) broadcastStatus() {
	s.PublishText(s.statusFrameJSON())
}

// previewPayload builds the status frame's `preview` object, or nil when no
// dev-server port is allocated. The `url` is populated only when something is
// actually listening on the port — otherwise it's empty, which the client
// reads as "no live site → withdraw the Browser tab".
//
// This retracts a stale preview: the port is allocated once at session create
// and never freed, so the old "previewPort > 0 ⇒ advertise a url" rule left the
// Browser tab pinned forever even after the dev server died or was never
// started. Probing liveness on each status frame makes the tab track reality —
// it appears when the agent's server comes up and disappears when it stops.
func previewPayload(port int, sessionID string) map[string]any {
	if port <= 0 {
		return nil
	}
	url := ""
	if previewPortLive(port) {
		url = "/preview/" + sessionID + "/"
	}
	return map[string]any{"port": port, "url": url}
}

// previewPortLive reports whether a dev server is currently accepting
// connections on the session's preview port. A short timeout keeps the
// status-frame build cheap; the dial is to loopback so it resolves fast.
func previewPortLive(port int) bool {
	conn, err := net.DialTimeout("tcp", net.JoinHostPort("127.0.0.1", strconv.Itoa(port)), 150*time.Millisecond)
	if err != nil {
		return false
	}
	_ = conn.Close()
	return true
}
