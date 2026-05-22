package sh.nikhil.swekitty

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
import sh.nikhil.swekitty.ui.AppRoot

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
            CompositionLocalProvider(LocalAppearanceStore provides appearance) {
                val themeMode by appearance.themeMode.collectAsState()
                val darkSystem = isSystemInDarkTheme()
                val useDark = when (themeMode) {
                    AppearanceStore.ThemeMode.System -> darkSystem
                    AppearanceStore.ThemeMode.Light -> false
                    AppearanceStore.ThemeMode.Dark -> true
                }
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
        if (data.scheme?.lowercase() != "swekitty") return
        // OAuth callbacks (`swekitty://oauth/<provider>/callback?code=...`)
        // share the `swekitty` scheme with pairing URLs. Route them to
        // the OAuth handler first; only fall through to pairing if
        // there's no in-flight OAuth request waiting for this redirect.
        if (store.handleOAuthCallback(data)) return
        store.applyDeepLink(data.toString())
    }
}
