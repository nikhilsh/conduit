package sh.nikhil.conduit.widget

/**
 * Android mirror of iOS `TurnLiveActivityController`
 * (`apps/ios/Sources/Models/TurnLiveActivityController.swift`).
 *
 * Owns a [TurnActivityModel] per session, applies the bridge's
 * [TurnActivityIntent]s, and routes the resulting [TurnActivityEffect]s
 * to a [TurnActivitySink]. The actual surface — an ongoing notification
 * and the Glance home-screen widget — is a [TurnActivitySink]
 * implementation wired in a follow-up PR; here we keep at most one
 * active model per session and translate Start/Update/End verbs.
 *
 * Idempotent: re-emitting the same conversation item only runs the idle
 * tick, never a duplicate Start/Update — mirrors the iOS controller so a
 * stream refresh doesn't flicker the surface.
 */

/** Surface that renders the active-turn effects (notification / Glance). */
interface TurnActivitySink {
    fun onStart(attributes: TurnActivityAttributesData, state: TurnActivityContentState)
    fun onUpdate(sessionID: String, state: TurnActivityContentState)
    fun onEnd(sessionID: String, state: TurnActivityContentState)

    /** No-op sink — the controller stays functional before a real surface
     *  is attached, matching how iOS swallows ActivityKit unavailability. */
    object Noop : TurnActivitySink {
        override fun onStart(attributes: TurnActivityAttributesData, state: TurnActivityContentState) {}
        override fun onUpdate(sessionID: String, state: TurnActivityContentState) {}
        override fun onEnd(sessionID: String, state: TurnActivityContentState) {}
    }
}

class TurnActivityController(
    private val sink: TurnActivitySink = TurnActivitySink.Noop,
    private val idleTimeoutMillis: Long = TurnActivityModel.DEFAULT_IDLE_TIMEOUT_MILLIS,
) {
    /** Per-session state machines. Most installs see one entry (the active
     *  session); the map keeps concurrent sessions from trampling. */
    private val models = mutableMapOf<String, TurnActivityModel>()

    /** Last-seen item id per session so an idempotent re-emit doesn't
     *  produce a duplicate Start/Update. */
    private val lastSeenItemID = mutableMapOf<String, String>()

    /** Apply an ordered batch of bridge intents — the normal entry point
     *  driven by [TurnActivityBridgeCore.ingest]. */
    fun applyIntents(intents: List<TurnActivityIntent>, nowMillis: Long = System.currentTimeMillis()) {
        for (intent in intents) {
            when (intent) {
                is TurnActivityIntent.Observe -> observe(intent.item, intent.sessionID, intent.agentName)
                is TurnActivityIntent.End -> sessionExited(intent.sessionID, nowMillis)
                TurnActivityIntent.Tick -> tickAll(nowMillis)
            }
        }
    }

    /** Hand a single classified item to the per-session state machine and
     *  let it decide Start / Update / End. */
    fun observe(item: TurnActivityItem, sessionID: String, agentName: String) {
        val model = models.getOrPut(sessionID) { TurnActivityModel(idleTimeoutMillis) }
        if (lastSeenItemID[sessionID] == item.id) {
            // Idempotent re-emit — tick so an idle close still fires.
            applyEffect(model.tick(item.timestampMillis), sessionID)
            return
        }
        lastSeenItemID[sessionID] = item.id
        applyEffect(model.apply(item, sessionID, agentName), sessionID)
    }

    /** External "session was reaped" signal — ends without waiting for the
     *  idle timeout. No-op for a session we never started. */
    fun sessionExited(sessionID: String, nowMillis: Long = System.currentTimeMillis()) {
        val model = models[sessionID] ?: return
        applyEffect(model.sessionExited(nowMillis), sessionID)
    }

    /** Periodic tick — closes activities idle past their timeout. */
    fun tickAll(nowMillis: Long = System.currentTimeMillis()) {
        for ((sessionID, model) in models) {
            applyEffect(model.tick(nowMillis), sessionID)
        }
    }

    private fun applyEffect(effect: TurnActivityEffect, sessionID: String) {
        when (effect) {
            is TurnActivityEffect.Noop -> {}
            is TurnActivityEffect.Start -> sink.onStart(effect.attributes, effect.state)
            is TurnActivityEffect.Update -> sink.onUpdate(sessionID, effect.state)
            is TurnActivityEffect.End -> sink.onEnd(sessionID, effect.state)
        }
    }
}
