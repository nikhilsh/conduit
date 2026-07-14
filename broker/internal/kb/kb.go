// Package kb implements the conduit knowledge-base store and write-path
// checks. It operates on a workspace's knowledge/ directory containing an
// INDEX.md and individual <slug>.md entry files.
//
// The package is intentionally side-effect-free in its pure functions
// (slug generation, dedup checks, secret scrub, INDEX regeneration) so
// they can be unit-tested without a real filesystem.
package kb

import (
	"bufio"
	"fmt"
	"os"
	"path/filepath"
	"regexp"
	"sort"
	"strings"
	"time"
	"unicode"
)

// KnowledgeDir is the subdirectory name within a workspace that holds entries.
const KnowledgeDir = "knowledge"

// IndexFile is the name of the generated index within KnowledgeDir.
const IndexFile = "INDEX.md"

// StagingDir is the subdirectory within KnowledgeDir used when a conflict
// prevents writing to the main store.
const StagingDir = "_staging"

// MaxIndexLines is the maximum number of INDEX.md lines injected into agent
// context. Lines beyond this cap are truncated with a note.
const MaxIndexLines = 120

// MaxIndexBytes is the maximum INDEX.md bytes injected into agent context.
const MaxIndexBytes = 4096

// Entry holds the parsed frontmatter + body of a knowledge entry.
type Entry struct {
	Slug   string
	Title  string
	Tags   []string
	Scope  string
	Source string
	Status string
	Body   string
}

// Store is a handle to a workspace's knowledge/ directory.
type Store struct {
	dir string // absolute path to <workspace>/knowledge/
}

// NewStore returns a Store operating on <workspace>/knowledge/.
// It does NOT create the directory.
func NewStore(workspace string) *Store {
	return &Store{dir: filepath.Join(workspace, KnowledgeDir)}
}

// Dir returns the absolute path to the knowledge/ directory.
func (s *Store) Dir() string { return s.dir }

// IndexPath returns the absolute path to INDEX.md.
func (s *Store) IndexPath() string { return filepath.Join(s.dir, IndexFile) }

// Exists reports whether the knowledge directory and INDEX.md both exist.
// Used as the self-gate: no knowledge/INDEX.md => KB section is suppressed.
func (s *Store) Exists() bool {
	_, err := os.Stat(s.IndexPath())
	return err == nil
}

// ReadIndex returns the raw contents of INDEX.md, or an error if it cannot
// be read.
func (s *Store) ReadIndex() (string, error) {
	b, err := os.ReadFile(s.IndexPath())
	if err != nil {
		return "", err
	}
	return string(b), nil
}

// IndexForInjection returns the index contents suitable for injecting into an
// agent's context. It caps to MaxIndexLines / MaxIndexBytes and appends a
// truncation note when needed.
func (s *Store) IndexForInjection() (string, error) {
	raw, err := s.ReadIndex()
	if err != nil {
		return "", err
	}
	return truncateForInjection(raw), nil
}

// TruncateForInjection caps raw index content to MaxIndexLines / MaxIndexBytes.
// Exported for unit testing.
func TruncateForInjection(raw string) string {
	return truncateForInjection(raw)
}

func truncateForInjection(raw string) string {
	if len(raw) <= MaxIndexBytes {
		lines := strings.Count(raw, "\n")
		if lines <= MaxIndexLines {
			return raw
		}
	}
	lines := strings.Split(raw, "\n")
	var kept []string
	total := 0
	truncated := false
	for i, line := range lines {
		if i >= MaxIndexLines {
			truncated = true
			break
		}
		// +1 for the newline
		if total+len(line)+1 > MaxIndexBytes {
			truncated = true
			break
		}
		kept = append(kept, line)
		total += len(line) + 1
	}
	result := strings.Join(kept, "\n")
	if truncated {
		result += "\n\n[INDEX truncated; run `conduit-broker kb list` for the full index]"
	}
	return result
}

// EntryPath returns the path for a given slug.
func (s *Store) EntryPath(slug string) string {
	return filepath.Join(s.dir, slug+".md")
}

// ReadEntry reads and parses the entry at knowledge/<slug>.md.
func (s *Store) ReadEntry(slug string) (*Entry, error) {
	path := s.EntryPath(slug)
	b, err := os.ReadFile(path)
	if err != nil {
		return nil, fmt.Errorf("entry %q not found: %w", slug, err)
	}
	e, err := parseEntry(slug, string(b))
	if err != nil {
		return nil, fmt.Errorf("entry %q: %w", slug, err)
	}
	return e, nil
}

// ListEntries returns all entry slugs (filenames without .md extension,
// excluding INDEX.md and files under _staging/).
func (s *Store) ListEntries() ([]string, error) {
	entries, err := os.ReadDir(s.dir)
	if err != nil {
		return nil, err
	}
	var slugs []string
	for _, e := range entries {
		if e.IsDir() {
			continue
		}
		name := e.Name()
		if !strings.HasSuffix(name, ".md") {
			continue
		}
		slug := strings.TrimSuffix(name, ".md")
		if slug == "INDEX" || slug == "SOURCES" {
			// INDEX.md is the generated index; SOURCES.md is the box-local
			// registered-sources registry (Phase 3a) — neither is an entry.
			continue
		}
		slugs = append(slugs, slug)
	}
	sort.Strings(slugs)
	return slugs, nil
}

// Search performs a case-insensitive grep over entry titles, tags, and bodies.
// It returns matching "slug — summary" lines from the index.
func (s *Store) Search(query string) ([]string, error) {
	if query == "" {
		return nil, fmt.Errorf("search query must be non-empty")
	}
	lower := strings.ToLower(query)

	slugs, err := s.ListEntries()
	if err != nil {
		return nil, err
	}

	// Build a slug -> one-line summary map from INDEX.md for nicer output.
	summaries := indexSummaries(s.IndexPath())

	var matches []string
	for _, slug := range slugs {
		path := s.EntryPath(slug)
		b, err := os.ReadFile(path)
		if err != nil {
			continue
		}
		content := strings.ToLower(string(b))
		if strings.Contains(content, lower) {
			line := slug
			upperSlug := strings.ToUpper(slug)
			if sum, ok := summaries[upperSlug]; ok {
				line = slug + " — " + sum
			}
			matches = append(matches, line)
		}
	}
	return matches, nil
}

// indexSummaries parses the INDEX.md table to build a map of
// UPPERCASE-SLUG -> summary string. Best-effort; returns empty map on error.
func indexSummaries(indexPath string) map[string]string {
	b, err := os.ReadFile(indexPath)
	if err != nil {
		return nil
	}
	m := make(map[string]string)
	scanner := bufio.NewScanner(strings.NewReader(string(b)))
	// Matches a markdown table row: | [SLUG](SLUG.md) | summary |
	rowRe := regexp.MustCompile(`^\|\s*\[([A-Z0-9_-]+)\]\([^)]+\)\s*\|\s*(.+?)\s*\|`)
	for scanner.Scan() {
		line := scanner.Text()
		if m2 := rowRe.FindStringSubmatch(line); m2 != nil {
			m[m2[1]] = strings.TrimSpace(m2[2])
		}
	}
	return m
}

// AddRequest holds the parameters for adding a new KB entry.
type AddRequest struct {
	Title string
	Tags  []string
	Scope string
	Body  string
}

// AddResult describes the outcome of an Add call.
type AddResult struct {
	Slug    string
	Path    string
	Staged  bool   // true when written to _staging/ due to a slug conflict
	Message string // human-readable outcome
}

// Add validates, writes, and indexes a new KB entry. It runs schema, dedup,
// and secret-scrub checks before writing.
//
// If knowledge/ does not exist yet, Add creates it (and, via RegenerateIndex
// below, a fresh INDEX.md) rather than erroring -- the first `kb add` in a
// repo bootstraps the knowledge base instead of requiring a separate init
// step. This is intentional beyond convenience: prompt injection
// (conduitprompt.go) self-gates on <workspace>/knowledge/INDEX.md existing,
// so a fresh repo's first kb add is also what flips awareness-injection ON
// for that workspace. That's the desired Phase-3 init behavior, not a side
// effect to guard against.
func (s *Store) Add(req AddRequest) (*AddResult, error) {
	// Schema checks.
	if err := validateSchema(req); err != nil {
		return nil, err
	}

	slug := MakeSlug(req.Title)

	// Dedup checks.
	if conflict, err := s.checkDedup(slug, req.Title); err != nil {
		return nil, err
	} else if conflict != "" {
		return nil, fmt.Errorf("duplicate entry: an entry with slug %q already exists at %s\nEdit that entry instead of adding a new one", slug, conflict)
	}

	// Secret scrub.
	if pattern, matched := scrubSecrets(req.Body); matched {
		return nil, fmt.Errorf("secret detected: body matches pattern %q -- remove secrets before adding to the knowledge base", pattern)
	}

	// Generate frontmatter + body.
	content := renderEntry(slug, req)

	// Try writing to main store.
	targetPath := s.EntryPath(slug)
	if err := os.MkdirAll(s.dir, 0o755); err != nil {
		return nil, fmt.Errorf("create knowledge dir: %w", err)
	}

	staged := false
	writePath := targetPath
	if _, err := os.Stat(targetPath); err == nil {
		// File exists (race after dedup check) -- fall back to staging.
		staged = true
		stagingDir := filepath.Join(s.dir, StagingDir)
		if err2 := os.MkdirAll(stagingDir, 0o755); err2 != nil {
			return nil, fmt.Errorf("create staging dir: %w", err2)
		}
		writePath = filepath.Join(stagingDir, slug+".md")
	}

	if err := os.WriteFile(writePath, []byte(content), 0o644); err != nil {
		return nil, fmt.Errorf("write entry: %w", err)
	}

	// Regenerate INDEX.md only when written to the main store.
	if !staged {
		if err := s.RegenerateIndex(); err != nil {
			// Non-fatal: log but don't fail the add.
			fmt.Fprintf(os.Stderr, "kb: warning: failed to regenerate INDEX.md: %v\n", err)
		}
	}

	msg := fmt.Sprintf("wrote knowledge/%s.md", slug)
	if staged {
		msg = fmt.Sprintf("conflict: wrote to knowledge/_staging/%s.md (review before promoting)", slug)
	}

	return &AddResult{
		Slug:    slug,
		Path:    writePath,
		Staged:  staged,
		Message: msg,
	}, nil
}

// RegenerateIndex regenerates INDEX.md from the entries currently in the store.
// It preserves the preamble (everything before the first table row) if it
// exists in the current INDEX.md, and rewrites the entry table section.
func (s *Store) RegenerateIndex() error {
	slugs, err := s.ListEntries()
	if err != nil {
		return fmt.Errorf("list entries: %w", err)
	}
	content, err := buildIndex(s.dir, slugs)
	if err != nil {
		return err
	}
	return os.WriteFile(s.IndexPath(), []byte(content), 0o644)
}

// BuildIndex constructs a fresh INDEX.md from the given slug list.
// Exported for unit testing.
func BuildIndex(dir string, slugs []string) (string, error) {
	return buildIndex(dir, slugs)
}

func buildIndex(dir string, slugs []string) (string, error) {
	// Read existing index to preserve the human-authored preamble.
	existingIndex := ""
	if b, err := os.ReadFile(filepath.Join(dir, IndexFile)); err == nil {
		existingIndex = string(b)
	}
	preamble := extractIndexPreamble(existingIndex)

	var rows []string
	for _, slug := range slugs {
		path := filepath.Join(dir, slug+".md")
		b, err := os.ReadFile(path)
		if err != nil {
			continue
		}
		e, err := parseEntry(slug, string(b))
		if err != nil {
			continue
		}
		summary := firstBodySentence(e.Body)
		rows = append(rows, fmt.Sprintf("| [%s](%s.md) | %s |", strings.ToUpper(slug), slug, summary))
	}

	var sb strings.Builder
	if preamble != "" {
		sb.WriteString(preamble)
		if !strings.HasSuffix(preamble, "\n") {
			sb.WriteString("\n")
		}
		sb.WriteString("\n")
	} else {
		sb.WriteString("# Knowledge base index\n\n")
		sb.WriteString("Generated by `conduit-broker kb`. Run `conduit-broker kb list` to see all entries.\n\n")
	}

	sb.WriteString("<!-- BEGIN KB ENTRIES (auto-generated) -->\n\n")
	sb.WriteString("## Entries\n\n")
	sb.WriteString("| Entry | Summary |\n")
	sb.WriteString("|-------|----------|\n")
	for _, row := range rows {
		sb.WriteString(row)
		sb.WriteString("\n")
	}
	sb.WriteString("\n<!-- END KB ENTRIES -->\n")

	return sb.String(), nil
}

// extractIndexPreamble returns the portion of an existing INDEX.md that
// appears before the auto-generated entries block (or the first table).
func extractIndexPreamble(existing string) string {
	// If there's a managed block marker, preserve everything before it.
	if idx := strings.Index(existing, "<!-- BEGIN KB ENTRIES"); idx >= 0 {
		return strings.TrimRight(existing[:idx], "\n")
	}
	// Otherwise preserve everything before the first table section header.
	scanner := bufio.NewScanner(strings.NewReader(existing))
	var preambleLines []string
	for scanner.Scan() {
		line := scanner.Text()
		if strings.HasPrefix(line, "## Entries") || strings.HasPrefix(line, "| Entry") {
			break
		}
		preambleLines = append(preambleLines, line)
	}
	result := strings.Join(preambleLines, "\n")
	return strings.TrimRight(result, "\n")
}

// firstBodySentence extracts a short summary from the entry body.
func firstBodySentence(body string) string {
	scanner := bufio.NewScanner(strings.NewReader(body))
	for scanner.Scan() {
		line := strings.TrimSpace(scanner.Text())
		if line == "" || strings.HasPrefix(line, "#") || strings.HasPrefix(line, "---") {
			continue
		}
		if len(line) > 120 {
			line = line[:117] + "..."
		}
		return line
	}
	return "(no summary)"
}

// MakeSlug converts a title to a kebab-case slug (lowercase, alphanumeric +
// hyphens only, no leading/trailing hyphens, collapsed runs).
func MakeSlug(title string) string {
	var sb strings.Builder
	lastWasHyphen := true // suppress leading hyphens
	for _, r := range strings.ToLower(title) {
		if unicode.IsLetter(r) || unicode.IsDigit(r) {
			sb.WriteRune(r)
			lastWasHyphen = false
		} else if !lastWasHyphen {
			sb.WriteRune('-')
			lastWasHyphen = true
		}
	}
	result := strings.TrimRight(sb.String(), "-")
	if result == "" {
		return "untitled"
	}
	return result
}

// CheckDedup returns the conflicting path if an entry with the same or very
// similar slug exists; empty string if no conflict. Exported for testing.
func CheckDedup(s *Store, slug, title string) (string, error) {
	return s.checkDedup(slug, title)
}

func (s *Store) checkDedup(slug, title string) (string, error) {
	// Exact slug match.
	path := s.EntryPath(slug)
	if _, err := os.Stat(path); err == nil {
		return path, nil
	}

	// Normalized title contains-check against existing entry titles.
	normalizedNew := normalizeTitle(title)
	slugs, err := s.ListEntries()
	if err != nil {
		// If the knowledge dir does not exist yet there are no entries to
		// conflict with — treat as empty (Add will mkdir it later).
		if os.IsNotExist(err) {
			return "", nil
		}
		return "", err
	}
	for _, existing := range slugs {
		existingPath := s.EntryPath(existing)
		b, readErr := os.ReadFile(existingPath)
		if readErr != nil {
			continue
		}
		e, parseErr := parseEntry(existing, string(b))
		if parseErr != nil {
			continue
		}
		if e.Title != "" {
			normalizedExisting := normalizeTitle(e.Title)
			// If either normalized form contains the other, treat as near-duplicate.
			if strings.Contains(normalizedExisting, normalizedNew) || strings.Contains(normalizedNew, normalizedExisting) {
				return existingPath, nil
			}
		}
	}
	return "", nil
}

// normalizeTitle returns a lowercase, whitespace-collapsed version of title.
func normalizeTitle(title string) string {
	fields := strings.Fields(strings.ToLower(title))
	return strings.Join(fields, " ")
}

// secretPatterns is the list of secret-detection regexes.
var secretPatterns = []struct {
	name    string
	pattern *regexp.Regexp
}{
	{"AWS access key", regexp.MustCompile(`AKIA[0-9A-Z]{16}`)},
	{"private key block", regexp.MustCompile(`-----BEGIN [\w ]*PRIVATE KEY-----`)},
	{"Slack token", regexp.MustCompile(`xox[baprs]-[0-9A-Za-z-]{10,}`)},
	{"GitHub token", regexp.MustCompile(`gh[pousr]_[A-Za-z0-9]{20,}`)},
	{"CONDUIT_TOKEN assignment", regexp.MustCompile(`(?i)CONDUIT_TOKEN\s*=\s*\S+`)},
	{"password assignment", regexp.MustCompile(`(?i)(password|passwd|pwd)\s*=\s*\S{4,}`)},
	{"secret assignment", regexp.MustCompile(`(?i)secret\s*=\s*\S{4,}`)},
	{"long hex blob (32+ hex chars)", regexp.MustCompile(`\b[0-9a-fA-F]{32,}\b`)},
	{"long base64 blob (40+ chars)", regexp.MustCompile(`[A-Za-z0-9+/]{40,}={0,2}`)},
}

// ScrubSecrets checks body for obvious secret patterns. Returns (patternName,
// true) on a match; ("", false) otherwise. Exported for testing.
func ScrubSecrets(body string) (string, bool) {
	return scrubSecrets(body)
}

func scrubSecrets(body string) (string, bool) {
	for _, sp := range secretPatterns {
		if sp.pattern.MatchString(body) {
			return sp.name, true
		}
	}
	return "", false
}

// validateSchema checks the required fields of an AddRequest.
func validateSchema(req AddRequest) error {
	if strings.TrimSpace(req.Title) == "" {
		return fmt.Errorf("schema: --title is required")
	}
	if len(req.Tags) == 0 {
		return fmt.Errorf("schema: at least one --tag is required")
	}
	if strings.TrimSpace(req.Body) == "" {
		return fmt.Errorf("schema: body is required (use --body or pipe on stdin)")
	}
	return nil
}

// renderEntry generates the full markdown content for a knowledge entry.
func renderEntry(slug string, req AddRequest) string {
	var sb strings.Builder
	sb.WriteString("---\n")
	sb.WriteString(fmt.Sprintf("title: %s\n", req.Title))
	tags := make([]string, len(req.Tags))
	copy(tags, req.Tags)
	sb.WriteString(fmt.Sprintf("tags: [%s]\n", strings.Join(tags, ", ")))
	scope := req.Scope
	if scope == "" {
		scope = "repo"
	}
	sb.WriteString(fmt.Sprintf("scope: %s\n", scope))
	sb.WriteString("source: agent\n")
	sb.WriteString("status: active\n")
	sb.WriteString(fmt.Sprintf("added: %s\n", time.Now().UTC().Format("2006-01-02")))
	sb.WriteString("---\n\n")
	body := strings.TrimSpace(req.Body)
	sb.WriteString(body)
	if !strings.HasSuffix(body, "\n") {
		sb.WriteString("\n")
	}
	return sb.String()
}

// parseEntry parses an entry markdown file. Frontmatter is expected in
// YAML-ish "key: value" form between "---" delimiters.
func parseEntry(slug, content string) (*Entry, error) {
	e := &Entry{Slug: slug}
	if !strings.HasPrefix(content, "---") {
		e.Body = content
		return e, nil
	}
	// Find closing ---
	rest := content[3:]
	end := strings.Index(rest, "\n---")
	if end < 0 {
		e.Body = content
		return e, nil
	}
	fm := rest[:end]
	body := rest[end+4:] // skip "\n---"
	if len(body) > 0 && body[0] == '\n' {
		body = body[1:]
	}
	e.Body = body

	for _, line := range strings.Split(fm, "\n") {
		kv := strings.SplitN(line, ":", 2)
		if len(kv) != 2 {
			continue
		}
		key := strings.TrimSpace(kv[0])
		val := strings.TrimSpace(kv[1])
		switch key {
		case "title":
			e.Title = val
		case "tags":
			val = strings.Trim(val, "[]")
			for _, t := range strings.Split(val, ",") {
				if t2 := strings.TrimSpace(t); t2 != "" {
					e.Tags = append(e.Tags, t2)
				}
			}
		case "scope":
			e.Scope = val
		case "source":
			e.Source = val
		case "status":
			e.Status = val
		}
	}
	return e, nil
}
