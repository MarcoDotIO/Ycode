import Foundation
import Testing
@testable import YcodeDisplayStream

/// Lossless once still (specs/simulator/display-stream.md §4.2.2; uikit-feel-ycode.md §8.4).
struct StillRefinementTests {
    typealias R = StillRefinement.Rect
    static let still = StillRefinement.stillNanoseconds

    @Test func nothingLossyIsNeverDue() {
        let s = StillRefinement(width: 1206, height: 2622, tile: 32)
        #expect(s.isEmpty)
        #expect(!s.isDue(at: 10 * Self.still))
    }

    @Test func lossyPartsAreDueOnlyOnceTheScreenIsStill() {
        var s = StillRefinement(width: 1206, height: 2622, tile: 32)
        s.sentLossy([R(x: 40, y: 40, width: 10, height: 10)], at: 1_000)
        #expect(!s.isDue(at: 1_000 + Self.still - 1))
        #expect(s.isDue(at: 1_000 + Self.still))
        // A new picture postpones it.
        s.screenChanged(at: 1_000 + Self.still / 2)
        #expect(!s.isDue(at: 1_000 + Self.still))
        #expect(s.isDue(at: 1_000 + Self.still / 2 + Self.still))
    }

    @Test func takeReturnsWholeTilesAndForgetsThem() {
        var s = StillRefinement(width: 100, height: 100, tile: 32)
        s.sentLossy([R(x: 40, y: 40, width: 10, height: 10)], at: 0)
        #expect(s.take() == [R(x: 32, y: 32, width: 32, height: 32)])
        #expect(s.isEmpty)
        #expect(s.take().isEmpty)
    }

    @Test func edgeTilesAreClippedToTheImage() {
        var s = StillRefinement(width: 100, height: 70, tile: 32)
        s.sentLossy([R(x: 0, y: 0, width: 100, height: 70)], at: 0)
        // One run per row, equal spans joined: the whole image.
        #expect(s.take() == [R(x: 0, y: 0, width: 100, height: 70)])
    }

    @Test func disjointRunsStayDisjoint() {
        var s = StillRefinement(width: 256, height: 128, tile: 32)
        s.sentLossy([R(x: 0, y: 0, width: 64, height: 64), R(x: 160, y: 32, width: 32, height: 64)], at: 0)
        let rects = s.take()
        #expect(rects == [R(x: 0, y: 0, width: 64, height: 64), R(x: 160, y: 32, width: 32, height: 64)])
        // No two rectangles overlap (the viewer decodes tiles in parallel).
        for (i, a) in rects.enumerated() {
            for b in rects[(i + 1)...] {
                #expect(a.x + a.width <= b.x || b.x + b.width <= a.x || a.y + a.height <= b.y || b.y + b.height <= a.y)
            }
        }
    }

    @Test func losslessTilesClearOnlyWhatTheyCoverCompletely() {
        var s = StillRefinement(width: 128, height: 64, tile: 32)
        s.sentLossy([R(x: 0, y: 0, width: 128, height: 64)], at: 0)
        // Covers tiles (1,0) and (2,0) completely and touches (0,0) and (3,0) partly.
        s.sentLossless([R(x: 16, y: 0, width: 96, height: 32)])
        #expect(s.take() == [R(x: 0, y: 0, width: 32, height: 32), R(x: 96, y: 0, width: 32, height: 32),
                             R(x: 0, y: 32, width: 128, height: 32)])
    }

    @Test func helloAsksForItAndOldHellosDoNot() throws {
        let h = DisplayClientHello(client: "viewer")
        #expect(h.stillLossless == true)
        let old = try JSONDecoder().decode(DisplayClientHello.self, from: Data(#"{"protocol":"ycode-display/1","client":"old","maxFPS":60,"encoding":"jpeg","quality":80,"downscale":1}"#.utf8))
        #expect(old.stillLossless == nil)
    }
}
