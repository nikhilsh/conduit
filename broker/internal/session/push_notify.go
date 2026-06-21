package session

import (
	"context"
	"encoding/json"
	"fmt"
	"log"
	"os"
	"strings"
	"sync"
	"time"

	"github.com/nikhilsh/conduit/broker/internal/push"
)

// jsonUnmarshal is an alias so tests can intercept it if needed.
var jsonUnmarshal = json.Unmarshal

// pushNotifyState is the per-session push-notification state:
// the notifier, the identity to notify under, and a debounce latch
// so rapid idle-transitions don't flood the device.
type pushNotifyState struct {
	mu       sync.Mutex
	notifier push.Notifier
	identity string
	// ownerDeviceID is the stable per-install UUID of the device that
	// created this session (from the WS connect device_id query param).
	// When non-empty, maybeNotifyTurnEnd and maybeNotifyPendingInput direct
	// the push to this device's token(s) via NotifyDevice, falling back to
	// broadcast Notify when the device has no stored token (e.g. token was
	// registered before device_id was introduced).
	// Empty for sessions created by old clients → always broadcasts.
	ownerDeviceID string
	// registry is the alert token registry, used to resolve ownerDeviceID
	// to a stored token set. Nil when no registry is wired (broadcast only).
	registry *push.Registry
	// dispatcher is the Dispatcher (type-asserting notifier) used when
	// per-device targeting is possible. Nil when notifier is not a *Dispatcher.
	dispatcher *push.Dispatcher
	// lastIdle records when the session last transitioned to idle. Used to
	// ensure at most one push per idle-transition: a turn that completes and
	// immediately starts another turn should not deliver two pushes.
	lastIdle time.Time
	// lastInput records when we last fired a pending-input push, for the
	// same coalescing reason.
	lastInput time.Time
}

// idlePushWindow is the minimum time between two consecutive turn-end pushes
// for the same session. A second turn that completes within this window after
// the first is coalesced into silence (the user either saw the first push or
// opened the session and is watching). 2 s covers rapid tool-loop completions
// without missing genuine idle states separated by real user think-time.
const idlePushWindow = 2 * time.Second

// SetPushNotifier wires the push notifier and the single-operator identity
// bucket into the session's notification state. Called by the Manager
// immediately after session creation. nil notifier is accepted and silently
// no-ops all notification attempts.
func (s *Session) SetPushNotifier(n push.Notifier, identity string) {
	s.pushState.mu.Lock()
	s.pushState.notifier = n
	s.pushState.identity = identity
	s.pushState.mu.Unlock()
}

// SetPushOwner records the owning device and wires the registry + dispatcher
// needed for per-device targeting. Called by the Manager after SetPushNotifier
// when OwnerDeviceID is non-empty. Safe to skip (no-op / broadcast fallback).
func (s *Session) SetPushOwner(ownerDeviceID string, reg *push.Registry, d *push.Dispatcher) {
	s.pushState.mu.Lock()
	s.pushState.ownerDeviceID = ownerDeviceID
	s.pushState.registry = reg
	s.pushState.dispatcher = d
	s.pushState.mu.Unlock()
}

// notifyTargeted delivers payload to the session's owner device when one is
// set AND has a registered token; otherwise it falls back to broadcasting via
// n.Notify. This is the single dispatch point for both turn-end and
// pending-input notifications so the broadcast fallback lives in one place.
//
// Invariant: never silently drops a push. An owner device with no stored token
// (e.g. device_id sent on create but token registered before device_id was
// introduced) falls through to broadcast.
func (s *Session) notifyTargeted(ctx context.Context, n push.Notifier, identity string, payload push.Payload) error {
	s.pushState.mu.Lock()
	ownerDeviceID := s.pushState.ownerDeviceID
	reg := s.pushState.registry
	dispatcher := s.pushState.dispatcher
	s.pushState.mu.Unlock()

	if ownerDeviceID != "" && reg != nil && dispatcher != nil {
		if matched := reg.TokensForDevice(identity, ownerDeviceID); len(matched) > 0 {
			return dispatcher.NotifyDevice(ctx, identity, ownerDeviceID, payload)
		}
		// No token stored yet for this device_id (old token, race on first
		// register) — fall through to broadcast so the push is not lost.
	}
	return n.Notify(ctx, identity, payload)
}

// maybeNotifyTurnEnd fires a push notification when a turn just completed
// AND no owner-device client is currently attached to this session.
// It debounces: at most one push per idlePushWindow per session. Safe for
// concurrent callers (the accumulateUsage / onTurnEnd sites may race with
// a re-attaching client).
//
// Gate semantics (Option A, §3 of PLAN-SSH-CHAT-TAKEOVER.md):
//   - Legacy (OwnerDeviceID == ""): suppress when SubscriberCount() > 0.
//     Byte-identical to the previous behavior — any viewer suppresses.
//   - Modern (OwnerDeviceID != ""): suppress only when the owner device
//     is currently connected. A non-owner subscriber (e.g. the SSH CLI)
//     carries no matching device_id and is invisible to this gate.
func (s *Session) maybeNotifyTurnEnd() {
	// LA update: always emit (not gated on subscriber count) with event:"end".
	s.notifyLATurnEnd()

	if s.ownerPresenceGate() {
		return // owner device is watching — don't alert
	}
	s.pushState.mu.Lock()
	n := s.pushState.notifier
	id := s.pushState.identity
	if n == nil || id == "" {
		s.pushState.mu.Unlock()
		return
	}
	now := pushNow()
	if now.Sub(s.pushState.lastIdle) < idlePushWindow {
		// Within the debounce window — coalesce.
		s.pushState.mu.Unlock()
		return
	}
	s.pushState.lastIdle = now
	s.pushState.mu.Unlock()

	title := s.pushTitleForSession()
	body := s.lastAssistantMessagePreview(100)
	log.Printf("push: turn-end session=%s title=%q body=%q", s.ID, title, body)
	payload := push.Payload{
		Title:     title,
		Body:      body,
		SessionID: s.ID,
	}
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	if err := s.notifyTargeted(ctx, n, id, payload); err != nil {
		fmt.Fprintf(os.Stderr, "push: turn-end notify session=%s: %v\n", s.ID, err)
	}
}

// maybeNotifyPendingInput fires a push notification when the agent is now
// blocked on an AskUserQuestion and no owner-device client is currently attached.
// Uses a separate debounce latch from turn-end so a pending-input doesn't
// suppress a subsequent turn-end push or vice-versa.
//
// When the pending input is a codex approval-type request (command or
// file-change), the notification carries Category="approval" and the approval
// summary as the body (truncated to 120 chars) so iOS/Android can render an
// actionable approval notification without opening the app. Generic pending
// input (AskUserQuestion, elicitation, etc.) carries Category="input".
//
// Gate semantics: same owner-presence logic as maybeNotifyTurnEnd (see above).
func (s *Session) maybeNotifyPendingInput() {
	// LA update: emit for pending-input (choice/permission interrupt).
	s.notifyLAPendingInput()

	if s.ownerPresenceGate() {
		return
	}
	s.pushState.mu.Lock()
	n := s.pushState.notifier
	id := s.pushState.identity
	if n == nil || id == "" {
		s.pushState.mu.Unlock()
		return
	}
	now := pushNow()
	if now.Sub(s.pushState.lastInput) < idlePushWindow {
		s.pushState.mu.Unlock()
		return
	}
	s.pushState.lastInput = now
	s.pushState.mu.Unlock()

	name := s.displayOrAssistant()

	// Distinguish approval-type pending input from generic pending input.
	body := "Needs your input"
	category := "input"
	if summary, isApproval := s.PendingApprovalSummaryForPush(); isApproval && summary != "" {
		category = "approval"
		body = truncatePushBody(summary, 120)
	}

	payload := push.Payload{
		Title:     name,
		Body:      body,
		SessionID: s.ID,
		Category:  category,
	}
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	if err := s.notifyTargeted(ctx, n, id, payload); err != nil {
		fmt.Fprintf(os.Stderr, "push: pending-input notify session=%s: %v\n", s.ID, err)
	}
}

// ownerPresenceGate returns true when the push should be suppressed because
// the device that should receive it is currently connected and watching.
//
// Two-path logic (Option A, PLAN-SSH-CHAT-TAKEOVER.md §3):
//   - Legacy (OwnerDeviceID == ""): suppress when any PTY subscriber is present,
//     exactly as before. Preserves byte-identical behavior for old clients.
//   - Modern (OwnerDeviceID != ""): suppress only when an owner-device WS client
//     is connected. Non-owner subscribers (SSH CLI, future PTY viewers that are
//     not the owner phone) do NOT suppress the owner phone's alert pushes.
func (s *Session) ownerPresenceGate() bool {
	if s.OwnerDeviceID() == "" {
		// Legacy path: any subscriber suppresses (unchanged behavior).
		return s.SubscriberCount() > 0
	}
	// Modern path: only owner-device presence suppresses.
	return s.OwnerDeviceConnected()
}

// truncatePushBody truncates s to at most maxLen runes, appending "…" when
// truncated. Used to bound approval summaries in push notification bodies.
func truncatePushBody(s string, maxLen int) string {
	runes := []rune(s)
	if len(runes) <= maxLen {
		return s
	}
	return string(runes[:maxLen]) + "…"
}

// displayOrAssistant returns the best human-readable label for the session
// (manual display name if set, otherwise the assistant name).
func (s *Session) displayOrAssistant() string {
	s.mu.Lock()
	name := s.displayName
	s.mu.Unlock()
	if name != "" {
		return name
	}
	return s.Assistant
}

// pushTitleForSession returns the notification title for turn-end pushes.
// Format: "{AgentName} · {SessionName}" when a session name exists,
// otherwise just "{AgentName}". Session name priority: manual displayName >
// AI-generated aiTitle. The middle dot (U+00B7) is the same separator used
// in the iOS status bar for compound labels.
func (s *Session) pushTitleForSession() string {
	s.mu.Lock()
	agent := s.Assistant
	display := s.displayName
	ai := s.aiTitle
	s.mu.Unlock()

	sessionName := display
	if sessionName == "" {
		sessionName = ai
	}
	if sessionName == "" {
		return agent
	}
	return agent + " · " + sessionName
}

// lastAssistantMessagePreview reads the most recent assistant message from the
// session's conversation log and returns its text truncated to maxLen runes.
// Returns "Turn complete" when no assistant message is found (new session,
// convLog missing, or only non-text messages).
func (s *Session) lastAssistantMessagePreview(maxLen int) string {
	s.mu.Lock()
	logPath := ""
	if s.convLog != nil {
		logPath = s.convLog.path
	}
	s.mu.Unlock()

	if logPath == "" {
		return "Turn complete"
	}

	entries, err := readConvLog(logPath)
	if err != nil {
		return "Turn complete"
	}

	// Walk backwards to find the last assistant message.
	for i := len(entries) - 1; i >= 0; i-- {
		e := entries[i]
		if e.Role != "assistant" {
			continue
		}
		text := strings.TrimSpace(e.Content)
		if text == "" {
			continue
		}
		// Strip any pending-input sentinel prefix so it's never surfaced raw.
		if strings.HasPrefix(text, pendingInputSentinel) {
			continue
		}
		return truncatePushBody(text, maxLen)
	}
	return "Turn complete"
}

// pushNow is the clock for push notification timestamps; overridable in tests.
var pushNow = time.Now

// -----------------------------------------------------------------------
// Live Activity (LA) push notification state and emission.
// -----------------------------------------------------------------------

// laPushState holds the per-session Live Activity push state: the LA token
// registry, sender, and debounce latch for LA-specific updates.
type laPushState struct {
	mu sync.Mutex
	// laTokens is the registry keyed by (identity, session_id).
	laTokens *push.LARegistry
	// alertRegistry is the persisted alert token registry that also stores the
	// push-to-start token (PlatformAPNsLiveActivityStart). Used by emitLAStart
	// to look up the device-scoped start token via StartTokenFor.
	alertRegistry *push.Registry
	// laSender is the push Sender used for LA updates (typically the relay sender
	// for PlatformAPNs). Set via SetLASender.
	laSender push.Sender
	// identity is the single-operator bucket used for LA token lookup.
	identity string
	// lastLA records when the last LA push was emitted, for debounce.
	lastLA time.Time
	// lastLAStart records when the last push-to-start emit occurred, for
	// debouncing double-start within the ~2s window before the device registers
	// its update token after a start push. Mirrors the lastLA/idlePushWindow pattern.
	lastLAStart time.Time
	// currentTool is the tool most recently reported active in this session.
	currentTool string
	// currentCommand is the shell command most recently reported active.
	currentCommand string
	// summary is the AI-generated session summary (from titleGen / aiTitle).
	summary string
	// interruptKind is set when the session is blocked on a pending-input:
	// "choice" for AskUserQuestion multi-select, "permission" for tool approval.
	interruptKind string
	// prompt is the question text of the pending input.
	prompt string
	// optionCount is the number of options for a multi-select.
	optionCount int
	// status is one of "running", "pending", "exited".
	status string
	// turnStartedAt is when the current turn began. Set to pushNow() on first
	// LA update for a turn; persists until next turn starts.
	turnStartedAt time.Time
}

// SetLAState wires the LA registry, sender, and identity into the session.
// Called from the Manager after the session is constructed. Nil-safe: absent
// wiring silently no-ops all LA emission.
func (s *Session) SetLAState(reg *push.LARegistry, sender push.Sender, identity string) {
	s.laState.mu.Lock()
	s.laState.laTokens = reg
	s.laState.laSender = sender
	s.laState.identity = identity
	s.laState.status = "running"
	s.laState.mu.Unlock()
}

// SetLAAlertRegistry wires the persisted alert Registry into the session's LA
// state so emitLAStart can look up the push-to-start token via StartTokenFor.
// Called from the Manager after SetLAState. Nil-safe.
func (s *Session) SetLAAlertRegistry(reg *push.Registry) {
	s.laState.mu.Lock()
	s.laState.alertRegistry = reg
	s.laState.mu.Unlock()
}

// SetLACurrentTool records a tool change and fires a debounced LA update.
// Safe to call from any goroutine. No-op if no LA token is registered for
// the session.
func (s *Session) SetLACurrentTool(toolName string) {
	s.laState.mu.Lock()
	s.laState.currentTool = toolName
	s.laState.currentCommand = ""
	// Reset interrupt state on tool activity — the agent is active again.
	s.laState.interruptKind = ""
	s.laState.prompt = ""
	s.laState.optionCount = 0
	if s.laState.status != "exited" {
		s.laState.status = "running"
	}
	if s.laState.turnStartedAt.IsZero() {
		s.laState.turnStartedAt = pushNow()
	}
	s.laState.mu.Unlock()
	s.maybeEmitLAUpdate()
}

// SetLACurrentCommand records a shell command change and fires a debounced LA update.
// Safe to call from any goroutine.
func (s *Session) SetLACurrentCommand(cmd string) {
	s.laState.mu.Lock()
	s.laState.currentCommand = cmd
	s.laState.currentTool = ""
	if s.laState.status != "exited" {
		s.laState.status = "running"
	}
	if s.laState.turnStartedAt.IsZero() {
		s.laState.turnStartedAt = pushNow()
	}
	s.laState.mu.Unlock()
	s.maybeEmitLAUpdate()
}

// notifyLATurnEnd is called from maybeNotifyTurnEnd to emit an LA "end" event.
// Not gated on subscriber count (LA card tracks even when app is foregrounded-but-locked).
func (s *Session) notifyLATurnEnd() {
	s.laState.mu.Lock()
	s.laState.status = "exited"
	s.laState.interruptKind = ""
	s.laState.prompt = ""
	s.laState.optionCount = 0
	s.laState.mu.Unlock()
	s.emitLAUpdateImmediate("end")
}

// notifyLAPendingInput is called from maybeNotifyPendingInput to emit an LA
// "update" event reflecting the pending-input state.
func (s *Session) notifyLAPendingInput() {
	s.laState.mu.Lock()
	s.laState.status = "pending"
	// Determine interruptKind from the pending ask.
	// We look at pendingAsk under s.mu to classify it.
	s.laState.mu.Unlock()

	// Read pending ask info under s.mu.
	s.mu.Lock()
	ask := s.pendingAsk
	s.mu.Unlock()

	kind := "permission"
	prompt := ""
	optionCount := 0
	if ask != nil {
		kind, prompt, optionCount = classifyPendingAsk(ask)
	}

	s.laState.mu.Lock()
	s.laState.interruptKind = kind
	s.laState.prompt = prompt
	s.laState.optionCount = optionCount
	s.laState.mu.Unlock()

	s.emitLAUpdateImmediate("update")
}

// classifyPendingAsk extracts interruptKind/prompt/optionCount from a pending ask.
func classifyPendingAsk(ask *pendingAsk) (kind, prompt string, optionCount int) {
	// Parse the input to classify AskUserQuestion vs. tool approval.
	if ask == nil {
		return "permission", "", 0
	}
	var input struct {
		Questions []struct {
			Question string   `json:"question"`
			Options  []string `json:"options"`
		} `json:"questions"`
	}
	if len(ask.input) > 0 {
		if err := jsonUnmarshal(ask.input, &input); err == nil && len(input.Questions) > 0 {
			q := input.Questions[0]
			prompt = q.Question
			optionCount = len(q.Options)
			if optionCount > 0 {
				return "choice", prompt, optionCount
			}
		}
	}
	return "permission", prompt, 0
}

// maybeEmitLAUpdate emits a debounced LA "update" push (1–2s coalesce window).
func (s *Session) maybeEmitLAUpdate() {
	s.laState.mu.Lock()
	now := pushNow()
	if now.Sub(s.laState.lastLA) < idlePushWindow {
		s.laState.mu.Unlock()
		return
	}
	s.laState.lastLA = now
	s.laState.mu.Unlock()
	s.emitLAUpdateImmediate("update")
}

// emitLAUpdateImmediate sends an LA push unconditionally (no debounce).
// event is "update" or "end". If no update token exists for the session and
// event != "end", it attempts a push-to-start via emitLAStart (§G1).
func (s *Session) emitLAUpdateImmediate(event string) {
	s.laState.mu.Lock()
	reg := s.laState.laTokens
	sender := s.laState.laSender
	identity := s.laState.identity
	if reg == nil || sender == nil || identity == "" {
		s.laState.mu.Unlock()
		return
	}
	updateToken := reg.GetLA(identity, s.ID)
	if updateToken != "" {
		// Existing path: a card is live — send update or end to it.
		// Build content_state from current LA state.
		nowMs := pushNow().UnixMilli()
		cs := map[string]any{
			"status":     s.laState.status,
			"syncedAtMs": nowMs,
		}
		if !s.laState.turnStartedAt.IsZero() {
			cs["startedAtMs"] = s.laState.turnStartedAt.UnixMilli()
		} else {
			cs["startedAtMs"] = nowMs
		}
		if s.laState.currentTool != "" {
			cs["currentTool"] = s.laState.currentTool
		}
		if s.laState.currentCommand != "" {
			cs["currentCommand"] = s.laState.currentCommand
		}
		if s.laState.summary != "" {
			cs["summary"] = s.laState.summary
		}
		if s.laState.interruptKind != "" {
			cs["interruptKind"] = s.laState.interruptKind
		}
		if s.laState.prompt != "" {
			cs["prompt"] = s.laState.prompt
		}
		if s.laState.optionCount > 0 {
			cs["optionCount"] = s.laState.optionCount
		}

		if event == "end" {
			// On end, drop the LA token so we don't send further updates.
			reg.DropLA(identity, s.ID)
		}

		name := s.laState.identity // title fallback
		s.laState.mu.Unlock()

		// Read token counts outside laState.mu (s.mu is a different lock).
		s.mu.Lock()
		tokIn := s.totalInputTokens
		tokOut := s.totalOutputTokens
		s.mu.Unlock()
		if tokIn > 0 || tokOut > 0 {
			cs["tokensIn"] = int64(tokIn)
			cs["tokensOut"] = int64(tokOut)
		}

		// Use the display name as the notification title.
		displayName := s.displayOrAssistant()
		if displayName == "" {
			displayName = name
		}

		dt := push.DeviceToken{Platform: push.PlatformAPNs, Token: updateToken}
		payload := push.Payload{
			Title:        displayName,
			Body:         "Turn in progress",
			SessionID:    s.ID,
			Category:     "liveactivity",
			Event:        event,
			ContentState: cs,
		}
		ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
		defer cancel()
		if err := sender.Send(ctx, dt, payload); err != nil {
			fmt.Fprintf(os.Stderr, "push: LA update session=%s event=%s: %v\n", s.ID, event, err)
		}
		return
	}

	// No live card known for this session.
	if event == "end" {
		// Nothing to end — no card exists.
		s.laState.mu.Unlock()
		return
	}

	// Attempt push-to-start (G1): only when backgrounded (no subscribers).
	alertReg := s.laState.alertRegistry
	// Debounce: if we already emitted a start within idlePushWindow, suppress.
	now := pushNow()
	if now.Sub(s.laState.lastLAStart) < idlePushWindow {
		s.laState.mu.Unlock()
		return
	}
	s.laState.mu.Unlock()

	// SubscriberCount reads s.mu — must be called outside laState.mu to avoid
	// potential lock-order issues.
	if s.SubscriberCount() > 0 {
		// App is foreground/attached — it will call Activity.request itself.
		// Do NOT emit a start (foreground/start contract: exactly one party starts).
		return
	}

	if alertReg == nil {
		return
	}
	startToken := alertReg.StartTokenFor(identity)
	if startToken == "" {
		return
	}

	// Record the debounce latch before sending.
	s.laState.mu.Lock()
	// Re-check after re-acquiring the lock (could have been set concurrently).
	if now.Sub(s.laState.lastLAStart) < idlePushWindow {
		s.laState.mu.Unlock()
		return
	}
	s.laState.lastLAStart = now
	s.laState.mu.Unlock()

	s.emitLAStart(startToken, sender)
}

// emitLAStart sends a push-to-start Live Activity push to the device.
// Called when no per-session update token exists and the app is backgrounded.
// startToken is the device-scoped PlatformAPNsLiveActivityStart token.
func (s *Session) emitLAStart(startToken string, sender push.Sender) {
	// Build content_state snapshot (same shape as update).
	s.laState.mu.Lock()
	nowMs := pushNow().UnixMilli()
	cs := map[string]any{
		"status":     s.laState.status,
		"syncedAtMs": nowMs,
	}
	if !s.laState.turnStartedAt.IsZero() {
		cs["startedAtMs"] = s.laState.turnStartedAt.UnixMilli()
	} else {
		cs["startedAtMs"] = nowMs
	}
	if s.laState.currentTool != "" {
		cs["currentTool"] = s.laState.currentTool
	}
	if s.laState.currentCommand != "" {
		cs["currentCommand"] = s.laState.currentCommand
	}
	if s.laState.summary != "" {
		cs["summary"] = s.laState.summary
	}
	if s.laState.interruptKind != "" {
		cs["interruptKind"] = s.laState.interruptKind
	}
	if s.laState.prompt != "" {
		cs["prompt"] = s.laState.prompt
	}
	if s.laState.optionCount > 0 {
		cs["optionCount"] = s.laState.optionCount
	}
	identity := s.laState.identity
	s.laState.mu.Unlock()

	// Read token counts outside laState.mu.
	s.mu.Lock()
	tokIn := s.totalInputTokens
	tokOut := s.totalOutputTokens
	s.mu.Unlock()
	if tokIn > 0 || tokOut > 0 {
		cs["tokensIn"] = int64(tokIn)
		cs["tokensOut"] = int64(tokOut)
	}

	displayName := s.displayOrAssistant()
	if displayName == "" {
		displayName = identity
	}

	// Determine a useful alert body: prefer the pending prompt, fall back to
	// a generic "is working" message.
	alertBody := "is working"
	s.laState.mu.Lock()
	if s.laState.prompt != "" {
		alertBody = s.laState.prompt
	} else if s.laState.interruptKind == "permission" {
		alertBody = "Needs your input"
	}
	s.laState.mu.Unlock()

	// AttributesType and Attributes wire contract (critical — silent OS reject on typo):
	// AttributesType MUST be exactly "TurnActivityAttributes" (the iOS struct name).
	// Attributes keys MUST be exactly "agentName", "sessionID", "sessionName".
	// See: TurnActivityAttributes.swift, docs/PLAN-push-to-start-la.md §2.3.
	dt := push.DeviceToken{Platform: push.PlatformAPNsLiveActivityStart, Token: startToken}
	payload := push.Payload{
		Title:          displayName,
		Body:           alertBody,
		SessionID:      s.ID,
		Category:       "liveactivity",
		Event:          "start",
		ContentState:   cs,
		AttributesType: "TurnActivityAttributes",
		Attributes: map[string]any{
			"agentName":   s.Assistant,
			"sessionID":   s.ID,
			"sessionName": displayName,
		},
		Alert: map[string]any{
			"title": displayName,
			"body":  alertBody,
		},
	}
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	if err := sender.Send(ctx, dt, payload); err != nil {
		fmt.Fprintf(os.Stderr, "push: LA start session=%s: %v\n", s.ID, err)
	}
}
