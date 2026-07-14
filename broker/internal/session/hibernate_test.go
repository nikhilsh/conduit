package session

import (
	"encoding/json"
	"testing"
	"time"

	"github.com/nikhilsh/conduit/broker/internal/agents"
)

// ---------------------------------------------------------------------------
// Pure predicate unit tests — no spawned process needed (mirrors
// turnactive_test.go's &Session{} pattern). Each hibernationEligible
// sub-condition gets its own helper (hibernate.go) so it's pinned here in
// isolation before the integrated matrix below.
// ---------------------------------------------------------------------------

func TestBackendSupportsResume(t *testing.T) {
	s := &Session{}
	if s.backendSupportsResume() {
		t.Fatal("nil chat backend (TUI-scrape path) must never support resume")
	}
	s.chat = &turnBackend{active: false}
	s.adapter = agents.Adapter{Protocol: "does-not-exist"}
	if s.backendSupportsResume() {
		t.Fatal("an unregistered protocol must not support resume")
	}
	s.adapter = agents.Adapter{Protocol: "stream-json"}
	if !s.backendSupportsResume() {
		t.Fatal("stream-json (claude) declares Resume:true and must report supported")
	}
}

func TestIdleSince(t *testing.T) {
	s := &Session{}
	now := time.Now()
	window := 30 * time.Minute

	if s.idleSince(window, now) {
		t.Fatal("a zero lastOutput (never seeded) must report NOT idle — conservative default")
	}
	s.lastOutput = now.Add(-5 * time.Minute)
	if s.idleSince(window, now) {
		t.Fatal("5m idle must not satisfy a 30m window")
	}
	s.lastOutput = now.Add(-40 * time.Minute)
	if !s.idleSince(window, now) {
		t.Fatal("40m idle must satisfy a 30m window")
	}
	s.lastOutput = now.Add(-window)
	if !s.idleSince(window, now) {
		t.Fatal("idle == window must satisfy (>=, not >)")
	}
}

// approvalPendingBackend is a chatBackend that also implements
// approvalCardResurfacer with a controllable pending state, so blockedOnInput
// can be pinned for the codex-approval half of the check independently of
// pendingAsk (the claude-AskUserQuestion half).
type approvalPendingBackend struct {
	turnBackend
	pending bool
}

func (b *approvalPendingBackend) PendingApprovalCard() (string, bool) {
	if !b.pending {
		return "", false
	}
	return "card", true
}

func TestBlockedOnInput(t *testing.T) {
	s := &Session{}
	if s.blockedOnInput() {
		t.Fatal("no chat, no pendingAsk: must not be blocked")
	}

	s.pendingAsk = &pendingAsk{requestID: "req-1"}
	if !s.blockedOnInput() {
		t.Fatal("a non-nil pendingAsk must block, regardless of its content rendering")
	}
	s.pendingAsk = nil
	if s.blockedOnInput() {
		t.Fatal("clearing pendingAsk must unblock")
	}

	s.chat = &approvalPendingBackend{pending: true}
	if !s.blockedOnInput() {
		t.Fatal("a codex backend reporting a pending approval card must block")
	}
	s.chat.(*approvalPendingBackend).pending = false
	if s.blockedOnInput() {
		t.Fatal("no pending approval + no pendingAsk must not block")
	}
}

func TestIsPipelineManaged(t *testing.T) {
	s := &Session{}
	if s.isPipelineManaged() {
		t.Fatal("default must be false — not pipeline-managed")
	}
	s.pipelineManaged = true
	if !s.isPipelineManaged() {
		t.Fatal("must reflect pipelineManaged = true")
	}
}

// ---------------------------------------------------------------------------
// Integrated eligibility matrix — a real spawned (legacy-adapter) session
// gives hibernationEligible a genuinely alive process + live phase; the
// structured-backend half is bolted on directly (same technique
// TestSwitchRepointsChatBackend / turnactive_test.go use) so the test needs
// no real claude/codex binary. Each sub-test flips exactly one condition off
// a known-eligible baseline.
// ---------------------------------------------------------------------------

func newEligibleTestSession(t *testing.T) (*Manager, *Session) {
	t.Helper()
	root := testRoot(t)
	reg := testRegistry(t, root, map[string]string{"claude": idleScript("hib-elig-ready")})
	m := NewManager(reg)
	t.Cleanup(m.Close)

	sess, created, err := m.GetOrCreate("session-hib-elig", "claude")
	if err != nil {
		t.Fatalf("GetOrCreate: %v", err)
	}
	if !created {
		t.Fatal("expected new session")
	}
	waitForOutput(t, sess, "hib-elig-ready")

	// Bolt on a resumable structured backend — the fixture adapter otherwise
	// has no chat_mode (legacy TUI-scrape), which is never eligible by
	// design (condition 1). The real PTY process (idleScript) stays alive
	// underneath, satisfying condition 7 (processAlive + isLivePhase).
	sess.mu.Lock()
	sess.adapter.Protocol = "stream-json"
	sess.chat = &turnBackend{active: false}
	sess.lastOutput = time.Now().Add(-40 * time.Minute) // stale — satisfies the default 30m window
	sess.mu.Unlock()

	return m, sess
}

func TestHibernationEligible_Baseline(t *testing.T) {
	_, sess := newEligibleTestSession(t)
	window := 30 * time.Minute
	now := time.Now()
	if !sess.hibernationEligible(window, now) {
		t.Fatal("a resumable, idle, turn-quiet, unblocked, unviewed, non-pipeline, live session must be eligible")
	}
}

func TestHibernationEligible_MidTurn(t *testing.T) {
	_, sess := newEligibleTestSession(t)
	sess.mu.Lock()
	sess.chat = &turnBackend{active: true}
	sess.mu.Unlock()
	if sess.hibernationEligible(30*time.Minute, time.Now()) {
		t.Fatal("a session with a turn in flight must not be hibernation-eligible")
	}
}

func TestHibernationEligible_AttachedClient(t *testing.T) {
	_, sess := newEligibleTestSession(t)
	ch := attachViewer(sess)
	defer detachViewer(sess, ch)
	if sess.hibernationEligible(30*time.Minute, time.Now()) {
		t.Fatal("a session with an attached WS client must not be hibernation-eligible")
	}
}

func TestHibernationEligible_PendingAsk(t *testing.T) {
	_, sess := newEligibleTestSession(t)
	sess.mu.Lock()
	sess.pendingAsk = &pendingAsk{requestID: "req-1"}
	sess.mu.Unlock()
	if sess.hibernationEligible(30*time.Minute, time.Now()) {
		t.Fatal("a session blocked on a pending AskUserQuestion must not be hibernation-eligible")
	}
}

func TestHibernationEligible_PipelineManaged(t *testing.T) {
	_, sess := newEligibleTestSession(t)
	sess.mu.Lock()
	sess.pipelineManaged = true
	sess.mu.Unlock()
	if sess.hibernationEligible(30*time.Minute, time.Now()) {
		t.Fatal("a pipeline-managed step session must not be hibernation-eligible")
	}
}

func TestHibernationEligible_NonResumableBackend(t *testing.T) {
	_, sess := newEligibleTestSession(t)
	sess.mu.Lock()
	sess.chat = nil // legacy TUI-scrape path
	sess.mu.Unlock()
	if sess.hibernationEligible(30*time.Minute, time.Now()) {
		t.Fatal("a session with no structured chat backend must not be hibernation-eligible")
	}
}

func TestHibernationEligible_FreshIdle(t *testing.T) {
	_, sess := newEligibleTestSession(t)
	sess.mu.Lock()
	sess.lastOutput = time.Now().Add(-5 * time.Minute) // well inside a 30m window
	sess.mu.Unlock()
	if sess.hibernationEligible(30*time.Minute, time.Now()) {
		t.Fatal("a freshly-active session must not be hibernation-eligible")
	}
}

func TestHibernationEligible_DeadProcess(t *testing.T) {
	_, sess := newEligibleTestSession(t)
	sess.mu.Lock()
	sess.phase = "exited" // simulates the watchdog's post-death phase without
	sess.mu.Unlock()      // actually killing the shared test process
	if sess.hibernationEligible(30*time.Minute, time.Now()) {
		t.Fatal("a session whose phase no longer reads live must not be hibernation-eligible")
	}
}

// ---------------------------------------------------------------------------
// hibernateSession round trip: Close() + markHibernatedOnDisk() on the way
// down, GetOrCreateWithOptions (recoverSessionLocked) on the way up.
// ---------------------------------------------------------------------------

func TestHibernateSessionRoundTrip(t *testing.T) {
	root := testRoot(t)
	reg := testRegistry(t, root, map[string]string{"claude": idleScript("hib-rt-ready")})
	m := NewManager(reg)
	t.Cleanup(m.Close)

	sess, created, err := m.GetOrCreate("session-hib-rt", "claude")
	if err != nil {
		t.Fatalf("GetOrCreate: %v", err)
	}
	if !created {
		t.Fatal("expected new session")
	}
	waitForOutput(t, sess, "hib-rt-ready")

	m.hibernateSession(sess)

	// Dropped from the live map the instant hibernateSession returns —
	// mirrors DeleteSession's synchronous-delete guarantee (delete_test.go),
	// not the async Done()-watcher reaper.
	if _, ok := m.Get("session-hib-rt"); ok {
		t.Fatal("session still in the live map after hibernateSession")
	}

	meta, err := m.readSessionMeta("session-hib-rt")
	if err != nil {
		t.Fatalf("readSessionMeta: %v", err)
	}
	if !meta.Hibernated {
		t.Fatal("meta.json must be flagged hibernated:true")
	}
	if meta.Phase != "hibernated" {
		t.Fatalf("meta.Phase = %q, want %q", meta.Phase, "hibernated")
	}
	if meta.ReasonCode != "hibernated" {
		t.Fatalf("meta.ReasonCode = %q, want %q", meta.ReasonCode, "hibernated")
	}
	if meta.HibernatedAt == "" {
		t.Fatal("meta.HibernatedAt must be set")
	}
	if _, err := time.Parse(time.RFC3339Nano, meta.HibernatedAt); err != nil {
		t.Fatalf("meta.HibernatedAt not RFC3339Nano: %v", err)
	}

	if !m.IsHibernated("session-hib-rt") {
		t.Fatal("IsHibernated must report true for a hibernated session")
	}

	// RecoverableSessions surfaces the wire shape from
	// docs/PLAN-SESSION-HIBERNATION.md §5: recoverable:true, hibernated:true,
	// phase:"hibernated", running:false.
	var found *LiveSessionInfo
	for _, info := range m.RecoverableSessions() {
		if info.ID == "session-hib-rt" {
			f := info
			found = &f
			break
		}
	}
	if found == nil {
		t.Fatal("hibernated session missing from RecoverableSessions")
	}
	if !found.Recoverable {
		t.Error("recoverable entry must have Recoverable = true")
	}
	if !found.Hibernated {
		t.Error("recoverable entry must have Hibernated = true")
	}
	if found.Phase != "hibernated" {
		t.Errorf("recoverable entry Phase = %q, want hibernated", found.Phase)
	}
	if found.Running {
		t.Error("recoverable entry must have Running = false")
	}

	// Waking: GetOrCreateWithOptions reuses the standard lazy-recovery path
	// (recoverSessionLocked) — no new spawn code. The assistant arg is
	// ignored on the recovery branch (meta.Assistant wins).
	woken, wcreated, err := m.GetOrCreateWithOptions("session-hib-rt", "", CreateOptions{})
	if err != nil {
		t.Fatalf("GetOrCreateWithOptions (wake): %v", err)
	}
	if wcreated {
		t.Fatal("waking a hibernated session must recover it, not report a fresh create")
	}
	waitForOutput(t, woken, "hib-rt-ready")
	if st := woken.Status(); st.Phase != "running" {
		t.Fatalf("woken phase = %q, want running (recovery.go normalizes non-live phases)", st.Phase)
	}

	// The persisted hibernated marker is cleared implicitly on the next
	// live persistMetadata (never re-written by the live path; omitempty
	// drops it).
	if err := woken.persistMetadata(); err != nil {
		t.Fatalf("persistMetadata: %v", err)
	}
	meta2, err := m.readSessionMeta("session-hib-rt")
	if err != nil {
		t.Fatalf("readSessionMeta after wake: %v", err)
	}
	if meta2.Hibernated {
		t.Fatal("hibernated flag must be cleared after the woken session's next persistMetadata")
	}
	if m.IsHibernated("session-hib-rt") {
		t.Fatal("IsHibernated must report false once the session is live again")
	}
}

// TestHibernateSessionCancelsGenuineStopTimer pins that hibernating a session
// never lets a stale "session ended" push / Live-Activity teardown fire
// afterward: Close() calls cancelPendingTurnEndPush BEFORE tearing anything
// else down (manager.go Close doc comment / PLAN §4).
func TestHibernateSessionCancelsGenuineStopTimer(t *testing.T) {
	root := testRoot(t)
	reg := testRegistry(t, root, map[string]string{"claude": idleScript("hib-la-ready")})
	m := NewManager(reg)
	t.Cleanup(m.Close)

	sess, _, err := m.GetOrCreate("session-hib-la", "claude")
	if err != nil {
		t.Fatalf("GetOrCreate: %v", err)
	}
	waitForOutput(t, sess, "hib-la-ready")

	n := &recordingNotifier{}
	sess.SetPushNotifier(n, "broker")
	la := &recordingSender{}
	sess.SetLAState(nil, la, "broker")

	// Arm the genuine-stop timer exactly as a real turn-end would (no
	// owner-device client attached).
	sess.maybeNotifyTurnEnd()
	sess.pushState.mu.Lock()
	armed := sess.pushState.pendingStopTimer != nil
	sess.pushState.mu.Unlock()
	if !armed {
		t.Fatal("maybeNotifyTurnEnd must arm the genuine-stop timer with no client attached")
	}

	m.hibernateSession(sess)

	sess.pushState.mu.Lock()
	stillArmed := sess.pushState.pendingStopTimer != nil
	sess.pushState.mu.Unlock()
	if stillArmed {
		t.Fatal("hibernate (Close) must cancel the pending genuine-stop timer")
	}
	if n.count() != 0 {
		t.Fatalf("hibernate must not itself send a turn-end push, got %d", n.count())
	}
	if la.count() != 0 {
		t.Fatalf("hibernate must not itself send an LA update, got %d", la.count())
	}
}

// ---------------------------------------------------------------------------
// Sweep + loop: env overrides.
// ---------------------------------------------------------------------------

func TestSweepHibernationRespectsWindow(t *testing.T) {
	root := testRoot(t)
	reg := testRegistry(t, root, map[string]string{"claude": idleScript("sweep-ready")})
	m := NewManager(reg)
	t.Cleanup(m.Close)

	sess, _, err := m.GetOrCreate("session-sweep", "claude")
	if err != nil {
		t.Fatalf("GetOrCreate: %v", err)
	}
	waitForOutput(t, sess, "sweep-ready")

	sess.mu.Lock()
	sess.adapter.Protocol = "stream-json"
	sess.chat = &turnBackend{active: false}
	sess.mu.Unlock()

	now := time.Now()
	window := 30 * time.Minute

	sess.mu.Lock()
	sess.lastOutput = now.Add(-5 * time.Minute)
	sess.mu.Unlock()
	m.sweepHibernation(window, now)
	if _, ok := m.Get("session-sweep"); !ok {
		t.Fatal("fresh-idle session must survive a sweep with a larger window")
	}

	sess.mu.Lock()
	sess.lastOutput = now.Add(-40 * time.Minute)
	sess.mu.Unlock()
	m.sweepHibernation(window, now)
	if _, ok := m.Get("session-sweep"); ok {
		t.Fatal("stale-idle session must be hibernated by the sweep")
	}
	if !m.IsHibernated("session-sweep") {
		t.Fatal("swept session must be flagged hibernated on disk")
	}
}

// TestHibernateLoopHonorsKillSwitch pins CONDUIT_HIBERNATE_DISABLED: even
// with a 1-second sweep cadence and a session idle well past a 1-minute
// window, the real background loop must never touch it.
func TestHibernateLoopHonorsKillSwitch(t *testing.T) {
	root := testRoot(t)
	t.Setenv("CONDUIT_HIBERNATE_DISABLED", "1")
	t.Setenv("CONDUIT_HIBERNATE_MINUTES", "1")
	t.Setenv("CONDUIT_HIBERNATE_SWEEP_SECONDS", "1")
	reg := testRegistry(t, root, map[string]string{"claude": idleScript("kill-ready")})
	m := NewManager(reg)
	t.Cleanup(m.Close)

	sess, _, err := m.GetOrCreate("session-kill", "claude")
	if err != nil {
		t.Fatalf("GetOrCreate: %v", err)
	}
	waitForOutput(t, sess, "kill-ready")
	sess.mu.Lock()
	sess.adapter.Protocol = "stream-json"
	sess.chat = &turnBackend{active: false}
	sess.lastOutput = time.Now().Add(-2 * time.Minute) // past the 1-minute window
	sess.mu.Unlock()

	time.Sleep(1500 * time.Millisecond) // > 1 sweep cadence, were the loop running
	if _, ok := m.Get("session-kill"); !ok {
		t.Fatal("CONDUIT_HIBERNATE_DISABLED must fully disable the sweep loop")
	}
}

// TestHibernateLoopEndToEndHonorsEnvOverrides pins that CONDUIT_HIBERNATE_
// MINUTES / CONDUIT_HIBERNATE_SWEEP_SECONDS actually drive the REAL
// background loop started by NewManager, not just sweepHibernation called
// directly.
func TestHibernateLoopEndToEndHonorsEnvOverrides(t *testing.T) {
	root := testRoot(t)
	t.Setenv("CONDUIT_HIBERNATE_MINUTES", "1")
	t.Setenv("CONDUIT_HIBERNATE_SWEEP_SECONDS", "1")
	reg := testRegistry(t, root, map[string]string{"claude": idleScript("loop-ready")})
	m := NewManager(reg)
	t.Cleanup(m.Close)

	sess, _, err := m.GetOrCreate("session-loop", "claude")
	if err != nil {
		t.Fatalf("GetOrCreate: %v", err)
	}
	waitForOutput(t, sess, "loop-ready")
	sess.mu.Lock()
	sess.adapter.Protocol = "stream-json"
	sess.chat = &turnBackend{active: false}
	sess.lastOutput = time.Now().Add(-2 * time.Minute) // past the 1-minute window
	sess.mu.Unlock()

	deadline := time.Now().Add(5 * time.Second)
	for {
		if _, ok := m.Get("session-loop"); !ok {
			break
		}
		if time.Now().After(deadline) {
			t.Fatal("session was not hibernated by the real loop within 5s — env overrides not honored")
		}
		time.Sleep(100 * time.Millisecond)
	}
	if !m.IsHibernated("session-loop") {
		t.Fatal("expected the session to be flagged hibernated on disk")
	}
}

// TestSessionMetadataHibernatedFieldsRoundTripJSON pins the wire shape of the
// two new persisted fields (docs/PLAN-SESSION-HIBERNATION.md §5): omitted
// when false/empty, present with the documented keys when set.
func TestSessionMetadataHibernatedFieldsRoundTripJSON(t *testing.T) {
	zero := sessionMetadata{ID: "s", Assistant: "claude"}
	data, err := json.Marshal(zero)
	if err != nil {
		t.Fatalf("Marshal: %v", err)
	}
	if string(data) == "" {
		t.Fatal("unexpected empty marshal")
	}
	var raw map[string]any
	if err := json.Unmarshal(data, &raw); err != nil {
		t.Fatalf("Unmarshal: %v", err)
	}
	if _, present := raw["hibernated"]; present {
		t.Error("hibernated must be omitted (omitempty) when false")
	}
	if _, present := raw["hibernated_at"]; present {
		t.Error("hibernated_at must be omitted (omitempty) when empty")
	}

	set := sessionMetadata{ID: "s", Assistant: "claude", Hibernated: true, HibernatedAt: "2026-07-14T00:00:00Z"}
	data2, err := json.Marshal(set)
	if err != nil {
		t.Fatalf("Marshal: %v", err)
	}
	var raw2 map[string]any
	if err := json.Unmarshal(data2, &raw2); err != nil {
		t.Fatalf("Unmarshal: %v", err)
	}
	if v, _ := raw2["hibernated"].(bool); !v {
		t.Error("hibernated must be true in the wire payload")
	}
	if v, _ := raw2["hibernated_at"].(string); v != "2026-07-14T00:00:00Z" {
		t.Errorf("hibernated_at = %v, want the set timestamp", raw2["hibernated_at"])
	}
}
