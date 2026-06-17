package session

import (
	"fmt"
	"log"
	"os"
	"path/filepath"
	"regexp"
	"sort"
	"strings"

	"github.com/nikhilsh/conduit/broker/internal/kb"
)

// This file is Phase 2 of the cross-agent knowledge base (see
// docs/PLAN-knowledge-base.md). Phase 1 injects the KB INDEX once at session
// spawn so the agent KNOWS the KB exists. Phase 2 adds a per-turn relevance
// hook: when a user prompt arrives, the broker scans the KB index for entries
// whose slug/summary overlap the prompt's keywords and prepends a small,
// clearly-delineated "possibly relevant" hint block ahead of the user's actual
// message — for BOTH claude (stream-json) and codex (app-server / exec), at the
// single shared send point in Session.SendChat.
//
// Conservatism is the whole game here: this mutates the LIVE prompt every turn,
// so a false positive erodes trust fast. The relevance decision is therefore a
// PURE function (relevantEntries) with a real threshold and a hard cap, and a
// per-session dedup set means a long session never re-surfaces the same hint.

// kbRelevanceMinTerms is the minimum number of DISTINCT prompt query-terms that
// must appear in an entry's (slug + summary) text for it to count as relevant.
// Two is deliberately conservative: a single shared common word (e.g. "broker")
// should not trigger an injection; two distinct overlapping terms is a real
// topical signal. Tuned to make MOST turns inject nothing (no per-turn spam).
const kbRelevanceMinTerms = 2

// kbRelevanceMaxHits caps how many entries are injected in a single turn so the
// hint block stays small (point 3 of the plan: a few lines, not a wall).
const kbRelevanceMaxHits = 3

// kbRelevanceMinTokenLen drops very short prompt tokens before matching. Short
// tokens ("a", "is", "to", "go") are noise that would otherwise spuriously
// overlap entry summaries.
const kbRelevanceMinTokenLen = 3

// kbHit is one relevant KB entry: its slug (as it appears in INDEX.md, used by
// `conduit-broker kb get <slug>`) plus the one-line summary and the relevance
// score (number of distinct matching query terms). Pure-function output.
type kbHit struct {
	slug    string
	summary string
	score   int
}

// kbIndexRowRe matches an INDEX.md entry row: `| [SLUG](slug.md) | summary |`.
// Mirrors the row shape produced by the kb package's index generator (kb.go
// buildIndex). Group 1 is the slug as displayed (used for `kb get`), group 2
// is the one-line summary.
var kbIndexRowRe = regexp.MustCompile(`^\|\s*\[([^\]]+)\]\([^)]+\)\s*\|\s*(.+?)\s*\|\s*$`)

// kbTokenRe splits prompt/entry text into lowercase alphanumeric tokens.
var kbTokenRe = regexp.MustCompile(`[a-z0-9]+`)

// kbStopwords are common English words excluded from query-term matching so
// they can't contribute to the relevance score. Kept small and generic.
var kbStopwords = map[string]bool{
	"the": true, "and": true, "for": true, "with": true, "that": true,
	"this": true, "you": true, "your": true, "are": true, "was": true,
	"were": true, "has": true, "have": true, "had": true, "but": true,
	"not": true, "can": true, "will": true, "would": true, "should": true,
	"could": true, "from": true, "into": true, "out": true, "off": true,
	"how": true, "why": true, "what": true, "when": true, "where": true,
	"which": true, "who": true, "they": true, "them": true, "its": true,
	"our": true, "all": true, "any": true, "use": true, "using": true,
	"get": true, "got": true, "let": true, "now": true, "via": true,
	"per": true, "set": true, "see": true, "run": true, "add": true,
	"new": true, "old": true, "fix": true, "need": true, "want": true,
	"make": true, "just": true, "like": true, "some": true, "more": true,
	"only": true, "than": true, "then": true, "also": true, "here": true,
	"there": true, "about": true, "after": true, "before": true,
}

// promptQueryTerms extracts the DISTINCT, non-stopword, length-filtered tokens
// from a prompt. The set is what relevantEntries scores entries against. Pure.
func promptQueryTerms(prompt string) map[string]bool {
	terms := make(map[string]bool)
	for _, tok := range kbTokenRe.FindAllString(strings.ToLower(prompt), -1) {
		if len(tok) < kbRelevanceMinTokenLen {
			continue
		}
		if kbStopwords[tok] {
			continue
		}
		terms[tok] = true
	}
	return terms
}

// relevantEntries is the PURE relevance decision: given INDEX.md content, a user
// prompt, and the set of slugs already surfaced this session, it returns the
// top entries whose slug+summary overlaps the prompt by at least
// kbRelevanceMinTerms distinct query-terms, capped at kbRelevanceMaxHits and
// sorted by descending score (ties broken alphabetically by slug for
// determinism). Already-seen slugs are excluded. No I/O, no side effects — the
// send-path wiring is thin glue over this.
func relevantEntries(indexContent, prompt string, alreadySeen map[string]bool) []kbHit {
	terms := promptQueryTerms(prompt)
	if len(terms) == 0 {
		return nil
	}

	var hits []kbHit
	for _, line := range strings.Split(indexContent, "\n") {
		m := kbIndexRowRe.FindStringSubmatch(line)
		if m == nil {
			continue
		}
		slug := strings.TrimSpace(m[1])
		summary := strings.TrimSpace(m[2])
		if slug == "" || slug == "Entry" { // skip the table header row
			continue
		}
		if alreadySeen[slug] {
			continue
		}

		// Score = number of DISTINCT prompt terms present in the entry's
		// slug+summary text. Slug words count too (slugs are topic-dense).
		hay := strings.ToLower(slug + " " + summary)
		hayTokens := make(map[string]bool)
		for _, t := range kbTokenRe.FindAllString(hay, -1) {
			hayTokens[t] = true
		}
		score := 0
		for term := range terms {
			if hayTokens[term] {
				score++
			}
		}
		if score >= kbRelevanceMinTerms {
			hits = append(hits, kbHit{slug: slug, summary: summary, score: score})
		}
	}

	// Highest score first; alphabetical slug tiebreak for deterministic output.
	sort.Slice(hits, func(i, j int) bool {
		if hits[i].score != hits[j].score {
			return hits[i].score > hits[j].score
		}
		return hits[i].slug < hits[j].slug
	})
	if len(hits) > kbRelevanceMaxHits {
		hits = hits[:kbRelevanceMaxHits]
	}
	return hits
}

// renderKBHintBlock formats the matched entries into the bracketed,
// clearly-delineated reference block prepended to the prompt. It is framed as a
// HINT, not an instruction, and names `conduit-broker kb get <slug>` for detail
// so bodies are never inlined (the block stays small — point 3 of the plan).
// Returns "" for no hits.
func renderKBHintBlock(brokerBin string, hits []kbHit) string {
	if len(hits) == 0 {
		return ""
	}
	var parts []string
	for _, h := range hits {
		parts = append(parts, h.slug+" — "+h.summary)
	}
	return "[conduit knowledge base — possibly relevant to this request (run `" +
		brokerBin + " kb get <slug>` for detail): " +
		strings.Join(parts, "; ") + "]"
}

// kbWorkspaceIndex reads <workspace>/knowledge/INDEX.md, reusing the SAME gate
// as Phase 1 (kbSection): returns ("", false) when the workspace has no
// INDEX.md so the per-turn hook is a strict no-op (zero behavior change with no
// KB). Errors are swallowed (returns false) — KB problems must never block a
// turn.
func kbWorkspaceIndex(workspaceDir string) (string, bool) {
	if workspaceDir == "" {
		return "", false
	}
	// Phase 3a (flag ON): the per-turn hook spans all three origins (tracked,
	// box-local, source-pointers), self-gated on kb.SourceExists. The merged
	// content is rendered into the `| [slug](slug.md) | summary |` row form the
	// pure relevantEntries scorer already understands, so its scoring/threshold
	// logic is unchanged.
	if kb.ExperimentalEnabled() {
		if !kb.SourceExists(workspaceDir) {
			return "", false
		}
		merged := kb.MergedIndexForWorkspace(workspaceDir)
		if len(merged) == 0 {
			return "", false
		}
		var sb strings.Builder
		for _, l := range merged {
			// slug doubles as the link target; the scorer only reads slug+summary.
			sb.WriteString(fmt.Sprintf("| [%s](%s.md) | %s |\n", l.Slug, l.Slug, l.Summary))
		}
		return sb.String(), true
	}

	// Flag OFF (default): byte-identical to Phase 2 — tracked INDEX.md only.
	indexPath := filepath.Join(workspaceDir, "knowledge", "INDEX.md")
	b, err := os.ReadFile(indexPath)
	if err != nil {
		return "", false
	}
	return string(b), true
}

// kbTurnHint is the send-path glue: given a user prompt, it returns the hint
// block to PREPEND for this turn (or "" for none) and the list of slugs that
// were surfaced, so the caller can record them in the per-session dedup set.
// Self-gated on knowledge/INDEX.md; never errors (logs + returns "" on any
// trouble). alreadySeen is read-only here — the caller mutates its set after a
// successful send.
func (s *Session) kbTurnHint(prompt string, alreadySeen map[string]bool) (block string, surfaced []string) {
	indexContent, ok := kbWorkspaceIndex(s.workspaceDir)
	if !ok {
		return "", nil
	}
	hits := relevantEntries(indexContent, prompt, alreadySeen)
	if len(hits) == 0 {
		return "", nil
	}
	block = renderKBHintBlock(brokerExecutable(), hits)
	for _, h := range hits {
		surfaced = append(surfaced, h.slug)
	}
	log.Printf("session %s: kb relevance hook surfaced %d entr%s: %v",
		s.ID, len(surfaced), plural(len(surfaced)), surfaced)
	return block, surfaced
}

func plural(n int) string {
	if n == 1 {
		return "y"
	}
	return "ies"
}
