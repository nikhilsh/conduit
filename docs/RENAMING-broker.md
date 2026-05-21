# Renaming `harness/` → `broker/`

Written 2026-05-21. Companion to `docs/TESTING-STRATEGY.md`.

## Why

We've been calling the Go server component `harness` since the first commit. The word is wrong, and it actively impedes any conversation about real test harnesses for the mobile apps. From [TESTING-STRATEGY.md](./TESTING-STRATEGY.md):

> In software engineering, a "test harness" is scaffolding that drives the system under test. What we call `swe-kitty-harness` is: a WebSocket server, an agent process manager (spawns Claude/Codex in PTYs), a session/state broker, a snapshot ring + sidecar coordinator. That's a **gateway** or **broker**, not a harness.

The word snowballed across the repo (`harness/`, `swe-kitty-harness` binary, `release-harness.yml`, install scripts, docs, even memory files). It needs to come out cleanly in one PR so we can use "harness" correctly going forward.

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
| `harness/` | `broker/` |
| `harness/cmd/swe-kitty-harness/` | `broker/cmd/swe-kitty-broker/` |
| `harness/internal/session/` | `broker/internal/session/` |
| `harness/internal/ws/` | `broker/internal/ws/` |
| `harness/internal/agents/` | `broker/internal/agents/` |
| `harness/internal/termgrid/` | `broker/internal/termgrid/` |
| `harness/sidecar/` | `broker/sidecar/` |
| `harness/go.mod`, `harness/go.sum` | `broker/go.mod`, `broker/go.sum` |

### Go module path

`github.com/nikhilsh/swe-kitty/harness` → `github.com/nikhilsh/swe-kitty/broker`

Every `internal/...` import inside the module gets updated. The `find`/`sed` is mechanical.

### Binary name

`swe-kitty-harness` → `swe-kitty-broker`

This breaks every `/opt/swe-kitty/swe-kitty-harness` install on a live VPS. See **Migration** below.

### Workflows

| Before | After |
| --- | --- |
| `.github/workflows/release-harness.yml` | `.github/workflows/release-broker.yml` |
| `ci.yml` job `harness (go)` | `ci.yml` job `broker (go)` |
| `release.yml` step `harness / cross-compile...` | `release.yml` step `broker / cross-compile...` |
| Release artifact `swe-kitty-harness-${OS}-${ARCH}.tar.gz` | `swe-kitty-broker-${OS}-${ARCH}.tar.gz` |

### Scripts

- `scripts/install.sh`: every `swe-kitty-harness` token → `swe-kitty-broker`. Detect old install, offer to remove the old binary alongside placing the new one.
- `scripts/remote-bootstrap.sh`: same.

### Environment variables

Audit all `KITTY_*` and `SWE_KITTY_*` env vars. Any with `HARNESS` in the name renamed; everything else kept (no risk of breaking user configs unnecessarily). Today: none have HARNESS in the name; the prefix is already `KITTY_*`. No env changes needed.

### Documentation

`docs/PLAN.md`, `docs/ARCHITECTURE.md`, `docs/MOBILE-PORT-MATRIX.md`, `docs/RELEASE.md`, `docs/MOBILE-FEATURE-BACKLOG.md`, `README.md`, `CONTRIBUTING.md`, plus the memory files at `~/.claude/projects/-root/memory/project_swe_kitty.md` and `feedback_verify_ci.md`.

The word "harness" appears in two distinct senses in the docs today:
1. The server component (what we're renaming).
2. The dev harness for parallel-agent workflow on this repo (the `swe-swe`-style multi-agent setup described in `docs/PLAN.md` Part A). **This usage IS a valid "harness"** — it's literally infrastructure that runs the agents. We keep this usage; we only rename the **server** instances.

The renaming PR must distinguish these. Sense (1) → `broker`. Sense (2) → leave alone.

### What does NOT change

- `swe-kitty.service` systemd unit name. User-facing; renaming would force every VPS operator to manually disable/re-enable.
- `swe-kitty` CLI name (the wrapper that runs commands like `swe-kitty memory render`).
- `.swe-kitty/` data directory. Same reason as the service name — user-facing.
- `swekitty` system user on the VPS. Same.
- The product name. Still "swe-kitty".
- Memory file slugs like `project-swe-kitty` (slug rename would invalidate `[[link]]` references).

## Migration path for existing VPS installs

The binary path changes from `/opt/swe-kitty/swe-kitty-harness` to `/opt/swe-kitty/swe-kitty-broker`. Existing installs need a one-time fixup.

**Strategy A — install.sh side-by-side (recommended).** The new `install.sh` lays down the new binary, updates the systemd unit's `ExecStart=`, removes the old binary. Single command for the user; no manual cleanup.

```bash
# After the rename ships:
ssh vps "curl -fsSL https://swe-kitty.fyra.dev/install.sh | sudo bash"
# The script detects /opt/swe-kitty/swe-kitty-harness, replaces it.
```

**Strategy B — symlink for one release cycle.** Drop `swe-kitty-broker` as the new binary AND a symlink `swe-kitty-harness → swe-kitty-broker` so unmodified systemd units keep working. Remove the symlink in the next release.

**Decision: Strategy A.** Cleaner. Less code in install.sh long-term.

## Risks

- **GitHub release artifact URLs change.** Anyone hot-linking `swe-kitty-harness-linux-amd64.tar.gz` from an external script breaks. Mitigation: cut one release that publishes BOTH the old and new names; deprecate the old name in the release after that.
- **Memory file references.** The memory file `project_swe_kitty.md` mentions "harness" repeatedly. Need to update prose but keep the slug.
- **External docs / blog posts / Slack messages.** Out of our control; one-line "we renamed harness → broker" note in the next release notes covers it.

## What the rename PR actually contains

1. `git mv harness broker`
2. Sed pass over the whole tree: `github.com/nikhilsh/swe-kitty/harness` → `github.com/nikhilsh/swe-kitty/broker`
3. Binary name change in `release.yml`, `release-harness.yml` → `release-broker.yml`, plus the build commands inside.
4. CI job rename in `ci.yml`.
5. `scripts/install.sh` rewrite for Strategy A.
6. Doc pass: replace "harness" in server-component sense, keep in dev-harness sense.
7. CHANGELOG entry.

Single PR. Big diff, but mechanical. Reviewable by reading the workflow + script changes carefully and skimming the import-path diff for anything weird.

## Order of operations

1. Land **`TESTING-STRATEGY.md`** (this doc's sibling) so the testing posture is in place first.
2. Land **the rename**.
3. Add the iOS / Android test targets per the testing doc.

Reason: doing the rename before adding tests means there's no working-but-renamed-twice churn. Doing tests before the rename means the first test file lives at `harness/internal/...` and immediately needs to be moved.
