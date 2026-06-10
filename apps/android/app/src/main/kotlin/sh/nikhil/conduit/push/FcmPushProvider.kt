package sh.nikhil.conduit.push

/**
 * FCM push provider stub — no-op until google-services.json + the
 * Google Services gradle plugin are added to the project.
 *
 * Returning `isAvailable = false` means [PushProviders.forContext] skips
 * this provider entirely and falls back to [UnifiedPushProvider]. The entire
 * Firebase dependency is intentionally absent from build.gradle.kts so that
 * the build doesn't fail when google-services.json is missing.
 *
 * See [PushProvider] docs for the step-by-step enablement guide.
 */
class FcmPushProvider : PushProvider {
    override val name: String = "FCM (unavailable — google-services.json not configured)"
    override val isAvailable: Boolean = false
    override val platform: String = "fcm"

    override fun requestToken(onResult: (String?) -> Unit) {
        // Stub: FCM is not configured. Return null so callers know.
        onResult(null)
    }

    override fun unregisterToken() {
        // No-op until FCM is wired in.
    }
}
