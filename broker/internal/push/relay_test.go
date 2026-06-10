package push

import (
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"testing"
)

func TestRelaySenderHappyPath(t *testing.T) {
	var got relaySendBody
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != "/v1/send" || r.Method != http.MethodPost {
			t.Errorf("unexpected %s %s", r.Method, r.URL.Path)
		}
		if err := json.NewDecoder(r.Body).Decode(&got); err != nil {
			t.Errorf("decode body: %v", err)
		}
		w.WriteHeader(http.StatusOK)
	}))
	defer srv.Close()

	dir := t.TempDir()
	sender, err := NewRelaySender(srv.URL, filepath.Join(dir, "push-install.json"))
	if err != nil {
		t.Fatalf("NewRelaySender: %v", err)
	}
	if sender == nil {
		t.Fatal("NewRelaySender returned nil")
	}

	token := DeviceToken{Platform: PlatformAPNs, Token: "mydevicetoken"}
	payload := Payload{Title: "hello", Body: "world", SessionID: "sess-1"}

	if err := sender.Send(context.Background(), token, payload); err != nil {
		t.Fatalf("Send: %v", err)
	}

	if got.Platform != "apns" {
		t.Errorf("platform=%q, want apns", got.Platform)
	}
	if got.Token != "mydevicetoken" {
		t.Errorf("token=%q, want mydevicetoken", got.Token)
	}
	if got.Payload.Title != "hello" || got.Payload.Body != "world" || got.Payload.SessionID != "sess-1" {
		t.Errorf("payload=%+v, want title=hello body=world session_id=sess-1", got.Payload)
	}
	if got.InstallID == "" || got.InstallSecret == "" {
		t.Errorf("install_id/install_secret not sent: id=%q sec=%q", got.InstallID, got.InstallSecret)
	}
	if got.Env != "production" {
		t.Errorf("env=%q, want production", got.Env)
	}
}

func TestRelaySender410MapsToTokenGone(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		// Consume body to avoid connection reset
		var b relaySendBody
		_ = json.NewDecoder(r.Body).Decode(&b)
		w.WriteHeader(http.StatusGone)
	}))
	defer srv.Close()

	dir := t.TempDir()
	sender, _ := NewRelaySender(srv.URL, filepath.Join(dir, "push-install.json"))
	err := sender.Send(context.Background(), DeviceToken{Platform: PlatformFCM, Token: "t"}, Payload{})
	if err != ErrTokenGone {
		t.Fatalf("expected ErrTokenGone, got %v", err)
	}
}

func TestRelaySender429RateLimit(t *testing.T) {
	calls := 0
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		calls++
		var b relaySendBody
		_ = json.NewDecoder(r.Body).Decode(&b)
		w.WriteHeader(http.StatusTooManyRequests)
	}))
	defer srv.Close()

	dir := t.TempDir()
	sender, _ := NewRelaySender(srv.URL, filepath.Join(dir, "push-install.json"))
	err := sender.Send(context.Background(), DeviceToken{Platform: PlatformAPNs, Token: "t"}, Payload{})
	if err == nil {
		t.Fatal("expected error on 429")
	}
	// Rate limit should NOT retry.
	if calls != 1 {
		t.Errorf("429 should not retry, got %d calls", calls)
	}
}

func TestRelaySender5xxRetries(t *testing.T) {
	calls := 0
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		calls++
		var b relaySendBody
		_ = json.NewDecoder(r.Body).Decode(&b)
		if calls == 1 {
			w.WriteHeader(http.StatusInternalServerError)
		} else {
			w.WriteHeader(http.StatusOK)
		}
	}))
	defer srv.Close()

	dir := t.TempDir()
	sender, _ := NewRelaySender(srv.URL, filepath.Join(dir, "push-install.json"))
	err := sender.Send(context.Background(), DeviceToken{Platform: PlatformAPNs, Token: "t"}, Payload{})
	if err != nil {
		t.Fatalf("Send should succeed on retry, got %v", err)
	}
	if calls != 2 {
		t.Errorf("5xx should retry once, got %d calls", calls)
	}
}

func TestRelaySenderDisabledWhenEmptyURL(t *testing.T) {
	sender, err := NewRelaySender("", "/irrelevant")
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if sender != nil {
		t.Fatal("empty relayURL should return nil sender")
	}
}

func TestInstallCredMintAndReuse(t *testing.T) {
	path := filepath.Join(t.TempDir(), "push-install.json")

	c1, err := loadOrMintInstallCred(path)
	if err != nil {
		t.Fatalf("mint: %v", err)
	}
	if len(c1.InstallID) != 32 {
		t.Errorf("install_id len=%d, want 32 hex chars", len(c1.InstallID))
	}
	if len(c1.InstallSecret) != 48 {
		t.Errorf("install_secret len=%d, want 48 hex chars", len(c1.InstallSecret))
	}

	// Second load must reuse the same values.
	c2, err := loadOrMintInstallCred(path)
	if err != nil {
		t.Fatalf("reload: %v", err)
	}
	if c1.InstallID != c2.InstallID || c1.InstallSecret != c2.InstallSecret {
		t.Errorf("reloaded cred differs: %+v vs %+v", c1, c2)
	}

	// File must be 0600.
	fi, err := os.Stat(path)
	if err != nil {
		t.Fatalf("stat: %v", err)
	}
	if fi.Mode().Perm() != 0o600 {
		t.Errorf("perm=%o, want 600", fi.Mode().Perm())
	}
}
