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
)

// fileVersion is the leading byte of every `.enc` file. Bumped when
// the AEAD envelope changes. Today: AES-256-GCM with a 12-byte nonce
// prepended to the ciphertext.
const fileVersion byte = 0x01

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
	// key is the 32-byte AES-256 key derived from the broker's bearer
	// secret. Held in memory only; never written to disk. See
	// `deriveKey` for the derivation function and §D.2 of the plan for
	// the trade-off discussion.
	key []byte
}

// NewStore returns a Store rooted at `dir`. The directory is created
// (mode 0700) lazily on the first write. `bearer` is the broker's
// authentication secret; the encryption key is derived deterministically
// from it via SHA-256 so the broker can decrypt blobs across restarts
// without persisting the key. Passing an empty bearer is allowed for
// tests but yields a deterministic, trivially-guessable key — production
// callers should always supply the real bearer bytes.
func NewStore(dir string, bearer []byte) *Store {
	return &Store{
		dir: dir,
		key: deriveKey(bearer),
	}
}

// Dir returns the root directory the store writes under. Mainly useful
// for logging at broker startup.
func (s *Store) Dir() string { return s.dir }

// deriveKey hashes the bearer into a 32-byte AES-256 key. SHA-256 is
// the simplest "fits-in-32-bytes" derivation that doesn't require a
// new dependency and is more than sufficient for a key whose threat
// model is "the broker process holds the secret" rather than "an
// attacker is brute-forcing the key" — anyone who can read the broker
// state directory can also read the bearer from the broker's process
// environment (or its pairing-QR stdout) and reproduce the derivation.
//
// Empty bearer yields a constant key (used only by tests).
func deriveKey(bearer []byte) []byte {
	h := sha256.Sum256(bearer)
	return h[:]
}

// identitySubdir returns the per-identity directory name. Done as a
// hex sha256 so the on-disk shape doesn't leak the raw bearer to anyone
// who lists the credentials directory.
func (s *Store) identitySubdir() string {
	h := sha256.Sum256([]byte(s.dirSalt()))
	return hex.EncodeToString(h[:])
}

// dirSalt is the bytes hashed into the per-identity subdirectory name.
// For Stage 1 we derive it from the same bearer-derived key — that
// keeps it deterministic across restarts without storing a separate
// salt file, and the broker rotates identity dirs implicitly when the
// bearer rotates. (If we ever support multiple bearers in the same
// broker, this becomes a per-bearer call site, not a Store field.)
func (s *Store) dirSalt() string {
	// Mix in a fixed namespace string so the subdirectory hash is
	// distinct from any other sha256 we might compute over the key.
	return "swekitty-credentials-v1:" + string(s.key)
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
	data, err := os.ReadFile(s.providerPath(provider))
	if err != nil {
		return nil, err
	}
	plain, err := s.open(data)
	if err != nil {
		return nil, err
	}
	return json.RawMessage(plain), nil
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

// seal encrypts `plain` with AES-256-GCM. Layout:
//
//	[1 byte version][12 byte nonce][ciphertext || tag]
//
// `version` is checked by `open` so we can rev the envelope later.
func (s *Store) seal(plain []byte) ([]byte, error) {
	block, err := aes.NewCipher(s.key)
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

// open is the inverse of seal. Rejects unknown version bytes.
func (s *Store) open(envelope []byte) ([]byte, error) {
	if len(envelope) < 1 {
		return nil, errors.New("credentials: empty envelope")
	}
	if envelope[0] != fileVersion {
		return nil, fmt.Errorf("credentials: unknown envelope version 0x%02x", envelope[0])
	}
	block, err := aes.NewCipher(s.key)
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
