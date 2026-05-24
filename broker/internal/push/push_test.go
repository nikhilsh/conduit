package push

import (
	"context"
	"testing"
)

func tok(p Platform, t string) DeviceToken { return DeviceToken{Platform: p, Token: t} }

func TestRegisterAndTokensFor(t *testing.T) {
	r := NewRegistry()
	if !r.Register("alice", tok(PlatformAPNs, "a1")) {
		t.Fatal("Register apns should succeed")
	}
	if !r.Register("alice", tok(PlatformFCM, "f1")) {
		t.Fatal("Register fcm should succeed")
	}
	got := r.TokensFor("alice")
	if len(got) != 2 {
		t.Fatalf("TokensFor = %d tokens, want 2", len(got))
	}
	// Sorted (platform, token): apns before fcm.
	if got[0].Platform != PlatformAPNs || got[1].Platform != PlatformFCM {
		t.Fatalf("tokens not sorted by platform: %+v", got)
	}
}

func TestRegisterIsIdempotent(t *testing.T) {
	r := NewRegistry()
	r.Register("alice", tok(PlatformAPNs, "a1"))
	r.Register("alice", tok(PlatformAPNs, "a1"))
	if n := len(r.TokensFor("alice")); n != 1 {
		t.Fatalf("duplicate token registered %d times, want 1", n)
	}
}

func TestRegisterRejectsBadInput(t *testing.T) {
	r := NewRegistry()
	cases := []struct {
		name     string
		identity string
		token    DeviceToken
	}{
		{"empty identity", "", tok(PlatformAPNs, "a1")},
		{"empty token", "alice", tok(PlatformAPNs, "")},
		{"whitespace token", "alice", tok(PlatformAPNs, "   ")},
		{"unknown platform", "alice", tok(Platform("web"), "w1")},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			if r.Register(c.identity, c.token) {
				t.Fatalf("Register(%q, %+v) should be rejected", c.identity, c.token)
			}
		})
	}
	if n := len(r.TokensFor("alice")); n != 0 {
		t.Fatalf("rejected registrations leaked %d tokens", n)
	}
}

func TestRegisterTrimsWhitespace(t *testing.T) {
	r := NewRegistry()
	if !r.Register("  alice  ", tok(PlatformAPNs, "  a1  ")) {
		t.Fatal("Register with padded values should succeed after trim")
	}
	got := r.TokensFor("alice")
	if len(got) != 1 || got[0].Token != "a1" {
		t.Fatalf("token not trimmed/keyed correctly: %+v", got)
	}
}

func TestUnregister(t *testing.T) {
	r := NewRegistry()
	r.Register("alice", tok(PlatformAPNs, "a1"))
	r.Register("alice", tok(PlatformFCM, "f1"))
	r.Unregister("alice", tok(PlatformAPNs, "a1"))
	got := r.TokensFor("alice")
	if len(got) != 1 || got[0].Platform != PlatformFCM {
		t.Fatalf("after unregister apns, got %+v", got)
	}
	// Dropping the last token removes the identity entry entirely.
	r.Unregister("alice", tok(PlatformFCM, "f1"))
	if n := len(r.TokensFor("alice")); n != 0 {
		t.Fatalf("identity should be empty, got %d", n)
	}
	// Unregistering a never-seen token is safe.
	r.Unregister("bob", tok(PlatformAPNs, "nope"))
}

func TestTokensForIsolatesIdentities(t *testing.T) {
	r := NewRegistry()
	r.Register("alice", tok(PlatformAPNs, "a1"))
	r.Register("bob", tok(PlatformAPNs, "b1"))
	if got := r.TokensFor("alice"); len(got) != 1 || got[0].Token != "a1" {
		t.Fatalf("alice tokens leaked across identity: %+v", got)
	}
	if got := r.TokensFor("nobody"); len(got) != 0 {
		t.Fatalf("unknown identity should have no tokens, got %+v", got)
	}
}

func TestNoopNotifierNeverErrors(t *testing.T) {
	var n Notifier = NoopNotifier{}
	if err := n.Notify(context.Background(), "alice", Payload{Title: "t", Body: "b", SessionID: "s"}); err != nil {
		t.Fatalf("NoopNotifier.Notify errored: %v", err)
	}
}
