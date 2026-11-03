import Foundation
import OVPlatform
import OVRender
#if OPENVIEWS_RENAMED
import OpenViews
#else
import SwiftUI
#endif

// ov-editor-bench (R13): how fast OpenViews scrolls a 10 000-line source
// file drawn the way EditorKit will draw it (docs/PARITY.md §5.9 item 2): a
// tall scroll content and a viewport-sized `Canvas` that draws only the
// visible lines as text runs (line numbers and code, monospaced), at the
// scroll offset. Headless back end, the window's real presenter (display
// list, damage, ThorVG rasterisation, the software compositor); one wheel
// step of 37 points per 60 Hz frame. Build it in release:
//
//     swift build -c release --product ov-editor-bench && .build/release/ov-editor-bench
//
// Switches: OV_BENCH_FRAMES (600), OV_BENCH_LINES (10000), OV_BENCH_SIZE
// (1400x900), OV_BENCH_SCALE (1; 2 for a high-density window).

struct BenchSurface: View {
    let lines: [String]
    static let lineHeight: CGFloat = 16
    @State private var top: CGFloat = 0
    @State private var height: CGFloat = 600

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

func benchSource(lines n: Int) -> [String] {
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
    // Every line differs (as in a real file): the text plus its number.
    return (0..<n).map { i in templates[i % templates.count] + "  // \(i + 1)" }
}

@MainActor
enum Bench {
    static var lines: [String] = []
    static var size = CGSize(width: 1400, height: 900)
}

struct BenchApp: App {
    var body: some Scene {
        WindowGroup("Bench") { BenchSurface(lines: Bench.lines) }
            .defaultSize(width: Bench.size.width, height: Bench.size.height)
    }
}

/// Times the window's presenter.
@MainActor
final class TimedPresenter: FramePresenter {
    let inner: any FramePresenter
    var seconds: [Double] = []
    init(_ inner: any FramePresenter) { self.inner = inner }
    func present(_ window: WindowHost) {
        let t = DispatchTime.now().uptimeNanoseconds
        inner.present(window)
        seconds.append(Double(DispatchTime.now().uptimeNanoseconds - t) / 1e9)
    }
    func surfaceDidResize() { inner.surfaceDidResize() }
    func invalidate() { inner.invalidate() }
    func readback() -> PixelBuffer? { inner.readback() }
}

@main
struct EditorBenchMain {
    @MainActor static func main() {
        let env = ProcessInfo.processInfo.environment
        let frames = Int(env["OV_BENCH_FRAMES"] ?? "") ?? 600
        let n = Int(env["OV_BENCH_LINES"] ?? "") ?? 10_000
        let scale = Double(env["OV_BENCH_SCALE"] ?? "") ?? 1
        if let s = env["OV_BENCH_SIZE"], case let p = s.split(separator: "x"), p.count == 2,
           let w = Double(p[0]), let h = Double(p[1]) { Bench.size = CGSize(width: w, height: h) }
        Bench.lines = benchSource(lines: n)
        let backend = HeadlessBackend(scale: scale)
        let host = AppHost(BenchApp.self, backend: backend)
        var timed: TimedPresenter?
        let make = host.makePresenter
        host.makePresenter = { w in
            guard let p = make(w) else { return nil }
            let t = TimedPresenter(p)
            if timed == nil { timed = t }
            return t
        }
        host.showsMenuBar = false
        host.launch()
        host.run(until: 0.5)
        guard let window = host.windows.first else { print("no window"); return }
        let presenterName = (timed?.inner as? CompositorPresenter)?.description ?? "?"
        timed?.seconds = []
        var t = 1.0
        var total: [Double] = []
        let scrollStep = -37.0
        for i in 0..<frames {
            t += 1.0 / 60
            // Down to the end and back up.
            let dir = (i / 400) % 2 == 0 ? scrollStep : -scrollStep
            backend.post(.scroll(ScrollEvent(window: window.platform.id, location: CGPoint(x: Bench.size.width / 2, y: Bench.size.height / 2),
                                             delta: CGSize(width: 0, height: dir), timestamp: t)), at: t)
            let start = DispatchTime.now().uptimeNanoseconds
            host.run(until: t + 0.001)
            total.append(Double(DispatchTime.now().uptimeNanoseconds - start) / 1e9)
        }
        // Page jumps: every frame shows lines not drawn before.
        var jumps: [Double] = []
        let jumpFrames = env["OV_BENCH_JUMPS"].flatMap { Int($0) } ?? 60
        for i in 0..<jumpFrames {
            t += 1.0 / 60
            let dir = (i / 30) % 2 == 0 ? -Bench.size.height : Bench.size.height
            backend.post(.scroll(ScrollEvent(window: window.platform.id, location: CGPoint(x: Bench.size.width / 2, y: Bench.size.height / 2),
                                             delta: CGSize(width: 0, height: dir * 3), timestamp: t)), at: t)
            let start = DispatchTime.now().uptimeNanoseconds
            host.run(until: t + 0.001)
            jumps.append(Double(DispatchTime.now().uptimeNanoseconds - start) / 1e9)
        }
        func stats(_ v: [Double]) -> String {
            guard !v.isEmpty else { return "-" }
            let s = v.sorted()
            let mean = v.reduce(0, +) / Double(v.count)
            return String(format: "mean %.2f ms, p50 %.2f, p95 %.2f, max %.2f", mean * 1000, s[s.count / 2] * 1000,
                          s[min(s.count - 1, Int(Double(s.count) * 0.95))] * 1000, s.last! * 1000)
        }
        let present = timed?.seconds ?? []
        print("ov-editor-bench: \(n) lines, \(Int(Bench.size.width))x\(Int(Bench.size.height)) pt at scale \(scale), \(frames) frames, presenter \(presenterName)")
        print("  frame (update, layout, display list, raster, present): \(stats(total))")
        print("  presenter (display list, damage, raster, composite):   \(stats(present)) (\(present.count) presented)")
        let fps = 1.0 / (total.reduce(0, +) / Double(max(1, total.count)))
        print(String(format: "  sustainable: %.0f fps", fps))
        print("  page jumps (\(jumpFrames) frames of 3 screens each, all lines new): \(stats(jumps))")
        // The presenter's parts, measured apart on the current frame.
        if let cp = timed?.inner as? CompositorPresenter {
            var dl: [Double] = [], raster: [Double] = []
            let r = SoftwareRasterizer()
            let px = PixelSize(width: Int(Bench.size.width * scale), height: Int(Bench.size.height * scale))
            for _ in 0..<30 {
                var a = DispatchTime.now().uptimeNanoseconds
                let frame = cp.makeFrame(window)
                dl.append(Double(DispatchTime.now().uptimeNanoseconds - a) / 1e9)
                a = DispatchTime.now().uptimeNanoseconds
                _ = r.render(frame, size: px)
                raster.append(Double(DispatchTime.now().uptimeNanoseconds - a) / 1e9)
            }
            print("  display list alone: \(stats(dl)); full-window raster alone: \(stats(raster))")
        }
    }
}
