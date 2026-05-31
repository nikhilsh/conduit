package sh.nikhil.conduit

import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.viewModels
import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.darkColorScheme
import androidx.compose.material3.lightColorScheme
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import sh.nikhil.conduit.ui.AppRoot
import sh.nikhil.conduit.ui.LocalNeonTheme
import sh.nikhil.conduit.ui.LocalUseDarkTheme
import sh.nikhil.conduit.ui.NeonTheme

class MainActivity : ComponentActivity() {
    private val store: SessionStore by viewModels()
    private val appearance: AppearanceStore by viewModels()

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        Telemetry.configure(applicationContext)
        store.hydrate(applicationContext)
        appearance.hydrate(applicationContext)
        handlePairingIntent(intent)
        setContent {
            val themeMode by appearance.themeMode.collectAsState()
            val darkSystem = isSystemInDarkTheme()
            val useDark = when (themeMode) {
                AppearanceStore.ThemeMode.System -> darkSystem
                AppearanceStore.ThemeMode.Light -> false
                AppearanceStore.ThemeMode.Dark -> true
            }
            // Resolve the Neon Terminal theme from the user's palette +
            // glow choices and the same effective-dark flag MaterialTheme
            // uses. Provided alongside the appearance store so any
            // composable below can read LocalNeonTheme.current.
            val neonPalette by appearance.neonPalette.collectAsState()
            val neonGlow by appearance.neonGlow.collectAsState()
            val neonTheme = NeonTheme.resolve(
                palette = sh.nikhil.conduit.ui.NeonPalette.fromId(neonPalette.id),
                dark = useDark,
                glow = neonGlow,
            )
            // Provide the effective dark flag alongside the appearance
            // store so ConduitPalette palette resolution stays in sync
            // with MaterialTheme — both flip on every effective change,
            // including sheets / dialogs / any window inheriting this
            // composition (the prior code read `isSystemInDarkTheme()`
            // inside palette lookups, which ignored the user override).
            CompositionLocalProvider(
                LocalAppearanceStore provides appearance,
                LocalUseDarkTheme provides useDark,
                LocalNeonTheme provides neonTheme,
            ) {
                MaterialTheme(colorScheme = if (useDark) darkColorScheme() else lightColorScheme()) {
                    // GlassAppBackground inside AppRoot supplies the canvas; no
                    // opaque Surface wrap so the glass layering reads correctly.
                    AppRoot(store)
                }
            }
        }
    }

    override fun onNewIntent(intent: android.content.Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        handlePairingIntent(intent)
    }

    private fun handlePairingIntent(intent: android.content.Intent?) {
        val data = intent?.data ?: return
        if (data.scheme?.lowercase() != "conduit") return
        // OAuth callbacks (`conduit://oauth/<provider>/callback?code=...`)
        // share the `conduit` scheme with pairing URLs. Route them to
        // the OAuth handler first; only fall through to pairing if
        // there's no in-flight OAuth request waiting for this redirect.
        if (store.handleOAuthCallback(data)) return
        store.applyDeepLink(data.toString())
    }
}
