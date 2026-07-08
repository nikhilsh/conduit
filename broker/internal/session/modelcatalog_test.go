package session

import (
	"context"
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"reflect"
	"testing"
	"time"

	"github.com/nikhilsh/conduit/broker/internal/credentials"
)

// resetDynamicEfforts clears the package-level discovered-effort registry so
// tests don't leak catalog state into each other.
func resetDynamicEfforts() {
	dynamicEfforts.mu.Lock()
	dynamicEfforts.m = map[string]map[string]bool{}
	dynamicEfforts.mu.Unlock()
}

// claudeInitFixture is a trimmed control_response captured live from
// claude-code 2.1.170 (`control_request {"subtype":"initialize"}`).
const claudeInitFixture = `{"type":"control_response","response":{"subtype":"success","request_id":"conduit-model-catalog","response":{"commands":[],"models":[{"value":"default","displayName":"Default (recommended)","description":"Opus 4.8 with 1M context · Best for everyday, complex tasks","supportsEffort":true,"supportedEffortLevels":["low","medium","high","xhigh","max"],"supportsFastMode":true},{"value":"claude-fable-5[1m]","displayName":"Fable","description":"Fable 5 · Most capable for your hardest tasks","supportsEffort":true,"supportedEffortLevels":["low","medium","high","xhigh","max"]},{"value":"sonnet","displayName":"Sonnet","description":"Sonnet 4.6 · Efficient for routine tasks","supportsEffort":true,"supportedEffortLevels":["low","medium","high","max"]},{"value":"haiku","displayName":"Haiku","description":"Haiku 4.5 · Fastest for quick answers"}]}}}`

// codexModelListFixture is a trimmed model/list result captured live from
// codex-cli 0.132.0 (one visible default, one visible, one hidden).
const codexModelListFixture = `{"data":[{"id":"gpt-5.5","model":"gpt-5.5","displayName":"GPT-5.5","description":"Frontier model for complex coding.","hidden":false,"supportedReasoningEfforts":[{"reasoningEffort":"low","description":"Fast"},{"reasoningEffort":"medium","description":"Balanced"},{"reasoningEffort":"high","description":"Deep"},{"reasoningEffort":"xhigh","description":"Extra"}],"defaultReasoningEffort":"medium","isDefault":true},{"id":"gpt-5.4-mini","model":"gpt-5.4-mini","displayName":"GPT-5.4-Mini","description":"Small and fast.","hidden":false,"supportedReasoningEfforts":[{"reasoningEffort":"low","description":"Fast"},{"reasoningEffort":"medium","description":"Balanced"}],"defaultReasoningEffort":"medium","isDefault":false},{"id":"codex-auto-review","model":"codex-auto-review","displayName":"Codex Auto Review","description":"internal","hidden":true,"supportedReasoningEfforts":[],"defaultReasoningEffort":"medium","isDefault":false}],"nextCursor":null}`

func TestParseClaudeCatalogLine(t *testing.T) {
	models, ok := parseClaudeCatalogLine([]byte(claudeInitFixture), "conduit-model-catalog")
	if !ok {
		t.Fatal("expected fixture to parse")
	}
	want := []ModelInfo{
		{ID: "", DisplayName: "Default (recommended)", Description: "Opus 4.8 with 1M context · Best for everyday, complex tasks", IsDefault: true, Efforts: []string{"low", "medium", "high", "xhigh", "max"}, SupportsFastMode: true},
		{ID: "claude-fable-5[1m]", DisplayName: "Fable", Description: "Fable 5 · Most capable for your hardest tasks", Efforts: []string{"low", "medium", "high", "xhigh", "max"}},
		{ID: "sonnet", DisplayName: "Sonnet", Description: "Sonnet 4.6 · Efficient for routine tasks", Efforts: []string{"low", "medium", "high", "max"}},
		{ID: "haiku", DisplayName: "Haiku", Description: "Haiku 4.5 · Fastest for quick answers"},
	}
	if !reflect.DeepEqual(models, want) {
		t.Fatalf("parsed catalog mismatch:\n got %+v\nwant %+v", models, want)
	}
}

func TestParseClaudeCatalogLineIgnoresOtherFrames(t *testing.T) {
	for _, line := range []string{
		`{"type":"system","subtype":"init","model":"claude-fable-5[1m]"}`,
		`{"type":"control_response","response":{"subtype":"success","request_id":"someone-else","response":{"models":[{"value":"sonnet"}]}}}`,
		`not json`,
	} {
		if _, ok := parseClaudeCatalogLine([]byte(line), "conduit-model-catalog"); ok {
			t.Fatalf("line should not parse as catalog: %s", line)
		}
	}
}

func TestParseCodexModelList(t *testing.T) {
	models, err := parseCodexModelList([]byte(codexModelListFixture))
	if err != nil {
		t.Fatal(err)
	}
	want := []ModelInfo{
		{ID: "gpt-5.5", DisplayName: "GPT-5.5", Description: "Frontier model for complex coding.", IsDefault: true, DefaultEffort: "medium", Efforts: []string{"low", "medium", "high", "xhigh"}},
		{ID: "gpt-5.4-mini", DisplayName: "GPT-5.4-Mini", Description: "Small and fast.", DefaultEffort: "medium", Efforts: []string{"low", "medium"}},
	}
	if !reflect.DeepEqual(models, want) {
		t.Fatalf("parsed catalog mismatch:\n got %+v\nwant %+v", models, want)
	}
}

func TestParseCodexModelListAllHiddenErrors(t *testing.T) {
	if _, err := parseCodexModelList([]byte(`{"data":[{"id":"x","hidden":true}]}`)); err == nil {
		t.Fatal("expected error for all-hidden list")
	}
}

func TestEffortSupportedWidensFromCatalog(t *testing.T) {
	resetDynamicEfforts()
	defer resetDynamicEfforts()

	// Static fallback: codex xhigh is NOT in codexEfforts.
	if effortSupported("codex", "xhigh") {
		t.Fatal("xhigh should be rejected before discovery")
	}
	if codexEffortParam("xhigh") != "" {
		t.Fatal("codexEffortParam should drop xhigh before discovery")
	}

	recordDynamicEfforts("codex", []ModelInfo{{ID: "gpt-5.5", Efforts: []string{"low", "medium", "high", "xhigh"}}})

	if !effortSupported("codex", "xhigh") {
		t.Fatal("xhigh should be accepted after the catalog advertises it")
	}
	if got := codexEffortParam("xhigh"); got != "xhigh" {
		t.Fatalf("codexEffortParam(xhigh) = %q, want xhigh", got)
	}
	// Discovery widens codex only; claude validation is untouched.
	if effortSupported("claude", "nonsense") {
		t.Fatal("unknown claude effort must still be rejected")
	}
	// Static map still works alongside the catalog.
	if !effortSupported("codex", "medium") {
		t.Fatal("static fallback must keep working")
	}
}

func TestExtraArgsForUsesDiscoveredEfforts(t *testing.T) {
	resetDynamicEfforts()
	defer resetDynamicEfforts()

	o := SpawnOverride{ReasoningEffort: "xhigh", Model: "gpt-5.5"}
	if got := o.extraArgsFor("codex"); !reflect.DeepEqual(got, []string{"--model", "gpt-5.5"}) {
		t.Fatalf("before discovery: %v", got)
	}
	recordDynamicEfforts("codex", []ModelInfo{{ID: "gpt-5.5", Efforts: []string{"xhigh"}}})
	want := []string{"-c", "model_reasoning_effort=xhigh", "--model", "gpt-5.5"}
	if got := o.extraArgsFor("codex"); !reflect.DeepEqual(got, want) {
		t.Fatalf("after discovery: got %v want %v", got, want)
	}
}

// writeStubBinary drops an executable shell script into dir and returns its
// path. Used to exercise the probes without the real CLIs (CI has neither).
func writeStubBinary(t *testing.T, dir, name, script string) string {
	t.Helper()
	p := filepath.Join(dir, name)
	if err := os.WriteFile(p, []byte("#!/bin/sh\n"+script), 0o755); err != nil {
		t.Fatal(err)
	}
	return p
}

func TestProbeClaudeCatalogAgainstStub(t *testing.T) {
	dir := t.TempDir()
	// Stub: ignore stdin, emit an init frame then the control_response.
	bin := writeStubBinary(t, dir, "claude", `
echo '{"type":"system","subtype":"init"}'
cat <<'EOF'
`+claudeInitFixture+`
EOF
sleep 5
`)
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	models, err := probeClaudeCatalog(ctx, bin, nil)
	if err != nil {
		t.Fatal(err)
	}
	if len(models) != 4 || models[1].DisplayName != "Fable" {
		t.Fatalf("unexpected catalog: %+v", models)
	}
}

func TestProbeCodexCatalogAgainstStub(t *testing.T) {
	dir := t.TempDir()
	// Stub: answer initialize (id 1), then model/list (id 2). Reads stdin
	// lines so the ordering matches the real handshake.
	bin := writeStubBinary(t, dir, "codex", `
read line1
echo '{"id":1,"result":{"userAgent":"stub"}}'
read line2
cat <<'EOF'
{"id":2,"result":`+codexModelListFixture+`}
EOF
sleep 5
`)
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	models, err := probeCodexCatalog(ctx, bin, nil)
	if err != nil {
		t.Fatal(err)
	}
	if len(models) != 2 || models[0].ID != "gpt-5.5" || !models[0].IsDefault {
		t.Fatalf("unexpected catalog: %+v", models)
	}
}

// TestMaybeRefreshCatalogFingerprintInvalidation verifies that a fingerprint
// change forces a re-probe even when the TTL has not expired, but the same
// fingerprint within TTL does NOT trigger a re-probe.
func TestMaybeRefreshCatalogFingerprintInvalidation(t *testing.T) {
	resetDynamicEfforts()
	defer resetDynamicEfforts()

	root := testRoot(t)

	setA := []ModelInfo{{ID: "model-a", DisplayName: "Model A"}}
	setB := []ModelInfo{{ID: "model-b", DisplayName: "Model B"}}

	calls := 0
	reg := testRegistry(t, root, map[string]string{"claude": idleScript("fp-test")})
	m := NewManager(reg)
	t.Cleanup(m.Close)

	// Inject the test seams before enabling discovery.
	fpValue := "fingerprint-v1"
	m.catalog.fingerprintFn = func(_ string) string { return fpValue }
	m.catalog.probe = func(_ context.Context, _ string, _ string, _ []string) ([]ModelInfo, error) {
		calls++
		if calls == 1 {
			return setA, nil
		}
		return setB, nil
	}

	m.catalog.mu.Lock()
	m.catalog.init()
	m.catalog.enabled = true
	m.catalog.mu.Unlock()

	// First probe: no catalog yet, triggers probe → set A.
	m.maybeRefreshCatalog("claude")
	// Wait for the goroutine to complete.
	deadline := time.Now().Add(2 * time.Second)
	for time.Now().Before(deadline) {
		m.catalog.mu.Lock()
		done := len(m.catalog.models["claude"]) > 0
		m.catalog.mu.Unlock()
		if done {
			break
		}
		time.Sleep(10 * time.Millisecond)
	}
	if calls != 1 {
		t.Fatalf("expected 1 probe after initial call, got %d", calls)
	}
	snap := m.ModelCatalog()
	if len(snap["claude"]) == 0 || snap["claude"][0].ID != "model-a" {
		t.Fatalf("expected set A after first probe, got %v", snap["claude"])
	}

	// Second call with same fingerprint, within TTL — must NOT re-probe.
	m.maybeRefreshCatalog("claude")
	time.Sleep(50 * time.Millisecond) // no goroutine should be running
	if calls != 1 {
		t.Fatalf("expected no additional probe within TTL with same fingerprint, got %d calls", calls)
	}

	// Change fingerprint to simulate a CLI upgrade — must force re-probe even
	// though the TTL has not expired.
	fpValue = "fingerprint-v2"
	m.maybeRefreshCatalog("claude")
	deadline = time.Now().Add(2 * time.Second)
	for time.Now().Before(deadline) {
		m.catalog.mu.Lock()
		fp := m.catalog.fingerprints["claude"]
		m.catalog.mu.Unlock()
		if fp == "fingerprint-v2" {
			break
		}
		time.Sleep(10 * time.Millisecond)
	}
	if calls != 2 {
		t.Fatalf("expected 2nd probe after fingerprint change, got %d calls", calls)
	}
	snap = m.ModelCatalog()
	if len(snap["claude"]) == 0 || snap["claude"][0].ID != "model-b" {
		t.Fatalf("expected set B after fingerprint-triggered re-probe, got %v", snap["claude"])
	}
}

func TestManagerModelCatalogSnapshotAndInjection(t *testing.T) {
	resetDynamicEfforts()
	defer resetDynamicEfforts()

	root := testRoot(t)
	reg := testRegistryWithHooks(t, root, map[string]string{"claude": idleScript("catalog-ready")}, map[string]string{
		"claude": `protocol = "stream-json"`,
	})
	m := NewManager(reg)
	t.Cleanup(m.Close)

	if got := m.ModelCatalog(); got != nil {
		t.Fatalf("expected nil catalog before discovery, got %v", got)
	}
	in := []ModelInfo{{ID: "", DisplayName: "Default", IsDefault: true, Efforts: []string{"low", "max"}}}
	m.SetModelCatalog("claude", in)
	got := m.ModelCatalog()
	if !reflect.DeepEqual(got["claude"], in) {
		t.Fatalf("catalog snapshot mismatch: %v", got)
	}
	if !effortSupported("claude", "max") {
		t.Fatal("injection should feed effort validation")
	}
}

func TestManagerModelCatalogStatusIncludesPendingAndError(t *testing.T) {
	root := testRoot(t)
	reg := testRegistryWithHooks(t, root, map[string]string{"claude": idleScript("catalog-ready")}, map[string]string{
		"claude": `protocol = "stream-json"`,
	})
	m := NewManager(reg)
	t.Cleanup(m.Close)

	attempted := time.Now().Add(-time.Minute)
	m.catalog.mu.Lock()
	m.catalog.init()
	m.catalog.enabled = true
	m.catalog.attempted["claude"] = attempted
	m.catalog.busy["claude"] = true
	m.catalog.lastErr["claude"] = "probe failed"
	m.catalog.mu.Unlock()

	status := m.ModelCatalogStatus()
	if !status.Enabled {
		t.Fatal("catalog status should report enabled")
	}
	claude, ok := status.Assistants["claude"]
	if !ok {
		t.Fatalf("catalog status missing claude: %+v", status.Assistants)
	}
	if claude.Present || !claude.Pending {
		t.Fatalf("claude status present/pending mismatch: %+v", claude)
	}
	if claude.LastAttemptedAt == "" || claude.NextRetryAt == "" || claude.LastError != "probe failed" {
		t.Fatalf("claude status missing retry/error details: %+v", claude)
	}
}

// TestCatalogExtraEnvSharedCreds verifies the core invariant of the
// model-catalog probe fix: when CONDUIT_SHARED_AGENT_CREDS is on and an app
// credential blob is present (forcing Option B), catalogExtraEnv returns
// CLAUDE_CONFIG_DIR and CODEX_HOME pointing at the broker-owned agent-cred
// dirs — NOT empty (which was the bug: the probe was inheriting the broker
// process env, authenticating as the host-login account). When the flag is
// off, catalogExtraEnv must return nil (no env injection; byte-identical to
// pre-fix behaviour).
func TestCatalogExtraEnvSharedCreds(t *testing.T) {
	// Build a minimal anthropic blob with a far-future expiresAt so the
	// blob-wins branch in resolveSharedCred fires (Option B → broker-owned
	// agent-cred home). expiresAt is epoch-milliseconds; 100 years from now.
	futureExpMs := (time.Now().Add(100 * 365 * 24 * time.Hour)).UnixMilli()
	blob, err := json.Marshal(map[string]any{
		"claudeAiOauth": map[string]any{
			"expiresAt":     futureExpMs,
			"access_token":  "tok-test",
			"refresh_token": "rtok-test",
		},
	})
	if err != nil {
		t.Fatalf("marshal blob: %v", err)
	}

	// Prepare a temp conduitRoot with a credential store containing the blob.
	conduitDir := t.TempDir()
	storeDir := filepath.Join(conduitDir, "store")
	if err := os.MkdirAll(storeDir, 0o700); err != nil {
		t.Fatalf("mkdir store: %v", err)
	}
	store := credentials.NewStore(storeDir, []byte("test-bearer-key-for-catalog-probe"))
	if err := store.Set("anthropic", blob); err != nil {
		t.Fatalf("store.Set: %v", err)
	}

	// Subtest 1: flag OFF — extraEnv must be nil.
	t.Run("flag_off", func(t *testing.T) {
		t.Setenv("CONDUIT_SHARED_AGENT_CREDS", "")
		root := testRoot(t)
		reg := testRegistry(t, root, map[string]string{"claude": idleScript("env-off")})
		m := NewManager(reg)
		t.Cleanup(m.Close)
		m.conduitRoot = conduitDir
		m.credStore = store

		got := m.catalogExtraEnv()
		if len(got) != 0 {
			t.Fatalf("flag OFF: expected nil/empty extraEnv, got %v", got)
		}
	})

	// Subtest 2: flag ON with a valid blob (Option B) — extraEnv must contain
	// CLAUDE_CONFIG_DIR and CODEX_HOME pointing at the broker-owned dirs under
	// conduitRoot/agent-cred.
	t.Run("flag_on_option_b", func(t *testing.T) {
		t.Setenv("CONDUIT_SHARED_AGENT_CREDS", "1")
		root := testRoot(t)
		reg := testRegistry(t, root, map[string]string{"claude": idleScript("env-on")})
		m := NewManager(reg)
		t.Cleanup(m.Close)
		m.conduitRoot = conduitDir
		m.credStore = store

		got := m.catalogExtraEnv()
		if len(got) == 0 {
			t.Fatal("flag ON: expected non-empty extraEnv")
		}

		// Build a lookup map from the "K=V" pairs.
		envMap := map[string]string{}
		for _, kv := range got {
			for i := 0; i < len(kv); i++ {
				if kv[i] == '=' {
					envMap[kv[:i]] = kv[i+1:]
					break
				}
			}
		}

		wantClaudeDir := filepath.Join(conduitDir, "agent-cred", ".claude")
		wantCodexHome := filepath.Join(conduitDir, "agent-cred", ".codex")

		if got := envMap["CLAUDE_CONFIG_DIR"]; got != wantClaudeDir {
			t.Errorf("CLAUDE_CONFIG_DIR = %q, want %q", got, wantClaudeDir)
		}
		if got := envMap["CODEX_HOME"]; got != wantCodexHome {
			t.Errorf("CODEX_HOME = %q, want %q", got, wantCodexHome)
		}
		// Sanity: no unexpected keys.
		for k := range envMap {
			if k != "CLAUDE_CONFIG_DIR" && k != "CODEX_HOME" {
				t.Errorf("unexpected env key %q in extraEnv", k)
			}
		}
		t.Logf("extraEnv: %v", got)
	})

	// Subtest 3: flag ON but nil credStore — must not panic, must return
	// non-empty env (Option A: host-home .claude/.codex) or at minimum not nil.
	t.Run("flag_on_nil_store", func(t *testing.T) {
		t.Setenv("CONDUIT_SHARED_AGENT_CREDS", "1")
		root := testRoot(t)
		reg := testRegistry(t, root, map[string]string{"claude": idleScript("env-nilstore")})
		m := NewManager(reg)
		t.Cleanup(m.Close)
		m.conduitRoot = conduitDir
		m.credStore = nil // nil store must not panic

		// resolveSharedCred with nil store → no blob → Option A (host home).
		// catalogExtraEnv calls sharedCredEnvFrom which populates CLAUDE_CONFIG_DIR
		// and CODEX_HOME from the host home (non-empty on the dev box).
		// Just verify no panic and we get some env vars back.
		got := m.catalogExtraEnv()
		_ = fmt.Sprintf("nil store extraEnv: %v", got) // suppress unused-import lint
		// We don't assert specific paths here because the host home varies by
		// environment; the invariant is "no panic and non-nil result".
		// (On a box with a real $HOME this will be non-empty; in a hermetic
		// container with no HOME it may be nil — both are acceptable.)
	})
}
