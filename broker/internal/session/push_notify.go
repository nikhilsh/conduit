package session

import (
	"context"
	"encoding/json"
	"fmt"
	"os"
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

// maybeNotifyTurnEnd fires a push notification when a turn just completed
// AND no client is currently attached to this session (subscriber count == 0).
// It debounces: at most one push per idlePushWindow per session. Safe for
// concurrent callers (the accumulateUsage / onTurnEnd sites may race with
// a re-attaching client).
func (s *Session) maybeNotifyTurnEnd() {
	// LA update: always emit (not gated on subscriber count) with event:"end".
	s.notifyLATurnEnd()

	if s.SubscriberCount() > 0 {
		return // someone is watching — don't notify
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

	name := s.displayOrAssistant()
	payload := push.Payload{
		Title:     name,
		Body:      "Turn finished",
		SessionID: s.ID,
	}
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	if err := n.Notify(ctx, id, payload); err != nil {
		fmt.Fprintf(os.Stderr, "push: turn-end notify session=%s: %v\n", s.ID, err)
	}
}

// maybeNotifyPendingInput fires a push notification when the agent is now
// blocked on an AskUserQuestion and no client is currently attached.
// Uses a separate debounce latch from turn-end so a pending-input doesn't
// suppress a subsequent turn-end push or vice-versa.
func (s *Session) maybeNotifyPendingInput() {
	// LA update: emit for pending-input (choice/permission interrupt).
	s.notifyLAPendingInput()

	if s.SubscriberCount() > 0 {
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
	payload := push.Payload{
		Title:     name,
		Body:      "Needs your input",
		SessionID: s.ID,
	}
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	if err := n.Notify(ctx, id, payload); err != nil {
		fmt.Fprintf(os.Stderr, "push: pending-input notify session=%s: %v\n", s.ID, err)
	}
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
	// laSender is the push Sender used for LA updates (typically the relay sender
	// for PlatformAPNs). Set via SetLASender.
	laSender push.Sender
	// identity is the single-operator bucket used for LA token lookup.
	identity string
	// lastLA records when the last LA push was emitted, for debounce.
	lastLA time.Time
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
// event is "update" or "end".
func (s *Session) emitLAUpdateImmediate(event string) {
	s.laState.mu.Lock()
	reg := s.laState.laTokens
	sender := s.laState.laSender
	identity := s.laState.identity
	if reg == nil || sender == nil || identity == "" {
		s.laState.mu.Unlock()
		return
	}
	token := reg.GetLA(identity, s.ID)
	if token == "" {
		s.laState.mu.Unlock()
		return
	}

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

	// Grab token counts from the session under s.mu.
	// Update lastLA time only on successful attempts, not here — we already
	// set it in maybeEmitLAUpdate.
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

	dt := push.DeviceToken{Platform: push.PlatformAPNs, Token: token}
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
}
