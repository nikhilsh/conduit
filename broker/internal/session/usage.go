package session

import "encoding/json"

// usageDelta is one turn's token/cost usage, normalized across agents.
// input/output/cached/cost accumulate across the session; context* are
// point-in-time (the latest turn's prompt size + the model's window) so a
// context gauge reflects "now", not the lifetime sum.
type usageDelta struct {
	input         uint64
	output        uint64
	cached        uint64
	costUSD       float64
	contextUsed   uint64 // this turn's prompt size (input + cached)
	contextWindow uint64 // model max; 0 when the agent doesn't report it
}

// SessionUsage is the cumulative snapshot surfaced in the status frame.
type SessionUsage struct {
	InputTokens         uint64
	OutputTokens        uint64
	CachedTokens        uint64
	CostUSD             float64
	ContextUsedTokens   uint64
	ContextWindowTokens uint64
	HasUsage            bool
}

// accumulateUsage folds one turn's usage into the running totals. Cost +
// tokens add up; the context gauge tracks the latest turn only.
func (s *Session) accumulateUsage(d usageDelta) {
	s.mu.Lock()
	s.totalInputTokens += d.input
	s.totalOutputTokens += d.output
	s.totalCachedTokens += d.cached
	s.totalCostUSD += d.costUSD
	s.contextUsedTokens = d.contextUsed
	if d.contextWindow > 0 {
		s.contextWindowTokens = d.contextWindow
	}
	// Defensive clamp: current context occupancy can never exceed the
	// model's window. A bad delta (e.g. a summed-across-API-calls value)
	// would otherwise pin the gauge past 100%.
	if s.contextWindowTokens > 0 && s.contextUsedTokens > s.contextWindowTokens {
		s.contextUsedTokens = s.contextWindowTokens
	}
	s.hasUsage = true
	s.mu.Unlock()
	// Push the updated totals to connected clients NOW. Usage accumulates on
	// turn completion, but the broker otherwise only sends a status frame on
	// connect — so without this re-broadcast the usage card never updates
	// live (it stayed hidden on a session whose first turn finished while you
	// were watching, and only appeared after a reconnect). Broadcast OUTSIDE
	// the lock: StatusPayload re-acquires s.mu via its accessors.
	s.broadcastStatus()
	// Codex account usage (the 5h/weekly windows) is freshest right after a
	// turn: the `codex exec` that produced it just refreshed the short-lived
	// OAuth token in auth.json, and the utilisation just changed. Kick a
	// background refresh so the card stays live without waiting for a manual
	// pull. Best-effort + off the hot path; claude pulls its usage on connect
	// instead (its token is long-lived, so a per-turn refetch buys nothing).
	if s.Assistant == "codex" {
		go s.RefreshAccountUsage()
	}
	// Persist the updated totals (meta.json) so a broker restart doesn't
	// blank the usage card — recovery restores these fields. Best-effort
	// and once per turn-completion, so the extra write is negligible.
	// (metaPath is empty on bare test fixtures — nothing to persist to.)
	if s.metaPath != "" {
		_ = s.persistMetadata()
	}
}

// Usage returns the cumulative usage snapshot for the status frame.
func (s *Session) Usage() SessionUsage {
	s.mu.Lock()
	defer s.mu.Unlock()
	return SessionUsage{
		InputTokens:         s.totalInputTokens,
		OutputTokens:        s.totalOutputTokens,
		CachedTokens:        s.totalCachedTokens,
		CostUSD:             s.totalCostUSD,
		ContextUsedTokens:   s.contextUsedTokens,
		ContextWindowTokens: s.contextWindowTokens,
		HasUsage:            s.hasUsage,
	}
}

// parseClaudeUsage lifts one turn's usage out of a claude stream-json
// `result` envelope (input/output/cache tokens + total_cost_usd, and the
// model's contextWindow from `modelUsage`). ok=false for any other line.
func parseClaudeUsage(line []byte) (usageDelta, bool) {
	var ev struct {
		Type         string  `json:"type"`
		TotalCostUSD float64 `json:"total_cost_usd"`
		Usage        struct {
			InputTokens              uint64 `json:"input_tokens"`
			OutputTokens             uint64 `json:"output_tokens"`
			CacheReadInputTokens     uint64 `json:"cache_read_input_tokens"`
			CacheCreationInputTokens uint64 `json:"cache_creation_input_tokens"`
		} `json:"usage"`
		ModelUsage map[string]struct {
			ContextWindow uint64 `json:"contextWindow"`
		} `json:"modelUsage"`
	}
	if err := json.Unmarshal(line, &ev); err != nil || ev.Type != "result" {
		return usageDelta{}, false
	}
	var window uint64
	for _, m := range ev.ModelUsage {
		if m.ContextWindow > window {
			window = m.ContextWindow
		}
	}
	cached := ev.Usage.CacheReadInputTokens + ev.Usage.CacheCreationInputTokens
	return usageDelta{
		input:         ev.Usage.InputTokens,
		output:        ev.Usage.OutputTokens,
		cached:        cached,
		costUSD:       ev.TotalCostUSD,
		contextUsed:   ev.Usage.InputTokens + cached,
		contextWindow: window,
	}, true
}

// parseClaudeContextTokens lifts the *current* context-window occupancy from a
// claude stream-json `assistant` message line: the prompt size of that single
// API call (input + cache read + cache creation). Claude makes one such call
// per tool-use cycle within a turn, so the LATEST assistant message reflects the
// live context size.
//
// This exists because the turn-end `result` envelope's usage is the SUM across
// every API call in the turn (its total_cost_usd is likewise cumulative). A turn
// with many tool calls re-reads the cached conversation prefix on each call, so
// the summed cache_read alone can reach millions — which is how the context
// gauge showed "2.5M / 1.0M" after a 111-command turn. The last call's prompt
// size is the real occupancy and is bounded by the window.
//
// ok=false for any non-assistant line or one carrying no usage.
func parseClaudeContextTokens(line []byte) (uint64, bool) {
	var ev struct {
		Type    string `json:"type"`
		Message struct {
			Usage struct {
				InputTokens              uint64 `json:"input_tokens"`
				CacheReadInputTokens     uint64 `json:"cache_read_input_tokens"`
				CacheCreationInputTokens uint64 `json:"cache_creation_input_tokens"`
			} `json:"usage"`
		} `json:"message"`
	}
	if err := json.Unmarshal(line, &ev); err != nil || ev.Type != "assistant" {
		return 0, false
	}
	used := ev.Message.Usage.InputTokens +
		ev.Message.Usage.CacheReadInputTokens +
		ev.Message.Usage.CacheCreationInputTokens
	if used == 0 {
		return 0, false
	}
	return used, true
}

// parseCodexUsage lifts one turn's usage out of a codex `turn.completed`
// event. Codex reports tokens but no per-call cost or context window.
func parseCodexUsage(line []byte) (usageDelta, bool) {
	var ev struct {
		Type  string `json:"type"`
		Usage struct {
			InputTokens           uint64 `json:"input_tokens"`
			CachedInputTokens     uint64 `json:"cached_input_tokens"`
			OutputTokens          uint64 `json:"output_tokens"`
			ReasoningOutputTokens uint64 `json:"reasoning_output_tokens"`
		} `json:"usage"`
	}
	if err := json.Unmarshal(line, &ev); err != nil || ev.Type != "turn.completed" {
		return usageDelta{}, false
	}
	return usageDelta{
		input:       ev.Usage.InputTokens,
		output:      ev.Usage.OutputTokens + ev.Usage.ReasoningOutputTokens,
		cached:      ev.Usage.CachedInputTokens,
		contextUsed: ev.Usage.InputTokens,
	}, true
}
