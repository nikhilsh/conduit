# Plan: `swe-kitty` — phone-first AI coding broker with per-project multi-view, built under its own dev harness

## How To Read This Document

- **Status Snapshot** below is the current reality and should drive execution.
- **Part A onward** preserves the detailed target architecture and the original (2026-04) bootstrap plan, including framing that referenced upstream `swe-swe` as the harness for dev work. That dependency is gone — swe-kitty ships its own `swe-kitty-broker` binary now — but the historical text is preserved verbatim below so the design rationale isn't lost. The newer execution layer is [`PLAN-2026-05-19.md`](PLAN-2026-05-19.md).
- If there is any mismatch, treat the Status Snapshot + newer focused docs (`RELEASE.md`, `MOBILE-FEATURE-BACKLOG.md`, `NEXT-RELEASE.md`, `PLAN-2026-05-19.md`) as the source of truth for immediate work.

## Status Snapshot (May 18, 2026)

### Done
- Repository, CI, and tagged release automation are active.
- Broker one-line bootstrap is active:
  - `install.sh` download/install
  - `swe-kitty-broker up --local` prints bearer token + pairing QR + `swekitty://` deep link
- iOS and Android shipping flow is tag-driven (release workflows + orchestrator + website deploy).
- Rust core has:
  - reconnect/liveness handling
  - typed conversation-item foundation
  - UniFFI bindings used by both apps
- Mobile apps have:
  - terminal/chat/browser tabs
  - tool cards, diff rendering, quick-reply chips
  - saved-server persistence scaffolding in settings

### In Progress
- KittyLitter parity for structured tool-call UX:
  - command metadata richness (args/exit/duration/progress)
  - stronger diff UX (grouping/collapse)
- Pending user-input first-class UX on both platforms.
- Discovery UI parity (mDNS browser / server switching UX polish).

### Planned / Future
- Push notifications + background fetch/wakeup.
- Voice I/O surfaces.
- Subagent/handoff visualization parity.
- Further UI convergence toward KittyLitter design language.

## Original Planning Context (Preserved)

Originally this plan started from an empty working tree (`/root/developer/projects/kitty-swe`) and described full bootstrap to `git@github.com:nikhilsh/swe-kitty.git`. That historical context is intentionally preserved below so future planned sections are not lost.

Two threads run through this plan, and they must not be conflated:

1. **What we are building** — a native iOS + Android app that drives AI coding agents on a broker server. Per-project the app shows multiple **views** (terminal / agent-chat / browser-preview), and the user switches between views inside one project. A separate top-level nav switches between projects.
2. **How we are building it** — local development itself runs under a swe-swe-style harness. Multiple agents (Claude Code, Codex) work on this repo in parallel via per-agent git worktrees, each in its own PTY/container, all pushing to the same GitHub remote. The repo ships a `.swe-kitty/` config so any team member (or AI agent) can `swe-swe up` and instantly get the same harnessed dev environment.

Reference projects:
- **[swe-swe](https://github.com/choonkeat/swe-swe)** — Go harness with PTY+worktree sessions, WebSocket on `:1977`, per-project tabbed multi-view (terminal / agent / browser), agent-interchangeability via CLI adapters
- **[litter](https://github.com/dnakov/litter)** — Native iOS+Android Codex client with Rust shared core (`codex-mobile-client`) exposed through UniFFI bindings; ad-hoc/TestFlight CI scripts

v1 scope decisions (from clarifying Q&A):
- Broker host: **both local LAN and remote VPS**
- Agents v1: **Claude Code + Codex**
- iOS: **ad-hoc signed IPA → GitHub Release** (sideload via AltStore/Sideloadly)
- Android: **signed APK → GitHub Release** (no Play Console)

---

## Part A — Development harness (build *swe-kitty* under harness)

This is set up **before any product code is written**. The goal: `git clone … && swe-swe up` produces an environment where Claude Code and Codex can both be spawned on per-agent git worktrees, working on this repo in parallel.

### A1. Reuse upstream swe-swe for dev

We do *not* fork or modify swe-swe for the dev workflow. Use it as published:

```bash
npm i -g swe-swe          # or alias swe-swe='npx -y swe-swe'
cd ~/developer/projects/kitty-swe
swe-swe up                # opens http://localhost:1977
```

### A2. Repo-shipped harness config: `.swe-kitty/`

```
.swe-kitty/
├── config.toml           # which agents, default ports, default branch base
├── env.example           # ANTHROPIC_API_KEY=, OPENAI_API_KEY= (env to .swe-kitty/env, gitignored)
├── agents/
│   ├── claude.toml       # agent adapter (see Part B section 1)
│   └── codex.toml
├── tasks/                # markdown task briefs for parallel agents
│   ├── 001-harness-server.md
│   ├── 002-rust-core.md
│   ├── 003-ios-shell.md
│   └── 004-android-shell.md
└── README.md             # "How parallel agents work on this repo"
```

`config.toml` example:
```toml
[harness]
agents = ["claude", "codex"]
preview_port_range = [3000, 3019]
default_branch = "main"

[worktree]
# Each session creates: .git/worktrees/<uuid>, branch named agent/<assistant>-<task>
naming = "agent/{assistant}-{task}"

[[task]]
id = "001-harness-server"
brief = ".swe-kitty/tasks/001-harness-server.md"
suggested_agent = "codex"   # not enforcing; user can override

[[task]]
id = "002-rust-core"
brief = ".swe-kitty/tasks/002-rust-core.md"
suggested_agent = "claude"
```

### A3. Parallel-agent workflow on this repo

- Each task brief in `.swe-kitty/tasks/` is self-contained: scope, files to touch, interface contract (e.g., WebSocket protocol is fixed across tasks 001 and 002 so they can land independently), how to test.
- An agent is spawned with `swe-swe up`, picks a task, gets a fresh worktree on branch `agent/<assistant>-<task-id>`.
- Agents commit + push their branch to `nikhilsh/swe-kitty`; integration happens via PRs into `main`.
- `.github/CODEOWNERS` is empty so any agent can merge after CI passes. Required CI checks (Part E) gate the merge.
- **Coordination**: the WebSocket protocol spec (`docs/WEBSOCKET-PROTOCOL.md`) is written in task 000 *first* and held stable so 001 (server) and 002 (core) parallelize cleanly. Same for the agent-adapter TOML schema across 001 and the Dockerfiles.

### A4. CONTRIBUTING.md

Documents the harness workflow so a human contributor or a third agent can drop in. Includes: how to set API keys, how to claim a task (rename brief to `.claimed-by-<agent>.md`), how to rebase before PR.

---

## Part B — The product: `swe-kitty` mobile app + broker server

### Repo layout

```
swe-kitty/                         # local: kitty-swe, remote: nikhilsh/swe-kitty
├── .swe-kitty/                    # dev harness config (Part A)
├── broker/                       # Go server (swe-swe-derived, slimmed)
│   ├── cmd/swe-kitty-broker/
│   ├── internal/session/          # PTY + worktree manager
│   ├── internal/ws/               # WebSocket protocol
│   ├── internal/agents/           # adapter registry
│   ├── internal/auth/             # bearer + mDNS
│   └── docker/                    # per-agent Dockerfiles
├── core/                          # Rust shared core (swe-kitty-core)
│   ├── src/lib.rs
│   ├── src/transport.rs
│   ├── src/session.rs             # per-project session model with multiple views
│   ├── src/views.rs               # terminal/chat/browser view abstractions
│   ├── src/discovery.rs           # mDNS + remote endpoint config
│   └── swe-kitty-core.udl         # UniFFI interface
├── apps/
│   ├── ios/                       # SwiftUI
│   └── android/                   # Kotlin Compose
├── agents/                        # production agent adapters (separate from .swe-kitty/agents/)
│   ├── claude.toml
│   └── codex.toml
├── .github/workflows/
│   ├── ci.yml
│   ├── release-ios.yml
│   ├── release-android.yml
│   └── release-broker.yml
├── Makefile
├── CONTRIBUTING.md
└── docs/
    ├── ARCHITECTURE.md
    ├── WEBSOCKET-PROTOCOL.md
    ├── AGENT-ADAPTERS.md
    └── INSTALL-{IOS,ANDROID}.md
```

### Architecture diagram

```
┌────────────────────────────────────────────────────────────────┐
│  iOS / Android app                                             │
│                                                                │
│  Top-level: ProjectSwitcher (drawer / nav)                     │
│       │                                                        │
│       └── ActiveProject                                        │
│              │                                                 │
│              ├── View tabs (segmented): Terminal | Chat | Web  │
│              ├── TerminalView   (SwiftTerm / termux-terminal)  │
│              ├── AgentChatView  (structured msg list)          │
│              └── BrowserView    (WKWebView / WebView)          │
└──────────────────────────────┬─────────────────────────────────┘
                               │  UniFFI bindings
                               ▼
              ┌────────────────────────────────────┐
              │  swe-kitty-core (Rust)             │
              │  - WebSocket transport             │
              │  - ProjectSession { id, agent,     │
              │      views: { terminal: PtyState,  │
              │               chat: ChatLog,       │
              │               browser: PreviewURL  │
              │      } }                           │
              │  - Discovery (mDNS / remote URL)   │
              │  - Auth (bearer)                   │
              └────────────────┬───────────────────┘
                               │  WebSocket (binary + JSON)
                               ▼
              ┌────────────────────────────────────┐
              │  swe-kitty-broker (Go)            │
              │  - HTTP+WS on :1977                │
              │  - SessionManager (PTY+worktree)   │
              │  - Docker-spawned agent containers │
              │  - Preview reverse-proxy           │
              │  - mDNS + bearer auth              │
              └────────────────┬───────────────────┘
                               │  docker run
                               ▼
        ┌──────────────────┐  ┌──────────────────┐
        │ claude container │  │ codex container  │  interchangeable
        │ /workspace =     │  │ /workspace =     │  via assistant=
        │  worktree mount  │  │  worktree mount  │
        └──────────────────┘  └──────────────────┘
```

### B1. Harness server (`broker/`)

Slimmed fork of swe-swe's server. Keep:
- WebSocket framing **byte-identical** to swe-swe (`docs/websocket-protocol.md`) so the swe-swe browser UI also works against our server during dev
- Endpoint `GET /ws/{session-uuid}?assistant={claude|codex}` with `Authorization: Bearer <token>`
- Binary prefixes `0x00` resize / `0x01` upload / `0x02` chunked snapshot / raw PTY otherwise
- JSON control: `ping`, `status`, `chat`, `rename_session`, `exit`, `toggle_yolo`
- 30s ping/pong, gzip snapshot on join

Add:
- `switch_agent` JSON control message → server kills container, re-spawns with new adapter, **keeps worktree + scrollback** (Claude can hand off to Codex on the same branch)
- `view_event` JSON messages for the **chat view**: separate stream so the mobile chat tab doesn't have to scrape PTY output (see B5)
- mDNS advertise (`_swe-kitty._tcp.local`) when `--local` flag set; bearer token printed as QR on `swe-kitty-broker up`
- `--public-url https://…` flag for remote mode; runs TLS-terminated behind Caddy

**Session manager** (`internal/session/`):
- Each session = UUID + worktree (`git worktree add .swe-kitty/sessions/<uuid>/work <branch>`) + PTY (`creack/pty`) + Docker container
- Bind mount worktree to `/workspace`, inject env vars (`SESSION_UUID`, `PORT`, `AGENT_CHAT_PORT`, plus `.swe-kitty/env` contents)
- Per-session preview port allocated from `[3000, 3019]`, reverse-proxied at `/preview/<uuid>/*`

### B2. Agent adapter contract (`agents/`)

```toml
# agents/claude.toml
name = "claude"
image = "swekitty/claude:latest"
command = ["claude"]
args = ["--dangerously-skip-permissions"]
env_passthrough = ["ANTHROPIC_API_KEY"]
workdir = "/workspace"
# Optional MCP bridge: agent emits chat events to this port → broker forwards as view_event
chat_event_port_env = "AGENT_CHAT_PORT"
```

```toml
# agents/codex.toml
name = "codex"
image = "swekitty/codex:latest"
command = ["codex"]
args = ["--full-auto"]
env_passthrough = ["OPENAI_API_KEY"]
workdir = "/workspace"
chat_event_port_env = "AGENT_CHAT_PORT"
```

Adding Gemini/Aider/Goose later = one TOML + one Dockerfile, no code changes.

### B3. Rust core (`core/`, `swe-kitty-core`)

UniFFI surface (`swe-kitty-core.udl`):
```
dictionary ProjectSession {
  string id;
  string name;
  string assistant;          // current agent
  string branch;
  PreviewInfo? preview;      // {url, port}
};

interface SweKittyClient {
  constructor(string endpoint, string bearer_token);
  void connect();
  void disconnect();
  [Throws=Error] string create_session(string assistant, string? branch);
  [Throws=Error] void switch_agent(string session_id, string assistant);
  [Throws=Error] void send_input(string session_id, bytes data);      // terminal view input
  [Throws=Error] void send_chat(string session_id, string msg);        // chat view input
  [Throws=Error] void resize(string session_id, u16 rows, u16 cols);
  [Throws=Error] sequence<ProjectSession> list_sessions();
};

callback interface SweKittyDelegate {
  void on_pty_data(string session_id, bytes data);          // terminal view
  void on_chat_event(string session_id, ChatEvent ev);      // chat view
  void on_preview_ready(string session_id, PreviewInfo p);  // browser view
  void on_status(string session_id, SessionStatus s);
  void on_snapshot(string session_id, bytes gzipped);
  void on_exit(string session_id, i32 code);
  void on_disconnected(string reason);
};
```

The Rust layer is the **single source of truth for per-session multi-view state**. iOS and Android pull from the same `ProjectSession` model; they only render.

### B4. iOS app (`apps/ios/`, SwiftUI)

Project generated via `xcodegen` from `project.yml` (litter pattern, keeps `.pbxproj` out of git).

**UI hierarchy:**
```
RootView
├── NavigationSplitView (iPad) / NavigationStack (iPhone)
│   ├── Sidebar/Drawer: ProjectListView         ← top-level: switch projects
│   │      ├── New session (agent picker: Claude/Codex)
│   │      └── List of active ProjectSessions
│   └── Detail: ProjectView(session)            ← one project
│          ├── Header: name, agent badge (tap → switch agent)
│          ├── Picker: [Terminal] [Chat] [Browser]    ← multi-view inside project
│          └── Content:
│              ├── TerminalTab (SwiftTerm bound to on_pty_data / send_input)
│              ├── ChatTab     (List<ChatEvent> + composer → send_chat)
│              └── BrowserTab  (WKWebView at <endpoint>/preview/<uuid>/)
```

Key choices:
- **SwiftTerm** (`migueldeicaza/SwiftTerm`) for terminal rendering — do not write an emulator
- View picker uses `.segmented` Picker style on iPhone, can become a sidebar segment on iPad
- Agent switch is a `Menu` on the agent badge → `switch_agent` RPC
- Auth: QR scan → parses `swekitty://<endpoint>?token=<bearer>` → Keychain
- State: `@Observable` `SessionStore` wraps `SweKittyClient`

### B5. Android app (`apps/android/`, Compose)

```
MainActivity
└── Scaffold
    ├── NavigationDrawer: ProjectList            ← top-level
    └── ProjectScreen(session)
           ├── TopAppBar: name + agent badge
           ├── TabRow: [Terminal] [Chat] [Browser]   ← multi-view inside project
           └── HorizontalPager:
               ├── TerminalPage (termux/terminal-view in AndroidView)
               ├── ChatPage     (LazyColumn<ChatEvent> + composer)
               └── BrowserPage  (WebView in AndroidView)
```

- **termux/terminal-view** (BSD-licensed) for terminal rendering
- CameraX QR scanner for auth → `EncryptedSharedPreferences`
- PiP on the browser tab when app is backgrounded during long-running previews

### B6. Build & bindings

- `core/` produces:
  - `apps/ios/build-rust.sh` → `SweKittyCore.xcframework` (targets `aarch64-apple-ios`, `aarch64-apple-ios-sim`, `x86_64-apple-ios`)
  - `apps/android/build-rust.sh` → JNI libs (`aarch64`, `armv7`, `x86_64`, `i686`)
- `make bindings` regenerates Swift + Kotlin glue from the `.udl` (litter pattern)

---

## Part C — GitHub remote + Actions

### C1. Initial push

```bash
cd /root/developer/projects/kitty-swe
git init -b main
# (after Part A scaffolding is committed)
git remote add origin git@github.com:nikhilsh/swe-kitty.git
git push -u origin main
```

### C2. `.github/workflows/ci.yml` — every PR
- `broker`: `go vet`, `go test ./...`, `golangci-lint`
- `core`: `cargo fmt --check`, `cargo clippy -D warnings`, `cargo test`
- `ios-build`: macOS runner, `make bindings`, build-rust, `xcodebuild -scheme SweKitty -destination 'platform=iOS Simulator,name=iPhone 16' build` (no signing)
- `android-build`: `./gradlew assembleDebug`

### C3. `.github/workflows/release-ios.yml` — on tag `v*`
**Ad-hoc signed IPA → GitHub Release asset.**

Required secrets:
- `IOS_CERTIFICATE_P12_BASE64`, `IOS_CERTIFICATE_PASSWORD`
- `IOS_PROVISIONING_PROFILE_BASE64` (ad-hoc, with registered UDIDs)
- `IOS_KEYCHAIN_PASSWORD`, `IOS_TEAM_ID`

Steps:
1. `macos-14` runner, Xcode 16, Rust toolchain w/ iOS targets
2. Decode P12 + profile, create temp keychain, import cert, install profile
3. `apps/ios/build-rust.sh` → xcframework
4. `xcodebuild archive -scheme SweKitty -archivePath build/SweKitty.xcarchive CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM=$IOS_TEAM_ID`
5. `xcodebuild -exportArchive -exportPath build/ipa -exportOptionsPlist ExportOptions.plist` (method=ad-hoc)
6. `gh release upload $TAG build/ipa/SweKitty.ipa`

Install path documented in `docs/INSTALL-IOS.md`: AltStore / Sideloadly / Apple Configurator. UDIDs must be in the provisioning profile (≤100/year).

### C4. `.github/workflows/release-android.yml` — on tag `v*`
**Signed APK → GitHub Release asset.**

Required secrets:
- `ANDROID_KEYSTORE_BASE64`, `ANDROID_KEYSTORE_PASSWORD`
- `ANDROID_KEY_ALIAS`, `ANDROID_KEY_PASSWORD`

Steps:
1. `ubuntu-24.04`, JDK 17, Android SDK API 35, NDK, Rust w/ Android targets
2. Decode keystore to `apps/android/release.keystore`
3. `apps/android/build-rust.sh` → jniLibs
4. `./gradlew assembleRelease` (signing config reads env)
5. `gh release upload $TAG app/build/outputs/apk/release/app-release.apk`

### C5. `.github/workflows/release-broker.yml` — on tag `v*`
Cross-compile the Go server for `linux/{amd64,arm64}` and `darwin/{amd64,arm64}` + `install.sh`. Attach to the same Release.

---

## Part D' — Memory & inter-agent handoff (HTML)

**Hard v1 requirement:** any agent must be able to leave, and any other agent must be able to pick up exactly where it left off. The medium is a structured HTML document that lives in the repo and inside each session's worktree.

### Two layers of memory

| Scope | Path | Lifetime | Who writes |
|---|---|---|---|
| **Project** | `.swe-kitty/memory/index.html` | Committed to git; permanent | Any agent, any session |
| **Session** | `.swe-kitty/memory/sessions/<uuid>.html` | Tied to a session UUID; gitignored | The agent currently driving the session |

Project memory captures cross-session truth (architecture decisions, conventions, "do not do X"). Session memory captures live state (current task, what I just tried, what's next, open questions, last-known-good state).

### HTML schema (preferred over Markdown because it renders directly in the mobile browser-view tab and supports structured sections + embedded artifacts)

```html
<!doctype html>
<html lang="en" data-swe-kitty-memory="v1">
<head>
  <meta charset="utf-8">
  <title>swe-kitty memory · session <uuid></title>
  <link rel="stylesheet" href="../memory.css">
</head>
<body>
  <header data-section="meta">
    <dl>
      <dt>session</dt><dd><code>...</code></dd>
      <dt>worktree</dt><dd><code>.swe-kitty/sessions/.../work</code></dd>
      <dt>branch</dt><dd><code>agent/claude-002-rust-core</code></dd>
      <dt>current-agent</dt><dd>claude</dd>
      <dt>last-checkpoint</dt><dd><time datetime="...">...</time></dd>
    </dl>
  </header>

  <section data-section="task">
    <h2>Current task</h2>
    <p>...</p>
  </section>

  <section data-section="state">
    <h2>Where I am</h2>
    <p>Last completed: ...</p>
    <p>Currently working on: ...</p>
    <p>Next step: ...</p>
  </section>

  <section data-section="decisions">
    <h2>Decisions made</h2>
    <ol>
      <li data-id="d-001">...</li>
    </ol>
  </section>

  <section data-section="attempts">
    <h2>Things I tried that did not work</h2>
    <ul>...</ul>
  </section>

  <section data-section="open-questions">
    <h2>Open questions for the next agent</h2>
    <ul>...</ul>
  </section>

  <section data-section="env-snapshot">
    <h2>Environment snapshot</h2>
    <pre><code>... last 200 lines of relevant terminal scrollback ...</code></pre>
  </section>

  <section data-section="handoff" hidden>
    <!-- Filled in only when an agent is leaving. Next agent reads this first. -->
    <h2>Handoff brief</h2>
    <p>...</p>
  </section>
</body>
</html>
```

Each `<section>` has a `data-section` attribute so the broker can parse + diff sections without an HTML AST library — a strict subset of HTML5 the broker validates on write.

### Agent adapter integration

Each agent adapter TOML gets two hook commands:

```toml
[hooks]
on_start = "swe-kitty memory render --session $SESSION_UUID > /workspace/.swe-kitty/HANDOFF.html"
on_exit  = "swe-kitty memory checkpoint --session $SESSION_UUID --reason 'exit'"
on_swap  = "swe-kitty memory handoff --session $SESSION_UUID --from $FROM_AGENT --to $TO_AGENT"
```

- `on_start`: broker writes the current session memory into the worktree as `HANDOFF.html`; the agent's startup prompt (handled inside the Docker image's entrypoint) instructs the agent to read it before doing anything else
- `on_exit` / `on_swap`: broker invokes a small CLI (part of `swe-kitty-broker`) that parses the agent's outgoing chat log + last-known scrollback and updates the session HTML

For Claude Code: image entrypoint sets `--system-prompt-file /workspace/HANDOFF.html` (or prepends its contents). For Codex: same pattern via Codex's system-prompt mechanism. Documented in `docs/AGENT-ADAPTERS.md`.

### CLI: `swe-kitty memory`

A subcommand of the broker binary so it works locally without the server:

- `swe-kitty memory init` — scaffolds `.swe-kitty/memory/` with empty templates
- `swe-kitty memory render --session <uuid>` — emits the current HTML
- `swe-kitty memory checkpoint --session <uuid> --reason <str>` — append timestamped checkpoint
- `swe-kitty memory handoff --session <uuid> --from <a> --to <b>` — flush handoff section, mark agent swap
- `swe-kitty memory promote --session <uuid> --decision <id>` — copy a decision from session HTML into the project-level `index.html`
- `swe-kitty memory show` — render to terminal (uses `w3m` or built-in plaintext fallback)

### Mobile surface

The Chat view in the app has a "Memory" affordance (icon top-right) → opens the **same** `.../memory/sessions/<uuid>.html` in the in-app browser. The user can scroll through what the agent currently believes / has tried, and (later) edit a section to correct course. iOS shares this with the Browser tab via WKWebView; Android via WebView. No new rendering layer needed.

---

## Part D'' — Long-running sessions: checkpoints, watchdogs, agent swap continuity

Sessions must survive: agent crashes, container OOM, broker restart, network blips, mid-session agent swaps, and overnight idle. The user phrased it: **"long running sessions with constant checks and ability to switch out agents and not lose where we are"**.

### Three persistence rails

| Rail | What's captured | Where | Cadence |
|---|---|---|---|
| **Scrollback ring buffer** | Last N MB of raw PTY bytes | `.swe-kitty/sessions/<uuid>/scrollback.bin` (mmap) | Continuous |
| **Memory HTML** | Structured agent state (Part D') | `.swe-kitty/memory/sessions/<uuid>.html` | Every 60s + on event |
| **Worktree** | Code changes themselves | git worktree | Every commit (agent-driven) + auto-WIP every 5 min |

A session is **recoverable** iff all three rails are intact on disk. The broker verifies this on every checkpoint.

### Session manager additions (extends Part B1)

```
internal/session/
├── manager.go        (existing)
├── checkpoint.go     ← NEW: periodic + event-driven snapshots
├── watchdog.go       ← NEW: liveness probes + auto-restart policy
├── handoff.go        ← NEW: agent-swap atomicity
└── recovery.go       ← NEW: replay on broker restart
```

**Checkpointer** (`checkpoint.go`):
- Fires on a 60s ticker, on every `switch_agent`, before `exit`, and on `SIGTERM` to the broker
- Atomically:
  1. Pauses PTY drain into a buffer
  2. Writes scrollback ring to disk (rename + fsync)
  3. Triggers `swe-kitty memory checkpoint` for the session
  4. Runs `git add -A && git stash push -m "checkpoint:<ts>"` in the worktree (auto-WIP)
  5. Resumes PTY drain

**Watchdog** (`watchdog.go`):
- Every 30s, sends a no-op probe to the agent container (`docker exec ... echo`) — confirms the container is alive
- Every 30s, parses tail of PTY output for a "stuck" pattern (no bytes in 5 min) — opens an alert via `view_event` so the mobile app surfaces it
- On container death: marks session `stalled`, **does not auto-restart by default**, requires user to tap "Resume" (avoids agents looping forever burning credits). User-configurable in `.swe-kitty/config.toml`:
  ```toml
  [watchdog]
  liveness_probe_interval_sec = 30
  stall_alert_after_sec = 300
  auto_restart_on_crash = false
  ```

**Handoff** (`handoff.go`) — agent swap is atomic:
1. Send agent a `SIGUSR1` (or write to a control file inside the container) — adapter's image is built to interpret this as "begin handoff" and write a final chat message to `/workspace/.swe-kitty/HANDOFF-OUT.html`
2. Wait up to 30s for that file to land; if it doesn't, fall back to last memory checkpoint
3. Stop container
4. Run `swe-kitty memory handoff --from claude --to codex` → reads `HANDOFF-OUT.html`, merges into session HTML, flushes
5. Start new container, mount worktree, `on_start` hook copies `HANDOFF.html` into the workspace, new agent reads it first
6. Notify mobile clients via `status` message: `{phase: "swapped", from: "claude", to: "codex"}`

**Recovery** (`recovery.go`):
- On `swe-kitty-broker up`, scans `.swe-kitty/sessions/*/` for sessions
- For each: re-creates the PTY, replays scrollback from disk, re-attaches the (still-running, since Docker survives broker restart by default) container OR re-spawns it if `--restart unless-stopped` policy lost it
- Clients reconnecting receive the gzip snapshot as usual; from their POV nothing happened

### Constant checks for the user

A "Health" badge in the mobile project header reflects three states:
- 🟢 healthy — container alive, PTY drained recently, last checkpoint < 90s ago
- 🟡 warning — stall pattern detected OR last checkpoint > 90s
- 🔴 dead — container exited; tap to view exit code, last 20 lines, and a "Resume with same agent / Swap agent / End session" sheet

### Failure-mode matrix (must pass before v1)

| Failure | Expected behavior |
|---|---|
| Agent CLI crashes | Session marked dead; scrollback + memory intact; user can Resume (same agent) or Swap |
| Container OOM | Same as above |
| Harness process killed (SIGKILL) | On restart, all sessions recovered from disk; clients reconnect transparently |
| Mid-PR agent swap | New agent has identical context; sees diff-so-far in `HANDOFF.html`; existing git stash auto-restored if requested |
| Phone loses network 1h | Sessions keep running on broker; on reconnect, gzip snapshot brings UI up to date |
| Concurrent edits to memory HTML | File lock + write-rename; broker is single writer per session |
| User force-quits mobile app | No effect on broker; sessions continue; reopen app → resume |

---

## Part D — Implementation order

(Each step ends with a commit pushed to `nikhilsh/swe-kitty`. Steps that can fan out to parallel agent worktrees are tagged ⟂.)

1. **Bootstrap** — `git init`, push to `nikhilsh/swe-kitty`, scaffold `.swe-kitty/` (Part A), write `docs/WEBSOCKET-PROTOCOL.md`, `docs/AGENT-ADAPTERS.md`, **`docs/MEMORY-FORMAT.md`** (HTML schema from Part D'), `docs/SESSION-LIFECYCLE.md` (checkpoints + recovery from Part D''). These four contracts are frozen here so the next four steps can parallelize. Includes `CONTRIBUTING.md`, CI workflow skeleton, `.gitignore`, project-level `.swe-kitty/memory/index.html` seed
2. ⟂ **Harness server core** — `broker/cmd/swe-kitty-broker/main.go` + `internal/session/manager.go` + `internal/ws/server.go`. One hardcoded agent working end-to-end with `wscat`
3. ⟂ **Rust core** — `core/swe-kitty-core.udl`, `transport.rs`, `session.rs`, `views.rs`; `cargo test` with mock WS server
4. **Agent adapters** — `internal/agents/registry.go`, `agents/{claude,codex}.toml`, `broker/docker/{claude,codex}.Dockerfile`, `switch_agent` wired but without handoff yet
5. **Memory + checkpoint subsystem** — `swe-kitty memory` subcommand, `internal/session/{checkpoint,handoff,recovery,watchdog}.go`, HTML schema validator, agent-swap end-to-end with handoff section round-trip. **Cannot defer to v2** per user requirement
6. ⟂ **iOS shell** — xcodegen + project.yml + build-rust.sh + xcframework; `ProjectListView`, `ProjectView` with view picker, terminal tab only
7. ⟂ **Android shell** — Gradle + build-rust.sh + JNI; drawer + project screen with view tabs, terminal page only
8. **Chat view + browser view** on both platforms; `view_event` plumbing; "Memory" affordance in chat header that opens session HTML in the in-app browser
9. **Auth + discovery** — QR flow, mDNS, remote URL path; bearer token persisted in Keychain / EncryptedSharedPreferences
10. **CI green** — all 4 workflows pass on a no-op PR
11. **Release smoke** — `git tag v0.0.1`, verify IPA + APK + broker binaries on the Release; sideload on real device; connect to a `$5` VPS over LTE; run the Part D'' failure-mode matrix on the real hardware

---

## Part E — End-to-end verification

1. **Dev harness sanity**: fresh clone → `npm i -g swe-swe && swe-swe up` reads `.swe-kitty/config.toml`, lets you spawn parallel Claude + Codex sessions on this repo, each on its own worktree
2. **Harness server**: `go run ./cmd/swe-kitty-broker up` → QR + `:1977`. `wscat` to `/ws/$(uuidgen)?assistant=claude` echoes PTY
3. **Agent swap**: `{"type":"switch_agent","assistant":"codex"}` in same session → container replaced, worktree preserved
4. **Core**: `cargo test` against mock WS; `cargo run --example cli-driver` against real broker
5. **iOS sim**: Xcode → iPhone 16, scan QR (dev: paste), spawn Claude session, swipe View picker: Terminal types and echoes → Chat shows agent messages → Browser shows `npm run dev` preview
6. **Android emu**: same flow on Pixel 8
7. **CI**: open a no-op PR → 4 jobs green
8. **Release**: `git tag v0.0.1 && git push --tags` → 3 workflows run → Release has `swe-kitty-broker-{linux,darwin}-{amd64,arm64}`, `SweKitty.ipa`, `SweKitty.apk`
9. **Sideload + remote**: install IPA via AltStore (UDID registered), install APK on Pixel; spin up VPS with Caddy + `swe-kitty-broker up --public-url …`; connect from LTE; verify all three views work over the public internet

---

---

## Part F — Roadmap

Versions are deliberate, not aspirational. Each one ends in a tagged GitHub Release with installable artifacts.

### v0.1 — "hello agent" (≈ 2 weeks of harnessed work)
**Goal:** prove the loop end-to-end on one device.
- Bootstrap + frozen contracts (impl step 1)
- Harness server with one hardcoded Claude agent (steps 2–3)
- Agent adapter system + Codex adapter; `switch_agent` works but no handoff yet (step 4)
- iOS shell with **terminal view only**, manual endpoint+token entry (step 6)
- CI: lint/test/build-sim (step 10 partial)
- **Exit criterion:** type in iOS terminal view → Claude responds; manually swap to Codex via app menu → Codex responds; sessions survive app backgrounding but **not** broker restart

### v0.2 — "I can leave and come back" (≈ 2 weeks)
**Goal:** the long-running-session requirement (Part D'').
- Memory subsystem + HTML schema (step 5)
- Checkpointer, watchdog, recovery (Part D'')
- `switch_agent` round-trips HANDOFF.html so Codex picks up Claude's work intact
- Android shell with terminal view (step 7)
- Memory affordance in mobile chat header
- **Exit criterion:** the Part D'' failure-mode matrix passes; close phone overnight, reopen, agent is still on track

### v0.3 — "multi-view" (≈ 1 week)
**Goal:** the multi-view requirement (Part B).
- Chat view + browser view on both platforms (step 8)
- `view_event` channel separate from PTY stream
- Per-session preview proxy
- **Exit criterion:** start `npm run dev` in terminal tab → see preview in browser tab → see agent's structured progress in chat tab, all from same project

### v0.4 — "off my laptop" (≈ 1 week)
**Goal:** remote + LAN broker production-ready.
- Auth + discovery (step 9): QR + mDNS + remote URL
- Caddy + TLS docs for VPS deployment
- Release pipeline complete: signed IPA + signed APK + cross-compiled broker binaries (step 11)
- **Exit criterion:** sideload IPA via AltStore, install APK on Android, both connect to a $5 VPS over LTE; full Part E verification passes

### v1.0 — "ship it" (polish window)
- Crash-free for 48 hours of continuous use
- Docs for `INSTALL-IOS.md`, `INSTALL-ANDROID.md`, `SELF-HOST.md`
- `swe-kitty memory promote` workflow documented (curating session insights into project-level memory)
- Public README + screencast

### v1.x roadmap (post-v1, prioritized)
1. **Quick replies** (inspired by swe-swe, re-implemented client-side) — a horizontally-scrolling chip rail above the terminal/chat input with one-tap inputs. **Must be contextual**: chips reflect what the agent is currently waiting for, not a static list. Solves the "phone keyboard is hostile to TUI prompts" problem; ships on both iOS and Android.
   - **Why client-side, not agent-side:** swe-swe gets contextual replies by running an MCP bridge so the agent explicitly calls `SendVerbalReply { text, quickReply, moreQuickReplies }` and the server forwards them on the chat event. That requires every agent to integrate the MCP tool. We want to support arbitrary agents (Claude Code, Codex, Gemini, Aider, …) with **zero agent-side cooperation**, so the client parses the agent's visible output and infers expected replies instead.
   - **Client-side detector** (per-agent strategies, lives in `core/` or in the platform layers — TBD): regex/state-machine over the PTY scrollback for common prompt shapes — numbered menus (`^\s*\d+\.\s+`), `(y/n)` / `[y/N]` confirmations, Claude Code tool-use prompts (`1. Yes  2. Yes, don't ask again  3. No`), Codex `[A]pprove / [E]dit / [R]eject`, "Press Enter to continue", `?` help affordances. Each agent adapter ships a small detector module so we can tune to that agent's exact TUI.
   - **No protocol change** — selected chip injects into the existing `send_input` (PTY raw bytes) or `send_chat` (structured) channel.
   - **Fallback rail** for when no prompt is detected: control keys (Enter / Esc / Ctrl-C / Tab / arrows) + a user-pinned list per agent stored in app prefs.
   - **Investigation tasks before building:** (a) record real PTY transcripts from Claude Code and Codex during a representative session and catalogue every distinct "expecting reply" UI shape; (b) decide whether the detector belongs in Rust core (shared logic, harder to iterate) or in each platform's view layer (faster iteration, duplicated code) — leaning Rust core so detectors round-trip through `view_event`.
2. **More agents** — Gemini, Aider, Goose, OpenCode adapters (one TOML + Dockerfile each)
3. **MCP bridge** — agents can call mobile-specific tools (camera, share-sheet) via MCP, surfaced as `view_event`s
4. **Voice input** — Whisper on-device (iOS Speech.framework / Android SpeechRecognizer) → `send_chat`
5. **Pairing / multi-user sessions** — multiple phones drive one project simultaneously (the swe-swe "pair live" feature)
6. **Memory diff UI** — visual diff between memory checkpoints in the mobile browser view; one-tap revert to a prior known-good state
7. **TestFlight + Play Internal** — graduate from sideload to real distribution (deferred from v1 per user choice)
8. **Auto-restart policies** — opt-in supervised loops with credit limits
9. **Cross-session memory linking** — `<a href="../sessions/<uuid>.html">` for context spanning sessions

### Non-goals (explicit, to prevent scope creep)
- Web client (the swe-swe browser UI already works against our server during dev; no need to ship our own)
- Self-hosted multi-tenant SaaS
- In-app billing / paid tiers
- Windows/Linux desktop apps (the broker binary already runs there; the mobile is the product)

---

## Reused from upstream (do not rewrite)

- **swe-swe**: WebSocket framing (byte-identical), `loadEnvFile` (`$VAR` expansion of `.swe-kitty/env`), per-project tabbed multi-view UX model, `--agents` flag semantics
- **litter**: `build-rust.sh` shape, `make bindings` target, xcframework packaging, UniFFI `.udl` → Swift/Kotlin codegen flow, app-store/ad-hoc export-options plist patterns
- **SwiftTerm** (iOS) and **termux/terminal-view** (Android) — terminal rendering; do not write an emulator

## Critical files to create (paths only, in order)

1. `.swe-kitty/config.toml`, `.swe-kitty/env.example`, `.swe-kitty/agents/{claude,codex}.toml`, `.swe-kitty/tasks/*.md`, `.swe-kitty/README.md`, `.swe-kitty/memory/index.html` (project), `.swe-kitty/memory/memory.css`, `.swe-kitty/memory/session-template.html`, `CONTRIBUTING.md`
2. `docs/WEBSOCKET-PROTOCOL.md`, `docs/AGENT-ADAPTERS.md`, `docs/MEMORY-FORMAT.md`, `docs/SESSION-LIFECYCLE.md`, `docs/ARCHITECTURE.md`
3. `broker/cmd/swe-kitty-broker/main.go`, `broker/internal/session/{manager,checkpoint,handoff,recovery,watchdog}.go`, `broker/internal/{ws,agents,auth,memory}/*.go`, `broker/docker/{claude,codex}.Dockerfile`, `agents/{claude,codex}.toml`
4. `core/swe-kitty-core.udl`, `core/src/{lib,transport,session,views,discovery}.rs`, `core/Cargo.toml`
5. `apps/ios/project.yml`, `apps/ios/build-rust.sh`, `apps/ios/Sources/{SessionStore,Views/ProjectListView,Views/ProjectView,Views/TerminalTab,Views/ChatTab,Views/BrowserTab,Views/MemoryButton}.swift`, `apps/ios/ExportOptions.plist`
6. `apps/android/build-rust.sh`, `apps/android/app/build.gradle.kts`, `apps/android/app/src/main/kotlin/sh/nikhil/swekitty/{MainActivity,ProjectListScreen,ProjectScreen,TerminalPage,ChatPage,BrowserPage,MemoryButton}.kt`
7. `.github/workflows/{ci,release-ios,release-android,release-broker}.yml`
8. `docs/INSTALL-{IOS,ANDROID}.md`, `docs/SELF-HOST.md`, `Makefile`, `.gitignore`
