package sh.nikhil.swekitty.ui

import android.content.Intent
import android.net.Uri
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.TopAppBar
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.window.Dialog
import androidx.compose.ui.window.DialogProperties

/**
 * Static attribution data for the Licenses screen. Update by editing
 * [LICENSE_GROUPS] below. Mirror of `apps/ios/.../LicensesScreen.swift`
 * — both platforms render the same content, so changes ship in pairs.
 */
internal data class LicenseEntry(
    val name: String,
    val license: String,
    val holder: String,
    val url: String,
)

internal data class LicenseGroup(
    val title: String,
    val entries: List<LicenseEntry>,
)

/**
 * The full attribution list, grouped by where each library ships.
 * Source: `apps/android/app/build.gradle.kts`, `apps/ios/project.yml`,
 * `core/Cargo.toml`, `broker/go.mod`. Bundles a publisher's family of
 * libraries (e.g. all `androidx.compose.*`) into one line so the list
 * reads cleanly — the full per-artifact breakdown is recoverable from
 * the build files themselves.
 */
internal val LICENSE_GROUPS: List<LicenseGroup> = listOf(
    LicenseGroup(
        title = "Android app",
        entries = listOf(
            LicenseEntry(
                name = "Jetpack Compose + AndroidX",
                license = "Apache-2.0",
                holder = "Google",
                url = "https://developer.android.com/jetpack/androidx",
            ),
            LicenseEntry(
                name = "OkHttp",
                license = "Apache-2.0",
                holder = "Square, Inc.",
                url = "https://github.com/square/okhttp",
            ),
            LicenseEntry(
                name = "JNA (Java Native Access)",
                license = "Apache-2.0",
                holder = "JNA contributors",
                url = "https://github.com/java-native-access/jna",
            ),
            LicenseEntry(
                name = "Sentry Android",
                license = "MIT",
                holder = "Sentry",
                url = "https://github.com/getsentry/sentry-java",
            ),
            LicenseEntry(
                name = "ZXing Android Embedded",
                license = "Apache-2.0",
                holder = "JourneyApps + ZXing authors",
                url = "https://github.com/journeyapps/zxing-android-embedded",
            ),
            LicenseEntry(
                name = "Termux Terminal Emulator + View",
                license = "GPL-3.0",
                holder = "Termux contributors",
                url = "https://github.com/termux/termux-app",
            ),
        ),
    ),
    LicenseGroup(
        title = "iOS app",
        entries = listOf(
            LicenseEntry(
                name = "libghostty (vendored)",
                license = "MIT",
                holder = "Mitchell Hashimoto + Ghostty contributors",
                url = "https://github.com/ghostty-org/ghostty",
            ),
            LicenseEntry(
                name = "libghostty-spm packaging",
                license = "MIT",
                holder = "Lakr233",
                url = "https://github.com/Lakr233/libghostty-spm",
            ),
            LicenseEntry(
                name = "HighlightSwift",
                license = "MIT",
                holder = "Stefan Bauer",
                url = "https://github.com/appstefan/highlightswift",
            ),
            LicenseEntry(
                name = "Sentry Cocoa",
                license = "MIT",
                holder = "Sentry",
                url = "https://github.com/getsentry/sentry-cocoa",
            ),
        ),
    ),
    LicenseGroup(
        title = "Rust core (both apps)",
        entries = listOf(
            LicenseEntry(
                name = "UniFFI",
                license = "MPL-2.0",
                holder = "Mozilla",
                url = "https://github.com/mozilla/uniffi-rs",
            ),
            LicenseEntry(
                name = "tokio + tokio-tungstenite",
                license = "MIT",
                holder = "Tokio contributors / Snapview",
                url = "https://github.com/tokio-rs/tokio",
            ),
            LicenseEntry(
                name = "serde + serde_json",
                license = "MIT or Apache-2.0",
                holder = "David Tolnay et al.",
                url = "https://github.com/serde-rs/serde",
            ),
            LicenseEntry(
                name = "russh + russh-keys",
                license = "Apache-2.0",
                holder = "Pierre-Étienne Meunier + russh contributors",
                url = "https://github.com/Eugeny/russh",
            ),
            LicenseEntry(
                name = "futures-rs, url, parking_lot, once_cell, uuid, flate2, thiserror, async-trait",
                license = "MIT or Apache-2.0",
                holder = "Rust ecosystem contributors",
                url = "https://crates.io",
            ),
        ),
    ),
    LicenseGroup(
        title = "Broker (Go, server-side)",
        entries = listOf(
            LicenseEntry(
                name = "Gorilla WebSocket",
                license = "BSD-2-Clause",
                holder = "The Gorilla Authors",
                url = "https://github.com/gorilla/websocket",
            ),
            LicenseEntry(
                name = "creack/pty",
                license = "MIT",
                holder = "Krzysztof Kowalczyk + contributors",
                url = "https://github.com/creack/pty",
            ),
            LicenseEntry(
                name = "BurntSushi/toml",
                license = "MIT",
                holder = "Andrew Gallant",
                url = "https://github.com/BurntSushi/toml",
            ),
            LicenseEntry(
                name = "grandcat/zeroconf (mDNS)",
                license = "MIT",
                holder = "Yiming Liu + contributors",
                url = "https://github.com/grandcat/zeroconf",
            ),
            LicenseEntry(
                name = "miekg/dns",
                license = "BSD-3-Clause",
                holder = "Miek Gieben + contributors",
                url = "https://github.com/miekg/dns",
            ),
            LicenseEntry(
                name = "mdp/qrterminal + rsc/qr",
                license = "MIT / BSD-3-Clause",
                holder = "Matthew D. Proud / Russ Cox",
                url = "https://github.com/mdp/qrterminal",
            ),
            LicenseEntry(
                name = "golang.org/x/crypto, net, sys, term",
                license = "BSD-3-Clause",
                holder = "Google + Go contributors",
                url = "https://pkg.go.dev/golang.org/x",
            ),
            LicenseEntry(
                name = "cenkalti/backoff",
                license = "MIT",
                holder = "Cenk Altı",
                url = "https://github.com/cenkalti/backoff",
            ),
        ),
    ),
)

/**
 * Trademark / model-provider attribution. Separate from the
 * open-source [LICENSE_GROUPS] above — these are NOT libraries we
 * link against; they're trademarked names whose owners deserve
 * acknowledgement when their model powers an agent session.
 */
internal data class TrademarkAttribution(
    val name: String,
    val text: String,
)

internal val TRADEMARK_ATTRIBUTIONS: List<TrademarkAttribution> = listOf(
    TrademarkAttribution(
        name = "Claude / Anthropic",
        text = "Claude and the Claude wordmark are trademarks of Anthropic, PBC. " +
            "SweKitty is an independent client and is not affiliated with, endorsed " +
            "by, or sponsored by Anthropic.",
    ),
    TrademarkAttribution(
        name = "OpenAI / Codex / ChatGPT",
        text = "OpenAI, Codex, ChatGPT, and their respective wordmarks are trademarks " +
            "of OpenAI OpCo, LLC. SweKitty is an independent client and is not " +
            "affiliated with, endorsed by, or sponsored by OpenAI.",
    ),
    TrademarkAttribution(
        name = "Ghostty",
        text = "Ghostty is a trademark of Mitchell Hashimoto. The libghostty " +
            "xcframework is used under the MIT license; SweKitty is not the " +
            "Ghostty terminal emulator and is not affiliated with the Ghostty project.",
    ),
)

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun LicensesScreen(onDismiss: () -> Unit) {
    val ctx = LocalContext.current

    // Settings is a ModalBottomSheet, which lives in its own window above
    // the activity content. A plain Scaffold here would draw in the
    // content layer — i.e. *behind* the still-open Settings sheet. Hosting
    // it in a full-screen Dialog gives it a top-most window of its own, so
    // it presents over Settings; Back (via onDismissRequest) returns to
    // Settings, mirroring iOS's NavigationLink push.
    Dialog(
        onDismissRequest = onDismiss,
        properties = DialogProperties(usePlatformDefaultWidth = false),
    ) {
        Scaffold(
            topBar = {
                TopAppBar(
                    title = { Text("Licenses", fontWeight = FontWeight.SemiBold) },
                    navigationIcon = {
                        IconButton(onClick = onDismiss) {
                            Icon(
                                Icons.AutoMirrored.Filled.ArrowBack,
                                contentDescription = "Back",
                            )
                        }
                    },
                )
            },
        ) { padding ->
            LazyColumn(
                modifier = Modifier.fillMaxSize().padding(padding),
                contentPadding = PaddingValues(horizontal = 16.dp, vertical = 12.dp),
                verticalArrangement = Arrangement.spacedBy(20.dp),
            ) {
                item("intro") {
                    Text(
                        "SweKitty ships the open-source libraries listed below. " +
                            "Each is used under its respective license; tap a row for " +
                            "the upstream source.",
                        style = MaterialTheme.typography.bodyMedium,
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                    )
                }

                LICENSE_GROUPS.forEach { group ->
                    item("hdr-${group.title}") {
                        LicensesSectionHeader(group.title)
                    }
                    items(group.entries, key = { "${group.title}-${it.name}" }) { entry ->
                        LicenseRow(entry) {
                            ctx.startActivity(Intent(Intent.ACTION_VIEW, Uri.parse(entry.url)))
                        }
                    }
                }

                item("trademarks-hdr") {
                    LicensesSectionHeader("Trademark attribution")
                }
                items(TRADEMARK_ATTRIBUTIONS, key = { "tm-${it.name}" }) { tm ->
                    TrademarkRow(tm)
                }

                item("footer") {
                    Spacer(Modifier.height(12.dp))
                    Text(
                        "If you maintain a library listed here and notice an " +
                            "incorrect attribution, please open an issue at " +
                            "github.com/nikhilsh/swe-kitty.",
                        style = MaterialTheme.typography.bodySmall,
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                    )
                }
            }
        }
    }
}

@Composable
private fun LicensesSectionHeader(title: String) {
    Text(
        title.uppercase(),
        style = MaterialTheme.typography.labelSmall,
        fontFamily = FontFamily.Monospace,
        fontWeight = FontWeight.Bold,
        color = MaterialTheme.colorScheme.onSurfaceVariant,
        modifier = Modifier.padding(start = 4.dp, bottom = 4.dp),
    )
}

@Composable
private fun LicenseRow(entry: LicenseEntry, onOpen: () -> Unit) {
    Surface(
        shape = RoundedCornerShape(14.dp),
        color = MaterialTheme.colorScheme.surfaceVariant.copy(alpha = 0.32f),
        modifier = Modifier.fillMaxWidth().clickable(onClick = onOpen),
    ) {
        Column(
            modifier = Modifier.padding(horizontal = 14.dp, vertical = 12.dp),
            verticalArrangement = Arrangement.spacedBy(4.dp),
        ) {
            Row(
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(8.dp),
            ) {
                Text(
                    entry.name,
                    style = MaterialTheme.typography.titleSmall,
                    fontWeight = FontWeight.SemiBold,
                    modifier = Modifier.weight(1f),
                    maxLines = 2,
                    overflow = TextOverflow.Ellipsis,
                )
                LicenseBadge(entry.license)
            }
            Text(
                entry.holder,
                style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
            )
            Text(
                entry.url,
                style = MaterialTheme.typography.labelSmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant.copy(alpha = 0.7f),
                fontFamily = FontFamily.Monospace,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
            )
        }
    }
}

@Composable
private fun LicenseBadge(label: String) {
    Surface(
        shape = RoundedCornerShape(50),
        color = SweKittyTheme.accentStrong().copy(alpha = 0.18f),
    ) {
        Text(
            label,
            modifier = Modifier.padding(horizontal = 8.dp, vertical = 2.dp),
            style = MaterialTheme.typography.labelSmall,
            fontWeight = FontWeight.SemiBold,
            color = SweKittyTheme.accentStrong(),
            fontFamily = FontFamily.Monospace,
            maxLines = 1,
        )
    }
}

@Composable
private fun TrademarkRow(tm: TrademarkAttribution) {
    Surface(
        shape = RoundedCornerShape(14.dp),
        color = MaterialTheme.colorScheme.surfaceVariant.copy(alpha = 0.32f),
        modifier = Modifier.fillMaxWidth(),
    ) {
        Column(
            modifier = Modifier.padding(horizontal = 14.dp, vertical = 12.dp),
            verticalArrangement = Arrangement.spacedBy(6.dp),
        ) {
            Text(
                tm.name,
                style = MaterialTheme.typography.titleSmall,
                fontWeight = FontWeight.SemiBold,
            )
            Text(
                tm.text,
                style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
            )
        }
    }
}

