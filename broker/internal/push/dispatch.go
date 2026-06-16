package push

import (
	"context"
	"errors"
)

// Sender delivers one Payload to one device. Implementations are the
// platform transports — APNs (iOS) and FCM (Android); the live HTTP
// senders land in a follow-up. Returning [ErrTokenGone] tells the
// Dispatcher to drop the token from the registry.
type Sender interface {
	Send(ctx context.Context, token DeviceToken, payload Payload) error
}

// ErrTokenGone signals a token the provider has permanently rejected
// (APNs 410 Unregistered / FCM UNREGISTERED). The Dispatcher
// unregisters it so the broker stops sending to dead devices.
var ErrTokenGone = errors.New("push: device token no longer valid")

// Dispatcher is the registry-backed [Notifier]: it fans a Payload out to
// every device registered for an identity via the per-platform [Sender],
// and prunes tokens the provider reports as gone. Safe for concurrent
// use — it delegates locking to the Registry.
type Dispatcher struct {
	registry *Registry
	senders  map[Platform]Sender
}

// NewDispatcher builds a Dispatcher. `senders` maps each platform to its
// transport; a platform with no configured sender is skipped (its tokens
// stay registered for when a sender is wired up), so a half-configured
// broker still delivers to the platforms it can reach.
func NewDispatcher(registry *Registry, senders map[Platform]Sender) *Dispatcher {
	return &Dispatcher{registry: registry, senders: senders}
}

// Notify delivers payload to every registered device for identity.
// Per-device send errors are collected and returned joined; an
// [ErrTokenGone] result unregisters that token instead. A platform with
// no configured sender is skipped silently. Implements [Notifier].
func (d *Dispatcher) Notify(ctx context.Context, identity string, payload Payload) error {
	return d.sendToTokens(ctx, identity, d.registry.TokensFor(identity), payload)
}

// NotifyDevice delivers payload only to tokens registered for identity whose
// DeviceID matches deviceID. If deviceID is empty or no matching token is
// found this is a no-op (callers must fall back to Notify themselves — see
// the servePushTest and maybeNotify* sites). Per-device send errors are
// collected and returned joined; ErrTokenGone prunes the token.
func (d *Dispatcher) NotifyDevice(ctx context.Context, identity, deviceID string, payload Payload) error {
	tokens := d.registry.TokensForDevice(identity, deviceID)
	if len(tokens) == 0 {
		return nil
	}
	return d.sendToTokens(ctx, identity, tokens, payload)
}

// sendToTokens is the shared fan-out loop used by Notify and NotifyDevice.
func (d *Dispatcher) sendToTokens(ctx context.Context, identity string, tokens []DeviceToken, payload Payload) error {
	var errs []error
	for _, tok := range tokens {
		sender := d.senders[tok.Platform]
		if sender == nil {
			continue
		}
		if err := sender.Send(ctx, tok, payload); err != nil {
			if errors.Is(err, ErrTokenGone) {
				d.registry.Unregister(identity, tok)
				continue
			}
			errs = append(errs, err)
		}
	}
	return errors.Join(errs...)
}
