# Self-hosting `conduit-broker`

The broker runs **directly on the box** as a single static Go binary —
there is no Docker / container requirement. You install the binary, make
sure the agent CLIs (`claude`, `codex`) are on `PATH`, point it at a
working directory, and run `conduit-broker up`. The pairing log line is
your `conduit://…?token=…` URL — tap it on the phone (the Conduit app
registers the scheme) and you're connected.

Running as **root is fine**: the broker sets `IS_SANDBOX=1` for the
agents it spawns, which lets Claude Code accept
`--dangerously-skip-permissions` under root (it otherwise refuses). Each
session gets its own ephemeral `$HOME`, so concurrent agents don't race
on credentials.

> Trust model: anyone with the bearer token can run commands on this box
> through the agent (the agents run with `--dangerously-skip-permissions`
> / `--dangerously-bypass-approvals-and-sandbox`). Self-host on a box you
> own, for your own use. Treat the bearer like an SSH key.

## Install the broker

```bash
# Install the broker binary (from the GitHub Release):
curl -sLo /usr/local/bin/conduit-broker \
  https://github.com/nikhilsh/conduit/releases/latest/download/conduit-broker-linux-amd64
chmod +x /usr/local/bin/conduit-broker

# Install agent CLIs *natively* (NOT via npm for claude — re-running
# `npm install -g` on top of a previous install fails with ENOTEMPTY and
# leaves the binary half-broken). Anthropic's signed apt repo is the
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

# Or via the official native installer (per-user under ~/.local/bin/claude,
# auto-updates in background):
#   curl -fsSL https://claude.ai/install.sh | bash

# Codex still ships via npm only:
npm install -g @openai/codex

# Bring the broker up. --local enables mDNS so the app auto-discovers it
# on your LAN. Pick the working directory the agents run in with --cwd
# (defaults to a per-session worktree).
conduit-broker up --local --addr :1977
```

stdout prints:

```
conduit-broker up
  addr:    :1977
  url:     http://localhost:1977
  token:   <bearer>
  pairing: conduit://hostname.local:1977?token=<bearer>

▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄
█ ▄▄▄▄▄ █▀▀█ ▄▄▄▄▄ █  …    ← the QR
…
```

Scan the QR with the Conduit app (or tap the `conduit://` link). Done.

Two supported topologies:

1. **LAN / homelab** — run `conduit-broker up --local` on a laptop / dev
   box. Mobile clients connect over `ws://<host>:1977` and discover it via
   mDNS (`_conduit._tcp`).
2. **Public VPS** — same binary, plus Caddy in front for TLS; mobile
   clients connect over `wss://<your-domain>` from anywhere (below).

## Public VPS (Caddy + TLS)

You need:

- A small VPS (1 CPU / 1 GB is fine for a single-user broker).
- A domain pointing an A record at it.

### Install

```bash
ssh root@vps
mkdir -p /opt/conduit && cd /opt/conduit
curl -fsSL https://github.com/nikhilsh/conduit/releases/latest/download/install.sh \
  | sh -s -- --bin-dir /opt/conduit
mkdir -p .conduit
# Drop .conduit/env if you want to pass through ANTHROPIC_API_KEY /
# OPENAI_API_KEY. The default agent TOMLs are embedded in the binary;
# override by placing TOMLs in ~/.conduit/agents/ or pass --agents-dir.
# Install claude/codex on PATH on the VPS too (see "Install the broker").
```

### systemd unit (`/etc/systemd/system/conduit.service`)

```ini
[Unit]
Description=conduit broker
After=network-online.target

[Service]
WorkingDirectory=/opt/conduit
EnvironmentFile=/opt/conduit/.conduit/env
ExecStart=/opt/conduit/conduit-broker up \
            --addr 127.0.0.1:1977 \
            --public-url https://broker.example.com
Restart=always

[Install]
WantedBy=multi-user.target
```

```bash
systemctl daemon-reload
systemctl enable --now conduit
journalctl -u conduit -f
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
journalctl -u conduit | grep -A 30 'pairing:'
```

Scan the QR. The app stores the bearer in Keychain
(iOS) / EncryptedSharedPreferences (Android) and connects over
`wss://broker.example.com`.

## Updating

```bash
systemctl stop conduit
curl -sLo /opt/conduit/conduit-broker \
  https://github.com/nikhilsh/conduit/releases/latest/download/conduit-broker-linux-amd64
chmod +x /opt/conduit/conduit-broker
systemctl start conduit
```

Sessions are recovered from `.conduit/sessions/` on disk — clients
reconnect transparently. See `docs/SESSION-LIFECYCLE.md` for the
recovery model.

## Sanity checks

```bash
# from a laptop on the same LAN as a --local broker
dns-sd -B _conduit._tcp local        # macOS
avahi-browse -t _conduit._tcp        # Linux

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
  broker host through the agent. Rotate by restarting the broker (each
  `up` mints a fresh token).
- Bind the broker to `127.0.0.1` (as in the systemd example) so it's only
  reachable via the reverse proxy.
- Caddy + Cloudflare in front gives DDoS protection essentially for free.
