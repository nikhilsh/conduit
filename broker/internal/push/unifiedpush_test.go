package push

import (
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"testing"
)

func TestUnifiedPushSenderHappyPath(t *testing.T) {
	var got unifiedPushPayload
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Method != http.MethodPost {
			t.Errorf("unexpected method %s", r.Method)
		}
		if err := json.NewDecoder(r.Body).Decode(&got); err != nil {
			t.Errorf("decode body: %v", err)
		}
		w.WriteHeader(http.StatusOK)
	}))
	defer srv.Close()

	sender := NewUnifiedPushSender()
	token := DeviceToken{Platform: PlatformUnifiedPush, Token: srv.URL + "/push/endpoint"}
	payload := Payload{Title: "t", Body: "b", SessionID: "sess-2"}

	if err := sender.Send(context.Background(), token, payload); err != nil {
		t.Fatalf("Send: %v", err)
	}
	if got.Title != "t" || got.Body != "b" || got.SessionID != "sess-2" {
		t.Errorf("payload=%+v, want {t b sess-2}", got)
	}
}

func TestUnifiedPushSender404MapsToTokenGone(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		var b unifiedPushPayload
		_ = json.NewDecoder(r.Body).Decode(&b)
		w.WriteHeader(http.StatusNotFound)
	}))
	defer srv.Close()

	sender := NewUnifiedPushSender()
	err := sender.Send(context.Background(), DeviceToken{Platform: PlatformUnifiedPush, Token: srv.URL}, Payload{})
	if err != ErrTokenGone {
		t.Fatalf("expected ErrTokenGone on 404, got %v", err)
	}
}

func TestUnifiedPushSender410MapsToTokenGone(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		var b unifiedPushPayload
		_ = json.NewDecoder(r.Body).Decode(&b)
		w.WriteHeader(http.StatusGone)
	}))
	defer srv.Close()

	sender := NewUnifiedPushSender()
	err := sender.Send(context.Background(), DeviceToken{Platform: PlatformUnifiedPush, Token: srv.URL}, Payload{})
	if err != ErrTokenGone {
		t.Fatalf("expected ErrTokenGone on 410, got %v", err)
	}
}

func TestUnifiedPushSenderInvalidURLIsTokenGone(t *testing.T) {
	sender := NewUnifiedPushSender()
	err := sender.Send(context.Background(), DeviceToken{Platform: PlatformUnifiedPush, Token: "not-a-url"}, Payload{})
	if err != ErrTokenGone {
		t.Fatalf("expected ErrTokenGone for non-URL token, got %v", err)
	}
}

func TestUnifiedPushSender5xxRetries(t *testing.T) {
	calls := 0
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		calls++
		var b unifiedPushPayload
		_ = json.NewDecoder(r.Body).Decode(&b)
		if calls == 1 {
			w.WriteHeader(http.StatusBadGateway)
		} else {
			w.WriteHeader(http.StatusOK)
		}
	}))
	defer srv.Close()

	sender := NewUnifiedPushSender()
	err := sender.Send(context.Background(), DeviceToken{Platform: PlatformUnifiedPush, Token: srv.URL}, Payload{})
	if err != nil {
		t.Fatalf("Send should succeed on retry, got %v", err)
	}
	if calls != 2 {
		t.Errorf("5xx should retry once, got %d calls", calls)
	}
}
