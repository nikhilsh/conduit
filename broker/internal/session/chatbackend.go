package session

// chatBackend is a structured Chat-tab agent: it takes the user's composer
// messages and publishes chat view_events out of band (no PTY scraping).
// Both the claude stream-json *chatProcess and the codex exec/resume
// *codexChatProcess satisfy it; the session picks one by the adapter's
// chat_mode. See docs/PLAN-CHAT-CHANNEL.md (task #24).
type chatBackend interface {
	Send(text string) error
	// Interrupt stops the currently-running turn WITHOUT ending the session,
	// so the composer's Stop button can halt a streaming/working agent. A
	// no-op (nil) when no turn is in flight. claude writes a stream-json
	// `control_request {subtype:"interrupt"}`; codex app-server sends
	// `turn/interrupt`; codex-exec kills the in-flight turn process.
	Interrupt() error
	Close() error
	// TurnActive reports whether a turn is in flight right now. It is the
	// authoritative backend truth the broker folds into the status frame
	// (`turn_active`) so a reconnecting client can clear or keep its
	// "agent is working" indicator instead of guessing from the
	// conversation log's trailing role — the source of the stuck-indicator
	// bug when an app is backgrounded mid-turn. Must be cheap and
	// non-blocking (read a mutex-guarded flag).
	TurnActive() bool
}

// structuredChatBackend maps an adapter's chat_mode to the backend kind:
//
//	"stream-json"      → "claude"  (claude -p --input-format/--output-format stream-json)
//	"codex-exec"       → "codex"   (codex exec / exec resume — fallback path)
//	"codex-app-server" → "codex"   (codex app-server JSON-RPC; persistent thread)
//	anything else      → ""        (legacy TUI-scrape path: PTY agent + chatScraper)
//
// Both codex modes map to the "codex" branch; startChatBackend then picks the
// concrete backend (exec vs app-server) by the raw chat_mode. Pure, so the
// routing decision is unit-testable without spawning anything.
func structuredChatBackend(chatMode string) string {
	switch chatMode {
	case "stream-json":
		return "claude"
	case "codex-exec", "codex-app-server":
		return "codex"
	default:
		return ""
	}
}
