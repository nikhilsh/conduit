package push

import (
	"context"
	"errors"
	"testing"
)

// recordingSender records each Send call and can be told to fail a
// specific token (with an arbitrary error, including ErrTokenGone).
type recordingSender struct {
	sent     []DeviceToken
	failWith map[string]error // token -> error to return
}

func (s *recordingSender) Send(_ context.Context, token DeviceToken, _ Payload) error {
	s.sent = append(s.sent, token)
	if s.failWith != nil {
		if err, ok := s.failWith[token.Token]; ok {
			return err
		}
	}
	return nil
}

func TestDispatcherFansOutToAllPlatforms(t *testing.T) {
	reg := NewRegistry()
	reg.Register("alice", tok(PlatformAPNs, "a1"))
	reg.Register("alice", tok(PlatformFCM, "f1"))
	apns := &recordingSender{}
	fcm := &recordingSender{}
	d := NewDispatcher(reg, map[Platform]Sender{PlatformAPNs: apns, PlatformFCM: fcm})

	if err := d.Notify(context.Background(), "alice", Payload{Title: "t", Body: "b"}); err != nil {
		t.Fatalf("Notify: %v", err)
	}
	if len(apns.sent) != 1 || apns.sent[0].Token != "a1" {
		t.Fatalf("apns sent = %+v, want [a1]", apns.sent)
	}
	if len(fcm.sent) != 1 || fcm.sent[0].Token != "f1" {
		t.Fatalf("fcm sent = %+v, want [f1]", fcm.sent)
	}
}

func TestDispatcherPrunesGoneTokens(t *testing.T) {
	reg := NewRegistry()
	reg.Register("alice", tok(PlatformAPNs, "good"))
	reg.Register("alice", tok(PlatformAPNs, "dead"))
	apns := &recordingSender{failWith: map[string]error{"dead": ErrTokenGone}}
	d := NewDispatcher(reg, map[Platform]Sender{PlatformAPNs: apns})

	// ErrTokenGone is not surfaced as an error — it's handled by pruning.
	if err := d.Notify(context.Background(), "alice", Payload{}); err != nil {
		t.Fatalf("Notify should not error on ErrTokenGone, got %v", err)
	}
	left := reg.TokensFor("alice")
	if len(left) != 1 || left[0].Token != "good" {
		t.Fatalf("after prune, tokens = %+v, want [good]", left)
	}
}

func TestDispatcherSkipsPlatformWithoutSender(t *testing.T) {
	reg := NewRegistry()
	reg.Register("alice", tok(PlatformAPNs, "a1"))
	reg.Register("alice", tok(PlatformFCM, "f1"))
	// Only an APNs sender configured; FCM has none.
	apns := &recordingSender{}
	d := NewDispatcher(reg, map[Platform]Sender{PlatformAPNs: apns})

	if err := d.Notify(context.Background(), "alice", Payload{}); err != nil {
		t.Fatalf("Notify: %v", err)
	}
	if len(apns.sent) != 1 {
		t.Fatalf("apns sent = %d, want 1", len(apns.sent))
	}
	// The FCM token is left registered (not pruned) for when a sender lands.
	if n := len(reg.TokensFor("alice")); n != 2 {
		t.Fatalf("tokens = %d, want 2 (fcm kept)", n)
	}
}

func TestDispatcherJoinsTransientErrors(t *testing.T) {
	reg := NewRegistry()
	reg.Register("alice", tok(PlatformAPNs, "a1"))
	boom := errors.New("apns 503")
	apns := &recordingSender{failWith: map[string]error{"a1": boom}}
	d := NewDispatcher(reg, map[Platform]Sender{PlatformAPNs: apns})

	err := d.Notify(context.Background(), "alice", Payload{})
	if err == nil || !errors.Is(err, boom) {
		t.Fatalf("expected transient error surfaced, got %v", err)
	}
	// Transient failure does NOT prune the token.
	if n := len(reg.TokensFor("alice")); n != 1 {
		t.Fatalf("token should be kept on transient error, got %d", n)
	}
}

// Dispatcher must satisfy the Notifier interface.
var _ Notifier = (*Dispatcher)(nil)

// ---- NotifyDevice tests (b) ----

// (b) NotifyDevice sends only to the matching device's tokens.
func TestNotifyDevice_TargetsOnlyMatchingDevice(t *testing.T) {
	reg := NewRegistry()
	reg.Register("broker", DeviceToken{Platform: PlatformAPNs, Token: "tok-a-apns", DeviceID: "device-a"})
	reg.Register("broker", DeviceToken{Platform: PlatformFCM, Token: "tok-a-fcm", DeviceID: "device-a"})
	reg.Register("broker", DeviceToken{Platform: PlatformAPNs, Token: "tok-b", DeviceID: "device-b"})

	apns := &recordingSender{}
	fcm := &recordingSender{}
	d := NewDispatcher(reg, map[Platform]Sender{PlatformAPNs: apns, PlatformFCM: fcm})

	if err := d.NotifyDevice(context.Background(), "broker", "device-a", Payload{Title: "t", Body: "b"}); err != nil {
		t.Fatalf("NotifyDevice: %v", err)
	}
	// device-a has 2 tokens (apns + fcm); device-b must NOT be notified.
	if len(apns.sent) != 1 || apns.sent[0].Token != "tok-a-apns" {
		t.Fatalf("apns sent = %+v, want [tok-a-apns]", apns.sent)
	}
	if len(fcm.sent) != 1 || fcm.sent[0].Token != "tok-a-fcm" {
		t.Fatalf("fcm sent = %+v, want [tok-a-fcm]", fcm.sent)
	}

	// Notify device-b: only tok-b via apns.
	apns.sent = nil
	fcm.sent = nil
	if err := d.NotifyDevice(context.Background(), "broker", "device-b", Payload{}); err != nil {
		t.Fatalf("NotifyDevice device-b: %v", err)
	}
	if len(apns.sent) != 1 || apns.sent[0].Token != "tok-b" {
		t.Fatalf("apns for device-b = %+v, want [tok-b]", apns.sent)
	}
	if len(fcm.sent) != 0 {
		t.Fatalf("fcm for device-b should be 0 (no fcm token), got %d", len(fcm.sent))
	}
}

// (b) NotifyDevice with empty or unknown device_id is a no-op (no panic, no sends).
func TestNotifyDevice_EmptyDeviceID_IsNoOp(t *testing.T) {
	reg := NewRegistry()
	reg.Register("broker", DeviceToken{Platform: PlatformAPNs, Token: "tok-a", DeviceID: "device-a"})
	apns := &recordingSender{}
	d := NewDispatcher(reg, map[Platform]Sender{PlatformAPNs: apns})

	// Empty device_id: no-op.
	if err := d.NotifyDevice(context.Background(), "broker", "", Payload{}); err != nil {
		t.Fatalf("NotifyDevice empty device_id: %v", err)
	}
	if len(apns.sent) != 0 {
		t.Fatalf("empty device_id should send nothing, got %d sends", len(apns.sent))
	}

	// Unknown device_id: no-op (caller must fall back to Notify).
	if err := d.NotifyDevice(context.Background(), "broker", "no-such-device", Payload{}); err != nil {
		t.Fatalf("NotifyDevice unknown device: %v", err)
	}
	if len(apns.sent) != 0 {
		t.Fatalf("unknown device_id should send nothing, got %d sends", len(apns.sent))
	}
}

// (b) NotifyDevice prunes gone tokens (ErrTokenGone), just like Notify.
func TestNotifyDevice_PrunesGoneToken(t *testing.T) {
	reg := NewRegistry()
	reg.Register("broker", DeviceToken{Platform: PlatformAPNs, Token: "dead", DeviceID: "device-a"})
	reg.Register("broker", DeviceToken{Platform: PlatformAPNs, Token: "good", DeviceID: "device-a"})
	apns := &recordingSender{failWith: map[string]error{"dead": ErrTokenGone}}
	d := NewDispatcher(reg, map[Platform]Sender{PlatformAPNs: apns})

	if err := d.NotifyDevice(context.Background(), "broker", "device-a", Payload{}); err != nil {
		t.Fatalf("NotifyDevice with gone token should not surface error: %v", err)
	}
	left := reg.TokensForDevice("broker", "device-a")
	if len(left) != 1 || left[0].Token != "good" {
		t.Fatalf("after prune, tokens = %+v, want only [good]", left)
	}
}
