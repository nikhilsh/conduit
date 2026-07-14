package session

import "time"

// hibernationEligible reports whether s should be hibernated right now, given
// the configured idle window and the current time. ALL of the following must
// hold (docs/PLAN-SESSION-HIBERNATION.md §1); each condition is broken out
// into its own small helper so it can be pinned individually in tests:
//
//  1. the backend supports resume (a respawn can pick the conversation back
//     up) — the legacy TUI-scrape path and `shell` never hibernate;
//  2. the session has been idle (no chat/PTY output) for at least window;
//  3. no turn is currently in flight;
//  4. the session isn't blocked on a pending AskUserQuestion / approval —
//     hibernating would silently drop it;
//  5. no WS client is currently attached;
//  6. the session isn't pipeline/flow-managed (a pipeline drives its step
//     sessions programmatically; pausing one mid-run would stall it);
//  7. the process is actually alive and the phase still reads as live (guards
//     against racing an already-dying session).
func (s *Session) hibernationEligible(window time.Duration, now time.Time) bool {
	if !s.backendSupportsResume() {
		return false
	}
	if !s.idleSince(window, now) {
		return false
	}
	if active, present := s.structuredTurnActive(); present && active {
		return false
	}
	if s.blockedOnInput() {
		return false
	}
	if s.SubscriberCount() > 0 {
		return false
	}
	if s.isPipelineManaged() {
		return false
	}
	if !s.processAlive() {
		return false
	}
	s.mu.Lock()
	phase := s.phase
	s.mu.Unlock()
	return isLivePhase(phase)
}

// backendSupportsResume reports whether the session has a structured chat
// backend AND that backend's protocol declares Resume support. The legacy
// TUI-scrape path (s.chat == nil) and any protocol without Resume (none
// today, but the check stays honest) are never hibernation-eligible.
func (s *Session) backendSupportsResume() bool {
	s.mu.Lock()
	chat := s.chat
	adapter := s.adapter
	s.mu.Unlock()
	if chat == nil {
		return false
	}
	backend, err := backendFor(adapter.Protocol)
	if err != nil {
		return false
	}
	return backend.Capabilities().Resume
}

// idleSince reports whether the session's last activity clock (lastOutput,
// the same clock the watchdog uses) is at least window in the past. A zero
// lastOutput (shouldn't happen for a live session, but conservative) reports
// not-idle rather than risk hibernating something that never got its clock
// seeded.
func (s *Session) idleSince(window time.Duration, now time.Time) bool {
	s.mu.Lock()
	lastOutput := s.lastOutput
	s.mu.Unlock()
	if lastOutput.IsZero() {
		return false
	}
	return now.Sub(lastOutput) >= window
}

// blockedOnInput reports whether the session is waiting on the user's answer
// to an AskUserQuestion (s.pendingAsk) or a codex server-side approval
// request. Checked directly against pendingAsk rather than going through
// PendingAskChatContent/askUserQuestionContent: those answer "is there
// renderable card content" (ok=false on malformed input) — a different
// question from "is a decision outstanding". A hibernation must never drop a
// pending question just because its content happened to fail to render.
func (s *Session) blockedOnInput() bool {
	s.mu.Lock()
	ask := s.pendingAsk
	chat := s.chat
	s.mu.Unlock()
	if ask != nil {
		return true
	}
	if rs, ok := chat.(approvalCardResurfacer); ok {
		if _, pending := rs.PendingApprovalCard(); pending {
			return true
		}
	}
	return false
}

// isPipelineManaged reports whether this session was created by the pipeline
// subsystem to run a step (ws/pipeline.go CreateSession) rather than opened
// directly by a client.
func (s *Session) isPipelineManaged() bool {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.pipelineManaged
}
