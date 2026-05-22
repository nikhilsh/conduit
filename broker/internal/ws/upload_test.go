package ws

import (
	"encoding/binary"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// buildUploadPayload encodes a 0x01 file-upload payload (without the
// leading tag byte — parseUploadFrame expects the tag to already be
// peeled). Helper for table tests below.
func buildUploadPayload(sessionID, filename, mime string, body []byte) []byte {
	out := []byte{}
	appendLP := func(s []byte) {
		var lenBuf [4]byte
		binary.LittleEndian.PutUint32(lenBuf[:], uint32(len(s)))
		out = append(out, lenBuf[:]...)
		out = append(out, s...)
	}
	appendLP([]byte(sessionID))
	appendLP([]byte(filename))
	appendLP([]byte(mime))
	out = append(out, body...)
	return out
}

func TestUploadFrameRoundTripWritesFile(t *testing.T) {
	tmp := t.TempDir()
	sessionID := "9d8c1f3a-0000-4000-8000-000000000001"
	filename := "hello.txt"
	body := []byte("hello upload\n")

	raw := buildUploadPayload(sessionID, filename, "text/plain", body)
	frame, err := parseUploadFrame(raw)
	if err != nil {
		t.Fatalf("parseUploadFrame: %v", err)
	}
	if frame.SessionID != sessionID {
		t.Fatalf("session id: got %q want %q", frame.SessionID, sessionID)
	}
	if frame.Filename != filename {
		t.Fatalf("filename: got %q want %q", frame.Filename, filename)
	}
	if frame.MIME != "text/plain" {
		t.Fatalf("mime: got %q", frame.MIME)
	}
	if string(frame.Body) != string(body) {
		t.Fatalf("body: got %q want %q", frame.Body, body)
	}

	dst, err := writeUpload(tmp, frame.SessionID, frame.Filename, frame.Body)
	if err != nil {
		t.Fatalf("writeUpload: %v", err)
	}
	wantPath := filepath.Join(tmp, "uploads", sessionID, filename)
	if dst != wantPath {
		t.Fatalf("dst: got %q want %q", dst, wantPath)
	}
	got, err := os.ReadFile(dst)
	if err != nil {
		t.Fatalf("ReadFile: %v", err)
	}
	if string(got) != string(body) {
		t.Fatalf("on-disk body: got %q want %q", got, body)
	}
}

// Path-traversal: '../etc/passwd' MUST be rejected by sanitization and
// MUST NOT land on disk anywhere under workspaceDir.
func TestUploadRejectsPathTraversal(t *testing.T) {
	tmp := t.TempDir()
	sessionID := "9d8c1f3a-0000-4000-8000-000000000002"

	cases := []string{
		"../etc/passwd",
		"/etc/passwd",
		"foo/bar.txt",
		"..\\windows\\system32",
		"..",
		".",
		"",
		"   ",
	}
	for _, bad := range cases {
		bad := bad
		t.Run(bad, func(t *testing.T) {
			_, err := writeUpload(tmp, sessionID, bad, []byte("x"))
			if err == nil {
				t.Fatalf("writeUpload(%q): expected error, got none", bad)
			}
			// Nothing should have been written at the workspace root.
			entries, _ := os.ReadDir(tmp)
			for _, e := range entries {
				if e.Name() != "uploads" {
					t.Fatalf("unexpected sibling created at workspace root: %s", e.Name())
				}
			}
		})
	}
}

// Missing / mismatched session: parser accepts any session id (it's a
// string), but writeUpload rejects ones that fail the same sanitization
// rules as filenames (no path separators, no '..', no leading '/'). The
// socket-side mismatch ("upload claims a different session than the WS
// path") is exercised in the server-level path; here we pin the
// sanitization contract.
func TestUploadRejectsInvalidSessionID(t *testing.T) {
	tmp := t.TempDir()
	cases := []string{
		"",
		"/abs",
		"../escape",
		"a/b",
	}
	for _, bad := range cases {
		bad := bad
		t.Run("session="+bad, func(t *testing.T) {
			_, err := writeUpload(tmp, bad, "ok.txt", []byte("x"))
			if err == nil {
				t.Fatalf("writeUpload(session=%q): expected error", bad)
			}
			if !strings.Contains(err.Error(), "session") {
				t.Fatalf("error should mention session id; got: %v", err)
			}
		})
	}
}

// Sanity: the encoder/decoder are length-prefixed correctly even for
// awkward UTF-8 filenames (Cyrillic, with spaces).
func TestUploadFrameUTF8Filename(t *testing.T) {
	tmp := t.TempDir()
	sessionID := "9d8c1f3a-0000-4000-8000-000000000003"
	filename := "Привет мир.txt"
	body := []byte("ok")
	raw := buildUploadPayload(sessionID, filename, "text/plain", body)
	frame, err := parseUploadFrame(raw)
	if err != nil {
		t.Fatalf("parseUploadFrame: %v", err)
	}
	if frame.Filename != filename {
		t.Fatalf("filename round-trip: got %q want %q", frame.Filename, filename)
	}
	dst, err := writeUpload(tmp, frame.SessionID, frame.Filename, frame.Body)
	if err != nil {
		t.Fatalf("writeUpload: %v", err)
	}
	if filepath.Base(dst) != filename {
		t.Fatalf("basename: got %q want %q", filepath.Base(dst), filename)
	}
}

// Truncated frames return parse errors rather than panicking.
func TestUploadFrameTruncated(t *testing.T) {
	// Just a length prefix, no payload bytes.
	short := []byte{0x05, 0x00, 0x00, 0x00, 'a'} // claims 5 bytes, supplies 1
	if _, err := parseUploadFrame(short); err == nil {
		t.Fatal("expected truncation error, got nil")
	}
}
