import Testing
import Foundation
@testable import SweKitty

/// AI-generated quick replies (task #233): the broker emits a
/// `view:"quick_replies"` view_event the core flattens into an
/// `on_view_event` payload (`replies` as a JSON-array string,
/// `for_message_id` plain). These pin the decode + the store's
/// ingest/clear lifecycle so the composer chips render the broker's
/// suggestions and drop them on the next turn / on send.
@Suite("AIQuickReplies")
@MainActor
struct AIQuickRepliesTests {

    @Test func decodesRepliesAndMessageID() {
        let qr = AIQuickReplies.from(payload: [
            "replies": #"["Yes, go ahead","No","Tell me more"]"#,
            "for_message_id": "msg-7",
        ])
        #expect(qr?.replies == ["Yes, go ahead", "No", "Tell me more"])
        #expect(qr?.forMessageID == "msg-7")
    }

    @Test func trimsEmptiesAndCapsAtFour() {
        let qr = AIQuickReplies.from(payload: [
            "replies": #"["  Run it  ","","A","B","C","D","E"]"#
        ])
        // Whitespace trimmed, empties dropped, capped to 4.
        #expect(qr?.replies == ["Run it", "A", "B", "C"])
        // Missing for_message_id defaults to empty.
        #expect(qr?.forMessageID == "")
    }

    @Test func returnsNilOnUnusablePayload() {
        #expect(AIQuickReplies.from(payload: [:]) == nil)
        #expect(AIQuickReplies.from(payload: ["replies": "[]"]) == nil)
        #expect(AIQuickReplies.from(payload: ["replies": "not json"]) == nil)
        #expect(AIQuickReplies.from(payload: ["replies": #"["   ",""]"#]) == nil)
    }

    @Test func ingestStoresAndOverwrites() {
        let store = SessionStore()
        let sid = "qr-\(UUID().uuidString)"

        store.ingestQuickReplies(sid, payload: ["replies": #"["A","B"]"#, "for_message_id": "m1"])
        #expect(store.quickReplies[sid]?.replies == ["A", "B"])

        // A newer set replaces the prior one.
        store.ingestQuickReplies(sid, payload: ["replies": #"["C"]"#, "for_message_id": "m2"])
        #expect(store.quickReplies[sid]?.replies == ["C"])
        #expect(store.quickReplies[sid]?.forMessageID == "m2")
    }

    @Test func unusablePayloadClearsChips() {
        let store = SessionStore()
        let sid = "qr-\(UUID().uuidString)"
        store.ingestQuickReplies(sid, payload: ["replies": #"["A"]"#])
        #expect(store.quickReplies[sid] != nil)

        store.ingestQuickReplies(sid, payload: ["replies": "[]"])
        #expect(store.quickReplies[sid] == nil)
    }

    @Test func freshAssistantTurnClearsChips() {
        let store = SessionStore()
        let sid = "qr-\(UUID().uuidString)"
        store.ingestQuickReplies(sid, payload: ["replies": #"["A","B"]"#])
        #expect(store.quickReplies[sid] != nil)

        // A new assistant chat event invalidates the prior turn's chips.
        store.ingestChat(sid, ChatEvent(role: "assistant", content: "next", ts: "1", files: []))
        #expect(store.quickReplies[sid] == nil)
    }

    @Test func sendClearsChips() {
        let store = SessionStore()
        let sid = "qr-\(UUID().uuidString)"
        store.ingestQuickReplies(sid, payload: ["replies": #"["A","B"]"#])
        #expect(store.quickReplies[sid] != nil)

        // Sending the user's reply clears the chips (no client transport
        // needed — sendChat materializes the local echo first).
        store.sendChat(sessionID: sid, message: "A")
        #expect(store.quickReplies[sid] == nil)
    }
}
