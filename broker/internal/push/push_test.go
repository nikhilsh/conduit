package push

import (
	"context"
	"testing"
)

// ---- LARegistry tests ----

func TestLARegistry_SetGetDrop(t *testing.T) {
	r := NewLARegistry()

	// Not yet registered.
	if got := r.GetLA("broker", "sess-1"); got != "" {
		t.Fatalf("GetLA before set = %q, want empty", got)
	}

	// Set and retrieve.
	r.SetLA("broker", "sess-1", "tok-abc")
	if got := r.GetLA("broker", "sess-1"); got != "tok-abc" {
		t.Fatalf("GetLA after set = %q, want tok-abc", got)
	}

	// Different session — isolated.
	if got := r.GetLA("broker", "sess-2"); got != "" {
		t.Fatalf("sess-2 should be empty, got %q", got)
	}

	// Replace on re-register.
	r.SetLA("broker", "sess-1", "tok-xyz")
	if got := r.GetLA("broker", "sess-1"); got != "tok-xyz" {
		t.Fatalf("after replace = %q, want tok-xyz", got)
	}

	// Drop.
	r.DropLA("broker", "sess-1")
	if got := r.GetLA("broker", "sess-1"); got != "" {
		t.Fatalf("after drop = %q, want empty", got)
	}

	// Safe double-drop.
	r.DropLA("broker", "sess-1")
}

func TestLARegistry_AlertTokenUnaffected(t *testing.T) {
	// LA registry is separate from the alert Registry; operations on one must not
	// affect the other.
	alert := NewRegistry()
	la := NewLARegistry()

	alert.Register("broker", tok(PlatformAPNs, "alert-tok"))
	la.SetLA("broker", "sess-1", "la-tok")

	// Alert registry still has the alert token.
	if toks := alert.TokensFor("broker"); len(toks) != 1 || toks[0].Token != "alert-tok" {
		t.Fatalf("alert token changed: %+v", toks)
	}
	// LA registry has only the LA token.
	if got := la.GetLA("broker", "sess-1"); got != "la-tok" {
		t.Fatalf("la token changed: %q", got)
	}

	// Dropping the LA token leaves the alert token intact.
	la.DropLA("broker", "sess-1")
	if toks := alert.TokensFor("broker"); len(toks) != 1 {
		t.Fatalf("alert token disappeared after LA drop: %+v", toks)
	}
}

func TestLARegistry_SetEmptyTokenDrops(t *testing.T) {
	r := NewLARegistry()
	r.SetLA("broker", "sess-1", "tok-abc")
	r.SetLA("broker", "sess-1", "") // empty token = drop
	if got := r.GetLA("broker", "sess-1"); got != "" {
		t.Fatalf("after set-empty = %q, want empty", got)
	}
}

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

// ---- PlatformAPNsLiveActivityStart tests ----

func TestValidPlatform_LiveActivityStart(t *testing.T) {
	if !ValidPlatform(PlatformAPNsLiveActivityStart) {
		t.Fatal("PlatformAPNsLiveActivityStart should be valid")
	}
}

func TestRegisterStartToken_ValidAndPersisted(t *testing.T) {
	path := t.TempDir() + "/tokens.json"
	r := NewRegistryWithPersistence(path)

	// Register a push-to-start token.
	dt := DeviceToken{Platform: PlatformAPNsLiveActivityStart, Token: "start-tok-abc"}
	if !r.Register("broker", dt) {
		t.Fatal("Register apns-liveactivity-start should succeed")
	}

	// StartTokenFor returns it.
	got := r.StartTokenFor("broker")
	if got != "start-tok-abc" {
		t.Fatalf("StartTokenFor = %q, want start-tok-abc", got)
	}

	// TokensFor includes it.
	tokens := r.TokensFor("broker")
	found := false
	for _, t2 := range tokens {
		if t2.Platform == PlatformAPNsLiveActivityStart && t2.Token == "start-tok-abc" {
			found = true
		}
	}
	if !found {
		t.Fatalf("start token not in TokensFor: %+v", tokens)
	}

	// Reload: token persists.
	r2 := NewRegistryWithPersistence(path)
	if got2 := r2.StartTokenFor("broker"); got2 != "start-tok-abc" {
		t.Fatalf("StartTokenFor after reload = %q, want start-tok-abc", got2)
	}
}

func TestStartTokenFor_AbsentWhenNoneRegistered(t *testing.T) {
	r := NewRegistry()
	if got := r.StartTokenFor("broker"); got != "" {
		t.Fatalf("StartTokenFor with no token = %q, want empty", got)
	}
}

func TestRegisterStartToken_DoesNotAffectAlertTokens(t *testing.T) {
	r := NewRegistry()
	r.Register("broker", tok(PlatformAPNs, "alert-tok"))
	r.Register("broker", DeviceToken{Platform: PlatformAPNsLiveActivityStart, Token: "start-tok"})

	// Alert token still present.
	tokens := r.TokensFor("broker")
	var hasAlert, hasStart bool
	for _, t2 := range tokens {
		if t2.Platform == PlatformAPNs {
			hasAlert = true
		}
		if t2.Platform == PlatformAPNsLiveActivityStart {
			hasStart = true
		}
	}
	if !hasAlert {
		t.Error("alert token missing after registering start token")
	}
	if !hasStart {
		t.Error("start token missing")
	}

	// StartTokenFor returns only the start token.
	if got := r.StartTokenFor("broker"); got != "start-tok" {
		t.Errorf("StartTokenFor = %q, want start-tok", got)
	}
}

// ---- Per-device targeting tests (TokensForDevice + persistence) ----

func tokWithDevice(p Platform, token, deviceID string) DeviceToken {
	return DeviceToken{Platform: p, Token: token, DeviceID: deviceID}
}

// (a) Register with device_id stores it; TokensForDevice returns only that device's tokens.
func TestTokensForDevice_ReturnsOnlyMatchingDevice(t *testing.T) {
	r := NewRegistry()
	r.Register("broker", tokWithDevice(PlatformAPNs, "tok-phone-a", "device-a"))
	r.Register("broker", tokWithDevice(PlatformFCM, "tok-phone-a-fcm", "device-a"))
	r.Register("broker", tokWithDevice(PlatformAPNs, "tok-phone-b", "device-b"))

	gotA := r.TokensForDevice("broker", "device-a")
	if len(gotA) != 2 {
		t.Fatalf("TokensForDevice device-a = %d tokens, want 2", len(gotA))
	}
	for _, dt := range gotA {
		if dt.DeviceID != "device-a" {
			t.Errorf("token %q has DeviceID %q, want device-a", dt.Token, dt.DeviceID)
		}
	}

	gotB := r.TokensForDevice("broker", "device-b")
	if len(gotB) != 1 || gotB[0].Token != "tok-phone-b" {
		t.Fatalf("TokensForDevice device-b = %+v, want [tok-phone-b]", gotB)
	}

	// Unknown device_id returns nil (not an empty slice — callers test len).
	if got := r.TokensForDevice("broker", "device-unknown"); len(got) != 0 {
		t.Fatalf("unknown device_id should return empty, got %+v", got)
	}

	// Empty device_id always returns nil.
	if got := r.TokensForDevice("broker", ""); len(got) != 0 {
		t.Fatalf("empty device_id should return empty, got %+v", got)
	}
}

// (a) DeviceID persists through load/save round-trip.
func TestDeviceIDPersistsRoundTrip(t *testing.T) {
	path := t.TempDir() + "/tokens.json"
	r1 := NewRegistryWithPersistence(path)
	r1.Register("broker", tokWithDevice(PlatformAPNs, "tok-abc", "device-uuid-1"))
	r1.Register("broker", tokWithDevice(PlatformFCM, "tok-fcm", "device-uuid-2"))

	r2 := NewRegistryWithPersistence(path)
	got := r2.TokensForDevice("broker", "device-uuid-1")
	if len(got) != 1 || got[0].Token != "tok-abc" || got[0].DeviceID != "device-uuid-1" {
		t.Fatalf("after reload TokensForDevice device-uuid-1 = %+v, want [{apns tok-abc device-uuid-1}]", got)
	}
	got2 := r2.TokensForDevice("broker", "device-uuid-2")
	if len(got2) != 1 || got2[0].DeviceID != "device-uuid-2" {
		t.Fatalf("after reload TokensForDevice device-uuid-2 = %+v", got2)
	}
}

// (a) Old tokens (no DeviceID) are not returned by TokensForDevice.
func TestTokensForDevice_ExcludesOldTokens(t *testing.T) {
	r := NewRegistry()
	r.Register("broker", tok(PlatformAPNs, "old-tok")) // no DeviceID
	r.Register("broker", tokWithDevice(PlatformFCM, "new-tok", "device-a"))

	// Old token should NOT appear under any device_id lookup.
	if got := r.TokensForDevice("broker", ""); len(got) != 0 {
		t.Fatalf("empty device_id returned tokens: %+v", got)
	}
	// Old token does not appear under a real device_id.
	got := r.TokensForDevice("broker", "device-a")
	if len(got) != 1 || got[0].Token != "new-tok" {
		t.Fatalf("TokensForDevice device-a = %+v, want only new-tok", got)
	}
	// Old token still appears in TokensFor (broadcast).
	all := r.TokensFor("broker")
	if len(all) != 2 {
		t.Fatalf("TokensFor = %d, want 2 (both old and new)", len(all))
	}
}
