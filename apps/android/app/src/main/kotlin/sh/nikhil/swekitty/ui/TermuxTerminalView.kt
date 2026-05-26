package sh.nikhil.swekitty.ui

import android.content.ClipData
import android.content.ClipboardManager
import android.content.Context
import android.content.res.Configuration
import android.graphics.Color as AndroidColor
import android.graphics.Typeface
import android.util.Log
import android.util.TypedValue
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
import sh.nikhil.swekitty.AppearanceStore
import sh.nikhil.swekitty.LocalAppearanceStore
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

    // Appearance-driven palette + font. A theme/font change recomposes
    // and re-applies to the live emulator without a remount. Font-family
    // choice maps to a typeface that's always monospaced (the cell grid
    // can't tolerate proportional widths) but follows the user's design
    // hint where the system ships a matching variant.
    val appearance = LocalAppearanceStore.current
    val fontFamily by appearance.fontFamily.collectAsState()
    // Terminal colour theme + font size are the SAME user-tunable
    // controls the xterm.js path reads, so the native (Termux) path
    // honours them too. The curated theme (Ghostty Dark / Solarized /
    // Nord / Dracula / Gruvbox) drives the colour table; it replaces
    // the old light/dark `forMode` split (all five are dark themes,
    // matching iOS).
    val terminalTheme by appearance.terminalTheme.collectAsState()
    val terminalFontSize by appearance.terminalFontSize.collectAsState()
    val palette = TerminalPalette.forTheme(terminalTheme)

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
                    initialPalette = palette,
                    initialFontFamily = fontFamily,
                    initialFontSize = terminalFontSize,
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

    // Re-apply appearance on every recomposition that changes the
    // palette or font family. The `applyAppearance` helper is
    // idempotent — same inputs, same view → no-op — so this is cheap
    // and lets a Settings-sheet swap take effect without remounting.
    LaunchedEffect(palette, fontFamily, terminalFontSize, emulatorReadyTick.intValue) {
        val view = mount.terminalView ?: return@LaunchedEffect
        applyAppearance(view, mount.session, palette, fontFamily, terminalFontSize)
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
    initialPalette: TerminalPalette,
    initialFontFamily: AppearanceStore.FontFamily,
    initialFontSize: Float,
): View {
    val view = TerminalView(ctx, /* attributes= */ null).apply {
        setBackgroundColor(initialPalette.defaultBackground)
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

    val sessionClient = BrokerTerminalSessionClient(
        appContext = ctx.applicationContext,
        onInput = onInput,
    )
    val session = TerminalSession(
        /* shellPath = */ config.shellPath,
        /* cwd = */ config.cwd,
        /* args = */ config.args,
        /* env = */ config.env,
        /* transcriptRows = */ TermuxSessionConfig.TRANSCRIPT_ROWS,
        /* client = */ sessionClient,
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

    // Apply the user's font + palette before the first frame so the
    // initial paint already reads from `AppearanceStore`. Colour table
    // wires through to the emulator on `view.post {}` because the
    // emulator instance isn't live until the first layout pass.
    applyAppearance(view, /* session = */ null, initialPalette, initialFontFamily, initialFontSize)

    // Stage 2 banner. `emulator` is null until updateSize runs on
    // the first layout pass — defer the append until then so we
    // don't NPE. The LaunchedEffect in the Composable will also
    // (idempotently) replay any broker buffer that arrived early.
    view.post {
        try {
            val bytes = STAGE2_BANNER.toByteArray(Charsets.UTF_8)
            val emulator = session.emulator
            emulator?.append(bytes, bytes.size)
            // Re-apply once the emulator is live so the per-colour
            // table sees the user's palette on the first frame.
            applyAppearance(view, session, initialPalette, initialFontFamily, initialFontSize)
            view.invalidate()
        } catch (t: Throwable) {
            Log.w(TAG, "Stage 2 banner inject failed", t)
        }
    }

    return view
}

/**
 * Apply the user-selected palette + font choice to a live
 * [TerminalView]. Idempotent — same inputs, same view → no visible
 * change — so it's safe to call from a Compose `LaunchedEffect`
 * keyed against [TerminalPalette] / [AppearanceStore.FontFamily].
 *
 * Colour table wiring relies on Termux's [com.termux.terminal.TerminalEmulator]
 * exposing its 256-colour table via the well-known `mColors` field.
 * We poke entries 0..15 (the ANSI slots) plus the two default
 * fg/bg slots (`COLOR_INDEX_FOREGROUND` = 256, `COLOR_INDEX_BACKGROUND` = 257)
 * directly into `mCurrentColors[]`. If a future Termux release
 * rearranges those fields the call is wrapped in a runCatching so
 * we fall back to text/typeface theming only — better than crashing.
 *
 * Dynamic Type / system font scale: [TerminalView.setTextSize]
 * takes pixels; we multiply the base 13sp by the
 * [Configuration.fontScale] so a user who's bumped Android's "Font
 * size" preference gets a proportionally larger cell. Matches the
 * iOS `UIFontMetrics.default.scaledValue(for:)` behaviour.
 */
internal fun applyAppearance(
    view: TerminalView,
    session: TerminalSession?,
    palette: TerminalPalette,
    fontFamily: AppearanceStore.FontFamily,
    fontSize: Float = AppearanceStore.DEFAULT_TERMINAL_FONT_SIZE,
) {
    // 1. Background — the view's own backing colour shows through
    //    cells with `defaultBackground` so the palette swap takes
    //    effect even on rows the emulator hasn't repainted yet.
    runCatching { view.setBackgroundColor(palette.defaultBackground) }

    // 2. Typeface. Always a monospaced face — the cell grid renderer
    //    in Termux assumes fixed-width glyphs. The user's family
    //    choice still influences the picked typeface (serif → falls
    //    back to monospace; system → typewriter-ish; monospaced →
    //    Typeface.MONOSPACE).
    val typeface = when (fontFamily) {
        AppearanceStore.FontFamily.Monospaced -> Typeface.MONOSPACE
        AppearanceStore.FontFamily.System -> Typeface.MONOSPACE
    }
    runCatching { view.setTypeface(typeface) }

    // 3. Cell text size. Base is the user's Settings terminal font size
    //    (default 10sp, denser than the old 13sp — matches iOS), scaled
    //    against the system "Font size" preference for Dynamic-Type
    //    parity with iOS.
    val res = view.resources
    val fontScale = res.configuration.fontScale.coerceAtLeast(0.5f)
    val px = TypedValue.applyDimension(
        TypedValue.COMPLEX_UNIT_SP,
        fontSize * fontScale,
        res.displayMetrics,
    )
    runCatching { view.setTextSize(px.toInt()) }

    // 4. Colour table — best-effort. Termux's TerminalColors lives at
    //    `emulator.mColors`; the `mCurrentColors` int[] indexes 0..15
    //    for ANSI slots and 256/257 for fg/bg defaults (xterm's
    //    convention; same constants the upstream Termux app uses).
    val emulator = session?.emulator ?: return
    runCatching {
        val colors = emulator.mColors
        for (i in palette.ansi.indices) {
            colors.mCurrentColors[i] = palette.ansi[i]
        }
        colors.mCurrentColors[COLOR_INDEX_FOREGROUND] = palette.defaultForeground
        colors.mCurrentColors[COLOR_INDEX_BACKGROUND] = palette.defaultBackground
        view.onScreenUpdated()
    }
}

/** Xterm's "default foreground" index — same constant Termux uses. */
private const val COLOR_INDEX_FOREGROUND = 256
/** Xterm's "default background" index. */
private const val COLOR_INDEX_BACKGROUND = 257

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
 * Stage 3 [TerminalSessionClient]. Wires Termux's built-in
 * selection-action-mode callbacks into the system clipboard and the
 * broker:
 *  - [onCopyTextToClipboard] runs when the user taps Copy in the
 *    Termux floating toolbar after dragging a selection. We push the
 *    text onto `ClipboardManager.primaryClip` so any other app can
 *    paste it.
 *  - [onPasteTextFromClipboard] runs when the user taps Paste. We
 *    read the system clipboard and forward the bytes through
 *    [SessionStore.sendInput] (`onInput`) so the broker — not the
 *    silent local PTY — receives the input.
 *
 * Title / bell / cursor hooks remain no-ops; theming + bell handling
 * are still queued for a polish pass. The log forwarders are real so
 * Termux's internal logs surface in `adb logcat -s TermuxTerminalView`.
 */
internal class BrokerTerminalSessionClient(
    private val appContext: Context,
    private val onInput: (ByteArray) -> Unit,
) : TerminalSessionClient {
    override fun onTextChanged(changedSession: TerminalSession?) {}
    override fun onTitleChanged(changedSession: TerminalSession?) {}
    override fun onSessionFinished(finishedSession: TerminalSession?) {}

    override fun onCopyTextToClipboard(session: TerminalSession?, text: String?) {
        val payload = text ?: return
        if (payload.isEmpty()) return
        try {
            val cm = appContext.getSystemService(Context.CLIPBOARD_SERVICE)
                as? ClipboardManager ?: return
            cm.setPrimaryClip(ClipData.newPlainText("swe-kitty terminal", payload))
        } catch (t: Throwable) {
            Log.w(TAG, "onCopyTextToClipboard failed", t)
        }
    }

    override fun onPasteTextFromClipboard(session: TerminalSession?) {
        try {
            val cm = appContext.getSystemService(Context.CLIPBOARD_SERVICE)
                as? ClipboardManager ?: return
            val clip = cm.primaryClip ?: return
            if (clip.itemCount == 0) return
            val text = clip.getItemAt(0).coerceToText(appContext)?.toString() ?: return
            if (text.isEmpty()) return
            // Forward bytes to the broker. Termux normally calls
            // `session.write(text)` here which would route the input
            // into the local /system/bin/sleep PTY — pointless. Send
            // the bytes directly to the broker instead, so the
            // remote agent receives them.
            onInput(text.toByteArray(Charsets.UTF_8))
        } catch (t: Throwable) {
            Log.w(TAG, "onPasteTextFromClipboard failed", t)
        }
    }

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

/**
 * Pure-data Stage 3 selection rectangle. Termux's `TerminalView`
 * owns the live selection UI (drag handles + floating action mode),
 * so this type is *not* wired into the live mount today — the same
 * rectangle shape lives inside `TextSelectionCursorController` in
 * Termux. We keep it here so:
 *  - the unit test ([TerminalSelectionRangeTest]) can lock the
 *    text-extraction contract that mirrors the iOS
 *    `TerminalSelectionRange.selectedText(from:)` helper, and
 *  - a future Stage 3.1 pass that draws its own selection (e.g.
 *    for the Compose accessory bar's "Send selection to chat"
 *    button) can reuse this row/col + extraction logic without
 *    re-inventing it.
 *
 * The range is **inclusive on both ends** — `start` and `end` both
 * point at cells whose graphemes belong to the selection. A
 * single-cell selection has `start == end`. [normalized] reorders the
 * anchors so the upper-left is `start` (drag-backwards-friendly).
 */
internal data class TerminalSelectionAnchor(val row: Int, val col: Int)

internal data class TerminalSelectionRange(
    val start: TerminalSelectionAnchor,
    val end: TerminalSelectionAnchor,
) {
    /**
     * Reordered (start, end) so that `start` is strictly the
     * upper-left anchor in reading order. Pure function so any caller
     * that paints the highlight + the text extractor agree on the
     * rectangle.
     */
    fun normalized(): TerminalSelectionRange {
        val s = start
        val e = end
        return if (s.row < e.row || (s.row == e.row && s.col <= e.col)) {
            this
        } else {
            TerminalSelectionRange(start = e, end = s)
        }
    }

    /**
     * Walk a (rows × cols) grid between the normalized anchors and
     * return the substring. Empty / whitespace cells render as a
     * single space, mirroring the iOS [TerminalSelectionRange]
     * helper.
     *
     * `cells` is laid out outer-row, inner-cell — same shape the iOS
     * `TerminalSnapshotShim.cells` uses. Each inner element is a
     * grapheme string (typically one character, possibly empty for
     * unwritten cells).
     */
    fun selectedText(cells: List<List<String>>): String {
        if (cells.isEmpty()) return ""
        val rows = cells.size
        val cols = cells.firstOrNull()?.size ?: 0
        if (cols == 0) return ""

        val n = normalized()
        val r0 = n.start.row.coerceIn(0, rows - 1)
        val r1 = n.end.row.coerceIn(0, rows - 1)
        val c0 = n.start.col.coerceIn(0, cols - 1)
        val c1 = n.end.col.coerceIn(0, cols - 1)

        if (r0 == r1) {
            return cellsToString(cells[r0], c0, c1)
        }
        val sb = StringBuilder()
        // First row: c0..lastCol.
        sb.append(cellsToString(cells[r0], c0, cols - 1))
        sb.append('\n')
        // Middle rows: full width.
        if (r1 - r0 > 1) {
            for (r in (r0 + 1) until r1) {
                sb.append(cellsToString(cells[r], 0, cols - 1))
                sb.append('\n')
            }
        }
        // Last row: 0..c1.
        sb.append(cellsToString(cells[r1], 0, c1))
        return sb.toString()
    }

    private fun cellsToString(row: List<String>, start: Int, end: Int): String {
        if (row.isEmpty()) return ""
        val s = start.coerceIn(0, row.size - 1)
        val e = end.coerceIn(0, row.size - 1)
        if (s > e) return ""
        val sb = StringBuilder()
        for (i in s..e) {
            val cell = row[i]
            sb.append(if (cell.isEmpty()) " " else cell)
        }
        return sb.toString()
    }
}
