package main

import (
	"flag"
	"fmt"
	"io"
	"os"
	"strings"

	"github.com/nikhilsh/conduit/broker/internal/kb"
)

// runKB dispatches the `conduit-broker kb <sub> ...` subcommand tree.
// It operates on a workspace's knowledge/ directory. The default workspace
// is the current working directory; --dir / --workspace overrides this.
//
// --dir / --workspace may appear BEFORE or AFTER the subcommand name; each
// subcommand parses its own FlagSet so flags in any position are recognized.
func runKB(args []string) int {
	// Top-level FlagSet: parse flags that appear BEFORE the subcommand word.
	// This handles `kb --dir X list` style.
	topFS := flag.NewFlagSet("kb", flag.ContinueOnError)
	topDir := topFS.String("dir", "", "workspace directory (default: cwd)")
	topWorkspace := topFS.String("workspace", "", "alias for --dir")
	topFS.Usage = func() {
		fmt.Fprintln(os.Stderr, `conduit-broker kb — knowledge-base CLI

Usage:
  conduit-broker kb [--dir <workspace>] <sub> [args...]

Subcommands:
  list              print the knowledge index
  get <slug>        print knowledge/<slug>.md (or .conduit/knowledge/<slug>.md)
  search <query>    case-insensitive search over entries
  add               add a new entry (use --title, --tags, --scope, --body)
  lint              validate structural integrity of the knowledge base
  ingest            register existing docs (README/docs/CLAUDE.md/...) as pointers [experimental]
  promote <slug>    move a box-local entry into the tracked knowledge/ dir [experimental]

Options:`)
		topFS.PrintDefaults()
	}
	if err := topFS.Parse(args); err != nil {
		return 2
	}
	remaining := topFS.Args()
	if len(remaining) == 0 {
		topFS.Usage()
		return 2
	}

	// resolveDir picks from top-level flags first, then falls back to the
	// per-subcommand dir value (passed in after sub-FlagSet parsing).
	resolveDir := func(subDir string) (string, int) {
		wsDir := *topDir
		if wsDir == "" {
			wsDir = *topWorkspace
		}
		if wsDir == "" {
			wsDir = subDir
		}
		if wsDir == "" {
			cwd, err := os.Getwd()
			if err != nil {
				fmt.Fprintf(os.Stderr, "kb: cannot determine cwd: %v\n", err)
				return "", 1
			}
			wsDir = cwd
		}
		return wsDir, 0
	}

	sub := remaining[0]
	subArgs := remaining[1:]

	switch sub {
	case "list":
		return kbList(subArgs, resolveDir)
	case "get":
		return kbGet(subArgs, resolveDir)
	case "search":
		return kbSearch(subArgs, resolveDir)
	case "add":
		return kbAdd(subArgs, resolveDir)
	case "lint":
		return kbLint(subArgs, resolveDir)
	case "ingest":
		return kbIngest(subArgs, resolveDir)
	case "promote":
		return kbPromote(subArgs, resolveDir)
	default:
		fmt.Fprintf(os.Stderr, "kb: unknown subcommand %q\n", sub)
		return 2
	}
}

// dirResolver is a function that takes a subcommand-level dir string and
// returns the resolved workspace dir + exit code (0 = ok).
type dirResolver func(subDir string) (string, int)

func kbList(args []string, resolve dirResolver) int {
	fs := flag.NewFlagSet("kb list", flag.ContinueOnError)
	dir := fs.String("dir", "", "workspace directory (default: cwd)")
	workspace := fs.String("workspace", "", "alias for --dir")
	_ = fs.Parse(args)

	subDir := *dir
	if subDir == "" {
		subDir = *workspace
	}
	wsDir, code := resolve(subDir)
	if code != 0 {
		return code
	}

	// Phase 3a (flag ON): list spans all three origins, clearly labeled.
	if kb.ExperimentalEnabled() {
		if !kb.SourceExists(wsDir) {
			fmt.Fprintln(os.Stderr, "kb: no knowledge sources found in workspace (no tracked entries, box-local entries, or ingestable docs)")
			return 1
		}
		merged := kb.MergedIndexForWorkspace(wsDir)
		fmt.Print(kb.RenderMergedIndex(merged))
		return 0
	}

	store := kb.NewStore(wsDir)
	if !store.Exists() {
		fmt.Fprintln(os.Stderr, "kb: no knowledge/INDEX.md found in workspace (knowledge base not initialized)")
		return 1
	}
	idx, err := store.ReadIndex()
	if err != nil {
		fmt.Fprintf(os.Stderr, "kb: read INDEX.md: %v\n", err)
		return 1
	}
	fmt.Print(idx)
	return 0
}

func kbGet(args []string, resolve dirResolver) int {
	fs := flag.NewFlagSet("kb get", flag.ContinueOnError)
	dir := fs.String("dir", "", "workspace directory (default: cwd)")
	workspace := fs.String("workspace", "", "alias for --dir")
	_ = fs.Parse(args)

	subDir := *dir
	if subDir == "" {
		subDir = *workspace
	}
	wsDir, code := resolve(subDir)
	if code != 0 {
		return code
	}

	remaining := fs.Args()
	if len(remaining) == 0 {
		fmt.Fprintln(os.Stderr, "kb get: requires a slug argument")
		return 2
	}
	slug := remaining[0]

	// Phase 3a (flag ON): a slug may live in the tracked store OR the box-local
	// store. Prefer tracked (curated/shared), fall back to box-local.
	stores := []*kb.Store{kb.NewStore(wsDir)}
	if kb.ExperimentalEnabled() {
		stores = append(stores, kb.NewBoxLocalStore(wsDir))
	}
	for _, store := range stores {
		raw, err := os.ReadFile(store.EntryPath(slug))
		if err != nil {
			continue
		}
		fmt.Print(string(raw))
		return 0
	}
	fmt.Fprintf(os.Stderr, "kb get: entry %q not found\n", slug)
	return 1
}

func kbSearch(args []string, resolve dirResolver) int {
	fs := flag.NewFlagSet("kb search", flag.ContinueOnError)
	dir := fs.String("dir", "", "workspace directory (default: cwd)")
	workspace := fs.String("workspace", "", "alias for --dir")
	_ = fs.Parse(args)

	subDir := *dir
	if subDir == "" {
		subDir = *workspace
	}
	wsDir, code := resolve(subDir)
	if code != 0 {
		return code
	}
	store := kb.NewStore(wsDir)

	remaining := fs.Args()
	if len(remaining) == 0 {
		fmt.Fprintln(os.Stderr, "kb search: requires a query argument")
		return 2
	}
	query := strings.Join(remaining, " ")

	// Phase 3a (flag ON): search spans tracked + box-local entries AND the
	// registered-source pointers, each labeled by origin.
	if kb.ExperimentalEnabled() {
		var out []string
		if m, err := kb.NewStore(wsDir).Search(query); err == nil {
			for _, line := range m {
				out = append(out, "[tracked] "+line)
			}
		}
		if m, err := kb.NewBoxLocalStore(wsDir).Search(query); err == nil {
			for _, line := range m {
				out = append(out, "[box-local] "+line)
			}
		}
		lq := strings.ToLower(query)
		if ptrs, err := kb.ScanSources(wsDir); err == nil {
			for _, p := range ptrs {
				if strings.Contains(strings.ToLower(p.RelPath+" "+p.Summary), lq) {
					out = append(out, "[source-pointer] "+p.RelPath+" — "+p.Summary)
				}
			}
		}
		if len(out) == 0 {
			fmt.Println("(no matches)")
			return 0
		}
		for _, line := range out {
			fmt.Println(line)
		}
		return 0
	}

	if !store.Exists() {
		fmt.Fprintln(os.Stderr, "kb: no knowledge/INDEX.md found in workspace")
		return 1
	}
	matches, err := store.Search(query)
	if err != nil {
		fmt.Fprintf(os.Stderr, "kb search: %v\n", err)
		return 1
	}
	if len(matches) == 0 {
		fmt.Println("(no matches)")
		return 0
	}
	for _, m := range matches {
		fmt.Println(m)
	}
	return 0
}

func kbAdd(args []string, resolve dirResolver) int {
	fs := flag.NewFlagSet("kb add", flag.ContinueOnError)
	dir := fs.String("dir", "", "workspace directory (default: cwd)")
	workspace := fs.String("workspace", "", "alias for --dir")
	title := fs.String("title", "", "entry title (required)")
	tagsStr := fs.String("tags", "", "comma-separated tags (required, e.g. broker,ops)")
	scope := fs.String("scope", "repo", "scope: repo or session")
	body := fs.String("body", "", "entry body (or omit to read from stdin)")
	fs.Usage = func() {
		fmt.Fprintln(os.Stderr, `conduit-broker kb add — add a new knowledge entry

Usage:
  conduit-broker kb add --title "..." --tags "tag1,tag2" [--scope repo] [--body "..."]
  conduit-broker kb add --dir /path/to/workspace --title "..." --tags "tag1,tag2"

If --body is omitted, the entry body is read from stdin.`)
		fs.PrintDefaults()
	}
	if err := fs.Parse(args); err != nil {
		return 2
	}

	subDir := *dir
	if subDir == "" {
		subDir = *workspace
	}
	wsDir, code := resolve(subDir)
	if code != 0 {
		return code
	}
	// Phase 3a (flag ON): agent-written entries default to the box-local,
	// gitignored .conduit/knowledge/ store so they are NEVER auto-committed to
	// the user's repo. The user opts in to sharing via `kb promote`. Flag OFF:
	// writes to the tracked knowledge/ dir exactly as Phase 1.
	var store *kb.Store
	if kb.ExperimentalEnabled() {
		store = kb.NewBoxLocalStore(wsDir)
		if err := kb.EnsureBoxLocalGitignore(wsDir); err != nil {
			fmt.Fprintf(os.Stderr, "kb add: ensure .conduit gitignore: %v\n", err)
			return 1
		}
	} else {
		store = kb.NewStore(wsDir)
	}

	entryBody := *body
	if strings.TrimSpace(entryBody) == "" {
		// Read from stdin.
		b, err := io.ReadAll(os.Stdin)
		if err != nil {
			fmt.Fprintf(os.Stderr, "kb add: read stdin: %v\n", err)
			return 1
		}
		entryBody = string(b)
	}

	var tags []string
	for _, t := range strings.Split(*tagsStr, ",") {
		t = strings.TrimSpace(t)
		if t != "" {
			tags = append(tags, t)
		}
	}

	result, err := store.Add(kb.AddRequest{
		Title: *title,
		Tags:  tags,
		Scope: *scope,
		Body:  entryBody,
	})
	if err != nil {
		fmt.Fprintf(os.Stderr, "kb add: %v\n", err)
		return 1
	}
	fmt.Println(result.Message)
	if result.Staged {
		fmt.Printf("Staged path: %s\n", result.Path)
		return 0
	}
	fmt.Printf("Entry: %s\n", result.Path)
	return 0
}

func kbLint(args []string, resolve dirResolver) int {
	fs := flag.NewFlagSet("kb lint", flag.ContinueOnError)
	dir := fs.String("dir", "", "workspace directory (default: cwd)")
	workspace := fs.String("workspace", "", "alias for --dir")
	fs.Usage = func() {
		fmt.Fprintln(os.Stderr, `conduit-broker kb lint — validate knowledge base structural integrity

Usage:
  conduit-broker kb lint [--dir <workspace>]

Checks:
  - INDEX.md sync: every entry file appears in INDEX.md and every INDEX reference has a file.
  - Valid frontmatter: title, >=1 tag, status (hard errors).
  - No duplicate slugs (case-insensitive).
  - No broken relative cross-links ([TEXT](X.md) pointing at missing entries).
  - WARN: entries with heavily-overlapping titles+tags (structural heuristic only;
    semantic/contradiction detection is out of scope -- needs an LLM pass).

Exits non-zero on hard errors. Warnings are informational only.`)
		fs.PrintDefaults()
	}
	if err := fs.Parse(args); err != nil {
		return 2
	}

	subDir := *dir
	if subDir == "" {
		subDir = *workspace
	}
	wsDir, code := resolve(subDir)
	if code != 0 {
		return code
	}

	res, err := kb.Lint(wsDir)
	if err != nil {
		fmt.Fprintf(os.Stderr, "kb lint: %v\n", err)
		return 1
	}

	for _, w := range res.Warnings {
		fmt.Fprintf(os.Stdout, "WARN  %s\n", w)
	}
	for _, e := range res.Errors {
		fmt.Fprintf(os.Stderr, "ERROR %s\n", e)
	}

	fmt.Printf("\nkb lint: %s\n", res.Summary())

	if !res.OK() {
		return 1
	}
	return 0
}

// kbIngest (Phase 3a) scans the workspace for existing knowledge docs and
// registers each as a POINTER (path + auto summary) under the box-local store.
// It NEVER edits a source file. Available only when the experimental flag is
// ON; gated here so OFF behavior is unchanged.
func kbIngest(args []string, resolve dirResolver) int {
	fs := flag.NewFlagSet("kb ingest", flag.ContinueOnError)
	dir := fs.String("dir", "", "workspace directory (default: cwd)")
	workspace := fs.String("workspace", "", "alias for --dir")
	_ = fs.Parse(args)

	if !kb.ExperimentalEnabled() {
		fmt.Fprintln(os.Stderr, "kb ingest: experimental user-box KB is OFF (set --kb-experimental / CONDUIT_KB_EXPERIMENTAL=1)")
		return 1
	}

	subDir := *dir
	if subDir == "" {
		subDir = *workspace
	}
	wsDir, code := resolve(subDir)
	if code != 0 {
		return code
	}
	res, err := kb.Ingest(wsDir)
	if err != nil {
		fmt.Fprintf(os.Stderr, "kb ingest: %v\n", err)
		return 1
	}
	fmt.Printf("registered %d source pointer(s) (pointers only — no source file modified)\n", len(res.Pointers))
	for _, p := range res.Pointers {
		fmt.Printf("  %s — %s\n", p.RelPath, p.Summary)
	}
	fmt.Printf("registry: %s\n", res.Path)
	return 0
}

// kbPromote (Phase 3a) moves a box-local entry into the tracked knowledge/ dir
// — the user's explicit opt-in to share/commit it. Available only when the
// experimental flag is ON.
func kbPromote(args []string, resolve dirResolver) int {
	fs := flag.NewFlagSet("kb promote", flag.ContinueOnError)
	dir := fs.String("dir", "", "workspace directory (default: cwd)")
	workspace := fs.String("workspace", "", "alias for --dir")
	_ = fs.Parse(args)

	if !kb.ExperimentalEnabled() {
		fmt.Fprintln(os.Stderr, "kb promote: experimental user-box KB is OFF (set --kb-experimental / CONDUIT_KB_EXPERIMENTAL=1)")
		return 1
	}

	subDir := *dir
	if subDir == "" {
		subDir = *workspace
	}
	wsDir, code := resolve(subDir)
	if code != 0 {
		return code
	}
	remaining := fs.Args()
	if len(remaining) == 0 {
		fmt.Fprintln(os.Stderr, "kb promote: requires a slug argument")
		return 2
	}
	res, err := kb.Promote(wsDir, remaining[0])
	if err != nil {
		fmt.Fprintf(os.Stderr, "kb promote: %v\n", err)
		return 1
	}
	fmt.Printf("promoted %s: %s -> %s\n", res.Slug, res.From, res.To)
	fmt.Println("(now tracked; commit it to share with your team)")
	return 0
}
