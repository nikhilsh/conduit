# Renaming `broker/` → `broker/`

> **Archived 2026-05-27 — shipped; see [`docs/ROADMAP.md`](../ROADMAP.md).** The
> `harness/` → `broker/` rename landed and "harness" is gone from the
> user-facing product. Preserved for the rename rationale and migration notes.

Written 2026-05-21. Companion to `docs/TESTING-STRATEGY.md`.

## Why

We've been calling the Go server component `harness` since the first commit. The word is wrong, and it actively impedes any conversation about real test harnesses for the mobile apps. From [TESTING-STRATEGY.md](./TESTING-STRATEGY.md):

> In software engineering, a "test harness" is scaffolding that drives the system under test. What we call `conduit-broker` is: a WebSocket server, an agent process manager (spawns Claude/Codex in PTYs), a session/state broker, a snapshot ring + sidecar coordinator. That's a **gateway** or **broker**, not a harness.

The word snowballed across the repo (`broker/`, `conduit-broker` binary, `release-broker.yml`, install scripts, docs, even memory files). It needs to come out cleanly in one PR so we can use "harness" correctly going forward.

## Naming

**`broker`** — wins because:
- Accurate: the service brokers between mobile clients and agent processes, holding session state in the middle.
- Short (six characters), reads well in code (`broker.Session`, `broker.NewManager`).
- Doesn't collide with any existing concept in the repo.

Alternatives considered:
- `gateway` — accurate but generic; every web service is a gateway to something. Less informative.
- `daemon` — too generic; tells you nothing about what the service does.
- `agent-broker` — accurate but verbose; the prefix doesn't add information given the context.
- `server` — too generic; we already have lots of "server" in the codebase as a noun.

**Decision:** `broker`.

## Scope of the rename

### Code paths

| Before | After |
| --- | --- |
| `broker/` | `broker/` |
| `broker/cmd/conduit-broker/` | `broker/cmd/conduit-broker/` |
| `broker/internal/session/` | `broker/internal/session/` |
| `broker/internal/ws/` | `broker/internal/ws/` |
| `broker/internal/agents/` | `broker/internal/agents/` |
| `broker/internal/termgrid/` | `broker/internal/termgrid/` |
| `broker/sidecar/` | `broker/sidecar/` |
| `broker/go.mod`, `broker/go.sum` | `broker/go.mod`, `broker/go.sum` |

### Go module path

`github.com/nikhilsh/conduit/harness` → `github.com/nikhilsh/conduit/broker`

Every `internal/...` import inside the module gets updated. The `find`/`sed` is mechanical.

### Binary name

`conduit-broker` → `conduit-broker`

This breaks every `/opt/conduit/conduit-broker` install on a live VPS. See **Migration** below.

### Workflows

| Before | After |
| --- | --- |
| `.github/workflows/release-broker.yml` | `.github/workflows/release-broker.yml` |
| `ci.yml` job `harness (go)` | `ci.yml` job `broker (go)` |
| `release.yml` step `harness / cross-compile...` | `release.yml` step `broker / cross-compile...` |
| Release artifact `conduit-broker-${OS}-${ARCH}.tar.gz` | `conduit-broker-${OS}-${ARCH}.tar.gz` |

### Scripts

- `scripts/install.sh`: every `conduit-broker` token → `conduit-broker`. Detect old install, offer to remove the old binary alongside placing the new one.
- `scripts/remote-bootstrap.sh`: same.

### Environment variables

Audit all `KITTY_*` and `CONDUIT_*` env vars. Any with `HARNESS` in the name renamed; everything else kept (no risk of breaking user configs unnecessarily). Today: none have HARNESS in the name; the prefix is already `KITTY_*`. No env changes needed.

### Documentation

`docs/PLAN.md`, `docs/ARCHITECTURE.md`, `docs/MOBILE-PORT-MATRIX.md`, `docs/RELEASE.md`, `docs/MOBILE-FEATURE-BACKLOG.md`, `README.md`, `CONTRIBUTING.md`, plus the memory files at `~/.claude/projects/-root/memory/project_conduit.md` and `feedback_verify_ci.md`.

The word "harness" appears in two distinct senses in the docs today:
1. The server component (what we're renaming).
2. The dev harness for parallel-agent workflow on this repo (the `swe-swe`-style multi-agent setup described in `docs/PLAN.md` Part A). **This usage IS a valid "harness"** — it's literally infrastructure that runs the agents. We keep this usage; we only rename the **server** instances.

The renaming PR must distinguish these. Sense (1) → `broker`. Sense (2) → leave alone.

### What does NOT change

- `conduit.service` systemd unit name. User-facing; renaming would force every VPS operator to manually disable/re-enable.
- `conduit` CLI name (the wrapper that runs commands like `conduit memory render`).
- `.conduit/` data directory. Same reason as the service name — user-facing.
- `conduit` system user on the VPS. Same.
- The product name. Still "conduit".
- Memory file slugs like `project-conduit` (slug rename would invalidate `[[link]]` references).

## Migration path for existing VPS installs

The binary path changes from `/opt/conduit/conduit-broker` to `/opt/conduit/conduit-broker`. Existing installs need a one-time fixup.

**Strategy A — install.sh side-by-side (recommended).** The new `install.sh` lays down the new binary, updates the systemd unit's `ExecStart=`, removes the old binary. Single command for the user; no manual cleanup.

```bash
# After the rename ships:
ssh vps "curl -fsSL https://conduit.fyra.dev/install.sh | sudo bash"
# The script detects /opt/conduit/conduit-broker, replaces it.
```

**Strategy B — symlink for one release cycle.** Drop `conduit-broker` as the new binary AND a symlink `conduit-broker → conduit-broker` so unmodified systemd units keep working. Remove the symlink in the next release.

**Decision: Strategy A.** Cleaner. Less code in install.sh long-term.

## Risks

- **GitHub release artifact URLs change.** Anyone hot-linking `conduit-broker-linux-amd64.tar.gz` from an external script breaks. Mitigation: cut one release that publishes BOTH the old and new names; deprecate the old name in the release after that.
- **Memory file references.** The memory file `project_conduit.md` mentions "harness" repeatedly. Need to update prose but keep the slug.
- **External docs / blog posts / Slack messages.** Out of our control; one-line "we renamed harness → broker" note in the next release notes covers it.

## What the rename PR actually contains

1. `git mv harness broker`
2. Sed pass over the whole tree: `github.com/nikhilsh/conduit/harness` → `github.com/nikhilsh/conduit/broker`
3. Binary name change in `release.yml`, `release-broker.yml` → `release-broker.yml`, plus the build commands inside.
4. CI job rename in `ci.yml`.
5. `scripts/install.sh` rewrite for Strategy A.
6. Doc pass: replace "harness" in server-component sense, keep in dev-harness sense.
7. CHANGELOG entry.

Single PR. Big diff, but mechanical. Reviewable by reading the workflow + script changes carefully and skimming the import-path diff for anything weird.

## Order of operations

1. Land **`TESTING-STRATEGY.md`** (this doc's sibling) so the testing posture is in place first.
2. Land **the rename**.
3. Add the iOS / Android test targets per the testing doc.

Reason: doing the rename before adding tests means there's no working-but-renamed-twice churn. Doing tests before the rename means the first test file lives at `broker/internal/...` and immediately needs to be moved.
