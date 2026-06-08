//go:build !linux

package session

// listeningPortsForTree has no /proc to read off Linux, so auto-detection is a
// no-op on a developer's macOS box: the preview falls back to the pooled $PORT
// (and the `.conduit/preview.json` override still works). The broker runs on
// Linux in production, where detection is active; this stub only keeps non-Linux
// builds compiling.
func listeningPortsForTree(rootPID int) []int {
	return nil
}
