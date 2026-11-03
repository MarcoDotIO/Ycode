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

/// T-IMG golden scenes (10-plan.md §3.2): rendered headlessly at scale 2 and
/// compared with the PNGs in Goldens/.
@Suite("T-IMG golden scenes")
@MainActor
struct SampleSceneTests {
    @Test("img.shapes") func shapes() {
        let img = R5.render(SampleScenes.shapes, width: 240, height: 100, name: "img.shapes")
        #expect(R5.compareGolden(img, "img.shapes") == nil)
    }

    @Test("img.gradients") func gradients() {
        let img = R5.render(SampleScenes.gradients, width: 220, height: 110, name: "img.gradients")
        #expect(R5.compareGolden(img, "img.gradients") == nil)
    }

    @Test("img.composite: shapes, gradients, an image, text and clipping") func composite() {
        let img = R5.render(SampleScenes.composite, width: 240, height: 170, name: "img.composite")
        #expect(R5.compareGolden(img, "img.composite") == nil)
    }

    @Test("img.composite.dark") func compositeDark() {
        let img = R5.render(SampleScenes.composite, width: 240, height: 170, dark: true, name: "img.composite.dark")
        #expect(R5.compareGolden(img, "img.composite.dark") == nil)
    }
}
