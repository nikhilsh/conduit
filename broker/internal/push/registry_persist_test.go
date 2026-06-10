package push

import (
	"os"
	"path/filepath"
	"testing"
)

func TestRegistryPersistenceRoundTrip(t *testing.T) {
	path := filepath.Join(t.TempDir(), "push-tokens.json")

	r1 := NewRegistryWithPersistence(path)
	r1.Register("alice", tok(PlatformAPNs, "a1"))
	r1.Register("alice", tok(PlatformFCM, "f1"))
	r1.Register("bob", tok(PlatformUnifiedPush, "https://ntfy.example.com/push/abc"))

	// Reload from disk.
	r2 := NewRegistryWithPersistence(path)

	aliceTokens := r2.TokensFor("alice")
	if len(aliceTokens) != 2 {
		t.Fatalf("alice: got %d tokens after reload, want 2", len(aliceTokens))
	}
	bobTokens := r2.TokensFor("bob")
	if len(bobTokens) != 1 || bobTokens[0].Platform != PlatformUnifiedPush {
		t.Fatalf("bob: got %+v after reload, want 1 unifiedpush token", bobTokens)
	}
}

func TestRegistryPersistenceUnregisterPersists(t *testing.T) {
	path := filepath.Join(t.TempDir(), "push-tokens.json")

	r1 := NewRegistryWithPersistence(path)
	r1.Register("alice", tok(PlatformAPNs, "a1"))
	r1.Register("alice", tok(PlatformFCM, "f1"))
	r1.Unregister("alice", tok(PlatformAPNs, "a1"))

	r2 := NewRegistryWithPersistence(path)
	tokens := r2.TokensFor("alice")
	if len(tokens) != 1 || tokens[0].Platform != PlatformFCM {
		t.Fatalf("after unregister+reload: got %+v, want 1 fcm token", tokens)
	}
}

func TestRegistryPersistenceFileMode(t *testing.T) {
	path := filepath.Join(t.TempDir(), "push-tokens.json")
	r := NewRegistryWithPersistence(path)
	r.Register("alice", tok(PlatformAPNs, "a1"))

	fi, err := os.Stat(path)
	if err != nil {
		t.Fatalf("stat: %v", err)
	}
	if fi.Mode().Perm() != 0o600 {
		t.Errorf("perm=%o, want 600", fi.Mode().Perm())
	}
}

func TestRegistryWithoutPersistenceStillWorks(t *testing.T) {
	r := NewRegistry()
	r.Register("alice", tok(PlatformAPNs, "a1"))
	tokens := r.TokensFor("alice")
	if len(tokens) != 1 {
		t.Fatalf("got %d tokens, want 1", len(tokens))
	}
	// Unregister must not panic without a persistPath.
	r.Unregister("alice", tok(PlatformAPNs, "a1"))
	if n := len(r.TokensFor("alice")); n != 0 {
		t.Fatalf("expected 0 after unregister, got %d", n)
	}
}
