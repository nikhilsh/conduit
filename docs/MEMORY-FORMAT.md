# Memory format (frozen contract v1)

Inter-agent handoff and long-running-session continuity in swe-kitty rely on a structured HTML document. This file specifies the schema. Anything outside this schema is undefined behavior; the broker validator will reject non-conforming HTML.

HTML was chosen over Markdown because:
- It renders directly in the mobile in-app browser (no Markdown engine to ship)
- `<section data-section="…">` gives a stable, machine-readable structure without an AST library
- Embedded `<pre>`, `<dl>`, hyperlinks, and `hidden` attributes solve real needs cleanly
- A future "Memory diff UI" (v1.x) can highlight section-level diffs

## 1. Scopes

| Scope | Path | Lifetime |
|---|---|---|
| **project** | `.swe-kitty/memory/index.html` | Committed to git; permanent |
| **session** | `.swe-kitty/memory/sessions/<uuid>.html` | Per session; gitignored |

A document declares its scope via `<html data-scope="project|session">`.

## 2. Document skeleton

```html
<!doctype html>
<html lang="en" data-swe-kitty-memory="v1" data-scope="project|session">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width,initial-scale=1">
  <title>...</title>
  <link rel="stylesheet" href="memory.css">   <!-- project -->
  <!-- or for session: href="../memory.css" -->
</head>
<body>
  <header data-section="meta">...</header>
  <section data-section="...">...</section>
  ...
</body>
</html>
```

The `data-swe-kitty-memory` version attribute is mandatory. Schema breaking changes bump it to `v2`; the broker must reject mismatched versions with a clear error.

## 3. Required sections

### 3.1 `meta` (header, both scopes)
A `<dl>` of key/value metadata. Keys vary by scope; see §3.2 and §3.3.

### 3.2 Project-scope required sections

| `data-section` | Content |
|---|---|
| `meta` | `repo`, `memory-format`, `last-promoted` |
| `north-star` | One paragraph: what swe-kitty is, why |
| `frozen-contracts` | `<ol>` linking to the four contract docs |
| `decisions` | `<ol>` of `<li data-id="d-NNN">` project-wide decisions |
| `conventions` | `<ul>` of one-line conventions |
| `open-questions` | `<ul>` of unresolved project-wide questions |
| `promoted-from-sessions` | `<ol>` of insights lifted from session memory via `memory promote` |

### 3.3 Session-scope required sections

| `data-section` | Content |
|---|---|
| `meta` | `session`, `worktree`, `branch`, `task`, `current-agent`, `created`, `last-checkpoint` |
| `task` | Brief summary + pointer to the canonical brief in `.swe-kitty/tasks/` |
| `state` | "Last completed", "Currently working on", "Next step" |
| `decisions` | `<ol data-id="d-NNN">` decisions made this session |
| `attempts` | `<ul>` of things tried that didn't work — keeps next agent from repeating |
| `open-questions` | `<ul>` of questions for the next agent / human |
| `env-snapshot` | `<pre><code>` last N lines of PTY scrollback |
| `handoff` | `hidden` until an agent is leaving; then populated and shown |

## 4. The `handoff` section

When `switch_agent` fires (or an agent exits cleanly), the agent writes its outgoing brief to `/workspace/.swe-kitty/HANDOFF-OUT.html`. The broker parses the `<section data-section="handoff">` from that file and merges it into the session memory's own `handoff` section (removing the `hidden` attribute).

The incoming agent's startup hook (`on_start`) renders the full session memory into `/workspace/.swe-kitty/HANDOFF.html`; the entrypoint script feeds it as system-prompt prefix.

### Handoff section shape
```html
<section data-section="handoff">
  <h2>Handoff brief</h2>
  <p data-fill="handoff-from">From: claude</p>
  <p data-fill="handoff-to">To: codex</p>
  <p data-fill="handoff-reason">Reason: user requested swap mid-task</p>
  <div data-fill="handoff-body">
    <p>I have finished implementing transport.rs (passes <code>cargo test</code>). Next I was going to wire session.rs to it. Watch out for the ping/pong timer — uses tokio::time::interval not tokio::time::sleep. Test fixture for the snapshot reassembly is incomplete; see <code>tests/snapshot_fixture.rs</code>.</p>
  </div>
</section>
```

## 5. Validator rules

The `swe-kitty memory` CLI validates on every write. Reject if:
- Missing `<!doctype html>`
- `data-swe-kitty-memory` absent or != `v1`
- `data-scope` not in {`project`, `session`}
- Any required section (§3) missing
- A `data-id` on a decision is not unique within its file
- A `data-fill` reference can't be resolved (project / session template only)
- Disallowed elements: `<script>`, `<iframe>`, `<object>`, `<embed>`, `<form>`, event-handler attributes (`onclick=` etc.)
- File size > 1 MiB

## 6. Editing rules

- **Single writer per session**: the broker holds a file lock (`flock(2)`) on the session HTML during writes. Agents inside containers SHOULD NOT write the session HTML directly — they emit `HANDOFF-OUT.html` and the broker merges.
- **Concurrent edits**: if a human edits the session HTML in the worktree while the agent is running, the broker detects via mtime+hash on the next checkpoint and merges by keeping the human's section content and overwriting only `meta` and `env-snapshot`.
- **Atomicity**: writes are temp-file + rename(2) within the same dir.

## 7. CLI

| Command | Effect |
|---|---|
| `swe-kitty memory init` | Scaffolds `.swe-kitty/memory/` if missing |
| `swe-kitty memory render --session <uuid>` | Emits the current session HTML to stdout |
| `swe-kitty memory checkpoint --session <uuid> --reason <str>` | Append a checkpoint entry; flush scrollback tail into `env-snapshot` |
| `swe-kitty memory handoff --session <uuid> --from <a> --to <b>` | Merge `HANDOFF-OUT.html`, mark agent swap |
| `swe-kitty memory promote --session <uuid> --decision <id>` | Copy a `data-id="d-NNN"` decision from session into project `decisions` |
| `swe-kitty memory show [--session <uuid>]` | Render plaintext to terminal |

## 8. Mobile rendering

The Chat tab has a "Memory" affordance (icon) that opens `/memory/sessions/<uuid>.html` in the in-app browser (WKWebView / WebView). Because the schema is plain HTML5 with a single stylesheet (`.swe-kitty/memory/memory.css`), no in-app renderer is needed. Dark mode honors `prefers-color-scheme`.
