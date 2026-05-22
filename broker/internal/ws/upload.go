package ws

import (
	"encoding/binary"
	"errors"
	"os"
	"path/filepath"
	"strings"
)

// uploadFrame is the decoded form of a 0x01 binary file-upload frame.
// Wire layout (after the leading 0x01 tag byte):
//
//	u32 LE session_id_length
//	session_id_bytes
//	u32 LE filename_length
//	filename_bytes
//	u32 LE mime_length
//	mime_bytes
//	file_bytes…
//
// Note: the embedded session_id is intentionally redundant with the WS
// path's session id — the broker rejects frames whose embedded id does
// not match the socket's bound session, so a confused client cannot
// land bytes in another session's upload dir.
type uploadFrame struct {
	SessionID string
	Filename  string
	MIME      string
	Body      []byte
}

// parseUploadFrame decodes a 0x01 file-upload payload. The leading
// tag byte must already be peeled off (callers pass payload[1:]).
//
// All three length fields use u32 little-endian. The function returns
// io-shape errors only — sanitization of filename/session_id happens
// in writeUpload so the caller can pin distinct error semantics in
// tests.
func parseUploadFrame(payload []byte) (uploadFrame, error) {
	var f uploadFrame
	r := payload

	readLP := func(field string) ([]byte, error) {
		if len(r) < 4 {
			return nil, errors.New("upload: truncated " + field + " length")
		}
		n := binary.LittleEndian.Uint32(r[:4])
		r = r[4:]
		if uint64(n) > uint64(len(r)) {
			return nil, errors.New("upload: truncated " + field + " bytes")
		}
		b := r[:n]
		r = r[n:]
		return b, nil
	}

	sid, err := readLP("session_id")
	if err != nil {
		return f, err
	}
	name, err := readLP("filename")
	if err != nil {
		return f, err
	}
	mime, err := readLP("mime")
	if err != nil {
		return f, err
	}

	f.SessionID = string(sid)
	f.Filename = string(name)
	f.MIME = string(mime)
	f.Body = r
	return f, nil
}

// sanitizeUploadFilename strips any path components from `name` and
// rejects values that escape the destination directory. Returns the
// safe basename or an error explaining why the input was unsafe.
//
// Rules (sweswe-parity §2.1):
//   - reject empty / whitespace-only names
//   - reject absolute paths (leading '/')
//   - reject '..' anywhere in the path
//   - reject names containing '/' or '\\' (we want a flat basename)
//   - reject names that resolve to "." after Clean (e.g. ".")
//
// The function is exported only to the package; tests in this
// package exercise it directly via the table cases below.
func sanitizeUploadFilename(name string) (string, error) {
	trimmed := strings.TrimSpace(name)
	if trimmed == "" {
		return "", errors.New("empty filename")
	}
	if strings.HasPrefix(trimmed, "/") {
		return "", errors.New("absolute path not allowed")
	}
	if strings.Contains(trimmed, "..") {
		return "", errors.New("'..' not allowed in filename")
	}
	if strings.ContainsAny(trimmed, "/\\") {
		return "", errors.New("path separators not allowed in filename")
	}
	cleaned := filepath.Clean(trimmed)
	if cleaned == "." || cleaned == "" {
		return "", errors.New("invalid filename")
	}
	return cleaned, nil
}

// writeUpload persists `body` to <workspaceDir>/uploads/<sessionID>/<safeName>.
// Creates parent directories with 0o755 and writes the file with
// 0o644 — same permissions the agent's own writes use. Returns the
// final on-disk path so the caller can surface it in the tool-event
// it emits.
//
// The function does NOT take a lock; the underlying os.MkdirAll and
// os.WriteFile are safe under concurrent uploads to distinct files.
// Concurrent uploads to the *same* filename race the way os.WriteFile
// races — last writer wins, which is fine for chat-driven uploads.
func writeUpload(workspaceDir, sessionID, filename string, body []byte) (string, error) {
	safe, err := sanitizeUploadFilename(filename)
	if err != nil {
		return "", err
	}
	// session id is opaque from sanitization's POV — we only need it
	// to not escape. UUIDs satisfy this, but a malicious client could
	// pass anything, so apply the same rules.
	safeSession, err := sanitizeUploadFilename(sessionID)
	if err != nil {
		return "", errors.New("invalid session id: " + err.Error())
	}
	dir := filepath.Join(workspaceDir, "uploads", safeSession)
	if err := os.MkdirAll(dir, 0o755); err != nil {
		return "", err
	}
	dst := filepath.Join(dir, safe)
	if err := os.WriteFile(dst, body, 0o644); err != nil {
		return "", err
	}
	return dst, nil
}
