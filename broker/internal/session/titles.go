package session

import (
	"context"
	"fmt"
	"net/http"
	"os"
	"regexp"
	"strings"
	"sync"
	"time"
)

// AI-generated session titles (task: ai-session-titles). Like Claude.ai
// auto-titling a conversation by its purpose, the broker mints a short
// human title from the first meaningful exchange (first user prompt +
// first assistant reply) and emits it to the apps as the session's
// display name — replacing the verbatim-first-message default. A user's
// manual rename still wins (the apps slot the AI title BELOW a manual
// rename in their display-name priority).
//
// Mechanism: reuses the fast direct Anthropic Messages API path from the
// quick-reply work (#237) via the shared `anthropicMessages` helper
// (aigen.go) — a haiku call authorized by the session's OAuth token,
// returning in ~1-2s. NOT the slow `claude -p` cold-start.
//
// Cadence + cost: generation is best-effort + async + cheap. We generate
// once after the first exchange completes, then optionally refine ONCE
// more when the conversation has grown substantially. A hard cap
// (maxTitleGenerations) ensures at most a couple of haiku calls per
// session — we never regenerate every turn.
//
// Wire: emitted as a `view:"session_title"` view_event with payload
// {session_id, title}, mirroring how `view:"quick_replies"` flows through
// core transport.rs → on_view_event. Persisted into the session meta so a
// reopened/relisted session keeps the title without re-generating, and
// re-emitted to a freshly attached client.
//
// Config: SWE_KITTY_AI_TITLES=0 (or false/off/no) disables it; default ON.

// titleTimeout caps the HTTP call. The title is a nicety, not the turn,
// so we bail rather than linger; on timeout we emit nothing and the apps
// keep showing the first-message fallback.
const titleTimeout = 12 * time.Second

// titleMaxTokens caps the model's output. A <=6-word title fits easily.
const titleMaxTokens = 32

// maxTitleLen is the hard length cap on a generated title (characters).
// The §3.3 rename regex caps manual names at 32; we mirror that so the AI
// title renders identically in every title surface.
const maxTitleLen = 32

// maxTitleWords is the soft word cap we instruct the model with and
// enforce client-side, keeping titles short and glanceable.
const maxTitleWords = 6

// maxTitleGenerations bounds how many haiku calls a single session will
// make for titling. 1 = the post-first-exchange title; 2 = one optional
// refine after substantial growth. Never more — titling must stay cheap.
const maxTitleGenerations = 2

// titleRefineAfterChars is the conversation-length growth (in characters
// of accumulated assistant prose) past which we allow ONE refine. Keeps
// us from regenerating on a trivial follow-up.
const titleRefineAfterChars = 1500

// titlesEnabled reports whether AI session-title generation is on.
// Default ON; SWE_KITTY_AI_TITLES=0 (or "false"/"off"/"no") disables it.
func titlesEnabled() bool {
	return aiFeatureEnabled("SWE_KITTY_AI_TITLES")
}

// titleGenerator produces an AI title for a session. It owns its own
// generation-count + growth bookkeeping so the stream reader can fire it
// at turn-end without tracking state, and it reaches back into the
// session only through two closures: firstPrompt (the captured first user
// message) and setTitle (persist + emit). nil is a valid generator: every
// method tolerates a nil receiver and no-ops, so the disabled / non-claude
// paths don't have to branch.
type titleGenerator struct {
	sessionID    string
	agentHomeDir string // session ephemeral $HOME (source of the OAuth token)
	// firstPrompt returns the session's first user prompt (the composer
	// text that opened the conversation). Empty until the user has sent at
	// least one message.
	firstPrompt func() string
	// setTitle stores + persists + emits the generated title. Called only
	// on a successful, non-empty generation.
	setTitle func(string)
	// httpDo issues the Messages API request. Defaults to a real HTTP
	// client; tests inject a stub so CI never touches the network.
	httpDo httpDoFunc

	mu          sync.Mutex
	gens        int // generations performed so far (cap: maxTitleGenerations)
	seenChars   int // accumulated assistant prose length across the session
	refinedChar int // seenChars value at which the last gen fired
	inFlight    bool
}

// newTitleGenerator builds a generator for a claude stream-json session,
// or returns nil when titling can't / shouldn't run (feature disabled, no
// ephemeral HOME for the token, or missing closures). Returning nil keeps
// the call site branch-free. `binary` mirrors the quick-reply guard:
// titling is only for a real claude backend.
func newTitleGenerator(sessionID, binary, agentHomeDir string, firstPrompt func() string, setTitle func(string)) *titleGenerator {
	if !titlesEnabled() || agentHomeDir == "" || binary == "" || firstPrompt == nil || setTitle == nil {
		return nil
	}
	return &titleGenerator{
		sessionID:    sessionID,
		agentHomeDir: agentHomeDir,
		firstPrompt:  firstPrompt,
		setTitle:     setTitle,
		httpDo:       http.DefaultClient.Do,
	}
}

// onTurnEnd is the stream reader's hook: called with the turn's final
// assistant text when a `result` envelope lands. It decides — under the
// cadence rules — whether to fire a (re)generation, and does so in a
// goroutine so the reader never blocks. nil-safe.
func (g *titleGenerator) onTurnEnd(lastAssistant string) {
	if g == nil {
		return
	}
	g.mu.Lock()
	g.seenChars += len(strings.TrimSpace(lastAssistant))
	shouldGen := false
	switch {
	case g.inFlight:
		// A generation is already running; don't pile on.
	case g.gens == 0:
		// First meaningful exchange complete → mint the initial title.
		shouldGen = true
	case g.gens < maxTitleGenerations && g.seenChars-g.refinedChar >= titleRefineAfterChars:
		// Conversation grew substantially → allow one cheap refine.
		shouldGen = true
	}
	if shouldGen {
		g.inFlight = true
	}
	g.mu.Unlock()
	if !shouldGen {
		return
	}
	go g.generate(lastAssistant)
}

// generate runs one best-effort title generation and, on success,
// persists + emits via setTitle. Synchronous; onTurnEnd spawns it.
func (g *titleGenerator) generate(lastAssistant string) {
	defer func() {
		g.mu.Lock()
		g.inFlight = false
		g.mu.Unlock()
	}()

	prompt := strings.TrimSpace(g.firstPrompt())
	lastAssistant = strings.TrimSpace(lastAssistant)
	// Need at least a user prompt to title against. (The assistant reply
	// is helpful context but optional — a titled session keyed only on the
	// user's ask is still far better than the raw first message.)
	if prompt == "" {
		return
	}

	ctx, cancel := context.WithTimeout(context.Background(), titleTimeout)
	defer cancel()

	title, err := g.invoke(ctx, prompt, lastAssistant)
	if err != nil || title == "" {
		// Best-effort: stay silent. Log to stderr for debuggability.
		if err != nil {
			fmt.Fprintf(os.Stderr, "session %s: title generation: %v\n", g.sessionID, err)
		}
		return
	}

	g.mu.Lock()
	g.gens++
	g.refinedChar = g.seenChars
	g.mu.Unlock()

	g.setTitle(title)
}

// invoke makes a direct Anthropic Messages API call and returns the
// cleaned title (or "" when the model produced nothing usable).
func (g *titleGenerator) invoke(ctx context.Context, prompt, lastAssistant string) (string, error) {
	text, err := anthropicMessages(ctx, g.httpDo, g.agentHomeDir, titlePrompt(prompt, lastAssistant), titleMaxTokens)
	if err != nil {
		return "", err
	}
	return cleanTitle(text), nil
}

// titlePrompt is the tight instruction handed to the model. It asks for a
// bare title line summarizing the conversation's purpose — no quotes, no
// trailing punctuation, <= ~6 words.
func titlePrompt(firstUser, firstAssistant string) string {
	var b strings.Builder
	b.WriteString("Generate a short title for a coding-assistant conversation, like an IDE tab label. ")
	b.WriteString(fmt.Sprintf("At most %d words. ", maxTitleWords))
	b.WriteString("Capture the conversation's PURPOSE/TASK (e.g. \"Debug broker session limit\", \"Summarize repo structure\"). ")
	b.WriteString("Use Title Case. No surrounding quotes, no trailing punctuation, no emoji, no preamble. ")
	b.WriteString("Respond with ONLY the title text on a single line.\n\n")
	b.WriteString("User's first message:\n")
	b.WriteString(firstUser)
	if firstAssistant != "" {
		b.WriteString("\n\nAssistant's reply:\n")
		b.WriteString(firstAssistant)
	}
	return b.String()
}

// titleNoisePrefix strips a leading "Title:" / "Here's a title:" style
// preamble some models emit despite the instruction. The optional
// "(here'?s|here is|sure)" lead-in and "a/the (suggested) title/name/tab"
// phrase are both consumed up to the colon/dash, leaving the bare title.
var titleNoisePrefix = regexp.MustCompile(`(?i)^\s*((here'?s|here is|sure)[,!]?\s*)?(a|the)?\s*(suggested\s+)?(title|name|tab)\s*[:\-]\s*`)

// cleanTitle distills the model's raw output into a safe, short title:
// first non-empty line, stripped of wrapping quotes / preamble / trailing
// punctuation, collapsed whitespace, capped to maxTitleWords words and
// maxTitleLen chars. Returns "" when nothing usable remains so callers
// emit nothing.
func cleanTitle(raw string) string {
	// First non-empty line.
	line := ""
	for _, l := range strings.Split(raw, "\n") {
		if strings.TrimSpace(l) != "" {
			line = l
			break
		}
	}
	line = strings.TrimSpace(line)
	if line == "" {
		return ""
	}
	// Drop a leading preamble ("Title: …", "Here's a title: …").
	line = titleNoisePrefix.ReplaceAllString(line, "")
	// Strip surrounding matched quotes/backticks, possibly repeated.
	line = strings.TrimSpace(line)
	for {
		trimmed := trimWrappingQuote(line)
		if trimmed == line {
			break
		}
		line = strings.TrimSpace(trimmed)
	}
	// Collapse internal whitespace runs.
	line = strings.Join(strings.Fields(line), " ")
	// Trailing sentence punctuation is noise for a tab label.
	line = strings.TrimRight(line, " .,:;!?-")
	line = strings.TrimSpace(line)
	if line == "" {
		return ""
	}
	// Word cap.
	words := strings.Fields(line)
	if len(words) > maxTitleWords {
		words = words[:maxTitleWords]
		line = strings.Join(words, " ")
	}
	// Hard char cap (mirrors the §3.3 manual-rename limit). Trim back to a
	// word boundary so we don't slice mid-word.
	if len(line) > maxTitleLen {
		line = line[:maxTitleLen]
		if i := strings.LastIndexByte(line, ' '); i > 0 {
			line = line[:i]
		}
		line = strings.TrimSpace(line)
	}
	return line
}

// trimWrappingQuote removes one layer of matched wrapping quote/backtick
// from s, or returns s unchanged when it isn't wrapped.
func trimWrappingQuote(s string) string {
	if len(s) < 2 {
		return s
	}
	first, last := s[0], s[len(s)-1]
	if (first == '"' && last == '"') ||
		(first == '\'' && last == '\'') ||
		(first == '`' && last == '`') {
		return s[1 : len(s)-1]
	}
	return s
}
