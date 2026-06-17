package session

import (
	"strings"
	"testing"
)

// testKBIndex is a small INDEX.md fixture in the same row shape the kb package
// generates: `| [SLUG](slug.md) | summary |`, plus a header row and preamble
// the pure function must ignore.
const testKBIndex = `# Knowledge base index

Some preamble prose that mentions broker and release but is not a table row.

## Broker and deployment

| Entry | Summary |
|-------|---------|
| [BROKER-OPS-FOOTGUNS](BROKER-OPS-FOOTGUNS.md) | Broker runs under systemd; redeploy is mv plus systemctl restart; never pkill; deploy relay before broker. |
| [RELEASE-GOTCHAS](RELEASE-GOTCHAS.md) | Android release runs lint that PR CI skips; tagging does not deploy the broker. |

## Core / bindings

| Entry | Summary |
|-------|---------|
| [UNIFFI-BINDINGS](UNIFFI-BINDINGS.md) | Always make bindings; hand-edited bindings carry stale checksums that fatal-panic the app at load. |
| [IS-SANDBOX-ROOT](IS-SANDBOX-ROOT.md) | Broker exec of claude dangerously-skip-permissions must set IS_SANDBOX or it is refused under root. |
`

func TestRelevantEntries_StrongMatchReturnsHit(t *testing.T) {
	// Prompt overlaps BROKER-OPS-FOOTGUNS on "systemd" + "redeploy" + "broker".
	prompt := "how do I redeploy the broker under systemd safely"
	hits := relevantEntries(testKBIndex, prompt, nil)
	if len(hits) == 0 {
		t.Fatalf("expected at least one hit, got none")
	}
	if hits[0].slug != "BROKER-OPS-FOOTGUNS" {
		t.Fatalf("expected BROKER-OPS-FOOTGUNS as top hit, got %q (all=%v)", hits[0].slug, slugsOf(hits))
	}
	if hits[0].score < kbRelevanceMinTerms {
		t.Fatalf("top hit score %d below threshold %d", hits[0].score, kbRelevanceMinTerms)
	}
}

func TestRelevantEntries_WeakMatchReturnsNone(t *testing.T) {
	// "broker" alone overlaps several summaries but only ONE distinct term —
	// below the threshold, so nothing should inject (no per-turn spam).
	prompt := "broker"
	if hits := relevantEntries(testKBIndex, prompt, nil); len(hits) != 0 {
		t.Fatalf("expected no hits for single-term prompt, got %v", slugsOf(hits))
	}
}

func TestRelevantEntries_NoMatchReturnsNone(t *testing.T) {
	prompt := "what is the weather in tokyo this weekend"
	if hits := relevantEntries(testKBIndex, prompt, nil); len(hits) != 0 {
		t.Fatalf("expected no hits for unrelated prompt, got %v", slugsOf(hits))
	}
}

func TestRelevantEntries_EmptyPromptReturnsNone(t *testing.T) {
	if hits := relevantEntries(testKBIndex, "", nil); len(hits) != 0 {
		t.Fatalf("expected no hits for empty prompt, got %v", slugsOf(hits))
	}
	// All-stopword / sub-min-length prompt yields no query terms either.
	if hits := relevantEntries(testKBIndex, "is it ok to go", nil); len(hits) != 0 {
		t.Fatalf("expected no hits for stopword-only prompt, got %v", slugsOf(hits))
	}
}

func TestRelevantEntries_AlreadySeenExcluded(t *testing.T) {
	prompt := "how do I redeploy the broker under systemd safely"
	seen := map[string]bool{"BROKER-OPS-FOOTGUNS": true}
	hits := relevantEntries(testKBIndex, prompt, seen)
	for _, h := range hits {
		if h.slug == "BROKER-OPS-FOOTGUNS" {
			t.Fatalf("already-seen slug BROKER-OPS-FOOTGUNS must be excluded, got %v", slugsOf(hits))
		}
	}
}

func TestRelevantEntries_CapRespected(t *testing.T) {
	// A prompt engineered to match all four entries (>=2 distinct terms each).
	prompt := "broker systemd redeploy release lint tagging bindings checksums sandbox claude permissions"
	hits := relevantEntries(testKBIndex, prompt, nil)
	if len(hits) > kbRelevanceMaxHits {
		t.Fatalf("cap not respected: got %d hits, max %d (%v)", len(hits), kbRelevanceMaxHits, slugsOf(hits))
	}
}

func TestRelevantEntries_ThresholdRespected(t *testing.T) {
	// Exactly one distinct overlapping term ("bindings") must NOT cross the
	// >=2 threshold for UNIFFI-BINDINGS.
	prompt := "regenerate the bindings folder"
	for _, h := range relevantEntries(testKBIndex, prompt, nil) {
		if h.score < kbRelevanceMinTerms {
			t.Fatalf("hit %q below threshold leaked: score=%d", h.slug, h.score)
		}
	}
}

func TestRelevantEntries_SortedByScoreDesc(t *testing.T) {
	prompt := "broker systemd redeploy release lint"
	hits := relevantEntries(testKBIndex, prompt, nil)
	for i := 1; i < len(hits); i++ {
		if hits[i-1].score < hits[i].score {
			t.Fatalf("hits not sorted by descending score: %v", hits)
		}
	}
}

func TestPromptQueryTerms_DropsStopwordsAndShort(t *testing.T) {
	terms := promptQueryTerms("How do I REDEPLOY the broker on a box")
	if terms["how"] {
		t.Fatalf("stopword 'how' should be dropped")
	}
	if terms["do"] {
		t.Fatalf("short token 'do' should be dropped")
	}
	if !terms["redeploy"] {
		t.Fatalf("'redeploy' should be a query term (got %v)", terms)
	}
	if !terms["broker"] {
		t.Fatalf("'broker' should be a query term (got %v)", terms)
	}
}

func TestRenderKBHintBlock(t *testing.T) {
	if got := renderKBHintBlock("/usr/bin/conduit-broker", nil); got != "" {
		t.Fatalf("empty hits should render empty block, got %q", got)
	}
	hits := []kbHit{
		{slug: "BROKER-OPS-FOOTGUNS", summary: "redeploy via mv + restart", score: 3},
		{slug: "RELEASE-GOTCHAS", summary: "tagging does not deploy", score: 2},
	}
	block := renderKBHintBlock("/usr/bin/conduit-broker", hits)
	if !strings.HasPrefix(block, "[conduit knowledge base") {
		t.Fatalf("block missing delineating prefix: %q", block)
	}
	if !strings.Contains(block, "conduit-broker kb get <slug>") {
		t.Fatalf("block must tell agent how to get detail: %q", block)
	}
	if !strings.Contains(block, "BROKER-OPS-FOOTGUNS — redeploy via mv + restart") {
		t.Fatalf("block must carry slug + summary: %q", block)
	}
	if !strings.Contains(block, "RELEASE-GOTCHAS") {
		t.Fatalf("block must carry all hits: %q", block)
	}
	if !strings.HasSuffix(strings.TrimSpace(block), "]") {
		t.Fatalf("block must be bracket-delineated: %q", block)
	}
}

func slugsOf(hits []kbHit) []string {
	var out []string
	for _, h := range hits {
		out = append(out, h.slug)
	}
	return out
}
