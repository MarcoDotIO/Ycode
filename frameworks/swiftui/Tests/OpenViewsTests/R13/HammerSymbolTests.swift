import Foundation
import OVRender
import Testing
#if OPENVIEWS_RENAMED
@testable import OpenViewsCore
@testable import OpenViews
#else
@testable import SwiftUICore
@testable import SwiftUI
#endif

// R13 (BUILD-HUD): `hammer` holds up at bezel sizes (80–120 points): a claw
// hammer with a head, a claw and a tapered handle, Ycode's own drawing.
// `OV_RENDER_OUT=<dir>` keeps `hammer-sheet.png`.

@MainActor
@Suite("R13 hammer symbol")
struct HammerSymbolTests {
    struct Sheet: View {
        var body: some View {
            HStack(spacing: 24) {
                Image(systemName: "hammer").resizable().frame(width: 112, height: 96)
                Image(systemName: "hammer.fill").resizable().frame(width: 112, height: 96)
                Image(systemName: "hammer").font(.system(size: 40))
                Image(systemName: "hammer")
            }
            .foregroundStyle(.white)
            .padding(24)
            .background(Color(.sRGB, red: 0.08, green: 0.08, blue: 0.08))
        }
    }

    @Test func theHammerHasAHeadAClawAndAHandle() {
        let img = R5.render(Sheet(), width: 420, height: 144, scale: 2, name: "hammer-sheet")
        // Ink (white) in the 112 × 96 frame at (24, 24): the head towards the
        // top right, the handle's end towards the bottom left, and empty
        // corners at the top left and bottom right.
        func ink(_ x: Double, _ y: Double) -> Bool { R5.probe(img, 24 + x, 24 + y).0 > 128 }
        var head = 0, handle = 0, topLeft = 0, bottomRight = 0
        for i in 0..<20 {
            for j in 0..<20 {
                let fx = Double(i) / 20, fy = Double(j) / 20
                if ink(56 + fx * 56, fy * 40) { head += 1 }
                if ink(fx * 40, 56 + fy * 40) { handle += 1 }
                if ink(fx * 20, fy * 16) { topLeft += 1 }
                if ink(92 + fx * 20, 80 + fy * 16) { bottomRight += 1 }
            }
        }
        #expect(head > 40 && handle > 10)
        #expect(topLeft == 0 && bottomRight == 0)
    }
}
