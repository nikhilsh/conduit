# PLAN: Agent credential lineage — never fork the refresher

Status: **design only. No production code in this PR.**

This plan fixes a credential-lineage **race** in the broker that logs the box
operator out of their agents (Claude, Codex, …). The broker forks one OAuth
login into N+1 independent on-disk copies (the host login + one per session),
each of which refreshes on its own schedule. Because the providers rotate
refresh tokens **single-use**, whichever copy refreshes first invalidates every
other copy — including the operator's own host login. The fix is structural:
**stop forking the lineage.** Make every session and (ideally) the host share
**one** broker-owned canonical credential file per provider, and let the agent
CLI's own cross-process refresh coordination do its job.

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

`claude` already solves this **when multiple processes share one file**: its
auth supervisor does cross-process refresh coordination (re-reads the file,
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
   `claude` **does** coordinate refresh across processes that share one file
   (the behaviour conduit defeats by copying).
2. `proactive refresh failed, signalling re-auth required` recurring in bursts —
   the operator's host login being **stranded** because a forked copy already
   consumed the lineage's refresh token. Repeated `scheduling proactive refresh`
   lines appearing in **duplicate at the same millisecond** are two processes
   reading the same on-disk schedule — the fork fingerprint.

The diagnosis in the task ("two live credential copies on the box had DIVERGED
refresh tokens with expiries ~27s apart") is the same phenomenon: two heads of
one lineage, each refreshed independently.

### 1.4 Provider verification (live, non-destructive, this box)

Verified by reading binaries / `--help` / on-disk file shapes only — **no real
token refresh was triggered** against the operator's live account.

| Provider | Cred file (under `$HOME`) | Rotates refresh token single-use? | Cross-process refresh lock? | Env-token bypass? |
|----------|---------------------------|-----------------------------------|-----------------------------|-------------------|
| **claude** (anthropic) | `.claude/.credentials.json` (`claudeAiOauth{accessToken,refreshToken,expiresAt,scopes,subscriptionType}`) | **Yes** (Anthropic OAuth; live daemon.log shows refresh→re-auth strands) | **Yes** — supervisor re-reads file, logs `token still valid (cross-process refresh or not yet due)` | `CLAUDE_CODE_OAUTH_TOKEN` exists (63 refs in 2.1.186) **but is inference-only / non-refreshing** — see §1.5 |
| **codex** (openai) | `.codex/auth.json` (`auth_mode:"chatgpt"`, `tokens{id_token,access_token,refresh_token,account_id}`, `last_refresh`) | **Yes** (OpenAI rotates `refresh_token` on `offline_access` exchanges; `last_refresh` is a single-writer timestamp) | **Unverified / assume NO** — binary stripped, no `flock`/`lock` strings found; design must assume codex has no cross-process lock | `codex login --with-access-token` (stdin) takes an **access** token only — **no refresh token → expires in ~1h, never refreshes** (archived PLAN §C.3). Not usable. |
| **opencode** | env-first; optional `.local/share/opencode/auth.json` (absent on this box — it now uses `opencode.db` SQLite). Provider keys flow via `ANTHROPIC_API_KEY`/`OPENAI_API_KEY`/`OPENCODE_API_KEY` env. | N/A for env keys (API keys don't rotate); zen free provider has no creds | N/A | **Env IS the primary path** (`opencode.toml env_passthrough`) |
| **gemini** (google) | `.gemini/gemini-credentials.json` (**encrypted/opaque blob** — not plain JSON) + `google_accounts.json` | Unknown (opaque); Google OAuth refresh tokens are typically **long-lived/reusable**, not single-use | Unknown | `GEMINI_API_KEY` / `GOOGLE_API_KEY` (`gemini.toml env_passthrough`) |

Key point: the **only two providers that (a) rotate single-use refresh tokens
AND (b) have an app-push / host-OAuth file lineage that conduit forks** are
**claude and codex**. Those are exactly the two the app-pushed credential store
already supports (`credentials.ValidProvider` = `{openai, anthropic}`). opencode
and gemini are **not** in the encrypted store and authenticate primarily via
**env keys that don't rotate**, so they are not part of the race — but the
uniform mechanism below covers them for free where a file exists.

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

## 2. The invariant

> **Exactly one refresher per lineage. Never fork the lineage.**

Operationally: for each provider there is **one** canonical credential file the
broker owns. Every session's credential path (and, where safe, the host's)
**points at that one file** (symlink), so the agent CLIs' own cross-process
refresh coordination is the *only* thing that ever advances the lineage. A
refresh by any session, or by the operator's own interactive `claude`/`codex`,
mutates the **same bytes** everyone else reads. There is no second head to
strand.

Corollary invariants the design must also hold:
- **App-push on a login-less box keeps working** (hard requirement — the
  SSH-bootstrap per-box credential model depends on it). The canonical file is
  seeded from *either* the host login *or* the app-pushed blob, whichever
  exists.
- **A still-valid app blob for a deliberately-different account still wins**
  (the phone may be signed into a different account than the box on purpose).
- **The encrypted at-rest store survives** (it persists app-pushed blobs across
  broker restarts and re-seeds the canonical file).

---

## 3. Chosen structure: one canonical file per provider, symlinked into every HOME

### 3.1 Layout

```
<conduitRoot>/
  credentials/                         # (existing encrypted store dir, unchanged)
    <identity-sha256>/anthropic.enc     # app-pushed blob, encrypted at rest
    <identity-sha256>/openai.enc
    .keyfile
  agent-creds/                          # NEW: broker-owned CANONICAL plaintext files
    anthropic/.credentials.json         # the single lineage head for claude
    openai/auth.json                    # the single lineage head for codex
    # (opencode/gemini: a file slot only materialized if/when a file lineage exists)
  sessions/<id>/agent-home/
    .claude/.credentials.json  ->  <conduitRoot>/agent-creds/anthropic/.credentials.json   (symlink)
    .codex/auth.json           ->  <conduitRoot>/agent-creds/openai/auth.json              (symlink)
    .claude.json                # per-session real file (theme/onboarding) — NOT shared
    .codex/config.toml          # per-session real file — NOT shared
```

The canonical files live **plaintext** (mode `0600`, dir `0700`, broker UID) —
they have to, because the agent CLI reads/writes them directly. This is **no
weaker** than today: `~/.claude/.credentials.json` and every
`agent-home/.../credentials.json` copy are already plaintext `0600` on the same
UID. The encrypted `.enc` store keeps its role (at-rest protection of the
app-pushed blob against a raw-disk/backup reader who lacks `.keyfile`).

### 3.2 Why uniform (symlink-to-canonical-file) for ALL providers, not a mix

Simplicity First. A single mechanism — "the session's credential path is a
symlink to the provider's canonical file" — covers claude, codex, opencode, and
gemini identically:

- It is **provider-agnostic**: nothing about it knows the credential *schema*;
  it only knows the *path* each provider reads (already encoded in the adapter
  TOML `cred_files` / `config_dir`).
- It **preserves the agent's own refresh + cross-process coordination** verbatim
  — the CLI writes the same file it always did; it just happens to be shared.
  (Atomic-rename writers are handled in §6.)
- It works for the **env-key providers (opencode/gemini) for free**: if no file
  lineage exists, there is simply nothing to symlink and the env passthrough is
  untouched. No special-casing.
- The broker-side fetchers that read
  `<agentHomeDir>/.claude/.credentials.json` directly
  (`accountusage.go`, `aigen.go`, `codexaccountusage.go`) keep working with
  **zero changes** — `os.ReadFile` follows the symlink to the canonical file and
  always sees the freshest token, which is strictly *better* than today (today
  they can read a stale per-session copy).

The **env-injection alternative for claude only** (`CLAUDE_CODE_OAUTH_TOKEN`) is
rejected as the default (§1.5): it is a different, reduced-scope credential type,
requires a separate login, and applies to exactly one provider — the opposite of
uniform. The canonical-file approach gives claude full subscription scope and is
identical to the other three providers' handling.

### 3.3 Seeding the canonical file (the app-push-on-login-less-box requirement)

At broker startup and at session spawn, the canonical file for a provider is
**ensured** from exactly one source, in this precedence (this is the new home
for the `useHostOverAppBlob` decision — made **once per provider**, not once per
session):

1. **Valid app-pushed blob present** → decrypt `<provider>.enc` and write it to
   the canonical file. A *valid* (non-expired) blob always wins over the host
   login — it may be a deliberately different account. **This is the login-less
   SSH-bootstrap path**: there is no host `~/.claude/.credentials.json`, the
   phone pushed the only credential, and it lands in the canonical file that
   every session symlinks. App-push keeps working exactly as before; only the
   *destination* changes from "each session's private copy" to "the one shared
   canonical file."
2. **No valid app blob, host login present** → seed the canonical file from
   `~/.claude/.credentials.json` (resp. `~/.codex/auth.json`). On a box where the
   operator runs the CLI directly, prefer the **host file as the canonical file
   itself** when safe — see §3.4 — so operator and sessions are *literally the
   same lineage*.
3. **Expired app blob + fresher host login** → seed from the host
   (`useHostOverAppBlob` semantics, preserved).
4. **Neither** → no canonical file; sessions symlink-dangling is avoided by
   simply not creating the symlink, and the agent prompts `/login` (clean error,
   no race), exactly as today.

Account-switch (phone pushes a different account via `set_agent_credentials` /
`Store.Set`) overwrites the **canonical file** atomically → all sessions and
fetchers see the new account at their next read. In-flight agent processes that
hold the old file open keep running on it until their next file read (the CLIs
re-read on refresh), which is the desired "next turn picks up the new account"
semantics already documented in archived PLAN §D.4.

### 3.4 Host coupling: share the lineage with the operator (the actual fix)

The race that logs the *operator* out only ends if the operator's interactive
`claude`/`codex` and the broker sessions are the **same lineage**. Two options,
gated behind the feature flag (§8):

- **Option A — canonical file IS the host file (default when a host login
  exists).** The canonical path for anthropic *is* `~/.claude/.credentials.json`;
  sessions symlink to it. The operator and every session share one file; the
  CLI's cross-process coordination (proven live, §1.3) governs all refreshes.
  This is the **minimal, race-free-by-construction** design and requires no copy
  at all on a logged-in box.
- **Option B — canonical file under `<conduitRoot>/agent-creds`, host
  symlinked to it.** On a login-less box (no host file) the canonical file is
  broker-owned (seeded from the app blob). If we *also* want the operator's
  future interactive `claude login` to feed the same lineage, the broker can
  symlink `~/.claude/.credentials.json` → canonical. This is more invasive
  (touches the operator's `$HOME`) and is **opt-in** (off by default; many
  operators won't want conduit symlinking their dotfiles).

**Recommendation:** Option A when a host login exists (zero-copy, the operator is
already the lineage); Option B's broker-owned canonical file when no host login
exists (login-less SSH box). The host-`$HOME` symlink half of Option B is
deferred behind an explicit flag — it is the only part that mutates the
operator's home directory.

---

## 4. Concurrency analysis (honest, per provider)

The shared-file question: host + 2 sessions all point at one file and two try to
refresh near-simultaneously. What happens?

### 4.1 claude (anthropic) — **safe; the CLI coordinates**

Live-proven (§1.3): the claude auth supervisor performs **cross-process refresh
coordination** — before refreshing it re-reads the file, and if a peer already
refreshed (`token still valid (cross-process refresh or not yet due)`) it
declines. Worst case if two processes still race the window: both attempt a
refresh; one wins (advances the lineage and writes the file), the other's
refresh returns `invalid_grant`, the loser **re-reads the now-fresh file** and
recovers on the next inference call. Recoverable **because they share the file** —
the loser reads the winner's fresh token. This is exactly the property conduit
destroys today by giving each a private copy (the loser's private copy has no
winner to read). Atomic-rename writes (§6) ensure no torn read.

### 4.2 codex (openai) — **assume no lock; recoverable but with a worst-case window**

We could not confirm a cross-process lock in the codex binary (stripped). Treat
codex as **no cross-process coordination**. Worst case: two sessions refresh in
the same window; both POST the rotating `refresh_token`; the provider honors the
first and `invalid_grant`s the second; the second's in-memory token is now dead
**but** the first wrote a fresh `auth.json`, so the second's **next file read**
(codex re-reads `auth.json` on its refresh path) recovers. The recovery hinges
on the file being **shared** — which the canonical-file design guarantees. This
is still strictly better than today: today the loser's *private copy* is
permanently dead (nothing fresher to read) and the operator's host login is a
third racer that gets stranded too.
Residual risk: a refresh storm (many codex sessions all expiring at once) could
cause repeated `invalid_grant`→re-read churn for a few seconds. Acceptable and
self-healing; flagged for live verification (§10). If it proves noisy, a small
broker-held **per-provider advisory `flock`** around the canonical file (held
only during the brief window the CLI is allowed to refresh) is a follow-up — but
we do **not** ship it speculatively.

### 4.3 opencode / gemini — **not in the race**

opencode authenticates via non-rotating env API keys (primary path) or the zen
free provider; gemini via `GEMINI_API_KEY` env or a Google OAuth blob whose
refresh tokens are conventionally reusable (not single-use). Neither has the
fork-strands-the-operator failure mode the way anthropic/codex do. The uniform
symlink covers them if a file lineage ever exists, otherwise the env path is
untouched. No special handling.

---

## 5. Security notes

- **File perms/ownership:** canonical files `0600`, `agent-creds/<provider>/`
  dirs `0700`, all broker UID — identical posture to today's per-session copies
  and the host file. No new at-rest exposure.
- **Symlink safety:** the broker creates each symlink itself, pointing at a
  **broker-owned absolute path** under `conduitRoot` (or the resolved host file).
  It never creates a symlink whose target is attacker-controlled, and the
  session HOME is broker-created `0700`. The agent runs as the broker UID, so a
  symlink can't cross a privilege boundary. Before pointing a session symlink at
  the host file (Option A), the broker `Lstat`s the target and refuses if it is
  itself a symlink to outside `$HOME`/`conduitRoot` (defense against a
  pre-planted malicious dotfile). Writes go through atomic temp-file + rename
  **within the canonical dir**, never following the session-side symlink to an
  unexpected location.
- **Encrypted store unchanged:** `broker/internal/credentials/store.go` keeps
  AES-256-GCM + keyfile. Its role is now precisely: (a) persist the app-pushed
  blob across broker restarts, (b) re-seed the canonical file on startup /
  account-switch. `Materialize` gains/【or is wrapped by】a "write to the
  canonical path" variant; `Set` triggers a canonical re-seed. The `.enc` blob
  remains the only at-rest-encrypted copy; the canonical plaintext file is the
  live working copy (as the host file already is).
- **No token ever crosses a new wire.** Unchanged from today.

---

## 6. Atomic-write / shared-file write hazard

Both CLIs write credentials via **temp-file + rename** (`atomicWriteFileMode` in
the broker mirrors this; the CLIs do the same). A rename **replaces the inode**,
which would **break a symlink that points at the old inode's *name*** only if the
symlink pointed at the temp file — it does not. The session symlinks point at the
**canonical path name** (`…/agent-creds/anthropic/.credentials.json`); a
rename-into-that-name is exactly how the file is meant to be updated, and the
symlink resolves to the new inode on the next open. The hazard to verify live
(§10): a CLI that writes its credential via `rename` from a temp file **in its
own `$HOME/.claude/`** (i.e. it writes through the symlink's directory, not the
canonical dir). If a CLI does `open(.claude/.credentials.json)` and writes
in-place, it writes through the symlink to the canonical inode — **good**. If it
does `write tmp in .claude/ + rename over .credentials.json`, the rename
**replaces the symlink with a real file in the session HOME** — re-forking the
lineage. Mitigation hierarchy:
1. **Point the symlink at the directory, not the file** is not possible
   (`.claude` holds other per-session state). Instead, symlink the **file**.
2. If a provider's CLI is found to rename-over the symlink, fall back for **that
   provider** to making `.claude` itself a symlink scoped to a per-provider
   canonical config dir — accepted only if forced. claude's live behaviour
   (cross-process coordination implies it re-opens/rewrites in place, not a HOME
   rename) suggests in-place write; **this is the single most important live
   verification item.**

This hazard is the reason the plan is **design + live-verify**, not blind
implementation.

---

## 7. What gets DELETED / shrunk

- **`broker/internal/session/credfresh.go` — the watchdog re-mirror is
  DELETED.** `refreshStaleAgentCredentials` exists solely to heal a forked copy
  that went stale. With one shared canonical file there is no copy to go stale,
  so the watchdog tick (`watchdog.go:68`) and the spawn-time re-materialize
  (`manager.go:1744`) lose their cred branch. Retain only the small
  `credentialExpiryMillis` / `jwtExpiryMillis` helpers — they move to the
  seed-precedence decision (§3.3) where the *blob-vs-host freshness* comparison
  still happens **once per provider**, not per session.
- **`mirrorHostCredentials` (lifecycle.go) — replaced** by `linkCanonicalCreds`
  (create the symlink) + `ensureCanonicalCred` (seed the canonical file). The
  per-session *copy* is gone. The "mirror every provider into every session HOME
  so the Terminal tab is logged in" loop (`manager.go:521–530`) becomes "symlink
  every provider's canonical file into the session HOME" — cheaper and
  race-free.
- **`useHostOverAppBlob` — kept but relocated** to the once-per-provider seed
  path; its per-session call site is removed.
- **The broker-side fetchers (`accountusage.go`, `aigen.go`,
  `codexaccountusage.go`) — UNCHANGED.** They read
  `<agentHomeDir>/.claude/.credentials.json`; `os.ReadFile` follows the symlink.

Net: one file deleted (`credfresh.go` minus the two retained helpers, which move
to a `credseed.go`), one spawn branch simplified, the watchdog cred tick gone.

---

## 8. Rollout / migration

- **Feature flag:** `CONDUIT_SHARED_AGENT_CREDS` (broker env / flag), default
  **off** for one release. Off → today's per-session copy + watchdog path
  verbatim. On → canonical-file + symlink path. This lets us ship the code dark,
  flip on the dev box, and confirm the §6 write-hazard live before defaulting on.
- **Existing running sessions:** untouched. The flag only changes how *new*
  sessions are spawned. A redeploy doesn't migrate live agent-homes; they keep
  their private copies until they exit. (Broker redeploy is a hard gate per
  `CLAUDE.md` since `broker/` changes.)
- **No-downtime:** the canonical file is ensured idempotently at startup and at
  each spawn; a half-written canonical file can never be observed (atomic
  rename). If seeding fails, fall back to the legacy copy path for that spawn
  (fail-safe: a session never refuses to start over a cred-seed hiccup).
- **Account-switch / sign-out:** `Store.Set` re-seeds the canonical file;
  `Store.Delete` removes the canonical file (and `.enc`) for that provider — the
  next session prompts `/login`. Host login files are never touched by Delete
  (existing `Store.Delete` contract preserved).

---

## 9. Escape hatch (documented, not default)

`CLAUDE_CODE_OAUTH_TOKEN` (claude only): for a CI-style box where the operator
*wants* a long-lived inference-only token and never runs interactive `claude`,
the broker may inject it via env and skip the canonical file entirely (store
nothing refreshable in the session HOME → no lineage to fork). This is a
**provider-specific, reduced-scope** path (§1.5) and is explicitly **not** the
default. Surfaced here so we don't reinvent it later; gated behind its own env
opt-in if ever wired.

---

## 10. Test plan

### Unit (broker, locally runnable: `gofmt -l . && go vet ./... && go test ./...`)

`broker/internal/session`:
- `ensureCanonicalCred`: seeds from valid app blob (login-less box) → canonical
  file equals decrypted blob. Seeds from host when no blob. Expired-blob +
  fresher-host → host wins (preserves `useHostOverAppBlob` table tests, moved).
  Neither source → no canonical file, no symlink, no error.
- `linkCanonicalCreds`: session HOME gets a symlink whose target is the canonical
  path; reading through the symlink returns canonical bytes; updating the
  canonical file is visible through every session's symlink (the invariant —
  one write, all readers see it).
- Symlink safety: refuses to point at a host file that is itself a symlink
  outside `$HOME`/`conduitRoot` (Lstat guard).
- Account-switch: `Store.Set` re-seed overwrites the canonical file; an existing
  session's symlink now resolves to the new account.
- Deletion of the watchdog branch: `credfresh_test.go` cases that asserted
  re-mirror behaviour are removed/replaced with "no per-session copy exists; the
  canonical file is the only file."
- Multi-session: spawn 3 sessions for the same provider → assert all 3 cred
  paths resolve (`EvalSymlinks`) to the **same** canonical inode (the structural
  proof that the lineage is not forked).

`broker/internal/credentials`:
- `Set`/`Get`/`Materialize` unchanged; add a `MaterializeCanonical(provider,
  canonicalDir)` (or equivalent) test that the plaintext lands `0600` at the
  canonical path.

### Live / device-only (cannot be unit-tested — flag as needs-live-verify)

1. **The §6 write hazard (highest priority):** run a real `claude` and a real
   `codex` session against the canonical file, force a refresh window, and
   confirm via `ls -li` that the session's `.claude/.credentials.json` is still a
   **symlink to the canonical inode** afterward (i.e. the CLI wrote *in place* and
   did not rename-over the symlink). If either renames-over, escalate to the §6
   per-provider fallback.
2. **The operator-logout fix (the actual bug):** with the flag on, run several
   broker sessions + interactive `claude` on the box concurrently for a refresh
   cycle; confirm `daemon.log` no longer logs
   `proactive refresh failed, signalling re-auth required` and the operator
   stays logged in.
3. **Login-less SSH box:** fresh box, no host login, phone pushes the blob →
   canonical file seeded from the blob → session runs on the pushed account.
   App-push still works (hard requirement).
4. **codex refresh storm:** many codex sessions expiring together → confirm
   self-healing within seconds, no permanent logout (validates §4.2's honest
   worst case).

### Definition of done for the implementing PR(s)

- Local broker gates green; **broker redeployed** (the cred path is live code).
- Flag defaults off; live items 1–4 verified on the dev box before defaulting
  the flag on in a follow-up.

---

## 11. File-by-file implementation map (for the implementing PR)

| File | Change |
|------|--------|
| `broker/internal/session/lifecycle.go` | Replace `mirrorHostCredentials` with `linkCanonicalCreds(provider, ephemeralHome)` (symlink) + keep `seedClaudeConfig` (per-session `.claude.json` stays a real file). |
| `broker/internal/session/credseed.go` (new) | `ensureCanonicalCred(provider)` (seed precedence §3.3) + relocated `useHostOverAppBlob` / `credentialExpiryMillis` / `jwtExpiryMillis`. `canonicalCredPath(provider)`. |
| `broker/internal/session/credfresh.go` | **Delete** `refreshStaleAgentCredentials` + the watchdog re-mirror. Move retained expiry helpers to `credseed.go`. |
| `broker/internal/session/watchdog.go` | Remove the `refreshStaleAgentCredentials()` call (L68). |
| `broker/internal/session/manager.go` | Spawn path (~L458–530): once-per-provider `ensureCanonicalCred`, then `linkCanonicalCreds` for the session provider + every other known provider; drop the per-session copy + the `manager.go:1744` re-materialize. Gate on `CONDUIT_SHARED_AGENT_CREDS`. |
| `broker/internal/credentials/store.go` | Add `MaterializeCanonical` (or have spawn call `Get` + write canonical) and a `Set` hook to re-seed the canonical file on account-switch. Encrypted store otherwise unchanged. |
| `broker/cmd/conduit-broker/main.go` | Read `CONDUIT_SHARED_AGENT_CREDS`; ensure `agent-creds/` dir at startup; seed canonical files for stored providers on boot. |
| tests | `credseed_test.go` (new), update `credfresh_test.go`, add multi-session same-inode assertion. |

---

## 12. References (verbatim code paths)

- `broker/internal/session/lifecycle.go` — `mirrorHostCredentials`, `commandEnv`
  (HOME injection L124), `seedClaudeConfig`.
- `broker/internal/session/manager.go` — spawn cred branch (~L458–530),
  watchdog re-materialize (L1726–1744).
- `broker/internal/session/credfresh.go` — `useHostOverAppBlob`,
  `refreshStaleAgentCredentials`, `credentialExpiryMillis`, `jwtExpiryMillis`.
- `broker/internal/session/watchdog.go:68` — watchdog cred tick.
- `broker/internal/session/{accountusage,aigen,codexaccountusage}.go` —
  broker-side fetchers that read the session cred file (symlink-transparent).
- `broker/internal/credentials/store.go` — encrypted at-rest store
  (`ValidProvider` = `{openai, anthropic}`), `Set`/`Get`/`Materialize`/`Delete`.
- `broker/cmd/conduit-broker/embedded-agents/{claude,codex,opencode,gemini}.toml`
  — `login_provider`, `cred_files`, `config_dir`, `env_passthrough`.
- `docs/archive/PLAN-AGENT-OAUTH.md` — the app-pushed-blob model (§D), claude/
  codex auth mechanics (§B/§C), litter-faithful server-side login.
- Live evidence: `/root/.claude/daemon.log` (cross-process refresh +
  re-auth-required strands); `/root/.local/share/claude/versions/2.1.186`
  strings (`CLAUDE_CODE_OAUTH_TOKEN` inference-only / scope-limited).
