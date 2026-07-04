package session

import (
	"encoding/json"
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
	// turn_active is the authoritative "is a turn in flight" signal for
	// structured-chat sessions. `phase` stays "running" whether idle or
	// working, so it can't drive a transient indicator — clients fold this
	// instead to clear/keep the composer's working state on (re)connect.
	// Emitted ONLY for structured-chat sessions; OMITTED for the legacy
	// TUI-scrape path so those clients keep their log-role inference (a flat
	// false would pin their indicator off). Rides every status frame, so the
	// existing turn-end broadcast (accumulateUsage) and the watchdog tick
	// flip it live, not only on reconnect.
	if active, present := s.structuredTurnActive(); present {
		payload["turn_active"] = active
	}
	// turn_phase is the sub-state of the current in-flight turn: "writing"
	// (streaming text), "working" (tool executing), "thinking" (extended
	// reasoning). Omitted when no turn is active or no structured backend.
	// Lets clients show distinct indicators instead of a single "typing" dot.
	if tp, present := s.structuredTurnPhase(); present && tp != "" {
		payload["turn_phase"] = tp
	}
	// model is the agent-reported model id (e.g. "claude-sonnet-4-6").
	// Priority: live backend report > SpawnOverride. Omitted when unknown
	// so old apps/brokers see no key and don't render a stale value.
	if m, present := s.structuredModel(); present {
		payload["model"] = m
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
	if pv := s.previewPayload(); pv != nil {
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
			if o.PRURL != "" {
				payload["pr_url"] = o.PRURL
			}
			if o.PRProvider != "" {
				payload["pr_provider"] = o.PRProvider
			}
		}
	}
	if a := s.AccountUsage(); a.HasUsage {
		payload["account_5h_pct"] = a.FiveHourPct
		payload["account_5h_resets_at"] = a.FiveHourResetsAt
		payload["account_7d_pct"] = a.SevenDayPct
		payload["account_7d_resets_at"] = a.SevenDayResetsAt
	}
	if s.credentialSource != "" {
		payload["credential_source"] = s.credentialSource
	}
	// Live git state — computed against the session's workspace directory
	// using a short per-session cache so back-to-back status broadcasts
	// don't each shell out. All git fields are gated on Branch being
	// non-empty (which only holds when isGitRepo passed) so old clients and
	// non-git sessions see no new keys.
	gs := s.liveGitState()
	if gs.Branch != "" {
		payload["git_branch"] = gs.Branch
		payload["git_dirty"] = gs.Dirty
		if gs.Ahead != 0 {
			payload["git_ahead"] = gs.Ahead
		}
		if gs.Behind != 0 {
			payload["git_behind"] = gs.Behind
		}
		if gs.WorktreeName != "" {
			payload["worktree_name"] = gs.WorktreeName
		}
	}
	return payload
}

// liveGitState returns the cached (or freshly computed) GitState for the
// agent's actual current working directory. When the agent process has
// changed into a worktree (via git worktree add + cd), /proc/<pid>/cwd
// reflects that real location; otherwise we fall back to the static
// WorkspaceDir (existing behaviour).
func (s *Session) liveGitState() GitState {
	if gs, ok := s.gitStateCache.get(); ok {
		return gs
	}
	dir := s.WorkspaceDir()
	if pid := s.agentPID(); pid > 0 {
		if cwd := agentCWD(pid); cwd != "" {
			dir = cwd
		}
	}
	gs := computeGitState(dir, worktreeNameFor(s))
	s.gitStateCache.set(gs)
	return gs
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
