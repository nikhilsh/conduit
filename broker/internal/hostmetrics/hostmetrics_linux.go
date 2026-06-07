//go:build linux

package hostmetrics

import (
	"os"
	"strconv"
	"strings"
	"syscall"
	"time"
)

const platformAvailable = true

// platformSample reads /proc + statfs. Any individual read failing zeroes
// that field rather than failing the whole snapshot; ok=false only when
// nothing could be read (e.g. /proc not mounted in an odd container).
func platformSample() (Snapshot, bool) {
	var snap Snapshot
	got := false

	if pct, ok := sampleCPU(); ok {
		snap.CPUPct = pct
		got = true
	}
	if pct, ok := sampleMem(); ok {
		snap.MemPct = pct
		got = true
	}
	if pct, ok := sampleDisk("/"); ok {
		snap.DiskPct = pct
		got = true
	}
	if load, ok := sampleLoad1(); ok {
		snap.Load1 = load
		got = true
	}
	if up, ok := sampleUptime(); ok {
		snap.UptimeSecs = up
		got = true
	}
	if !got {
		return Snapshot{}, false
	}
	snap.SampledAt = time.Now().UTC()
	return snap, true
}

// readCPUTicks parses the aggregate "cpu " line of /proc/stat into
// (idle, total) jiffies. idle includes iowait.
func readCPUTicks() (idle, total uint64, ok bool) {
	data, err := os.ReadFile("/proc/stat")
	if err != nil {
		return 0, 0, false
	}
	line, _, _ := strings.Cut(string(data), "\n")
	fields := strings.Fields(line)
	// "cpu user nice system idle iowait irq softirq steal ..."
	if len(fields) < 5 || fields[0] != "cpu" {
		return 0, 0, false
	}
	for i, f := range fields[1:] {
		v, err := strconv.ParseUint(f, 10, 64)
		if err != nil {
			return 0, 0, false
		}
		total += v
		if i == 3 || i == 4 { // idle + iowait
			idle += v
		}
	}
	return idle, total, true
}

func sampleCPU() (float64, bool) {
	idle0, total0, ok := readCPUTicks()
	if !ok {
		return 0, false
	}
	time.Sleep(cpuSampleGap)
	idle1, total1, ok := readCPUTicks()
	if !ok || total1 <= total0 {
		return 0, false
	}
	dTotal := float64(total1 - total0)
	dIdle := float64(idle1 - idle0)
	pct := (1 - dIdle/dTotal) * 100
	return clampPct(pct), true
}

func sampleMem() (float64, bool) {
	data, err := os.ReadFile("/proc/meminfo")
	if err != nil {
		return 0, false
	}
	var total, avail uint64
	for _, line := range strings.Split(string(data), "\n") {
		if v, ok := meminfoKB(line, "MemTotal:"); ok {
			total = v
		} else if v, ok := meminfoKB(line, "MemAvailable:"); ok {
			avail = v
		}
		if total > 0 && avail > 0 {
			break
		}
	}
	if total == 0 {
		return 0, false
	}
	return clampPct(float64(total-avail) / float64(total) * 100), true
}

func meminfoKB(line, key string) (uint64, bool) {
	if !strings.HasPrefix(line, key) {
		return 0, false
	}
	fields := strings.Fields(line[len(key):])
	if len(fields) == 0 {
		return 0, false
	}
	v, err := strconv.ParseUint(fields[0], 10, 64)
	if err != nil {
		return 0, false
	}
	return v, true
}

func sampleDisk(path string) (float64, bool) {
	var st syscall.Statfs_t
	if err := syscall.Statfs(path, &st); err != nil || st.Blocks == 0 {
		return 0, false
	}
	// Used% the way df reports it: used / (used + available-to-unprivileged).
	used := st.Blocks - st.Bfree
	denom := used + st.Bavail
	if denom == 0 {
		return 0, false
	}
	return clampPct(float64(used) / float64(denom) * 100), true
}

func sampleLoad1() (float64, bool) {
	data, err := os.ReadFile("/proc/loadavg")
	if err != nil {
		return 0, false
	}
	fields := strings.Fields(string(data))
	if len(fields) == 0 {
		return 0, false
	}
	v, err := strconv.ParseFloat(fields[0], 64)
	if err != nil {
		return 0, false
	}
	return v, true
}

func sampleUptime() (int64, bool) {
	data, err := os.ReadFile("/proc/uptime")
	if err != nil {
		return 0, false
	}
	fields := strings.Fields(string(data))
	if len(fields) == 0 {
		return 0, false
	}
	v, err := strconv.ParseFloat(fields[0], 64)
	if err != nil {
		return 0, false
	}
	return int64(v), true
}

func clampPct(v float64) float64 {
	if v < 0 {
		return 0
	}
	if v > 100 {
		return 100
	}
	return v
}
