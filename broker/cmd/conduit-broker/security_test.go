package main

import "testing"

func TestIsPublicBind(t *testing.T) {
	cases := []struct {
		addr string
		want bool
	}{
		// Loopback / explicit local — NOT public.
		{"127.0.0.1:1977", false},
		{"localhost:1977", false},
		{"[::1]:1977", false},
		// All-interfaces binds — public.
		{":1977", true},
		{"0.0.0.0:1977", true},
		{"[::]:1977", true},
		// Concrete LAN/public IP — public.
		{"192.168.1.10:1977", true},
		{"203.0.113.5:1977", true},
		// Hostname (non-IP) — treated as public.
		{"broker.example.com:1977", true},
		// Unparseable — conservatively public.
		{"garbage", true},
	}
	for _, c := range cases {
		if got := isPublicBind(c.addr); got != c.want {
			t.Errorf("isPublicBind(%q) = %v, want %v", c.addr, got, c.want)
		}
	}
}

func TestRedactToken(t *testing.T) {
	// A real minted token is 43 chars; the fingerprint must not contain
	// the full secret but must reveal the prefix + length.
	tok := "abcdef0123456789abcdef0123456789abcdef0123"
	got := redactToken(tok)
	if got == tok {
		t.Fatal("redactToken returned the full token")
	}
	if len(got) >= len(tok) {
		t.Fatalf("redacted form not shorter than token: %q", got)
	}
	if got[:6] != "abcdef" {
		t.Fatalf("redacted form lost the 6-char prefix: %q", got)
	}
	// Short tokens collapse entirely.
	if redactToken("short") != "<redacted>" {
		t.Fatalf("short token not collapsed: %q", redactToken("short"))
	}
}
