package session

import (
	"encoding/json"
	"errors"
	"log"
	"os"
	"path/filepath"
	"syscall"
	"time"
)

// agentPIDFile is the per-session file that records the running agent's OS PID
// and its /proc start-time so a restarted broker can identify and reap the
// orphaned process before spawning a replacement.
const agentPIDFile = "agent_pid.json"

// agentPIDRecord is the JSON structure written to agentPIDFile.
type agentPIDRecord struct {
	PID       int    `json:"pid"`
	StartTime uint64 `json:"start_time"` // jiffies since boot from /proc/<pid>/stat field 22
}

// writeAgentPIDRecord persists the PID and its proc start-time for the given
// session directory. Called immediately after pty.Start so the file is always
// current. Best-effort: errors are silently ignored so a write failure never
// blocks session creation.
func writeAgentPIDRecord(sessionDir string, pid int, startTime uint64) {
	rec := agentPIDRecord{PID: pid, StartTime: startTime}
	data, err := json.Marshal(rec)
	if err != nil {
		return
	}
	_ = atomicWriteFile(filepath.Join(sessionDir, agentPIDFile), append(data, '\n'))
}

// readAgentPIDRecord reads the persisted PID record for sessionDir. Returns
// (record, true) on success; (zero, false) when absent or unreadable.
func readAgentPIDRecord(sessionDir string) (agentPIDRecord, bool) {
	data, err := os.ReadFile(filepath.Join(sessionDir, agentPIDFile))
	if err != nil {
		return agentPIDRecord{}, false
	}
	var rec agentPIDRecord
	if err := json.Unmarshal(data, &rec); err != nil {
		return agentPIDRecord{}, false
	}
	if rec.PID <= 0 {
		return agentPIDRecord{}, false
	}
	return rec, true
}

// orphanDecision is the outcome of decideOrphanReap.
type orphanDecision int

const (
	orphanSkipAbsent orphanDecision = iota // no PID file — old session, skip
	orphanSkipDead                         // process already gone, nothing to do
	orphanSkipReused                       // PID reused (start-time mismatch), do NOT kill
	orphanKill                             // PID alive and start-time matches — reap it
)

// decideOrphanReap determines whether the process with the given PID should be
// killed before a new agent is spawned for the same session.
//
// readStartTime is injectable so the decision logic is unit-testable without
// actual OS processes: pass a mock that returns fixed values.
//
// Returns:
//   - orphanSkipDead   — /proc/<pid> is absent, process already gone.
//   - orphanSkipReused — process exists but start-time does not match the
//     recorded value, meaning the PID was recycled by a different process;
//     killing it would be wrong.
//   - orphanKill       — process exists and start-time matches; safe to kill.
func decideOrphanReap(pid int, recordedStart uint64, readStartTime func(int) (uint64, error)) orphanDecision {
	liveStart, err := readStartTime(pid)
	if err != nil {
		// /proc/<pid> unreadable or absent — process is gone.
		return orphanSkipDead
	}
	if liveStart != recordedStart {
		// PID was reused by an unrelated process — do NOT kill.
		return orphanSkipReused
	}
	return orphanKill
}

// reapOrphanAgent reads the recorded PID for sessionDir and, if the process is
// still alive and matches, kills it before the new agent spawns into the same
// session. This prevents the old process (left running when the broker died
// under KillMode=process) from interleaving writes into conversation.jsonl.
//
// readProcStart is the OS-level start-time reader (procStartTime on Linux;
// injected for tests via testable decideOrphanReap).
//
// Call order: read PID file → decide → SIGTERM → wait up to 3 s → SIGKILL.
// The function returns after the process is gone (or was already gone).
// All outcomes are logged; errors are non-fatal so a reap failure never blocks
// session recovery.
func reapOrphanAgent(sessionDir string, readProcStart func(int) (uint64, error)) {
	rec, ok := readAgentPIDRecord(sessionDir)
	if !ok {
		return // No record — old session before this feature, or already cleared.
	}

	decision := decideOrphanReap(rec.PID, rec.StartTime, readProcStart)
	switch decision {
	case orphanSkipDead:
		log.Printf("orphan-reap session=%s pid=%d: already dead, nothing to do", filepath.Base(sessionDir), rec.PID)
		return
	case orphanSkipReused:
		log.Printf("orphan-reap session=%s pid=%d: PID reused (start-time mismatch), skipping", filepath.Base(sessionDir), rec.PID)
		return
	case orphanKill:
		// Fall through to kill.
	}

	proc, err := os.FindProcess(rec.PID)
	if err != nil {
		// Extremely unlikely on Linux (FindProcess never fails for a valid PID),
		// but guard anyway.
		log.Printf("orphan-reap session=%s pid=%d: FindProcess: %v", filepath.Base(sessionDir), rec.PID, err)
		return
	}

	log.Printf("orphan-reap session=%s pid=%d: sending SIGTERM", filepath.Base(sessionDir), rec.PID)
	if err := proc.Signal(syscall.SIGTERM); err != nil {
		if errors.Is(err, os.ErrProcessDone) {
			log.Printf("orphan-reap session=%s pid=%d: already exited before SIGTERM", filepath.Base(sessionDir), rec.PID)
			return
		}
		log.Printf("orphan-reap session=%s pid=%d: SIGTERM failed: %v", filepath.Base(sessionDir), rec.PID, err)
	}

	// Wait up to 3 s for graceful exit, then SIGKILL.
	const gracePeriod = 3 * time.Second
	const pollInterval = 100 * time.Millisecond
	deadline := time.Now().Add(gracePeriod)
	for time.Now().Before(deadline) {
		time.Sleep(pollInterval)
		if _, err := readProcStart(rec.PID); err != nil {
			// Process is gone.
			log.Printf("orphan-reap session=%s pid=%d: exited after SIGTERM", filepath.Base(sessionDir), rec.PID)
			return
		}
	}

	log.Printf("orphan-reap session=%s pid=%d: still alive after %v, sending SIGKILL", filepath.Base(sessionDir), rec.PID, gracePeriod)
	if err := proc.Signal(syscall.SIGKILL); err != nil && !errors.Is(err, os.ErrProcessDone) {
		log.Printf("orphan-reap session=%s pid=%d: SIGKILL failed: %v", filepath.Base(sessionDir), rec.PID, err)
	}
}
