# Knowledge base index

This is Phase 0 of the conduit knowledge base — a static, git-tracked index.
Phase 1 will add a `conduit kb` CLI and injection into both agents at session
spawn via `broker/internal/session/conduitprompt.go`.

**Convention:** index-then-open. Read the one-line summaries here to find the
right entry; open the entry file for the full fact, rule, or footgun. Each entry
is self-contained and cross-links related entries.

---

## Broker and deployment

| Entry | Summary |
|-------|---------|
| [BROKER-OPS-FOOTGUNS](BROKER-OPS-FOOTGUNS.md) | Broker runs under systemd — redeploy = mv + systemctl restart; never pkill; pgrep returns wrong PID; auto-update only fires on full re-bootstrap; deploy relay before broker when adding push categories. |
| [RELEASE-GOTCHAS](RELEASE-GOTCHAS.md) | Android release runs lint that PR CI skips (fix forward, no tag rollback); tagging does NOT deploy the broker; relay deploys before broker for new push categories; website deploys via workflow_dispatch not from the dev box. |

## SSH bootstrap

| Entry | Summary |
|-------|---------|
| [SSH-BOOTSTRAP-FOOTGUNS](SSH-BOOTSTRAP-FOOTGUNS.md) | Never use /releases/latest/download (all conduit releases are prereleases → 404); curl\|sh masks exit code (assert binary exists after install); systemd broker unit needs explicit PATH env or agent CLIs are not found; iOS TOFU prompt must be an alert not a sheet (two sheets deadlock); failed adds persist as retryable entries since v0.0.158. |

## Core / bindings

| Entry | Summary |
|-------|---------|
| [UNIFFI-BINDINGS](UNIFFI-BINDINGS.md) | Always `make bindings` — hand-edited bindings carry stale checksums that compile but fatal-panic the app at load (contractVersionMismatch); clippy does not catch it. |
| [IS-SANDBOX-ROOT](IS-SANDBOX-ROOT.md) | Any broker exec of `claude --dangerously-skip-permissions` must set `IS_SANDBOX=1` or it is refused under root; CI (non-root) passes while prod fails silently. |

## Auth and protocol

| Entry | Summary |
|-------|---------|
| [CLAUDE-OAUTH-GROUND-TRUTH](CLAUDE-OAUTH-GROUND-TRUTH.md) | Extract Claude OAuth params from the real CLI binary — live URL probe + bundle grep; token exchange is JSON body (not form), state+verifier are 43-char base64url; re-extract when Anthropic rotates the flow. |
| [ASKUSERQUESTION-CONTROL-BRIDGE](ASKUSERQUESTION-CONTROL-BRIDGE.md) | Broker intercepts AskUserQuestion via --permission-prompt-tool stdio; agent blocks until phone answers; multi-select encoded as a text marker; chat resume via --resume / codex thread persistence. |
| [STOP-INTERRUPT-PROTOCOL](STOP-INTERRUPT-PROTOCOL.md) | Claude: send control_request subtype=interrupt to stdin; Codex: turn/interrupt JSON-RPC with threadId+turnId (both required); no process kill needed; turnId must be latched from turn/start response. |
| [PER-BOX-CREDENTIAL-MODEL](PER-BOX-CREDENTIAL-MODEL.md) | Credentials are stored per-box on the broker (not device-global); apps auto-propagate on every connect via POST /api/agent/credentials; /clear removes only the app-pushed credential, not the box owner's shell login. |

## iOS and Android

| Entry | Summary |
|-------|---------|
| [IOS-HTTP-FOOTGUNS](IOS-HTTP-FOOTGUNS.md) | URLComponents.path percent-encodes ? → %3F — split at ? and set percentEncodedQuery instead; stale-callback flicker must be guarded by client generation, not by reachability; iOS compile: fileprivate + @MainActor nonisolated footguns. |
| [ANDROID-THEMING](ANDROID-THEMING.md) | Stock Material colorScheme leaks purple into FilledTonalButton/Chip/menus — use conduitColorScheme(neonTheme) in MaterialTheme; specific-tint buttons still need explicit ButtonDefaults.filledTonalButtonColors. |

## Observability

| Entry | Summary |
|-------|---------|
| [SENTRY-QUOTA-DIAGNOSIS](SENTRY-QUOTA-DIAGNOSIS.md) | Telemetry-dark always check quota first (one API call to stats_v2); Telemetry.debug creates full events — downgrade to breadcrumbs for high-frequency calls; breadcrumbs are invisible in Sentry without a captured event at the terminus. |

---

## Living process (pointers — do not duplicate here)

- **Operating model, delegation, Definition of Done, commit style:**
  → `CLAUDE.md` (repo root)
- **Harness hooks, /compact, /clear, agent concurrency:**
  → `docs/OPERATING-HARNESS.md`
- **Roadmap → In-Progress → Verify-Checklist → Done pipeline:**
  → `docs/ROADMAP.md`, `docs/IN-PROGRESS.md`, `docs/VERIFY-CHECKLIST.md`,
    `docs/DONE.md`

---

## Runbooks (pointers — do not duplicate here)

| Doc | Purpose |
|-----|---------|
| `docs/BROKER-REDEPLOY.md` | Canonical broker redeploy procedure (build → mv -f → systemctl restart → verify). |
| `docs/RELEASE.md` | App release procedure. |
| `docs/RELEASE-IOS.md` | iOS-specific release and TestFlight steps. |
| `docs/SELF-HOST.md` | Self-hosting the broker. |
| `docs/BACKUP-RECOVERY.md` | Backup and recovery. |
| `docs/SENTRY-OPS.md` | Sentry project management, quota, DSN rotation. |

---

## Protocol contracts (read before touching broker/ or core/)

These docs define wire formats and lifecycle contracts. Read them before making
changes that cross the broker/app boundary.

| Doc | Covers |
|-----|--------|
| `docs/WEBSOCKET-PROTOCOL.md` | All WebSocket message types between broker and apps. |
| `docs/SESSION-LIFECYCLE.md` | Session create/attach/close state machine. |
| `docs/AGENT-ADAPTERS.md` | How broker wraps claude, codex, opencode, acp. |
| `docs/CHAT-CHANNEL.md` | Chat message flow, durable send, client_msg_id/chat_ack. |
| `docs/MEMORY-FORMAT.md` | Agent memory HTML format rendered in the app. |
| `docs/CODEX-APPSERVER-PROTOCOL.md` | Codex app-server JSON-RPC (turn/start, turn/interrupt, thread persistence). |
| `docs/OPENCODE-PROTOCOL.md` | opencode adapter protocol. |
| `docs/ACP-PROTOCOL.md` | ACP (Agent Communication Protocol) adapter. |
| `docs/ARCHITECTURE.md` | System architecture overview. |
