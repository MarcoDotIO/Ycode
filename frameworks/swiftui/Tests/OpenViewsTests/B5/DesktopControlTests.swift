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

// B5-OPENVIEWS (`cross-platform-parity.md` §15 OV-5): the desktop control
// looks against the macOS IDE's sizes and fills (DesktopControls.swift).

@MainActor
@Suite("B5 desktop controls")
struct DesktopControlTests {
    struct Probe<C: View>: View {
        let content: C
        var background = Color.white
        var body: some View {
            content.padding(10).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .background(background).environment(\._desktopChrome, true)
        }
    }

    private func size<V: View>(_ v: V) -> CGSize {
        var env = EnvironmentValues()
        env._desktopChrome = true
        env._desktopTextStyles = true
        let g = ViewGraph(rootView: AnyView(v), environment: env, layout: HostLayout(.proposal(.unspecified), symbols: StubSymbolProvider()))
        g.update()
        return g.layoutResult?.size ?? .zero
    }

    @Test func pushButtonIs24TallWithAGreyBezelAndBlackLabel() {
        let b = Button("Simulator Runtimes…") {}.buttonStyle(.bordered)
        let s = size(b)
        #expect(abs(s.height - 24) < 0.6, "\(s)")
        let img = R5.render(Probe(content: b), width: 220, height: 44, name: "b5-push-button")
        #expect(R5.near(R5.probe(img, 13, 22), R5.hex("#E4E4E4"), 2))
        let dark = R5.render(Probe(content: b, background: Color(ycodeHex: 0x262626)), width: 220, height: 44, dark: true)
        #expect(R5.near(R5.probe(dark, 13, 22), R5.hex("#363636"), 2))
        // The label is drawn in the text colour, not the accent: no blue ink.
        var blue = 0
        for x in stride(from: 20.0, to: 160, by: 0.5) {
            let (r, g, b, _) = R5.probe(img, x, 22)
            if b > r + 40 && b > g + 20 { blue += 1 }
        }
        #expect(blue == 0)
    }

    @Test func roundedFieldIs23TallWithAHairline() {
        struct F: View {
            @State var t = ""
            var body: some View { TextField("user@sim-host", text: $t).textFieldStyle(.roundedBorder).frame(width: 320) }
        }
        // 3.5 above and below the line (23 with the IDE's 13-point Inter).
        let line = size(Text("user@sim-host")).height
        #expect(abs(size(F()).height - (line + 7)) < 0.6, "\(size(F())) \(line)")
        let img = R5.render(Probe(content: F()), width: 340, height: 60, name: "b5-text-field")
        // The top hairline: a row of #EBEBEB-class pixels near the top.
        var rim = false
        for y in stride(from: 4.25, through: 14, by: 0.5) where R5.near(R5.probe(img, 100, y), R5.hex("#EBEBEB"), 6) { rim = true }
        #expect(rim)
        #expect(R5.near(R5.probe(img, 200, 21), R5.hex("#FFFFFF"), 1))
    }

    @Test func segmentedHasGreyTrackAndDarkerSelection() {
        struct S: View {
            @State var v = 0
            var body: some View {
                Picker("", selection: $v) { Text("Changes").tag(0); Text("Repositories").tag(1) }
                    .pickerStyle(.segmented).labelsHidden().controlSize(.mini).frame(width: 272)
            }
        }
        #expect(abs(size(S()).height - 16) < 0.01)
        let img = R5.render(Probe(content: S(), background: Color(ycodeHex: 0xF2F2F3)), width: 292, height: 36,
                            name: "b5-segmented")
        // Track #E1E1E2 and selection #C7C7C8 over the sidebar's #F2F2F3.
        #expect(R5.near(R5.probe(img, 12, 14), R5.hex("#C7C7C8"), 3))
        #expect(R5.near(R5.probe(img, 160, 14), R5.hex("#E1E1E2"), 3))
    }

    @Test func borderlessPopUpFillsItsColumnWithChevronsAtTheEnd() {
        struct P: View {
            @State var v = 0
            var body: some View {
                Picker("", selection: $v) { Text("No Explicit Encoding").tag(0); Text("UTF-8").tag(1) }
                    .pickerStyle(.menu).menuStyle(.borderlessButton).labelsHidden()
                    .font(.system(size: 11)).frame(width: 173)
            }
        }
        let s = size(P())
        #expect(abs(s.width - 173) < 0.6 && abs(s.height - 16) < 0.6, "\(s)")
        let img = R5.render(Probe(content: P(), background: Color(ycodeHex: 0x252627)), width: 193, height: 36, dark: true,
                            name: "b5-popup-borderless")
        #expect(R5.near(R5.probe(img, 150, 12), R5.hex("#3E3F40"), 3))
        // The chevrons sit 7 from the end (ink between 173 − 13 and 173 − 7).
        let ink = R5.inkCount(img, in: CGRect(x: 10 + 173 - 14, y: 12, width: 8, height: 12), background: R5.hex("#3E3F40"),
                              tolerance: 30)
        #expect(ink > 6)
    }

    @Test func stepperIs17By20() {
        struct St: View {
            @State var v = 4
            var body: some View { Stepper("Tab", value: $v, in: 1...16).labelsHidden() }
        }
        let s = size(St())
        #expect(abs(s.width - 17) < 0.01 && abs(s.height - 20) < 0.01, "\(s)")
        let img = R5.render(Probe(content: St(), background: Color(ycodeHex: 0xF2F2F3)), width: 37, height: 40,
                            name: "b5-stepper")
        #expect(R5.near(R5.probe(img, 12, 20), R5.hex("#E9E9EA"), 3))
    }
}
