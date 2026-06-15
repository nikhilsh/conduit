// Package discovery advertises the harness on the LAN so mobile clients
// can pick it up without typing the address. Service name is
// `_conduit._tcp.local`; the TXT record carries a protocol version, the
// instance id (host-port), and the bearer token so a phone on the same
// LAN can auto-pair with zero typing.
//
// SECURITY: mDNS TXT records are broadcast in cleartext to every host on
// the LAN segment, so the token-bearing advertisement is ONLY safe on a
// trusted, private/loopback bind. The caller (cmd/conduit-broker) gates
// Advertise on the bind posture — it is never called when the broker is
// bound to a public interface (see isPublicBind), so the token is never
// shouted on a public/datacenter wire. On a public bind the operator
// pairs out of band (QR / manual entry) instead.
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

// Advertise registers the service (presence, port, instance id, and the
// bearer token for zero-typing LAN auto-pair) and returns a shutdown func
// the caller invokes on harness shutdown.
//
// SECURITY: the token rides the TXT record in cleartext. Callers MUST only
// invoke Advertise on a trusted private/loopback bind (see the package doc
// and the isPublicBind gate in cmd/conduit-broker) — never when the broker
// is publicly reachable.
func Advertise(port int, token string) (func(), error) {
	host, err := os.Hostname()
	if err != nil || host == "" {
		host = "conduit"
	}
	instance := fmt.Sprintf("%s-%d", host, port)

	txt := []string{
		"v=1",
		"instance=" + instance,
	}
	if token != "" {
		// Only safe because the caller gates this on a private/loopback
		// bind (see the package doc). Lets a same-LAN phone auto-pair.
		txt = append(txt, "token="+token)
	}

	srv, err := zeroconf.Register(
		instance,
		ServiceType,
		Domain,
		port,
		txt,
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
