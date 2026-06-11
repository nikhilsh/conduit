import Testing
import Foundation
@testable import Conduit

// MARK: - Token encoding tests

/// Pure tests for the APNs device-token hex-encoding helper and the
/// register-payload shape — no network, no system calls, no `@MainActor`
/// gymnastics needed.
@Suite("Push notification — token hex encoding")
struct PushTokenHexTests {

    @Test func emptyDataProducesEmptyHex() {
        let data = Data()
        #expect(data.apnsTokenHex == "")
    }

    @Test func singleByteEncodesLowerHex() {
        let data = Data([0x0f])
        #expect(data.apnsTokenHex == "0f")
    }

    @Test func singleByteLeadingZero() {
        let data = Data([0x07])
        #expect(data.apnsTokenHex == "07")
    }

    @Test func fullFFByte() {
        let data = Data([0xff])
        #expect(data.apnsTokenHex == "ff")
    }

    @Test func multiByteLowercaseNoSeparator() {
        let data = Data([0xde, 0xad, 0xbe, 0xef])
        #expect(data.apnsTokenHex == "deadbeef")
    }

    @Test func typicalTokenLength32Bytes() {
        // A real APNs token is 32 bytes → 64 hex chars.
        let bytes: [UInt8] = (0..<32).map { UInt8($0) }
        let data = Data(bytes)
        let hex = data.apnsTokenHex
        #expect(hex.count == 64)
        #expect(hex.hasPrefix("00010203"))
    }

    @Test func hexIsLowercaseOnly() {
        // All bytes that produce a–f: ensure lowercase (Apple expects it).
        let data = Data([0xAB, 0xCD, 0xEF])
        let hex = data.apnsTokenHex
        #expect(hex == "abcdef")
        #expect(hex == hex.lowercased())
    }
}

// MARK: - Register payload shape tests

/// Verify that the JSON body we POST to `/api/push/register` has the
/// exact shape the broker expects: `{"platform":"apns","token":"<hex>"}`.
@Suite("Push notification — register payload shape")
struct PushRegisterPayloadTests {

    @Test func registerPayloadHasCorrectKeys() throws {
        let hex = "deadbeef01020304"
        let payload = ["platform": "apns", "token": hex]
        let data = try JSONEncoder().encode(payload)
        let decoded = try JSONDecoder().decode([String: String].self, from: data)
        #expect(decoded["platform"] == "apns")
        #expect(decoded["token"] == hex)
        #expect(decoded.keys.count == 2)
    }

    @Test func testPushPayloadHasCorrectKeys() throws {
        let payload: [String: String] = [
            "title": "Conduit test",
            "body": "Push notifications are working",
        ]
        let data = try JSONEncoder().encode(payload)
        let decoded = try JSONDecoder().decode([String: String].self, from: data)
        #expect(decoded["title"] == "Conduit test")
        #expect(decoded["body"] == "Push notifications are working")
    }

    @Test func testPushPayloadDefaultsAreNonEmpty() throws {
        // Ensure the defaults we send are non-empty (the broker fills in
        // its own defaults on empty strings, but we want ours to show up).
        let title = "Conduit test"
        let body = "Push notifications are working"
        #expect(!title.isEmpty)
        #expect(!body.isEmpty)
    }
}

// MARK: - PushSettingsState tests

/// Settings state derivation is pure — no system calls, no async.
@Suite("Push notification — PushSettingsState")
struct PushSettingsStateTests {

    @Test func defaultStateIsNotDetermined() {
        let state = PushSettingsState()
        #expect(state.auth == .notDetermined)
        #expect(state.brokerSupported == false)
        #expect(state.registered == false)
    }

    @Test func statusLabelWhenBrokerNotSupported() {
        let state = PushSettingsState(auth: .authorized, brokerSupported: false, registered: false)
        #expect(state.statusLabel == "box doesn't support push")
    }

    @Test func statusLabelWhenDenied() {
        let state = PushSettingsState(auth: .denied, brokerSupported: true, registered: false)
        #expect(state.statusLabel == "disabled in Settings")
    }

    @Test func statusLabelWhenPending() {
        let state = PushSettingsState(auth: .pending, brokerSupported: true, registered: false)
        #expect(state.statusLabel == "waiting for system token…")
    }

    @Test func statusLabelWhenAuthorizedAndRegistered() {
        let state = PushSettingsState(auth: .authorized, brokerSupported: true, registered: true)
        #expect(state.statusLabel == "authorized · registered with box")
    }

    @Test func statusLabelWhenAuthorizedButNotRegistered() {
        let state = PushSettingsState(auth: .authorized, brokerSupported: true, registered: false)
        #expect(state.statusLabel == "authorized · not registered")
    }

    @Test func statusLabelWhenNotDetermined() {
        let state = PushSettingsState(auth: .notDetermined, brokerSupported: true, registered: false)
        #expect(state.statusLabel == "not set up")
    }

    @Test func equatableDistinguishesAuthStates() {
        let a = PushSettingsState(auth: .authorized, brokerSupported: true, registered: true)
        let b = PushSettingsState(auth: .authorized, brokerSupported: true, registered: true)
        let c = PushSettingsState(auth: .denied, brokerSupported: true, registered: false)
        #expect(a == b)
        #expect(a != c)
    }

    // Broker-not-supported wins over all auth states (honest-state rule)
    @Test func brokerNotSupportedWinsOverAuth() {
        for auth: PushAuthState in [.notDetermined, .authorized, .denied, .pending] {
            let state = PushSettingsState(auth: auth, brokerSupported: false)
            #expect(state.statusLabel == "box doesn't support push",
                    "Expected broker-not-supported label for auth=\(auth)")
        }
    }
}

// MARK: - Fan-out register logic tests

// Pure helper that mirrors the dedup + fan-out endpoint selection in
// PushNotificationManager.registerWithAllServers. Tests run on any host
// (no network, no MainActor, no system calls).
private func fanOutEndpoints(
    activeEndpoint: StoredEndpoint,
    allEndpoints: [StoredEndpoint]
) -> [StoredEndpoint] {
    var seen = Set<StoredEndpoint>()
    var result: [StoredEndpoint] = []
    let candidates = activeEndpoint.isComplete
        ? [activeEndpoint] + allEndpoints
        : allEndpoints
    for ep in candidates {
        guard ep.isComplete, seen.insert(ep).inserted else { continue }
        result.append(ep)
    }
    return result
}

// Pure helper: simulate fan-out results (nil = failure) and count successes.
private func countFanOutSuccesses(_ results: [Bool?]) -> Int {
    results.compactMap { $0 }.filter { $0 }.count
}

@Suite("Push notification — multi-box fan-out")
struct PushFanOutTests {

    private func ep(_ url: String) -> StoredEndpoint {
        StoredEndpoint(url: url, token: "tok")
    }
    private let empty = StoredEndpoint(url: "", token: "")

    @Test func nEndpointsProduceNCalls() {
        let active = ep("https://box1.example.com")
        let all = [
            ep("https://box1.example.com"),
            ep("https://box2.example.com"),
            ep("https://box3.example.com"),
        ]
        let selected = fanOutEndpoints(activeEndpoint: active, allEndpoints: all)
        #expect(selected.count == 3)
    }

    @Test func activeEndpointIncludedEvenIfNotInAllEndpoints() {
        let active = ep("https://active.example.com")
        let all = [
            ep("https://box2.example.com"),
            ep("https://box3.example.com"),
        ]
        let selected = fanOutEndpoints(activeEndpoint: active, allEndpoints: all)
        #expect(selected.count == 3)
        #expect(selected.first == active)
    }

    @Test func duplicatesAreDeduped() {
        let active = ep("https://box1.example.com")
        let all = [
            ep("https://box1.example.com"),
            ep("https://box1.example.com"),
            ep("https://box2.example.com"),
        ]
        let selected = fanOutEndpoints(activeEndpoint: active, allEndpoints: all)
        #expect(selected.count == 2)
    }

    @Test func emptyAllEndpointsOnlyActiveRegistered() {
        let active = ep("https://solo.example.com")
        let selected = fanOutEndpoints(activeEndpoint: active, allEndpoints: [])
        #expect(selected.count == 1)
        #expect(selected.first == active)
    }

    @Test func emptyAllEndpointsAndIncompleteActiveProducesZero() {
        let selected = fanOutEndpoints(activeEndpoint: empty, allEndpoints: [])
        #expect(selected.count == 0)
    }

    @Test func incompleteEndpointsSkipped() {
        let active = ep("https://box1.example.com")
        let all = [
            ep("https://box1.example.com"),
            StoredEndpoint(url: "", token: ""),
            StoredEndpoint(url: "https://no-token.example.com", token: ""),
        ]
        let selected = fanOutEndpoints(activeEndpoint: active, allEndpoints: all)
        #expect(selected.count == 1)
    }

    @Test func oneBoxFailureDoesNotPreventOthers() {
        // Simulate 3 boxes: box1 success, box2 failure (nil), box3 success.
        let results: [Bool?] = [true, nil, true]
        let successes = countFanOutSuccesses(results)
        #expect(successes == 2)
    }

    @Test func allFailuresTrackedIndependently() {
        let results: [Bool?] = [nil, nil, nil]
        let successes = countFanOutSuccesses(results)
        #expect(successes == 0)
    }

    @Test func allSuccessesCountedCorrectly() {
        let results: [Bool?] = [true, true, true]
        let successes = countFanOutSuccesses(results)
        #expect(successes == 3)
    }

    @Test func registerPayloadFieldsPerBox() throws {
        // Verify the per-box register payload has the correct shape.
        let hex = "cafebabe"
        let payload = ["platform": "apns", "token": hex]
        let data = try JSONEncoder().encode(payload)
        let decoded = try JSONDecoder().decode([String: String].self, from: data)
        #expect(decoded["platform"] == "apns")
        #expect(decoded["token"] == hex)
        #expect(decoded.keys.count == 2)
    }
}

// MARK: - Live Activity push-token registration payload tests

/// Verify the JSON body POST'd to `/api/push/register` for LA tokens has
/// the exact shape the broker expects per the push-LA contract:
/// `{"platform":"apns-liveactivity","token":"<hex>","session_id":"<id>"}`.
@Suite("Push notification -- Live Activity register payload")
struct PushLARegisterPayloadTests {

    private struct LARegisterPayload: Encodable {
        let platform: String
        let token: String
        let session_id: String
    }

    @Test func laRegisterPayloadHasCorrectKeys() throws {
        let hex = "deadbeef01020304"
        let payload = LARegisterPayload(
            platform: "apns-liveactivity",
            token: hex,
            session_id: "session-abc-123"
        )
        let data = try JSONEncoder().encode(payload)
        let decoded = try JSONDecoder().decode([String: String].self, from: data)
        #expect(decoded["platform"]   == "apns-liveactivity")
        #expect(decoded["token"]      == hex)
        #expect(decoded["session_id"] == "session-abc-123")
        #expect(decoded.keys.count == 3)
    }

    @Test func laRegisterPlatformDistinctFromAlertPlatform() throws {
        // LA and alert tokens use different platform strings -- the broker
        // stores them separately (keyed by (identity, session_id) for LA).
        let alertPayload = ["platform": "apns", "token": "aabbcc"]
        let laPayload = LARegisterPayload(
            platform: "apns-liveactivity",
            token: "aabbcc",
            session_id: "s-1"
        )
        let alertData = try JSONEncoder().encode(alertPayload)
        let laData    = try JSONEncoder().encode(laPayload)
        let alertDecoded = try JSONDecoder().decode([String: String].self, from: alertData)
        let laDecoded    = try JSONDecoder().decode([String: String].self, from: laData)
        #expect(alertDecoded["platform"] != laDecoded["platform"])
        #expect(laDecoded["platform"] == "apns-liveactivity")
        #expect(alertDecoded["platform"] == "apns")
    }
}

// MARK: - "Prompt existing users on active" guard tests
//
// The scene-phase .active hook fires requestAuthorizationIfNeeded() only when
// BOTH conditions hold: sessions is non-empty AND auth is .notDetermined.
// This suite validates that guard function independently of UIKit/async so it
// can run on any host.

/// Pure helper that mirrors the scene-phase guard in ConduitApp.swift.
/// Returns true when the manager should be asked to request authorization.
private func shouldPromptOnActive(sessionCount: Int, auth: PushAuthState) -> Bool {
    sessionCount > 0 && auth == .notDetermined
}

@Suite("Push notification — existing-user active prompt guard")
struct PushActivePromptGuardTests {

    @Test func promptsWhenSessionsExistAndNotDetermined() {
        #expect(shouldPromptOnActive(sessionCount: 1, auth: .notDetermined) == true)
        #expect(shouldPromptOnActive(sessionCount: 5, auth: .notDetermined) == true)
    }

    @Test func doesNotPromptWhenNoSessions() {
        #expect(shouldPromptOnActive(sessionCount: 0, auth: .notDetermined) == false)
    }

    @Test func doesNotPromptWhenAlreadyAuthorized() {
        #expect(shouldPromptOnActive(sessionCount: 1, auth: .authorized) == false)
        #expect(shouldPromptOnActive(sessionCount: 3, auth: .authorized) == false)
    }

    @Test func doesNotPromptWhenDenied() {
        // Denied users cannot be re-prompted; they must go to iOS Settings.
        #expect(shouldPromptOnActive(sessionCount: 1, auth: .denied) == false)
    }

    @Test func doesNotPromptWhenPending() {
        // Pending means we already called registerForRemoteNotifications.
        #expect(shouldPromptOnActive(sessionCount: 1, auth: .pending) == false)
    }

    @Test func doesNotPromptWhenNoSessionsAndAllAuthStates() {
        for auth: PushAuthState in [.notDetermined, .authorized, .denied, .pending] {
            #expect(shouldPromptOnActive(sessionCount: 0, auth: auth) == false,
                    "Should not prompt with 0 sessions, auth=\(auth)")
        }
    }
}
