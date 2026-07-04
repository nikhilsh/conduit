package session

import (
	"errors"
	"os"
	"path/filepath"
	"testing"
)

// errFakeNoProcess is the sentinel error returned by the fake readStartTime
// when simulating a dead process.
var errFakeNoProcess = errors.New("fake: no such process")

// fakeAlive returns a readStartTime func that always reports the given
// start-time (simulating a live process with that start-time).
func fakeAlive(startTime uint64) func(int) (uint64, error) {
	return func(pid int) (uint64, error) {
		return startTime, nil
	}
}

// fakeDead returns a readStartTime func that always reports the process as
// gone (simulating a dead or reaped process).
func fakeDead() func(int) (uint64, error) {
	return func(pid int) (uint64, error) {
		return 0, errFakeNoProcess
	}
}

// TestDecideOrphanReapMatchKill asserts that a live process whose start-time
// matches the recorded value is chosen for killing.
func TestDecideOrphanReapMatchKill(t *testing.T) {
	const (
		pid           = 12345
		recordedStart = uint64(9876543)
	)
	decision := decideOrphanReap(pid, recordedStart, fakeAlive(recordedStart))
	if decision != orphanKill {
		t.Fatalf("expected orphanKill, got %d", decision)
	}
}

// TestDecideOrphanReapStartTimeMismatchSkip asserts that a live process whose
// start-time differs from the recorded value (PID reuse) is NOT killed.
func TestDecideOrphanReapStartTimeMismatchSkip(t *testing.T) {
	const (
		pid           = 12345
		recordedStart = uint64(9876543)
		liveStart     = uint64(1111111) // different — PID was reused
	)
	decision := decideOrphanReap(pid, recordedStart, fakeAlive(liveStart))
	if decision != orphanSkipReused {
		t.Fatalf("expected orphanSkipReused, got %d", decision)
	}
}

// TestDecideOrphanReapDeadProcessSkip asserts that when readStartTime reports
// an error (process is gone), the decision is orphanSkipDead.
func TestDecideOrphanReapDeadProcessSkip(t *testing.T) {
	decision := decideOrphanReap(99999, 42, fakeDead())
	if decision != orphanSkipDead {
		t.Fatalf("expected orphanSkipDead, got %d", decision)
	}
}

// TestWriteReadAgentPIDRecord verifies the round-trip: write then read back.
func TestWriteReadAgentPIDRecord(t *testing.T) {
	dir := t.TempDir()
	const (
		pid       = 55555
		startTime = uint64(777888999)
	)
	writeAgentPIDRecord(dir, pid, startTime)

	rec, ok := readAgentPIDRecord(dir)
	if !ok {
		t.Fatal("readAgentPIDRecord: expected ok=true after write")
	}
	if rec.PID != pid {
		t.Fatalf("PID: got %d, want %d", rec.PID, pid)
	}
	if rec.StartTime != startTime {
		t.Fatalf("StartTime: got %d, want %d", rec.StartTime, startTime)
	}
}

// TestReadAgentPIDRecordMissingReturnsNotOK asserts that a missing file returns
// ok=false cleanly without panicking.
func TestReadAgentPIDRecordMissingReturnsNotOK(t *testing.T) {
	dir := t.TempDir()
	_, ok := readAgentPIDRecord(dir)
	if ok {
		t.Fatal("expected ok=false for missing agent_pid.json")
	}
}

// TestReadAgentPIDRecordCorruptReturnsNotOK asserts that a corrupt PID file
// is silently ignored.
func TestReadAgentPIDRecordCorruptReturnsNotOK(t *testing.T) {
	dir := t.TempDir()
	if err := os.WriteFile(filepath.Join(dir, agentPIDFile), []byte("not json"), 0o644); err != nil {
		t.Fatal(err)
	}
	_, ok := readAgentPIDRecord(dir)
	if ok {
		t.Fatal("expected ok=false for corrupt agent_pid.json")
	}
}
