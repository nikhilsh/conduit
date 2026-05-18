// Package discovery advertises the harness on the LAN so mobile clients
// can pick it up without typing the address. Service name is
// `_swe-kitty._tcp.local`; TXT records carry the bearer token and a
// short instance id so multiple harnesses on one network are
// distinguishable in the picker UI.
package discovery

import (
	"context"
	"fmt"
	"os"

	"github.com/grandcat/zeroconf"
)

const (
	ServiceType = "_swe-kitty._tcp"
	Domain      = "local."
)

// Advertise registers the service and returns a shutdown func. Caller
// invokes the returned func on harness shutdown.
func Advertise(port int, token string) (func(), error) {
	host, err := os.Hostname()
	if err != nil || host == "" {
		host = "swe-kitty"
	}
	instance := fmt.Sprintf("%s-%d", host, port)

	srv, err := zeroconf.Register(
		instance,
		ServiceType,
		Domain,
		port,
		[]string{
			"v=1",
			// Token in a TXT record is fine for LAN discovery — a
			// device that can read TXT can also reach the harness.
			"token=" + token,
		},
		nil, // interfaces — nil means all
	)
	if err != nil {
		return nil, fmt.Errorf("mdns register: %w", err)
	}
	shutdown := func() {
		srv.Shutdown()
	}
	return shutdown, nil
}

// Browse is a one-shot lookup helper for tests / CLI smoke checks.
// Mobile clients use platform-native browsers (NWBrowser on iOS,
// NsdManager on Android) instead.
func Browse(ctx context.Context, results chan<- *zeroconf.ServiceEntry) error {
	resolver, err := zeroconf.NewResolver(nil)
	if err != nil {
		return err
	}
	return resolver.Browse(ctx, ServiceType, Domain, results)
}
