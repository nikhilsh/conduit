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
func runKB(args []string) int {
	fs := flag.NewFlagSet("kb", flag.ContinueOnError)
	dir := fs.String("dir", "", "workspace directory (default: cwd)")
	workspace := fs.String("workspace", "", "alias for --dir")
	fs.Usage = func() {
		fmt.Fprintln(os.Stderr, `conduit-broker kb — knowledge-base CLI

Usage:
  conduit-broker kb [--dir <workspace>] <sub> [args...]

Subcommands:
  list              print INDEX.md
  get <slug>        print knowledge/<slug>.md
  search <query>    case-insensitive search over entries
  add               add a new entry (use --title, --tags, --scope, --body)

Options:`)
		fs.PrintDefaults()
	}
	if err := fs.Parse(args); err != nil {
		return 2
	}
	remaining := fs.Args()
	if len(remaining) == 0 {
		fs.Usage()
		return 2
	}

	// Resolve workspace directory.
	wsDir := *dir
	if wsDir == "" {
		wsDir = *workspace
	}
	if wsDir == "" {
		cwd, err := os.Getwd()
		if err != nil {
			fmt.Fprintf(os.Stderr, "kb: cannot determine cwd: %v\n", err)
			return 1
		}
		wsDir = cwd
	}

	store := kb.NewStore(wsDir)

	sub := remaining[0]
	subArgs := remaining[1:]

	switch sub {
	case "list":
		return kbList(store, subArgs)
	case "get":
		return kbGet(store, subArgs)
	case "search":
		return kbSearch(store, subArgs)
	case "add":
		return kbAdd(store, subArgs)
	default:
		fmt.Fprintf(os.Stderr, "kb: unknown subcommand %q\n", sub)
		return 2
	}
}

func kbList(store *kb.Store, args []string) int {
	_ = args // no flags for list
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

func kbGet(store *kb.Store, args []string) int {
	if len(args) == 0 {
		fmt.Fprintln(os.Stderr, "kb get: requires a slug argument")
		return 2
	}
	slug := args[0]
	e, err := store.ReadEntry(slug)
	if err != nil {
		fmt.Fprintf(os.Stderr, "kb get: %v\n", err)
		return 1
	}
	// Re-read the raw file for faithful output (includes frontmatter).
	raw, err := os.ReadFile(store.EntryPath(slug))
	if err != nil {
		// Fall back to reconstructed output.
		fmt.Printf("# %s\n\n", e.Title)
		fmt.Print(e.Body)
		return 0
	}
	fmt.Print(string(raw))
	return 0
}

func kbSearch(store *kb.Store, args []string) int {
	if len(args) == 0 {
		fmt.Fprintln(os.Stderr, "kb search: requires a query argument")
		return 2
	}
	query := strings.Join(args, " ")
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

func kbAdd(store *kb.Store, args []string) int {
	fs := flag.NewFlagSet("kb add", flag.ContinueOnError)
	title := fs.String("title", "", "entry title (required)")
	tagsStr := fs.String("tags", "", "comma-separated tags (required, e.g. broker,ops)")
	scope := fs.String("scope", "repo", "scope: repo or session")
	body := fs.String("body", "", "entry body (or omit to read from stdin)")
	fs.Usage = func() {
		fmt.Fprintln(os.Stderr, `conduit-broker kb add — add a new knowledge entry

Usage:
  conduit-broker kb add --title "..." --tags "tag1,tag2" [--scope repo] [--body "..."]

If --body is omitted, the entry body is read from stdin.`)
		fs.PrintDefaults()
	}
	if err := fs.Parse(args); err != nil {
		return 2
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
