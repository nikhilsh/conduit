//go:build linux

package session

import (
	"fmt"
	"os"
	"path/filepath"
	"strconv"
	"strings"
)

// procStartTime reads the process start-time (jiffies since boot) for pid
// from /proc/<pid>/stat field 22. This value is stable for the lifetime of
// the process and changes when a PID is recycled — making it a reliable
// guard against killing the wrong process after PID reuse.
//
// Returns an error when the process is not found or the stat file is
// unparseable (treat either as "process is gone").
func procStartTime(pid int) (uint64, error) {
	data, err := os.ReadFile(filepath.Join("/proc", strconv.Itoa(pid), "stat"))
	if err != nil {
		return 0, fmt.Errorf("procStartTime %d: %w", pid, err)
	}
	// The comm field (2nd) is parenthesised and may contain spaces and ')'.
	// Split after the LAST ')' so we never misparse a process whose name
	// contains ')'. The fields after the ')' are:
	//   [0]=state [1]=ppid ... [19]=starttime
	closeIdx := strings.LastIndexByte(string(data), ')')
	if closeIdx < 0 {
		return 0, fmt.Errorf("procStartTime %d: malformed stat (no closing paren)", pid)
	}
	rest := strings.Fields(string(data)[closeIdx+1:])
	// starttime is the 20th field after ')' (0-indexed 19).
	const startTimeIdx = 19
	if len(rest) <= startTimeIdx {
		return 0, fmt.Errorf("procStartTime %d: stat has too few fields (%d)", pid, len(rest))
	}
	v, err := strconv.ParseUint(rest[startTimeIdx], 10, 64)
	if err != nil {
		return 0, fmt.Errorf("procStartTime %d: parse starttime: %w", pid, err)
	}
	return v, nil
}
