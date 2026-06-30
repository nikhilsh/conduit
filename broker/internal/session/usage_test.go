package session

import (
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

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

func TestParseClaudeContextTokens(t *testing.T) {
	// An assistant message carries this single API call's prompt size.
	line := `{"type":"assistant","message":{"role":"assistant","usage":{"input_tokens":12,"cache_read_input_tokens":850000,"cache_creation_input_tokens":1500,"output_tokens":40}}}`
	used, ok := parseClaudeContextTokens([]byte(line))
	if !ok {
		t.Fatal("expected an assistant usage line to parse")
	}
	if used != 12+850000+1500 {
		t.Fatalf("used=%d want %d", used, 12+850000+1500)
	}
	// Non-assistant lines and usage-less assistant lines don't parse.
	if _, ok := parseClaudeContextTokens([]byte(`{"type":"result","usage":{"input_tokens":5}}`)); ok {
		t.Fatal("result line should not parse as context tokens")
	}
	if _, ok := parseClaudeContextTokens([]byte(`{"type":"assistant","message":{"role":"assistant","content":[]}}`)); ok {
		t.Fatal("assistant line with no usage should not parse")
	}
}

// The whole point of the fix: a turn's context occupancy is the LAST API
// call's prompt size, not the result envelope's summed-across-calls usage.
func TestProcessClaudeStreamOutputContextIsLastCall(t *testing.T) {
	claudeChatNow = func() time.Time { return time.Unix(0, 0).UTC() }
	defer func() { claudeChatNow = time.Now }()

	// Three tool-use calls each re-read the cached prefix; the result
	// envelope sums them (cache_read 900000) which would overcount context.
	// The last assistant call's prompt is 500012 — that's the real
	// occupancy and must be what onUsage receives.
	stream := strings.Join([]string{
		`{"type":"assistant","message":{"role":"assistant","usage":{"input_tokens":4,"cache_read_input_tokens":100000,"cache_creation_input_tokens":8}}}`,
		`{"type":"assistant","message":{"role":"assistant","usage":{"input_tokens":6,"cache_read_input_tokens":300000,"cache_creation_input_tokens":0}}}`,
		`{"type":"assistant","message":{"role":"assistant","usage":{"input_tokens":12,"cache_read_input_tokens":500000,"cache_creation_input_tokens":0}}}`,
		`{"type":"result","total_cost_usd":0.5,"usage":{"input_tokens":22,"output_tokens":40,"cache_read_input_tokens":900000,"cache_creation_input_tokens":8},"modelUsage":{"claude-opus-4-8[1m]":{"contextWindow":1000000}}}`,
	}, "\n")

	var got usageDelta
	var calls int
	err := processClaudeStreamOutput(strings.NewReader(stream), func([]byte) {}, nil, nil, func(u usageDelta) {
		got = u
		calls++
	}, nil, nil, nil, nil, nil)
	if err != nil {
		t.Fatalf("process: %v", err)
	}
	if calls != 1 {
		t.Fatalf("expected onUsage once, got %d", calls)
	}
	// contextUsed = last call's prompt (12 + 500000 + 0), NOT the summed
	// result (22 + 900000 + 8 = 900030).
	if got.contextUsed != 500012 {
		t.Fatalf("contextUsed=%d want 500012 (last call), not the summed result", got.contextUsed)
	}
	// Cumulative fields still come from the result envelope.
	if got.contextWindow != 1000000 {
		t.Fatalf("contextWindow=%d want 1000000", got.contextWindow)
	}
	if got.costUSD == 0 {
		t.Fatal("expected cumulative cost from the result envelope")
	}
}

func TestAccumulateUsageClampsContext(t *testing.T) {
	s := &Session{}
	// A pathological delta whose contextUsed exceeds the window must clamp.
	s.accumulateUsage(usageDelta{contextUsed: 2_500_000, contextWindow: 1_000_000})
	if u := s.Usage(); u.ContextUsedTokens != 1_000_000 {
		t.Fatalf("contextUsed=%d want clamped to 1000000", u.ContextUsedTokens)
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

// Usage must survive a broker restart: accumulateUsage persists the
// totals + context gauge into meta.json and recovery restores them
// (post-v0.0.117 — a redeploy used to blank the Session Info usage
// card until the next turn).
func TestUsagePersistsAcrossRestart(t *testing.T) {
	dir := t.TempDir()
	s := &Session{}
	s.metaPath = filepath.Join(dir, "meta.json")
	s.accumulateUsage(usageDelta{
		input: 100, output: 200, cached: 4000, costUSD: 1.25,
		contextUsed: 4100, contextWindow: 1_000_000,
	})

	raw, err := os.ReadFile(s.metaPath)
	if err != nil {
		t.Fatalf("meta.json not written: %v", err)
	}
	var meta sessionMetadata
	if err := json.Unmarshal(raw, &meta); err != nil {
		t.Fatalf("meta.json unmarshal: %v", err)
	}
	if meta.TotalInputTokens != 100 || meta.TotalOutputTokens != 200 ||
		meta.TotalCachedTokens != 4000 || meta.TotalCostUSD != 1.25 ||
		meta.ContextUsedTokens != 4100 || meta.ContextWindowTokens != 1_000_000 {
		t.Fatalf("persisted usage mismatch: %+v", meta)
	}

	// The recovery side is a plain field copy (recovery.go); pin the
	// hasUsage derivation contract here: any restored tokens mean the
	// usage card shows.
	restored := &Session{}
	restored.totalInputTokens = meta.TotalInputTokens
	restored.totalOutputTokens = meta.TotalOutputTokens
	restored.totalCachedTokens = meta.TotalCachedTokens
	restored.totalCostUSD = meta.TotalCostUSD
	restored.contextUsedTokens = meta.ContextUsedTokens
	restored.contextWindowTokens = meta.ContextWindowTokens
	restored.hasUsage = meta.TotalInputTokens > 0 || meta.TotalOutputTokens > 0 ||
		meta.ContextUsedTokens > 0
	u := restored.Usage()
	if !u.HasUsage || u.ContextUsedTokens != 4100 || u.ContextWindowTokens != 1_000_000 {
		t.Fatalf("restored usage mismatch: %+v", u)
	}
}
