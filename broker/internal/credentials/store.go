// Package credentials encrypts and materializes per-identity agent OAuth
// blobs that the broker receives from a paired client (see
// docs/PLAN-AGENT-OAUTH.md §D and §G). Stage 1 scope: encrypted at-rest
// storage + per-session materialization. Refresh broadcast (§D.4)
// lands in a later stage.
package credentials

import (
	"crypto/aes"
	"crypto/cipher"
	"crypto/rand"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"strings"
	"sync"
)

// fileVersion is the leading byte of every `.enc` file. Bumped when
// the AEAD envelope changes. Today: AES-256-GCM with a 12-byte nonce
// prepended to the ciphertext. The AEAD envelope is identical between
// the legacy bearer-derived key and the keyfile key — only the key bytes
// changed (audit H1) — so the version byte stays 0x01 and migration is a
// re-encrypt, not a format bump.
const fileVersion byte = 0x01

// keyfileName is the basename of the random 32-byte AES-256 key that
// encrypts every `.enc` blob. It lives inside the credentials dir with
// mode 0600 and is generated once on first use with crypto/rand.
//
// THREAT MODEL (read before "improving" the key derivation): the real
// at-rest boundary is this keyfile plus the filesystem permissions
// (0700 dir / 0600 files, broker UID). Against a raw-disk or backup
// reader who can copy the `.enc` blobs but NOT the keyfile, this is
// genuine AES-256-GCM encryption — they recover only ciphertext. It is
// NOT a defense against anyone who already has read access as the broker
// UID (they can read the keyfile too); nothing on the same UID can be.
//
// This fixes audit finding H1: the key used to be SHA256(bearer), where
// the bearer (CONDUIT_TOKEN) is stored in cleartext in the systemd unit
// right next to these blobs — so the old "encryption" protected nothing
// against a state-dir reader, who could read the bearer and reproduce
// the key. The keyfile is a SEPARATE, high-entropy secret that is never
// the bearer.
const keyfileName = ".keyfile"

// Known provider identifiers. Anything else is rejected at the WS edge
// AND at the store edge — defense in depth, since the materialize path
// turns the provider name into a file path.
const (
	ProviderOpenAI    = "openai"
	ProviderAnthropic = "anthropic"
)

// ValidProvider returns true when `p` names a credential schema the
// broker knows how to materialize. Keep this in lockstep with
// Materialize's switch below — adding a new provider here without
// teaching Materialize where to write would silently mis-materialize.
func ValidProvider(p string) bool {
	switch p {
	case ProviderOpenAI, ProviderAnthropic:
		return true
	default:
		return false
	}
}

// Store persists encrypted OAuth blobs under a single directory rooted
// at `dir`. Each paired bearer-token identity gets its own subdirectory
// (named by sha256(bearer)) so multiple identities sharing a broker
// don't collide. Concurrent-safe: writes are atomic per provider.
type Store struct {
	dir string
	// bearerKey is SHA256(bearer): the LEGACY AES-256 key (audit H1).
	// Held only to (a) derive the per-identity subdir name so existing
	// blobs stay locatable across the migration, and (b) decrypt-then-
	// re-encrypt old blobs in the lazy fallback path. It is NEVER the
	// primary encryption key anymore. Empty when the bearer is empty.
	bearerKey []byte

	// keyOnce guards lazy load/generate of the keyfile-backed primary key.
	keyOnce sync.Once
	// key is the 32-byte AES-256 PRIMARY key, read from (or generated
	// into) the 0600 keyfile in `dir`. Held in memory only after first
	// load. Populated lazily via loadKey; keyErr captures a load failure.
	key    []byte
	keyErr error
}

// NewStore returns a Store rooted at `dir`. The directory is created
// (mode 0700) lazily on the first write. `bearer` is the broker's
// authentication secret. It is NO LONGER the encryption key (audit H1):
// the primary AES-256 key is a random 32-byte keyfile generated under
// `dir`. The bearer is retained only to name the per-identity subdir and
// to transparently migrate pre-keyfile blobs (which were encrypted with
// SHA256(bearer)) on first read. Passing an empty bearer is allowed for
// tests / keyfile-only operation: the keyfile path still works, but the
// legacy-decrypt migration fallback is then unavailable.
func NewStore(dir string, bearer []byte) *Store {
	return &Store{
		dir:       dir,
		bearerKey: deriveBearerKey(bearer),
	}
}

// Dir returns the root directory the store writes under. Mainly useful
// for logging at broker startup.
func (s *Store) Dir() string { return s.dir }

// deriveBearerKey hashes the bearer into the 32-byte LEGACY AES-256 key.
// This is the pre-H1 derivation, kept solely for the migration fallback
// and the identity-subdir name. Empty bearer yields a nil key (no legacy
// fallback, no bearer-derived subdir component).
func deriveBearerKey(bearer []byte) []byte {
	if len(bearer) == 0 {
		return nil
	}
	h := sha256.Sum256(bearer)
	return h[:]
}

// keyfilePath is where the random primary key lives.
func (s *Store) keyfilePath() string {
	return filepath.Join(s.dir, keyfileName)
}

// loadKey loads the keyfile-backed primary key, generating it on first
// use. Idempotent via keyOnce; the result is cached on the Store. The
// keyfile is created with mode 0600 inside `dir` (mode 0700), both owned
// by the broker UID. Generation uses crypto/rand for a full 32 bytes of
// entropy — this key is independent of the bearer.
func (s *Store) loadKey() ([]byte, error) {
	s.keyOnce.Do(func() {
		s.key, s.keyErr = readOrCreateKeyfile(s.dir, s.keyfilePath())
	})
	return s.key, s.keyErr
}

// readOrCreateKeyfile returns the 32-byte key from `path`, creating it
// (and the parent `dir`, mode 0700) with fresh crypto/rand bytes and
// mode 0600 if it does not yet exist. A keyfile of the wrong length is
// treated as corrupt and rejected rather than silently regenerated —
// regenerating would orphan every existing blob.
func readOrCreateKeyfile(dir, path string) ([]byte, error) {
	if err := os.MkdirAll(dir, 0o700); err != nil {
		return nil, fmt.Errorf("credentials: mkdir %s: %w", dir, err)
	}
	data, err := os.ReadFile(path)
	switch {
	case err == nil:
		if len(data) != 32 {
			return nil, fmt.Errorf("credentials: keyfile %s has %d bytes, want 32", path, len(data))
		}
		return data, nil
	case errors.Is(err, os.ErrNotExist):
		key := make([]byte, 32)
		if _, err := io.ReadFull(rand.Reader, key); err != nil {
			return nil, fmt.Errorf("credentials: generate keyfile: %w", err)
		}
		if err := atomicWrite(path, key, 0o600); err != nil {
			return nil, fmt.Errorf("credentials: write keyfile: %w", err)
		}
		return key, nil
	default:
		return nil, fmt.Errorf("credentials: read keyfile %s: %w", path, err)
	}
}

// identitySubdir returns the per-identity directory name. Done as a
// hex sha256 so the on-disk shape doesn't leak the raw bearer to anyone
// who lists the credentials directory.
func (s *Store) identitySubdir() string {
	h := sha256.Sum256([]byte(s.dirSalt()))
	return hex.EncodeToString(h[:])
}

// dirSalt is the bytes hashed into the per-identity subdirectory name.
// It stays derived from the bearer-derived key (NOT the keyfile key) so
// the on-disk identity layout is UNCHANGED by the H1 re-key: existing
// blobs remain at the same path and the lazy migration can find them.
// The broker still rotates identity dirs implicitly when the bearer
// rotates, exactly as before. An empty bearer yields a fixed namespace
// salt (tests / keyfile-only).
func (s *Store) dirSalt() string {
	// Mix in a fixed namespace string so the subdirectory hash is
	// distinct from any other sha256 we might compute over the key.
	return "conduit-credentials-v1:" + string(s.bearerKey)
}

// providerPath returns the on-disk path for a given provider's
// encrypted blob. Provider is validated by the caller.
func (s *Store) providerPath(provider string) string {
	return filepath.Join(s.dir, s.identitySubdir(), provider+".enc")
}

// Set encrypts `credential` (the raw JSON blob the client shipped) and
// writes it to disk atomically. The blob is stored verbatim — no
// schema normalization — so additive vendor changes (new fields on
// codex's `auth.json`, etc.) survive round-trip without code changes.
// Returns an error if `provider` isn't known or if the directory
// cannot be created.
func (s *Store) Set(provider string, credential json.RawMessage) error {
	if !ValidProvider(provider) {
		return fmt.Errorf("credentials: unknown provider %q", provider)
	}
	if len(credential) == 0 {
		return errors.New("credentials: empty credential payload")
	}
	subdir := filepath.Join(s.dir, s.identitySubdir())
	if err := os.MkdirAll(subdir, 0o700); err != nil {
		return fmt.Errorf("credentials: mkdir %s: %w", subdir, err)
	}
	envelope, err := s.seal(credential)
	if err != nil {
		return err
	}
	return atomicWrite(s.providerPath(provider), envelope, 0o600)
}

// Get returns the decrypted blob for `provider`, or os.ErrNotExist if
// nothing has been stored yet. Mostly useful for tests; the live path
// is Materialize.
func (s *Store) Get(provider string) (json.RawMessage, error) {
	if !ValidProvider(provider) {
		return nil, fmt.Errorf("credentials: unknown provider %q", provider)
	}
	path := s.providerPath(provider)
	data, err := os.ReadFile(path)
	if err != nil {
		return nil, err
	}
	plain, err := s.open(data)
	if err == nil {
		return json.RawMessage(plain), nil
	}
	// Lazy migration (audit H1): a blob written before the keyfile re-key
	// was sealed with SHA256(bearer). The keyfile open above fails its GCM
	// auth tag on such a blob; fall back to the legacy bearer key, and on
	// success transparently RE-ENCRYPT under the keyfile key so the next
	// read is a clean keyfile decrypt. The running broker still has the
	// bearer in env on an upgrade/redeploy, so every existing blob migrates
	// on first access with no data loss and no re-pair.
	if len(s.bearerKey) == 0 {
		return nil, err
	}
	legacyPlain, legacyErr := openWith(s.bearerKey, data)
	if legacyErr != nil {
		// Neither key opened it: surface the PRIMARY-key error, which is
		// the one a caller debugging a keyfile mismatch wants to see.
		return nil, err
	}
	// Re-seal under the keyfile key and rewrite atomically (0600). A
	// failure to rewrite is non-fatal to the read — we still return the
	// recovered plaintext; the migration simply retries on the next Get.
	if envelope, sealErr := s.seal(legacyPlain); sealErr == nil {
		_ = atomicWrite(path, envelope, 0o600)
	}
	return json.RawMessage(legacyPlain), nil
}

// Has reports whether a credential for `provider` exists on disk.
// Distinguishes "no credential yet" from "decrypt error" at the call
// site — Materialize uses Has first to keep the fallback path cheap.
func (s *Store) Has(provider string) bool {
	if !ValidProvider(provider) {
		return false
	}
	_, err := os.Stat(s.providerPath(provider))
	return err == nil
}

// Delete removes the app-pushed encrypted credential for `provider` from
// this identity's store. It removes ONLY the `<provider>.enc` blob the app
// pushed via Set — it never touches the box owner's host-HOME login files
// (~/.claude/.credentials.json, ~/.codex/auth.json). Those are the box
// owner's own CLI login and are not the app's to revoke; the per-box
// sign-out the app surfaces is honestly scoped to "remove the pushed
// credential from this box".
//
// Returns nil when nothing was stored (idempotent: a double sign-out is a
// no-op success) and a wrapped error only on an unexpected filesystem
// failure. Unknown providers are rejected up front, matching Set/Get.
func (s *Store) Delete(provider string) error {
	if !ValidProvider(provider) {
		return fmt.Errorf("credentials: unknown provider %q", provider)
	}
	if err := os.Remove(s.providerPath(provider)); err != nil {
		if errors.Is(err, os.ErrNotExist) {
			return nil
		}
		return fmt.Errorf("credentials: delete %s: %w", provider, err)
	}
	return nil
}

// Materialize decrypts the stored credential for `provider` and writes
// it into a per-session ephemeral HOME at the provider-native path:
//
//   - openai    → <ephemeralHome>/.codex/auth.json
//   - anthropic → <ephemeralHome>/.claude/.credentials.json
//
// The ephemeral parent dirs are created with mode 0700; the credential
// file lands with mode 0600. Caller is responsible for creating /
// removing `ephemeralHome` itself — Materialize only owns the
// `.codex/` or `.claude/` subdirectory underneath it.
//
// Returns os.ErrNotExist when no credential is stored for `provider`,
// so the session spawn path can fall back to the legacy host-mirror
// behaviour without bubbling up a hard error.
func (s *Store) Materialize(provider, ephemeralHome string) error {
	if !ValidProvider(provider) {
		return fmt.Errorf("credentials: unknown provider %q", provider)
	}
	if strings.TrimSpace(ephemeralHome) == "" {
		return errors.New("credentials: empty ephemeralHome")
	}
	blob, err := s.Get(provider)
	if err != nil {
		return err
	}
	var (
		subdir   string
		filename string
	)
	switch provider {
	case ProviderOpenAI:
		subdir = filepath.Join(ephemeralHome, ".codex")
		filename = "auth.json"
	case ProviderAnthropic:
		subdir = filepath.Join(ephemeralHome, ".claude")
		filename = ".credentials.json"
	default:
		// Unreachable — guarded above. Belt + suspenders so the
		// linters don't worry about a fall-through writing into the
		// session root.
		return fmt.Errorf("credentials: unknown provider %q", provider)
	}
	if err := os.MkdirAll(subdir, 0o700); err != nil {
		return fmt.Errorf("credentials: mkdir %s: %w", subdir, err)
	}
	return atomicWrite(filepath.Join(subdir, filename), blob, 0o600)
}

// MaterializeCanonical decrypts the stored credential for `provider` and
// writes it directly into `canonicalDir` at the provider-native filename:
//
//   - openai    → <canonicalDir>/auth.json
//   - anthropic → <canonicalDir>/.credentials.json
//
// Unlike Materialize, `canonicalDir` IS the provider-native config dir (e.g.
// ~/.claude or <conduitRoot>/agent-cred/.claude), not a parent "HOME". The
// directory is created with mode 0700 if absent; the file lands with mode 0600.
// Atomic write (temp+rename in the same dir). Used by the shared-credential
// lineage fix (CONDUIT_SHARED_AGENT_CREDS) to seed the one canonical file that
// every session reads through CLAUDE_CONFIG_DIR / CODEX_HOME.
//
// Returns os.ErrNotExist when no credential is stored for `provider`.
func (s *Store) MaterializeCanonical(provider, canonicalDir string) error {
	if !ValidProvider(provider) {
		return fmt.Errorf("credentials: unknown provider %q", provider)
	}
	if strings.TrimSpace(canonicalDir) == "" {
		return errors.New("credentials: empty canonicalDir")
	}
	blob, err := s.Get(provider)
	if err != nil {
		return err
	}
	var filename string
	switch provider {
	case ProviderOpenAI:
		filename = "auth.json"
	case ProviderAnthropic:
		filename = ".credentials.json"
	default:
		return fmt.Errorf("credentials: unknown provider %q", provider)
	}
	if err := os.MkdirAll(canonicalDir, 0o700); err != nil {
		return fmt.Errorf("credentials: mkdir %s: %w", canonicalDir, err)
	}
	return atomicWrite(filepath.Join(canonicalDir, filename), blob, 0o600)
}

// seal encrypts `plain` with AES-256-GCM under the keyfile primary key.
// Layout:
//
//	[1 byte version][12 byte nonce][ciphertext || tag]
//
// `version` is checked by `open` so we can rev the envelope later.
func (s *Store) seal(plain []byte) ([]byte, error) {
	key, err := s.loadKey()
	if err != nil {
		return nil, err
	}
	return sealWith(key, plain)
}

// open is the inverse of seal under the keyfile primary key. Rejects
// unknown version bytes. A GCM auth failure here is what triggers the
// legacy-bearer migration fallback in Get.
func (s *Store) open(envelope []byte) ([]byte, error) {
	key, err := s.loadKey()
	if err != nil {
		return nil, err
	}
	return openWith(key, envelope)
}

// sealWith / openWith carry the actual AEAD so the primary-key and the
// legacy-bearer-key paths share identical envelope params (version byte,
// 12-byte nonce, AES-256-GCM, no AAD). Only the key bytes differ.
func sealWith(key, plain []byte) ([]byte, error) {
	block, err := aes.NewCipher(key)
	if err != nil {
		return nil, fmt.Errorf("credentials: aes: %w", err)
	}
	gcm, err := cipher.NewGCM(block)
	if err != nil {
		return nil, fmt.Errorf("credentials: gcm: %w", err)
	}
	nonce := make([]byte, gcm.NonceSize())
	if _, err := io.ReadFull(rand.Reader, nonce); err != nil {
		return nil, fmt.Errorf("credentials: nonce: %w", err)
	}
	ct := gcm.Seal(nil, nonce, plain, nil)
	out := make([]byte, 0, 1+len(nonce)+len(ct))
	out = append(out, fileVersion)
	out = append(out, nonce...)
	out = append(out, ct...)
	return out, nil
}

func openWith(key, envelope []byte) ([]byte, error) {
	if len(envelope) < 1 {
		return nil, errors.New("credentials: empty envelope")
	}
	if envelope[0] != fileVersion {
		return nil, fmt.Errorf("credentials: unknown envelope version 0x%02x", envelope[0])
	}
	block, err := aes.NewCipher(key)
	if err != nil {
		return nil, fmt.Errorf("credentials: aes: %w", err)
	}
	gcm, err := cipher.NewGCM(block)
	if err != nil {
		return nil, fmt.Errorf("credentials: gcm: %w", err)
	}
	ns := gcm.NonceSize()
	if len(envelope) < 1+ns {
		return nil, errors.New("credentials: envelope truncated")
	}
	nonce := envelope[1 : 1+ns]
	ct := envelope[1+ns:]
	plain, err := gcm.Open(nil, nonce, ct, nil)
	if err != nil {
		return nil, fmt.Errorf("credentials: gcm open: %w", err)
	}
	return plain, nil
}

// atomicWrite writes `data` to `path` via a temp file in the same
// directory + rename, so a torn write never leaves a half-decryptable
// file on disk. Mode is applied to the temp file before the rename so
// the final file is created with the requested permissions.
func atomicWrite(path string, data []byte, mode os.FileMode) error {
	dir := filepath.Dir(path)
	tmp, err := os.CreateTemp(dir, ".swk-cred-*.tmp")
	if err != nil {
		return err
	}
	tmpPath := tmp.Name()
	// On any error after this point we want the temp file gone.
	cleanup := func() { _ = os.Remove(tmpPath) }
	if _, err := tmp.Write(data); err != nil {
		_ = tmp.Close()
		cleanup()
		return err
	}
	if err := tmp.Chmod(mode); err != nil {
		_ = tmp.Close()
		cleanup()
		return err
	}
	if err := tmp.Close(); err != nil {
		cleanup()
		return err
	}
	if err := os.Rename(tmpPath, path); err != nil {
		cleanup()
		return err
	}
	return nil
}
