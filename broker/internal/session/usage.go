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
	defer s.mu.Unlock()
	s.totalInputTokens += d.input
	s.totalOutputTokens += d.output
	s.totalCachedTokens += d.cached
	s.totalCostUSD += d.costUSD
	s.contextUsedTokens = d.contextUsed
	if d.contextWindow > 0 {
		s.contextWindowTokens = d.contextWindow
	}
	s.hasUsage = true
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
