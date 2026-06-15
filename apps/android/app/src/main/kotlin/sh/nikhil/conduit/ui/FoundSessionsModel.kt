package sh.nikhil.conduit.ui

/**
 * Pure view-model for the Found Sessions feature -- no Compose import, fully
 * unit-testable on the JVM. Mirrors the iOS `FoundSessionsModel`.
 *
 * Data model:
 *   FoundSessionState  = idle | running | adopted
 *   FoundSession       { externalId, agent, title, cwd, gitBranch, turnCount,
 *                        lastActivityAt, state }
 *   FoundSessionsSnapshot { boxId, sessions, hiddenIds, query, filter,
 *                           discoveryState }
 *   filter             = recent | byFolder | all
 *   discoveryState     = scanning | loaded | empty | offline | error(reason)
 */

// -- Model enums ---------------------------------------------------------------

enum class FoundSessionState {
    /** Session is idle (not running) -- Resume is offered. */
    IDLE,
    /** Session is live in a terminal -- Branch a copy is offered. */
    RUNNING,
    /** Session is already inside Conduit -- dimmed "In Conduit". */
    ADOPTED,
}

enum class FoundFilter { RECENT, BY_FOLDER, ALL }

sealed class FoundDiscoveryState {
    data object Scanning : FoundDiscoveryState()
    data object Loaded : FoundDiscoveryState()
    data object Empty : FoundDiscoveryState()
    data object Offline : FoundDiscoveryState()
    data class Error(val reason: String) : FoundDiscoveryState()
}

// -- Data classes --------------------------------------------------------------

data class FoundSession(
    val externalId: String,
    val agent: String,
    val title: String,
    val cwd: String,
    val gitBranch: String,
    val turnCount: Int,
    /** Unix millis, same as wire contract last_activity_at. */
    val lastActivityAtMs: Long,
    val state: FoundSessionState,
)

data class FoundSessionsSnapshot(
    val boxId: String,
    val sessions: List<FoundSession>,
    val hiddenIds: Set<String>,
    val query: String,
    val filter: FoundFilter,
    val discoveryState: FoundDiscoveryState,
    /** Total count on disk from the broker (for the footer). */
    val totalOnDisk: Int = 0,
)

data class FoundSessionRow(
    val session: FoundSession,
    /** Folder header key (cwd) used for grouping in BY_FOLDER / ALL filters. */
    val folderKey: String,
)

// -- Model object --------------------------------------------------------------

/**
 * Computes the visible rows and folder groups from a [FoundSessionsSnapshot].
 * Pure function -- no side-effects, no Android/Compose imports.
 */
object FoundSessionsModel {

    /**
     * Returns visible rows (hidden-filtered + search-filtered + filter-applied)
     * in display order. Each row carries its [FoundSession] and a
     * [FoundSessionRow.folderKey] for sticky-header grouping.
     *
     * Sort order inside groups: most-recent-first (lastActivityAtMs desc).
     */
    fun rows(snapshot: FoundSessionsSnapshot): List<FoundSessionRow> {
        val q = snapshot.query.trim().lowercase()

        // 1. Filter out explicitly hidden sessions.
        val visible = snapshot.sessions.filter { s ->
            s.externalId !in snapshot.hiddenIds
        }

        // 2. Search filter (applies across all filter modes).
        val searched = if (q.isBlank()) visible else visible.filter { s ->
            s.title.lowercase().contains(q) ||
                s.cwd.lowercase().contains(q) ||
                s.gitBranch.lowercase().contains(q)
        }

        // 3. Filter mode.
        val filtered = when (snapshot.filter) {
            FoundFilter.RECENT -> {
                // Recent = up to 8 most-recent sessions (flat, any folder).
                searched.sortedByDescending { it.lastActivityAtMs }.take(8)
            }
            FoundFilter.BY_FOLDER -> {
                // All sessions, grouped by cwd; no count cap.
                searched.sortedByDescending { it.lastActivityAtMs }
            }
            FoundFilter.ALL -> {
                searched.sortedByDescending { it.lastActivityAtMs }
            }
        }

        // 4. Map to rows.
        return filtered.map { s -> FoundSessionRow(session = s, folderKey = s.cwd) }
    }

    /**
     * Returns the unique folder keys (cwd values) in display order for the
     * current filter mode. Used to render stickyHeader separators.
     */
    fun folderKeys(rows: List<FoundSessionRow>): List<String> {
        return rows.map { it.folderKey }.distinct()
    }

    /**
     * Recent count: sessions not hidden, ordered recent-first, capped at 8.
     * Used for the entry card count badge.
     */
    fun recentCount(snapshot: FoundSessionsSnapshot): Int {
        return snapshot.sessions.count { it.externalId !in snapshot.hiddenIds }
            .coerceAtMost(8)
    }

    /**
     * Whether the entry card should be shown in BoxHealthScreen.
     * Hidden when capability absent, count==0 & not scanning.
     */
    fun showEntryCard(
        snapshot: FoundSessionsSnapshot?,
        sessionDiscovery: Boolean,
    ): Boolean {
        if (!sessionDiscovery) return false
        if (snapshot == null) return false
        val count = snapshot.sessions.count { it.externalId !in snapshot.hiddenIds }
        val scanning = snapshot.discoveryState is FoundDiscoveryState.Scanning
        return count > 0 || scanning
    }
}
