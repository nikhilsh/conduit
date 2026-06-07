// Package hostmetrics samples coarse host health (CPU / memory / disk /
// load / uptime) for the app's Box health screen. Linux-only by design —
// the broker runs on Linux boxes; other platforms report unavailable and
// the app hides the health section entirely (honest-state rule, see
// apps/ios/.../ConduitBoxHealthView.swift).
package hostmetrics

import (
	"sync"
	"time"
)

// Snapshot is one host-health sample. Percentages are 0–100.
type Snapshot struct {
	CPUPct     float64   `json:"cpu_pct"`
	MemPct     float64   `json:"mem_pct"`
	DiskPct    float64   `json:"disk_pct"`
	Load1      float64   `json:"load1"`
	UptimeSecs int64     `json:"uptime_secs"`
	SampledAt  time.Time `json:"sampled_at"`
}

// cacheTTL bounds how often a metrics request re-reads /proc. The CPU
// sample blocks for cpuSampleGap (two /proc/stat reads), so the cache
// also keeps a polling client from stacking 250ms pauses.
const cacheTTL = 2 * time.Second

// cpuSampleGap is the delta window between the two /proc/stat reads that
// produce CPUPct.
const cpuSampleGap = 250 * time.Millisecond

var (
	mu       sync.Mutex
	cached   Snapshot
	cachedOK bool
	cachedAt time.Time
)

// Available reports whether this platform can sample host metrics at all.
// Callers use it to set the capabilities flag once at startup.
func Available() bool { return platformAvailable }

// Sample returns the current host snapshot, serving a cached value when
// the last sample is fresher than cacheTTL. ok=false means the platform
// (or this particular host) cannot report metrics.
func Sample() (Snapshot, bool) {
	mu.Lock()
	defer mu.Unlock()
	if cachedOK && time.Since(cachedAt) < cacheTTL {
		return cached, true
	}
	snap, ok := platformSample()
	if !ok {
		return Snapshot{}, false
	}
	cached, cachedOK, cachedAt = snap, true, time.Now()
	return snap, true
}
