import Foundation
import SwiftUI

// MARK: - ConduitAgentPickerSheet
//
// Native ConduitUI agent-picker sheet. Replaces the legacy
// `AgentPickerSheet`. Visual choices:
//   - small-caps "PAIRED WITH" / "INITIAL PROMPT" / "AGENT" section
//     labels (11pt mono, brand-tinted)
//   - neon card surfaces via `neonCardSurface(...)`
//   - per-agent accent on the avatar circle only; row text stays in
//     `textPrimary` so the buttons read as a list not a rainbow
//
// Used in two places:
//   - "+" button on `ConduitHomeView` (new session).
//   - Auto-presented after a deep-link pair so the user lands on
//     "pick Claude/Codex" instead of an empty session list.

extension ConduitUI {
    struct AgentPickerSheet: View {
        @Environment(SessionStore.self) private var store
        @Environment(FeatureFlags.self) private var flags
        @Environment(\.neonTheme) private var neon
        @Environment(\.dismiss) private var dismiss

        /// Optional context label (e.g. host that was just paired) shown
        /// in the sheet header. nil hides it.
        var headerNote: String? = nil

        /// Optional pre-populated prompt (typically a voice transcript).
        /// When set, tapping an agent creates the session with this
        /// prompt seeded as its first chat message.
        var initialPrompt: String? = nil

        /// Agent the user tapped; pushes the directory picker. nil while
        /// on the agent-selection screen.
        @State private var pickedAgent: String?
        /// WS-H.3: show the agent-login sheet when the user taps "Sign in"
        /// on a not-signed-in readiness row.
        @State private var showAgentLogin = false
        /// Single-flight guard for the Continue bar. Set true on the FIRST tap
        /// so subsequent taps during the navigation-push animation are dropped
        /// (and the button shows a spinner so the user sees the tap registered).
        @State private var isContinueLaunching: Bool = false

        /// In cards mode (§3) the selected agent tints the whole sheet before
        /// the user commits with "Continue". Defaults to Claude (first card).
        @State private var selectedAgentKind: String = "claude"

        /// Box the session should run on (device feedback, round 3:
        /// "I can't choose where to start the session in"). nil =
        /// whatever box is currently connected; an explicit pick of a
        /// different box routes the create through
        /// `store.connectAndStart` (switch endpoint → connect → create).
        @State private var selectedServerID: String?

        /// The effective box pick: the explicit selection, else the
        /// saved server matching the live endpoint.
        private var resolvedServer: SavedServer? {
            if let id = selectedServerID,
               let picked = store.savedServers.first(where: { $0.id == id }) {
                return picked
            }
            return store.savedServers.first(where: { $0.endpoint == store.endpoint })
        }

        var body: some View {
            NavigationStack {
                ZStack {
                    GlassAppBackground()
                    ScrollView {
                        VStack(alignment: .leading, spacing: 14) {
                            header
                            if let prompt = initialPrompt?.trimmingCharacters(in: .whitespacesAndNewlines),
                               !prompt.isEmpty {
                                promptPreview(prompt)
                            }
                            sectionLabel("Agent", tint: flags.newSessionAgentCards ? sheetTint : nil)
                            if flags.newSessionAgentCards {
                                // Two-column grid: hardcoded cards first, then
                                // any generic agents from the descriptor map
                                // that aren't already covered.
                                let allKinds = allAgentKinds
                                LazyVGrid(
                                    columns: [
                                        GridItem(.flexible(), spacing: 11),
                                        GridItem(.flexible(), spacing: 11),
                                    ],
                                    spacing: 11
                                ) {
                                    ForEach(allKinds, id: \.self) { kind in
                                        agentCard(kind: kind)
                                    }
                                }
                            } else {
                                agentRow(
                                    kind: "claude",
                                    label: "Claude",
                                    subtitle: "Powered by Anthropic"
                                )
                                agentRow(
                                    kind: "codex",
                                    label: "Codex",
                                    subtitle: "Powered by OpenAI"
                                )
                                // Generic rows for any extra descriptors.
                                ForEach(extraAgentKinds, id: \.self) { kind in
                                    let meta = agentMeta(kind)
                                    agentRow(
                                        kind: kind,
                                        label: meta.name,
                                        subtitle: meta.blurb
                                    )
                                }
                            }
                            // Always show where the session will run — even
                            // with one box. Device feedback round 4: with the
                            // section gated on >1 servers, a single-box user
                            // "can't choose the box" and can't tell local vs
                            // server. One box = one checked row + footnote.
                            if !store.savedServers.isEmpty {
                                sectionLabel("Box")
                                boxSection
                            }
                            if !store.harness.canIssueCommands {
                                Text("Connect to a server first — open Settings to pair.")
                                    .font(neon.sans(13))
                                    .foregroundStyle(neon.textDim)
                                    .multilineTextAlignment(.center)
                                    .frame(maxWidth: .infinity, alignment: .center)
                                    .padding(.top, 4)
                            }
                            // WS-H.3: post-pair readiness checklist — informational,
                            // never blocking. Only shown when the broker sent a
                            // readiness block (nil = old broker, silently omitted).
                            if let readiness = store.brokerReadiness {
                                let items = readinessCheckItems(
                                    readiness: readiness,
                                    descriptors: store.agentDescriptors
                                )
                                if !items.isEmpty {
                                    sectionLabel("Box readiness")
                                    ConduitUI.ReadinessChecklist(items: items) { _ in
                                        // "Sign in" deep-links the existing agent-login flow.
                                        showAgentLogin = true
                                    }
                                }
                            }
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 18)
                    }
                    .scrollIndicators(.hidden)
                }
                .navigationTitle("New session")
                .navigationBarTitleDisplayMode(.inline)
                .safeAreaInset(edge: .bottom) {
                    // Cards mode commits with a tinted Continue bar (§3); rows
                    // mode keeps tap-to-drill, so no bottom bar there.
                    if flags.newSessionAgentCards && store.harness.canIssueCommands {
                        continueBar
                    }
                }
                .navigationDestination(item: $pickedAgent) { kind in
                    DirectoryPicker(
                        agentKind: kind,
                        agentTint: neon.agentTint(forAgent: kind),
                        initialPrompt: initialPrompt,
                        onCreate: { cwd, model, effort, permissionMode, fastMode, seedPrompt in
                            // Part B: a "Set up agent harness" tap passes the
                            // bootstrap prompt as seedPrompt; otherwise fall
                            // back to the sheet's initialPrompt (voice transcript).
                            let seed = seedPrompt ?? initialPrompt
                            // Always create on the connected box — readiness,
                            // directory browser, and create all use the
                            // connected box's client. Non-connected box rows
                            // are disabled in boxSection, so resolvedServer
                            // always points to the connected box here.
                            store.createSession(
                                assistant: kind,
                                startupCwd: cwd,
                                reasoningEffort: effort,
                                model: model,
                                permissionMode: permissionMode,
                                fastMode: fastMode,
                                initialPrompt: seed
                            )
                            // Defer the dismiss one runloop tick. createSession
                            // mutates the store → the app tree rebuilds; tearing
                            // down this pushed DirectoryPicker (a representable
                            // subtree) in the SAME CoreAnimation transaction can
                            // message a freed CALayer →
                            // `-[NSIndirectTaggedPointerString bounds]` at CA
                            // commit (Sentry CONDUIT-IOS-N/M, the dominant 0.0.83
                            // crash). Letting the create commit first, then
                            // dismissing, avoids the collision. Best-effort —
                            // needs on-device verification.
                            DispatchQueue.main.async { dismiss() }
                        }
                    )
                }
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") { dismiss() }
                    }
                }
            }
            .presentationDetents([.medium, .large])
            .presentationCornerRadius(26)
            .tint(neon.accent)
            // Reset the single-flight guard when the user navigates BACK from
            // DirectoryPicker (pickedAgent -> nil) so the Continue bar is live again.
            .onChange(of: pickedAgent) { _, newValue in
                if newValue == nil { isContinueLaunching = false }
            }
            .task {
                // Pull the live per-agent model catalog (broker-discovered
                // from the agent CLIs) so the cards' model line and the
                // directory step's model/effort options reflect what the
                // box actually serves. Failure = keep static fallbacks.
                // WS-H.1: also parses readiness block for H.2/H.3 banners.
                await store.refreshModelCatalog()
            }
            // WS-H.3: agent-login sheet launched from "Sign in" on a
            // not-signed-in readiness row (informational, never blocking).
            .sheet(isPresented: $showAgentLogin) {
                ConduitUI.AgentLoginSheet()
            }
            .onAppear {
                // Funnel: agent picker opened (new-session flow or post-pair deep link).
                let isFirstSession = store.sessions.isEmpty
                Telemetry.breadcrumb("onboarding", OnboardingStep.agentPickerOpened,
                    data: ["first_session": "\(isFirstSession)",
                           "host": store.endpoint.displayHost])
            }
            .appearanceColorScheme()
        }

        // MARK: - Subviews

        @ViewBuilder
        private var header: some View {
            if let note = headerNote, !note.isEmpty {
                // PLAN-CONDUIT-VISUAL-PARITY audit §A.5 / PR 5
                // deferred — collapse the chunky tinted glass card
                // around the "Paired with <host>" note to an inline
                // caption. The agent buttons below are the action;
                // the header is metadata and shouldn't compete with
                // them for visual weight.
                HStack(spacing: 6) {
                    Text("PAIRED WITH")
                        .font(neon.mono(11).weight(.bold))
                        .tracking(0.6)
                        .foregroundStyle(neon.textFaint)
                    Text(note)
                        .font(neon.sans(13).weight(.semibold))
                        .foregroundStyle(neon.textDim)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 4)
                .padding(.bottom, 2)
            }
        }

        /// Tinted commit bar for cards mode — pushes the directory step for
        /// the selected agent. Tint tracks the selected card (§3 acceptance:
        /// switching agent recolors the Start/Continue button).
        private var continueBar: some View {
            let meta = agentMeta(selectedAgentKind)
            return Button {
                // Single-flight: drop duplicate taps during the push animation.
                guard !isContinueLaunching else { return }
                isContinueLaunching = true
                // Breadcrumb so we can confirm the tap fires in Sentry.
                Telemetry.breadcrumb("pairing", "setup connect tapped", data: [
                    "agent": selectedAgentKind,
                    "host": store.endpoint.displayHost,
                ])
                pickedAgent = selectedAgentKind
            } label: {
                HStack(spacing: 8) {
                    if isContinueLaunching {
                        // Immediate visual feedback — spinner replaces the chevron
                        // so the user knows the first tap was registered even
                        // before the navigation-push animation begins.
                        ProgressView()
                            .progressViewStyle(.circular)
                            .tint(neon.accentText)
                            .scaleEffect(0.8)
                    } else {
                        Text("Continue with \(meta.name)")
                        Image(systemName: "chevron.right")
                            .font(.system(size: 13, weight: .bold))
                    }
                }
                .font(neon.sans(15).weight(.semibold))
                .foregroundStyle(neon.accentText)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
                .background(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(sheetTint.opacity(isContinueLaunching ? 0.7 : 1.0))
                )
                .neonGlowBox(neon.glow && !isContinueLaunching ? neon.glowBox?.tinted(sheetTint) : nil)
            }
            .buttonStyle(.plain)
            .disabled(isContinueLaunching)
            .padding(.horizontal, 16)
            .padding(.top, 10)
            .padding(.bottom, 12)
            .background(
                neon.surfaceSolid
                    .overlay(alignment: .top) {
                        Rectangle().fill(neon.border).frame(height: 1)
                    }
                    .ignoresSafeArea(edges: .bottom)
            )
        }

        private func promptPreview(_ prompt: String) -> some View {
            VStack(alignment: .leading, spacing: 6) {
                sectionLabel("Initial prompt")
                Text(prompt)
                    .font(neon.sans(13))
                    .foregroundStyle(neon.text)
                    .lineLimit(4)
                    .multilineTextAlignment(.leading)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .neonCardSurface(neon, fill: neon.surface, cornerRadius: 13)
            .accessibilityIdentifier("ConduitAgentPickerSheet.initialPrompt")
        }

        private func sectionLabel(_ text: String, tint: Color? = nil) -> some View {
            Text(text.uppercased())
                .font(neon.mono(11).weight(.bold))
                .tracking(0.6)
                .foregroundStyle(tint ?? neon.textFaint)
        }

        /// The agent tint that recolors the sheet in cards mode (§3).
        private var sheetTint: Color { neon.agentTint(forAgent: selectedAgentKind) }

        /// Hardcoded agent kinds that have first-class branded cards.
        private static let hardcodedKinds: Set<String> = ["claude", "codex"]

        /// Agents from the broker's descriptor map that don't have a
        /// hardcoded card. Sorted alphabetically for stable ordering.
        private var extraAgentKinds: [String] {
            store.agentDescriptors.keys
                .filter { !Self.hardcodedKinds.contains($0.lowercased()) }
                .sorted()
        }

        /// All agent kinds to show in the picker: hardcoded first, then extras,
        /// filtered by `flags.enabledAgents` (default: ["claude","codex"]).
        private var allAgentKinds: [String] {
            let enabled = Set(flags.enabledAgents.map { $0.lowercased() })
            let base: [String] = ["claude", "codex"].filter { enabled.contains($0) }
            let extras = extraAgentKinds.filter { enabled.contains($0.lowercased()) }
            return base + extras
        }

        /// Side-by-side agent card (§3, `02-ns`). Carries the agent's brand
        /// color, model name, and a one-line character note. Selecting a card
        /// tints the whole sheet (labels + Continue button) with its color.
        private func agentCard(kind: String) -> some View {
            let canIssue = store.harness.canIssueCommands
            let tint = neon.agentTint(forAgent: kind)
            let selected = selectedAgentKind == kind
            let meta = agentMeta(kind)
            // Live default-model name from the discovered catalog ("GPT-5.5",
            // "Opus 4.8") — the static meta.model is only the offline
            // fallback, so the card never pins a stale model name.
            let modelTitle = ConduitUI.ForkOptions.defaultModelTitle(
                forCatalog: store.modelCatalog[kind]) ?? meta.model
            return Button {
                selectedAgentKind = kind
            } label: {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(alignment: .top) {
                        AgentAvatar(assistant: kind, size: 34)
                        Spacer(minLength: 0)
                        ZStack {
                            Circle()
                                .fill(selected ? tint : Color.clear)
                                .overlay(Circle().strokeBorder(selected ? Color.clear : neon.border, lineWidth: 1.5))
                                .frame(width: 20, height: 20)
                            if selected {
                                Image(systemName: "checkmark")
                                    .font(.system(size: 11, weight: .bold))
                                    .foregroundStyle(neon.accentText)
                            }
                        }
                    }
                    Text(meta.name)
                        .font(neon.sans(16).weight(.bold))
                        .foregroundStyle(neon.text)
                    Text(modelTitle)
                        .font(neon.mono(11.5))
                        .foregroundStyle(selected ? tint : neon.textFaint)
                    Text(meta.blurb)
                        .font(neon.sans(12.5))
                        .foregroundStyle(neon.textDim)
                        .lineLimit(3)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(EdgeInsets(top: 13, leading: 13, bottom: 14, trailing: 13))
                .frame(maxWidth: .infinity, alignment: .leading)
                .neonCardSurface(
                    neon,
                    fill: selected ? tint.opacity(neon.dark ? 0.14 : 0.10) : neon.surface,
                    cornerRadius: 15,
                    border: selected ? tint : neon.border,
                    glowTint: selected ? tint : nil
                )
            }
            .buttonStyle(.plain)
            .disabled(!canIssue)
            .opacity(canIssue ? 1.0 : 0.55)
        }

        /// Brand metadata for the agent cards (§3). Mirrors `imp-newsession`.
        /// For hardcoded agents (claude / codex) uses static copy. For generic
        /// agents, falls back to the descriptor's display_name and a neutral
        /// blurb — needs on-device verification.
        private func agentMeta(_ kind: String) -> (name: String, model: String, blurb: String) {
            switch kind.lowercased() {
            case "codex":
                return ("Codex", "gpt-5-codex", "Terse and fast on well-scoped code tasks.")
            case "claude":
                return ("Claude", "Sonnet 4.6", "Careful, conversational — best for ambiguous work.")
            default:
                // Generic agent: pull display_name from the descriptor if available.
                let desc = store.agentDescriptors[kind.lowercased()]
                let name = (desc?.displayName.isEmpty == false) ? desc!.displayName : kind.capitalized
                let modelTitle = ConduitUI.ForkOptions.defaultModelTitle(forCatalog: store.modelCatalog[kind]) ?? ""
                return (name, modelTitle, "Runs on this box.")
            }
        }


        /// One row per paired box; the session is created on the checked
        /// one. Only the currently-connected box is selectable — readiness,
        /// directory browser, and create all use the connected box's client,
        /// so allowing a different selection would show the connected box's
        /// readiness/filesystem but create elsewhere (incoherent). Multi-box
        /// concurrent sessions are a future feature; for now, non-connected
        /// boxes show a "Switch in Settings" note and are disabled.
        /// "This device" on the home Boxes list is display-only — a phone
        /// can't host the broker — so it is deliberately not a target here.
        private var boxSection: some View {
            VStack(spacing: 6) {
                ForEach(store.savedServers) { server in
                    let isConnected = server.endpoint == store.endpoint
                    let isSelected = server.id == resolvedServer?.id
                    HStack(spacing: 12) {
                        Image(systemName: "server.rack")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(isSelected ? neon.accent : neon.textDim)
                            .frame(width: 30, height: 30)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(server.name)
                                .font(neon.sans(13).weight(.semibold))
                                .foregroundStyle(neon.text)
                            if isConnected {
                                Text(server.endpoint.displayHost)
                                    .font(neon.mono(11))
                                    .foregroundStyle(neon.textDim)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                            } else {
                                Text("Switch to this box in Settings to start a session on it.")
                                    .font(neon.mono(10.5))
                                    .foregroundStyle(neon.textFaint)
                                    .lineLimit(2)
                            }
                        }
                        Spacer()
                        Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(isSelected ? neon.accent : neon.textFaint)
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 11)
                    .neonCardSurface(
                        neon,
                        fill: isSelected ? neon.accent.opacity(neon.dark ? 0.10 : 0.07) : neon.surface,
                        cornerRadius: 13,
                        border: isSelected ? neon.accent.opacity(0.5) : neon.border
                    )
                    .opacity(isConnected ? 1.0 : 0.55)
                }
                if store.savedServers.count == 1 {
                    Text("Sessions run on a paired box — this device can't host them. Pair another box in Settings.")
                        .font(neon.mono(10.5))
                        .foregroundStyle(neon.textFaint)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.top, 2)
                }
            }
            .accessibilityIdentifier("ConduitAgentPickerSheet.boxSection")
        }

        private func agentRow(kind: String, label: String, subtitle: String) -> some View {
            let canIssue = store.harness.canIssueCommands
            let tint = neon.agentTint(forAgent: kind)
            return Button {
                pickedAgent = kind
            } label: {
                HStack(spacing: 14) {
                    AgentAvatar(assistant: kind, size: 40)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(label)
                            .font(neon.sans(13).weight(.semibold))
                            .foregroundStyle(neon.text)
                        Text(subtitle)
                            .font(neon.sans(11))
                            .foregroundStyle(neon.textDim)
                    }
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(tint)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
                .neonCardSurface(
                    neon,
                    fill: tint.opacity(neon.dark ? 0.14 : 0.10),
                    cornerRadius: 13,
                    border: tint.opacity(0.5),
                    glowTint: tint
                )
            }
            .buttonStyle(.plain)
            .disabled(!canIssue)
            .opacity(canIssue ? 1.0 : 0.55)
        }
    }
}

// MARK: - DirectoryPicker
//
// Second step of the new-session flow (upstream parity, task #36). After
// the agent is chosen the user lands here to pick a working directory:
//   - "Recent" shortcut list (from `store.recentDirectories`, per-server)
//   - a live browser over `store.listDirectories(path:)` — tap a folder
//     to descend, breadcrumb / parent button to go back up
//   - "Use this folder" starts the session cd'd into the current path
//   - "Start without a folder" preserves today's behavior (no cwd)
//
// Style follows the ConduitUI palette + glass cards used by the agent
// step above so the two screens read as one sheet.

extension ConduitUI {
    struct DirectoryPicker: View {
        let agentKind: String
        /// The chosen agent's brand color (§3) — tints the effort dial fill,
        /// the launch line, and the Start button so the directory step keeps
        /// the agent's identity carried over from the cards step. nil on the
        /// legacy rows path → falls back to the neon accent.
        var agentTint: Color?
        var initialPrompt: String?
        /// Called with the absolute path to cd into (or nil to start with no
        /// working directory), the selected model alias (nil = inherit the
        /// agent's default model), the chosen reasoning effort (nil = the
        /// agent's default effort), the agent mode (nil = Auto / full-auto
        /// default; "plan" = read-only planning), and an optional seed prompt
        /// override (Part B: the "Set up agent harness" bootstrap prompt; nil
        /// falls back to the sheet's own initialPrompt, e.g. a voice transcript).
        let onCreate: (String?, String?, String?, String?, Bool?, String?) -> Void

        @Environment(SessionStore.self) private var store
        @Environment(FeatureFlags.self) private var flags
        @Environment(\.neonTheme) private var neon
        @Environment(\.dismiss) private var dismiss
        @Environment(\.horizontalSizeClass) private var horizontalSizeClass

        @State private var listing: RemoteDirectoryListing?
        @State private var isLoading = false
        @State private var loadError: String?
        /// Path currently being browsed. nil = the harness default (home).
        @State private var currentPath: String?
        /// Part B: whether the currently-browsed dir already has CLAUDE.md /
        /// AGENTS.md. nil = unknown / not yet checked (default: don't nag).
        /// Refetched alongside each listing in load().
        @State private var harnessStatus: RemoteHarnessStatus?
        /// User dismissed the "Set up agent harness" chip for this session —
        /// keep it hidden for the rest of the sheet (honest, non-nagging).
        @State private var harnessChipDismissed = false
        /// Selected model option. `ForkOptions.inheritModel` (empty string)
        /// means "no override — use the agent's default model", which is the
        /// default and keeps the start path identical to before.
        @State private var model: String = ConduitUI.ForkOptions.inheritModel
        /// Selected reasoning effort. Defaults to the agent's sensible
        /// default ("medium" when offered) via `defaultEffort`, mirroring the
        /// Fork sheet — the new-session flow previously couldn't set effort.
        @State private var effort: String
        /// Selected agent mode. `ForkOptions.autoMode` (empty string) means
        /// the app's current full-auto default — sent as nil so the spawn
        /// carries no override, identical to before this picker existed.
        @State private var permissionMode: String = ConduitUI.ForkOptions.autoMode
        /// Claude-only "fast mode" toggle. Defaults OFF; only shown (and only
        /// passed to onCreate) when the selected model advertises
        /// `supportsFastMode`. Sent as nil otherwise so the start path is
        /// byte-identical to before.
        @State private var fastMode: Bool = false

        init(
            agentKind: String,
            agentTint: Color? = nil,
            initialPrompt: String? = nil,
            onCreate: @escaping (String?, String?, String?, String?, Bool?, String?) -> Void
        ) {
            self.agentKind = agentKind
            self.agentTint = agentTint
            self.initialPrompt = initialPrompt
            self.onCreate = onCreate
            self._effort = State(initialValue: Self.defaultEffort(forAssistant: agentKind))
        }

        /// One dial stop: a friendly label over a raw API effort value with
        /// a consequence line. Stops are derived from the effort options of
        /// the selected model (catalog-aware), so the dial grows past the
        /// classic Fast/Balanced/Deep when the agent offers xhigh/max.
        private struct EffortStop {
            let label: String
            let value: String
            let desc: String
        }
        private var effortStops: [EffortStop] {
            effortOptions.map {
                EffortStop(
                    label: ConduitUI.ForkOptions.effortLabel($0),
                    value: $0,
                    desc: ConduitUI.ForkOptions.effortDescription($0))
            }
        }

        /// Tint to use for the agent-coloured chrome — falls back to the neon
        /// accent if no agent tint was threaded in (rows-mode / legacy paths).
        private var tint: Color { agentTint ?? neon.accent }

        private static func defaultEffort(forAssistant assistant: String) -> String {
            let options = ConduitUI.ForkOptions.efforts(forAssistant: assistant)
            return options.contains("medium") ? "medium" : (options.first ?? "medium")
        }

        /// The agent's live model catalog (broker-discovered, fetched by the
        /// agent step's `.task`); nil/empty falls back to the static lists.
        private var catalog: [ConduitUI.AgentModel]? {
            store.modelCatalog[agentKind]
        }

        /// Broker-served descriptor for this agent, if any.
        private var descriptor: AgentDescriptor? {
            store.agentDescriptors[agentKind.lowercased()]
        }

        private var modelOptions: [String] {
            ConduitUI.ForkOptions.models(forAssistant: agentKind, catalog: catalog)
        }

        /// Effort options for the SELECTED model (catalog is per-model:
        /// sonnet lacks xhigh, haiku has none). Empty = the model has no
        /// effort control → the effort UI hides and no override is sent.
        /// Also returns empty when the descriptor signals supports.effort =
        /// false — the whole effort section is hidden for agents like
        /// opencode that have no effort concept at all.
        private var effortOptions: [String] {
            if let d = descriptor, !d.supports.effort { return [] }
            return ConduitUI.ForkOptions.efforts(forAssistant: agentKind, model: model, catalog: catalog)
        }

        /// The model to hand to onCreate: the sentinel maps to nil.
        private var selectedModel: String? { model.isEmpty ? nil : model }

        /// The effort to hand to onCreate: nil when the model has no effort
        /// control (or nothing is selected) so the spawn carries no override.
        private var selectedEffort: String? {
            effortOptions.isEmpty || effort.isEmpty ? nil : effort
        }

        /// The agent mode to hand to onCreate: Auto (sentinel) maps to nil.
        private var selectedPermissionMode: String? { permissionMode.isEmpty ? nil : permissionMode }

        /// The fast-mode toggle to hand to onCreate: nil unless the selected
        /// model supports it, so an unsupported model never sends an override.
        private var selectedFastMode: Bool? {
            ConduitUI.ForkOptions.supportsFastMode(model, catalog: catalog) ? fastMode : nil
        }

        var body: some View {
            ZStack {
                GlassAppBackground()
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        modelSection
                        // Tablet (§6): effort + mode sit side by side to use
                        // the width; phone stacks them. A model with no
                        // effort control (haiku) drops the effort section.
                        if effortOptions.isEmpty {
                            modeSection
                        } else if horizontalSizeClass == .regular {
                            HStack(alignment: .top, spacing: 14) {
                                effortSection.frame(maxWidth: .infinity, alignment: .leading)
                                modeSection.frame(maxWidth: .infinity, alignment: .leading)
                            }
                        } else {
                            effortSection
                            modeSection
                        }
                        if !store.recentDirectories.isEmpty {
                            recentSection
                        }
                        browseSection
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 18)
                }
                .scrollIndicators(.hidden)
            }
            .navigationTitle("Working directory")
            .navigationBarTitleDisplayMode(.inline)
            // Replace iOS 26's default circular glass back button — its
            // translucent fill let the app's grid background show through
            // ("the back shows under the button", device feedback) and it
            // clashed with the plain-chevron back used everywhere else
            // (see ConduitProjectView's header). A flat chevron pops the
            // nav stack via the dismiss environment.
            .navigationBarBackButtonHidden(true)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(neon.text)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Back")
                }
            }
            .safeAreaInset(edge: .bottom) { bottomBar }
            .task(id: currentPath) { await load() }
            .onAppear {
                // Honour the last effort the user picked on the dial (§3
                // acceptance: "persists the last choice"), but only when it's
                // a value this agent supports — otherwise keep the per-agent
                // default seeded in init.
                let last = flags.newSessionLastEffort
                if flags.newSessionEffortDial, !last.isEmpty, effortOptions.contains(last) {
                    effort = last
                } else if !effortOptions.isEmpty, !effortOptions.contains(effort) {
                    // The catalog may know a narrower range than the static
                    // seed used in init (per-model efforts).
                    effort = ConduitUI.ForkOptions.defaultEffort(
                        forAssistant: agentKind, model: model, catalog: catalog)
                }
            }
            // A model switch can change the supported effort range — snap an
            // out-of-range selection back to the new model's default.
            .onChange(of: model) {
                if !effortOptions.isEmpty, !effortOptions.contains(effort) {
                    effort = ConduitUI.ForkOptions.defaultEffort(
                        forAssistant: agentKind, model: model, catalog: catalog)
                }
            }
            .tint(neon.accent)
        }

        // MARK: Sections

        private var modelSection: some View {
            VStack(alignment: .leading, spacing: 8) {
                sectionLabel("Model")
                Menu {
                    Picker("Model", selection: $model) {
                        ForEach(modelOptions, id: \.self) { option in
                            Text(ConduitUI.ForkOptions.modelLabel(option, catalog: catalog)).tag(option)
                        }
                    }
                } label: {
                    HStack {
                        Text(ConduitUI.ForkOptions.modelLabel(model, catalog: catalog))
                            .font(neon.sans(13).weight(.medium))
                            .foregroundStyle(neon.text)
                        Spacer()
                        Image(systemName: "chevron.up.chevron.down")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(neon.textDim)
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 12)
                    .neonCardSurface(neon, fill: neon.surface, cornerRadius: 13)
                }
                .tint(neon.accent)
                // The agent's own description of the (resolved) selection —
                // e.g. "Sonnet 4.6 · Efficient for routine tasks". Only when
                // the live catalog is in; the static fallback has none.
                if let detail = ConduitUI.ForkOptions.modelDetail(model, catalog: catalog) {
                    Text(detail)
                        .font(neon.sans(12))
                        .foregroundStyle(neon.textDim)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                if ConduitUI.ForkOptions.supportsFastMode(model, catalog: catalog) {
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
            }
        }

        @ViewBuilder
        private var effortSection: some View {
            if flags.newSessionEffortDial {
                effortDialSection
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    sectionLabel("Reasoning effort")
                    Picker("Reasoning effort", selection: $effort) {
                        ForEach(effortOptions, id: \.self) { level in
                            Text(level.capitalized).tag(level)
                        }
                    }
                    .pickerStyle(.segmented)
                    .tint(neon.accent)
                }
            }
        }

        /// Effort dial (§3, `03-ns`): one stop per effort level the selected
        /// model supports — Fast/Balanced/Deep for the classic three, growing
        /// to X-High/Max when the agent's catalog offers them. The track
        /// fills up to (and including) the selected stop in the agent tint; a
        /// consequence line + the raw API value chip sit beneath.
        private var effortDialSection: some View {
            let stops = effortStops
            let idx = max(0, min(stops.count - 1, stops.firstIndex(where: { $0.value == effort }) ?? 1))
            let cur = stops[idx]
            return VStack(alignment: .leading, spacing: 8) {
                sectionLabel("Reasoning effort", tint: tint)
                HStack(spacing: 7) {
                    ForEach(Array(stops.enumerated()), id: \.offset) { i, stop in
                        Button {
                            effort = stop.value
                            flags.newSessionLastEffort = stop.value
                        } label: {
                            VStack(spacing: 9) {
                                Capsule()
                                    .fill(i <= idx ? tint : neon.textFaint.opacity(0.25))
                                    .frame(height: 8)
                                    .neonGlowBox(i == idx && neon.glow ? neon.glowBox?.tinted(tint) : nil)
                                Text(stop.label)
                                    .font(neon.sans(13).weight(i == idx ? .bold : .medium))
                                    .foregroundStyle(i == idx ? neon.text : neon.textFaint)
                                    .lineLimit(1)
                                    .minimumScaleFactor(0.7)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .frame(maxWidth: .infinity)
                    }
                }
                HStack(spacing: 9) {
                    Text(cur.value)
                        .font(neon.mono(11).weight(.bold))
                        .foregroundStyle(tint)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(
                            Capsule().fill(tint.opacity(0.12))
                                .overlay(Capsule().strokeBorder(tint.opacity(0.4), lineWidth: 1))
                        )
                    Text(cur.desc)
                        .font(neon.sans(13))
                        .foregroundStyle(neon.textDim)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 13)
                .padding(.vertical, 11)
                .frame(maxWidth: .infinity, alignment: .leading)
                .neonCardSurface(neon, fill: neon.surface, cornerRadius: 12)
            }
            .animation(.easeInOut(duration: 0.18), value: effort)
        }

        private var modeSection: some View {
            VStack(alignment: .leading, spacing: 8) {
                sectionLabel("Mode")
                Picker("Mode", selection: $permissionMode) {
                    ForEach(ConduitUI.ForkOptions.permissionModes, id: \.self) { mode in
                        Text(ConduitUI.ForkOptions.permissionModeLabel(mode)).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .tint(neon.accent)
                Text("Plan = read-only; agent explores and proposes without editing.")
                    .font(neon.mono(10.5))
                    .foregroundStyle(neon.textFaint)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }

        private var recentSection: some View {
            VStack(alignment: .leading, spacing: 8) {
                sectionLabel("Recent")
                VStack(spacing: 6) {
                    ForEach(Array(store.recentDirectories.prefix(3)), id: \.self) { path in
                        Button {
                            onCreate(path, selectedModel, selectedEffort, selectedPermissionMode, selectedFastMode, nil)
                        } label: {
                            ConduitUI.ListRow(
                                icon: "clock.arrow.circlepath",
                                title: displayName(of: path),
                                subtitle: path,
                                iconTint: neon.accent
                            ) {
                                Image(systemName: "arrow.up.right")
                                    .font(.system(size: 12, weight: .semibold))
                                    .foregroundStyle(neon.accent)
                            }
                            .neonCardSurface(neon, fill: neon.surface, cornerRadius: 13)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .accessibilityIdentifier("ConduitDirectoryPicker.recent")
        }

        private var browseSection: some View {
            VStack(alignment: .leading, spacing: 8) {
                sectionLabel("Browse")
                breadcrumb
                // iOS-26.5 crash hardening (CONDUIT-IOS-N / -M). This subtree
                // must stay structurally STABLE. We previously swapped between
                // ProgressView / error Text / folderList with if·else·if; when
                // /api/fs/list returned and flipped @State, SwiftUI
                // restructured the tree *inside* the freshly-pushed picker's
                // CoreAnimation commit and corrupted the AttributeGraph →
                // crash in CA::Transaction::commit
                // (-[NSTaggedPointerString bounds]). Keeping all three
                // branches resident and toggling opacity means only opacity
                // changes; the view identity never moves.
                ZStack {
                    folderList
                        .opacity(isLoading || loadError != nil ? 0 : 1)
                    ProgressView()
                        .controlSize(.small)
                        .padding(.vertical, 24)
                        .opacity(isLoading ? 1 : 0)
                    Text(loadError ?? " ")
                        .font(neon.sans(13))
                        .foregroundStyle(neon.red)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.vertical, 16)
                        .opacity(loadError != nil ? 1 : 0)
                        .accessibilityHidden(loadError == nil)
                }
                .frame(maxWidth: .infinity)
            }
        }

        private var breadcrumb: some View {
            HStack(spacing: 8) {
                Button {
                    if let parent = listing?.parent, !parent.isEmpty,
                       parent != listing?.path {
                        currentPath = parent
                    }
                } label: {
                    Image(systemName: "chevron.up")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(canGoUp ? neon.accent : neon.textFaint)
                        .frame(width: 30, height: 30)
                        .background(Circle().fill(neon.surface))
                        .overlay(Circle().stroke(neon.border, lineWidth: 1))
                }
                .buttonStyle(.plain)
                .disabled(!canGoUp)

                Text(listing?.path ?? "…")
                    .font(neon.mono(12).weight(.medium))
                    .foregroundStyle(neon.textDim)
                    .lineLimit(1)
                    .truncationMode(.head)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }

        private var folderList: some View {
            let folders = (listing?.entries ?? []).filter { $0.is_dir }
            // Stable container (no empty/non-empty if·else swap — see
            // browseSection note). The "No sub-folders" copy is an opacity
            // overlay so the subtree shape never changes when the listing
            // lands inside the picker's CoreAnimation commit.
            return VStack(spacing: 6) {
                ForEach(folders) { entry in
                    Button {
                        currentPath = entry.path
                    } label: {
                        ConduitUI.navRow(icon: "folder", title: entry.name, iconTint: neon.accent)
                            .neonCardSurface(neon, fill: neon.surface, cornerRadius: 13)
                    }
                    .buttonStyle(.plain)
                }
            }
            .frame(maxWidth: .infinity, minHeight: folders.isEmpty ? 44 : nil)
            .overlay {
                Text("No sub-folders here.")
                    .font(neon.sans(13))
                    .foregroundStyle(neon.textDim)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .opacity(folders.isEmpty ? 1 : 0)
                    .accessibilityHidden(!folders.isEmpty)
            }
        }

        private var bottomBar: some View {
            VStack(spacing: 10) {
                if showHarnessChip {
                    harnessChip
                }
                if flags.newSessionLaunchLine {
                    launchLine
                }
                Button {
                    onCreate(listing?.path, selectedModel, selectedEffort, selectedPermissionMode, selectedFastMode, nil)
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "checkmark.circle.fill")
                        Text("Use this folder")
                    }
                    .font(neon.sans(15).weight(.semibold))
                    .foregroundStyle(neon.accentText)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 13)
                    .background(
                        RoundedRectangle(cornerRadius: 13, style: .continuous)
                            .fill(tint)
                    )
                    .neonGlowBox(neon.glow ? neon.glowBox?.tinted(tint) : nil)
                }
                .buttonStyle(.plain)
                .disabled(listing == nil)
                .opacity(listing == nil ? 0.5 : 1.0)

                Button {
                    onCreate(nil, selectedModel, selectedEffort, selectedPermissionMode, selectedFastMode, nil)
                } label: {
                    Text("Start without a folder")
                        .font(neon.sans(13).weight(.medium))
                        .foregroundStyle(neon.textDim)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 16)
            .padding(.top, 10)
            .padding(.bottom, 12)
            // Fully opaque docked bar. At 0.96 the browse list scrolled
            // visibly THROUGH the bar ("you can see the options under
            // 'Use this folder'", device feedback) — there's no blur
            // behind a safe-area inset to hide it, so the bar must be
            // solid. A hairline on top keeps it visually separated from
            // the scrolling content above.
            // ignoresSafeArea(.bottom) extends the solid fill through the
            // home-indicator gap to the physical screen edge so folder rows
            // can't peek through in the safe-area gutter below "Start without
            // a folder" (device feedback: "go" folder visible at the bottom).
            .background(
                neon.surfaceSolid
                    .overlay(alignment: .top) {
                        Rectangle()
                            .fill(neon.border)
                            .frame(height: 1)
                    }
                    .ignoresSafeArea(edges: .bottom)
            )
        }

        /// Live mono launch preview (§3, `04-ns`): `will run claude · medium ·
        /// <folder>`. Updates as the agent / effort / folder change.
        private var launchLine: some View {
            let folder = (listing?.path).map { displayName(of: $0) }
            return HStack(spacing: 0) {
                Text("will run ")
                    .foregroundStyle(neon.textFaint)
                Text(agentKind)
                    .foregroundStyle(tint)
                if let effortValue = selectedEffort {
                    Text(" · \(effortValue)")
                        .foregroundStyle(neon.textDim)
                }
                if let folder, !folder.isEmpty {
                    Text(" · \(folder)")
                        .foregroundStyle(neon.textDim)
                }
                Spacer(minLength: 0)
            }
            .font(neon.mono(11.5))
            .lineLimit(1)
            .truncationMode(.middle)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 2)
        }

        /// Part B: a tasteful, dismissible suggestion shown only when the
        /// chosen folder has neither CLAUDE.md nor AGENTS.md. Tapping seeds the
        /// session with the curated bootstrap prompt (audit repo → write
        /// CLAUDE.md + AGENTS.md with verified gates, ask before committing)
        /// and starts cd'd into the folder. An x dismisses it for the session.
        private var harnessChip: some View {
            HStack(spacing: 10) {
                Image(systemName: "wand.and.stars")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(tint)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Set up agent harness")
                        .font(neon.sans(13).weight(.semibold))
                        .foregroundStyle(neon.text)
                    Text("No CLAUDE.md or AGENTS.md here. Have the agent audit the repo and write them.")
                        .font(neon.mono(10.5))
                        .foregroundStyle(neon.textDim)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
                Button {
                    harnessChipDismissed = true
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(neon.textFaint)
                        .padding(6)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Dismiss harness suggestion")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(tint.opacity(0.10))
                    .overlay(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .strokeBorder(tint.opacity(0.35), lineWidth: 1)
                    )
            )
            .contentShape(Rectangle())
            .onTapGesture {
                onCreate(
                    listing?.path, selectedModel, selectedEffort,
                    selectedPermissionMode, selectedFastMode, SessionStore.harnessBootstrapPrompt)
            }
            .accessibilityIdentifier("ConduitDirectoryPicker.harnessChip")
        }

        // MARK: Helpers

        private var canGoUp: Bool {
            guard let listing else { return false }
            return !listing.parent.isEmpty && listing.parent != listing.path
        }

        private func sectionLabel(_ text: String, tint: Color? = nil) -> some View {
            Text(text.uppercased())
                .font(neon.mono(11).weight(.bold))
                .tracking(0.6)
                .foregroundStyle(tint ?? neon.textFaint)
        }

        private func displayName(of path: String) -> String {
            let trimmed = path.hasSuffix("/") ? String(path.dropLast()) : path
            let last = trimmed.split(separator: "/").last.map(String.init)
            return (last?.isEmpty == false ? last : nil) ?? trimmed
        }

        private func load() async {
            isLoading = true
            loadError = nil
            do {
                let result = try await store.listDirectories(path: currentPath)
                listing = result
                // Part B: refresh the harness check for the resolved path the
                // broker actually listed (currentPath may be nil = home).
                // Best-effort — nil leaves the chip hidden.
                harnessStatus = await store.harnessStatus(path: result.path)
            } catch {
                loadError = "Couldn't list this folder."
            }
            isLoading = false
        }

        /// Part B: show the "Set up agent harness" chip only when the broker
        /// confirmed BOTH CLAUDE.md and AGENTS.md are absent, and the user
        /// hasn't dismissed it for this session.
        private var showHarnessChip: Bool {
            guard let status = harnessStatus, !status.has_harness else { return false }
            return !harnessChipDismissed && listing != nil
        }
    }
}
