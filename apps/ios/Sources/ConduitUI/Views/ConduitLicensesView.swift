import SwiftUI

// MARK: - ConduitLicensesView
//
// Static third-party attribution screen pushed from ConduitSettingsView →
// About → Licenses. Mirror of `apps/android/.../LicensesScreen.kt`. Both
// platforms render the same content, so changes ship in pairs.
//
// The data lives inline below in `licenseGroups` + `trademarkAttributions`
// so attributes can't drift away from the source-of-truth build files
// (`apps/ios/project.yml`, `apps/ios/GhosttyVT/Package.swift`,
// `apps/android/app/build.gradle.kts`, `core/Cargo.toml`,
// `broker/go.mod`). When a dependency lands or leaves, edit this file
// alongside the build file.

private struct LicenseEntry: Identifiable, Hashable {
    let name: String
    let license: String
    let holder: String
    let url: URL
    var id: String { name }
}

private struct LicenseGroup: Identifiable {
    let title: String
    let entries: [LicenseEntry]
    var id: String { title }
}

private struct TrademarkAttribution: Identifiable {
    let name: String
    let text: String
    var id: String { name }
}

extension ConduitUI {

    struct LicensesView: View {
        @Environment(\.dismiss) private var dismiss
        @Environment(\.colorScheme) private var colorScheme
        @Environment(\.neonTheme) private var neon

        var body: some View {
            ZStack {
                ConduitUI.Palette.surface.color.ignoresSafeArea()

                ScrollView {
                    VStack(alignment: .leading, spacing: 22) {
                        Text(
                            "Conduit ships the open-source libraries listed below. " +
                            "Each is used under its respective license; tap a row " +
                            "for the upstream source."
                        )
                        .font(.footnote)
                        .foregroundStyle(ConduitUI.Palette.textMuted.color)

                        ForEach(licenseGroups) { group in
                            section(title: group.title) {
                                VStack(spacing: 8) {
                                    ForEach(group.entries) { entry in
                                        licenseRow(entry)
                                    }
                                }
                            }
                        }

                        section(title: "Trademark attribution") {
                            VStack(spacing: 8) {
                                ForEach(trademarkAttributions) { tm in
                                    trademarkRow(tm)
                                }
                            }
                        }

                        Text(
                            "If you maintain a library listed here and notice " +
                            "an incorrect attribution, please open an issue at " +
                            "github.com/nikhilsh/conduit."
                        )
                        .font(.caption)
                        .foregroundStyle(ConduitUI.Palette.textMuted.color)
                        .padding(.top, 4)
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 18)
                }
                .scrollIndicators(.hidden)
            }
            .navigationTitle("Licenses")
            .navigationBarTitleDisplayMode(.inline)
            .neonAccentTint()
            .appearanceColorScheme()
        }

        @ViewBuilder
        private func section<C: View>(
            title: String,
            @ViewBuilder content: () -> C
        ) -> some View {
            VStack(alignment: .leading, spacing: 10) {
                Text(title.uppercased())
                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                    .foregroundStyle(ConduitUI.Palette.textSecondary.color)
                    .padding(.horizontal, 4)
                content()
            }
        }

        @ViewBuilder
        private func licenseRow(_ entry: LicenseEntry) -> some View {
            Link(destination: entry.url) {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(entry.name)
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(ConduitUI.Palette.textPrimary.color)
                            .lineLimit(2)
                        Spacer(minLength: 6)
                        licenseBadge(entry.license)
                    }
                    Text(entry.holder)
                        .font(.system(size: 12))
                        .foregroundStyle(ConduitUI.Palette.textMuted.color)
                        .lineLimit(1)
                    Text(entry.url.absoluteString)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(ConduitUI.Palette.textMuted.color.opacity(0.8))
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .conduitGlassRoundedRect(cornerRadius: 14)
            }
            .buttonStyle(.plain)
        }

        private func licenseBadge(_ label: String) -> some View {
            Text(label)
                .font(.system(size: 10, weight: .bold, design: .monospaced))
                .neonAccentForeground()
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(
                    neon.accent.opacity(0.18),
                    in: Capsule()
                )
        }

        @ViewBuilder
        private func trademarkRow(_ tm: TrademarkAttribution) -> some View {
            VStack(alignment: .leading, spacing: 6) {
                Text(tm.name)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(ConduitUI.Palette.textPrimary.color)
                Text(tm.text)
                    .font(.footnote)
                    .foregroundStyle(ConduitUI.Palette.textMuted.color)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .conduitGlassRoundedRect(cornerRadius: 14)
        }
    }
}

// MARK: - Static data

/// Open-source dependencies shipped in the user-facing binaries.
/// Bundles a publisher's family (e.g. all `androidx.compose.*`) into a
/// single line so the list reads cleanly. Full per-artifact breakdown
/// is recoverable from the build files themselves.
private let licenseGroups: [LicenseGroup] = [
    LicenseGroup(
        title: "iOS app",
        entries: [
            LicenseEntry(
                name: "libghostty (vendored)",
                license: "MIT",
                holder: "Mitchell Hashimoto + Ghostty contributors",
                url: URL(string: "https://github.com/ghostty-org/ghostty")!
            ),
            LicenseEntry(
                name: "libghostty-spm packaging",
                license: "MIT",
                holder: "Lakr233",
                url: URL(string: "https://github.com/Lakr233/libghostty-spm")!
            ),
            LicenseEntry(
                name: "HighlightSwift",
                license: "MIT",
                holder: "Stefan Bauer",
                url: URL(string: "https://github.com/appstefan/highlightswift")!
            ),
            LicenseEntry(
                name: "Sentry Cocoa",
                license: "MIT",
                holder: "Sentry",
                url: URL(string: "https://github.com/getsentry/sentry-cocoa")!
            ),
        ]
    ),
    LicenseGroup(
        title: "Android app",
        entries: [
            LicenseEntry(
                name: "Jetpack Compose + AndroidX",
                license: "Apache-2.0",
                holder: "Google",
                url: URL(string: "https://developer.android.com/jetpack/androidx")!
            ),
            LicenseEntry(
                name: "OkHttp",
                license: "Apache-2.0",
                holder: "Square, Inc.",
                url: URL(string: "https://github.com/square/okhttp")!
            ),
            LicenseEntry(
                name: "JNA (Java Native Access)",
                license: "Apache-2.0",
                holder: "JNA contributors",
                url: URL(string: "https://github.com/java-native-access/jna")!
            ),
            LicenseEntry(
                name: "Sentry Android",
                license: "MIT",
                holder: "Sentry",
                url: URL(string: "https://github.com/getsentry/sentry-java")!
            ),
            LicenseEntry(
                name: "ZXing Android Embedded",
                license: "Apache-2.0",
                holder: "JourneyApps + ZXing authors",
                url: URL(string: "https://github.com/journeyapps/zxing-android-embedded")!
            ),
            LicenseEntry(
                name: "Termux Terminal Emulator + View",
                license: "GPL-3.0",
                holder: "Termux contributors",
                url: URL(string: "https://github.com/termux/termux-app")!
            ),
        ]
    ),
    LicenseGroup(
        title: "Rust core (both apps)",
        entries: [
            LicenseEntry(
                name: "UniFFI",
                license: "MPL-2.0",
                holder: "Mozilla",
                url: URL(string: "https://github.com/mozilla/uniffi-rs")!
            ),
            LicenseEntry(
                name: "tokio + tokio-tungstenite",
                license: "MIT",
                holder: "Tokio contributors / Snapview",
                url: URL(string: "https://github.com/tokio-rs/tokio")!
            ),
            LicenseEntry(
                name: "serde + serde_json",
                license: "MIT or Apache-2.0",
                holder: "David Tolnay et al.",
                url: URL(string: "https://github.com/serde-rs/serde")!
            ),
            LicenseEntry(
                name: "russh + russh-keys",
                license: "Apache-2.0",
                holder: "Pierre-Étienne Meunier + russh contributors",
                url: URL(string: "https://github.com/Eugeny/russh")!
            ),
            LicenseEntry(
                name: "futures-rs, url, parking_lot, once_cell, uuid, flate2, thiserror, async-trait",
                license: "MIT or Apache-2.0",
                holder: "Rust ecosystem contributors",
                url: URL(string: "https://crates.io")!
            ),
        ]
    ),
    LicenseGroup(
        title: "Broker (Go, server-side)",
        entries: [
            LicenseEntry(
                name: "Gorilla WebSocket",
                license: "BSD-2-Clause",
                holder: "The Gorilla Authors",
                url: URL(string: "https://github.com/gorilla/websocket")!
            ),
            LicenseEntry(
                name: "creack/pty",
                license: "MIT",
                holder: "Krzysztof Kowalczyk + contributors",
                url: URL(string: "https://github.com/creack/pty")!
            ),
            LicenseEntry(
                name: "BurntSushi/toml",
                license: "MIT",
                holder: "Andrew Gallant",
                url: URL(string: "https://github.com/BurntSushi/toml")!
            ),
            LicenseEntry(
                name: "grandcat/zeroconf (mDNS)",
                license: "MIT",
                holder: "Yiming Liu + contributors",
                url: URL(string: "https://github.com/grandcat/zeroconf")!
            ),
            LicenseEntry(
                name: "miekg/dns",
                license: "BSD-3-Clause",
                holder: "Miek Gieben + contributors",
                url: URL(string: "https://github.com/miekg/dns")!
            ),
            LicenseEntry(
                name: "mdp/qrterminal + rsc/qr",
                license: "MIT / BSD-3-Clause",
                holder: "Matthew D. Proud / Russ Cox",
                url: URL(string: "https://github.com/mdp/qrterminal")!
            ),
            LicenseEntry(
                name: "golang.org/x/crypto, net, sys, term",
                license: "BSD-3-Clause",
                holder: "Google + Go contributors",
                url: URL(string: "https://pkg.go.dev/golang.org/x")!
            ),
            LicenseEntry(
                name: "cenkalti/backoff",
                license: "MIT",
                holder: "Cenk Altı",
                url: URL(string: "https://github.com/cenkalti/backoff")!
            ),
        ]
    ),
]

private let trademarkAttributions: [TrademarkAttribution] = [
    TrademarkAttribution(
        name: "Claude / Anthropic",
        text: """
            Claude and the Claude wordmark are trademarks of Anthropic, PBC. \
            Conduit is an independent client and is not affiliated with, \
            endorsed by, or sponsored by Anthropic.
            """
    ),
    TrademarkAttribution(
        name: "OpenAI / Codex / ChatGPT",
        text: """
            OpenAI, Codex, ChatGPT, and their respective wordmarks are \
            trademarks of OpenAI OpCo, LLC. Conduit is an independent client \
            and is not affiliated with, endorsed by, or sponsored by OpenAI.
            """
    ),
    TrademarkAttribution(
        name: "Ghostty",
        text: """
            Ghostty is a trademark of Mitchell Hashimoto. The libghostty \
            xcframework is used under the MIT license; Conduit is not the \
            Ghostty terminal emulator and is not affiliated with the Ghostty \
            project.
            """
    ),
]
