package session

import (
	"encoding/base64"
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"testing"
	"time"

	"github.com/nikhilsh/conduit/broker/internal/credentials"
)

func anthropicBlob(expiresAt int64) []byte {
	return []byte(fmt.Sprintf(`{"claudeAiOauth":{"accessToken":"AT","refreshToken":"RT","expiresAt":%d,"subscriptionType":"max"}}`, expiresAt))
}

func openaiBlob(exp int64) []byte {
	enc := base64.RawURLEncoding
	header := enc.EncodeToString([]byte(`{"alg":"none"}`))
	payload := enc.EncodeToString([]byte(fmt.Sprintf(`{"exp":%d}`, exp)))
	return []byte(fmt.Sprintf(`{"tokens":{"access_token":"%s.%s.sig"}}`, header, payload))
}

func TestCredentialExpiryMillis(t *testing.T) {
	if got, ok := credentialExpiryMillis("anthropic", anthropicBlob(1780763004455)); !ok || got != 1780763004455 {
		t.Fatalf("anthropic: got (%d,%v), want (1780763004455,true)", got, ok)
	}
	if got, ok := credentialExpiryMillis("openai", openaiBlob(1780763004)); !ok || got != 1780763004000 {
		t.Fatalf("openai jwt exp: got (%d,%v), want (1780763004000,true)", got, ok)
	}
	if got, ok := credentialExpiryMillis("openai", []byte(`{"tokens":{"access_token":"not-a-jwt"},"last_refresh":"2026-05-29T07:47:01.698078980Z"}`)); !ok || got != time.Date(2026, 5, 29, 7, 47, 1, 698078980, time.UTC).UnixMilli() {
		t.Fatalf("openai last_refresh fallback: got (%d,%v)", got, ok)
	}
	for _, bad := range [][]byte{nil, []byte("{"), []byte(`{}`), []byte(`{"claudeAiOauth":{}}`)} {
		if _, ok := credentialExpiryMillis("anthropic", bad); ok {
			t.Fatalf("anthropic %q: want ok=false", bad)
		}
	}
	if _, ok := credentialExpiryMillis("ollama", anthropicBlob(1)); ok {
		t.Fatal("unknown provider: want ok=false")
	}
}

// seedHostClaude writes a host-login credentials file with the given
// expiry under a temp CONDUIT_HOST_HOME.
func seedHostClaude(t *testing.T, expiresAt int64) string {
	t.Helper()
	hostHome := t.TempDir()
	t.Setenv("CONDUIT_HOST_HOME", hostHome)
	if err := os.MkdirAll(filepath.Join(hostHome, ".claude"), 0o700); err != nil {
		t.Fatalf("mkdir: %v", err)
	}
	if err := os.WriteFile(filepath.Join(hostHome, ".claude", ".credentials.json"), anthropicBlob(expiresAt), 0o600); err != nil {
		t.Fatalf("write host creds: %v", err)
	}
	return hostHome
}

func TestUseHostOverAppBlob_ExpiredBlobLosesToFresherHost(t *testing.T) {
	now := time.Now().UnixMilli()
	seedHostClaude(t, now+3*time.Hour.Milliseconds())
	skip, _, _ := useHostOverAppBlob("anthropic", anthropicBlob(now-time.Hour.Milliseconds()))
	if !skip {
		t.Fatal("expired blob + fresh host: want skip=true")
	}
}

func TestUseHostOverAppBlob_ValidBlobAlwaysWins(t *testing.T) {
	// Host is fresher, but the blob is still valid — the app account
	// may be a deliberately different identity, so it must be honored.
	now := time.Now().UnixMilli()
	seedHostClaude(t, now+5*time.Hour.Milliseconds())
	skip, _, _ := useHostOverAppBlob("anthropic", anthropicBlob(now+time.Hour.Milliseconds()))
	if skip {
		t.Fatal("valid blob: want skip=false even when host is fresher")
	}
}

func TestUseHostOverAppBlob_NoHostKeepsBlob(t *testing.T) {
	hostHome := t.TempDir() // empty — no .claude login on the host
	t.Setenv("CONDUIT_HOST_HOME", hostHome)
	skip, _, _ := useHostOverAppBlob("anthropic", anthropicBlob(1))
	if skip {
		t.Fatal("expired blob but no host login: want skip=false (blob is all we have)")
	}
}

func TestRefreshStaleAgentCredentials_RemirrorsExpiredCopy(t *testing.T) {
	now := time.Now().UnixMilli()
	hostExp := now + 3*time.Hour.Milliseconds()
	seedHostClaude(t, hostExp)

	ephemeral := t.TempDir()
	credPath := filepath.Join(ephemeral, ".claude", ".credentials.json")
	if err := os.MkdirAll(filepath.Dir(credPath), 0o700); err != nil {
		t.Fatalf("mkdir: %v", err)
	}
	if err := os.WriteFile(credPath, anthropicBlob(now-time.Hour.Milliseconds()), 0o600); err != nil {
		t.Fatalf("write stale copy: %v", err)
	}

	s := &Session{ID: "t", agentHomeDir: ephemeral, agentCredProvider: "anthropic"}
	s.refreshStaleAgentCredentials()

	got, err := os.ReadFile(credPath)
	if err != nil {
		t.Fatalf("read copy: %v", err)
	}
	if exp, ok := credentialExpiryMillis("anthropic", got); !ok || exp != hostExp {
		t.Fatalf("copy not re-mirrored: expiry (%d,%v), want (%d,true)", exp, ok, hostExp)
	}
}

func TestRefreshStaleAgentCredentials_NeverClobbersFresherCopy(t *testing.T) {
	// The session's agent refreshed its own copy and now holds the
	// newest lineage; the (older) host file must not overwrite it —
	// and a still-valid copy is left alone entirely.
	now := time.Now().UnixMilli()
	seedHostClaude(t, now+time.Hour.Milliseconds())

	ephemeral := t.TempDir()
	credPath := filepath.Join(ephemeral, ".claude", ".credentials.json")
	if err := os.MkdirAll(filepath.Dir(credPath), 0o700); err != nil {
		t.Fatalf("mkdir: %v", err)
	}
	want := anthropicBlob(now + 2*time.Hour.Milliseconds())
	if err := os.WriteFile(credPath, want, 0o600); err != nil {
		t.Fatalf("write copy: %v", err)
	}

	s := &Session{ID: "t", agentHomeDir: ephemeral, agentCredProvider: "anthropic"}
	s.refreshStaleAgentCredentials()

	got, err := os.ReadFile(credPath)
	if err != nil {
		t.Fatalf("read copy: %v", err)
	}
	if string(got) != string(want) {
		t.Fatal("valid copy was clobbered")
	}
}

func TestRefreshStaleAgentCredentials_ExpiredEverywhereLeavesCopy(t *testing.T) {
	// Host is also expired and staler than the copy — nothing to heal
	// from; leave the copy untouched rather than churning the file.
	now := time.Now().UnixMilli()
	seedHostClaude(t, now-2*time.Hour.Milliseconds())

	ephemeral := t.TempDir()
	credPath := filepath.Join(ephemeral, ".claude", ".credentials.json")
	if err := os.MkdirAll(filepath.Dir(credPath), 0o700); err != nil {
		t.Fatalf("mkdir: %v", err)
	}
	want := anthropicBlob(now - time.Hour.Milliseconds())
	if err := os.WriteFile(credPath, want, 0o600); err != nil {
		t.Fatalf("write copy: %v", err)
	}

	s := &Session{ID: "t", agentHomeDir: ephemeral, agentCredProvider: "anthropic"}
	s.refreshStaleAgentCredentials()

	got, err := os.ReadFile(credPath)
	if err != nil {
		t.Fatalf("read copy: %v", err)
	}
	if string(got) != string(want) {
		t.Fatal("copy replaced by a staler host file")
	}
}

func TestRefreshStaleAgentCredentials_MaterializesAppBlobIntoSessionSpawnedWithout(t *testing.T) {
	// Simulates the live 401 bug: session spawned when no app credential
	// existed, so agentHomeDir has no credential file. App later pushes
	// a blob. On the next watchdog tick the blob must be materialized.
	now := time.Now().UnixMilli()

	storeDir := t.TempDir()
	store := credentials.NewStore(storeDir, nil)
	blob := anthropicBlob(now + 3*time.Hour.Milliseconds())
	if err := store.Set("anthropic", json.RawMessage(blob)); err != nil {
		t.Fatalf("store.Set: %v", err)
	}

	ephemeral := t.TempDir()
	credPath := filepath.Join(ephemeral, ".claude", ".credentials.json")
	// Do NOT write credPath — session spawned with no credential.

	s := &Session{
		ID:                "t",
		agentHomeDir:      ephemeral,
		agentCredProvider: "anthropic",
		agentCredStore:    store,
	}
	s.refreshStaleAgentCredentials()

	got, err := os.ReadFile(credPath)
	if err != nil {
		t.Fatalf("credential not materialized: %v", err)
	}
	if exp, ok := credentialExpiryMillis("anthropic", got); !ok || exp != now+3*time.Hour.Milliseconds() {
		t.Fatalf("materialized blob has wrong expiry: (%d,%v)", exp, ok)
	}
}

func TestRefreshStaleAgentCredentials_NoStoreNoCredentialIsNoop(t *testing.T) {
	// Session spawned with no credential and no store wired — should be
	// a safe no-op, not a panic or error.
	ephemeral := t.TempDir()
	// No credPath written, no store.
	s := &Session{ID: "t", agentHomeDir: ephemeral, agentCredProvider: "anthropic"}
	s.refreshStaleAgentCredentials() // must not panic
}
