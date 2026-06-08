//go:build linux

package session

import (
	"os"
	"path/filepath"
	"strconv"
	"strings"
)

// listeningPortsForTree returns the loopback ports that processes in rootPID's
// tree (rootPID itself or any descendant) are currently LISTENing on. This is
// how the broker auto-detects a session's dev server without the project having
// to honor $PORT: we find the agent's own listening sockets, whatever port they
// landed on.
//
// It works entirely from /proc (no deps, no privileges beyond reading our own
// and our children's fds): map every LISTEN socket inode to its port, then scan
// only the session subtree's open fds for those inodes. Scoping to the subtree
// both bounds the work and *is* the ownership guarantee — a stranger squatting
// a loopback port is never in our tree, so it can't be mistaken for ours.
//
// Limitation: a dev server that daemonizes and reparents to init (PPID 1)
// escapes the subtree walk. That's the case `.conduit/preview.json` covers.
func listeningPortsForTree(rootPID int) []int {
	if rootPID <= 0 {
		return nil
	}
	inodePort := listenInodePorts()
	if len(inodePort) == 0 {
		return nil
	}
	seen := map[int]bool{}
	var ports []int
	for pid := range descendantPIDs(rootPID) {
		for _, inode := range pidSocketInodes(pid) {
			if port, ok := inodePort[inode]; ok && !seen[port] {
				seen[port] = true
				ports = append(ports, port)
			}
		}
	}
	return ports
}

// listenInodePorts maps each LISTEN socket's inode to its local port, across
// IPv4 and IPv6 (a dev server may bind either).
func listenInodePorts() map[string]int {
	out := map[string]int{}
	for _, proc := range []string{"/proc/net/tcp", "/proc/net/tcp6"} {
		data, err := os.ReadFile(proc)
		if err != nil {
			continue
		}
		lines := strings.Split(string(data), "\n")
		for _, line := range lines[1:] { // skip header
			fields := strings.Fields(line)
			if len(fields) < 10 {
				continue
			}
			// fields[1] = local_address "HEXIP:HEXPORT"; fields[3] = state
			// (0A = TCP_LISTEN); fields[9] = inode.
			if fields[3] != "0A" {
				continue
			}
			_, hexPort, ok := strings.Cut(fields[1], ":")
			if !ok {
				continue
			}
			p, err := strconv.ParseInt(hexPort, 16, 32)
			if err != nil {
				continue
			}
			out[fields[9]] = int(p)
		}
	}
	return out
}

// pidSocketInodes returns the socket inodes pid has open (each /proc/<pid>/fd
// symlink to a socket reads as "socket:[<inode>]").
func pidSocketInodes(pid int) []string {
	fdDir := filepath.Join("/proc", strconv.Itoa(pid), "fd")
	entries, err := os.ReadDir(fdDir)
	if err != nil {
		return nil // process gone or fds unreadable
	}
	var inodes []string
	for _, e := range entries {
		target, err := os.Readlink(filepath.Join(fdDir, e.Name()))
		if err != nil {
			continue
		}
		if inode, ok := strings.CutPrefix(target, "socket:["); ok {
			inodes = append(inodes, strings.TrimSuffix(inode, "]"))
		}
	}
	return inodes
}

// descendantPIDs returns root and every process transitively descended from it,
// derived from each /proc/<pid>/stat's PPID field.
func descendantPIDs(root int) map[int]bool {
	children := map[int][]int{}
	entries, err := os.ReadDir("/proc")
	if err != nil {
		return map[int]bool{root: true}
	}
	for _, e := range entries {
		pid, err := strconv.Atoi(e.Name())
		if err != nil {
			continue // not a pid dir
		}
		if ppid, ok := parentPID(pid); ok {
			children[ppid] = append(children[ppid], pid)
		}
	}
	out := map[int]bool{}
	stack := []int{root}
	for len(stack) > 0 {
		pid := stack[len(stack)-1]
		stack = stack[:len(stack)-1]
		if out[pid] {
			continue
		}
		out[pid] = true
		stack = append(stack, children[pid]...)
	}
	return out
}

// parentPID reads the PPID for pid from /proc/<pid>/stat. The comm field (2nd)
// is parenthesised and may itself contain spaces and ')', so we split after the
// final ')': the remainder is "state ppid ...".
func parentPID(pid int) (int, bool) {
	data, err := os.ReadFile(filepath.Join("/proc", strconv.Itoa(pid), "stat"))
	if err != nil {
		return 0, false
	}
	closeIdx := strings.LastIndexByte(string(data), ')')
	if closeIdx < 0 {
		return 0, false
	}
	rest := strings.Fields(string(data)[closeIdx+1:])
	if len(rest) < 2 {
		return 0, false
	}
	ppid, err := strconv.Atoi(rest[1]) // rest[0]=state, rest[1]=ppid
	if err != nil {
		return 0, false
	}
	return ppid, true
}
