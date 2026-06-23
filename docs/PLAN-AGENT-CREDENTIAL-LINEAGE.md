# PLAN: Agent credential lineage — never fork the refresher

Status: **design only. No production code in this PR.**

This plan fixes a credential-lineage **race** in the broker that logs the box
operator out of their agents (Claude, Codex, …). The broker forks one OAuth
login into N+1 independent on-disk copies (the host login + one per session),
each of which refreshes on its own schedule. Because the providers rotate
refresh tokens **single-use**, whichever copy refreshes first invalidates every
other copy — including the operator's own host login. The fix is structural:
**stop forking the lineage.** Point every session at **one** broker-owned
canonical config directory per provider, via each CLI's own
config-dir-relocation env var (`CLAUDE_CONFIG_DIR` / `CODEX_HOME`), and let the
agent CLI's own cross-process refresh coordination do its job.

This revision (2026-06-23) **replaces the earlier file-symlink design** with
**config-dir relocation**, which is race-free *by construction* regardless of
whether the CLI writes its credential in place or via temp-file+rename. The
symlink approach was fragile to a `write tmp; rename(tmp, .credentials.json)`
that happens *inside the session HOME* — that rename replaces the symlink with a
private regular file and silently re-forks the lineage. We **cannot** empirically
verify the write mode without triggering a real refresh that logs the operator
out, so the design must not depend on it. Config-dir relocation removes that
dependency entirely: the temp+rename now happens *inside the shared canonical
dir* and still targets the one canonical file.

---

## 1. Problem statement (with live evidence)

### 1.1 What the broker does today

For every session the broker spawns an agent in an **ephemeral `$HOME`**
(`<conduitRoot>/sessions/<id>/agent-home`) and **copies** the login credential
into it:

- `broker/internal/session/lifecycle.go` `mirrorHostCredentials()` copies
  `~/.claude/.credentials.json` + `~/.claude.json` (anthropic),
  `~/.codex/auth.json` + `config.toml` (openai), and the opencode files into
  each session HOME.
- `broker/internal/session/manager.go` (`spawn`, ~L458–530) calls it at spawn
  and uses `useHostOverAppBlob` to choose between the host file and the
  app-pushed encrypted blob.
- `broker/internal/session/credfresh.go` is a **watchdog** that re-mirrors
  host→session when a session copy goes stale (`refreshStaleAgentCredentials`,
  called from `watchdog.go:68` and `manager.go:1744`).

So at steady state on a busy box there are **many** live copies of the same
credential lineage: `~/.claude/.credentials.json` (host), the app-pushed
`anthropic.enc` blob, and one `agent-home/.claude/.credentials.json` per live
session.

### 1.2 Why that is a race, not just duplication

OAuth **refresh tokens rotate single-use**: each successful refresh against the
provider's `/oauth/token` endpoint mints a *new* refresh token and invalidates
the *old* one. A credential file is therefore not a value — it is a **position
in a linked list** (a lineage). The moment you copy it, you have two heads of
the same list, and the first one to refresh advances the list and **strands**
the other head with a now-dead refresh token. Its next refresh returns
`401 invalid_grant` and the agent prompts `/login`.

`claude` already solves this **when multiple processes share one config dir**:
its auth supervisor does cross-process refresh coordination (re-reads the file,
detects a peer already refreshed, declines to refresh). Conduit **defeats** that
coordination by handing each session a *private* copy — turning a
coordinated-single-file problem back into an uncoordinated-many-file race.

### 1.3 Live evidence on this box (2026-06-23)

`/root/.claude/daemon.log`, host login supervisor:

```
[2026-06-17T11:39:37.923Z] [supervisor] auth: token still valid (cross-process refresh or not yet due)
...
[2026-06-21T06:50:59.331Z] [supervisor] auth: proactive refresh failed, signalling re-auth required
[2026-06-23T05:00:00.333Z] [supervisor] auth: proactive refresh failed, signalling re-auth required
[2026-06-23T05:01:00.688Z] [supervisor] auth: proactive refresh failed, signalling re-auth required
```

Two fingerprints in one log:

1. `token still valid (cross-process refresh or not yet due)` — proof that
   `claude` **does** coordinate refresh across processes that share one config
   dir (the behaviour conduit defeats by copying).
2. `proactive refresh failed, signalling re-auth required` recurring in bursts —
   the operator's host login being **stranded** because a forked copy already
   consumed the lineage's refresh token. Repeated `scheduling proactive refresh`
   lines appearing in **duplicate at the same millisecond** are two processes
   reading the same on-disk schedule — the fork fingerprint.

The diagnosis in the task ("two live credential copies on the box had DIVERGED
refresh tokens with expiries ~27s apart") is the same phenomenon: two heads of
one lineage, each refreshed independently.

### 1.4 Provider verification (live, non-destructive, this box)

Verified by reading binaries / `--help` / on-disk file shapes / source env-var
support only — **no real token refresh was triggered** against the operator's
live account.

| Provider | Config-dir relocation env | Cred file (under config dir) | Rotates refresh token single-use? | Cross-process refresh lock? | Env-token bypass? |
|----------|---------------------------|------------------------------|-----------------------------------|-----------------------------|-------------------|
| **claude** (anthropic) | **`CLAUDE_CONFIG_DIR`** (relocates the whole `.claude`) | `<dir>/.credentials.json` (`claudeAiOauth{accessToken,refreshToken,expiresAt,scopes,subscriptionType}`) | **Yes** (Anthropic OAuth; live daemon.log shows refresh→re-auth strands) | **Yes** — supervisor re-reads file, logs `token still valid (cross-process refresh or not yet due)` | `CLAUDE_CODE_OAUTH_TOKEN` exists **but is inference-only / non-refreshing** — see §1.5 |
| **codex** (openai) | **`CODEX_HOME`** (already set per-session — `lifecycle.go:127`) | `$CODEX_HOME/auth.json` (`auth_mode:"chatgpt"`, `tokens{id_token,access_token,refresh_token,account_id}`, `last_refresh`) | **Yes** (OpenAI rotates `refresh_token` on `offline_access` exchanges; `last_refresh` is a single-writer timestamp) | **Unverified / assume NO** — binary stripped, no `flock`/`lock` strings found; design must assume codex has no cross-process lock | `codex login --with-access-token` (stdin) takes an **access** token only — **no refresh token → expires in ~1h, never refreshes**. Not usable. |
| **opencode** | env-first; optional `.local/share/opencode/auth.json` (absent on this box — it now uses `opencode.db` SQLite). Provider keys flow via `ANTHROPIC_API_KEY`/`OPENAI_API_KEY`/`OPENCODE_API_KEY` env. | — | N/A for env keys (API keys don't rotate); zen free provider has no creds | N/A | **Env IS the primary path** (`opencode.toml env_passthrough`) |
| **gemini** (google) | `.gemini/gemini-credentials.json` (**encrypted/opaque blob**) + `google_accounts.json` | — | Unknown (opaque); Google OAuth refresh tokens are typically **long-lived/reusable**, not single-use | Unknown | `GEMINI_API_KEY` / `GOOGLE_API_KEY` (`gemini.toml env_passthrough`) |

Key point: the **only two providers that (a) rotate single-use refresh tokens
AND (b) have an app-push / host-OAuth file lineage that conduit forks** are
**claude and codex**. Those are exactly the two the app-pushed credential store
already supports (`credentials.ValidProvider` = `{openai, anthropic}`). opencode
and gemini are **not** in the encrypted store and authenticate primarily via
**env keys that don't rotate**, so they are **not in the race** and are
explicitly out of scope for the relocation mechanism — their env passthrough is
untouched.

### 1.4a Why config-dir relocation is the right primitive (the new facts)

Three verified facts make relocation strictly better than the per-HOME copy or
the per-file symlink:

1. **claude transcripts/projects are keyed by CWD-SLUG**
   (`<config-dir>/projects/-root--<cwd-slug>/`), not by process. The broker
   already reverses this slug
   (`external_discovery.go:claudeSlugToCWD`, "-root-developer-projects-conduit"
   → "/root/developer/projects/conduit"). So a **shared** `CLAUDE_CONFIG_DIR`
   across sessions **still isolates per-session resume** by each session's
   distinct workspace cwd — the `projects/<slug>/` subdirs **do not collide**.
   claude is *designed* for one config dir + many processes + many cwds (the
   host already runs many claude processes off one `~/.claude`); the
   per-session ephemeral HOME was conduit's invention, not claude's requirement.
2. **codex already honors `CODEX_HOME`, and the broker already sets it
   per-session** (`lifecycle.go:127`:
   `pairs["CODEX_HOME"] = filepath.Join(s.agentHomeDir, ".codex")`). codex auth
   lives at `$CODEX_HOME/auth.json`; sessions live at `$CODEX_HOME/sessions/…`.
   Pointing `CODEX_HOME` at a **shared canonical dir** shares `auth.json`
   natively — a one-line change to the value already being injected.
3. `claude` has `CLAUDE_CONFIG_DIR` (relocates the whole `.claude`).
   `apiKeyHelper` / `CLAUDE_CODE_OAUTH_TOKEN` already ruled out (§1.5).

### 1.5 Why `CLAUDE_CODE_OAUTH_TOKEN` is NOT a clean fix for claude

Strings extracted from the live binary (`/root/.local/share/claude/versions/2.1.186`):

```
Use this token by setting: export CLAUDE_CODE_OAUTH_TOKEN=<token>
Warning: CLAUDE_CODE_OAUTH_TOKEN is set in your environment and will override
  this login token at runtime. After logging in, unset that variable...
The OAuth token was supplied via CLAUDE_CODE_OAUTH_TOKEN and cannot be expanded
  with project scopes. Run /login in this session.
Remote Control requires a full-scope login token. Long-lived tokens (from
  `claude setup-token` or CLAUDE_CODE_OAUTH_TOKEN) are limited to inference-only
  for security reasons. Run `claude auth login` to use Remote Control.
This will guide you through long-lived (1-year) auth token setup... (setup-token)
```

So `CLAUDE_CODE_OAUTH_TOKEN` is a `claude setup-token`-style **long-lived
(1-year) inference-only** token, *not* a normal subscription OAuth access token,
and it is explicitly **scope-limited** ("cannot be expanded with project
scopes", "inference-only", "Remote Control requires a full-scope login"). It is
a *different credential type* the user would have to mint separately
(`claude setup-token` requires its own interactive subscription login). It does
NOT correspond to the `claudeAiOauth` access token the app's OAuth flow already
captures, and it **cannot** be used for codex/opencode/gemini. Adopting it would
mean a provider-specific mechanism plus a new login flow plus reduced scope.
**Rejected** for the default path (Simplicity First — one uniform mechanism that
preserves full subscription scope). Kept only as a documented escape hatch (§9).

---

## 1.6 Do we even need a separate root? (the subsuming question)

The operator raised the question that reframes the whole design: **why does a
conduit session create a second `$HOME` at all?** If a session ran with the
operator's **real `$HOME`** (where `~/.claude/.credentials.json` and
`~/.codex/auth.json` already live) and merely `cd`'d into the chosen workspace
folder, then on a logged-in box **the session and the operator are the same
lineage by construction** — the credential fork never happens. This is Option A
(§3.4a) taken to its end: *stop creating a second root*. Before adopting it we
must name, with code/commit evidence, exactly why the ephemeral home exists and
what (if anything) genuinely requires it.

### 1.6.1 Why the ephemeral `agentHomeDir` exists — the ACTUAL reasons (with evidence)

The per-session ephemeral HOME was introduced in **PR #126**
(`bbae5e7a broker-always-isolate-home: per-session HOME copy of broker creds (no
more refresh race)`). Its commit message states the rationale verbatim:

> "Each agent now refreshes its **own private copy** of the OAuth refresh token
> instead of racing concurrent peers on a shared `.credentials.json` — which is
> what triggered the silent 'Please run /login' cascade on hosts running >1
> claude session."

That is the **primary and originating reason**, and it is **circular with the
bug this plan fixes.** PR #126 diagnosed a refresh race and "fixed" it by giving
each agent a *private copy* — but a private copy of a single-use-rotating
lineage is precisely a **second head that strands the operator** (§1.2). The
isolation that #126 introduced to *stop* a race is the *cause* of the race we
see today. The originating reason is therefore not load-bearing; it is the bug.
(The same rationale is restamped in two live code comments that are now wrong:
`manager.go:266` "The per-session HOME is what breaks the concurrent-refresh
race"; the `lifecycle.go` §G.2 HOME-injection comment. Both should be corrected
when the fix lands.)

The OTHER reasons the home grew over time, each verified against current code:

| # | Reason | Evidence | Genuinely needs a separate HOME? |
|---|--------|----------|----------------------------------|
| 1 | **Credential isolation / "no refresh race"** | PR #126 message; `manager.go:266`, `agent_home_test.go` header | **No — circular with the bug.** Sharing the real `~/.claude` is what claude is *designed* for and is the actual fix. |
| 2 | **Resume** (`projects/<slug>/`, `sessions/…` survive Close) | `478c5f4e` ("agent-home survives shutdown, completing the resume chain"); `cleanupAgentHomeCredentials` (`manager.go:1349`) scrubs only the cred file, keeps transcripts | **No — cwd/date-keyed.** Transcripts are keyed by cwd-slug (claude) and date/id (codex); they don't collide in a shared dir and resume works *better* there (§1.4a fact #1). Real `~/.claude` already holds the operator's own resumable transcripts. |
| 3 | **`.claude.json` theme + `hasCompletedOnboarding`** (suppress first-run picker) | `seedClaudeConfig` (`lifecycle.go:357`) writes `$HOME/.claude.json` | **No.** It is a top-level HOME file, identical for every session. The operator's real `~/.claude.json` already has onboarding done. Sharing it is harmless. |
| 4 | **Terminal-tab "always logged in"** mirror loop | `manager.go:521–530` mirrors every *other* provider's host creds into the session HOME so a `claude` run inside a `codex` session isn't logged out | **No — this is the copy bug again.** With the real `$HOME`, the Terminal tab IS the operator's real login for *every* CLI for free; the entire mirror loop deletes. |
| 5 | **opencode per-session state** (`.local/share/opencode`, `.config/opencode`) | `lifecycle.go:258–260` | **No (and out of scope).** opencode authenticates via non-rotating env keys (§1.4); it is not in the race. It can keep a per-session mirror OR use the real dir — either is safe. |
| 6 | **IS_SANDBOX sandbox assertion** | `lifecycle.go:107–115`: the `IS_SANDBOX=1` comment cites "each session gets an ephemeral per-session `$HOME` and a dedicated PTY" as the basis for asserting a constrained sandbox to claude | **Partially — see §1.6.3.** The ephemeral home is invoked as *part of* the sandbox justification. This is the one reason that is not purely the copy bug. |
| 7 | **Workspace-pollution avoidance** (don't drop a creds dir in the repo) | `manager.go:452–456`: the home lives under `sessionDir`, NOT `s.workspaceDir`, to avoid polluting the user's repo / committing secrets | **N/A to this question.** This explains *where* the home lives, not *whether* a separate home is needed. Pointing creds at the operator's real `~/.claude` (outside the repo) satisfies it trivially. |

**Conclusion of the inventory:** of the seven reasons, **six are either the copy
bug itself, or state that is cwd/id-keyed and safe to share, or out of scope.**
Only the IS_SANDBOX assertion (#6) is a distinct, non-bug reason — and it is a
*comment's framing*, not a hard dependency (§1.6.3).

### 1.6.2 The host already proves sharing is safe

Verified live on this box (2026-06-23): **multiple `claude` processes are running
concurrently off the single `/root/.claude`** — `ps` shows several
`/root/.local/share/claude/versions/{2.1.185,2.1.186} --agent claude` processes
plus the `claude daemon` supervisor, all sharing one config dir and one
`daemon.log`. The daemon's cross-process refresh coordination
(`token still valid (cross-process refresh or not yet due)`, §1.3) is exactly the
mechanism that makes this safe. **claude is designed for one config dir + many
processes + many cwds; the per-session ephemeral HOME was conduit's invention,
not claude's requirement.** Codex honours `CODEX_HOME` natively and the broker
already injects it (`lifecycle.go:127`), so pointing it at the real `~/.codex`
is a one-value change. The original OAuth plan even noted "the temp-file-rename
pattern that **both CLIs use**" (`docs/archive/PLAN-AGENT-OAUTH.md §G.3`) —
corroborating §6's rename-proof argument for *both* providers.

### 1.6.3 Blast radius / the sandbox boundary — honest assessment

With the real `$HOME`, a misbehaving or compromised session can read/write the
operator's actual `~/.claude` and everything else under `$HOME`. Is today's
ephemeral home a real boundary worth keeping?

- It is **not a security boundary in any meaningful sense today.** Sessions
  already run as the **broker UID (root on the bare-VPS deploy)** with
  `--dangerously-skip-permissions` + `IS_SANDBOX=1`, and the session's cwd is the
  operator's **real repo** (`s.requestedCWD`), which it can already read/write
  arbitrarily. An agent that wanted the operator's `~/.claude` could already
  `cat ~/.claude/.credentials.json` from its shell — `$HOME` being elsewhere does
  not stop it. The ephemeral home is a **convenience/isolation** boundary, not a
  containment one.
- The **IS_SANDBOX comment's** "each session gets an ephemeral per-session
  `$HOME`" is one clause of its justification, but the operative sandbox
  properties are the **dedicated PTY** and the broker-controlled process tree,
  not the HOME location. `IS_SANDBOX=1` is an *assertion* conduit makes to let
  claude run skip-permissions under root; claude does not inspect HOME to
  validate it. So pointing HOME (or just `CLAUDE_CONFIG_DIR`) at the real config
  dir does **not** weaken the assertion in any way claude checks.
- **Middle ground exists and is strictly better than "full real HOME":** share
  only the **config/creds** via `CLAUDE_CONFIG_DIR` / `CODEX_HOME` pointed at the
  operator's real `~/.claude` / `~/.codex`, while keeping a **per-session HOME**
  for incidental state. This keeps the credential lineage unified (the actual
  fix) without dumping every session into the operator's full home directory for
  unrelated dotfiles. It is **exactly R1 with the canonical dir POINTED AT the
  operator's real config dir** — i.e. Option A — not a different design.

### 1.6.4 Verdict: X (don't fork) and Y (keep R1) are the SAME answer

The question is framed as X-vs-Y but they reconcile into one design:

- **(X) "Don't fork HOME" is correct and subsumes the bug:** the refresh race is
  cured by making the session and the operator one lineage. The originating
  reason for the separate home (#126's "private copy") was the bug; retiring the
  credential fork is the fix.
- **(Y) A separate HOME is NOT load-bearing for creds** — every cred-related
  reason is the copy bug or cwd-keyed-and-shareable. The *only* non-bug reason
  (IS_SANDBOX framing) does not actually depend on HOME location.

**Reconciliation:** we do **not** need to relocate the *entire* HOME to fix the
bug, and we shouldn't — most per-session HOME state (opencode, incidental
dotfiles, the per-session `.claude.json`) is harmless to keep isolated. We need
to unfork **only the credential lineage**, which is precisely **point
`CLAUDE_CONFIG_DIR` / `CODEX_HOME` at the operator's real `~/.claude` / `~/.codex`
config dir** (Option A) on a logged-in box, and at a broker-owned canonical dir
(seeded from the app blob) on a login-less box (Option B). **That is R1.**

So: **"don't fork the root" and "R1 config-dir relocation" are the same family.**
R1 with the canonical dir = the operator's real config dir IS the "don't fork"
answer, while preserving the per-session HOME for everything that is genuinely
incidental. The cleanest correct design is therefore:

> **Per-session HOME stays for incidental state; `CLAUDE_CONFIG_DIR` /
> `CODEX_HOME` point at the operator's real `~/.claude` / `~/.codex` (logged-in
> box, Option A) or a broker-owned canonical dir seeded by app-push (login-less
> box, Option B). The credential lineage is never copied.**

This is strictly simpler than the symlink design and simpler than even the
original copy path: on a logged-in box the broker does **no copy, no symlink, no
canonical-file seeding at all** — it sets two env vars to the operator's real
config dirs and deletes the entire mirror/watchdog apparatus (§7). The
**feature flag (`CONDUIT_SHARED_AGENT_CREDS`) stays** to ship dark and flip on
the dev box after the behavioural live items (§10) pass.

What this changes vs. the prior revision of this doc: the prior text already
chose R1 and described Option A, but treated the broker-owned `agent-creds/`
canonical dir as the *primary* layout (§3.2) and Option A as a recommendation.
**This section promotes Option A (real config dir) to the default whenever a host
login exists**, and demotes the broker-owned `agent-creds/` dir to the
login-less-box fallback (Option B). The implementation map (§11) and deletion
list (§7) already cover the code; §3.4a is the authority for the A/B selection.

---

## 2. The invariant

> **Exactly one refresher per lineage. Never fork the lineage.**

Operationally: for each provider there is **one** canonical config directory.
By default (logged-in box, §1.6.4 Option A) that directory **IS the operator's
real `~/.claude` / `~/.codex`**; on a login-less box (Option B) it is a
broker-owned dir under `conduitRoot`, seeded from the app-pushed blob. Every
session's agent process is pointed at that one directory via the CLI's own
relocation env var (`CLAUDE_CONFIG_DIR` for claude, `CODEX_HOME` for codex), so
the agent CLIs' own cross-process refresh coordination is the *only* thing that
ever advances the lineage. A refresh by any session, or by the
operator's own interactive `claude`/`codex`, mutates the **same bytes** everyone
else reads. **There is no second head to strand, and no write mode can create
one**: a temp-file+rename writes the temp file *into the shared canonical dir*
and renames over the *one* canonical credential file there — exactly the update
the CLI's coordination expects.

Corollary invariants the design must also hold:
- **App-push on a login-less box keeps working** (hard requirement — the
  SSH-bootstrap per-box credential model depends on it). The canonical dir is
  seeded from *either* the host login *or* the app-pushed blob, whichever
  exists.
- **A still-valid app blob for a deliberately-different account still wins**
  (the phone may be signed into a different account than the box on purpose).
- **The encrypted at-rest store survives** (it persists app-pushed blobs across
  broker restarts and re-seeds the canonical credential file).
- **Per-session resume still works**: `projects/<cwd-slug>/` (claude) and
  `sessions/YYYY/MM/DD/` (codex) live *inside* the shared dir but are
  cwd/date-keyed, so sessions don't trample each other's transcripts.

---

## 3. Chosen mechanism: config-dir relocation to a shared canonical dir (R1)

### 3.1 Decision per provider

The canonical dir is selected per §1.6.4 / §3.4a: **Option A (default when a host
login exists) = the operator's real `~/.claude` / `~/.codex`** — zero copy, the
operator IS the lineage; **Option B (login-less box) = a broker-owned dir under
`conduitRoot`**, seeded from the app-pushed blob. The env-injection mechanism is
identical either way — only the *target path* differs.

| Provider | Mechanism | Env injected (lifecycle.go `commandEnv`) | Why rename-proof |
|----------|-----------|------------------------------------------|------------------|
| **claude** | **R1 — relocate `CLAUDE_CONFIG_DIR`** to the canonical dir | `CLAUDE_CONFIG_DIR=$HOME/.claude` (Option A) **or** `<conduitRoot>/agent-creds/anthropic` (Option B) | A temp+rename happens *inside the shared dir* and still targets the one `.credentials.json` there; leverages claude's proven cross-process refresh coordination (§1.3). |
| **codex** | **R1 — relocate `CODEX_HOME`** to the canonical dir | `CODEX_HOME=$HOME/.codex` (Option A) **or** `<conduitRoot>/agent-creds/openai` (Option B) — replaces the current per-session `<home>/.codex` | Same: rename targets the one `$CODEX_HOME/auth.json`; even with *no* cross-process lock the loser re-reads the winner's fresh `auth.json` because it is the same file. |
| **opencode / gemini** | **not in the race** — env-key / reusable-token providers. **No relocation.** | unchanged | No single-use rotation; nothing to fork. |

R2 (per-file symlink) is **demoted to a rejected alternative** (§3.5): it cannot
be argued rename-safe without a live probe we cannot run. R3 (symlink +
self-healing absorb watchdog) is **rejected** — it resurrects the very watchdog
this plan deletes, to tolerate a hazard R1 makes impossible. **R1 is
robust-by-construction AND simplest** (it is mostly a change to one env value the
broker already injects), so it wins on both axes.

### 3.2 Layout

```
<conduitRoot>/
  credentials/                          # (existing encrypted store dir, unchanged)
    <identity-sha256>/anthropic.enc      # app-pushed blob, encrypted at rest
    <identity-sha256>/openai.enc
    .keyfile
  agent-creds/                          # NEW: broker-owned CANONICAL config dirs
    anthropic/                           # == CLAUDE_CONFIG_DIR for every session
      .credentials.json                  #   the single lineage head for claude
      projects/<cwd-slug>/<id>.jsonl     #   resume transcripts, cwd-keyed (no collision)
      (claude's own settings/history land here too — see §3.3)
    openai/                              # == CODEX_HOME for every session
      auth.json                          #   the single lineage head for codex
      config.toml                        #   shared codex config
      sessions/YYYY/MM/DD/<rollout>.jsonl #  resume rollouts, date/id-keyed (no collision)
  sessions/<id>/agent-home/             # still per-session HOME (theme/onboarding, MCP, opencode)
    .claude.json                         # per-session real file (theme/onboarding) — stays here
```

The canonical credential files live **plaintext** (mode `0600`, dir `0700`,
broker UID) — they have to, because the agent CLI reads/writes them directly.
This is **no weaker** than today: `~/.claude/.credentials.json` and every
`agent-home/.../credentials.json` copy are already plaintext `0600` on the same
UID. The encrypted `.enc` store keeps its role (at-rest protection of the
app-pushed blob against a raw-disk/backup reader who lacks `.keyfile`).

### 3.3 What the shared config dir now shares — and the reconciliation

Relocation shares **more than just the credential file**. We must account for
everything that moves into the shared dir and confirm nothing conduit relies on
in the per-session HOME breaks.

**claude (`CLAUDE_CONFIG_DIR`):**

| State | Lives in shared `CLAUDE_CONFIG_DIR`? | Collision risk? | Verdict |
|-------|--------------------------------------|-----------------|---------|
| `.credentials.json` | **yes** (the whole point) | none — single shared lineage | desired |
| `projects/<cwd-slug>/*.jsonl` (resume transcripts) | **yes** | **none** — keyed by cwd-slug (fact #1); each session has a distinct workspace cwd | safe; `stageExternalTranscript` must write here, see §3.6 |
| settings / `history` / `statsig` | **yes** | benign — shared settings is *fine* (it's the operator's box-wide claude config; the host already shares it across all the operator's claude runs) | acceptable |
| `.claude.json` (theme + `hasCompletedOnboarding`) | **stays at `$HOME/.claude.json`** — it is a top-level HOME file, NOT inside `.claude/`, so `CLAUDE_CONFIG_DIR` does **not** relocate it | per-session, unchanged | `seedClaudeConfig` keeps writing the per-session HOME exactly as today |

> Note (single live-verify item): on some claude builds `CLAUDE_CONFIG_DIR` also
> absorbs what was `~/.claude.json` as `<dir>/.claude.json`. If so, the shared
> theme/onboarding is *still* correct (identical for every session) — sharing it
> is harmless. Either way `seedClaudeConfig` must seed **the directory claude
> actually reads**: keep seeding `$HOME/.claude.json` AND, when the flag is on,
> also seed `<CLAUDE_CONFIG_DIR>/.claude.json` idempotently. This is cheap and
> covers both builds. Flagged in §10.

**codex (`CODEX_HOME`):**

| State | Lives in shared `CODEX_HOME`? | Collision risk? | Verdict |
|-------|-------------------------------|-----------------|---------|
| `auth.json` | **yes** (the point) | none — single shared lineage | desired |
| `config.toml` | **yes** | benign — same box-wide codex config for every session (today it's copied identically into each HOME anyway) | acceptable |
| `sessions/YYYY/MM/DD/<rollout>.jsonl` | **yes** | **none** — each rollout is a unique date/id-named file; sessions never write the same path | safe; `stageCodexTranscript` must write here, see §3.6 |

**What STAYS per-session HOME (NOT relocated):** the agent-home directory itself
remains per-session and remains `HOME`. It still holds `.claude.json`
(theme/onboarding), any MCP config seeded per session, and the **opencode**
state (`.local/share/opencode`, `.config/opencode`) — opencode is not relocated
and keeps its per-session mirror exactly as today. Only the **claude `.claude`**
and **codex `.codex`** subtrees are pulled out to the shared canonical dir via
the env vars. This is the "split out only the config/creds, keep per-session
HOME for everything else" option the task asked us to assess — and it is exactly
what the two env vars give us for free.

**Persistence note:** the agent-home is already *preserved* on session close
(`manager.go:1330` comment: `.claude/projects` and `.codex/sessions` are kept so
`--resume` works). Under R1 those resumable files live in the **shared** dir
instead, which is *strictly better* for persistence — they survive even the
per-session GC sweep, and any session in the same cwd can resume them. The
shared dir is broker-owned and lives under `conduitRoot`, so it persists across
broker restarts exactly like the rest of `conduitRoot`.

### 3.4 Seeding the canonical credential file (the app-push-on-login-less-box requirement)

At broker startup and at session spawn, the canonical credential file for a
provider is **ensured** from exactly one source, in this precedence (this is the
new home for the `useHostOverAppBlob` decision — made **once per provider**, not
once per session):

1. **Valid app-pushed blob present** → decrypt `<provider>.enc` and write it to
   the canonical file (`agent-creds/anthropic/.credentials.json`, resp.
   `agent-creds/openai/auth.json`). A *valid* (non-expired) blob always wins
   over the host login — it may be a deliberately different account. **This is
   the login-less SSH-bootstrap path**: there is no host
   `~/.claude/.credentials.json`, the phone pushed the only credential, and it
   lands in the canonical dir that every session points at via the env var.
   App-push keeps working exactly as before; only the *destination* changes from
   "each session's private copy" to "the one shared canonical file."
2. **No valid app blob, host login present** → seed the canonical file from
   `~/.claude/.credentials.json` (resp. `~/.codex/auth.json`). See §3.4a on
   coupling the operator's host lineage.
3. **Expired app blob + fresher host login** → seed from the host
   (`useHostOverAppBlob` semantics, preserved).
4. **Neither** → no canonical file; the agent prompts `/login` (clean error, no
   race), exactly as today. (The env var still points at the dir; it's just
   empty until a login lands.)

Account-switch (phone pushes a different account via `set_agent_credentials` /
`Store.Set`) overwrites the **canonical credential file** atomically → all
sessions and fetchers see the new account at their next read. In-flight agent
processes that hold the old token in memory keep running until their next file
read (the CLIs re-read on refresh), which is the desired "next turn picks up the
new account" semantics.

### 3.4a Host coupling: share the lineage with the operator (the actual fix)

The race that logs the *operator* out only ends if the operator's interactive
`claude`/`codex` and the broker sessions are the **same lineage**. With R1 there
are two ways to achieve that, gated behind the feature flag (§8):

- **Option A — canonical dir IS the host config dir (default when a host login
  exists).** Set `CLAUDE_CONFIG_DIR=$HOME/.claude` and
  `CODEX_HOME=$HOME/.codex` for every session — i.e. point sessions at the
  operator's real config dir. The operator's interactive `claude` (which uses
  `~/.claude` by default) and every session now share one dir; the CLI's
  cross-process coordination (proven live, §1.3) governs all refreshes. This is
  **zero-copy and race-free-by-construction** on a logged-in box — and is the
  *minimal* change: the broker stops copying and just lets sessions read the
  host dir directly, which is what claude is designed for. (Codex already had
  `CODEX_HOME` pointed at a per-session dir; Option A points it at `$HOME/.codex`
  instead.)
- **Option B — canonical dir under `<conduitRoot>/agent-creds`** (login-less
  box). When there is no host login, the canonical dir is broker-owned and
  seeded from the app blob (§3.4 step 1). The operator isn't running claude
  interactively on a login-less box, so there's no host lineage to couple. If
  the operator *later* logs in interactively and we want that to feed the same
  lineage, the broker can set `CLAUDE_CONFIG_DIR` in the operator's *shell
  profile* to the canonical dir — but that mutates the operator's environment
  and is **opt-in / deferred** (off by default).

**Recommendation:** **Option A when a host login exists** (point sessions at
`$HOME/.claude` / `$HOME/.codex` — zero copy, the operator IS the lineage);
**Option B's broker-owned canonical dir when no host login exists** (login-less
SSH box, seeded from the app blob). The shell-profile half of Option B is
deferred behind an explicit flag — it is the only part that touches the
operator's environment. Note Option A is even *simpler* than the symlink design:
on a logged-in box the broker does **no copy and no symlink at all** — it just
sets `CLAUDE_CONFIG_DIR=$HOME/.claude` and removes the per-session `.codex`
override in favour of `CODEX_HOME=$HOME/.codex`.

### 3.5 Rejected alternatives

- **R2 — per-file symlink** (the previous revision's design): session HOME's
  `.claude/.credentials.json` is a symlink to a canonical file. **Rejected as
  default.** Fragile to `write tmp; rename(tmp, .credentials.json)` *inside the
  session HOME*: the rename replaces the symlink with a private regular file →
  the lineage re-forks → the bug returns. We cannot verify the CLI's write mode
  without a destructive live refresh. R1 removes this dependency. (R2 is retained
  only as a theoretical fallback if a future CLI is found to *ignore* its
  relocation env var — none does today.)
- **R3 — symlink + self-healing absorb** (broker detects the cred path became a
  real file, folds the fresher token back, restores the symlink). **Rejected.**
  It tolerates the rename hazard by **resurrecting a watchdog** — the exact
  component this plan deletes (§7). Adds a polling loop and a token-merge
  heuristic to handle a case R1 makes structurally impossible. Violates
  Simplicity First.
- **`CLAUDE_CODE_OAUTH_TOKEN` env injection** (claude only): reduced-scope,
  separate login, single-provider. §1.5. Escape hatch only (§9).

### 3.6 Resume staging under the shared dir

`stageExternalTranscript` (`stage_transcript.go`) copies an external session's
transcript into the agent's config tree so `--resume` / `exec resume` finds it.
Today it writes `<agentHome>/.claude/projects/<slug>/<id>.jsonl` and
`<agentHome>/.codex/sessions/…`. Under R1 the agent reads `projects` /
`sessions` from the **shared canonical dir**, so staging must target:

- claude: `<CLAUDE_CONFIG_DIR>/projects/<slug>/<id>.jsonl`
- codex: `<CODEX_HOME>/sessions/<rel>`

Both are cwd/date/id-keyed, so writing into the shared dir does **not** collide
with other sessions' transcripts. Under **Option A** (canonical dir == host
dir), staging becomes a near-no-op for host-originated sessions: the transcript
is *already* in `$HOME/.claude/projects/<slug>/` — no copy needed. The staging
function takes the destination config-dir as a parameter instead of hardcoding
`agentHome/.claude`.

---

## 4. Concurrency analysis (honest, per provider)

The shared-dir question: host + 2 sessions all read one config dir and two try
to refresh near-simultaneously. What happens?

### 4.1 claude (anthropic) — **safe; the CLI coordinates**

Live-proven (§1.3): the claude auth supervisor performs **cross-process refresh
coordination** — before refreshing it re-reads the file, and if a peer already
refreshed (`token still valid (cross-process refresh or not yet due)`) it
declines. Worst case if two processes still race the window: both attempt a
refresh; one wins (advances the lineage, writes via temp+rename **into the
shared dir**), the other's refresh returns `invalid_grant`, the loser **re-reads
the now-fresh shared file** and recovers on the next inference call. Recoverable
**because they share the dir** — the loser reads the winner's fresh token. This
is exactly the property conduit destroys today by giving each a private copy.
**The temp+rename hazard that doomed R2 is moot here**: the rename happens inside
the shared dir and targets the one canonical `.credentials.json`, which is
precisely how claude's own coordination expects the file to be updated.

### 4.2 codex (openai) — **assume no lock; recoverable, no fork**

We could not confirm a cross-process lock in the codex binary (stripped). Treat
codex as **no cross-process coordination**. Worst case: two sessions refresh in
the same window; both POST the rotating `refresh_token`; the provider honors the
first and `invalid_grant`s the second; the second's in-memory token is now dead
**but** the first wrote a fresh `auth.json` (temp+rename into `$CODEX_HOME`), so
the second's **next file read** (codex re-reads `auth.json` on its refresh path)
recovers. The recovery hinges on the file being **shared** — which `CODEX_HOME`
relocation guarantees, *independent of write mode* (the rename targets the one
shared `auth.json`). Strictly better than today: today the loser's *private copy*
is permanently dead and the operator's host login is a third racer.
Residual risk: a refresh storm (many codex sessions all expiring at once) could
cause repeated `invalid_grant`→re-read churn for a few seconds. Acceptable and
self-healing; flagged for live verification (§10). If it proves noisy, a small
broker-held **per-provider advisory `flock`** around the canonical `auth.json` is
a follow-up — but we do **not** ship it speculatively.

### 4.3 opencode / gemini — **not in the race**

opencode authenticates via non-rotating env API keys (primary path) or the zen
free provider; gemini via `GEMINI_API_KEY` env or a Google OAuth blob whose
refresh tokens are conventionally reusable (not single-use). Neither has the
fork-strands-the-operator failure mode. They are **not relocated** — their env
passthrough / per-session opencode mirror is untouched. No special handling.

---

## 5. Security notes

- **File perms/ownership:** canonical files `0600`, `agent-creds/<provider>/`
  dirs `0700`, all broker UID — identical posture to today's per-session copies
  and the host file. No new at-rest exposure.
- **No symlinks, no symlink-target attack surface.** R1 sets an env var to a
  **broker-owned absolute path** under `conduitRoot` (Option B) or the operator's
  own `$HOME/.claude` / `$HOME/.codex` (Option A). The agent runs as the broker
  UID, so reading/writing that dir crosses no privilege boundary. (This is a
  security *simplification* vs. the symlink design, which needed an `Lstat`
  guard against a pre-planted malicious dotfile target.)
- **Encrypted store unchanged:** `broker/internal/credentials/store.go` keeps
  AES-256-GCM + keyfile. Its role is now precisely: (a) persist the app-pushed
  blob across broker restarts, (b) re-seed the canonical credential file on
  startup / account-switch. The `.enc` blob remains the only at-rest-encrypted
  copy; the canonical plaintext file is the live working copy (as the host file
  already is).
- **No token ever crosses a new wire.** Unchanged from today.

---

## 6. Why the atomic-write / temp+rename hazard is MOOT under R1

The previous revision flagged this as the single highest-priority live-verify
item: a CLI that writes its credential via `write tmp; rename(tmp,
.credentials.json)` *inside its `$HOME/.claude/`* would **replace the symlink
with a private regular file**, re-forking the lineage. That hazard was the only
reason the previous design was "design + live-verify" rather than shippable.

**Config-dir relocation removes the hazard by construction, regardless of write
mode:**

- If the CLI writes **in place** (`open(.credentials.json); write`): it writes
  the one canonical file in the shared dir. Shared. Good.
- If the CLI writes via **temp+rename**: it creates `tmpXXXX` *in the shared
  config dir* (CLIs rename within the same directory as the target, for
  atomicity across the same filesystem) and renames it over
  `<shared-dir>/.credentials.json`. The rename replaces the **one canonical
  inode** that every session reads through the same env-var path. There is **no
  per-session file to replace** — every session resolves the credential through
  `CLAUDE_CONFIG_DIR` / `CODEX_HOME`, not through a per-HOME symlink. Shared.
  Good.

In both cases the result is the same single canonical file, so **no write mode
can fork the lineage**. The §6 "live-verify the rename hazard" risk from the
prior revision is therefore **deleted**, not merely flagged. The only residual
live items (§10) are behavioural confirmations of the *fix* (operator stops
getting logged out) and of codex's no-lock worst case — not of correctness of
the mechanism.

---

## 7. What gets DELETED / shrunk

**On a logged-in box (Option A, the default), the credential side of agent-home
spawn collapses to almost nothing:** the broker sets
`CLAUDE_CONFIG_DIR=$HOME/.claude` / `CODEX_HOME=$HOME/.codex` and does **no
credential copy, no symlink, and no canonical-file seeding** — the session reads
the operator's real config dir directly. The per-session HOME *itself* is
retained for incidental state (opencode, `.claude.json`, the PTY/sandbox), but
its entire claude/codex **credential** apparatus is removed. Two now-false code
comments must be corrected as part of the change: `manager.go:266` ("The
per-session HOME is what breaks the concurrent-refresh race" — it CAUSES it) and
the `lifecycle.go` §G.2 HOME-injection comment.

Under R1 the watchdog credential branch **fully dies** for both providers:

- **`broker/internal/session/credfresh.go` — the watchdog re-mirror is
  DELETED.** `refreshStaleAgentCredentials` exists solely to heal a forked copy
  that went stale. With one shared canonical dir there is no copy to go stale,
  so the watchdog tick (`watchdog.go:68`) and the spawn-time re-materialize
  (`manager.go:1744` via `RefreshAllSessionCredentials`) lose their cred branch.
  Retain only the small `credentialExpiryMillis` / `jwtExpiryMillis` /
  `useHostOverAppBlob` helpers — they move to the **seed-precedence** decision
  (§3.4) where the *blob-vs-host freshness* comparison still happens **once per
  provider**, not per session.
- **`mirrorHostCredentials` (lifecycle.go) — DELETED for claude/codex**, replaced
  by `ensureCanonicalCred(provider)` (seed the canonical file) +
  pointing the env var at the canonical dir in `commandEnv`. opencode keeps a
  (renamed) per-session mirror since it is not relocated. The per-session *copy*
  of claude/codex creds is gone. The "mirror every provider into every session
  HOME so the Terminal tab is logged in" loop (`manager.go:521–530`) becomes
  "point `CLAUDE_CONFIG_DIR`/`CODEX_HOME` at the canonical dirs (which the
  Terminal tab inherits via the session env) + mirror opencode only."
- **`RefreshAllSessionCredentials` (manager.go:~1731) + its call sites — the
  cred-re-materialize body is DELETED**; `Store.Set` instead re-seeds the **one**
  canonical file (account-switch), which every session sees on next read. The
  method can be removed or reduced to a no-op shim if external callers remain.
- **`cleanupAgentHomeCredentials` (manager.go:~1349) — claude/codex entries
  removed.** There is no per-session cred file to clean up; the canonical file
  is broker-owned and persists. (opencode entry, if any, stays.)
- **`watchdog.go:68` — the `refreshStaleAgentCredentials()` call is removed.**
- **`useHostOverAppBlob` / `credentialExpiryMillis` / `jwtExpiryMillis` — kept
  but relocated** to the once-per-provider seed path (`credseed.go`); their
  per-session call sites are removed.
- **The broker-side fetchers (`accountusage.go`, `aigen.go`,
  `codexaccountusage.go`) — read the canonical dir.** They currently read
  `<agentHomeDir>/.claude/.credentials.json`. Under R1 the freshest token is in
  the canonical dir, so they must read the canonical path (or
  `selectAIGenProvider` must be passed the canonical dir instead of
  `agentHomeDir`). This is a small, mechanical redirect — and it is strictly
  *better* (they can no longer read a stale per-session copy).

Net: `credfresh.go` shrinks to expiry helpers (moved to `credseed.go`, file may
be deleted), the per-session copy + the entire watchdog cred tick + the
re-materialize fan-out are gone, and the spawn cred branch collapses to "seed the
canonical file once + set the env var."

---

## 8. Rollout / migration

- **Feature flag:** `CONDUIT_SHARED_AGENT_CREDS` (broker env / flag), default
  **off** for one release. Off → today's per-session copy + watchdog path
  verbatim. On → canonical-dir relocation path. This lets us ship the code dark,
  flip it on the dev box, and confirm the *behavioural* live items (§10) before
  defaulting on. (The §6 mechanism is correct by construction; the flag exists to
  de-risk the rollout, not to verify the rename hazard, which is now moot.)
- **Existing running sessions:** untouched. The flag only changes how *new*
  sessions are spawned. A redeploy doesn't migrate live agent-homes; they keep
  their private copies until they exit. (Broker redeploy is a hard gate per
  `CLAUDE.md` since `broker/` changes.)
- **No-downtime:** the canonical file is ensured idempotently at startup and at
  each spawn; a half-written canonical file can never be observed (atomic
  rename). If seeding fails, fall back to the legacy copy path for that spawn
  (fail-safe: a session never refuses to start over a cred-seed hiccup).
- **Account-switch / sign-out:** `Store.Set` re-seeds the canonical credential
  file; `Store.Delete` removes it (and `.enc`) for that provider — the next
  session prompts `/login`. Host login files are never touched by Delete
  (existing `Store.Delete` contract preserved).

---

## 9. Escape hatch (documented, not default)

`CLAUDE_CODE_OAUTH_TOKEN` (claude only): for a CI-style box where the operator
*wants* a long-lived inference-only token and never runs interactive `claude`,
the broker may inject it via env and skip the canonical file entirely (store
nothing refreshable → no lineage to fork). This is a **provider-specific,
reduced-scope** path (§1.5) and is explicitly **not** the default. Surfaced here
so we don't reinvent it later; gated behind its own env opt-in if ever wired.

---

## 10. Test plan

### Unit (broker, locally runnable: `gofmt -l . && go vet ./... && go test ./...`)

`broker/internal/session`:
- `ensureCanonicalCred`: seeds from valid app blob (login-less box) → canonical
  file equals decrypted blob. Seeds from host when no blob. Expired-blob +
  fresher-host → host wins (preserves `useHostOverAppBlob` table tests, moved).
  Neither source → no canonical file, no error.
- `commandEnv` (flag on): a claude session gets `CLAUDE_CONFIG_DIR=<canonical
  anthropic dir>`; a codex session gets `CODEX_HOME=<canonical openai dir>`
  (not the per-session `.codex`). Flag off → today's env verbatim.
- Multi-session: spawn 3 sessions for the same provider → assert all 3 resolve
  the canonical dir to the **same** path (the structural proof the lineage is not
  forked) and that 3 sessions in **distinct cwds** get distinct
  `projects/<slug>/` subdirs (no transcript collision) while sharing one
  `.credentials.json`.
- `stageExternalTranscript`: writes into `<canonicalDir>/projects/<slug>/` (resp.
  `<canonicalDir>/sessions/<rel>`), not the per-session HOME; idempotent; Option
  A (canonical == host) is a no-op when the transcript already exists there.
- `seedClaudeConfig`: still seeds `$HOME/.claude.json`; with flag on also seeds
  `<CLAUDE_CONFIG_DIR>/.claude.json` idempotently (covers both claude builds).
- Deletion of the watchdog branch: `credfresh_test.go` cases that asserted
  re-mirror behaviour are removed/replaced with "no per-session copy exists; the
  canonical file is the only file."

`broker/internal/credentials`:
- `Set`/`Get`/`Materialize` unchanged; add a `MaterializeCanonical(provider,
  canonicalDir)` (or equivalent) test that the plaintext lands `0600` at the
  canonical path (`<dir>/.credentials.json` for anthropic, `<dir>/auth.json` for
  openai).

### Live / device-only (cannot be unit-tested — flag as needs-live-verify)

1. **The operator-logout fix (the actual bug):** with the flag on, run several
   broker sessions + interactive `claude`/`codex` on the box concurrently for a
   refresh cycle; confirm `daemon.log` no longer logs `proactive refresh failed,
   signalling re-auth required` and **the operator stays logged in**. This is the
   single most important behavioural verification.
2. **Login-less SSH box:** fresh box, no host login, phone pushes the blob →
   canonical file seeded from the blob → session runs on the pushed account.
   **App-push still works** (hard requirement); account-switch re-seeds and the
   next turn picks up the new account.
3. **Resume still works under the shared dir:** start a claude and a codex
   session in two distinct cwds, confirm `--resume` / `exec resume` finds the
   correct per-cwd transcript from the shared `projects/`/`sessions/` tree and
   the two don't cross-contaminate.
4. **codex refresh storm:** many codex sessions expiring together → confirm
   self-healing within seconds, no permanent logout (validates §4.2's honest
   worst case for the no-lock provider).
5. **`.claude.json` location confirmation (low-risk):** confirm which dir the
   live claude build reads theme/onboarding from under `CLAUDE_CONFIG_DIR`; the
   seed-both approach (§3.3 note) is correct either way, so this only tidies a
   redundant write.

**The §6 temp+rename hazard is NOT a live item — it is moot under R1** (the
rename targets the one canonical file in the shared dir; no per-session file
exists to fork). This is the key change from the prior revision.

### Definition of done for the implementing PR(s)

- Local broker gates green; **broker redeployed** (the cred path is live code).
- Flag defaults off; live items 1–4 verified on the dev box before defaulting
  the flag on in a follow-up.

---

## 11. File-by-file implementation map (for the implementing PR)

| File | Change |
|------|--------|
| `broker/internal/session/lifecycle.go` | In `commandEnv` (the HOME/`CODEX_HOME` injection block, ~L124–129): when `CONDUIT_SHARED_AGENT_CREDS` is on, set `CLAUDE_CONFIG_DIR=<canonicalDir(anthropic)>` for claude sessions and `CODEX_HOME=<canonicalDir(openai)>` (replacing the per-session `<home>/.codex`). Delete `mirrorHostCredentials` for claude/codex (keep an opencode-only mirror). Keep `seedClaudeConfig` (also seed the canonical `.claude.json` when flagged). |
| `broker/internal/session/credseed.go` (new) | `canonicalCredDir(provider)` does the **Option A vs B selection: return the operator's real `$HOME/.claude` / `$HOME/.codex` when a host login exists (Option A — and then `ensureCanonicalCred` is a NO-OP, no seeding), else a broker-owned `agent-creds/<provider>` dir (Option B)**. `ensureCanonicalCred(provider)` seeds ONLY the Option-B dir (precedence §3.4) + relocated `useHostOverAppBlob` / `credentialExpiryMillis` / `jwtExpiryMillis`. |
| `broker/internal/session/credfresh.go` | **Delete** `refreshStaleAgentCredentials` + `sessionCredentialFile`. Move retained expiry helpers to `credseed.go`. File may be removed entirely. |
| `broker/internal/session/watchdog.go` | Remove the `refreshStaleAgentCredentials()` call (L68). |
| `broker/internal/session/manager.go` | Spawn path (~L458–530): once-per-provider `ensureCanonicalCred`; drop the per-session copy, the `allProviders` claude/codex mirror loop, and the per-session Materialize. Remove the claude/codex branches from `cleanupAgentHomeCredentials` (~L1349). Gut/remove `RefreshAllSessionCredentials` (~L1731). Gate everything on `CONDUIT_SHARED_AGENT_CREDS`. |
| `broker/internal/session/stage_transcript.go` | `stageExternalTranscript` takes the destination config dir as a parameter (the canonical dir under R1) instead of hardcoding `agentHome/.claude` / `agentHome/.codex`. |
| `broker/internal/session/{accountusage,aigen,codexaccountusage}.go` | Read the canonical cred dir (or have `selectAIGenProvider` receive the canonical dir) instead of `agentHomeDir`, when the flag is on. |
| `broker/internal/credentials/store.go` | Add `MaterializeCanonical(provider, canonicalDir)` (writes `.credentials.json` / `auth.json` at the canonical path) and a `Set` hook to re-seed the canonical file on account-switch. Encrypted store otherwise unchanged. |
| `broker/cmd/conduit-broker/main.go` | Read `CONDUIT_SHARED_AGENT_CREDS`. **Option-B only**: ensure `agent-creds/<provider>/` dirs at startup + seed canonical files for stored providers on boot. On a logged-in box (Option A) there is nothing to create or seed — sessions point at the real `~/.claude` / `~/.codex`. |
| tests | `credseed_test.go` (new), update `credfresh_test.go`, add the multi-session same-canonical-dir + distinct-cwd-slug assertions. |

---

## 12. References (verbatim code paths)

- `broker/internal/session/lifecycle.go` — `commandEnv` (HOME/`CODEX_HOME`
  injection L124–129), `mirrorHostCredentials`, `seedClaudeConfig`.
- `broker/internal/session/manager.go` — spawn cred branch (~L458–530),
  `cleanupAgentHomeCredentials` (~L1349), watchdog re-materialize
  `RefreshAllSessionCredentials` (~L1731).
- `broker/internal/session/credfresh.go` — `useHostOverAppBlob`,
  `refreshStaleAgentCredentials`, `credentialExpiryMillis`, `jwtExpiryMillis`,
  `sessionCredentialFile`, `hostCredentialFile`.
- `broker/internal/session/watchdog.go:68` — watchdog cred tick.
- `broker/internal/session/stage_transcript.go` — `stageExternalTranscript` /
  `stageClaudeTranscript` (writes `projects/<slug>/`) / `stageCodexTranscript`
  (writes `sessions/<rel>`).
- `broker/internal/session/external_discovery.go` — `claudeSlugToCWD`
  ("-root-developer-projects-conduit" → "/root/developer/projects/conduit"):
  proof transcripts are cwd-slug-keyed and thus collision-free in a shared dir.
- `broker/internal/session/{accountusage,aigen,codexaccountusage}.go` —
  broker-side fetchers that read the session cred file.
- `broker/internal/credentials/store.go` — encrypted at-rest store
  (`ValidProvider` = `{openai, anthropic}`), `Set`/`Get`/`Materialize`/`Delete`.
- `broker/cmd/conduit-broker/embedded-agents/{claude,codex,opencode,gemini}.toml`
  — `login_provider`, `cred_files`, `config_dir`, `env_passthrough`.
- `docs/archive/PLAN-AGENT-OAUTH.md` — the app-pushed-blob model (§D), claude/
  codex auth mechanics (§B/§C), litter-faithful server-side login.
- Live evidence: `/root/.claude/daemon.log` (cross-process refresh +
  re-auth-required strands); `/root/.local/share/claude/versions/2.1.186`
  strings (`CLAUDE_CODE_OAUTH_TOKEN` inference-only / scope-limited).
