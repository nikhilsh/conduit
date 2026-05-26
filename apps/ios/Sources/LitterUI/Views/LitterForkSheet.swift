import SwiftUI

// MARK: - LitterForkSheet
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

extension LitterUI {
    struct ForkSheet: View {
        @Environment(SessionStore.self) private var store
        @Environment(\.dismiss) private var dismiss

        let session: ProjectSession
        /// The original session's current effort, used as the default
        /// selection. nil → fall back to "medium".
        let currentEffort: String?

        @State private var effort: String
        @State private var modelDraft: String

        init(session: ProjectSession, currentEffort: String?) {
            self.session = session
            self.currentEffort = currentEffort
            let options = ForkOptions.efforts(forAssistant: session.assistant)
            let initial = currentEffort.flatMap { options.contains($0) ? $0 : nil }
                ?? (options.contains("medium") ? "medium" : (options.first ?? "medium"))
            self._effort = State(initialValue: initial)
            self._modelDraft = State(initialValue: "")
        }

        private var effortOptions: [String] {
            ForkOptions.efforts(forAssistant: session.assistant)
        }

        var body: some View {
            NavigationStack {
                ZStack {
                    LitterUI.Palette.surface.color.ignoresSafeArea()
                    VStack(alignment: .leading, spacing: 14) {
                        Text("Fork starts a fresh session from \(store.displayName(for: session)). Reasoning effort can't change mid-session, so pick the new effort (and optionally a model) here.")
                            .font(.caption2)
                            .foregroundStyle(LitterUI.Palette.textMuted.color)

                        sectionLabel("Reasoning effort")
                        Picker("Reasoning effort", selection: $effort) {
                            ForEach(effortOptions, id: \.self) { level in
                                Text(level.capitalized).tag(level)
                            }
                        }
                        .pickerStyle(.segmented)

                        sectionLabel("Model (optional)")
                        TextField(ForkOptions.modelPlaceholder(forAssistant: session.assistant), text: $modelDraft)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled(true)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 10)
                            .litterGlassRoundedRect(cornerRadius: 14)
                        Text("Leave blank to keep the current model. Use an alias (e.g. \(ForkOptions.modelPlaceholder(forAssistant: session.assistant))) or a full model name.")
                            .font(.caption2)
                            .foregroundStyle(LitterUI.Palette.textMuted.color)

                        Spacer()
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 18)
                }
                .navigationTitle("Fork session")
                .navigationBarTitleDisplayMode(.inline)
                .tint(LitterUI.Palette.brand.color)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") { dismiss() }
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Fork") {
                            let model = modelDraft.trimmingCharacters(in: .whitespacesAndNewlines)
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
        }

        private func sectionLabel(_ text: String) -> some View {
            Text(text.uppercased())
                .font(.system(size: 11, weight: .semibold))
                .tracking(0.8)
                .foregroundStyle(LitterUI.Palette.textMuted.color)
        }
    }

    /// Per-assistant fork option lists. Mirrors the broker's validated
    /// effort levels (broker/internal/session/override.go) so the UI never
    /// offers a level the agent would silently drop.
    enum ForkOptions {
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

        static func modelPlaceholder(forAssistant assistant: String) -> String {
            switch assistant {
            case "claude":
                return "opus"
            case "codex":
                return "gpt-5-codex"
            default:
                return "model"
            }
        }
    }
}
