import SwiftUI

// MARK: - ConduitForkSheet
//
// Fork-onto-a-different-model chooser. Forking starts a brand-new session
// (own id, history, worktree) seeded with a hand-off line pointing at the
// original — reasoning effort can't be changed mid-session (CLI limitation),
// so changing it requires a fork, not a live switch.
//
// The sheet lets the user pick a reasoning-effort level and (optionally) a
// model. Both default to the original session's current effort / no model
// override, so an un-touched fork behaves exactly like the old one-tap fork.
// The chosen values ride through SessionStore.forkSession → core
// create_session → the broker's WS connect query params, where they become
// the agent's --effort / --model CLI flags.

extension ConduitUI {
    struct ForkSheet: View {
        @Environment(SessionStore.self) private var store
        @Environment(\.dismiss) private var dismiss

        let session: ProjectSession
        /// The original session's current effort, used as the default
        /// selection. nil → fall back to "medium".
        let currentEffort: String?

        @State private var effort: String
        /// The selected model option. `ForkOptions.inheritModel` (empty
        /// string) means "no override — keep the current model", which is
        /// what an untouched fork sends.
        @State private var model: String

        init(session: ProjectSession, currentEffort: String?) {
            self.session = session
            self.currentEffort = currentEffort
            let options = ForkOptions.efforts(forAssistant: session.assistant)
            let initial = currentEffort.flatMap { options.contains($0) ? $0 : nil }
                ?? (options.contains("medium") ? "medium" : (options.first ?? "medium"))
            self._effort = State(initialValue: initial)
            self._model = State(initialValue: ForkOptions.inheritModel)
        }

        private var effortOptions: [String] {
            ForkOptions.efforts(forAssistant: session.assistant)
        }

        private var modelOptions: [String] {
            ForkOptions.models(forAssistant: session.assistant)
        }

        var body: some View {
            NavigationStack {
                ZStack {
                    ConduitUI.Palette.surface.color.ignoresSafeArea()
                    VStack(alignment: .leading, spacing: 14) {
                        Text("Fork starts a fresh session from \(store.displayName(for: session)). Reasoning effort can't change mid-session, so pick the new effort (and optionally a model) here.")
                            .font(.caption2)
                            .foregroundStyle(ConduitUI.Palette.textMuted.color)

                        sectionLabel("Reasoning effort")
                        Picker("Reasoning effort", selection: $effort) {
                            ForEach(effortOptions, id: \.self) { level in
                                Text(level.capitalized).tag(level)
                            }
                        }
                        .pickerStyle(.segmented)

                        sectionLabel("Model (optional)")
                        Menu {
                            Picker("Model", selection: $model) {
                                ForEach(modelOptions, id: \.self) { option in
                                    Text(ForkOptions.modelLabel(option)).tag(option)
                                }
                            }
                        } label: {
                            HStack {
                                Text(ForkOptions.modelLabel(model))
                                    .foregroundStyle(ConduitUI.Palette.textPrimary.color)
                                Spacer()
                                Image(systemName: "chevron.up.chevron.down")
                                    .font(.system(size: 12, weight: .semibold))
                                    .foregroundStyle(ConduitUI.Palette.textMuted.color)
                            }
                            .padding(.horizontal, 12)
                            .padding(.vertical, 12)
                            .conduitGlassRoundedRect(cornerRadius: 14)
                        }
                        .neonAccentTint()
                        Text("Default keeps the current model. Pick an alias to fork onto a different one.")
                            .font(.caption2)
                            .foregroundStyle(ConduitUI.Palette.textMuted.color)

                        Spacer()
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 18)
                }
                .navigationTitle("Fork session")
                .navigationBarTitleDisplayMode(.inline)
                .neonAccentTint()
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") { dismiss() }
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Fork") {
                            store.forkSession(
                                sessionID: session.id,
                                reasoningEffort: effort,
                                model: model.isEmpty ? nil : model
                            )
                            dismiss()
                        }
                    }
                }
            }
            .appearanceColorScheme()
        }

        private func sectionLabel(_ text: String) -> some View {
            Text(text.uppercased())
                .font(.system(size: 11, weight: .semibold))
                .tracking(0.8)
                .foregroundStyle(ConduitUI.Palette.textMuted.color)
        }
    }

    /// Per-assistant fork option lists. Mirrors the broker's validated
    /// effort levels (broker/internal/session/override.go) so the UI never
    /// offers a level the agent would silently drop.
    enum ForkOptions {
        /// Sentinel for the "keep the current model" option. Sent to
        /// forkSession as nil so the spawn carries no --model override —
        /// byte-for-byte identical to the pre-picker untouched fork.
        static let inheritModel = ""

        static func efforts(forAssistant assistant: String) -> [String] {
            switch assistant {
            case "claude":
                return ["low", "medium", "high", "xhigh", "max"]
            case "codex":
                return ["low", "medium", "high"]
            default:
                return ["low", "medium", "high"]
            }
        }

        /// Curated per-assistant model aliases for the fork picker. The
        /// broker passes the chosen value straight to the agent's --model
        /// flag (broker/internal/session/override.go), so these are the
        /// CLI's accepted aliases. The leading inheritModel entry maps to
        /// "no override". Aliases (opus/sonnet/haiku, gpt-5-codex) avoid
        /// pinning a dated full model name in the client.
        static func models(forAssistant assistant: String) -> [String] {
            switch assistant {
            case "claude":
                return [inheritModel, "opus", "sonnet", "haiku"]
            case "codex":
                return [inheritModel, "gpt-5-codex"]
            default:
                return [inheritModel]
            }
        }

        /// Display label for a model option. The sentinel renders as the
        /// "inherit" affordance; everything else shows its alias verbatim.
        static func modelLabel(_ option: String) -> String {
            option.isEmpty ? "Default (inherit)" : option
        }
    }
}
