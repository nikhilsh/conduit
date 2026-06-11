package session

import (
	"context"
	"os"
	"path/filepath"
	"reflect"
	"testing"
	"time"
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
	models, err := probeClaudeCatalog(ctx, bin)
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
	models, err := probeCodexCatalog(ctx, bin)
	if err != nil {
		t.Fatal(err)
	}
	if len(models) != 2 || models[0].ID != "gpt-5.5" || !models[0].IsDefault {
		t.Fatalf("unexpected catalog: %+v", models)
	}
}

func TestManagerModelCatalogSnapshotAndInjection(t *testing.T) {
	resetDynamicEfforts()
	defer resetDynamicEfforts()

	root := testRoot(t)
	reg := testRegistry(t, root, map[string]string{"claude": idleScript("catalog-ready")})
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
