// Package discovery advertises the harness on the LAN so mobile clients
// can pick it up without typing the address. Service name is
// `_conduit._tcp.local`; the TXT record carries only a protocol version
// and the instance id (host-port) so multiple harnesses on one network
// are distinguishable in the picker UI. The bearer token is deliberately
// NOT advertised — mDNS TXT records are broadcast in cleartext to every
// host on the LAN, so anyone sniffing the segment could read it. Clients
// pair the token out of band (QR / manual entry).
package discovery

import (
	"context"
	"fmt"
	"os"

	"github.com/grandcat/zeroconf"
)

const (
	ServiceType = "_conduit._tcp"
	Domain      = "local."
)

// Advertise registers the service and returns a shutdown func. Caller
// invokes the returned func on harness shutdown. The bearer token is NOT
// included in the advertisement (see the package doc) — only presence,
// port, and the instance id are broadcast.
func Advertise(port int) (func(), error) {
	host, err := os.Hostname()
	if err != nil || host == "" {
		host = "conduit"
	}
	instance := fmt.Sprintf("%s-%d", host, port)

	srv, err := zeroconf.Register(
		instance,
		ServiceType,
		Domain,
		port,
		[]string{
			"v=1",
			// Presence/port only. The bearer token is intentionally
			// absent — TXT records are broadcast in cleartext to the
			// whole LAN segment.
			"instance=" + instance,
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
