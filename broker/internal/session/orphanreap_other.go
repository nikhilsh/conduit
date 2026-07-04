//go:build !linux

package session

import "fmt"

// procStartTime is a no-op stub on non-Linux platforms. The broker runs on
// Linux in production; this stub keeps non-Linux developer builds compiling.
func procStartTime(pid int) (uint64, error) {
	return 0, fmt.Errorf("procStartTime: not supported on this platform (pid %d)", pid)
}
