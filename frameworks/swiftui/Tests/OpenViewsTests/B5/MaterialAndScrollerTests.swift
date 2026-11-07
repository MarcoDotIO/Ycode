import Foundation
import OVPlatform
import OVRender
import Testing
#if OPENVIEWS_RENAMED
@testable import OpenViewsCore
@testable import OpenViews
#else
@testable import SwiftUICore
@testable import SwiftUI
#endif

// B5-OPENVIEWS (`cross-platform-parity.md` §15 OV-1, OV-2, OV-3): the window
// buttons', sidebar material's and desktop scrollers' pixels against the
// macOS IDE's values.

@MainActor
@Suite("B5 window buttons, materials and scrollers drawn")
struct MaterialAndScrollerTests {
    @Test func windowButtonsDrawTheirColoursAndGreyWhenInactive() {
        let state = WindowChromeState()
        state.style = .hiddenTitleBar
        let layer = WindowButtonsLayer(state: state, contentTop: 0, modal: false)
        let img = R5.render(layer.background(Color.white), width: 120, height: 52, name: "b5-window-buttons")
        #expect(R5.near(R5.probe(img, 26, 26), R5.hex("#FF5F57"), 3))
        #expect(R5.near(R5.probe(img, 49, 26), R5.hex("#FEBC2E"), 3))
        #expect(R5.near(R5.probe(img, 72, 26), R5.hex("#28C840"), 3))
        #expect(R5.near(R5.probe(img, 100, 26), R5.hex("#FFFFFF"), 1))
        let inactive = R5.render(layer.background(Color.white).environment(\.controlActiveState, .inactive),
                                 width: 120, height: 52, name: "b5-window-buttons-inactive")
        for x in [26.0, 49, 72] { #expect(R5.near(R5.probe(inactive, x, 26), R5.hex("#E7E8E9"), 3)) }
        let dark = R5.render(layer.environment(\.controlActiveState, .inactive), width: 120, height: 52, dark: true)
        #expect(R5.near(R5.probe(dark, 26, 26), R5.hex("#4A4A4B"), 3))
        // Hovered: the glyphs (dark ink in the middle of each circle).
        state.buttonsHovered = true
        let hovered = R5.render(layer.background(Color.white), width: 120, height: 52, name: "b5-window-buttons-hover")
        let (r, g, b, _) = R5.probe(hovered, 26, 26)
        #expect(r < 0xE0 && g < 0x50 && b < 0x50)   // the cross over red
        #expect(R5.inkCount(hovered, in: CGRect(x: 66, y: 20, width: 12, height: 12), background: R5.hex("#28C840"), tolerance: 40) > 10)
    }

    @Test func sidebarListAndMaterialsTakeTheMacColours() {
        let list = List { Text("Row") }.listStyle(.sidebar).environment(\._desktopChrome, true)
        let light = R5.render(list, width: 200, height: 120, name: "b5-sidebar-light")
        #expect(R5.near(R5.probe(light, 150, 100), R5.hex("#F2F2F3"), 2))
        let dark = R5.render(list, width: 200, height: 120, dark: true, name: "b5-sidebar-dark")
        #expect(R5.near(R5.probe(dark, 150, 100), R5.hex("#252627"), 2))
        let bar = R5.render(Rectangle().fill(.bar), width: 20, height: 20, dark: true)
        #expect(R5.near(R5.probe(bar, 10, 10), R5.hex("#262626"), 2))
        let side = R5.render(Rectangle().fill(.sidebarMaterial), width: 20, height: 20)
        #expect(R5.near(R5.probe(side, 10, 10), R5.hex("#F2F2F3"), 2))
    }

    struct Tall: View {
        var body: some View {
            ScrollView {
                VStack(spacing: 0) {
                    ForEach(0..<40, id: \.self) { i in
                        Color(white: i % 2 == 0 ? 0.9 : 0.8).frame(maxWidth: .infinity).frame(height: 20)
                    }
                }
            }
            .background(Color.white)
        }
    }

    @Test func legacyScrollersTakeALaneAndShowAtRest() {
        let view = Tall().scrollerStyle(.legacy).environment(\._desktopChrome, true)
        let img = R5.render(view, width: 200, height: 200, name: "b5-scroller-legacy")
        // Content narrowed by the 17-point lane; knob 11 wide, 3 inside.
        #expect(R5.near(R5.probe(img, 180, 10), R5.hex("#E6E6E6"), 2))       // content
        #expect(R5.near(R5.probe(img, 191.5, 20), R5.hex("#7A7A7A"), 2))     // knob
        #expect(R5.near(R5.probe(img, 184.5, 20), R5.hex("#FFFFFF"), 2))     // lane beside the slot
        #expect(R5.near(R5.probe(img, 191.5, 190), R5.hex("#F3F3F3"), 2))    // slot below the knob
        let dark = R5.render(view, width: 200, height: 200, dark: true, name: "b5-scroller-legacy-dark")
        #expect(R5.near(R5.probe(dark, 191.5, 20), R5.hex("#9E9F9F"), 2))
        // The overlay look shows nothing at rest and takes no lane.
        let overlay = R5.render(Tall().scrollerStyle(.overlay).environment(\._desktopChrome, true), width: 200, height: 200)
        #expect(R5.near(R5.probe(overlay, 191.5, 10), R5.hex("#E6E6E6"), 2))
        // `.scrollIndicators(.visible)` on a desktop is the legacy look.
        let visible = R5.render(Tall().scrollIndicators(.visible).environment(\._desktopChrome, true), width: 200, height: 200)
        #expect(R5.near(R5.probe(visible, 191.5, 20), R5.hex("#7A7A7A"), 2))
    }

    @Test func desktopScrollerSettingFollowsTheDesktop() {
        var s = PlatformSettings()
        #expect(s.overlayScrollers)
        s.apply(key: "scrollers", value: "always")
        #expect(!s.overlayScrollers)
        var e = PlatformSettings()
        e.apply(environment: ["OV_SCROLLERS": "legacy"])
        #expect(!e.overlayScrollers)
        var env = EnvironmentValues()
        env._desktopChrome = true
        PlatformEnvironment.apply(e, to: &env)
        #expect(ScrollerStyle.resolved(env, indicators: (.automatic, .automatic)) == .legacy)
        env._desktopChrome = false
        #expect(ScrollerStyle.resolved(env, indicators: (.automatic, .automatic)) == nil)
    }
}
