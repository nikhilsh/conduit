package session

import (
	"testing"
)

// mockModelBackend is a minimal chatBackend+modelReporter stub for unit tests.
type mockModelBackend struct {
	model      string
	turnActive bool
}

func (m *mockModelBackend) Send(_ string) error  { return nil }
func (m *mockModelBackend) Interrupt() error     { return nil }
func (m *mockModelBackend) Close() error         { return nil }
func (m *mockModelBackend) TurnActive() bool     { return m.turnActive }
func (m *mockModelBackend) CurrentModel() string { return m.model }

// TestStatusPayload_ModelFromBackend verifies that StatusPayload includes the
// "model" key when the chat backend reports one via modelReporter.
func TestStatusPayload_ModelFromBackend(t *testing.T) {
	s := &Session{
		ID:        "test-model-backend",
		Assistant: "claude",
		chat:      &mockModelBackend{model: "claude-sonnet-4-6"},
	}
	payload := s.StatusPayload()
	got, ok := payload["model"]
	if !ok {
		t.Fatal("StatusPayload: expected \"model\" key, not found")
	}
	if got != "claude-sonnet-4-6" {
		t.Fatalf("StatusPayload model = %q, want %q", got, "claude-sonnet-4-6")
	}
}

// TestStatusPayload_ModelFromOverride verifies the SpawnOverride.Model fallback
// when the backend has no live model yet (e.g. before the first assistant turn).
func TestStatusPayload_ModelFromOverride(t *testing.T) {
	s := &Session{
		ID:        "test-model-override",
		Assistant: "claude",
		// No chat backend wired; only the override carries the model.
		override: SpawnOverride{Model: "claude-haiku-4-5"},
	}
	payload := s.StatusPayload()
	got, ok := payload["model"]
	if !ok {
		t.Fatal("StatusPayload: expected \"model\" key from override, not found")
	}
	if got != "claude-haiku-4-5" {
		t.Fatalf("StatusPayload override model = %q, want %q", got, "claude-haiku-4-5")
	}
}

// TestStatusPayload_ModelBackendWinsOverOverride verifies that the live backend
// model takes priority over the SpawnOverride when both are set.
func TestStatusPayload_ModelBackendWinsOverOverride(t *testing.T) {
	s := &Session{
		ID:        "test-model-priority",
		Assistant: "claude",
		chat:      &mockModelBackend{model: "claude-opus-4-5"},
		override:  SpawnOverride{Model: "claude-haiku-4-5"},
	}
	payload := s.StatusPayload()
	got, ok := payload["model"]
	if !ok {
		t.Fatal("StatusPayload: expected \"model\" key, not found")
	}
	if got != "claude-opus-4-5" {
		t.Fatalf("StatusPayload model = %q (backend should beat override), want %q", got, "claude-opus-4-5")
	}
}

// TestStatusPayload_ModelAbsentWhenUnknown verifies that the "model" key is
// omitted entirely when neither the backend nor the override carries a model.
func TestStatusPayload_ModelAbsentWhenUnknown(t *testing.T) {
	s := &Session{
		ID:        "test-model-absent",
		Assistant: "claude",
		// No chat backend, no override model.
	}
	payload := s.StatusPayload()
	if _, ok := payload["model"]; ok {
		t.Fatalf("StatusPayload: unexpected \"model\" key = %q, want absent", payload["model"])
	}
}

// TestStatusPayload_ModelBackendEmptyFallsToOverride verifies that a backend
// returning "" (model not yet known) falls through to the override.
func TestStatusPayload_ModelBackendEmptyFallsToOverride(t *testing.T) {
	s := &Session{
		ID:        "test-model-empty-backend",
		Assistant: "claude",
		chat:      &mockModelBackend{model: ""}, // backend knows nothing yet
		override:  SpawnOverride{Model: "claude-sonnet-4-5"},
	}
	payload := s.StatusPayload()
	got, ok := payload["model"]
	if !ok {
		t.Fatal("StatusPayload: expected \"model\" key from override fallback, not found")
	}
	if got != "claude-sonnet-4-5" {
		t.Fatalf("StatusPayload model = %q, want %q", got, "claude-sonnet-4-5")
	}
}
