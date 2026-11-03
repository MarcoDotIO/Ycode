import Foundation
import OVPlatform
import OVRender
import OVText
import Testing
#if OPENVIEWS_RENAMED
@testable import OpenViewsCore
@testable import OpenViews
#else
@testable import SwiftUICore
@testable import SwiftUI
#endif

// Round R13, what EditorKit (docs/PARITY.md §5.9, milestone L2) needs from
// the toolkit: the bundled monospace font, `onKeyPress`, scroll geometry,
// and a drawing surface for text runs (`Canvas` with resolved text) fast
// enough for a 10 000-line file. `OV_BENCH=1` runs the scrolling benchmark
// (prints milliseconds per frame).

@MainActor
final class KeyLog {
    var entries: [String] = []
}

struct KeyPressProbe: View {
    let log: KeyLog
    @FocusState private var focused: Bool

    var body: some View {
        Color.gray.frame(width: 200, height: 100)
            .focusable()
            .focused($focused)
            .onKeyPress(.upArrow) {
                log.entries.append("up")
                return .handled
            }
            .onKeyPress(keys: ["s"]) { p in
                log.entries.append("s \(p.modifiers.contains(.command) ? "cmd" : "-") \(p.characters)")
                return .handled
            }
            .onKeyPress(phases: .up) { p in
                log.entries.append("release \(p.characters)")
                return .ignored
            }
            .onAppear { focused = true }
    }
}

struct FieldKeyPressProbe: View {
    @Binding var text: String
    let log: KeyLog
    @FocusState private var focused: Bool

    var body: some View {
        TextField("Name", text: $text)
            .focused($focused)
            .onKeyPress(characters: .letters) { p in
                log.entries.append(p.characters)
                return .handled
            }
            .onAppear { focused = true }
    }
}

@MainActor
final class TextBox {
    var text = ""
}

struct FieldHost: View {
    let box: TextBox
    let log: KeyLog
    @State private var text = ""
    var body: some View {
        FieldKeyPressProbe(text: Binding(get: { text }, set: { text = $0; box.text = $0 }), log: log)
            .frame(width: 300)
    }
}

/// A 10 000-line editor surface: a tall scroll content, and a viewport-sized
/// `Canvas` that draws only the visible lines as text runs at the scroll
/// offset (what EditorKit's layer does; PARITY §5.9 item 2).
struct EditorSurfaceDemo: View {
    let lines: [String]
    static let lineHeight: CGFloat = 16
    @State private var top: CGFloat = 0
    @State private var height: CGFloat = 600
    var drawnLines: ((Range<Int>) -> Void)?

    var body: some View {
        let lh = Self.lineHeight
        ScrollView {
            Color.clear
                .frame(maxWidth: .infinity)
                .frame(height: CGFloat(lines.count) * lh)
                .overlay(alignment: .topLeading) {
                    Canvas { ctx, size in
                        let first = max(0, Int(top / lh))
                        let last = min(lines.count, Int((top + size.height) / lh) + 1)
                        guard first < last else { return }
                        drawnLines?(first..<last)
                        for i in first..<last {
                            let y = CGFloat(i) * lh - top
                            ctx.draw(Text(verbatim: "\(i + 1)").font(.system(size: 11, design: .monospaced)).foregroundColor(.gray),
                                     at: CGPoint(x: 40, y: y), anchor: .topTrailing)
                            ctx.draw(Text(verbatim: lines[i]).font(.system(size: 12, design: .monospaced)),
                                     at: CGPoint(x: 52, y: y), anchor: .topLeading)
                        }
                    }
                    .frame(height: height)
                    .offset(y: top)
                }
        }
        .onScrollGeometryChange(for: CGRect.self, of: { $0.visibleRect }) { _, r in
            top = max(0, r.minY)
            height = r.height
        }
    }
}

/// Swift-like lines (a mix of lengths).
func sampleSource(lines n: Int) -> [String] {
    let templates = [
        "import Foundation",
        "",
        "/// A value that counts the things it has seen so far.",
        "struct Counter<Element: Hashable> {",
        "    private(set) var counts: [Element: Int] = [:]",
        "    mutating func add(_ e: Element) { counts[e, default: 0] += 1 }",
        "    func count(of e: Element) -> Int { counts[e] ?? 0 }",
        "}",
        "let greeting = \"Hello, world!\"  // the classic",
        "for (index, word) in greeting.split(separator: \" \").enumerated() where index % 2 == 0 {",
        "    print(index, word.uppercased(), word.count, word.reversed())",
        "}",
    ]
    return (0..<n).map { i in templates[i % templates.count] }
}

@MainActor
@Suite("R13 editor support (L2)")
struct EditorSupportTests {
    // 8
    @Test func theBundledMonospaceFontIsUsedForTheMonospacedDesign() {
        let face = FontCatalog.bundled.face(for: FontRequest(design: .monospaced))
        #expect(face?.familyName == "Noto Sans Mono")
        let bold = FontCatalog.bundled.face(for: FontRequest(design: .monospaced, traits: FontTraits(weight: 700)))
        #expect(bold?.familyName == "Noto Sans Mono")
        // Every character advances the same distance.
        let m = TypesetTextMeasurer.shared
        func width(_ s: String, _ t: Text) -> CGFloat {
            m.measure(t.resolve(in: EnvironmentValues()), proposal: .unspecified).size.width
        }
        let a = width("iiiiiiii", Text(verbatim: "iiiiiiii").font(.system(.body, design: .monospaced)))
        let b = width("MMMMMMMM", Text(verbatim: "MMMMMMMM").font(.system(.body, design: .monospaced)))
        #expect(abs(a - b) < 0.01 && a > 0)
        let c = width("iiiiiiii", Text(verbatim: "iiiiiiii").monospaced())
        let d = width("MMMMMMMM", Text(verbatim: "MMMMMMMM").monospaced())
        #expect(abs(c - d) < 0.01)
        // The proportional UI font differs.
        let e = width("iiiiiiii", Text(verbatim: "iiiiiiii"))
        let f = width("MMMMMMMM", Text(verbatim: "MMMMMMMM"))
        #expect(f - e > 10)
    }

    // 9: onKeyPress
    @Test func keyPressHandlersGetTheFocusedViewsKeys() {
        let log = KeyLog()
        let h = CommandsHarness(menuBar: false) { KeyPressProbe(log: log) }
        h.run(until: 0.8)
        h.key(.upArrow, at: 1.0)
        h.key(.character("s"), .control, at: 1.1)
        h.key(.character("s"), .shift, at: 1.2)
        h.key(.downArrow, at: 1.3)                 // no handler: ignored
        h.backend.post(.key(KeyEvent(window: h.windowID, key: .character("x"), isDown: false, timestamp: 1.4)), at: 1.4)
        h.run(until: 1.5)
        #expect(log.entries == ["up", "s cmd s", "s - S", "release x"])
    }

    @Test func handledCharactersAreNotTypedAndOthersAre() {
        let log = KeyLog()
        let box = TextBox()
        let h = CommandsHarness(menuBar: false) { FieldHost(box: box, log: log) }
        h.run(until: 0.8)
        h.type("ab12", at: 1.0)
        h.run(until: 1.6)
        #expect(log.entries == ["a", "b"])
        #expect(box.text == "12")
    }

    @Test func keyPressesNeedFocus() {
        let log = KeyLog()
        let h = CommandsHarness(menuBar: false) {
            Color.gray.frame(width: 100, height: 100)
                .onKeyPress(.upArrow) {
                    log.entries.append("up")
                    return .handled
                }
        }
        h.key(.upArrow, at: 1.0)
        #expect(log.entries.isEmpty)
    }

    // 9: scroll geometry and the text surface
    @Test func theEditorSurfaceFollowsTheScrollGeometryAndDrawsOnlyVisibleLines() {
        var drawn: [Range<Int>] = []
        let lines = sampleSource(lines: 10_000)
        let h = Harness(size: CGSize(width: 800, height: 480), presenter: true) {
            EditorSurfaceDemo(lines: lines, drawnLines: { drawn.append($0) })
        }
        h.run(until: 1.0)
        #expect(drawn.last == 0..<31)
        h.backend.post(.scroll(ScrollEvent(window: h.windowID, location: CGPoint(x: 300, y: 200),
                                           delta: CGSize(width: 0, height: -1600), timestamp: 1.1)), at: 1.1)
        h.run(until: 1.3)
        // 1600 points down: from line 100, 31 lines.
        #expect(drawn.last.map { $0.lowerBound == 100 && $0.count <= 31 } == true)
        let w = h.window
        #expect(w.presentedFrames > 1)
    }

    @Test(arguments: [1.0, 2.0])
    func cachedGlyphRunsDrawTheSamePixels(scale: Double) {
        let lines = sampleSource(lines: 200)
        let h = Harness(size: CGSize(width: 500, height: 300), scale: scale) {
            VStack(alignment: .leading, spacing: 4) {
                EditorSurfaceDemo(lines: lines).frame(height: 160)
                Text("Proportional text, bold too").bold().offset(x: 0.3, y: 0.45)
                Text("Italic and coloured").italic().foregroundStyle(.blue).scaleEffect(1.5)
            }
        }
        h.run(until: 1.0)
        let frame = RenderFrame(displayList: h.window.graph.displayList(), scale: scale, background: .white)
        let px = PixelSize(width: Int(500 * scale), height: Int(300 * scale))
        let plain = SoftwareRasterizer()
        plain.cachesGlyphRuns = false
        let reference = plain.render(frame, size: px)
        let cached = SoftwareRasterizer()
        // First sight: shapes; second: images drawn; then reused.
        let shapes = cached.render(frame, size: px)
        #expect(cached.runImageStats.firstSeen > 20 && cached.runImageStats.drawn == 0)
        #expect(shapes == reference)
        let first = cached.render(frame, size: px)
        #expect(cached.runImageStats.drawn > 20 && cached.runImageStats.reused == 0)
        let second = cached.render(frame, size: px)
        #expect(cached.runImageStats.drawn == 0 && cached.runImageStats.reused > 20)
        #expect(first == second)
        var worst = 0, differing = 0
        for i in 0..<reference.rgba.count {
            let d = abs(Int(reference.rgba[i]) - Int(first.rgba[i]))
            worst = max(worst, d)
            if d > 2 { differing += 1 }
        }
        // The same coverage: identical but for a few edge pixels (rounding of
        // the composite).
        #expect(worst <= 8, "max channel difference \(worst)")
        #expect(differing * 10_000 <= reference.rgba.count, "\(differing) values differ by more than 2")
    }

    @Test func scrollingATenThousandLineSurfaceIsFastEnough() {
        // A short run always; the long one with OV_BENCH=1.
        let bench = ProcessInfo.processInfo.environment["OV_BENCH"] == "1"
        let lines = sampleSource(lines: 10_000)
        let h = Harness(size: CGSize(width: 1400, height: 900), presenter: true) { EditorSurfaceDemo(lines: lines) }
        h.run(until: 1.0)
        let frames = bench ? 600 : 30
        var t = 1.0
        var times: [Double] = []
        for _ in 0..<frames {
            t += 1.0 / 60
            h.backend.post(.scroll(ScrollEvent(window: h.windowID, location: CGPoint(x: 700, y: 400),
                                               delta: CGSize(width: 0, height: -37), timestamp: t)), at: t)
            let start = Date()
            h.run(until: t + 0.001)
            times.append(Date().timeIntervalSince(start) * 1000)
        }
        let sorted = times.sorted()
        let mean = times.reduce(0, +) / Double(times.count)
        let p95 = sorted[Int(Double(sorted.count) * 0.95)]
        print("OV-BENCH editor surface 1400x900, \(frames) frames: mean \(String(format: "%.2f", mean)) ms, p95 \(String(format: "%.2f", p95)) ms, max \(String(format: "%.2f", sorted.last!)) ms")
        #expect(h.window.presentedFrames >= frames / 2)
        if bench { #expect(p95 < 16.7) }
    }
}
