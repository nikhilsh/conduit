package sh.nikhil.conduit.ui

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

/**
 * Pure-data tests for the reply-haptics decision ([ReplyHapticsModel]), iOS
 * `ReplyHapticsTests` parity: which tap (if any) to play as the chat's
 * `showTyping` busy flag flips — including "don't fire on a mid-turn open",
 * the disabled-but-still-tracking gate, and debounce.
 */
class ReplyHapticsModelTest {

    private fun ReplyHapticsModel.event(busy: Boolean, enabled: Boolean, nowMs: Long) =
        observe(busy, enabled, nowMs)

    @Test fun firstObservationNeverFires() {
        // A session opened mid-turn (already busy) must not tap.
        val (_, e) = ReplyHapticsModel().event(busy = true, enabled = true, nowMs = 0)
        assertNull(e)
    }

    @Test fun firstObservationIdleAlsoSilent() {
        val (_, e) = ReplyHapticsModel().event(busy = false, enabled = true, nowMs = 0)
        assertNull(e)
    }

    @Test fun busyRiseFiresTurnStart() {
        var m = ReplyHapticsModel()
        m = m.event(busy = false, enabled = true, nowMs = 0).first
        val (_, e) = m.event(busy = true, enabled = true, nowMs = 1000)
        assertEquals(ReplyHapticEvent.TurnStart, e)
    }

    @Test fun busyFallFiresTurnFinish() {
        var m = ReplyHapticsModel()
        m = m.event(busy = false, enabled = true, nowMs = 0).first
        m = m.event(busy = true, enabled = true, nowMs = 1000).first
        val (_, e) = m.event(busy = false, enabled = true, nowMs = 5000)
        assertEquals(ReplyHapticEvent.TurnFinish, e)
    }

    @Test fun noFlipNoFire() {
        var m = ReplyHapticsModel()
        m = m.event(busy = false, enabled = true, nowMs = 0).first
        val (_, e) = m.event(busy = false, enabled = true, nowMs = 1000)
        assertNull(e)
    }

    @Test fun disabledSwallowsButStillTracks() {
        var m = ReplyHapticsModel()
        m = m.event(busy = false, enabled = false, nowMs = 0).first
        // Rise while disabled → no tap.
        var r = m.event(busy = true, enabled = false, nowMs = 1000)
        assertNull(r.second)
        m = r.first
        // Re-enable, no flip (still busy) → no spurious start.
        r = m.event(busy = true, enabled = true, nowMs = 2000)
        assertNull(r.second)
        m = r.first
        // Real fall while enabled → finish.
        r = m.event(busy = false, enabled = true, nowMs = 5000)
        assertEquals(ReplyHapticEvent.TurnFinish, r.second)
    }

    @Test fun debounceSwallowsRapidFlip() {
        var m = ReplyHapticsModel(minIntervalMs = 400)
        m = m.event(busy = false, enabled = true, nowMs = 0).first
        var r = m.event(busy = true, enabled = true, nowMs = 0)
        assertEquals(ReplyHapticEvent.TurnStart, r.second)
        m = r.first
        // Falls 100ms later — inside the 400ms window → swallowed.
        r = m.event(busy = false, enabled = true, nowMs = 100)
        assertNull(r.second)
        m = r.first
        // Rises again 200ms after start — still inside → swallowed.
        r = m.event(busy = true, enabled = true, nowMs = 200)
        assertNull(r.second)
    }

    @Test fun debounceAllowsSpacedTurns() {
        var m = ReplyHapticsModel(minIntervalMs = 400)
        m = m.event(busy = false, enabled = true, nowMs = 0).first
        var r = m.event(busy = true, enabled = true, nowMs = 0)
        assertEquals(ReplyHapticEvent.TurnStart, r.second)
        m = r.first
        r = m.event(busy = false, enabled = true, nowMs = 2000)
        assertEquals(ReplyHapticEvent.TurnFinish, r.second)
        m = r.first
        r = m.event(busy = true, enabled = true, nowMs = 4000)
        assertEquals(ReplyHapticEvent.TurnStart, r.second)
    }
}
