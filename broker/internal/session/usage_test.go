package session

import "testing"

// Real claude stream-json `result` envelope (claude-code 2.1.x) + codex
// `turn.completed` (codex-cli 0.132), captured 2026-05-29.
func TestParseClaudeUsage(t *testing.T) {
	line := `{"type":"result","total_cost_usd":0.0275,"usage":{"input_tokens":1681,"output_tokens":4,"cache_read_input_tokens":10315,"cache_creation_input_tokens":2137},"modelUsage":{"claude-opus-4-8[1m]":{"contextWindow":1000000}}}`
	u, ok := parseClaudeUsage([]byte(line))
	if !ok {
		t.Fatal("expected a result envelope to parse")
	}
	if u.input != 1681 || u.output != 4 {
		t.Fatalf("tokens: input=%d output=%d", u.input, u.output)
	}
	if u.cached != 10315+2137 {
		t.Fatalf("cached=%d want %d", u.cached, 10315+2137)
	}
	if u.costUSD == 0 {
		t.Fatal("expected non-zero cost")
	}
	if u.contextWindow != 1000000 {
		t.Fatalf("contextWindow=%d", u.contextWindow)
	}
	if u.contextUsed != 1681+10315+2137 {
		t.Fatalf("contextUsed=%d want %d", u.contextUsed, 1681+10315+2137)
	}
	if _, ok := parseClaudeUsage([]byte(`{"type":"assistant"}`)); ok {
		t.Fatal("non-result line should not parse")
	}
}

func TestParseCodexUsage(t *testing.T) {
	line := `{"type":"turn.completed","usage":{"input_tokens":33842,"cached_input_tokens":28416,"output_tokens":60,"reasoning_output_tokens":5}}`
	u, ok := parseCodexUsage([]byte(line))
	if !ok {
		t.Fatal("expected turn.completed to parse")
	}
	if u.input != 33842 || u.cached != 28416 {
		t.Fatalf("input=%d cached=%d", u.input, u.cached)
	}
	if u.output != 60+5 { // output + reasoning
		t.Fatalf("output=%d want 65", u.output)
	}
	if u.contextUsed != 33842 {
		t.Fatalf("contextUsed=%d", u.contextUsed)
	}
	if u.costUSD != 0 || u.contextWindow != 0 {
		t.Fatalf("codex should report no cost/window: cost=%v window=%d", u.costUSD, u.contextWindow)
	}
	if _, ok := parseCodexUsage([]byte(`{"type":"turn.started"}`)); ok {
		t.Fatal("non-turn.completed line should not parse")
	}
}

func TestAccumulateUsage(t *testing.T) {
	s := &Session{}
	s.accumulateUsage(usageDelta{input: 100, output: 10, cached: 50, costUSD: 0.01, contextUsed: 150, contextWindow: 200000})
	s.accumulateUsage(usageDelta{input: 200, output: 20, cached: 60, costUSD: 0.02, contextUsed: 280, contextWindow: 200000})
	u := s.Usage()
	if u.InputTokens != 300 || u.OutputTokens != 30 || u.CachedTokens != 110 {
		t.Fatalf("cumulative tokens: in=%d out=%d cached=%d", u.InputTokens, u.OutputTokens, u.CachedTokens)
	}
	if u.CostUSD < 0.0299 || u.CostUSD > 0.0301 {
		t.Fatalf("cumulative cost=%v want ~0.03", u.CostUSD)
	}
	// Context is point-in-time: the latest turn, not the sum.
	if u.ContextUsedTokens != 280 {
		t.Fatalf("contextUsed=%d want 280 (last turn)", u.ContextUsedTokens)
	}
	if u.ContextWindowTokens != 200000 || !u.HasUsage {
		t.Fatalf("window=%d hasUsage=%v", u.ContextWindowTokens, u.HasUsage)
	}
}
