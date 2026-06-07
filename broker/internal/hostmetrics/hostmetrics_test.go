//go:build linux

package hostmetrics

import "testing"

// CI broker jobs run on Linux, so the real /proc paths are exercised.
func TestSampleReportsSaneRanges(t *testing.T) {
	snap, ok := Sample()
	if !ok {
		t.Fatal("Sample() not ok on Linux")
	}
	for name, v := range map[string]float64{
		"cpu_pct":  snap.CPUPct,
		"mem_pct":  snap.MemPct,
		"disk_pct": snap.DiskPct,
	} {
		if v < 0 || v > 100 {
			t.Errorf("%s out of range: %v", name, v)
		}
	}
	if snap.MemPct == 0 {
		t.Error("mem_pct = 0; expected a live host to use some memory")
	}
	if snap.UptimeSecs <= 0 {
		t.Errorf("uptime_secs = %d; want > 0", snap.UptimeSecs)
	}
	if snap.SampledAt.IsZero() {
		t.Error("sampled_at is zero")
	}
}

func TestSampleUsesCache(t *testing.T) {
	first, ok := Sample()
	if !ok {
		t.Fatal("Sample() not ok")
	}
	second, ok := Sample()
	if !ok {
		t.Fatal("second Sample() not ok")
	}
	if !first.SampledAt.Equal(second.SampledAt) {
		t.Error("back-to-back samples should hit the cache (same sampled_at)")
	}
}

func TestReadCPUTicks(t *testing.T) {
	idle, total, ok := readCPUTicks()
	if !ok {
		t.Fatal("readCPUTicks not ok")
	}
	if idle == 0 || total == 0 || idle > total {
		t.Errorf("implausible ticks: idle=%d total=%d", idle, total)
	}
}

func TestMeminfoKB(t *testing.T) {
	v, ok := meminfoKB("MemTotal:        3980912 kB", "MemTotal:")
	if !ok || v != 3980912 {
		t.Errorf("meminfoKB = %d, %v; want 3980912, true", v, ok)
	}
	if _, ok := meminfoKB("MemFree: 1 kB", "MemTotal:"); ok {
		t.Error("meminfoKB matched the wrong key")
	}
}

func TestClampPct(t *testing.T) {
	for in, want := range map[float64]float64{-5: 0, 50: 50, 130: 100} {
		if got := clampPct(in); got != want {
			t.Errorf("clampPct(%v) = %v; want %v", in, got, want)
		}
	}
}
