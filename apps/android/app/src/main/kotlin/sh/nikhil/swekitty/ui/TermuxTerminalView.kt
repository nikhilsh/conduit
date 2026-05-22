package sh.nikhil.swekitty.ui

import android.content.Context
import android.graphics.Color as AndroidColor
import android.util.Log
import android.view.Gravity
import android.view.KeyEvent
import android.view.MotionEvent
import android.view.View
import android.view.ViewGroup
import android.widget.FrameLayout
import android.widget.TextView
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.remember
import androidx.compose.ui.Modifier
import androidx.compose.ui.viewinterop.AndroidView
import com.termux.terminal.KeyHandler
import com.termux.terminal.TerminalSession
import com.termux.terminal.TerminalSessionClient
import com.termux.view.TerminalView
import com.termux.view.TerminalViewClient
import sh.nikhil.swekitty.SessionStore
import uniffi.swe_kitty_core.ProjectSession

/**
 * Android mirror of iOS [GhosttyTerminalView]. Stage 2 of the
 * terminal-renderer rewrite — see `docs/PLAN-TERMINAL-REWRITE.md`
 * (Android section, "Stage 2 — input + selection + accessory bar
 * parity"). Stage 2 deliverable: route the broker's live PTY byte
 * stream into Termux's [com.termux.terminal.TerminalEmulator] and
 * forward user keystrokes back to the broker via
 * [SessionStore.sendInput].
 *
 * Stage 1 mounted a `TerminalView` with a hardcoded banner and a
 * real `/system/bin/sh` subprocess. Stage 2 keeps the `TerminalView`
 * mount + the local subprocess (now `/system/bin/sleep` so it's
 * silent) but **bypasses** the local PTY for output: broker bytes
 * are pushed straight into [com.termux.terminal.TerminalEmulator.append]
 * via the public `TerminalSession.getEmulator()` handle, mirroring
 * the way `WebTerminal.kt` feeds xterm.js. The local subprocess
 * still exists because [TerminalSession] is `final` and we can't
 * subclass it to avoid the JNI `createSubprocess` call — see the
 * gap doc in `docs/PLAN-TERMINAL-REWRITE.md`.
 *
 * Input is intercepted **before** it reaches the local PTY:
 *  - text codepoints — [TerminalViewClient.onCodePoint] returns
 *    `true` and we forward UTF-8 bytes to [SessionStore.sendInput].
 *  - hardware special keys (arrows / Esc / Enter / Tab / Ctrl-X) —
 *    [TerminalViewClient.onKeyDown] returns `true`, we compute the
 *    ANSI sequence via [KeyHandler.getCode] and forward it.
 *  - resize — a [View.OnLayoutChangeListener] on the [TerminalView]
 *    reads the emulator's freshly-computed dimensions after each
 *    layout pass and forwards them to [SessionStore.resize].
 *
 * Risk mitigation: the entire factory body is wrapped in a try/catch.
 * If the Termux Maven dep ever fails to resolve, or the JNI
 * `createSubprocess` throws on a hardened device, the wrapper falls
 * back to [TermuxPlaceholderView] (the Stage 0 placeholder) so the
 * Android build still works. We log the exception via [Log.w] with
 * a tag the catcher can grep in `adb logcat` to know which path is
 * live.
 *
 * Toggling [sh.nikhil.swekitty.AppearanceStore.experimentalNativeTerminal]
 * off restores the production xterm.js path ([WebTerminal]) within one
 * Compose recomposition — identical rollback shape to iOS.
 */
@Composable
fun TermuxTerminalView(
    store: SessionStore,
    session: ProjectSession,
    modifier: Modifier = Modifier,
) {
    val config = TermuxSessionConfig.from(session)
    // Per-session mount state: holds the TerminalView (or the
    // placeholder fallback) and the byte-feed cursor. Survives
    // recompositions; if the session id changes Compose rebuilds it
    // so a fresh attach can't reuse a stale `lastFedByteCount`.
    val mount = remember(session.id) { TermuxMount() }
    // Bumped by `BrokerTerminalViewClient.onEmulatorSet` when
    // Termux's emulator finishes its first-layout init. Hosted in
    // Compose state so the LaunchedEffect below recomposes against
    // it and can replay any broker bytes that arrived before the
    // emulator was ready.
    val emulatorReadyTick = remember(session.id) { mutableIntStateOf(0) }
    val buffers by store.terminalBuffer.collectAsState()
    val rawBuffer = buffers[session.id] ?: ByteArray(0)

    AndroidView(
        modifier = modifier,
        factory = { ctx ->
            try {
                buildTermuxTerminalView(
                    ctx = ctx,
                    config = config,
                    sessionId = session.id,
                    onInput = { bytes -> store.sendInput(session.id, bytes) },
                    onResize = { rows, cols ->
                        store.resize(session.id, rows.toUShort(), cols.toUShort())
                    },
                    onEmulatorReady = { emulatorReadyTick.intValue += 1 },
                    mount = mount,
                )
            } catch (t: Throwable) {
                // Catch Errors too (e.g. NoClassDefFoundError if the
                // JitPack dep didn't resolve at runtime on some
                // device). Either way, the Stage 0 placeholder is the
                // safe fallback — the user still sees a black-bg
                // status surface and the rest of the app stays alive.
                Log.w(TAG, "TerminalView mount failed; falling back to placeholder", t)
                TermuxPlaceholderView(ctx)
            }
        },
        update = { _ ->
            // Diff the broker buffer against the last byte count we
            // fed into the emulator and ship only the delta. If the
            // buffer shrank (snapshot replace), reset the emulator
            // and replay from scratch. Mirrors the xterm.js feed
            // discipline in `WebTerminal.kt`.
            val session = mount.session ?: return@AndroidView
            val emulator = session.emulator ?: return@AndroidView
            val decision = computeFeed(rawBuffer, mount.lastFedByteCount)
            if (decision.reset) {
                runCatching { session.reset() }
            }
            if (decision.bytes.isNotEmpty()) {
                emulator.append(decision.bytes, decision.bytes.size)
                mount.terminalView?.invalidate()
            }
            mount.lastFedByteCount = decision.newCursor
        },
    )

    // Detect snapshot replay separately: if `terminalBuffer` arrives
    // before the emulator is ready (first layout hasn't happened
    // yet) the update lambda above no-ops because emulator is null.
    // The LaunchedEffect re-runs on each new buffer and on emulator
    // initialization so we catch the first frame.
    LaunchedEffect(session.id, rawBuffer, emulatorReadyTick.intValue) {
        val s = mount.session ?: return@LaunchedEffect
        val emulator = s.emulator ?: return@LaunchedEffect
        val decision = computeFeed(rawBuffer, mount.lastFedByteCount)
        if (decision.reset) {
            runCatching { s.reset() }
        }
        if (decision.bytes.isNotEmpty()) {
            emulator.append(decision.bytes, decision.bytes.size)
            mount.terminalView?.invalidate()
        }
        mount.lastFedByteCount = decision.newCursor
    }

    DisposableEffect(session.id) {
        onDispose {
            runCatching { mount.session?.finishIfRunning() }
            mount.session = null
            mount.terminalView = null
        }
    }
}

private const val TAG = "TermuxTerminalView"

/**
 * Compute the delta to feed into Termux's emulator. Pulled out as a
 * pure function so a JUnit test can exercise the
 * grow / shrink / equal cases without an Android Context. Mirror of
 * the `lastFedByteCount` diff in `WebTerminal.kt`.
 *
 * `reset` is set when the broker buffer shrank below our cursor — a
 * snapshot replay, which means we should `TerminalSession.reset()`
 * and replay the whole buffer.
 */
internal data class FeedDecision(
    val reset: Boolean,
    val bytes: ByteArray,
    val newCursor: Int,
) {
    override fun equals(other: Any?): Boolean {
        if (this === other) return true
        if (other !is FeedDecision) return false
        return reset == other.reset &&
            bytes.contentEquals(other.bytes) &&
            newCursor == other.newCursor
    }

    override fun hashCode(): Int {
        var r = reset.hashCode()
        r = 31 * r + bytes.contentHashCode()
        r = 31 * r + newCursor
        return r
    }
}

internal fun computeFeed(buffer: ByteArray, lastFedByteCount: Int): FeedDecision = when {
    buffer.size > lastFedByteCount -> FeedDecision(
        reset = false,
        bytes = buffer.copyOfRange(lastFedByteCount, buffer.size),
        newCursor = buffer.size,
    )
    buffer.size < lastFedByteCount -> FeedDecision(
        reset = true,
        bytes = buffer.copyOf(),
        newCursor = buffer.size,
    )
    else -> FeedDecision(reset = false, bytes = ByteArray(0), newCursor = lastFedByteCount)
}

/**
 * Mutable per-session mount state. Holds the [TerminalView] and
 * [TerminalSession] handles so the `update` lambda can feed bytes
 * without re-running the factory, and the `lastFedByteCount` cursor
 * for the diff. The "emulator ready" signal lives in a separate
 * Compose `mutableIntStateOf` so a [LaunchedEffect] can recompose
 * against it on first layout — see the Composable above.
 */
internal class TermuxMount {
    var terminalView: TerminalView? = null
    var session: TerminalSession? = null
    var lastFedByteCount: Int = 0
}

/**
 * Stage 2 banner — written into the emulator on mount so the screen
 * isn't blank while the (broker) attach warms up. Mirrors the iOS
 * Stage 1 "GhosttyVT linked" debug print.
 */
private const val STAGE2_BANNER = "Termux Stage 2 mounted — awaiting broker bytes…\r\n"

/**
 * Build the live [TerminalView] hosting a Termux [TerminalSession].
 *
 * Kept as a top-level function so it can be unit-tested separately —
 * today's call sites: the factory above and any future Roborazzi
 * snapshot that wants to render the live surface instead of the
 * placeholder.
 */
private fun buildTermuxTerminalView(
    ctx: Context,
    config: TermuxSessionConfig,
    sessionId: String,
    onInput: (ByteArray) -> Unit,
    onResize: (Int, Int) -> Unit,
    onEmulatorReady: () -> Unit,
    mount: TermuxMount,
): View {
    val view = TerminalView(ctx, /* attributes= */ null).apply {
        setBackgroundColor(AndroidColor.BLACK)
        layoutParams = ViewGroup.LayoutParams(
            ViewGroup.LayoutParams.MATCH_PARENT,
            ViewGroup.LayoutParams.MATCH_PARENT,
        )
        isFocusable = true
        isFocusableInTouchMode = true
    }

    val viewClient = BrokerTerminalViewClient(
        sessionId = sessionId,
        onInput = onInput,
        onEmulatorReady = onEmulatorReady,
        getTerminalView = { mount.terminalView },
    )
    view.setTerminalViewClient(viewClient)

    val session = TerminalSession(
        /* shellPath = */ config.shellPath,
        /* cwd = */ config.cwd,
        /* args = */ config.args,
        /* env = */ config.env,
        /* transcriptRows = */ TermuxSessionConfig.TRANSCRIPT_ROWS,
        /* client = */ NoopTerminalSessionClient,
    )
    view.attachSession(session)

    mount.terminalView = view
    mount.session = session
    mount.lastFedByteCount = 0

    // Reflow + initial-size wiring. TerminalView's own onSizeChanged
    // calls TerminalSession.updateSize which initializes the
    // emulator on the first layout. We piggyback via a layout-change
    // listener: after each layout, if the emulator dimensions
    // changed, forward to the broker. Pre-emulator layouts are
    // ignored (cols/rows read as 0).
    var lastReportedCols = 0
    var lastReportedRows = 0
    view.addOnLayoutChangeListener { _, _, _, _, _, _, _, _, _ ->
        val emu = session.emulator ?: return@addOnLayoutChangeListener
        val cols = emu.mColumns
        val rows = emu.mRows
        if (cols > 0 && rows > 0 && (cols != lastReportedCols || rows != lastReportedRows)) {
            lastReportedCols = cols
            lastReportedRows = rows
            onResize(rows, cols)
        }
    }

    // Stage 2 banner. `emulator` is null until updateSize runs on
    // the first layout pass — defer the append until then so we
    // don't NPE. The LaunchedEffect in the Composable will also
    // (idempotently) replay any broker buffer that arrived early.
    view.post {
        try {
            val bytes = STAGE2_BANNER.toByteArray(Charsets.UTF_8)
            val emulator = session.emulator
            emulator?.append(bytes, bytes.size)
            view.invalidate()
        } catch (t: Throwable) {
            Log.w(TAG, "Stage 2 banner inject failed", t)
        }
    }

    return view
}

/**
 * Plain-data Stage 2 plumbing helper. Lifted out of the Compose
 * function so [buildTermuxTerminalView] is testable without standing
 * up an Android Context.
 *
 * The local subprocess is now `/system/bin/sleep 2147483647`
 * instead of `/system/bin/sh` — the local PTY needs *something* to
 * keep the JNI fd alive (since `TerminalSession` is `final` and we
 * can't elide [JNI.createSubprocess]) but it must produce no output
 * or the local shell prompt will race the broker bytes. `sleep`
 * with INT_MAX seconds (~68 years) is silent and quiescent. Stage 2
 * acceptance accepts this local-PTY wart — see
 * `docs/PLAN-TERMINAL-REWRITE.md`.
 */
internal data class TermuxSessionConfig(
    val shellPath: String,
    val cwd: String,
    val args: Array<String>,
    val env: Array<String>,
) {
    companion object {
        // Termux's default; large enough to hold a typical session's
        // history without paging. The broker keeps the source-of-
        // truth ring in `SessionStore.terminalBuffer`; this only
        // bounds the Termux emulator's own scrollback.
        const val TRANSCRIPT_ROWS = 2_000

        /** Max int seconds — about 68 years; quiescent enough. */
        private const val SLEEP_FOREVER = "2147483647"

        /**
         * Build the Stage 2 config from a [ProjectSession]. Pure
         * function for unit-testability. Stage 2 ignores
         * `session.id` for the subprocess args — the local PTY is
         * just a backstop for the JNI fd; the broker session id
         * lives in the [TermuxTerminalView] closure.
         */
        fun from(@Suppress("UNUSED_PARAMETER") session: ProjectSession): TermuxSessionConfig {
            return TermuxSessionConfig(
                // `/system/bin/sleep` exists on every Android device
                // since API 1. Picked over `/system/bin/sh` to keep
                // the local PTY silent — we route all output through
                // the broker (see class kdoc).
                shellPath = "/system/bin/sleep",
                cwd = "/",
                args = arrayOf("/system/bin/sleep", SLEEP_FOREVER),
                env = arrayOf(
                    "TERM=xterm-256color",
                    "HOME=/",
                    "PATH=/system/bin:/system/xbin",
                ),
            )
        }
    }

    // data class with arrays: opt into structural equality so the
    // JUnit test can assert on `copy()` round-trips without relying
    // on identity. Cheap enough at the call rate (once per mount).
    override fun equals(other: Any?): Boolean {
        if (this === other) return true
        if (other !is TermuxSessionConfig) return false
        return shellPath == other.shellPath &&
            cwd == other.cwd &&
            args.contentEquals(other.args) &&
            env.contentEquals(other.env)
    }

    override fun hashCode(): Int {
        var r = shellPath.hashCode()
        r = 31 * r + cwd.hashCode()
        r = 31 * r + args.contentHashCode()
        r = 31 * r + env.contentHashCode()
        return r
    }
}

/**
 * Stage 2 [TerminalViewClient] that funnels keystrokes through to
 * the broker via `onInput`. Text codepoints and hardware special
 * keys (arrows / Esc / Tab / Ctrl-X) are both intercepted **before**
 * they reach `TerminalSession.write` — the local subprocess never
 * sees user input.
 *
 * Logs forward to logcat so a `adb logcat -s TermuxTerminalView`
 * tail shows the input flow during bring-up.
 */
internal class BrokerTerminalViewClient(
    @Suppress("unused") private val sessionId: String,
    private val onInput: (ByteArray) -> Unit,
    private val onEmulatorReady: () -> Unit,
    private val getTerminalView: () -> TerminalView?,
) : TerminalViewClient {
    override fun onScale(scale: Float): Float = 1f
    override fun onSingleTapUp(e: MotionEvent) {
        // Match WebTerminal's behaviour — a tap summons the soft
        // keyboard. TerminalView is already focusable; we only need
        // to request focus.
        getTerminalView()?.requestFocus()
    }
    override fun shouldBackButtonBeMappedToEscape(): Boolean = false
    override fun shouldEnforceCharBasedInput(): Boolean = false
    override fun shouldUseCtrlSpaceWorkaround(): Boolean = false
    override fun isTerminalViewSelected(): Boolean = true
    override fun copyModeChanged(copyMode: Boolean) {}

    /**
     * Hardware-key handler. Translates [keyCode] + modifiers into
     * the ANSI sequence Termux's emulator would otherwise hand off
     * to the local PTY, then forwards the bytes to the broker.
     * Returns `true` to consume the event — `TerminalView` will not
     * call `mTermSession.write(...)` afterward.
     */
    override fun onKeyDown(
        keyCode: Int,
        e: KeyEvent?,
        session: TerminalSession?,
    ): Boolean {
        if (e == null) return false
        // Action keys (Tab, Enter, arrows, Esc, F-keys, …) have a
        // canonical ANSI sequence in Termux's KeyHandler. Try that
        // path first.
        val mod = computeKeyMod(e)
        val emu = session?.emulator
        val cursorApp = emu?.isCursorKeysApplicationMode ?: false
        val keypadApp = emu?.isKeypadApplicationMode ?: false
        val code = KeyHandler.getCode(keyCode, mod, cursorApp, keypadApp)
        if (code != null) {
            onInput(code.toByteArray(Charsets.UTF_8))
            return true
        }
        // Printable characters arrive via onCodePoint below, so
        // falling through here is fine — TerminalView will translate
        // the KeyEvent into a code point and call onCodePoint, which
        // we also intercept.
        return false
    }

    private fun computeKeyMod(e: KeyEvent): Int {
        var mod = 0
        if (e.isCtrlPressed) mod = mod or KeyHandler.KEYMOD_CTRL
        if (e.isAltPressed) mod = mod or KeyHandler.KEYMOD_ALT
        if (e.isShiftPressed) mod = mod or KeyHandler.KEYMOD_SHIFT
        if (e.isNumLockOn) mod = mod or KeyHandler.KEYMOD_NUM_LOCK
        return mod
    }

    override fun onKeyUp(keyCode: Int, e: KeyEvent?): Boolean = false
    override fun onLongPress(event: MotionEvent?): Boolean = false
    override fun readControlKey(): Boolean = false
    override fun readAltKey(): Boolean = false
    override fun readShiftKey(): Boolean = false
    override fun readFnKey(): Boolean = false

    /**
     * Soft-keyboard / printable-key handler. UTF-8 encode the code
     * point and forward to the broker. Returns `true` to consume the
     * event — `TerminalView.inputCodePoint` will not call
     * `mTermSession.writeCodePoint(...)` afterward.
     */
    override fun onCodePoint(
        codePoint: Int,
        ctrlDown: Boolean,
        session: TerminalSession?,
    ): Boolean {
        if (codePoint < 0) return true
        val cp = if (ctrlDown) foldControl(codePoint) else codePoint
        // Termux's TerminalView folds control characters before
        // calling onCodePoint, but the JS bridge equivalent (`xterm.js`)
        // expects the raw control byte — mirror that by folding here
        // too. If the caller already folded (ctrlDown=false), this is
        // a no-op.
        val bytes = encodeCodePointUtf8(cp)
        if (bytes.isNotEmpty()) onInput(bytes)
        return true
    }

    /**
     * Fold a printable character + Ctrl modifier into the
     * corresponding control byte. Lifted from
     * `TerminalView.inputCodePoint` (the lines after the
     * `mClient.onCodePoint` return) so our broker-forwarded bytes
     * match what the local PTY would have received.
     */
    private fun foldControl(codePoint: Int): Int = when (codePoint) {
        in 'a'.code..'z'.code -> codePoint - 'a'.code + 1
        in 'A'.code..'Z'.code -> codePoint - 'A'.code + 1
        ' '.code, '2'.code -> 0
        '['.code, '3'.code -> 27
        '\\'.code, '4'.code -> 28
        ']'.code, '5'.code -> 29
        '^'.code, '6'.code -> 30
        '_'.code, '7'.code, '/'.code -> 31
        '8'.code -> 127
        else -> codePoint
    }

    /** Standard UTF-8 encode of one code point. */
    private fun encodeCodePointUtf8(codePoint: Int): ByteArray {
        if (codePoint < 0 || codePoint > 0x10FFFF) return ByteArray(0)
        return String(intArrayOf(codePoint), 0, 1).toByteArray(Charsets.UTF_8)
    }

    override fun onEmulatorSet() {
        // Bump the readiness tick so the Compose LaunchedEffect can
        // replay any pre-mount broker bytes.
        onEmulatorReady()
    }

    override fun logError(tag: String?, message: String?) {
        Log.e(tag ?: TAG, message ?: "")
    }
    override fun logWarn(tag: String?, message: String?) {
        Log.w(tag ?: TAG, message ?: "")
    }
    override fun logInfo(tag: String?, message: String?) {
        Log.i(tag ?: TAG, message ?: "")
    }
    override fun logDebug(tag: String?, message: String?) {
        Log.d(tag ?: TAG, message ?: "")
    }
    override fun logVerbose(tag: String?, message: String?) {
        Log.v(tag ?: TAG, message ?: "")
    }
    override fun logStackTraceWithMessage(tag: String?, message: String?, e: Exception?) {
        Log.e(tag ?: TAG, message ?: "", e)
    }
    override fun logStackTrace(tag: String?, e: Exception?) {
        Log.e(tag ?: TAG, "", e)
    }
}

/**
 * Stage 2 [TerminalSessionClient]. Title / bell / clipboard hooks
 * are still no-ops — those land with the Stage 3 polish pass — but
 * the log forwarders are real so Termux's internal logs surface in
 * `adb logcat`.
 */
private object NoopTerminalSessionClient : TerminalSessionClient {
    override fun onTextChanged(changedSession: TerminalSession?) {}
    override fun onTitleChanged(changedSession: TerminalSession?) {}
    override fun onSessionFinished(finishedSession: TerminalSession?) {}
    override fun onCopyTextToClipboard(session: TerminalSession?, text: String?) {}
    override fun onPasteTextFromClipboard(session: TerminalSession?) {}
    override fun onBell(session: TerminalSession?) {}
    override fun onColorsChanged(session: TerminalSession?) {}
    override fun onTerminalCursorStateChange(state: Boolean) {}
    override fun getTerminalCursorStyle(): Int? = null
    override fun logError(tag: String?, message: String?) {
        Log.e(tag ?: TAG, message ?: "")
    }
    override fun logWarn(tag: String?, message: String?) {
        Log.w(tag ?: TAG, message ?: "")
    }
    override fun logInfo(tag: String?, message: String?) {
        Log.i(tag ?: TAG, message ?: "")
    }
    override fun logDebug(tag: String?, message: String?) {
        Log.d(tag ?: TAG, message ?: "")
    }
    override fun logVerbose(tag: String?, message: String?) {
        Log.v(tag ?: TAG, message ?: "")
    }
    override fun logStackTraceWithMessage(tag: String?, message: String?, e: Exception?) {
        Log.e(tag ?: TAG, message ?: "", e)
    }
    override fun logStackTrace(tag: String?, e: Exception?) {
        Log.e(tag ?: TAG, "", e)
    }
}

/**
 * Stage 0 fallback. Kept exported so the try/catch above can still
 * mount it when the Termux dep fails to resolve. Same visual shape
 * the placeholder used before Stage 1.
 */
internal class TermuxPlaceholderView(context: Context) : FrameLayout(context) {
    init {
        setBackgroundColor(AndroidColor.BLACK)
        layoutParams = ViewGroup.LayoutParams(
            ViewGroup.LayoutParams.MATCH_PARENT,
            ViewGroup.LayoutParams.MATCH_PARENT,
        )

        val label = TextView(context).apply {
            text = "Termux unavailable — falling back to placeholder " +
                "(see PLAN-TERMINAL-REWRITE Android section)"
            setTextColor(AndroidColor.WHITE)
            textSize = 13f
            gravity = Gravity.CENTER
            typeface = android.graphics.Typeface.MONOSPACE
            setPadding(48, 24, 48, 24)
        }
        val lp = LayoutParams(
            LayoutParams.WRAP_CONTENT,
            LayoutParams.WRAP_CONTENT,
        ).apply { gravity = Gravity.CENTER }
        addView(label, lp)
    }

    override fun onTouchEvent(event: android.view.MotionEvent): Boolean {
        if (event.action == android.view.MotionEvent.ACTION_UP) {
            requestFocus()
            performClick()
        }
        return true
    }

    override fun performClick(): Boolean {
        super.performClick()
        return true
    }
}
