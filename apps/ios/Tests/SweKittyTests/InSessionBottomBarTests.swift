import Testing
import Foundation
@testable import SweKitty

/// `litter-multi-thread` — persistent in-session bottom bar shape.
/// Mirrors PR B's `ProjectHeaderModel` pattern: assert against the
/// pure-data `InSessionBottomBarModel` rather than hosting the
/// SwiftUI body, so the three-control layout + per-tab voice routing
/// are pinned without a UI test rig.
@Suite("InSessionBottomBar — three-control dock")
struct InSessionBottomBarTests {

    // MARK: - Three-control structure

    @Test func dockHasThreeControlsInOrder() {
        // litter's HomeBottomBar parity: leading thread-switcher,
        // centre voice FAB, trailing new-session button. Drift here
        // means the visual reference is broken.
        #expect(InSessionBottomBarModel.controls == [.threads, .voice, .newSession])
        #expect(InSessionBottomBarModel.controls.count == 3)
    }

    @Test func eachControlUsesItsSpecSFSymbol() {
        // Pin the SF Symbols so a refactor can't silently swap
        // `square.stack` for `rectangle.stack` (subtly different
        // glyph in iOS 18) or downgrade the voice FAB icon.
        #expect(InSessionBottomBarModel.Control.threads.systemImage == "square.stack")
        #expect(InSessionBottomBarModel.Control.voice.systemImage == "mic.fill")
        #expect(InSessionBottomBarModel.Control.newSession.systemImage == "plus.circle.fill")
    }

    @Test func eachControlExposesVoiceOverLabel() {
        // VoiceOver labels are a regression-prone surface — assert
        // them explicitly so a string-table refactor can't strip
        // them.
        #expect(InSessionBottomBarModel.Control.threads.accessibilityLabel == "Switch thread")
        #expect(InSessionBottomBarModel.Control.voice.accessibilityLabel == "Voice dictation")
        #expect(InSessionBottomBarModel.Control.newSession.accessibilityLabel == "New session")
    }

    // MARK: - Per-tab voice routing

    @Test func voiceSheetOpensFromEveryTab() {
        // Stage 5 spec: the FAB opens the voice dictation sheet on
        // every tab — chat, terminal, browser. The actual routing
        // (chat → sendChat, terminal → sendInput, browser → toast)
        // happens inside `VoiceRoute`; see VoiceDictationModelTests
        // for the per-route matrix.
        #expect(InSessionBottomBarModel.voiceSupported(for: .chat))
        #expect(InSessionBottomBarModel.voiceSupported(for: .terminal))
        #expect(InSessionBottomBarModel.voiceSupported(for: .browser))
    }

    @Test func voiceUnsupportedMessageReflectsBrowserOnlyToast() {
        // The "not wired here" toast now only fires on browser —
        // terminal got promoted to a first-class voice surface in
        // Stage 5. Pin the string so a copy edit can't turn it back
        // into a no-op nag for terminal.
        let browserMsg = InSessionBottomBarModel.voiceUnsupportedMessage(for: .browser)
        #expect(browserMsg == "Voice not wired here")
    }

    // MARK: - ProjectTab → InSessionContext bridge

    @Test func inSessionContextMatchesProjectTab() {
        // The bottom bar lives next to the existing ProjectTab
        // segmented picker — the bridge between them must round-trip
        // cleanly so the active-tab signal doesn't drift if a future
        // refactor renames either enum.
        #expect(InSessionContext(.terminal) == .terminal)
        #expect(InSessionContext(.chat) == .chat)
        #expect(InSessionContext(.browser) == .browser)
    }

    @Test func allProjectTabsHaveAContext() {
        // Defensive: every ProjectTab case maps to an InSessionContext
        // case. If someone adds a fourth tab without updating the
        // bridge this would crash at runtime — this test catches it
        // at compile time via exhaustive switch.
        for tab in ProjectTab.allCases {
            let ctx = InSessionContext(tab)
            #expect(InSessionContext.allCases.contains(ctx))
        }
    }
}
