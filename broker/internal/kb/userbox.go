// Phase 3a — flag-gated user-box knowledge base.
//
// Everything in this file is INERT unless the broker is started with
// --kb-experimental (or CONDUIT_KB_EXPERIMENTAL=1). When OFF, the broker's
// behavior is byte-identical to Phase 1/2: KB injection only when a workspace
// has a tracked knowledge/INDEX.md, no ingest, no box-local store. See
// docs/PLAN-knowledge-base.md "Product integration (user boxes — Phase 3)".
//
// Three privacy invariants are the whole point of this phase and are encoded
// here (a violation is silent and serious):
//
//  1. conduit NEVER edits, moves, or rewrites a file the user authored.
//     Registered sources are POINTERS ONLY (path + auto summary); the source
//     bytes are never read-modified-written.
//  2. conduit NEVER auto-commits. Agent-written entries default to the
//     gitignored box-local .conduit/knowledge/ dir; promotion to the tracked
//     knowledge/ dir is an explicit `kb promote` (the user's opt-in).
//  3. Secret-scrub (Phase 1) runs before EVERY write path, box-local included.
package kb

import (
	"bufio"
	"fmt"
	"os"
	"path/filepath"
	"regexp"
	"sort"
	"strings"
)

// indexRowRe matches an INDEX.md entry row: `| [SLUG](slug.md) | summary |`.
// Mirrors the row shape produced by buildIndex (kb.go). Group 1 is the slug as
// displayed, group 2 the one-line summary.
var indexRowRe = regexp.MustCompile(`^\|\s*\[([^\]]+)\]\([^)]+\)\s*\|\s*(.+?)\s*\|\s*$`)

// ExperimentalEnv is the env var that turns Phase 3a user-box behavior ON.
// The broker `up` command also exposes it as --kb-experimental, which simply
// sets this env so flag and env unify on a single source of truth. OFF (unset
// or falsey) is the default: Phase 1/2 behavior, unchanged.
const ExperimentalEnv = "CONDUIT_KB_EXPERIMENTAL"

// BoxLocalDir is the box-local, gitignored knowledge directory relative to a
// workspace: <workspace>/.conduit/knowledge/. Agent-written entries land here
// by default when the experimental flag is ON, so they are NEVER auto-committed
// to the user's repo.
const BoxLocalDir = ".conduit/knowledge"

// ExperimentalEnabled reports whether Phase 3a user-box behavior is active.
// Truthy values: "1", "true", "yes", "on". Anything else (including unset) is
// OFF. Mirrors the truthiness convention used elsewhere in the broker but
// defaults OFF (Phase 1/2 behavior) rather than ON.
func ExperimentalEnabled() bool {
	switch strings.ToLower(strings.TrimSpace(os.Getenv(ExperimentalEnv))) {
	case "1", "true", "yes", "on", "enable", "enabled":
		return true
	default:
		return false
	}
}

// Origin labels a knowledge item by where it lives, so injection/search can
// clearly attribute each result.
type Origin string

const (
	// OriginTracked is the git-tracked knowledge/ dir (shared with the team).
	OriginTracked Origin = "tracked"
	// OriginBoxLocal is the gitignored .conduit/knowledge/ dir (box-private).
	OriginBoxLocal Origin = "box-local"
	// OriginSourcePointer is a registered pointer to a user-authored doc
	// (README/docs/CLAUDE.md/...). conduit never edits the file it points at.
	OriginSourcePointer Origin = "source-pointer"
)

// ---------------------------------------------------------------------------
// Box-local store
// ---------------------------------------------------------------------------

// NewBoxLocalStore returns a Store operating on <workspace>/.conduit/knowledge/.
// It does NOT create the directory. The returned Store reuses ALL Phase 1
// write-path checks (schema, dedup, secret-scrub) verbatim — only the target
// directory differs from NewStore.
func NewBoxLocalStore(workspace string) *Store {
	return &Store{dir: filepath.Join(workspace, BoxLocalDir)}
}

// EnsureBoxLocalGitignore guarantees that the box-local store can never be
// auto-committed to the user's repo. It writes <workspace>/.conduit/.gitignore
// containing `*` (ignore everything under .conduit/, including itself). This is
// the robust choice over editing the workspace .gitignore: it is self-contained
// (no managed-section parsing of a file the user owns), survives even if the
// user has no top-level .gitignore, and — like every Phase 3a write — never
// touches a file the user authored. Idempotent.
//
// Returns nil and does nothing if <workspace> is empty.
func EnsureBoxLocalGitignore(workspace string) error {
	if strings.TrimSpace(workspace) == "" {
		return nil
	}
	conduitDir := filepath.Join(workspace, ".conduit")
	if err := os.MkdirAll(conduitDir, 0o755); err != nil {
		return fmt.Errorf("create .conduit dir: %w", err)
	}
	gitignorePath := filepath.Join(conduitDir, ".gitignore")
	const want = "# Managed by Conduit: box-local knowledge + state is never committed.\n*\n"
	if b, err := os.ReadFile(gitignorePath); err == nil && string(b) == want {
		return nil // already current
	}
	return os.WriteFile(gitignorePath, []byte(want), 0o644)
}

// ---------------------------------------------------------------------------
// Promote: box-local -> tracked
// ---------------------------------------------------------------------------

// PromoteResult describes the outcome of a Promote call.
type PromoteResult struct {
	Slug string
	From string // box-local source path
	To   string // tracked destination path
}

// Promote moves a box-local .conduit/knowledge/<slug>.md entry into the tracked
// knowledge/ dir — the user's EXPLICIT opt-in to share/commit it. It creates
// knowledge/ if absent (mirrors the Phase-2 mkdir-on-add behavior), refuses to
// clobber an existing tracked entry of the same slug, regenerates BOTH indexes,
// and removes the box-local copy on success. Secret-scrub is re-run on the body
// before promotion (defense in depth — a box-local file could have been edited
// by hand after it was written).
func Promote(workspace, slug string) (*PromoteResult, error) {
	if strings.TrimSpace(slug) == "" {
		return nil, fmt.Errorf("promote: slug is required")
	}
	boxStore := NewBoxLocalStore(workspace)
	trackedStore := NewStore(workspace)

	from := boxStore.EntryPath(slug)
	raw, err := os.ReadFile(from)
	if err != nil {
		return nil, fmt.Errorf("promote: box-local entry %q not found: %w", slug, err)
	}

	to := trackedStore.EntryPath(slug)
	if _, err := os.Stat(to); err == nil {
		return nil, fmt.Errorf("promote: tracked entry %q already exists at %s (edit it instead)", slug, to)
	}

	// Re-scrub before crossing into the tracked (committable) store.
	if e, perr := parseEntry(slug, string(raw)); perr == nil {
		if pattern, matched := scrubSecrets(e.Body); matched {
			return nil, fmt.Errorf("promote: refusing — body matches secret pattern %q; remove it before promoting", pattern)
		}
	}

	if err := os.MkdirAll(trackedStore.dir, 0o755); err != nil {
		return nil, fmt.Errorf("promote: create knowledge dir: %w", err)
	}
	if err := os.WriteFile(to, raw, 0o644); err != nil {
		return nil, fmt.Errorf("promote: write tracked entry: %w", err)
	}
	if err := os.Remove(from); err != nil {
		// Tracked copy already written; surface but don't fail (the entry IS
		// promoted). A stale box-local copy is harmless (it's gitignored).
		fmt.Fprintf(os.Stderr, "kb: warning: promoted %s but failed to remove box-local copy: %v\n", slug, err)
	}

	if err := trackedStore.RegenerateIndex(); err != nil {
		fmt.Fprintf(os.Stderr, "kb: warning: failed to regenerate tracked INDEX.md: %v\n", err)
	}
	// Box-local index regen is best-effort and only if the dir still has the
	// generated index (it may now be empty — RegenerateIndex handles that).
	if _, err := os.Stat(boxStore.dir); err == nil {
		if err := boxStore.RegenerateIndex(); err != nil {
			fmt.Fprintf(os.Stderr, "kb: warning: failed to regenerate box-local INDEX.md: %v\n", err)
		}
	}

	return &PromoteResult{Slug: slug, From: from, To: to}, nil
}

// ---------------------------------------------------------------------------
// Registered-source ingest (pointers only — never touches the source file)
// ---------------------------------------------------------------------------

// SourcePointer is a registered pointer to a user-authored knowledge doc.
// It carries the workspace-relative path and an auto-generated one-line
// summary. The source file's BYTES ARE NEVER MODIFIED — only read to derive
// the summary.
type SourcePointer struct {
	RelPath string // path relative to the workspace root
	Summary string // first heading or first non-empty line (one line)
}

// ingestGlobs are the workspace-relative patterns scanned for existing
// knowledge. Top-level docs, the docs/ tree, agent context files, common ADR
// dirs, and cursor rules. Kept conservative to avoid pointer noise.
var ingestCandidatePaths = []string{
	"README.md",
	"CLAUDE.md",
	"AGENTS.md",
	".cursor/rules",
}

// ingestDirGlobs are directory subtrees whose *.md files become pointers.
var ingestDirGlobs = []string{
	"docs",
	"doc",
	".cursor/rules",
	"adr",
	"docs/adr",
	"docs/decisions",
	"decisions",
}

// maxIngestPointers caps how many pointers a single ingest registers, so a doc-
// heavy repo can't blow up the injected index (the context-bloat risk in the
// plan). Pointers are ranked shortest-path-first (top-level/canonical docs win)
// then alphabetically for determinism.
const maxIngestPointers = 40

// ScanSources walks a workspace and returns registered-source pointers for the
// existing knowledge docs it finds, WITHOUT modifying any of them. It is the
// pure, testable core of `kb ingest`:
//   - explicit candidate files (README.md, CLAUDE.md, AGENTS.md, .cursor/rules)
//   - every top-level *.md (e.g. CONTRIBUTING.md, ARCHITECTURE.md)
//   - *.md anywhere under the docs/ and ADR subtrees
//
// It excludes the conduit-managed stores themselves (knowledge/,
// .conduit/knowledge/) so ingest never points at generated entries, and dedups
// by path. Results are capped at maxIngestPointers (ranked by path depth then
// name). Missing files/dirs are skipped silently.
func ScanSources(workspace string) ([]SourcePointer, error) {
	if strings.TrimSpace(workspace) == "" {
		return nil, fmt.Errorf("ingest: workspace is required")
	}
	seen := make(map[string]bool)
	var ptrs []SourcePointer

	addPath := func(rel string) {
		if seen[rel] {
			return
		}
		abs := filepath.Join(workspace, rel)
		info, err := os.Stat(abs)
		if err != nil || info.IsDir() {
			return
		}
		summary := summarizeSourceFile(abs)
		seen[rel] = true
		ptrs = append(ptrs, SourcePointer{RelPath: rel, Summary: summary})
	}

	// Explicit, named candidate files.
	for _, rel := range ingestCandidatePaths {
		addPath(rel)
	}

	// Top-level *.md files.
	if entries, err := os.ReadDir(workspace); err == nil {
		for _, e := range entries {
			if e.IsDir() || !strings.HasSuffix(e.Name(), ".md") {
				continue
			}
			addPath(e.Name())
		}
	}

	// *.md under documented subtrees.
	for _, sub := range ingestDirGlobs {
		root := filepath.Join(workspace, sub)
		_ = filepath.WalkDir(root, func(path string, d os.DirEntry, err error) error {
			if err != nil {
				return nil // skip unreadable dirs
			}
			if d.IsDir() {
				return nil
			}
			name := d.Name()
			// .cursor/rules may be a single file (handled above) or a dir of
			// rule files of various extensions; otherwise require .md.
			if sub != ".cursor/rules" && !strings.HasSuffix(name, ".md") {
				return nil
			}
			rel, rerr := filepath.Rel(workspace, path)
			if rerr != nil {
				return nil
			}
			addPath(filepath.ToSlash(rel))
			return nil
		})
	}

	// Never point at conduit's own generated stores.
	ptrs = filterManagedPaths(ptrs)

	// Rank: shallower paths first (canonical top-level docs win the cap), then
	// alphabetical for determinism.
	sort.Slice(ptrs, func(i, j int) bool {
		di := strings.Count(ptrs[i].RelPath, "/")
		dj := strings.Count(ptrs[j].RelPath, "/")
		if di != dj {
			return di < dj
		}
		return ptrs[i].RelPath < ptrs[j].RelPath
	})
	if len(ptrs) > maxIngestPointers {
		ptrs = ptrs[:maxIngestPointers]
	}
	return ptrs, nil
}

// filterManagedPaths drops pointers that fall inside conduit-managed stores so
// ingest never registers a pointer to a generated INDEX.md or entry file.
func filterManagedPaths(ptrs []SourcePointer) []SourcePointer {
	var out []SourcePointer
	// Note on AGENTS.md: conduit DOES manage an awareness section inside it
	// (conduitprompt.go), but that is unrelated to KB pointers — we register it
	// as a readable pointer and never rewrite it for KB purposes.
	for _, p := range ptrs {
		slash := filepath.ToSlash(p.RelPath)
		if strings.HasPrefix(slash, KnowledgeDir+"/") ||
			strings.HasPrefix(slash, BoxLocalDir+"/") ||
			strings.HasPrefix(slash, ".conduit/") {
			continue
		}
		out = append(out, p)
	}
	return out
}

// summarizeSourceFile extracts a one-line summary from a doc WITHOUT modifying
// it: the first markdown heading text (stripped of leading '#'), else the first
// non-empty, non-frontmatter line. Read-only. Exported variant is
// SummarizeFirstLine for unit testing the pure extraction.
func summarizeSourceFile(absPath string) string {
	f, err := os.Open(absPath)
	if err != nil {
		return "(unreadable)"
	}
	defer f.Close()
	var lines []string
	scanner := bufio.NewScanner(f)
	scanner.Buffer(make([]byte, 0, 64*1024), 1024*1024)
	for scanner.Scan() && len(lines) < 200 {
		lines = append(lines, scanner.Text())
	}
	return SummarizeFirstLine(strings.Join(lines, "\n"))
}

// SummarizeFirstLine is the PURE summary extractor: given a document's text it
// returns the first markdown heading (without '#'), else the first non-empty
// line that isn't YAML frontmatter or an HTML comment. Truncated to 120 chars.
// Exported for unit testing.
func SummarizeFirstLine(content string) string {
	scanner := bufio.NewScanner(strings.NewReader(content))
	inFrontmatter := false
	lineNum := 0
	var fallback string
	for scanner.Scan() {
		raw := scanner.Text()
		line := strings.TrimSpace(raw)
		lineNum++
		// YAML frontmatter fence: skip the block entirely.
		if lineNum == 1 && line == "---" {
			inFrontmatter = true
			continue
		}
		if inFrontmatter {
			if line == "---" || line == "..." {
				inFrontmatter = false
			}
			continue
		}
		if line == "" {
			continue
		}
		if strings.HasPrefix(line, "<!--") {
			continue
		}
		if strings.HasPrefix(line, "#") {
			heading := strings.TrimSpace(strings.TrimLeft(line, "#"))
			if heading != "" {
				return truncateSummary(heading)
			}
			continue
		}
		if fallback == "" {
			fallback = line
		}
	}
	if fallback != "" {
		return truncateSummary(fallback)
	}
	return "(no summary)"
}

func truncateSummary(s string) string {
	if len(s) > 120 {
		return s[:117] + "..."
	}
	return s
}

// SourcesFile is the human-readable registry of pointers written under the
// box-local store by `kb ingest`. It is purely a readable artifact: the
// authoritative pointer set for injection/search is re-scanned live by
// MergedIndexForWorkspace, so this file going stale never produces a wrong
// injection. It lives inside the gitignored .conduit/ tree, so it is never
// committed to the user's repo.
const SourcesFile = "SOURCES.md"

// IngestResult describes the outcome of an Ingest run.
type IngestResult struct {
	Pointers []SourcePointer
	Path     string // path to the written SOURCES.md (box-local)
}

// Ingest scans the workspace for existing knowledge docs and registers each as
// a POINTER (path + auto summary) under the box-local store. It NEVER reads-
// modifies-writes any source file (invariant 1). It ensures the box-local
// gitignore exists (invariant 2) before writing, so the registry it creates is
// itself never committed. Returns the registered pointers.
func Ingest(workspace string) (*IngestResult, error) {
	ptrs, err := ScanSources(workspace)
	if err != nil {
		return nil, err
	}
	if err := EnsureBoxLocalGitignore(workspace); err != nil {
		return nil, err
	}
	store := NewBoxLocalStore(workspace)
	if err := os.MkdirAll(store.dir, 0o755); err != nil {
		return nil, fmt.Errorf("ingest: create box-local dir: %w", err)
	}
	path := filepath.Join(store.dir, SourcesFile)
	var sb strings.Builder
	sb.WriteString("# Registered sources (Conduit ingest — pointers only)\n\n")
	sb.WriteString("Conduit indexed these existing docs as POINTERS. It never edits them.\n\n")
	sb.WriteString("| Source | Summary |\n")
	sb.WriteString("|--------|----------|\n")
	for _, p := range ptrs {
		sb.WriteString(fmt.Sprintf("| %s | %s |\n", p.RelPath, p.Summary))
	}
	if err := os.WriteFile(path, []byte(sb.String()), 0o644); err != nil {
		return nil, fmt.Errorf("ingest: write SOURCES.md: %w", err)
	}
	return &IngestResult{Pointers: ptrs, Path: path}, nil
}

// ---------------------------------------------------------------------------
// Merged, origin-labeled view for injection + search
// ---------------------------------------------------------------------------

// IndexLine is one merged index entry with its origin attribution.
type IndexLine struct {
	Slug    string
	Summary string
	Origin  Origin
}

// maxMergedLines caps the merged injected index so a doc-heavy box can't bloat
// every session's context (plan's context-bloat risk). Tracked entries are kept
// first (most-curated), then box-local, then source pointers.
const maxMergedLines = 80

// MergeOrigins builds a single ranked, origin-labeled index from the three
// sources. Tracked entries rank first, then box-local, then source pointers;
// within each tier order is preserved as given. The total is capped at
// maxMergedLines. Pure — the caller supplies already-extracted slices.
func MergeOrigins(tracked, boxLocal []IndexLine, pointers []SourcePointer) []IndexLine {
	out := make([]IndexLine, 0, len(tracked)+len(boxLocal)+len(pointers))
	for _, t := range tracked {
		t.Origin = OriginTracked
		out = append(out, t)
	}
	for _, b := range boxLocal {
		b.Origin = OriginBoxLocal
		out = append(out, b)
	}
	for _, p := range pointers {
		out = append(out, IndexLine{Slug: p.RelPath, Summary: p.Summary, Origin: OriginSourcePointer})
	}
	if len(out) > maxMergedLines {
		out = out[:maxMergedLines]
	}
	return out
}

// indexLinesFromStore parses a Store's INDEX.md table into IndexLine values
// (origin set by the caller via MergeOrigins). Returns nil when the store has
// no index. Best-effort: malformed rows are skipped.
func indexLinesFromStore(s *Store) []IndexLine {
	raw, err := s.ReadIndex()
	if err != nil {
		return nil
	}
	var lines []IndexLine
	scanner := bufio.NewScanner(strings.NewReader(raw))
	for scanner.Scan() {
		m := indexRowRe.FindStringSubmatch(scanner.Text())
		if m == nil {
			continue
		}
		slug := strings.TrimSpace(m[1])
		if slug == "" || slug == "Entry" {
			continue
		}
		lines = append(lines, IndexLine{Slug: slug, Summary: strings.TrimSpace(m[2])})
	}
	return lines
}

// SourceExists reports whether a workspace has ANY KB source under the
// experimental model: a tracked entry, a box-local entry, OR an ingestable doc.
// This is the experimental-ON self-gate ("useful day one on any repo"). When
// the flag is OFF the caller must NOT use this — it falls back to the Phase-1
// tracked-INDEX.md-only gate.
func SourceExists(workspace string) bool {
	if NewStore(workspace).Exists() {
		return true
	}
	if NewBoxLocalStore(workspace).Exists() {
		return true
	}
	ptrs, err := ScanSources(workspace)
	return err == nil && len(ptrs) > 0
}

// MergedIndexForWorkspace assembles the merged, origin-labeled index for a
// workspace from all three sources. It is used (only when the experimental flag
// is ON) by the spawn-injection block and `kb list`. Pointers are scanned fresh
// each call (cheap; ranked + capped by ScanSources).
func MergedIndexForWorkspace(workspace string) []IndexLine {
	tracked := indexLinesFromStore(NewStore(workspace))
	boxLocal := indexLinesFromStore(NewBoxLocalStore(workspace))
	ptrs, _ := ScanSources(workspace)
	return MergeOrigins(tracked, boxLocal, ptrs)
}

// RenderMergedIndex formats merged index lines as a labeled markdown table
// suitable for injection. Origin is shown so the agent knows whether a hit is a
// shared/tracked fact, a box-private note, or a pointer into the user's docs.
func RenderMergedIndex(lines []IndexLine) string {
	var sb strings.Builder
	sb.WriteString("| Entry | Origin | Summary |\n")
	sb.WriteString("|-------|--------|----------|\n")
	for _, l := range lines {
		sb.WriteString(fmt.Sprintf("| %s | %s | %s |\n", l.Slug, l.Origin, l.Summary))
	}
	return sb.String()
}
