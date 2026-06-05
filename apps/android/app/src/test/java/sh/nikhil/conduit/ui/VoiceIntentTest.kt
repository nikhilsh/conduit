package sh.nikhil.conduit.ui

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Pins the honest keyword heuristic behind the voice-sheet detected-intent
 * chips (handoff §B.8). The heuristic must NOT fabricate: empty / neutral
 * speech yields no chips. Action verbs → a `task` chip, the word
 * test/tests/spec → a `+ test` chip, file-looking tokens → one chip each.
 * Mirrors iOS `VoiceIntent.detect`.
 */
class VoiceIntentTest {

    @Test fun blankYieldsNothing() {
        assertTrue(detectVoiceIntents("").isEmpty())
        assertTrue(detectVoiceIntents("   ").isEmpty())
    }

    @Test fun neutralSpeechYieldsNothing() {
        // No action verb, no test, no file token → no fabrication.
        assertTrue(detectVoiceIntents("can you tell me about the weather").isEmpty())
    }

    @Test fun actionVerbYieldsTask() {
        val chips = detectVoiceIntents("add rate limiting to the login endpoint")
        assertTrue(chips.any { it.kind == VoiceIntentKind.ACTION && it.label == "task" })
    }

    @Test fun testWordYieldsTestChip() {
        val chips = detectVoiceIntents("and write a test that hits it eleven times")
        assertTrue(chips.any { it.kind == VoiceIntentKind.TEST && it.label == "test" })
    }

    @Test fun fileTokenYieldsFileChip() {
        val chips = detectVoiceIntents("refactor login.ts and helpers.kt")
        val files = chips.filter { it.kind == VoiceIntentKind.FILE }.map { it.label }
        assertTrue(files.contains("login.ts"))
        assertTrue(files.contains("helpers.kt"))
    }

    @Test fun targetExampleProducesTaskTestAndFile() {
        // The exact transcript shown in images/09-voice.png.
        val chips = detectVoiceIntents(
            "Add rate limiting to the login endpoint and write a test that hits it eleven times login.ts",
        )
        assertTrue(chips.any { it.kind == VoiceIntentKind.ACTION })
        assertTrue(chips.any { it.kind == VoiceIntentKind.TEST })
        assertTrue(chips.any { it.kind == VoiceIntentKind.FILE && it.label == "login.ts" })
    }

    @Test fun cappedAtFour() {
        val chips = detectVoiceIntents("add fix a.ts b.ts c.ts d.ts e.ts test")
        assertEquals(4, chips.size)
    }

    @Test fun fileTokensDeduped() {
        val chips = detectVoiceIntents("edit login.ts then edit login.ts again")
        assertEquals(1, chips.count { it.label == "login.ts" })
    }
}
