package kb

import (
	"fmt"
	"os"
	"path/filepath"
	"regexp"
	"strings"
)

// LintResult is the output of a Lint run.
type LintResult struct {
	Errors   []string
	Warnings []string
}

// OK returns true when there are no hard errors.
func (r *LintResult) OK() bool { return len(r.Errors) == 0 }

// Summary returns a human-readable summary line.
func (r *LintResult) Summary() string {
	return fmt.Sprintf("%d error(s), %d warning(s)", len(r.Errors), len(r.Warnings))
}

// linkRe matches markdown links of the form [TEXT](SLUG.md) where SLUG has no
// path separator, i.e. a same-directory relative link.
var linkRe = regexp.MustCompile(`\[([^\]]+)\]\(([^)/]+\.md)\)`)

// wikiLinkRe matches [[SLUG]] wiki-style links.
var wikiLinkRe = regexp.MustCompile(`\[\[([^\]]+)\]\]`)

// Lint runs structural integrity checks on the knowledge/ directory rooted at
// workspace. It returns a LintResult; the caller decides how to act on it.
//
// Hard errors (exit-non-zero in CI):
//   - An entry file exists but is not referenced in INDEX.md.
//   - INDEX.md references a slug whose file does not exist.
//   - Duplicate slug (two files with the same case-folded name).
//   - Entry has invalid frontmatter (missing title, tags, or status).
//   - A relative .md cross-link inside an entry points at a nonexistent file.
//
// Warnings (non-fatal):
//   - Two entries share ≥2 tags AND one title is a substring of the other
//     (cheap overlap heuristic — not semantic dedup; LLM pass needed for that).
//
// NOTE: Semantic contradiction detection is intentionally out of scope. This
// lint is structural + a cheap overlap heuristic only. Do not overclaim.
func Lint(workspace string) (*LintResult, error) {
	dir := filepath.Join(workspace, KnowledgeDir)
	indexPath := filepath.Join(dir, IndexFile)

	res := &LintResult{}

	// --- 1. Collect entry files -------------------------------------------

	dirEntries, err := os.ReadDir(dir)
	if err != nil {
		return nil, fmt.Errorf("kb lint: cannot read knowledge dir %q: %w", dir, err)
	}

	// fileSlug -> absolute path, case-folded slug -> first-seen slug (for dup check)
	type entryInfo struct {
		slug string
		path string
	}
	var entries []entryInfo           // ordered list of real entries
	caseFolded := map[string]string{} // lowercase -> first slug seen
	slugSet := map[string]bool{}      // all slug names (as-on-disk)

	for _, de := range dirEntries {
		if de.IsDir() {
			continue
		}
		name := de.Name()
		if !strings.HasSuffix(name, ".md") {
			continue
		}
		slug := strings.TrimSuffix(name, ".md")
		if slug == "INDEX" {
			continue
		}
		lower := strings.ToLower(slug)
		if prev, exists := caseFolded[lower]; exists {
			res.Errors = append(res.Errors,
				fmt.Sprintf("duplicate slug (case-insensitive): %q and %q", prev, slug))
		} else {
			caseFolded[lower] = slug
		}
		entries = append(entries, entryInfo{slug: slug, path: filepath.Join(dir, name)})
		slugSet[slug] = true
	}

	// --- 2. INDEX.md sync --------------------------------------------------

	indexData, err := os.ReadFile(indexPath)
	if err != nil {
		res.Errors = append(res.Errors, fmt.Sprintf("INDEX.md missing or unreadable: %v", err))
		// Can't check sync without the index; still continue with other checks.
	} else {
		indexStr := string(indexData)

		// Slugs referenced in INDEX.md (filename part of links, e.g. "BROKER-OPS-FOOTGUNS.md").
		indexRefs := extractIndexRefs(indexStr)

		// Every file must appear in INDEX.
		for _, e := range entries {
			if !indexRefs[e.slug] {
				res.Errors = append(res.Errors,
					fmt.Sprintf("entry %q exists but is not referenced in INDEX.md", e.slug))
			}
		}

		// Every INDEX reference must have a file.
		for slug := range indexRefs {
			if !slugSet[slug] {
				res.Errors = append(res.Errors,
					fmt.Sprintf("INDEX.md references %q but knowledge/%s.md does not exist (orphan reference)", slug, slug))
			}
		}
	}

	// --- 3. Frontmatter validation + cross-links ---------------------------

	type parsedEntry struct {
		slug  string
		title string
		tags  []string
	}
	var parsed []parsedEntry

	for _, e := range entries {
		raw, readErr := os.ReadFile(e.path)
		if readErr != nil {
			res.Errors = append(res.Errors, fmt.Sprintf("cannot read %s: %v", e.slug, readErr))
			continue
		}
		content := string(raw)
		ent, parseErr := parseEntry(e.slug, content)
		if parseErr != nil {
			res.Errors = append(res.Errors, fmt.Sprintf("entry %q: parse error: %v", e.slug, parseErr))
			continue
		}

		// Frontmatter checks.
		if strings.TrimSpace(ent.Title) == "" {
			res.Errors = append(res.Errors, fmt.Sprintf("entry %q: missing frontmatter field 'title'", e.slug))
		}
		if len(ent.Tags) == 0 {
			res.Errors = append(res.Errors, fmt.Sprintf("entry %q: missing frontmatter field 'tags' (must have ≥1)", e.slug))
		}
		if strings.TrimSpace(ent.Status) == "" {
			res.Errors = append(res.Errors, fmt.Sprintf("entry %q: missing frontmatter field 'status'", e.slug))
		}

		// Cross-link checks: look for [TEXT](SLUG.md) links in the body.
		for _, m := range linkRe.FindAllStringSubmatch(content, -1) {
			target := strings.TrimSuffix(m[2], ".md")
			if !slugSet[target] {
				res.Errors = append(res.Errors,
					fmt.Sprintf("entry %q: broken cross-link -> %q (no such entry)", e.slug, target))
			}
		}

		// [[SLUG]] wiki-style links.
		for _, m := range wikiLinkRe.FindAllStringSubmatch(content, -1) {
			target := m[1]
			// Try both as-written and uppercase, since entries can be any case.
			if !slugSet[target] && !slugSet[strings.ToUpper(target)] {
				res.Errors = append(res.Errors,
					fmt.Sprintf("entry %q: broken wiki-link [[%s]] (no such entry)", e.slug, target))
			}
		}

		parsed = append(parsed, parsedEntry{
			slug:  e.slug,
			title: strings.ToLower(ent.Title),
			tags:  ent.Tags,
		})
	}

	// --- 4. Overlap heuristic (WARN only) ----------------------------------
	//
	// Two entries are flagged if they share ≥2 tags AND one normalized title
	// is a substring of the other. This is a cheap structural heuristic; it
	// does NOT detect semantic contradictions or redundancy between entries
	// with dissimilar titles. True dedup requires an LLM pass.
	for i := 0; i < len(parsed); i++ {
		for j := i + 1; j < len(parsed); j++ {
			a, b := parsed[i], parsed[j]
			if sharedTagCount(a.tags, b.tags) >= 2 && titlesOverlap(a.title, b.title) {
				res.Warnings = append(res.Warnings,
					fmt.Sprintf("potential overlap (shared tags + title substring): %q and %q — verify manually (structural heuristic only; semantic dedup needs LLM pass)",
						a.slug, b.slug))
			}
		}
	}

	return res, nil
}

// extractIndexRefs parses INDEX.md for Markdown links whose href is a bare
// filename (no directory component) ending in .md.  Returns a set of slug
// names (the filename without the .md suffix).
func extractIndexRefs(index string) map[string]bool {
	refs := map[string]bool{}
	for _, m := range linkRe.FindAllStringSubmatch(index, -1) {
		slug := strings.TrimSuffix(m[2], ".md")
		refs[slug] = true
	}
	return refs
}

// sharedTagCount returns the number of tags common to a and b (case-insensitive).
func sharedTagCount(a, b []string) int {
	setA := make(map[string]bool, len(a))
	for _, t := range a {
		setA[strings.ToLower(t)] = true
	}
	count := 0
	for _, t := range b {
		if setA[strings.ToLower(t)] {
			count++
		}
	}
	return count
}

// titlesOverlap returns true when one normalized title is a substring of the other.
func titlesOverlap(a, b string) bool {
	return strings.Contains(a, b) || strings.Contains(b, a)
}
