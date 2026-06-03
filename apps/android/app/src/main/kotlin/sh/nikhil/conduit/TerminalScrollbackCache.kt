package sh.nikhil.conduit

import java.io.File

/**
 * Pure file-backed cache for per-session terminal scrollback, enabling
 * cold-launch restore (see [SessionStore]). Kept separate from SessionStore so
 * the tail-cap + read/write round-trip is unit-testable without an Android
 * Context. Mirror of the inline logic in iOS `SessionStore.swift`.
 *
 * The broker holds the authoritative scrollback and replays it on re-attach;
 * this on-disk copy only seeds the terminal for an instant paint on a cold
 * launch, and is replaced by the live snapshot once the socket connects. So a
 * best-effort, occasionally-stale cache is fine — every failure is swallowed.
 */
object TerminalScrollbackCache {
    /** Keep only the most-recent [CAP] bytes — matches the broker ring size. */
    const val CAP = 256 * 1024

    fun file(dir: File, sessionId: String): File? {
        val safe = sessionId.replace('/', '_').replace("..", "_")
        if (safe.isEmpty()) return null
        return File(dir, "$safe.bin")
    }

    /** Write [data]'s tail (capped to [cap]) to the session's cache file. */
    fun write(dir: File, sessionId: String, data: ByteArray, cap: Int = CAP) {
        if (data.isEmpty()) return
        val f = file(dir, sessionId) ?: return
        if (!dir.exists()) dir.mkdirs()
        val tail = if (data.size > cap) {
            data.copyOfRange(data.size - cap, data.size)
        } else {
            data
        }
        try {
            // Atomic-ish: write a temp then rename so a crash mid-write can't
            // leave a torn file.
            val tmp = File(f.parentFile, "${f.name}.tmp")
            tmp.writeBytes(tail)
            if (!tmp.renameTo(f)) {
                f.writeBytes(tail)
                tmp.delete()
            }
        } catch (_: Exception) {
        }
    }

    /** Read a session's cached scrollback, or null if absent/empty/unreadable. */
    fun read(dir: File, sessionId: String): ByteArray? {
        val f = file(dir, sessionId) ?: return null
        if (!f.exists()) return null
        return try {
            f.readBytes().takeIf { it.isNotEmpty() }
        } catch (_: Exception) {
            null
        }
    }

    fun delete(dir: File, sessionId: String) {
        try {
            file(dir, sessionId)?.delete()
        } catch (_: Exception) {
        }
    }
}
