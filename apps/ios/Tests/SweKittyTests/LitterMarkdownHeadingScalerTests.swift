import Testing
import SwiftUI
@testable import SweKitty

/// Pins the heading multipliers used by `LitterMarkdownHeadingScaler`
/// (PLAN-LITTER-VISUAL-PARITY PR 4, audit §A.2.2 / §B.2). Before this
/// PR our `Text(AttributedString(markdown:))` rendered `# H1` … `####
/// H4` at the body size — markdown headers produced no visual
/// hierarchy. Litter ramps headings at 1.07× / 1.15× / 1.30× / 1.43×.
@Suite("Litter markdown heading scale")
struct LitterMarkdownHeadingScalerTests {

    @Test func h1MultiplierIs1_43() {
        #expect(LitterMarkdownHeadingScaler.multiplier(forLevel: 1) == 1.43)
    }

    @Test func h2MultiplierIs1_30() {
        #expect(LitterMarkdownHeadingScaler.multiplier(forLevel: 2) == 1.30)
    }

    @Test func h3MultiplierIs1_15() {
        #expect(LitterMarkdownHeadingScaler.multiplier(forLevel: 3) == 1.15)
    }

    @Test func h4MultiplierIs1_07() {
        #expect(LitterMarkdownHeadingScaler.multiplier(forLevel: 4) == 1.07)
    }

    @Test func h5AndBelowDoNotScale() {
        // Litter's transcripts never go past h4 — h5/h6 stay at body.
        // If we ever raise the ceiling, this test catches it so the
        // size jump is intentional.
        #expect(LitterMarkdownHeadingScaler.multiplier(forLevel: 5) == nil)
        #expect(LitterMarkdownHeadingScaler.multiplier(forLevel: 6) == nil)
    }

    @Test func multipliersAreMonotonicallyIncreasing() {
        // h1 > h2 > h3 > h4 — guards against accidental reorder of
        // the dictionary values.
        let m1 = LitterMarkdownHeadingScaler.multiplier(forLevel: 1)!
        let m2 = LitterMarkdownHeadingScaler.multiplier(forLevel: 2)!
        let m3 = LitterMarkdownHeadingScaler.multiplier(forLevel: 3)!
        let m4 = LitterMarkdownHeadingScaler.multiplier(forLevel: 4)!
        #expect(m1 > m2)
        #expect(m2 > m3)
        #expect(m3 > m4)
        #expect(m4 > 1.0)
    }
}
