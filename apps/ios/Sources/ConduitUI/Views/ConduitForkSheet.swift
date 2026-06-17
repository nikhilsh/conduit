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
        /// Selected agent mode. `ForkOptions.autoMode` (empty string) means
        /// the app's full-auto default — sent to forkSession as nil so the
        /// fork carries no permission override.
        @State private var permissionMode: String = ForkOptions.autoMode
        /// Claude-only "fast mode" toggle. Defaults OFF; only shown (and only
        /// sent to the fork) when the selected model advertises
        /// `supportsFastMode`. nil-when-unsupported keeps the fork's override
        /// absent so non-fast forks are byte-identical to before.
        @State private var fastMode: Bool = false

        init(session: ProjectSession, currentEffort: String?) {
            self.session = session
            self.currentEffort = currentEffort
            let options = ForkOptions.efforts(forAssistant: session.assistant)
            let initial = currentEffort.flatMap { options.contains($0) ? $0 : nil }
                ?? (options.contains("medium") ? "medium" : (options.first ?? "medium"))
            self._effort = State(initialValue: initial)
            self._model = State(initialValue: ForkOptions.inheritModel)
        }

        /// The assistant's live model catalog (broker-discovered); nil/empty
        /// falls back to the static ForkOptions lists.
        private var catalog: [AgentModel]? {
            store.modelCatalog[session.assistant]
        }

        /// Broker-served descriptor for this session's agent, if any.
        private var descriptor: AgentDescriptor? {
            store.agentDescriptors[session.assistant.lowercased()]
        }

        private var effortOptions: [String] {
            // When a descriptor is present and supports.effort is false the
            // agent has no effort control at all — return empty so the section
            // hides. Without a descriptor, fall through to catalog/static list
            // (today's behaviour preserved on old brokers).
            if let d = descriptor, !d.supports.effort { return [] }
            return ForkOptions.efforts(forAssistant: session.assistant, model: model, catalog: catalog)
        }

        private var modelOptions: [String] {
            ForkOptions.models(forAssistant: session.assistant, catalog: catalog)
        }

        var body: some View {
            NavigationStack {
                ZStack {
                    ConduitUI.Palette.surface.color.ignoresSafeArea()
                    VStack(alignment: .leading, spacing: 14) {
                        Text("Fork starts a fresh session from \(store.displayName(for: session)). Reasoning effort can't change mid-session, so pick the new effort (and optionally a model) here.")
                            .font(.caption2)
                            .foregroundStyle(ConduitUI.Palette.textMuted.color)

                        if !effortOptions.isEmpty {
                            sectionLabel("Reasoning effort")
                            Picker("Reasoning effort", selection: $effort) {
                                ForEach(effortOptions, id: \.self) { level in
                                    Text(ForkOptions.effortLabel(level)).tag(level)
                                }
                            }
                            .pickerStyle(.segmented)
                        }

                        sectionLabel("Model (optional)")
                        Menu {
                            Picker("Model", selection: $model) {
                                ForEach(modelOptions, id: \.self) { option in
                                    Text(ForkOptions.modelLabel(option, catalog: catalog)).tag(option)
                                }
                            }
                        } label: {
                            HStack {
                                Text(ForkOptions.modelLabel(model, catalog: catalog))
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
                        if ForkOptions.supportsFastMode(model, catalog: catalog) {
                            Toggle(isOn: $fastMode) {
                                HStack(spacing: 4) {
                                    Image(systemName: "bolt.fill")
                                        .font(.system(size: 11, weight: .bold))
                                    Text("Fast mode")
                                        .font(.system(size: 13, weight: .semibold))
                                }
                                .foregroundStyle(Color.yellow)
                            }
                            .tint(Color.yellow)
                        }
                        Text(ForkOptions.modelDetail(model, catalog: catalog)
                            ?? "Default keeps the current model. Pick an alias to fork onto a different one.")
                            .font(.caption2)
                            .foregroundStyle(ConduitUI.Palette.textMuted.color)

                        sectionLabel("Mode")
                        Picker("Mode", selection: $permissionMode) {
                            ForEach(ForkOptions.permissionModes, id: \.self) { mode in
                                Text(ForkOptions.permissionModeLabel(mode)).tag(mode)
                            }
                        }
                        .pickerStyle(.segmented)
                        Text("Plan = read-only; agent explores and proposes without editing.")
                            .font(.caption2)
                            .foregroundStyle(ConduitUI.Palette.textMuted.color)

                        Spacer()
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 18)
                    .frame(maxWidth: 560)
                    .frame(maxWidth: .infinity)
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
                                reasoningEffort: effort.isEmpty ? nil : effort,
                                model: model.isEmpty ? nil : model,
                                permissionMode: permissionMode.isEmpty ? nil : permissionMode,
                                // Only send the toggle when the model supports
                                // it; otherwise leave the override absent.
                                fastMode: ForkOptions.supportsFastMode(model, catalog: catalog) ? fastMode : nil
                            )
                            dismiss()
                        }
                    }
                }
            }
            // A model switch can change the supported effort range
            // (catalog is per-model: sonnet lacks xhigh, haiku has none) —
            // snap an out-of-range selection back to the model's default.
            .onChange(of: model) {
                if !effortOptions.contains(effort) {
                    effort = ForkOptions.defaultEffort(
                        forAssistant: session.assistant, model: model, catalog: catalog)
                }
            }
            .task {
                // Refresh the live catalog (no-op UI-wise if unchanged), then
                // re-validate the effort seeded in init from the static list.
                await store.refreshModelCatalog()
                if !effortOptions.isEmpty, !effortOptions.contains(effort) {
                    effort = ForkOptions.defaultEffort(
                        forAssistant: session.assistant, model: model, catalog: catalog)
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

    /// One model an agent advertises, discovered live by the broker from
    /// the agent CLI (capabilities "models", broker modelcatalog.go) and
    /// fetched into `SessionStore.modelCatalog`. `id` is the value sent as
    /// the session-create model override; "" is the inherit/default
    /// sentinel (the broker normalizes claude's own "default" entry to it).
    struct AgentModel: Equatable, Identifiable, Decodable {
        var id: String
        var displayName: String
        var description: String
        var isDefault: Bool
        var defaultEffort: String
        var efforts: [String]
        /// True when the claude CLI advertises supportsFastMode for this
        /// model. Only set for claude; always false for codex.
        var supportsFastMode: Bool

        enum CodingKeys: String, CodingKey {
            case id
            case displayName = "display_name"
            case description
            case isDefault = "is_default"
            case defaultEffort = "default_effort"
            case efforts
            case supportsFastMode = "supports_fast_mode"
        }

        init(
            id: String,
            displayName: String,
            description: String = "",
            isDefault: Bool = false,
            defaultEffort: String = "",
            efforts: [String] = [],
            supportsFastMode: Bool = false
        ) {
            self.id = id
            self.displayName = displayName
            self.description = description
            self.isDefault = isDefault
            self.defaultEffort = defaultEffort
            self.efforts = efforts
            self.supportsFastMode = supportsFastMode
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            id = try c.decodeIfPresent(String.self, forKey: .id) ?? ""
            displayName = try c.decodeIfPresent(String.self, forKey: .displayName) ?? ""
            description = try c.decodeIfPresent(String.self, forKey: .description) ?? ""
            isDefault = try c.decodeIfPresent(Bool.self, forKey: .isDefault) ?? false
            defaultEffort = try c.decodeIfPresent(String.self, forKey: .defaultEffort) ?? ""
            efforts = try c.decodeIfPresent([String].self, forKey: .efforts) ?? []
            supportsFastMode = try c.decodeIfPresent(Bool.self, forKey: .supportsFastMode) ?? false
        }
    }

    /// Per-assistant fork option lists. The static lists mirror the broker's
    /// validated effort levels (broker/internal/session/override.go) and are
    /// the FALLBACK; when the broker has discovered the agent's live catalog
    /// (`catalog:` overloads) the options come from the agent itself, so new
    /// models and effort levels appear without an app release.
    enum ForkOptions {
        /// Sentinel for the "keep the current model" option. Sent to
        /// forkSession as nil so the spawn carries no --model override —
        /// byte-for-byte identical to the pre-picker untouched fork.
        static let inheritModel = ""

        /// Agent permission modes. Only the two the broker actually backs:
        ///   - Auto ("") — full-auto default; broker spawns with
        ///     `--dangerously-skip-permissions` (codex unsandboxed).
        ///   - Plan ("plan") — read-only planning; broker swaps to
        ///     `--permission-mode plan` (codex `--sandbox read-only`).
        /// Sent to createSession as nil when Auto so the spawn carries no
        /// override — identical to today's default.
        static let autoMode = ""
        static let planMode = "plan"
        static let permissionModes = [autoMode, planMode]

        /// Display label for a permission-mode option.
        static func permissionModeLabel(_ option: String) -> String {
            option == planMode ? "Plan" : "Auto"
        }

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
                return [inheritModel, "gpt-5-codex", "gpt-5", "gpt-5.5"]
            default:
                return [inheritModel]
            }
        }

        /// Display label for a model option. The sentinel renders as the
        /// "inherit" affordance; everything else shows its alias verbatim.
        static func modelLabel(_ option: String) -> String {
            option.isEmpty ? "Default (inherit)" : option
        }

        // MARK: Catalog-aware overloads
        //
        // Each takes the assistant's discovered catalog
        // (`store.modelCatalog[assistant]`) and falls back to the static
        // lists above whenever it's nil/empty (old broker, discovery still
        // running, offline).

        /// The catalog entry a model option resolves to. The inherit
        /// sentinel resolves to the agent's default entry so its effort
        /// range / description follow the model the session would really run.
        static func catalogEntry(for option: String, in catalog: [AgentModel]?) -> AgentModel? {
            guard let catalog, !catalog.isEmpty else { return nil }
            if let exact = catalog.first(where: { $0.id == option }) { return exact }
            guard option == inheritModel else { return nil }
            return catalog.first(where: { $0.isDefault }) ?? catalog.first
        }

        /// Model options from the discovered catalog (inherit sentinel
        /// first), or the static list when no catalog is available.
        static func models(forAssistant assistant: String, catalog: [AgentModel]?) -> [String] {
            guard let catalog, !catalog.isEmpty else { return models(forAssistant: assistant) }
            let ids = catalog.map(\.id)
            // When the catalog has an explicit non-empty isDefault entry (e.g. codex's
            // "gpt-5.5"), that entry IS the recommended row — do NOT prepend the ""
            // inherit sentinel, which would create a duplicate recommended row.
            // When no explicit non-empty isDefault exists (e.g. claude whose catalog
            // already has a "" entry, or a catalog with no isDefault), fall through to
            // prepend "" if absent so the user can always select "no override".
            let hasExplicitDefault = catalog.contains { $0.isDefault && !$0.id.isEmpty }
            if hasExplicitDefault {
                return ids
            }
            var mutable = ids
            if !mutable.contains(inheritModel) { mutable.insert(inheritModel, at: 0) }
            return mutable
        }

        /// Display label for a model option, preferring the agent's own
        /// display name. For the default/inherit row the raw sentinel label
        /// ("Default (inherit)" or "Default (recommended)") hides the actual
        /// model — so we surface the resolved model name instead:
        /// "<Model Name> (recommended)" e.g. "Opus 4.8 (recommended)".
        /// Two cases:
        ///   Claude — catalog has a literal "" entry with displayName
        ///   "Default (recommended)". The entry is found directly and its
        ///   displayName triggers the resolved-name path.
        ///   Codex — catalog has NO "" entry (isDefault entry is "gpt-5.5").
        ///   No exact match for "", so we fall through to the inherit-sentinel
        ///   path: resolve via catalogEntry(for:"",in:) which returns the
        ///   isDefault entry, and show "<that displayName> (recommended)".
        /// This means every agent's inherit row shows the real model it will
        /// use, with no hardcoded names.
        static func modelLabel(_ option: String, catalog: [AgentModel]?) -> String {
            guard let catalog, !catalog.isEmpty else { return modelLabel(option) }
            if let entry = catalog.first(where: { $0.id == option }) {
                // Show "(recommended)" on the default entry, whether its id is "" (claude)
                // or a real model id (codex). Also catches claude's "Default (recommended)"
                // displayName prefix path.
                let isRecommendedRow = entry.isDefault ||
                    entry.displayName.lowercased().hasPrefix("default") ||
                    entry.id == inheritModel
                if isRecommendedRow {
                    if let resolved = defaultModelTitle(forCatalog: catalog) {
                        return "\(resolved) (recommended)"
                    }
                }
                return entry.displayName.isEmpty ? modelLabel(option) : entry.displayName
            }
            // No exact match. For the inherit sentinel (static-fallback path or catalogs
            // with no "" entry that are queried with ""), resolve via isDefault entry.
            if option == inheritModel,
               let resolved = defaultModelTitle(forCatalog: catalog) {
                return "\(resolved) (recommended)"
            }
            return modelLabel(option)
        }

        /// One-line detail for a model option (the agent's own description,
        /// e.g. "Sonnet 4.6 · Efficient for routine tasks"). nil without a
        /// catalog — the caller hides the caption.
        static func modelDetail(_ option: String, catalog: [AgentModel]?) -> String? {
            guard let entry = catalogEntry(for: option, in: catalog) else { return nil }
            return entry.description.isEmpty ? nil : entry.description
        }

        /// Effort levels for the chosen model from the discovered catalog
        /// (per-model: claude sonnet lacks xhigh, haiku has none at all);
        /// static per-assistant list when no catalog. An EMPTY result means
        /// the model has no effort control — hide the effort UI and send no
        /// override.
        static func efforts(forAssistant assistant: String, model: String, catalog: [AgentModel]?) -> [String] {
            guard let catalog, !catalog.isEmpty else { return efforts(forAssistant: assistant) }
            return catalogEntry(for: model, in: catalog)?.efforts ?? []
        }

        /// The effort to preselect for a model: the agent's own default when
        /// advertised, else "medium" when offered, else the first level.
        /// "" when the model has no effort control.
        static func defaultEffort(forAssistant assistant: String, model: String = inheritModel, catalog: [AgentModel]? = nil) -> String {
            let options = efforts(forAssistant: assistant, model: model, catalog: catalog)
            if options.isEmpty { return "" }
            if let entry = catalogEntry(for: model, in: catalog),
               !entry.defaultEffort.isEmpty, options.contains(entry.defaultEffort) {
                return entry.defaultEffort
            }
            return options.contains("medium") ? "medium" : options[0]
        }

        /// Friendly dial label for a raw effort level. Labels match the
        /// actual level names so the dial and the raw-value chip agree.
        /// Unknown levels fall back to their capitalized raw value so a
        /// future agent-side addition still renders.
        static func effortLabel(_ value: String) -> String {
            switch value {
            case "low": return "Low"
            case "medium": return "Medium"
            case "high": return "High"
            case "xhigh": return "X-High"
            case "max": return "Max"
            default: return value.capitalized
            }
        }

        /// Consequence line shown under the effort dial.
        static func effortDescription(_ value: String) -> String {
            switch value {
            case "low": return "Quick passes, minimal deliberation"
            case "medium": return "Reasons before it acts — the default"
            case "high": return "Plans hard and checks itself, slower"
            case "xhigh": return "Extra-high reasoning depth for hard problems"
            case "max": return "Maximum reasoning depth — slowest, most thorough"
            default: return "Reasoning depth: \(value)"
            }
        }

        /// True when the resolved catalog entry for `option` advertises fast
        /// mode. Always false without a catalog or for the inherit sentinel
        /// when the resolved default entry does not carry the flag.
        static func supportsFastMode(_ option: String, catalog: [AgentModel]?) -> Bool {
            catalogEntry(for: option, in: catalog)?.supportsFastMode ?? false
        }

        /// The model name to show on the agent card: the discovered default
        /// model's display name ("GPT-5.5"); for claude's "Default
        /// (recommended)" alias entry, the resolved model is the first
        /// "·"-chunk of its description ("Opus 4.8 with 1M context" ->
        /// "Opus 4.8"). nil without a catalog -- caller keeps its static
        /// label.
        static func defaultModelTitle(forCatalog catalog: [AgentModel]?) -> String? {
            guard let entry = catalog?.first(where: { $0.isDefault }) ?? catalog?.first else { return nil }
            var name = entry.displayName
            if name.lowercased().hasPrefix("default") || name.isEmpty {
                name = entry.description
                    .components(separatedBy: "·").first?
                    .trimmingCharacters(in: .whitespaces) ?? name
                if let r = name.range(of: " with ") {
                    name = String(name[..<r.lowerBound])
                }
            }
            return name.isEmpty ? nil : name
        }
    }
}
