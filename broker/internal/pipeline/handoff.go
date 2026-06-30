package pipeline

import (
	"fmt"
	"os"
	"path/filepath"
	"regexp"
	"strings"
)

// reHandoffSection matches a <section data-section="handoff">…</section> block.
// The content (group 1) may span multiple lines, so we use (?s) — dot-matches-newline.
var reHandoffSection = regexp.MustCompile(`(?s)<section[^>]+data-section="handoff"[^>]*>(.*?)</section>`)

// reHTMLTag strips any HTML tag.
var reHTMLTag = regexp.MustCompile(`<[^>]+>`)

// extractHandoffText reads <conduitRoot>/.conduit/HANDOFF-OUT.html (relative
// to workdir), finds the <section data-section="handoff"> element, and returns
// its inner text with HTML tags stripped. Returns "" on any error or missing
// section — callers must treat absence as empty, never fatal.
func extractHandoffText(workdir string) string {
	path := filepath.Join(workdir, ".conduit", "HANDOFF-OUT.html")
	data, err := os.ReadFile(path)
	if err != nil {
		return ""
	}
	m := reHandoffSection.FindSubmatch(data)
	if len(m) < 2 {
		return ""
	}
	// Strip HTML tags from the inner content and normalize whitespace.
	text := reHTMLTag.ReplaceAllString(string(m[1]), "")
	// Collapse runs of blank lines into a single blank line.
	lines := strings.Split(text, "\n")
	var out []string
	prev := false
	for _, l := range lines {
		blank := strings.TrimSpace(l) == ""
		if blank && prev {
			continue
		}
		out = append(out, l)
		prev = blank
	}
	return strings.TrimSpace(strings.Join(out, "\n"))
}

// BuildPrev constructs the {{prev}} substitution for the next step.
//
//   - workdir is the previous step's workspace path (used to find HANDOFF-OUT.html).
//   - transcriptText is the last assistant turn text (caller provides from the
//     session's conversation log).
//   - mode is the step's input_from_prev value.
func BuildPrev(workdir, transcriptText string, mode InputFromPrev) string {
	switch mode {
	case InputNone:
		return ""
	case InputOutput:
		return transcriptText
	case InputMemory:
		return extractHandoffText(workdir)
	case InputMemoryOutput:
		memory := extractHandoffText(workdir)
		if transcriptText == "" {
			return memory
		}
		if memory == "" {
			return transcriptText
		}
		return memory + "\n\n## Previous step output\n" + transcriptText
	default:
		return ""
	}
}

// SaveInput persists {{prev}} to <conduitRoot>/pipelines/<id>/steps/<n>/input.md
// for audit and replay purposes.
func SaveInput(conduitRoot, pipelineID string, stepIndex int, content string) error {
	dir := filepath.Join(conduitRoot, "pipelines", pipelineID, "steps", fmt.Sprintf("%d", stepIndex))
	if err := os.MkdirAll(dir, 0o755); err != nil {
		return fmt.Errorf("pipeline %s step %d: mkdir: %w", pipelineID, stepIndex, err)
	}
	path := filepath.Join(dir, "input.md")
	if err := os.WriteFile(path, []byte(content), 0o644); err != nil {
		return fmt.Errorf("pipeline %s step %d: write input.md: %w", pipelineID, stepIndex, err)
	}
	return nil
}
