import SwiftUI

// MARK: - ConduitDebugMenuView
//
// Staff Debug menu (handoff §2, `02-ab`). Surfaces the chat-shell-v2
// experiment internals — the stable id, computed bucket hash, assigned
// bucket, the resolved arm after overrides, and whether the one-per-install
// exposure has logged — and exposes every feature flag so a dogfooder can
// force an arm, flip the kill-switch, or toggle the new-session flags
// without a rebuild. Reached from Settings › Labs › Debug menu.

extension ConduitUI {
    struct DebugMenuView: View {
        @Environment(FeatureFlags.self) private var flags
        @Environment(\.neonTheme) private var neon

        var body: some View {
            @Bindable var flags = flags
            ZStack {
                GlassAppBackground()
                ScrollView {
                    VStack(spacing: 18) {
                        experimentSection
                        forceSection(flags: $flags)
                        newSessionSection(flags: $flags)
                        transportSection(flags: $flags)
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 18)
                }
                .scrollIndicators(.hidden)
            }
            .navigationTitle("Debug")
            .navigationBarTitleDisplayMode(.inline)
            .tint(neon.accent)
        }

        // MARK: chat-shell-v2 state (read-only)

        private var experimentSection: some View {
            sectionCard(title: "chat-shell-v2") {
                VStack(spacing: 0) {
                    infoRow("Stable id", flags.chatStableID, mono: true)
                    divider
                    infoRow("Bucket hash", String(flags.chatBucketHash), mono: true)
                    divider
                    infoRow("Assigned bucket", flags.chatAssignedArm.label)
                    divider
                    infoRow("Resolved arm", flags.resolvedChatArm.label)
                    divider
                    infoRow("Kill-switch", flags.chatExperimentKilled ? "ON → forces A" : "off")
                }
            }
        }

        // MARK: Force / kill controls

        private func forceSection(flags: Bindable<FeatureFlags>) -> some View {
            sectionCard(title: "Force") {
                VStack(alignment: .leading, spacing: 0) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Arm override")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(neon.text)
                        Picker("Arm override", selection: flags.chatStylePreference) {
                            ForEach(FeatureFlags.ChatStylePreference.allCases) { pref in
                                Text(pref.label).tag(pref)
                            }
                        }
                        .pickerStyle(.segmented)
                        .tint(neon.accent)
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 12)
                    divider
                    ConduitUI.toggleRow(
                        icon: "exclamationmark.octagon",
                        title: "Kill experiment",
                        subtitle: "Force arm A globally (guardrail)",
                        isOn: flags.chatExperimentKilled,
                        iconTint: neon.red
                    )
                }
            }
        }

        // MARK: New-session flags

        private func newSessionSection(flags: Bindable<FeatureFlags>) -> some View {
            sectionCard(title: "New session (§3)") {
                VStack(spacing: 0) {
                    ConduitUI.toggleRow(
                        icon: "rectangle.on.rectangle",
                        title: "Agent cards",
                        subtitle: "Side-by-side agent cards that tint the sheet",
                        isOn: flags.newSessionAgentCards
                    )
                    divider
                    ConduitUI.toggleRow(
                        icon: "dial.medium",
                        title: "Effort dial",
                        subtitle: "Fast / Balanced / Deep 3-stop dial",
                        isOn: flags.newSessionEffortDial
                    )
                    divider
                    ConduitUI.toggleRow(
                        icon: "terminal",
                        title: "Launch line",
                        subtitle: "Live `will run …` preview above Start",
                        isOn: flags.newSessionLaunchLine
                    )
                }
            }
        }

        // MARK: Transport

        private func transportSection(flags: Bindable<FeatureFlags>) -> some View {
            sectionCard(title: "Transport") {
                ConduitUI.toggleRow(
                    icon: "lock.shield",
                    title: "SSH tunnel",
                    subtitle: "Route SSH-paired boxes through the held tunnel (token stays in the SSH channel). Off = legacy public path.",
                    isOn: flags.sshTunnelTransport
                )
            }
        }

        // MARK: Helpers

        private func infoRow(_ title: String, _ value: String, mono: Bool = false) -> some View {
            HStack(spacing: 10) {
                Text(title)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(neon.text)
                Spacer(minLength: 8)
                Text(value)
                    .font(mono ? neon.mono(12) : neon.sans(13).weight(.medium))
                    .foregroundStyle(neon.textDim)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
        }

        private var divider: some View {
            Divider().background(neon.border).padding(.leading, 14)
        }

        @ViewBuilder
        private func sectionCard<C: View>(title: String, @ViewBuilder content: () -> C) -> some View {
            VStack(alignment: .leading, spacing: 8) {
                Text(title)
                    .font(neon.mono(11.5).weight(.bold))
                    .foregroundStyle(neon.textFaint)
                    .tracking(1.6)
                    .textCase(.uppercase)
                    .padding(.horizontal, 4)
                content()
                    .neonCardSurface(neon, fill: neon.surface, cornerRadius: 14)
            }
        }
    }
}
