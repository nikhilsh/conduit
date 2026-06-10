package sh.nikhil.conduit

import android.Manifest
import android.content.pm.PackageManager
import android.os.Build
import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.result.contract.ActivityResultContracts
import androidx.activity.viewModels
import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.darkColorScheme
import androidx.compose.material3.lightColorScheme
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.core.content.ContextCompat
import androidx.lifecycle.lifecycleScope
import kotlinx.coroutines.launch
import sh.nikhil.conduit.push.ConduitUnifiedPushReceiver
import sh.nikhil.conduit.push.PushStore
import sh.nikhil.conduit.ui.AppRoot
import sh.nikhil.conduit.ui.LocalNeonTheme
import sh.nikhil.conduit.ui.LocalUseDarkTheme
import sh.nikhil.conduit.ui.NeonTheme

class MainActivity : ComponentActivity() {
    private val store: SessionStore by viewModels()
    private val appearance: AppearanceStore by viewModels()
    private val pushStore: PushStore by viewModels()

    /**
     * Android 13+ POST_NOTIFICATIONS runtime permission launcher.
     * Requested at the push-registration moment (not app launch).
     */
    private val notificationPermissionLauncher =
        registerForActivityResult(ActivityResultContracts.RequestPermission()) { granted ->
            Telemetry.breadcrumb(
                "push", "POST_NOTIFICATIONS result",
                mapOf("granted" to granted.toString()),
            )
            if (granted) {
                // Permission granted — proceed with registration.
                val ep = store.endpoint.value
                if (ep.isComplete) {
                    pushStore.register(applicationContext, ep)
                }
            }
        }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        Telemetry.configure(applicationContext)
        store.hydrate(applicationContext)
        appearance.hydrate(applicationContext)
        pushStore.hydrate(applicationContext)

        // Mirror the active broker endpoint into plain SharedPrefs so the
        // UnifiedPush BroadcastReceiver can POST without EncryptedSharedPrefs.
        // Persists the initial endpoint, then re-persists whenever it changes
        // (box switch, new pairing).
        pushStore.persistBrokerEndpoint(store.endpoint.value)
        androidx.lifecycle.lifecycleScope.launch {
            store.endpoint.collect { ep ->
                pushStore.persistBrokerEndpoint(ep)
            }
        }

        handlePairingIntent(intent)
        handlePushIntent(intent)
        setContent {
            val themeMode by appearance.themeMode.collectAsState()
            val darkSystem = isSystemInDarkTheme()
            val useDark = when (themeMode) {
                AppearanceStore.ThemeMode.System -> darkSystem
                AppearanceStore.ThemeMode.Light -> false
                AppearanceStore.ThemeMode.Dark -> true
            }
            val neonPalette by appearance.neonPalette.collectAsState()
            val neonGlow by appearance.neonGlow.collectAsState()
            val chatFont by appearance.fontFamily.collectAsState()
            val neonTheme = NeonTheme.resolve(
                palette = sh.nikhil.conduit.ui.NeonPalette.fromId(neonPalette.id),
                dark = useDark,
                glow = neonGlow,
                chatFont = chatFont,
            )
            CompositionLocalProvider(
                LocalAppearanceStore provides appearance,
                LocalUseDarkTheme provides useDark,
                LocalNeonTheme provides neonTheme,
            ) {
                MaterialTheme(colorScheme = if (useDark) darkColorScheme() else lightColorScheme()) {
                    AppRoot(
                        store = store,
                        pushStore = pushStore,
                        onFirstSessionForPush = { requestPushRegistration() },
                    )
                }
            }
        }
    }

    override fun onNewIntent(intent: android.content.Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        handlePairingIntent(intent)
        handlePushIntent(intent)
    }

    private fun handlePairingIntent(intent: android.content.Intent?) {
        val data = intent?.data ?: return
        if (data.scheme?.lowercase() != "conduit") return
        // OAuth callbacks share the `conduit` scheme — route them first.
        if (store.handleOAuthCallback(data)) return
        store.applyDeepLink(data.toString())
    }

    /**
     * Handle a tap on a push notification: read the session_id extra and
     * navigate to that session via SessionStore.select.
     *
     * The session may not be in the live list yet (app cold-started by the
     * notification tap) — [SessionStore.attachLiveSession] handles that.
     */
    fun handlePushIntent(intent: android.content.Intent?) {
        val sessionId = intent?.getStringExtra(ConduitUnifiedPushReceiver.EXTRA_SESSION_ID)
            ?: return
        Telemetry.breadcrumb("push", "notification tap", mapOf("sessionId" to sessionId))
        // Route to the session. If it's already in the live list, select() navigates
        // immediately. If not (cold launch or session not yet listed), try to select
        // and let the existing reconnect logic surface it.
        val sessions = store.sessions.value
        if (sessions.any { it.id == sessionId }) {
            store.select(sessionId)
        } else {
            // Session not yet listed (cold launch, or broker hasn't reported it yet).
            // Select by ID — if the harness later lists the session it will become
            // visible with the correct selected state.
            store.select(sessionId)
        }
    }

    /**
     * Request POST_NOTIFICATIONS permission if needed (Android 13+), then
     * register for push. Called from the Settings row and after the first
     * session is created.
     */
    fun requestPushRegistration() {
        val ep = store.endpoint.value
        if (!ep.isComplete) return

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            val permission = Manifest.permission.POST_NOTIFICATIONS
            when {
                ContextCompat.checkSelfPermission(this, permission) ==
                    PackageManager.PERMISSION_GRANTED -> {
                    // Already granted — register directly.
                    Telemetry.breadcrumb("push", "POST_NOTIFICATIONS already granted")
                    pushStore.register(applicationContext, ep)
                }
                else -> {
                    // Request the permission; the launcher callback calls register.
                    Telemetry.breadcrumb("push", "requesting POST_NOTIFICATIONS")
                    notificationPermissionLauncher.launch(permission)
                }
            }
        } else {
            // Pre-Android-13: no runtime permission needed.
            pushStore.register(applicationContext, ep)
        }
    }
}
