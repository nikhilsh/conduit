package sh.nikhil.conduit.push

import android.content.Context
import android.content.SharedPreferences
import androidx.lifecycle.ViewModel
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import org.json.JSONObject
import sh.nikhil.conduit.Endpoint
import sh.nikhil.conduit.Telemetry
import java.net.HttpURLConnection
import java.net.URL

/**
 * Possible states the push-notification registration can be in.
 * Drives the Settings row honest-state rule.
 */
sealed class PushRegistrationState {
    /** No endpoint has been registered with the broker yet. */
    data object NotRegistered : PushRegistrationState()
    /** Registration is in progress. */
    data object Registering : PushRegistrationState()
    /** Endpoint registered via UnifiedPush distributor (ntfy). */
    data class RegisteredUnifiedPush(val distributorLabel: String) : PushRegistrationState()
    /** FCM token registered (stub path, pending google-services.json). */
    data object RegisteredFcm : PushRegistrationState()
    /** No distributor is installed — show the ntfy install hint. */
    data object NoDistributor : PushRegistrationState()
    /** The active broker's capabilities don't include `features.push`. */
    data object BrokerDoesNotSupportPush : PushRegistrationState()
    /** A test notification send is in flight. */
    data object TestSending : PushRegistrationState()
    /** Something went wrong during registration or test send. */
    data class Error(val message: String) : PushRegistrationState()
}

/**
 * Manages push-notification registration for the active broker box.
 *
 * Two access paths:
 *  1. As a [ViewModel] (via `viewModels()` in MainActivity) — full lifecycle
 *     management, coroutines scoped to the ViewModel.
 *  2. As a process-scoped singleton via [PushStore.applicationStore] —
 *     accessed from [ConduitUnifiedPushReceiver] when the app may not be
 *     in the foreground. Uses a SupervisorJob-backed scope.
 *
 * Responsibilities:
 *   - Store the registered endpoint URL in SharedPreferences.
 *   - POST /api/push/register when a new endpoint arrives from UnifiedPush.
 *   - POST /api/push/unregister on explicit removal.
 *   - POST /api/push/test to trigger a test notification.
 *   - Mirror broker URL+token into a plain prefs file so the
 *     BroadcastReceiver can POST without going through the full
 *     EncryptedSharedPreferences path.
 *   - Expose [registrationState] for the Settings row.
 */
class PushStore : ViewModel() {

    companion object {
        private const val PREFS_NAME = "conduit-push"
        private const val BROKER_PREFS_NAME = "conduit-push-broker"
        private const val KEY_ENDPOINT_URL = "up_endpoint_url"
        private const val KEY_PLATFORM = "up_platform"
        private const val KEY_BROKER_URL = "broker_url"
        private const val KEY_BROKER_TOKEN = "broker_token"

        /**
         * Process-scoped singleton for use from [ConduitUnifiedPushReceiver].
         * Lazily initialised on first access; survives as long as the process runs.
         */
        @Volatile
        private var sInstance: PushStore? = null

        fun applicationStore(appCtx: Context): PushStore {
            return sInstance ?: synchronized(this) {
                sInstance ?: PushStore().also { store ->
                    store.hydrate(appCtx)
                    sInstance = store
                }
            }
        }
    }

    private val _registrationState =
        MutableStateFlow<PushRegistrationState>(PushRegistrationState.NotRegistered)
    val registrationState: StateFlow<PushRegistrationState> = _registrationState.asStateFlow()

    /** The currently-registered endpoint URL (null = not registered). */
    private val _registeredEndpointUrl = MutableStateFlow<String?>(null)
    val registeredEndpointUrl: StateFlow<String?> = _registeredEndpointUrl.asStateFlow()

    private var prefs: SharedPreferences? = null
    private var brokerPrefs: SharedPreferences? = null

    /**
     * Application-scoped coroutine scope, used for all async work in
     * PushStore. Unlike [viewModelScope] (which is cancelled when the
     * ViewModel is cleared), this scope lives as long as the process.
     *
     * When the Activity-ViewModel instance is used, this means network calls
     * aren't cancelled when the Activity rotates (acceptable: push registration
     * is short-lived and idempotent). When the BroadcastReceiver accesses the
     * process-singleton instance, the scope just continues running.
     */
    private val appScope = CoroutineScope(SupervisorJob() + Dispatchers.Main)

    /**
     * Load persisted registration state. Call once from MainActivity.
     */
    fun hydrate(ctx: Context) {
        if (prefs != null) return
        prefs = ctx.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
        brokerPrefs = ctx.getSharedPreferences(BROKER_PREFS_NAME, Context.MODE_PRIVATE)
        val savedUrl = prefs?.getString(KEY_ENDPOINT_URL, null)
        val savedPlatform = prefs?.getString(KEY_PLATFORM, "unifiedpush")
        if (savedUrl != null) {
            _registeredEndpointUrl.value = savedUrl
            _registrationState.value = when (savedPlatform) {
                "fcm" -> PushRegistrationState.RegisteredFcm
                else -> PushRegistrationState.RegisteredUnifiedPush("ntfy")
            }
            Telemetry.breadcrumb(
                "push", "hydrated with existing registration",
                mapOf("platform" to (savedPlatform ?: "unknown")),
            )
        }
    }

    /**
     * Mirror the active broker endpoint to plain SharedPreferences so
     * [ConduitUnifiedPushReceiver] can find it without EncryptedSharedPrefs.
     * Call whenever the active endpoint changes (from SessionStore).
     */
    fun persistBrokerEndpoint(endpoint: Endpoint) {
        brokerPrefs?.edit()
            ?.putString(KEY_BROKER_URL, endpoint.url)
            ?.putString(KEY_BROKER_TOKEN, endpoint.token)
            ?.apply()
    }

    /**
     * Read the mirrored broker endpoint. Used by [ConduitUnifiedPushReceiver]
     * when the app may not be fully initialised.
     */
    fun readBrokerEndpoint(ctx: Context): Endpoint? {
        val p = ctx.getSharedPreferences(BROKER_PREFS_NAME, Context.MODE_PRIVATE)
        val url = p.getString(KEY_BROKER_URL, null) ?: return null
        val token = p.getString(KEY_BROKER_TOKEN, null) ?: return null
        return Endpoint(url = url, token = token)
    }

    /**
     * Called from [ConduitFcmService.onNewToken] when FCM rotates the token.
     * Re-registers the new token with ALL paired broker endpoints so every
     * box stays current. [settingsState] reflects the active endpoint's result.
     * No-op when no broker endpoints are known yet (deferred until first session).
     */
    fun onNewFcmToken(token: String, endpoint: Endpoint?, allEndpoints: List<Endpoint> = emptyList()) {
        Telemetry.breadcrumb(
            "push", "FCM onNewToken",
            mapOf("hasActiveBroker" to (endpoint != null).toString()),
        )
        prefs?.edit()
            ?.putString(KEY_ENDPOINT_URL, token)
            ?.putString(KEY_PLATFORM, "fcm")
            ?.apply()
        _registeredEndpointUrl.value = token

        val ep = endpoint ?: return
        registerWithAllEndpoints(
            activeEndpoint = ep,
            allEndpoints = allEndpoints,
            token = token,
            platform = "fcm",
        )
    }

    /**
     * Called from [ConduitUnifiedPushReceiver.onNewEndpoint].
     * Fans out registration to ALL paired endpoints concurrently.
     */
    fun updateEndpoint(endpointUrl: String, endpoint: Endpoint?, allEndpoints: List<Endpoint> = emptyList()) {
        Telemetry.breadcrumb(
            "push", "UP onNewEndpoint",
            mapOf("hasActiveBroker" to (endpoint != null).toString()),
        )
        _registeredEndpointUrl.value = endpointUrl
        prefs?.edit()
            ?.putString(KEY_ENDPOINT_URL, endpointUrl)
            ?.putString(KEY_PLATFORM, "unifiedpush")
            ?.apply()

        val ep = endpoint ?: return
        registerWithAllEndpoints(
            activeEndpoint = ep,
            allEndpoints = allEndpoints,
            token = endpointUrl,
            platform = "unifiedpush",
        )
    }

    /**
     * Re-register the stored push token with ALL paired endpoints when the
     * active endpoint changes. No-op when no token has been registered yet.
     * Called from MainActivity when [SessionStore.endpoint] changes.
     */
    fun onEndpointChanged(activeEndpoint: Endpoint, allEndpoints: List<Endpoint>) {
        val token = _registeredEndpointUrl.value ?: return
        if (!activeEndpoint.isComplete) return
        val platform = prefs?.getString(KEY_PLATFORM, "unifiedpush") ?: "unifiedpush"
        Telemetry.breadcrumb(
            "push", "endpoint changed — re-registering with all boxes",
            mapOf("host" to activeEndpoint.displayHost, "count" to allEndpoints.size.toString()),
        )
        registerWithAllEndpoints(
            activeEndpoint = activeEndpoint,
            allEndpoints = allEndpoints,
            token = token,
            platform = platform,
        )
    }

    /**
     * Fan out registration to ALL endpoints concurrently under a SupervisorJob
     * so one failure does not cancel others. The [_registrationState] is updated
     * based on the ACTIVE endpoint's result; other boxes are breadcrumbed only.
     */
    fun registerWithAllEndpoints(
        activeEndpoint: Endpoint,
        allEndpoints: List<Endpoint>,
        token: String,
        platform: String,
    ) {
        // Deduplicate endpoints; active endpoint is always first.
        val seen = mutableSetOf<String>()
        val endpoints = buildList<Endpoint> {
            if (activeEndpoint.isComplete && seen.add(activeEndpoint.url)) add(activeEndpoint)
            for (ep in allEndpoints) {
                if (ep.isComplete && seen.add(ep.url)) add(ep)
            }
        }

        Telemetry.breadcrumb(
            "push", "fan-out register: N boxes",
            mapOf("count" to endpoints.size.toString()),
        )

        for (ep in endpoints) {
            val isActive = (ep.url == activeEndpoint.url)
            appScope.launch {
                val ok = postRegisterToEndpoint(ep, token, platform)
                Telemetry.breadcrumb(
                    "push", "fan-out register result",
                    mapOf("host" to ep.displayHost, "success" to ok.toString()),
                )
                if (!ok && isActive) {
                    Telemetry.capture(
                        error = IllegalStateException("fan-out register failed"),
                        message = "Android push fan-out register failed",
                        tags = mapOf("surface" to "android", "phase" to "push_register_fanout"),
                        extras = mapOf("host" to ep.displayHost, "isActive" to "true"),
                    )
                }
                // Active endpoint result drives the visible registration state.
                if (isActive) {
                    withContext(Dispatchers.Main) {
                        if (ok) {
                            _registeredEndpointUrl.value = token
                            _registrationState.value = when (platform) {
                                "fcm" -> PushRegistrationState.RegisteredFcm
                                else -> PushRegistrationState.RegisteredUnifiedPush("ntfy")
                            }
                        } else {
                            _registrationState.value = PushRegistrationState.Error(
                                "Failed to register push with broker"
                            )
                        }
                    }
                }
            }
        }
    }

    /**
     * Best-effort unregister from a single endpoint. Called when a server
     * is removed from savedServers. Does NOT clear local prefs (the active
     * registration is preserved for the remaining boxes).
     */
    fun unregisterFromServer(endpoint: Endpoint) {
        if (!endpoint.isComplete) return
        Telemetry.breadcrumb(
            "push", "fan-out unregister: box removed",
            mapOf("host" to endpoint.displayHost),
        )
        appScope.launch(Dispatchers.IO) { unregisterWithBroker(endpoint) }
    }

    /**
     * Trigger registration for this device and POST the token to the broker.
     * Called after first session or from the Settings action.
     */
    fun register(ctx: Context, endpoint: Endpoint) {
        val provider = PushProviders.forContext(ctx)
        if (provider == null) {
            if (!PushProviders.hasUnifiedPushDistributor(ctx)) {
                Telemetry.breadcrumb("push", "register: no distributor installed")
                _registrationState.value = PushRegistrationState.NoDistributor
            } else {
                Telemetry.breadcrumb("push", "register: no provider available")
                _registrationState.value = PushRegistrationState.Error("No push provider available")
            }
            return
        }
        _registrationState.value = PushRegistrationState.Registering
        Telemetry.breadcrumb("push", "register start", mapOf("provider" to provider.name))

        provider.requestToken { token ->
            if (token == null && provider.platform == "unifiedpush") {
                // Async: endpoint arrives via onNewEndpoint callback.
                Telemetry.breadcrumb("push", "UP registration initiated (waiting for endpoint)")
                return@requestToken
            }
            if (token == null) {
                _registrationState.value =
                    PushRegistrationState.Error("${provider.name}: token unavailable")
                return@requestToken
            }
            appScope.launch {
                registerWithBroker(endpoint, token, provider.platform)
            }
        }
    }

    /**
     * POST /api/push/register to one endpoint. Returns true on HTTP 2xx,
     * false on any failure. Pure HTTP — no state side effects.
     * Must be called from within Dispatchers.IO context.
     */
    private suspend fun postRegisterToEndpoint(
        endpoint: Endpoint,
        token: String,
        platform: String,
    ): Boolean = withContext(Dispatchers.IO) {
        Telemetry.breadcrumb(
            "push", "register POST start",
            mapOf("platform" to platform, "host" to endpoint.displayHost),
        )
        val result = postJsonOrNull(
            endpoint = endpoint,
            path = "/api/push/register",
            body = JSONObject().apply {
                put("platform", platform)
                put("token", token)
            }.toString(),
        )
        val ok = result != null
        if (ok) {
            Telemetry.breadcrumb("push", "register POST success",
                mapOf("platform" to platform, "host" to endpoint.displayHost))
        } else {
            Telemetry.breadcrumb("push", "register POST failed",
                mapOf("platform" to platform, "host" to endpoint.displayHost))
        }
        ok
    }

    /**
     * Register with a single broker endpoint and update [_registrationState].
     * Used by [register] (single active endpoint path, e.g. first session).
     */
    private suspend fun registerWithBroker(
        endpoint: Endpoint,
        token: String,
        platform: String,
    ) = withContext(Dispatchers.IO) {
        val ok = postRegisterToEndpoint(endpoint, token, platform)
        withContext(Dispatchers.Main) {
            if (ok) {
                _registeredEndpointUrl.value = token
                _registrationState.value = when (platform) {
                    "fcm" -> PushRegistrationState.RegisteredFcm
                    else -> PushRegistrationState.RegisteredUnifiedPush("ntfy")
                }
            } else {
                val msg = "Failed to register push with broker"
                Telemetry.capture(
                    error = IllegalStateException(msg),
                    message = "Android push register failed",
                    tags = mapOf("surface" to "android", "phase" to "push_register", "platform" to platform),
                    extras = mapOf("host" to endpoint.displayHost),
                )
                _registrationState.value = PushRegistrationState.Error(msg)
            }
        }
    }

    /** Unregister from broker and clear local state. */
    fun unregister(ctx: Context, endpoint: Endpoint) {
        Telemetry.breadcrumb("push", "unregister start", mapOf("host" to endpoint.displayHost))
        PushProviders.forContext(ctx)?.unregisterToken()
        _registeredEndpointUrl.value = null
        prefs?.edit()?.remove(KEY_ENDPOINT_URL)?.remove(KEY_PLATFORM)?.apply()
        appScope.launch { unregisterWithBroker(endpoint) }
    }

    /** Called from [ConduitUnifiedPushReceiver.onUnregistered]. */
    fun onDistributorUnregistered(endpoint: Endpoint?) {
        Telemetry.breadcrumb("push", "UP onUnregistered")
        _registeredEndpointUrl.value = null
        prefs?.edit()?.remove(KEY_ENDPOINT_URL)?.remove(KEY_PLATFORM)?.apply()
        _registrationState.value = PushRegistrationState.NotRegistered
        val ep = endpoint ?: return
        appScope.launch { unregisterWithBroker(ep) }
    }

    private suspend fun unregisterWithBroker(endpoint: Endpoint) = withContext(Dispatchers.IO) {
        Telemetry.breadcrumb("push", "unregister POST start", mapOf("host" to endpoint.displayHost))
        postJsonOrNull(endpoint, "/api/push/unregister", "{}")
        withContext(Dispatchers.Main) {
            _registrationState.value = PushRegistrationState.NotRegistered
        }
    }

    /**
     * POST /api/push/test — sends a test notification.
     */
    fun sendTestNotification(endpoint: Endpoint) {
        Telemetry.breadcrumb("push", "test notification start", mapOf("host" to endpoint.displayHost))
        val prevState = _registrationState.value
        _registrationState.value = PushRegistrationState.TestSending
        appScope.launch(Dispatchers.IO) {
            val result = postJsonOrNull(
                endpoint = endpoint,
                path = "/api/push/test",
                body = JSONObject().apply {
                    put("title", "Conduit")
                    put("body", "Test notification from ${endpoint.displayHost}")
                }.toString(),
            )
            withContext(Dispatchers.Main) {
                if (result != null) {
                    Telemetry.breadcrumb("push", "test notification sent")
                } else {
                    Telemetry.capture(
                        error = IllegalStateException("Push test failed"),
                        message = "Android push test failed",
                        tags = mapOf("surface" to "android", "phase" to "push_test"),
                        extras = mapOf("host" to endpoint.displayHost),
                    )
                }
                _registrationState.value = prevState
            }
        }
    }

    /**
     * POST a JSON body to an authed broker path.
     * Returns the response body string on HTTP 2xx, null on any failure.
     * Mirrors [sh.nikhil.conduit.SessionStore.getJsonOrNull] (GET variant).
     * Must be called on Dispatchers.IO.
     */
    fun postJsonOrNull(endpoint: Endpoint, path: String, body: String): String? {
        val base = endpoint.httpBaseUrl ?: return null
        return runCatching {
            val conn = (URL("$base$path").openConnection() as HttpURLConnection).apply {
                requestMethod = "POST"
                doOutput = true
                setRequestProperty("Authorization", "Bearer ${endpoint.token}")
                setRequestProperty("Content-Type", "application/json")
                connectTimeout = 7_000
                readTimeout = 10_000
            }
            try {
                conn.outputStream.use { it.write(body.toByteArray(Charsets.UTF_8)) }
                if (conn.responseCode !in 200..299) return@runCatching null
                conn.inputStream.bufferedReader().use { it.readText() }
            } finally {
                conn.disconnect()
            }
        }.getOrNull()
    }
}
