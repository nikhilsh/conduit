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

    @Test func voiceWiredOnChatTabOnly() {
        // v1 spec: voice routes to `sendChat` when the user is on
        // the chat tab; terminal and browser surface a "not
        // supported" toast instead. Centralising the routing
        // matrix in the model means the SwiftUI button has nothing
        // to decide — it just asks.
        #expect(InSessionBottomBarModel.voiceSupported(for: .chat))
        #expect(!InSessionBottomBarModel.voiceSupported(for: .terminal))
        #expect(!InSessionBottomBarModel.voiceSupported(for: .browser))
    }

    @Test func voiceUnsupportedMessageIsActionable() {
        // The toast string itself is part of the contract — the
        // user needs to know what to do (or that the feature isn't
        // wired yet). Pin it so an accidental copy edit doesn't
        // turn it into a no-op nag.
        let terminalMsg = InSessionBottomBarModel.voiceUnsupportedMessage(for: .terminal)
        let browserMsg = InSessionBottomBarModel.voiceUnsupportedMessage(for: .browser)
        #expect(terminalMsg == "Voice not supported here")
        #expect(browserMsg == "Voice not supported here")
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
