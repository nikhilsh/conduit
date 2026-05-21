# Self-hosting `swe-kitty-broker`

The broker ships as a single Docker image (`swekitty/broker:latest`)
that bakes the Go server, all agent CLIs (claude, codex, …), and the
required system tooling into one container. This is the **recommended**
deploy path — it matches how upstream `swe-swe` distributes itself and
sidesteps the host-permissions corner cases (claude refuses
`--dangerously-skip-permissions` under root; bare-binary deploys hit
this).

## Recommended: docker compose (pull from GHCR)

Every tagged or dispatched release of this repo publishes
`ghcr.io/nikhilsh/swe-kitty:<tag>` and `ghcr.io/nikhilsh/swe-kitty:latest`
to the GitHub Container Registry. Multi-arch (linux/amd64 + linux/arm64).

```bash
git clone git@github.com:nikhilsh/swe-kitty.git    # for the compose file
cd swe-kitty/broker/docker

cp .env.example .env
$EDITOR .env                                       # fill ANTHROPIC_API_KEY / OPENAI_API_KEY

docker compose pull                                # fetch latest image from ghcr.io
docker compose up -d                               # one container, port 1977
docker logs swe-kitty-broker 2>&1 | grep -E 'token:|pairing:' | tail -2
```

Pin to a specific version instead of `latest`:

```bash
HARNESS_IMAGE_TAG=v0.0.27 docker compose up -d
```

Build locally instead of pulling (useful while iterating on the
Dockerfile / agent set):

```bash
docker compose up -d --build
```

The pairing log line is your `swekitty://…?token=…` URL — tap it on the
phone (the SweKitty app registers the scheme) and you're paired. The
default agent adapters (`claude`, `codex`) are pre-installed inside the
image, so no extra config is needed.

Two supported topologies:

1. **LAN / homelab** — `docker compose up -d` on a laptop / dev box.
   Mobile clients connect over `ws://<host>:1977`. Enable mDNS by
   appending `--local` to the broker command (see "Service overrides"
   below).
2. **Public VPS** — same compose stack, plus Caddy in front for TLS;
   mobile clients connect over `wss://<your-domain>` from anywhere.

## Bare binary (legacy path, not recommended)

If you can't run Docker, the broker still ships as a static binary —
but you'll need to install claude/codex separately on PATH, and you'll
need to run the broker as a non-root user (uid != 0) so claude accepts
`--dangerously-skip-permissions`.

```bash
# Install the broker binary (from the GitHub Release):
curl -sLo /usr/local/bin/swe-kitty-broker \
  https://github.com/nikhilsh/swe-kitty/releases/latest/download/swe-kitty-broker-linux-amd64
chmod +x /usr/local/bin/swe-kitty-broker

# Install agent CLIs *natively* (NOT via npm — re-running `npm install -g`
# on top of a previous install fails with ENOTEMPTY and leaves the
# binary in a half-broken state; we hit this three times in a single
# day on the dogfood box). Anthropic's signed apt repo is the
# preferred host install per https://code.claude.com/docs/en/setup.

# Claude Code via apt (Debian / Ubuntu):
install -d -m 0755 /etc/apt/keyrings
curl -fsSL https://downloads.claude.ai/keys/claude-code.asc \
  -o /etc/apt/keyrings/claude-code.asc
# Verify the fingerprint matches:
#   31DD DE24 DDFA B679 F42D 7BD2 BAA9 29FF 1A7E CACE
gpg --show-keys /etc/apt/keyrings/claude-code.asc
echo "deb [signed-by=/etc/apt/keyrings/claude-code.asc] https://downloads.claude.ai/claude-code/apt/stable stable main" \
  > /etc/apt/sources.list.d/claude-code.list
apt update && apt install -y claude-code

# Or via the official native installer (recommended by Anthropic,
# per-user under ~/.local/bin/claude, auto-updates in background):
#   curl -fsSL https://claude.ai/install.sh | bash

# Codex still ships via npm only:
npm install -g @openai/codex

# Bring up the broker. Run as a non-root user (claude refuses
# --dangerously-skip-permissions under root). --local enables mDNS.
swe-kitty-broker up --local --addr :1977
```

stdout prints:

```
swe-kitty-broker up
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

- A small VPS (1 CPU / 1 GB is fine for a single-user broker).
- A domain pointing an A record at it.
- Docker installed if you want to actually spawn agent containers
  (otherwise the broker works in PTY-only mode for testing).

### Install

```bash
ssh root@vps
mkdir -p /opt/swe-kitty && cd /opt/swe-kitty
curl -fsSL https://github.com/nikhilsh/swe-kitty/releases/latest/download/install.sh \
  | sh -s -- --bin-dir /opt/swe-kitty
mkdir -p .swe-kitty
# Drop .swe-kitty/env if you want to pass through ANTHROPIC_API_KEY /
# OPENAI_API_KEY. The default agent TOMLs are embedded in the binary;
# override by placing TOMLs in ~/.swe-kitty/agents/ or pass --agents-dir.
```

### systemd unit (`/etc/systemd/system/swe-kitty.service`)

```ini
[Unit]
Description=swe-kitty broker
After=network-online.target

[Service]
WorkingDirectory=/opt/swe-kitty
EnvironmentFile=/opt/swe-kitty/.swe-kitty/env
ExecStart=/opt/swe-kitty/swe-kitty-broker up \
            --addr 127.0.0.1:1977 \
            --public-url https://broker.example.com
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
broker.example.com {
    encode zstd gzip
    reverse_proxy 127.0.0.1:1977
}
```

Caddy automatically provisions a Let's Encrypt cert. The broker's
WebSocket endpoint at `/ws/...` is reverse-proxied through TLS.

### Pairing

```bash
journalctl -u swe-kitty | grep -A 30 'pairing:'
```

Scan the QR. The app stores the bearer in Keychain
(iOS) / EncryptedSharedPreferences (Android) and connects over
`wss://broker.example.com`.

## Updating

```bash
systemctl stop swe-kitty
curl -sLo /opt/swe-kitty/swe-kitty-broker \
  https://github.com/nikhilsh/swe-kitty/releases/latest/download/swe-kitty-broker-linux-amd64
chmod +x /opt/swe-kitty/swe-kitty-broker
systemctl start swe-kitty
```

Sessions are recovered from `.swe-kitty/sessions/` on disk — clients
reconnect transparently. See `docs/SESSION-LIFECYCLE.md` for the
recovery model.

## Sanity checks

```bash
# from a laptop on the same LAN as a --local broker
dns-sd -B _swe-kitty._tcp local        # macOS
avahi-browse -t _swe-kitty._tcp        # Linux

# from anywhere, against a public deploy
curl -i https://broker.example.com/ws/$(uuidgen) \
     -H "Authorization: Bearer $TOKEN" \
     -H "Upgrade: websocket" -H "Connection: Upgrade" \
     -H "Sec-WebSocket-Key: $(openssl rand -base64 16)" \
     -H "Sec-WebSocket-Version: 13"
# expect: 101 Switching Protocols
```

## Hardening

- Treat the bearer like an SSH key: anyone with it has shell on the
  broker host through the agent containers. Rotate by restarting the
  broker (each `up` mints a fresh token).
- Run the broker as a non-root user with Docker group membership.
- Caddy + Cloudflare in front gives DDoS protection essentially for
  free.
- The broker binds to `127.0.0.1` in the systemd example above so it's
  only reachable via the reverse proxy.
