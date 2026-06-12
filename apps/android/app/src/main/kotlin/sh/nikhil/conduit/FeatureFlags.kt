package sh.nikhil.conduit

/**
 * Pure, framework-free feature-flag + experiment logic (Android mirror of
 * iOS `FeatureFlags`). The persisted STATE lives on [AppearanceStore] (its
 * `chat*` / `onboarding*` StateFlows); these enums + functions are the
 * testable decision logic that state feeds into.
 *
 * Conduit has **no accounts / sign-in** — trust is the device↔broker pairing
 * handshake. So the chat A/B buckets on a stable DEVICE id and onboarding
 * routing is gated purely on device-local pairing state.
 */
object FeatureFlags {

    /** chat-shell-v2 arms. a = "Breathe", b = "Signature" (spine lane). */
    enum class ChatArm(val id: String, val label: String) {
        A("a", "Breathe (A)"),
        B("b", "Signature (B)");

        companion object {
            fun fromId(id: String?): ChatArm = entries.firstOrNull { it.id == id } ?: A
        }
    }

    /** User/staff conversation-style override (Settings › Labs). Auto defers
     *  to the assigned bucket; A/B are a local override that never changes
     *  the logged bucket. */
    enum class ChatStylePreference(val id: String, val label: String) {
        Auto("auto", "Auto"),
        A("a", "A"),
        B("b", "B");

        companion object {
            fun fromId(id: String?): ChatStylePreference = entries.firstOrNull { it.id == id } ?: Auto
        }
    }

    /** Launch routing target (accounts-free, device-local gating). */
    enum class OnboardingRoute { None, Full }

    /**
     * Entry intent for the onboarding wizard (Fix 1).
     *
     *  - [firstRun]   : automatic gate on first launch; may resolve to Done
     *                   when already paired.
     *  - [replay]     : Settings "Replay walkthrough"; always starts at Welcome.
     *  - [addMachine] : Settings "Add a machine"; always starts at Install.
     *
     * Only [firstRun] may resolve to Done directly. The other two intents
     * always run the flow so the user sees actual wizard steps.
     */
    enum class OnboardingEntry { firstRun, replay, addMachine }

    /** Onboarding step indices — shared by the routing math and the wizard. */
    object Step {
        const val WELCOME = 0
        const val INSTALL = 1
        const val PAIR = 2
        const val DONE = 3
    }

    // ── Debug flags ─────────────────────────────────────────────────────

    /**
     * Show the "Agents" subagent-roster panel in the session Information
     * screen. Default OFF — the panel is incomplete until the broker
     * ships the `view:"agents"` view_event. Expose via the debug settings
     * toggle (Labs section). Mirror of iOS `FeatureFlags.showSubagentPanel`.
     */
    const val showSubagentPanel: Boolean = false

    // ── Chat A/B ────────────────────────────────────────────────────────

    /** FNV-1a 32-bit over UTF-8 — small, dependency-free, stable across
     *  launches (unlike `hashCode()` which is unspecified for strings only
     *  in spec, but we keep our own for cross-platform determinism). */
    fun fnv1a(s: String): Int {
        var hash = -0x7ee3623b // 0x811c9dc5 as signed Int
        for (b in s.toByteArray(Charsets.UTF_8)) {
            hash = hash xor (b.toInt() and 0xff)
            hash *= 0x01000193
        }
        return hash
    }

    /** 50/50 bucket from a stable device id: low bit of the FNV-1a hash. */
    fun bucket(id: String): ChatArm = if (fnv1a(id) and 1 == 0) ChatArm.A else ChatArm.B

    /**
     * The arm the chat shell should render: kill-switch → A; local A/B
     * override → that arm; Auto → the assigned bucket.
     */
    fun resolvedChatArm(
        preference: ChatStylePreference,
        killed: Boolean,
        assigned: ChatArm,
    ): ChatArm = when {
        killed -> ChatArm.A
        preference == ChatStylePreference.A -> ChatArm.A
        preference == ChatStylePreference.B -> ChatArm.B
        else -> assigned
    }

    // ── Onboarding routing (§5) ─────────────────────────────────────────

    /**
     * First-match launch routing — device-local only. No accounts:
     *   - `pairedBrokers == 0` → Full onboarding (Welcome shown only if
     *     !seenWelcome; else enter at Install — see [onboardingInitialStep]).
     *   - paired (reachable or not) → None (Home; offline banner handled
     *     elsewhere). Never re-onboard a device that holds a pairing key.
     */
    fun onboardingRoute(pairedBrokers: Int, brokerReachable: Boolean): OnboardingRoute =
        if (pairedBrokers == 0) OnboardingRoute.Full else OnboardingRoute.None

    /**
     * The step the wizard opens on, honouring resume + once-ever Welcome:
     * Full enters at Welcome only if unseen, else the furthest incomplete
     * step (min Install). None → Done.
     */
    fun onboardingInitialStep(route: OnboardingRoute, seenWelcome: Boolean, furthestStep: Int): Int =
        when (route) {
            OnboardingRoute.None -> Step.DONE
            OnboardingRoute.Full -> {
                val floor = if (seenWelcome) Step.INSTALL else Step.WELCOME
                maxOf(floor, minOf(furthestStep, Step.PAIR))
            }
        }

    /**
     * Resolve the initial step for the wizard given an explicit entry intent
     * (Fix 1). The intent takes priority over the firstRun routing math:
     *
     *  - [OnboardingEntry.replay]      → always Welcome (run the full flow).
     *  - [OnboardingEntry.addMachine]  → always Install (skip Welcome).
     *  - [OnboardingEntry.firstRun]    → delegate to [onboardingInitialStep]
     *                                    (may return Done when already paired).
     *
     * Only [firstRun] can produce Done; replay/addMachine never land there
     * on entry — Done is only reachable by *finishing* the flow.
     */
    fun resolveInitialStep(
        entry: OnboardingEntry,
        pairedBrokers: Int,
        brokerReachable: Boolean,
        seenWelcome: Boolean,
        furthestStep: Int,
    ): Int = when (entry) {
        OnboardingEntry.replay      -> Step.WELCOME
        OnboardingEntry.addMachine  -> Step.INSTALL
        OnboardingEntry.firstRun    -> {
            val route = onboardingRoute(pairedBrokers, brokerReachable)
            onboardingInitialStep(route, seenWelcome, furthestStep)
        }
    }
}
