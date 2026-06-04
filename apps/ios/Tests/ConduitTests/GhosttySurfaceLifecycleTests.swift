import Testing
import Foundation
import GhosttyVT

/// Stage 2 of the rebuild. A live libghostty surface renders via Metal/IOSurface,
/// which only a real device/simulator window exercises — so (like the geistty /
/// clauntty test suites) these assert the SAFE paths: the create→teardown
/// lifecycle, idempotency, and that feed/draw/resize/teardown never crash whether
/// or not headless surface creation succeeded. Actual rendering is verified
/// on-device.
@Suite("GhosttySurface lifecycle")
struct GhosttySurfaceLifecycleTests {
    @Test func teardownIsIdempotentAndClearsAlive() {
        // App singleton must be up for surface creation to even be attempted.
        #expect(GhosttyApp.shared.readiness == .ready)

        let surface = GhosttySurface(hostView: nil, pixelWidth: 400, pixelHeight: 300, scaleFactor: 2.0)
        // Exercise the headless-safe ops only (feed + resize — what the prior
        // wrapper's smoke test proved safe). NOT `draw()`/`refresh()`: a headless
        // surface has no IOSurface/Metal target, so driving the renderer can block
        // — and live rendering is verified on-device, not in a unit test.
        if surface.isAlive {
            surface.feed("hello, ghostty\r\n")
            surface.resize(pixelWidth: 200, pixelHeight: 150, scale: 2.0)
        }

        surface.teardown()
        #expect(!surface.isAlive)

        // Second teardown is a no-op (the dismantle/deinit double-call path).
        surface.teardown()
        #expect(!surface.isAlive)
    }

    @Test func opsAfterTeardownDoNotCrash() {
        let surface = GhosttySurface(hostView: nil, pixelWidth: 200, pixelHeight: 100, scaleFactor: 2.0)
        surface.teardown()
        // All of these must no-op via their `guard let surface` once torn down.
        surface.feed("ignored")
        surface.draw()
        surface.refresh()
        surface.resize(pixelWidth: 10, pixelHeight: 10, scale: 1.0)
        surface.setFocus(true)
        surface.setOcclusion(true)
        #expect(surface.gridSize() == nil)
    }
}
