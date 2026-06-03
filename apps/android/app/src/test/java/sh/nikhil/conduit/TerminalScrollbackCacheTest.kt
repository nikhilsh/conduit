package sh.nikhil.conduit

import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder

/**
 * Android mirror of the cold-launch terminal-restore round-trip pinned on iOS
 * in `apps/ios/Tests/ConduitTests/TerminalScrollbackPersistenceTests.swift`.
 * Exercises [TerminalScrollbackCache] (the pure file/cap logic [SessionStore]
 * delegates to) so we stay on the JVM unit-test classpath without an Android
 * Context.
 */
class TerminalScrollbackCacheTest {

    @get:Rule
    val tmp = TemporaryFolder()

    @Test
    fun write_then_read_roundTrips() {
        val dir = tmp.newFolder("scrollback")
        val bytes = "scrollback survives a kill".toByteArray()
        TerminalScrollbackCache.write(dir, "sess-1", bytes)
        assertArrayEquals(bytes, TerminalScrollbackCache.read(dir, "sess-1"))
    }

    @Test
    fun write_keepsTailWithinCap() {
        val dir = tmp.newFolder("scrollback")
        val cap = 1024
        val marker = "THE-LATEST-BYTES".toByteArray()
        val big = ByteArray(cap + 5_000) + marker
        TerminalScrollbackCache.write(dir, "sess-cap", big, cap = cap)

        val restored = TerminalScrollbackCache.read(dir, "sess-cap")!!
        assertEquals(cap, restored.size)
        // The most-recent bytes (the marker) must be retained at the tail.
        assertArrayEquals(marker, restored.copyOfRange(restored.size - marker.size, restored.size))
    }

    @Test
    fun read_missing_isNull() {
        val dir = tmp.newFolder("scrollback")
        assertNull(TerminalScrollbackCache.read(dir, "never-written"))
    }

    @Test
    fun delete_removesFile() {
        val dir = tmp.newFolder("scrollback")
        TerminalScrollbackCache.write(dir, "sess-del", "temporary".toByteArray())
        TerminalScrollbackCache.delete(dir, "sess-del")
        assertNull(TerminalScrollbackCache.read(dir, "sess-del"))
    }

    @Test
    fun emptyData_writesNothing() {
        val dir = tmp.newFolder("scrollback")
        TerminalScrollbackCache.write(dir, "sess-empty", ByteArray(0))
        assertNull(TerminalScrollbackCache.read(dir, "sess-empty"))
    }
}
