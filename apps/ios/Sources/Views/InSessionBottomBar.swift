import SwiftUI

/// Active-tab context for the in-session bottom bar. Drives where the
/// voice transcript is routed when the user taps the center mic FAB —
/// chat gets `sendChat`, terminal gets `sendInput` (line-terminated),
/// browser falls through to a "not supported" toast for v1. Mirrors
/// `ProjectTab` but lives separately so the bar can be unit-tested
/// without standing up the SwiftUI view tree.
enum InSessionContext: String, CaseIterable, Equatable {
    case terminal
    case chat
    case browser

    init(_ tab: ProjectTab) {
        switch tab {
        case .terminal: self = .terminal
        case .chat:     self = .chat
        case .browser:  self = .browser
        }
    }
}

/// Pure-data description of the in-session bottom bar. Three controls
/// in a fixed left → center → trailing order — `square.stack` (thread
/// switcher), `mic.fill` (voice FAB), `plus.circle.fill` (new session
/// on the same server). Lifted out of the SwiftUI view so the tests
/// in `InSessionBottomBarTests` can pin the three-control structure
/// without a host controller. Same pattern as PR B's
/// `ProjectHeaderModel`.
struct InSessionBottomBarModel: Equatable {
    enum Control: String, CaseIterable, Equatable {
        case threads
        case voice
        case newSession

        /// SF Symbol used in the rendered bar. Asserted by tests so a
        /// refactor can't quietly swap the affordance.
        var systemImage: String {
            switch self {
            case .threads:    return "square.stack"
            case .voice:      return "mic.fill"
            case .newSession: return "plus.circle.fill"
            }
        }

        /// Accessibility label for VoiceOver. Asserted by tests.
        var accessibilityLabel: String {
            switch self {
            case .threads:    return "Switch thread"
            case .voice:      return "Voice dictation"
            case .newSession: return "New session"
            }
        }
    }

    /// Render order: leading → center → trailing. Tests assert this
    /// exact triple so the litter HomeBottomBar visual parity holds.
    static let controls: [Control] = [.threads, .voice, .newSession]

    /// Whether the center mic FAB is wired to the existing voice path
    /// for the supplied tab context. Per the spec: v1 supports chat
    /// only; terminal / browser surface a toast instead. Tests assert
    /// the routing table so a future refactor can't silently broaden
    /// or shrink the supported set.
    static func voiceSupported(for context: InSessionContext) -> Bool {
        switch context {
        case .chat:                  return true
        case .terminal, .browser:    return false
        }
    }

    /// Message used by the toast / inline note when voice isn't wired
    /// for the current tab. Mono-cased for parity with our other UI
    /// strings.
    static func voiceUnsupportedMessage(for context: InSessionContext) -> String {
        "Voice not supported here"
    }
}

/// Persistent in-session bottom dock — visible across the Terminal /
/// Chat / Browser tabs so the user always has the same three controls
/// at thumb-reach: switch parallel sessions on this server (left),
/// fire voice dictation into the active tab (center), or spin up
/// another session on the same server (right). Mirrors litter's
/// `HomeBottomBar`, but scoped to within a session — `BottomActionBar`
/// already covers the home surface.
struct InSessionBottomBar: View {
    let context: InSessionContext
    let onThreads: () -> Void
    let onVoice: () -> Void
    let onNewSession: () -> Void

    /// One-shot transient message surfaced when the user taps voice
    /// on an unsupported tab. Cleared after a short delay so the bar
    /// goes back to its three-icon resting state.
    @State private var unsupportedNote: String?

    var body: some View {
        VStack(spacing: 6) {
            if let note = unsupportedNote {
                Text(note)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(SweKittyTheme.textPrimary)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .glassCapsule(tint: SweKittyTheme.warning.opacity(0.34))
                    .transition(.opacity)
                    .accessibilityIdentifier("InSessionBottomBar.voiceUnsupported")
            }

            HStack(spacing: 14) {
                threadsButton
                Spacer()
                voiceFab
                Spacer()
                newSessionButton
            }
            .padding(.horizontal, 22)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity)
            // Glass capsule mirrors litter's HomeBottomBar dock shape —
            // the row is wide enough that the capsule's pill ends read
            // as soft shoulders, not aggressive ovals.
            .glassCapsule(tint: SweKittyTheme.surface.opacity(0.55))
            .padding(.horizontal, 14)
            .padding(.bottom, 6)
        }
    }

    private var threadsButton: some View {
        Button(action: onThreads) {
            Image(systemName: InSessionBottomBarModel.Control.threads.systemImage)
                .font(.title3.weight(.semibold))
                .foregroundStyle(SweKittyTheme.textPrimary)
                .frame(width: 44, height: 44)
                .glassCircle(tint: SweKittyTheme.surface.opacity(0.7))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(InSessionBottomBarModel.Control.threads.accessibilityLabel)
    }

    /// Center mic FAB — bigger and copper-accented to match litter's
    /// dominant voice affordance. Tap routes to `onVoice` when the
    /// tab supports voice, otherwise surfaces the "not supported" note
    /// so the user gets feedback instead of a no-op.
    private var voiceFab: some View {
        Button {
            if InSessionBottomBarModel.voiceSupported(for: context) {
                onVoice()
            } else {
                let msg = InSessionBottomBarModel.voiceUnsupportedMessage(for: context)
                withAnimation(.easeInOut(duration: 0.15)) {
                    unsupportedNote = msg
                }
                Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 1_800_000_000)
                    withAnimation(.easeInOut(duration: 0.2)) {
                        unsupportedNote = nil
                    }
                }
            }
        } label: {
            Image(systemName: InSessionBottomBarModel.Control.voice.systemImage)
                .font(.title.weight(.bold))
                .foregroundStyle(SweKittyTheme.textOnAccent)
                .frame(width: 60, height: 60)
                .background(
                    Circle()
                        .fill(SweKittyTheme.accentStrong)
                )
                .overlay(
                    Circle()
                        .stroke(SweKittyTheme.accentStrong.opacity(0.55), lineWidth: 3)
                        .blur(radius: 2)
                )
        }
        .buttonStyle(.plain)
        .accessibilityLabel(InSessionBottomBarModel.Control.voice.accessibilityLabel)
    }

    private var newSessionButton: some View {
        Button(action: onNewSession) {
            Image(systemName: InSessionBottomBarModel.Control.newSession.systemImage)
                .font(.title2.weight(.semibold))
                .foregroundStyle(SweKittyTheme.accentStrong)
                .frame(width: 44, height: 44)
                .glassCircle(tint: SweKittyTheme.surface.opacity(0.7))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(InSessionBottomBarModel.Control.newSession.accessibilityLabel)
    }
}
