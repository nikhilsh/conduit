package session

import (
	"context"
	"os"
	"path/filepath"
	"reflect"
	"testing"
	"time"
)

// writeCodexCreds drops a minimal `.codex/auth.json` into a fresh ephemeral
// HOME so codexCredsPresent / the codex provider selection sees creds.
func writeCodexCreds(t *testing.T) string {
	t.Helper()
	home := t.TempDir()
	p := filepath.Join(home, ".codex", "auth.json")
	if err := os.MkdirAll(filepath.Dir(p), 0o700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(p, []byte(`{"tokens":{"access_token":"codex-tok"}}`), 0o600); err != nil {
		t.Fatal(err)
	}
	return home
}

// TestCodexGenCompleteAgainstStub proves codexGen.Complete spawns `codex
// exec`, parses the final agent_message out of the JSONL, and returns it.
func TestCodexGenCompleteAgainstStub(t *testing.T) {
	dir := t.TempDir()
	// Stub: ignore the argv prompt, emit a thread.started then the
	// agent_message item.completed the parser lifts the title/replies from.
	bin := writeStubBinary(t, dir, "codex", `
echo '{"type":"thread.started","thread_id":"th-1"}'
echo '{"type":"turn.started"}'
echo '{"type":"item.completed","item":{"type":"agent_message","text":"Debug Broker Session Limit"}}'
echo '{"type":"turn.completed"}'
`)
	g := &codexGen{binary: bin}
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	got, err := g.Complete(ctx, "system", "summarize this", 32)
	if err != nil {
		t.Fatalf("Complete: %v", err)
	}
	if got != "Debug Broker Session Limit" {
		t.Fatalf("got %q, want %q", got, "Debug Broker Session Limit")
	}
}

// TestCodexGenCompleteNoMessage proves a run that emits no agent_message is a
// clean error (best-effort skip), not a panic or empty success.
func TestCodexGenCompleteNoMessage(t *testing.T) {
	dir := t.TempDir()
	bin := writeStubBinary(t, dir, "codex", `
echo '{"type":"thread.started","thread_id":"th-1"}'
echo '{"type":"turn.completed"}'
`)
	g := &codexGen{binary: bin}
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	if _, err := g.Complete(ctx, "", "hi", 32); err == nil {
		t.Fatal("expected error when no agent_message in output")
	}
}

func TestCodexGenArgv(t *testing.T) {
	// No model → --model omitted.
	got := codexGenArgv("codex", "", "do it")
	want := []string{"codex", "exec", "--json", "--skip-git-repo-check", "-c", "model_reasoning_effort=low", "do it"}
	if !reflect.DeepEqual(got, want) {
		t.Fatalf("no-model argv = %v, want %v", got, want)
	}
	// Model present → --model inserted before the prompt.
	got = codexGenArgv("codex", "gpt-5-mini", "do it")
	want = []string{"codex", "exec", "--json", "--skip-git-repo-check", "-c", "model_reasoning_effort=low", "--model", "gpt-5-mini", "do it"}
	if !reflect.DeepEqual(got, want) {
		t.Fatalf("model argv = %v, want %v", got, want)
	}
}

func TestSmallestCodexModel(t *testing.T) {
	// nil catalog → "".
	if got := smallestCodexModel(nil); got != "" {
		t.Fatalf("nil catalog = %q, want empty", got)
	}
	// Prefers a -mini suffix.
	cat := map[string][]ModelInfo{"codex": {
		{ID: "gpt-5", Efforts: []string{"low", "high"}},
		{ID: "gpt-5-mini", Efforts: []string{"low"}},
	}}
	if got := smallestCodexModel(cat); got != "gpt-5-mini" {
		t.Fatalf("mini preference = %q, want gpt-5-mini", got)
	}
	// No -mini → fewest efforts wins.
	cat = map[string][]ModelInfo{"codex": {
		{ID: "big", Efforts: []string{"low", "medium", "high"}},
		{ID: "small", Efforts: []string{"low"}},
	}}
	if got := smallestCodexModel(cat); got != "small" {
		t.Fatalf("fewest-efforts = %q, want small", got)
	}
}

// TestSelectAIGenProviderNoCreds proves that when neither agent has creds, no
// provider is selected — so no generation is attempted and no error surfaces.
func TestSelectAIGenProviderNoCreds(t *testing.T) {
	home := t.TempDir() // no .claude/.credentials.json, no .codex/auth.json
	if p := selectAIGenProvider("claude", home, "codex", nil, nil); p != nil {
		t.Fatalf("claude with no creds: got %T, want nil", p)
	}
	if p := selectAIGenProvider("codex", home, "codex", nil, nil); p != nil {
		t.Fatalf("codex with no creds: got %T, want nil", p)
	}
}

// TestSelectAIGenProviderPrefersOwnAgent proves the session's own agent's
// provider is chosen when its creds are present.
func TestSelectAIGenProviderPrefersOwnAgent(t *testing.T) {
	// claude session with anthropic creds → anthropicGen.
	claudeHome := writeCreds(t, "tok", time.Now().Add(time.Hour).UnixMilli())
	if p := selectAIGenProvider("claude", claudeHome, "codex", nil, nil); p == nil {
		t.Fatal("claude with anthropic creds: got nil")
	} else if _, ok := p.(*anthropicGen); !ok {
		t.Fatalf("claude: got %T, want *anthropicGen", p)
	}
	// codex session with codex creds → codexGen.
	codexHome := writeCodexCreds(t)
	if p := selectAIGenProvider("codex", codexHome, "codex", nil, nil); p == nil {
		t.Fatal("codex with codex creds: got nil")
	} else if _, ok := p.(*codexGen); !ok {
		t.Fatalf("codex: got %T, want *codexGen", p)
	}
}

// TestSelectAIGenProviderFallsBack proves a session falls back to the OTHER
// agent's provider when its own creds are missing.
func TestSelectAIGenProviderFallsBack(t *testing.T) {
	// codex session, only anthropic creds present → falls back to anthropicGen.
	anthHome := writeCreds(t, "tok", time.Now().Add(time.Hour).UnixMilli())
	if p := selectAIGenProvider("codex", anthHome, "codex", nil, nil); p == nil {
		t.Fatal("codex falling back: got nil")
	} else if _, ok := p.(*anthropicGen); !ok {
		t.Fatalf("codex fallback: got %T, want *anthropicGen", p)
	}
	// claude session, only codex creds present → falls back to codexGen.
	codexHome := writeCodexCreds(t)
	if p := selectAIGenProvider("claude", codexHome, "codex", nil, nil); p == nil {
		t.Fatal("claude falling back: got nil")
	} else if _, ok := p.(*codexGen); !ok {
		t.Fatalf("claude fallback: got %T, want *codexGen", p)
	}
	// Fallback to codex needs a binary: no codexBinary → no codex provider.
	if p := selectAIGenProvider("claude", codexHome, "", nil, nil); p != nil {
		t.Fatalf("claude fallback with no codex binary: got %T, want nil", p)
	}
}

// TestCodexGenCompleteFoldsSystemPrompt proves the system prompt is folded
// into the single codex-exec argv prompt (codex exec has no system channel):
// the stub emits the answer ONLY when the last argv (the prompt) contains
// both the system and user markers.
func TestCodexGenCompleteFoldsSystemPrompt(t *testing.T) {
	dir := t.TempDir()
	// The prompt is the last positional arg. POSIX sh: capture it by shifting
	// to the last. We assert via a `case` glob that both markers are present.
	bin := writeStubBinary(t, dir, "codex", `
for last in "$@"; do :; done
echo '{"type":"thread.started","thread_id":"th-1"}'
case "$last" in
  *SYS*USER*) echo '{"type":"item.completed","item":{"type":"agent_message","text":"folded-ok"}}' ;;
  *) echo '{"type":"item.completed","item":{"type":"agent_message","text":"missing"}}' ;;
esac
`)
	g := &codexGen{binary: bin}
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	got, err := g.Complete(ctx, "SYS", "USER", 16)
	if err != nil {
		t.Fatalf("Complete: %v", err)
	}
	if got != "folded-ok" {
		t.Fatalf("system prompt not folded into argv prompt: got %q", got)
	}
}
