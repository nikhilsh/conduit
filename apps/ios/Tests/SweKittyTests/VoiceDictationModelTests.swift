import Testing
import Foundation
@testable import SweKitty

/// Stage 5 — global voice dictation routing matrix. The mic FAB on
/// `InSessionBottomBar` now opens `VoiceDictationSheet` regardless of
/// tab; the resulting transcript routes via
/// `InSessionBottomBarModel.voiceRoute(for:)` to the right surface
/// (chat → `sendChat`, terminal → `sendInput`, browser → toast).
///
/// Pinning the matrix here so a future refactor can't silently
/// regress one of the routes. Same pattern as `ProjectHeaderModel` /
/// `ServerPillModel`: pure-data assertions, no SwiftUI host.
@Suite("VoiceDictationModel — per-tab routing matrix")
struct VoiceDictationModelTests {

    // MARK: - Sheet opens on every tab

    @Test func voiceSheetOpensOnEveryTab() {
        // Stage 5 spec: the FAB opens the sheet on chat / terminal /
        // browser. Terminal is no longer behind a "not supported"
        // toast pre-sheet. Browser still surfaces the toast — but
        // that happens inside the route handler, not before the sheet
        // opens.
        #expect(InSessionBottomBarModel.voiceSupported(for: .chat))
        #expect(InSessionBottomBarModel.voiceSupported(for: .terminal))
        #expect(InSessionBottomBarModel.voiceSupported(for: .browser))
    }

    // MARK: - Routing matrix

    @Test func chatRoutesToSendChat() {
        // Chat tab — transcript becomes a chat message via
        // `SessionStore.sendChat`. This is the canonical "speak to
        // reply" path inherited from `InlineVoiceButton`.
        #expect(InSessionBottomBarModel.voiceRoute(for: .chat) == .chat)
    }

    @Test func terminalRoutesToTerminalInput() {
        // Terminal tab — transcript becomes a line-terminated stdin
        // write via `SessionStore.sendInput`. The old "Voice not
        // supported here" toast is gone; terminal is now a
        // first-class voice surface.
        #expect(InSessionBottomBarModel.voiceRoute(for: .terminal) == .terminalInput)
    }

    @Test func browserRoutesToToast() {
        // Browser tab — no text-input surface in v1, so the route
        // handler surfaces the "Voice not wired here" toast rather
        // than dropping the transcript on the floor.
        #expect(InSessionBottomBarModel.voiceRoute(for: .browser) == .browserToast)
    }

    @Test func toastMessageHasNotWiredCopy() {
        // Pin the string so a copy edit can't turn it into a no-op
        // nag. "Not wired here" matches the Stage 5 spec, replacing
        // the prior "Not supported here" since terminal *is* now
        // wired (just not browser).
        #expect(
            InSessionBottomBarModel.voiceUnsupportedMessage(for: .browser)
                == "Voice not wired here"
        )
    }

    // MARK: - Context ⇄ ProjectTab bridge

    @Test func eachProjectTabHasExactlyOneRoute() {
        // Exhaustive check: every ProjectTab maps to a VoiceRoute via
        // InSessionContext. A future fourth tab would break the
        // switch and surface here at compile time.
        for tab in ProjectTab.allCases {
            let ctx = InSessionContext(tab)
            let route = InSessionBottomBarModel.voiceRoute(for: ctx)
            #expect([.chat, .terminalInput, .browserToast].contains(route))
        }
    }

    @Test func voiceRoutesArePartitionedAcrossTabs() {
        // No two tabs share a route — the matrix is a bijection so a
        // refactor that maps two tabs to the same destination is loud.
        let routes = InSessionContext.allCases.map(InSessionBottomBarModel.voiceRoute(for:))
        #expect(Set(routes).count == routes.count)
    }
}
