# Self-hosting `swe-kitty-harness`

Two supported topologies:

1. **LAN** — `swe-kitty-harness up --local` on a laptop / homelab. mDNS
   advertises `_swe-kitty._tcp.local`; mobile clients connect over
   `ws://<host>.local:1977`.
2. **Public VPS** — harness behind Caddy with TLS; mobile clients connect
   over `wss://<your-domain>` from anywhere.

This doc covers both, plus the pairing-QR flow that's the same in either
case.

## LAN

```bash
# Install the harness binary (from the GitHub Release):
curl -sLo /usr/local/bin/swe-kitty-harness \
  https://github.com/nikhilsh/swe-kitty/releases/latest/download/swe-kitty-harness-linux-amd64
chmod +x /usr/local/bin/swe-kitty-harness

# Bring it up. --local enables mDNS advertise.
swe-kitty-harness up --local --addr :1977
```

stdout prints:

```
swe-kitty-harness up
  addr:    :1977
  url:     http://localhost:1977
  token:   <bearer>
  pairing: swekitty://hostname.local:1977?token=<bearer>

▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄
█ ▄▄▄▄▄ █▀▀█ ▄▄▄▄▄ █  …    ← the QR
…
```

Scan the QR with the SweKitty app. Done.

## Public VPS (Caddy + TLS)

You need:

- A small VPS (1 CPU / 1 GB is fine for a single-user harness).
- A domain pointing an A record at it.
- Docker installed if you want to actually spawn agent containers
  (otherwise the harness works in PTY-only mode for testing).

### Install

```bash
ssh root@vps
mkdir -p /opt/swe-kitty && cd /opt/swe-kitty
curl -sLo swe-kitty-harness \
  https://github.com/nikhilsh/swe-kitty/releases/latest/download/swe-kitty-harness-linux-amd64
chmod +x swe-kitty-harness
mkdir -p agents .swe-kitty
# (drop your agents/{claude,codex}.toml + .swe-kitty/env)
```

### systemd unit (`/etc/systemd/system/swe-kitty.service`)

```ini
[Unit]
Description=swe-kitty harness
After=network-online.target

[Service]
WorkingDirectory=/opt/swe-kitty
EnvironmentFile=/opt/swe-kitty/.swe-kitty/env
ExecStart=/opt/swe-kitty/swe-kitty-harness up \
            --addr 127.0.0.1:1977 \
            --public-url https://harness.example.com
Restart=always

[Install]
WantedBy=multi-user.target
```

```bash
systemctl daemon-reload
systemctl enable --now swe-kitty
journalctl -u swe-kitty -f
# copy the printed bearer + QR
```

### Caddyfile (`/etc/caddy/Caddyfile`)

```
harness.example.com {
    encode zstd gzip
    reverse_proxy 127.0.0.1:1977
}
```

Caddy automatically provisions a Let's Encrypt cert. The harness's
WebSocket endpoint at `/ws/...` is reverse-proxied through TLS.

### Pairing

```bash
journalctl -u swe-kitty | grep -A 30 'pairing:'
```

Scan the QR. The app stores the bearer in Keychain
(iOS) / EncryptedSharedPreferences (Android) and connects over
`wss://harness.example.com`.

## Updating

```bash
systemctl stop swe-kitty
curl -sLo /opt/swe-kitty/swe-kitty-harness \
  https://github.com/nikhilsh/swe-kitty/releases/latest/download/swe-kitty-harness-linux-amd64
chmod +x /opt/swe-kitty/swe-kitty-harness
systemctl start swe-kitty
```

Sessions are recovered from `.swe-kitty/sessions/` on disk — clients
reconnect transparently. See `docs/SESSION-LIFECYCLE.md` for the
recovery model.

## Sanity checks

```bash
# from a laptop on the same LAN as a --local harness
dns-sd -B _swe-kitty._tcp local        # macOS
avahi-browse -t _swe-kitty._tcp        # Linux

# from anywhere, against a public deploy
curl -i https://harness.example.com/ws/$(uuidgen) \
     -H "Authorization: Bearer $TOKEN" \
     -H "Upgrade: websocket" -H "Connection: Upgrade" \
     -H "Sec-WebSocket-Key: $(openssl rand -base64 16)" \
     -H "Sec-WebSocket-Version: 13"
# expect: 101 Switching Protocols
```

## Hardening

- Treat the bearer like an SSH key: anyone with it has shell on the
  harness host through the agent containers. Rotate by restarting the
  harness (each `up` mints a fresh token).
- Run the harness as a non-root user with Docker group membership.
- Caddy + Cloudflare in front gives DDoS protection essentially for
  free.
- The harness binds to `127.0.0.1` in the systemd example above so it's
  only reachable via the reverse proxy.
