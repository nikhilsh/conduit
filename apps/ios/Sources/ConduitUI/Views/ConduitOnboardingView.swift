import SwiftUI

// MARK: - ConduitOnboardingView (handoff §5 / onb-flow.jsx)
//
// First-run onboarding: Welcome → Install the broker → Pair → Done. Gated
// on LIVE broker state by the caller (see RootView's onboarding gate); this
// view owns only the step flow + the pairing handoff. The "Guide me / I know
// my way" switch scales the hand-holding. Step + seenWelcome are persisted in
// FeatureFlags so a quit mid-setup resumes at the furthest incomplete step
// and Welcome shows once ever.
//
// Pairing reuses the existing primitives (QR scan / manual URL+token /
// mDNS discovery) — the same paths `AddServerSheet` drives — and advances to
// Done the moment a server is saved.

extension ConduitUI {
    struct OnboardingView: View {
        @Environment(SessionStore.self) private var store
        @Environment(FeatureFlags.self) private var flags
        @Environment(\.neonTheme) private var neon

        /// Called when the user finishes (or "Start your first session").
        var onFinish: () -> Void

        @State private var step: Int = FeatureFlags.OnboardingStep.welcome.rawValue
        @State private var didResolveInitialStep = false

        private typealias Step = FeatureFlags.OnboardingStep

        var body: some View {
            ZStack {
                neon.appBg.ignoresSafeArea()
                VStack(spacing: 0) {
                    topBar
                    if step < Step.done.rawValue {
                        progress
                    }
                    Group {
                        switch Step(rawValue: step) ?? .welcome {
                        case .welcome: welcomeStep
                        case .install: installStep
                        case .pair:    pairStep
                        case .done:    doneStep
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .tint(neon.accent)
            .onAppear(perform: resolveInitialStep)
            // Pairing succeeded somewhere (QR / manual / discovery / deep
            // link): a saved server now exists → advance to Done.
            .onChange(of: store.savedServers.count) { _, count in
                if count > 0, step <= Step.pair.rawValue {
                    go(to: .done)
                }
            }
        }

        // MARK: Step resolution / persistence

        private func resolveInitialStep() {
            guard !didResolveInitialStep else { return }
            didResolveInitialStep = true
            let route = FeatureFlags.onboardingRoute(
                signedIn: true,
                machines: store.savedServers.count,
                linkedHere: !store.savedServers.isEmpty,
                brokerReachable: store.harness.canIssueCommands
            )
            step = flags.onboardingInitialStep(for: route)
            if step == Step.welcome.rawValue { flags.onboardingSeenWelcome = true }
        }

        private func go(to target: Step) {
            withAnimation(.easeInOut(duration: 0.2)) { step = target.rawValue }
            flags.onboardingFurthestStep = max(flags.onboardingFurthestStep, target.rawValue)
            if target == .welcome { flags.onboardingSeenWelcome = true }
        }

        // MARK: Chrome

        private var topBar: some View {
            HStack {
                if step > Step.welcome.rawValue && step < Step.done.rawValue {
                    Button {
                        go(to: Step(rawValue: step - 1) ?? .welcome)
                    } label: {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 15, weight: .bold))
                            .foregroundStyle(neon.textDim)
                            .frame(width: 34, height: 34)
                            .background(Circle().fill(neon.surface))
                            .overlay(Circle().strokeBorder(neon.border, lineWidth: 1))
                    }
                    .buttonStyle(.plain)
                } else {
                    Color.clear.frame(width: 34, height: 34)
                }
                Spacer()
                if step < Step.done.rawValue {
                    guideSwitch
                }
                Spacer()
                Color.clear.frame(width: 34, height: 34)
            }
            .padding(.horizontal, 20)
            .padding(.top, 8)
            .padding(.bottom, 10)
        }

        private var guideSwitch: some View {
            @Bindable var flags = flags
            return HStack(spacing: 4) {
                ForEach([true, false], id: \.self) { isGuide in
                    let on = flags.onboardingGuide == isGuide
                    Button {
                        flags.onboardingGuide = isGuide
                    } label: {
                        Text(isGuide ? "Guide me" : "I know my way")
                            .font(neon.mono(11.5).weight(.bold))
                            .foregroundStyle(on ? neon.text : neon.textFaint)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .background(
                                Capsule().fill(on ? neon.surface2 : Color.clear)
                            )
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(4)
            .background(Capsule().fill(neon.surface).overlay(Capsule().strokeBorder(neon.border, lineWidth: 1)))
        }

        private var progress: some View {
            let labels = ["Welcome", "Install", "Pair"]
            let current = min(step, Step.pair.rawValue)
            return HStack(spacing: 7) {
                ForEach(Array(labels.enumerated()), id: \.offset) { i, label in
                    VStack(alignment: .leading, spacing: 6) {
                        Capsule()
                            .fill(i <= current
                                  ? AnyShapeStyle(LinearGradient(colors: [neon.codex, neon.green], startPoint: .leading, endPoint: .trailing))
                                  : AnyShapeStyle(neon.border))
                            .frame(height: 3)
                        Text("\(i + 1) \(label)")
                            .font(neon.mono(10))
                            .foregroundStyle(i == current ? neon.codex : (i < current ? neon.textDim : neon.textFaint))
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(.horizontal, 22)
            .padding(.bottom, 6)
        }

        // MARK: Step 1 — Welcome

        private var welcomeStep: some View {
            VStack(spacing: 26) {
                Spacer()
                VStack(spacing: 20) {
                    ConduitUI.ConduitMark(size: 62, glow: neon.glow)
                        .frame(width: 96, height: 96)
                        .background(
                            RoundedRectangle(cornerRadius: 26, style: .continuous)
                                .fill(Color.white.opacity(0.03))
                                .overlay(RoundedRectangle(cornerRadius: 26, style: .continuous).strokeBorder(neon.border, lineWidth: 1.5))
                        )
                    VStack(spacing: 10) {
                        (Text(">").foregroundColor(neon.codex) + Text("conduit").foregroundColor(neon.text))
                            .font(neon.mono(30).weight(.heavy))
                        Text("Your agents, in your pocket.")
                            .font(neon.sans(20))
                            .foregroundStyle(neon.textDim)
                    }
                }
                Text("Pair a machine, start a session, and drive Claude or Codex from anywhere.")
                    .font(neon.sans(16))
                    .foregroundStyle(neon.textDim)
                    .multilineTextAlignment(.center)
                    .lineSpacing(5)
                    .padding(.horizontal, 28)
                Spacer()
                VStack(spacing: 11) {
                    primaryCTA("Pair a machine", icon: "chevron.right") { go(to: .install) }
                    Button { go(to: .pair) } label: {
                        (Text("Already running a broker?  ").foregroundColor(neon.textFaint)
                         + Text("Enter a code →").foregroundColor(neon.codex))
                            .font(neon.mono(13))
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 28)
                .padding(.bottom, 24)
            }
        }

        // MARK: Step 2 — Install the broker

        @State private var platform: InstallPlatform = .mac
        @State private var copied = false

        private var installStep: some View {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    eyebrow("STEP 2 · THE BROKER", tint: neon.codex)
                    Text("Run the broker on your machine")
                        .font(neon.sans(26).weight(.semibold))
                        .foregroundStyle(neon.text)
                    if flags.onboardingGuide {
                        helper(tint: neon.codex) {
                            Text("The ") + Text("broker").bold().foregroundColor(neon.text)
                            + Text(" is a tiny program that runs on the computer your code lives on — your Mac, a dev box, or a cloud VPS. Conduit talks to it so your agents run on your hardware.")
                        }
                    }
                    sectionMini("WHERE WILL IT RUN?")
                    HStack(spacing: 8) {
                        ForEach(InstallPlatform.allCases) { p in
                            let on = p == platform
                            Button { platform = p } label: {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(p.label)
                                        .font(neon.mono(13.5).weight(.bold))
                                        .foregroundStyle(on ? neon.codex : neon.text)
                                    Text(p.sub)
                                        .font(neon.mono(10.5))
                                        .foregroundStyle(neon.textFaint)
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 11)
                                .background(
                                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                                        .fill(on ? neon.codex.opacity(0.10) : neon.surface)
                                        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(on ? neon.codex.opacity(0.5) : neon.border, lineWidth: 1))
                                )
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    sectionMini("PASTE THIS INTO ITS TERMINAL")
                    VStack(spacing: 0) {
                        HStack(alignment: .top, spacing: 6) {
                            Text("$")
                                .font(neon.mono(12.7))
                                .foregroundStyle(neon.green)
                            Text(platform.command)
                                .font(neon.mono(12.7))
                                .foregroundStyle(neon.text)
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 13)
                        Button {
                            UIPasteboard.general.string = platform.command
                            copied = true
                            DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) { copied = false }
                        } label: {
                            HStack(spacing: 7) {
                                Image(systemName: copied ? "checkmark" : "doc.on.doc")
                                Text(copied ? "Copied" : "Copy command")
                            }
                            .font(neon.mono(12.5).weight(.bold))
                            .foregroundStyle(copied ? neon.green : neon.codex)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 10)
                            .overlay(alignment: .top) { Rectangle().fill(neon.border).frame(height: 1) }
                        }
                        .buttonStyle(.plain)
                    }
                    .background(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(neon.codeBg)
                            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(neon.border, lineWidth: 1))
                    )
                    if flags.onboardingGuide {
                        Text("No machine yet?  Spin up a $5 VPS →")
                            .font(neon.mono(12.5))
                            .foregroundStyle(neon.textFaint)
                    }
                    primaryCTA("I ran it — find my broker", icon: "chevron.right") { go(to: .pair) }
                        .padding(.top, 4)
                }
                .padding(.horizontal, 24)
                .padding(.bottom, 24)
            }
        }

        // MARK: Step 3 — Pair

        @State private var showScanner = false
        @State private var showManual = false
        @State private var showDiscover = false

        private var pairStep: some View {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    eyebrow("STEP 3 · PAIR", tint: neon.green)
                    Text("Pair this phone")
                        .font(neon.sans(26).weight(.semibold))
                        .foregroundStyle(neon.text)
                    if flags.onboardingGuide {
                        helper(tint: neon.green) {
                            Text("When the broker starts it prints a pairing QR and a ws:// URL + token. Scan the QR, or paste the URL — that proves the phone and the machine are yours.")
                        }
                    }
                    pairOption(icon: "qrcode.viewfinder", title: "Scan pairing QR",
                               subtitle: "Camera-scan the QR from the broker terminal.") { showScanner = true }
                    pairOption(icon: "wifi.circle", title: "Discover on LAN",
                               subtitle: "Find a broker advertising on the same Wi-Fi.") { showDiscover = true }
                    pairOption(icon: "link", title: "Enter URL + token",
                               subtitle: "Paste ws://… and the bearer token by hand.") { showManual = true }
                }
                .padding(.horizontal, 24)
                .padding(.bottom, 24)
            }
            .sheet(isPresented: $showScanner) {
                QRScannerSheet { code in
                    if let parsed = PairingURL.parse(code) {
                        applyPairing(endpoint: parsed.endpoint, token: parsed.token)
                    }
                    showScanner = false
                }
            }
            // (DiscoveryView / ConduitManualPairSheet set the endpoint +
            // saved server themselves; the .onChange on savedServers.count
            // advances us to Done.)
            .sheet(isPresented: $showDiscover) {
                ConduitUI.DiscoveryView().environment(store)
            }
            .sheet(isPresented: $showManual) {
                ConduitManualPairSheet().environment(store)
            }
        }

        private func applyPairing(endpoint: String, token: String) {
            let next = StoredEndpoint(url: endpoint, token: token)
            store.endpoint = next
            store.upsertSavedServer(name: next.displayHost, endpoint: next, makeDefault: true)
            store.disconnect()
            store.connect()
            // savedServers count change advances us to Done via .onChange.
        }

        // MARK: Step 4 — Done

        private var doneStep: some View {
            VStack(spacing: 24) {
                Spacer()
                ConduitUI.ConduitMark(size: 66, glow: neon.glow)
                    .frame(width: 104, height: 104)
                    .background(
                        RoundedRectangle(cornerRadius: 28, style: .continuous)
                            .fill(neon.green.opacity(0.10))
                            .overlay(RoundedRectangle(cornerRadius: 28, style: .continuous).strokeBorder(neon.green.opacity(0.5), lineWidth: 1.5))
                    )
                    .overlay(alignment: .bottomTrailing) {
                        Image(systemName: "checkmark")
                            .font(.system(size: 16, weight: .bold))
                            .foregroundStyle(neon.accentText)
                            .frame(width: 34, height: 34)
                            .background(Circle().fill(neon.green))
                            .offset(x: 6, y: 6)
                    }
                VStack(spacing: 8) {
                    eyebrow("PAIRED", tint: neon.green)
                    Text("You're in.")
                        .font(neon.sans(28).weight(.semibold))
                        .foregroundStyle(neon.text)
                    Text("Claude and Codex are ready when you are.")
                        .font(neon.sans(16))
                        .foregroundStyle(neon.textDim)
                        .multilineTextAlignment(.center)
                }
                HStack(spacing: 8) {
                    agentChip("claude", tint: neon.claude)
                    agentChip("codex", tint: neon.codex)
                }
                Spacer()
                primaryCTA("Start your first session", icon: "chevron.right") {
                    flags.onboardingFurthestStep = Step.done.rawValue
                    onFinish()
                }
                .padding(.horizontal, 28)
                .padding(.bottom, 24)
            }
        }

        // MARK: Reusable bits

        private func primaryCTA(_ title: String, icon: String, action: @escaping () -> Void) -> some View {
            Button(action: action) {
                HStack(spacing: 9) {
                    Text(title)
                    Image(systemName: icon).font(.system(size: 15, weight: .bold))
                }
                .font(neon.mono(15.5).weight(.bold))
                .foregroundStyle(neon.accentText)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 15)
                .background(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(LinearGradient(colors: [neon.codex, neon.green], startPoint: .leading, endPoint: .trailing))
                )
                .neonGlowBox(neon.glow ? neon.glowBox?.tinted(neon.codex) : nil)
            }
            .buttonStyle(.plain)
        }

        private func pairOption(icon: String, title: String, subtitle: String, action: @escaping () -> Void) -> some View {
            Button(action: action) {
                HStack(spacing: 14) {
                    Image(systemName: icon)
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundStyle(neon.accent)
                        .frame(width: 30)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(title)
                            .font(neon.sans(14).weight(.semibold))
                            .foregroundStyle(neon.text)
                        Text(subtitle)
                            .font(neon.sans(11.5))
                            .foregroundStyle(neon.textDim)
                            .lineLimit(2)
                    }
                    Spacer(minLength: 8)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(neon.textFaint)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 13)
                .neonCardSurface(neon, fill: neon.surface, cornerRadius: 14)
            }
            .buttonStyle(.plain)
        }

        private func eyebrow(_ text: String, tint: Color) -> some View {
            Text(text)
                .font(neon.mono(12).weight(.bold))
                .tracking(2)
                .foregroundStyle(tint)
                .frame(maxWidth: .infinity, alignment: .leading)
        }

        private func sectionMini(_ text: String) -> some View {
            Text(text)
                .font(neon.mono(11).weight(.bold))
                .tracking(1)
                .foregroundStyle(neon.textFaint)
        }

        private func helper<C: View>(tint: Color, @ViewBuilder _ content: () -> C) -> some View {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "bolt.fill")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(tint)
                    .padding(.top, 2)
                content()
                    .font(neon.sans(15))
                    .foregroundStyle(neon.textDim)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(tint.opacity(0.06))
                    .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(tint.opacity(0.18), lineWidth: 1))
            )
        }

        private func agentChip(_ name: String, tint: Color) -> some View {
            Text("● \(name)")
                .font(neon.mono(12))
                .foregroundStyle(tint)
                .padding(.horizontal, 11)
                .padding(.vertical, 6)
                .background(
                    Capsule().fill(tint.opacity(0.14))
                        .overlay(Capsule().strokeBorder(tint.opacity(0.4), lineWidth: 1))
                )
        }
    }

    /// Install platforms for the broker (§5, `02-onb`).
    enum InstallPlatform: String, CaseIterable, Identifiable {
        case mac, linux, vps
        var id: String { rawValue }
        var label: String {
            switch self {
            case .mac:   return "macOS"
            case .linux: return "Linux"
            case .vps:   return "Cloud VPS"
            }
        }
        var sub: String {
            switch self {
            case .mac:   return "your laptop"
            case .linux: return "a dev box"
            case .vps:   return "rented server"
            }
        }
        var command: String {
            switch self {
            case .mac, .linux: return "curl -fsSL https://conduit.sh | sh"
            case .vps:         return "ssh root@your-vps \"curl -fsSL https://conduit.sh | sh\""
            }
        }
    }
}
