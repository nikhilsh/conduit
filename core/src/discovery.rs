//! Typed discovery registry — merge/dedupe layer that consumes seeds
//! from platform mDNS browsers (NWBrowser on iOS, NsdManager on
//! Android) and presents a stable, sorted snapshot to the UI.
//!
//! This is the v2 foundation that replaces the per-platform local
//! `Discovered` state introduced in 2026-05-20's first discovery
//! commit (`a872f70`). The mobile side still owns the actual mDNS
//! browse (Apple/Google APIs do that better than any Rust crate
//! could under mobile sandbox constraints) — what the Rust core
//! owns is the *merged registry*: dedupe by id, source priority,
//! stale-entry eviction, deterministic ordering.
//!
//! Surfaces (none exposed to UniFFI yet — that lands in a separate
//! pass once the mobile feeders are migrated and we can verify the
//! xcframework rebuild on device):
//!
//! - [`DiscoveredServer`] — typed row the UI consumes
//! - [`DiscoverySource`] — where the row came from (mDNS / manual /
//!   pairing); used for priority on conflict
//! - [`DiscoveryRegistry`] — thread-safe store with `upsert`,
//!   `remove`, `prune_stale`, `snapshot`

use std::collections::HashMap;

use parking_lot::Mutex;

/// Where a discovered server entry originated. Used to break ties
/// when the same `id` is observed via multiple paths — a user's
/// manually-added server should not get downgraded to "mdns" just
/// because the same advertiser was later seen on the LAN.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum DiscoverySource {
    /// Observed via mDNS browse (`_conduit._tcp.local`).
    Mdns,
    /// Reached via QR pairing or `conduit://` deeplink.
    Pairing,
    /// Typed in by the user in the Settings → URL/Token form.
    Manual,
}

impl DiscoverySource {
    /// Higher number wins on conflict.
    fn priority(self) -> u8 {
        match self {
            DiscoverySource::Manual => 3,
            DiscoverySource::Pairing => 2,
            DiscoverySource::Mdns => 1,
        }
    }
}

/// Typed row for one discovered conduit harness.
///
/// `id` is the dedupe key — pick the most stable thing the source
/// can produce. For mDNS, that's the service instance name (e.g.
/// `nikhil-1977`). For Manual/Pairing entries, derive a stable id
/// from `host:port` so re-typing the same address doesn't create a
/// duplicate.
#[derive(Clone, Debug)]
pub struct DiscoveredServer {
    pub id: String,
    pub name: String,
    pub host: String,
    pub port: u16,
    pub token: String,
    pub version: Option<String>,
    pub source: DiscoverySource,
    /// Wall-clock millis since UNIX epoch when this row was last
    /// confirmed by its source. mDNS browsers update this on every
    /// `onServiceResolved` / `netServiceDidResolveAddress` callback;
    /// Manual/Pairing entries get a single value at insert.
    pub last_seen_unix_ms: u64,
}

/// Thread-safe registry holding the merged set of discovered
/// servers. Cheap to clone behind an `Arc`; intended to live for
/// the app session.
#[derive(Default)]
pub struct DiscoveryRegistry {
    inner: Mutex<HashMap<String, DiscoveredServer>>,
}

impl DiscoveryRegistry {
    pub fn new() -> Self {
        Self::default()
    }

    /// Insert or update an entry.
    ///
    /// Merge policy: if an entry with the same `id` already exists
    /// **and its source has higher priority than the incoming
    /// source**, the source is *preserved* (Manual > Pairing >
    /// Mdns). All other fields are taken from the incoming value
    /// — most importantly `last_seen_unix_ms`, so a stale Manual
    /// entry can still be freshened by an mDNS observation
    /// without losing its Manual-ness.
    pub fn upsert(&self, mut server: DiscoveredServer) {
        let mut guard = self.inner.lock();
        if let Some(existing) = guard.get(&server.id) {
            if existing.source.priority() > server.source.priority() {
                server.source = existing.source;
            }
        }
        guard.insert(server.id.clone(), server);
    }

    /// Remove an entry by id. No-op if absent.
    pub fn remove(&self, id: &str) {
        self.inner.lock().remove(id);
    }

    /// Drop mDNS entries whose `last_seen_unix_ms` is older than
    /// `max_age_ms` relative to `now_unix_ms`. Manual and Pairing
    /// entries are never pruned by staleness — those came from
    /// the user and only the user removes them.
    ///
    /// Returns the number of entries dropped.
    pub fn prune_stale(&self, now_unix_ms: u64, max_age_ms: u64) -> usize {
        let mut guard = self.inner.lock();
        let before = guard.len();
        guard.retain(|_, s| {
            if s.source != DiscoverySource::Mdns {
                return true;
            }
            now_unix_ms.saturating_sub(s.last_seen_unix_ms) <= max_age_ms
        });
        before - guard.len()
    }

    /// Snapshot of all entries, sorted by `name` then `id`. Stable
    /// ordering means the UI list doesn't churn between observations.
    pub fn snapshot(&self) -> Vec<DiscoveredServer> {
        let mut list: Vec<DiscoveredServer> = self.inner.lock().values().cloned().collect();
        list.sort_by(|a, b| a.name.cmp(&b.name).then_with(|| a.id.cmp(&b.id)));
        list
    }

    pub fn len(&self) -> usize {
        self.inner.lock().len()
    }

    pub fn is_empty(&self) -> bool {
        self.inner.lock().is_empty()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn mk(
        id: &str,
        name: &str,
        source: DiscoverySource,
        last_seen_unix_ms: u64,
    ) -> DiscoveredServer {
        DiscoveredServer {
            id: id.to_string(),
            name: name.to_string(),
            host: "10.0.0.1".to_string(),
            port: 1977,
            token: "tok".to_string(),
            version: Some("1".to_string()),
            source,
            last_seen_unix_ms,
        }
    }

    #[test]
    fn upsert_dedupes_by_id() {
        let r = DiscoveryRegistry::new();
        r.upsert(mk("svc-a", "alpha", DiscoverySource::Mdns, 100));
        r.upsert(mk("svc-a", "alpha", DiscoverySource::Mdns, 200));
        assert_eq!(r.len(), 1);
        let snap = r.snapshot();
        assert_eq!(snap[0].last_seen_unix_ms, 200);
    }

    #[test]
    fn upsert_preserves_higher_priority_source() {
        let r = DiscoveryRegistry::new();
        // User manually added an entry.
        r.upsert(mk("svc-a", "alpha", DiscoverySource::Manual, 100));
        // Later, mDNS also sees it on the LAN.
        r.upsert(mk("svc-a", "alpha", DiscoverySource::Mdns, 250));
        let snap = r.snapshot();
        // Source stays Manual; last_seen advanced from the mDNS hit.
        assert_eq!(snap[0].source, DiscoverySource::Manual);
        assert_eq!(snap[0].last_seen_unix_ms, 250);
    }

    #[test]
    fn upsert_overwrites_when_incoming_priority_is_higher() {
        let r = DiscoveryRegistry::new();
        r.upsert(mk("svc-a", "alpha", DiscoverySource::Mdns, 100));
        // User adopts it via manual flow.
        r.upsert(mk("svc-a", "alpha", DiscoverySource::Manual, 150));
        let snap = r.snapshot();
        assert_eq!(snap[0].source, DiscoverySource::Manual);
    }

    #[test]
    fn pairing_beats_mdns_but_loses_to_manual() {
        let r = DiscoveryRegistry::new();
        r.upsert(mk("svc-a", "alpha", DiscoverySource::Mdns, 10));
        r.upsert(mk("svc-a", "alpha", DiscoverySource::Pairing, 20));
        assert_eq!(r.snapshot()[0].source, DiscoverySource::Pairing);

        r.upsert(mk("svc-a", "alpha", DiscoverySource::Manual, 30));
        assert_eq!(r.snapshot()[0].source, DiscoverySource::Manual);

        // mDNS hit after Manual must not downgrade.
        r.upsert(mk("svc-a", "alpha", DiscoverySource::Mdns, 40));
        let snap = r.snapshot();
        assert_eq!(snap[0].source, DiscoverySource::Manual);
        assert_eq!(snap[0].last_seen_unix_ms, 40);
    }

    #[test]
    fn remove_drops_entry() {
        let r = DiscoveryRegistry::new();
        r.upsert(mk("svc-a", "alpha", DiscoverySource::Mdns, 100));
        r.upsert(mk("svc-b", "bravo", DiscoverySource::Mdns, 100));
        r.remove("svc-a");
        let snap = r.snapshot();
        assert_eq!(snap.len(), 1);
        assert_eq!(snap[0].id, "svc-b");
    }

    #[test]
    fn remove_missing_is_noop() {
        let r = DiscoveryRegistry::new();
        r.remove("nothing");
        assert!(r.is_empty());
    }

    #[test]
    fn prune_stale_drops_only_old_mdns() {
        let r = DiscoveryRegistry::new();
        r.upsert(mk("mdns-fresh", "z", DiscoverySource::Mdns, 1_800));
        r.upsert(mk("mdns-stale", "y", DiscoverySource::Mdns, 100));
        r.upsert(mk("manual-stale", "x", DiscoverySource::Manual, 100));
        r.upsert(mk("pairing-stale", "w", DiscoverySource::Pairing, 100));

        // now = 2000, max_age = 500 → 100 is stale (1900 > 500),
        // 1800 is fresh (200 < 500).
        let dropped = r.prune_stale(2_000, 500);
        assert_eq!(dropped, 1);

        let ids: Vec<_> = r.snapshot().into_iter().map(|s| s.id).collect();
        assert!(ids.contains(&"mdns-fresh".to_string()));
        assert!(!ids.contains(&"mdns-stale".to_string()));
        assert!(ids.contains(&"manual-stale".to_string()));
        assert!(ids.contains(&"pairing-stale".to_string()));
    }

    #[test]
    fn prune_handles_now_before_last_seen() {
        // Clock skew shouldn't underflow our subtraction.
        let r = DiscoveryRegistry::new();
        r.upsert(mk("mdns-future", "f", DiscoverySource::Mdns, 5_000));
        let dropped = r.prune_stale(1_000, 500);
        assert_eq!(dropped, 0);
        assert_eq!(r.len(), 1);
    }

    #[test]
    fn snapshot_sorted_by_name_then_id() {
        let r = DiscoveryRegistry::new();
        r.upsert(mk("b", "alpha", DiscoverySource::Mdns, 100));
        r.upsert(mk("a", "alpha", DiscoverySource::Mdns, 100));
        r.upsert(mk("c", "zulu", DiscoverySource::Mdns, 100));
        let names: Vec<_> = r.snapshot().into_iter().map(|s| s.id).collect();
        assert_eq!(names, vec!["a", "b", "c"]);
    }
}
