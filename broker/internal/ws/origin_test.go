package ws

import (
	"net/http"
	"net/http/httptest"
	"testing"
)

func TestCheckOrigin(t *testing.T) {
	cases := []struct {
		name   string
		origin string
		host   string
		want   bool
	}{
		// Native clients (iOS/Android) send no Origin — the trusted path.
		{"missing-origin", "", "broker.example.com", true},
		// Same-origin with the request Host (preview UI served here).
		{"same-origin", "http://broker.example.com", "broker.example.com", true},
		// Loopback origins (local preview / dev tooling).
		{"loopback-localhost", "http://localhost:1977", "broker.example.com", true},
		{"loopback-127", "http://127.0.0.1:1977", "broker.example.com", true},
		// A genuinely cross-site browser Origin must be rejected.
		{"cross-site", "https://evil.example.org", "broker.example.com", false},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			r := httptest.NewRequest(http.MethodGet, "/ws/abc", nil)
			r.Host = c.host
			if c.origin != "" {
				r.Header.Set("Origin", c.origin)
			}
			if got := checkOrigin(r); got != c.want {
				t.Fatalf("checkOrigin(origin=%q host=%q) = %v, want %v", c.origin, c.host, got, c.want)
			}
		})
	}
}
