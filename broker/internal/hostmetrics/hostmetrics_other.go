//go:build !linux

package hostmetrics

const platformAvailable = false

func platformSample() (Snapshot, bool) { return Snapshot{}, false }
