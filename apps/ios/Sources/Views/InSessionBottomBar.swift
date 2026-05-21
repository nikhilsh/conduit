import SwiftUI

/// Active-tab context for the in-session bottom bar. Drives where the
/// voice transcript is routed when the user taps the center mic FAB —
/// chat gets `sendChat`, terminal gets `sendInput` (line-terminated),
/// browser is the only tab where v1 still surfaces a "not wired here"
/// toast since no text-entry surface exists. Mirrors `ProjectTab` but
/// lives separately so the bar can be unit-tested without standing up
/// the SwiftUI view tree.
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

/// Per-tab routing for the global voice transcript. Lifted out of the
/// view body so unit tests can pin the matrix without standing up the
/// SwiftUI host. Stage 5 of `docs/PLAN-LITTER-UI.md` opens the mic FAB
/// on every tab; the routing decides where the resulting transcript
/// lands.
enum VoiceRoute: Equatable {
    /// Send as a chat message to the active session.
    case chat
    /// Append to the terminal stdin as a line (CR-terminated).
    case terminalInput
    /// No text-input surface — show the "not wired here" toast.
    case browserToast
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

    /// Whether the center mic FAB actually opens the voice dictation
    /// sheet for the supplied tab. Stage 5 opens the sheet on every
    /// tab — even browser, where the resulting transcript falls
    /// through to the "not wired here" toast inside the route
    /// handler. Kept around as a single-source-of-truth boolean in
    /// case a future tab wants to suppress the sheet entirely.
    static func voiceSupported(for context: InSessionContext) -> Bool {
        switch context {
        case .chat, .terminal, .browser: return true
        }
    }

    /// Per-tab routing matrix for the resulting transcript. Asserted
    /// by `VoiceDictationModelTests` so a refactor can't silently
    /// shrink the supported set. v1 wires chat + terminal; browser
    /// surfaces the toast.
    static func voiceRoute(for context: InSessionContext) -> VoiceRoute {
        switch context {
        case .chat:     return .chat
        case .terminal: return .terminalInput
        case .browser:  return .browserToast
        }
    }

    /// Message used by the toast / inline note when voice has no
    /// text-input surface to land in (browser tab). Mono-cased for
    /// parity with our other UI strings.
    static func voiceUnsupportedMessage(for context: InSessionContext) -> String {
        "Voice not wired here"
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
    /// Transient note rendered above the bar — used by ProjectView to
    /// surface the "Voice not wired here" toast after the browser-tab
    /// route handler short-circuits the transcript. Nil hides the
    /// capsule. Owned by the parent so the bar itself stays stateless
    /// and unit-testable as a pure layout.
    var transientNote: String? = nil

    var body: some View {
        VStack(spacing: 6) {
            if let note = transientNote {
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
    /// dominant voice affordance. Stage 5: always opens the voice
    /// dictation sheet regardless of tab; the parent view's
    /// transcript callback decides where to route the result. The
    /// `unsupportedNote` survives on the bar so a future tab that
    /// suppresses the sheet entirely can still fall back to a toast.
    private var voiceFab: some View {
        Button {
            onVoice()
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
