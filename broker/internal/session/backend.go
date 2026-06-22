package session

import (
	"context"
	"fmt"

	"github.com/nikhilsh/conduit/broker/internal/agents"
)

// AgentBackend is a protocol implementation: everything the broker needs to
// drive a structured Chat-tab agent that speaks one wire protocol (claude's
// stream-json control protocol, codex's app-server JSON-RPC, the codex-exec
// per-turn fallback, …). Backends are keyed by adapter.Protocol — NOT by
// agent name — so a future agent speaking an existing protocol costs zero Go
// (see docs/PLAN-AGENT-PLATFORM.md Phase 2). Each implementation registers
// itself by protocol key in an init() via registerBackend.
//
// The seam formalizes what used to be the big claude/codex switch in
// startChatBackend, modelcatalog.go's catalogProbeFor, and accountusage.go's
// RefreshAccountUsage switch. The moves are behavior-preserving: the argv,
// wire frames, probe protocol and usage endpoints are byte-identical to the
// pre-refactor code (the golden tests pin this).
type AgentBackend interface {
	// Spawn builds the structured chat backend for a session. It owns the
	// protocol-specific construction (argv, RPC handshake, generator wiring
	// done the way each protocol natively expects it) and returns the backend
	// plus an optional self-heal respawn closure (nil when the protocol has
	// no long-lived process to respawn). The session-agnostic hook wiring
	// (push-notify idle/pending) is applied by the caller via the optional
	// interfaces below.
	Spawn(s *Session, adapter agents.Adapter, req spawnRequest) (spawnResult, error)

	// CatalogProbe returns the live model catalog by probing the agent CLI.
	// A backend whose protocol has no discovery probe returns a non-nil error;
	// maybeRefreshCatalog treats any probe error as "leave the cache untouched".
	CatalogProbe(ctx context.Context, bin string) ([]ModelInfo, error)

	// Usage fetches account-level subscription usage for the identity whose
	// credentials live under homeDir. ok=false means the protocol has no
	// usage source (the session then never fires a doomed fetch).
	Usage(ctx context.Context, do httpDoFunc, homeDir string) (usage AccountUsage, ok bool, err error)

	// Capabilities declares what the protocol supports. Feeds the per-assistant
	// descriptors in /api/capabilities (WS-2.3).
	Capabilities() BackendCapabilities
}

// BackendCapabilities is a protocol's self-declared feature set. It drives the
// per-assistant `supports` descriptor the apps render from (WS-2.3): unknown
// agents and protocols degrade gracefully because the app reads these flags
// instead of name-switching.
type BackendCapabilities struct {
	// Compact: the protocol supports an in-session /compact (history
	// summarization) — claude stream-json + codex app-server do; codex-exec
	// (per-turn) does not.
	Compact bool
	// AskUserQuestion: the protocol surfaces tappable choice/approval cards
	// that block the turn for the user's answer.
	AskUserQuestion bool
	// Effort: the protocol honors a reasoning-effort override.
	Effort bool
	// Resume: a session's conversation survives a respawn / broker restart.
	Resume bool
	// Interrupt: a running turn can be stopped without ending the session
	// (the composer Stop button).
	Interrupt bool
	// Usage: the protocol has an account-level subscription-usage source
	// (Usage returns ok=true). Drives the Session Info usage card's presence
	// in the per-assistant descriptor.
	Usage bool
	// Steer: the protocol supports injecting a message into a RUNNING turn
	// (turn/steer JSON-RPC). Drives the apps' "Queued Next" / "Steer" UI —
	// when true the composer queues + steers; when false it queues + holds
	// until the turn ends. Only codex app-server sets this true.
	Steer bool
}

// AgentDescriptor is the per-assistant capability descriptor served in
// /api/capabilities `agents` (WS-2.3). The apps render from these with a
// static fallback (PR #428 pattern), so an unknown agent degrades to a generic
// look and a new agent needs no app change. DisplayName/LoginProvider come from
// the adapter; Supports is the protocol's BackendCapabilities folded with the
// manifest's plan-mode rule; Models reuses the discovered ModelInfo slice.
type AgentDescriptor struct {
	DisplayName   string        `json:"display_name"`
	LoginProvider string        `json:"login_provider,omitempty"`
	Supports      AgentSupports `json:"supports"`
	Models        []ModelInfo   `json:"models,omitempty"`
}

// AgentSupports is the descriptor's feature-flag block, the wire shape the apps
// read instead of name-switching. compact/ask_user_question/effort/usage/steer
// come from BackendCapabilities; plan_mode from the manifest's permission_modes.
type AgentSupports struct {
	Compact         bool `json:"compact"`
	AskUserQuestion bool `json:"ask_user_question"`
	Effort          bool `json:"effort"`
	PlanMode        bool `json:"plan_mode"`
	Usage           bool `json:"usage"`
	Steer           bool `json:"steer"`
}

// spawnRequest carries the per-spawn inputs a backend needs that aren't on the
// Adapter: the AI-niceties generators (selected per session, wired into each
// protocol the way it natively expects) and the resume seeds.
type spawnRequest struct {
	// aiGen is the per-session AI-niceties provider (titles + quick replies),
	// nil when neither agent has creds. Each backend builds its own
	// quickReplyGenerator/titleGenerator from it and wires them natively
	// (claude through startChatProcess args, codex through setTurnHook).
	aiGen aiGenProvider

	// resumeChatSessionID seeds claude's --resume (stream-json conversation
	// id). "" = fresh conversation.
	resumeChatSessionID string
	// continueLatestChat appends claude's --continue when no id is known
	// (sessions recovered from a pre-latch broker).
	continueLatestChat bool
	// resumeCodexThreadID seeds codex's thread/resume. "" = new thread.
	resumeCodexThreadID string
	// forkChatSessionID, when non-empty, resumes AND forks the named claude
	// conversation via --resume <id> --fork-session, branching into a NEW
	// claude session id. The original is left untouched. For codex, there is
	// no wire-level fork; the codex backend falls back to plain resume
	// (resumeCodexThreadID) into the new worktree for isolation.
	forkChatSessionID string
}

// spawnResult is what a backend hands back: the live chatBackend and an
// optional self-heal respawn closure. respawn is nil for protocols with no
// long-lived process to revive (codex).
type spawnResult struct {
	backend chatBackend
	respawn func() (chatBackend, error)
}

// --- optional post-spawn hook interfaces ---
//
// These formalize the type-asserts that used to live inline in
// startChatBackend. A backend implements only the hooks its protocol fires;
// the caller wires whatever is present. Keeping them here (one place) means a
// new backend opts into push notifications / AI niceties by satisfying the
// matching interface — no edit to the wiring site.

// turnIdleHooker fires a callback after each turn ends (push notification when
// no client is attached). Implemented by all structured backends.
type turnIdleHooker interface {
	setTurnIdleHook(fn func())
}

// pendingInputHooker fires a callback when the backend stashes a pending
// approval/input card and waits for the user (push notification). Implemented
// by the codex app-server backend only.
type pendingInputHooker interface {
	setPendingInputHook(fn func())
}

// turnStartHooker fires a callback when the backend begins a new turn (before
// any tool/command fires). Used to start the Live Activity card as early as
// possible so the card is visible for the whole turn. Implemented by all
// structured backends.
type turnStartHooker interface {
	setTurnStartHook(fn func())
}

// backendRegistry maps adapter.Protocol → AgentBackend. Populated in init() by
// each implementation file via registerBackend. Resolution is by protocol key
// only; an empty protocol (legacy TUI-scrape adapters) resolves to no backend
// and the caller falls through to the chatScraper path.
var backendRegistry = map[string]AgentBackend{}

// registerBackend records a backend under its protocol key. Called from
// implementation file init()s. Panics on a duplicate key (a programming error
// — two files claiming the same protocol).
func registerBackend(protocol string, b AgentBackend) {
	if _, dup := backendRegistry[protocol]; dup {
		panic(fmt.Sprintf("session: duplicate backend for protocol %q", protocol))
	}
	backendRegistry[protocol] = b
}

// errNoBackend is returned by backendFor when no backend is registered for the
// protocol. An empty protocol returns it too (legacy scrape path); the chat
// startup treats both as "no structured backend".
var errNoBackend = fmt.Errorf("session: no backend for protocol")

// backendFor resolves the registered backend for a protocol key. An empty
// protocol (legacy TUI-scrape adapter) returns errNoBackend so the caller
// falls back to the scraper.
func backendFor(protocol string) (AgentBackend, error) {
	if protocol == "" {
		return nil, errNoBackend
	}
	b, ok := backendRegistry[protocol]
	if !ok {
		return nil, fmt.Errorf("%w %q", errNoBackend, protocol)
	}
	return b, nil
}

// backendForAssistant resolves the backend for an assistant by looking up its
// adapter's protocol in the registry. Used by the model-catalog probe and the
// account-usage refresh, which key off the assistant name. Returns errNoBackend
// when the assistant is unknown or its protocol has no backend.
func backendForAssistant(reg *agents.Registry, assistant string) (AgentBackend, error) {
	adapter, err := reg.Get(assistant)
	if err != nil {
		return nil, errNoBackend
	}
	return backendFor(adapter.Protocol)
}
