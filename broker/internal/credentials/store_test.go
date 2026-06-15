package credentials

import (
	"bytes"
	"encoding/json"
	"os"
	"path/filepath"
	"runtime"
	"testing"
)

// TestStoreSetGetRoundTrip exercises the encrypt → decrypt cycle for
// every supported provider. Different providers MUST be writable in
// the same store without clobbering each other.
func TestStoreSetGetRoundTrip(t *testing.T) {
	cases := []struct {
		provider string
		blob     string
	}{
		{
			provider: ProviderAnthropic,
			blob: `{
                "claudeAiOauth": {
                    "accessToken": "sk-ant-oat01-abc",
                    "refreshToken": "sk-ant-ort01-def",
                    "expiresAt": 1700000000000,
                    "scopes": ["user:inference", "user:profile"],
                    "subscriptionType": "max"
                }
            }`,
		},
		{
			provider: ProviderOpenAI,
			blob: `{
                "auth_mode": "ChatGPT",
                "OPENAI_API_KEY": null,
                "tokens": {
                    "id_token": "eyJ...",
                    "access_token": "at-123",
                    "refresh_token": "rt-456",
                    "account_id": "acct-789"
                },
                "last_refresh": "2026-05-22T08:00:00Z",
                "agent_identity": null
            }`,
		},
	}
	dir := t.TempDir()
	s := NewStore(dir, []byte("bearer-token-fixture-32-chars--"))
	for _, tc := range cases {
		tc := tc
		t.Run(tc.provider, func(t *testing.T) {
			if err := s.Set(tc.provider, json.RawMessage(tc.blob)); err != nil {
				t.Fatalf("Set: %v", err)
			}
			if !s.Has(tc.provider) {
				t.Fatalf("Has(%q) = false after Set", tc.provider)
			}
			got, err := s.Get(tc.provider)
			if err != nil {
				t.Fatalf("Get: %v", err)
			}
			if !bytes.Equal(got, []byte(tc.blob)) {
				t.Fatalf("Get mismatch:\n want %s\n got  %s", tc.blob, string(got))
			}
		})
	}
}

// TestStoreDelete covers per-box sign-out: Delete removes the pushed
// <provider>.enc, is idempotent (deleting nothing is a nil-error no-op),
// rejects unknown providers, and leaves OTHER providers' blobs intact.
func TestStoreDelete(t *testing.T) {
	dir := t.TempDir()
	s := NewStore(dir, []byte("bearer-token-fixture-32-chars--"))

	// Delete on an empty store is a no-op success (idempotent sign-out).
	if err := s.Delete(ProviderAnthropic); err != nil {
		t.Fatalf("Delete on empty store: %v", err)
	}

	// Store two providers, delete one, the other survives.
	if err := s.Set(ProviderAnthropic, json.RawMessage(`{"claudeAiOauth":{"accessToken":"a"}}`)); err != nil {
		t.Fatalf("Set anthropic: %v", err)
	}
	if err := s.Set(ProviderOpenAI, json.RawMessage(`{"tokens":{"access_token":"b"}}`)); err != nil {
		t.Fatalf("Set openai: %v", err)
	}
	if err := s.Delete(ProviderAnthropic); err != nil {
		t.Fatalf("Delete anthropic: %v", err)
	}
	if s.Has(ProviderAnthropic) {
		t.Errorf("Has(anthropic) = true after Delete")
	}
	if !s.Has(ProviderOpenAI) {
		t.Errorf("Has(openai) = false after deleting anthropic — Delete clobbered the wrong blob")
	}

	// Second delete of the same provider is still a no-op success.
	if err := s.Delete(ProviderAnthropic); err != nil {
		t.Fatalf("double Delete: %v", err)
	}

	// Unknown provider rejected up front, same as Set/Get.
	if err := s.Delete("../etc/passwd"); err == nil {
		t.Errorf("Delete unknown provider: expected error")
	}
}

// TestStoreGetMissing returns a not-exist error rather than a decrypt
// failure when nothing has been stored yet. Materialize relies on this
// to decide whether to fall back to the host-mirror behaviour.
func TestStoreGetMissing(t *testing.T) {
	s := NewStore(t.TempDir(), []byte("bearer-token-fixture-32-chars--"))
	_, err := s.Get(ProviderAnthropic)
	if err == nil {
		t.Fatalf("Get on empty store: expected error")
	}
	if !os.IsNotExist(err) {
		t.Fatalf("Get on empty store: want IsNotExist, got %v", err)
	}
}

// TestStoreUnknownProviderRejected covers the sanitization rule: we
// never want a caller (test or real) to materialize a credential to
// `<home>/../etc/passwd` or similar. Unknown provider names must be
// rejected up front.
func TestStoreUnknownProviderRejected(t *testing.T) {
	s := NewStore(t.TempDir(), []byte("bearer-token-fixture-32-chars--"))
	if err := s.Set("../etc/passwd", json.RawMessage(`{}`)); err == nil {
		t.Fatalf("Set: expected error for path-traversal provider name")
	}
	if err := s.Set("evilcorp", json.RawMessage(`{}`)); err == nil {
		t.Fatalf("Set: expected error for unknown provider")
	}
	if err := s.Materialize("../etc", "/tmp/dontmatter"); err == nil {
		t.Fatalf("Materialize: expected error for path-traversal provider name")
	}
	if _, err := s.Get("evilcorp"); err == nil {
		t.Fatalf("Get: expected error for unknown provider")
	}
}

// TestStoreEmptyPayloadRejected — silently writing an empty file would
// leave a future Get returning the empty envelope error rather than
// IsNotExist, so the session spawn path would not fall back cleanly.
// Catch it at Set time instead.
func TestStoreEmptyPayloadRejected(t *testing.T) {
	s := NewStore(t.TempDir(), []byte("bearer-token-fixture-32-chars--"))
	if err := s.Set(ProviderOpenAI, json.RawMessage(``)); err == nil {
		t.Fatalf("Set: expected error for empty payload")
	}
}

// TestStoreSetIsAtomic re-Sets a provider's credential several times
// and asserts the final read matches the last write. Atomicity is the
// guarantee that a torn write never leaves a half-decryptable file on
// disk; we exercise that by simply checking the rename-replace path
// works for repeated writes.
func TestStoreSetIsAtomic(t *testing.T) {
	s := NewStore(t.TempDir(), []byte("bearer-token-fixture-32-chars--"))
	payloads := []string{
		`{"v":1}`,
		`{"v":2,"extra":"abc"}`,
		`{"v":3}`,
	}
	for _, p := range payloads {
		if err := s.Set(ProviderAnthropic, json.RawMessage(p)); err != nil {
			t.Fatalf("Set %s: %v", p, err)
		}
	}
	got, err := s.Get(ProviderAnthropic)
	if err != nil {
		t.Fatalf("Get: %v", err)
	}
	if string(got) != payloads[len(payloads)-1] {
		t.Fatalf("final read: want %s, got %s", payloads[len(payloads)-1], string(got))
	}
}

// TestStoreDifferentBearerCannotDecrypt — the per-identity subdir is
// still bearer-derived, so a different bearer's Store finds nothing at
// its own path. Post-H1 the at-rest AEAD key is the per-DIRECTORY keyfile
// (not the bearer), so two stores rooted at the SAME dir share the keyfile
// by design — the meaningful at-rest property is now keyfile-based, proven
// by TestStoreKeyfileReaderRequired below.
func TestStoreDifferentBearerCannotDecrypt(t *testing.T) {
	dir := t.TempDir()
	a := NewStore(dir, []byte("alice-bearer-token-fixture-32"))
	if err := a.Set(ProviderOpenAI, json.RawMessage(`{"k":"v"}`)); err != nil {
		t.Fatalf("Set: %v", err)
	}

	// A bearer-mismatched store points at the same root directory but
	// derives a different identity subdir — so it shouldn't even find
	// the file.
	bob := NewStore(dir, []byte("bob-bearer-token-fixture-32-x"))
	if _, err := bob.Get(ProviderOpenAI); !os.IsNotExist(err) {
		t.Fatalf("bob Get: want IsNotExist (different identity subdir), got %v", err)
	}
}

// TestStoreKeyfileReaderRequired is the real H1 at-rest property: a
// raw-disk/backup reader who copies the .enc blob but NOT the keyfile
// cannot decrypt it, and crucially the bearer (which sits in cleartext
// in the systemd unit) no longer helps — the key is the keyfile, not
// SHA256(bearer).
func TestStoreKeyfileReaderRequired(t *testing.T) {
	dir := t.TempDir()
	bearer := []byte("bearer-token-fixture-32-chars--")
	s := NewStore(dir, bearer)
	if err := s.Set(ProviderOpenAI, json.RawMessage(`{"k":"v"}`)); err != nil {
		t.Fatalf("Set: %v", err)
	}
	envelope, err := os.ReadFile(s.providerPath(ProviderOpenAI))
	if err != nil {
		t.Fatalf("read blob: %v", err)
	}

	// The bearer-derived key (the OLD scheme) must NOT open the new blob.
	if _, err := openWith(deriveBearerKey(bearer), envelope); err == nil {
		t.Fatal("bearer-derived key opened a keyfile-sealed blob: H1 not fixed")
	}

	// A reader who lacks the keyfile (fresh dir, no keyfile copied) also
	// fails: a Store rooted elsewhere generates a different random key.
	other := NewStore(t.TempDir(), bearer)
	otherKey, err := other.loadKey()
	if err != nil {
		t.Fatalf("loadKey: %v", err)
	}
	if _, err := openWith(otherKey, envelope); err == nil {
		t.Fatal("a different keyfile opened the blob: keyfile is not the boundary")
	}
}

// TestStoreLazyMigration writes a blob under the LEGACY SHA256(bearer)
// scheme, then Gets it through a keyfile-backed store: the read must
// transparently fall back to the bearer key, return the plaintext, AND
// re-encrypt on disk under the keyfile key. Afterward the on-disk blob
// must have changed and must NO LONGER be decryptable by the bearer key.
func TestStoreLazyMigration(t *testing.T) {
	dir := t.TempDir()
	bearer := []byte("bearer-token-fixture-32-chars--")
	s := NewStore(dir, bearer)

	// Hand-craft a legacy blob sealed with the bearer-derived key and
	// drop it at the provider path the store reads from.
	plain := []byte(`{"tokens":{"access_token":"legacy"}}`)
	legacy, err := sealWith(deriveBearerKey(bearer), plain)
	if err != nil {
		t.Fatalf("sealWith legacy: %v", err)
	}
	path := s.providerPath(ProviderOpenAI)
	if err := os.MkdirAll(filepath.Dir(path), 0o700); err != nil {
		t.Fatalf("mkdir: %v", err)
	}
	if err := os.WriteFile(path, legacy, 0o600); err != nil {
		t.Fatalf("write legacy blob: %v", err)
	}

	// Get transparently decrypts via the bearer fallback.
	got, err := s.Get(ProviderOpenAI)
	if err != nil {
		t.Fatalf("Get legacy blob: %v", err)
	}
	if !bytes.Equal(got, plain) {
		t.Fatalf("Get mismatch: want %s, got %s", plain, got)
	}

	// The on-disk blob must have been rewritten (re-encrypted).
	migrated, err := os.ReadFile(path)
	if err != nil {
		t.Fatalf("read migrated blob: %v", err)
	}
	if bytes.Equal(migrated, legacy) {
		t.Fatal("blob was not rewritten: lazy migration did not re-encrypt")
	}

	// The migrated blob must NO LONGER open under the bearer-derived key.
	if _, err := openWith(deriveBearerKey(bearer), migrated); err == nil {
		t.Fatal("migrated blob still decrypts with the bearer key: not re-keyed")
	}

	// And it must open cleanly under the keyfile key (a second Get is a
	// straight keyfile decrypt, no fallback).
	got2, err := s.Get(ProviderOpenAI)
	if err != nil {
		t.Fatalf("Get after migration: %v", err)
	}
	if !bytes.Equal(got2, plain) {
		t.Fatalf("post-migration Get mismatch: want %s, got %s", plain, got2)
	}
}

// TestStoreKeyfileMode asserts the keyfile is created mode 0600 — the
// at-rest boundary depends on it being unreadable to other UIDs.
func TestStoreKeyfileMode(t *testing.T) {
	if runtime.GOOS == "windows" {
		t.Skip("file mode bits don't translate on windows")
	}
	dir := t.TempDir()
	s := NewStore(dir, []byte("bearer-token-fixture-32-chars--"))
	if err := s.Set(ProviderAnthropic, json.RawMessage(`{"x":1}`)); err != nil {
		t.Fatalf("Set: %v", err)
	}
	info, err := os.Stat(filepath.Join(dir, keyfileName))
	if err != nil {
		t.Fatalf("stat keyfile: %v", err)
	}
	if mode := info.Mode().Perm(); mode != 0o600 {
		t.Fatalf("keyfile mode: want 0600, got %o", mode)
	}
}

// TestStoreNoBearerKeyfileOnly — a store with an EMPTY bearer (no legacy
// fallback available) must still round-trip purely on the keyfile key.
func TestStoreNoBearerKeyfileOnly(t *testing.T) {
	s := NewStore(t.TempDir(), nil)
	blob := json.RawMessage(`{"claudeAiOauth":{"accessToken":"keyfile-only"}}`)
	if err := s.Set(ProviderAnthropic, blob); err != nil {
		t.Fatalf("Set: %v", err)
	}
	got, err := s.Get(ProviderAnthropic)
	if err != nil {
		t.Fatalf("Get: %v", err)
	}
	if !bytes.Equal(got, blob) {
		t.Fatalf("Get mismatch: want %s, got %s", blob, got)
	}
}

// TestStoreFileMode asserts the on-disk encrypted file is mode 0600.
// Important for the operator's threat model: anyone with read access
// to the broker state dir would otherwise be able to grep the file
// for ciphertext.
func TestStoreFileMode(t *testing.T) {
	if runtime.GOOS == "windows" {
		t.Skip("file mode bits don't translate on windows")
	}
	s := NewStore(t.TempDir(), []byte("bearer-token-fixture-32-chars--"))
	if err := s.Set(ProviderAnthropic, json.RawMessage(`{"x":1}`)); err != nil {
		t.Fatalf("Set: %v", err)
	}
	info, err := os.Stat(s.providerPath(ProviderAnthropic))
	if err != nil {
		t.Fatalf("stat: %v", err)
	}
	if mode := info.Mode().Perm(); mode != 0o600 {
		t.Fatalf("file mode: want 0600, got %o", mode)
	}
}

// TestMaterializeAnthropic writes the Claude credential to the
// .claude/.credentials.json path and confirms the bytes match the
// original payload (no normalization), mode 0600.
func TestMaterializeAnthropic(t *testing.T) {
	s := NewStore(t.TempDir(), []byte("bearer-token-fixture-32-chars--"))
	blob := `{"claudeAiOauth":{"accessToken":"sk-ant-oat01-xyz"}}`
	if err := s.Set(ProviderAnthropic, json.RawMessage(blob)); err != nil {
		t.Fatalf("Set: %v", err)
	}
	home := t.TempDir()
	if err := s.Materialize(ProviderAnthropic, home); err != nil {
		t.Fatalf("Materialize: %v", err)
	}
	got, err := os.ReadFile(filepath.Join(home, ".claude", ".credentials.json"))
	if err != nil {
		t.Fatalf("read materialized file: %v", err)
	}
	if string(got) != blob {
		t.Fatalf("materialized bytes: want %s, got %s", blob, string(got))
	}
	if runtime.GOOS != "windows" {
		info, _ := os.Stat(filepath.Join(home, ".claude", ".credentials.json"))
		if mode := info.Mode().Perm(); mode != 0o600 {
			t.Fatalf("materialized file mode: want 0600, got %o", mode)
		}
		dir, _ := os.Stat(filepath.Join(home, ".claude"))
		if mode := dir.Mode().Perm(); mode != 0o700 {
			t.Fatalf("materialized dir mode: want 0700, got %o", mode)
		}
	}
}

// TestMaterializeOpenAI is the Codex equivalent — writes to
// .codex/auth.json.
func TestMaterializeOpenAI(t *testing.T) {
	s := NewStore(t.TempDir(), []byte("bearer-token-fixture-32-chars--"))
	blob := `{"auth_mode":"ChatGPT","tokens":{"access_token":"at-123"}}`
	if err := s.Set(ProviderOpenAI, json.RawMessage(blob)); err != nil {
		t.Fatalf("Set: %v", err)
	}
	home := t.TempDir()
	if err := s.Materialize(ProviderOpenAI, home); err != nil {
		t.Fatalf("Materialize: %v", err)
	}
	got, err := os.ReadFile(filepath.Join(home, ".codex", "auth.json"))
	if err != nil {
		t.Fatalf("read materialized file: %v", err)
	}
	if string(got) != blob {
		t.Fatalf("materialized bytes: want %s, got %s", blob, string(got))
	}
}

// TestMaterializeMissingReturnsNotExist — when no credential is
// stored, Materialize must return os.ErrNotExist so the spawn path
// can fall back to the existing host-mirror behaviour without
// surfacing a hard error to the operator.
func TestMaterializeMissingReturnsNotExist(t *testing.T) {
	s := NewStore(t.TempDir(), []byte("bearer-token-fixture-32-chars--"))
	err := s.Materialize(ProviderOpenAI, t.TempDir())
	if err == nil {
		t.Fatalf("Materialize on empty store: expected error")
	}
	if !os.IsNotExist(err) {
		t.Fatalf("Materialize on empty store: want IsNotExist, got %v", err)
	}
}

// TestMaterializeEmptyHomeRejected — an empty ephemeralHome would
// resolve to writing into the broker's CWD, which is exactly the
// global-mirror anti-pattern we're trying to retire. Reject explicitly.
func TestMaterializeEmptyHomeRejected(t *testing.T) {
	s := NewStore(t.TempDir(), []byte("bearer-token-fixture-32-chars--"))
	if err := s.Set(ProviderAnthropic, json.RawMessage(`{"x":1}`)); err != nil {
		t.Fatalf("Set: %v", err)
	}
	if err := s.Materialize(ProviderAnthropic, ""); err == nil {
		t.Fatalf("Materialize: expected error for empty home")
	}
	if err := s.Materialize(ProviderAnthropic, "  "); err == nil {
		t.Fatalf("Materialize: expected error for whitespace home")
	}
}
