package session

// chatBackend is a structured Chat-tab agent: it takes the user's composer
// messages and publishes chat view_events out of band (no PTY scraping).
// Both the claude stream-json *chatProcess and the codex exec/resume
// *codexChatProcess satisfy it; the session picks one by the adapter's
// chat_mode. See docs/PLAN-CHAT-CHANNEL.md (task #24).
type chatBackend interface {
	Send(text string) error
	Close() error
}

// structuredChatBackend maps an adapter's chat_mode to the backend kind:
//
//	"stream-json" → "claude"  (claude -p --input-format/--output-format stream-json)
//	"codex-exec"  → "codex"   (codex exec / exec resume)
//	anything else → ""        (legacy TUI-scrape path: PTY agent + chatScraper)
//
// Pure, so the routing decision is unit-testable without spawning anything.
func structuredChatBackend(chatMode string) string {
	switch chatMode {
	case "stream-json":
		return "claude"
	case "codex-exec":
		return "codex"
	default:
		return ""
	}
}
