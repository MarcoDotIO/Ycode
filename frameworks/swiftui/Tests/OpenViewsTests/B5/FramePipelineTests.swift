import Foundation
import Observation
import OVRender
import Testing
#if OPENVIEWS_RENAMED
@testable import OpenViewsCore
@testable import OpenViews
#else
@testable import SwiftUICore
@testable import SwiftUI
#endif

// Beta 5, B5-OPENVIEWS (specs/ide/parity-inventory.md P-200): the frame
// pipeline is incremental. An unchanged subtree keeps its layout nodes and
// their measurements from one pass to the next, and an unchanged placement
// is not walked again, so a slide or a selection change costs what changed,
// not the whole window. Each test drives the same views on two graphs, one
// incremental and one that lowers and lays out everything every pass (the
// pre-beta-5 pipeline), and checks that both lay out and draw the same.

extension View {
    /// Names the view's layout node (its frame is in `LayoutResult.namedFrames`).
    func layoutName(_ name: String) -> some View {
        modifier(LayoutEffectModifier(name: "named", apply: { $0.named(name) }))
    }
}

@MainActor
@Observable
final class PipelineModel {
    var sidebarWidth: CGFloat = 240
    var selected = 3
    var detail = "Long.swift"
    var showsInspector = true
    var rows = (0..<120).map { "File \($0).swift" }
}

@MainActor
struct PipelineWindow: View {
    var model: PipelineModel
    var body: some View {
        HStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(model.rows.enumerated()), id: \.offset) { i, name in
                        PipelineRow(name: name, isSelected: i == model.selected)
                    }
                }
            }
            .frame(width: model.sidebarWidth)
            .layoutName("sidebar")
            PipelineEditor(detail: model.detail)
            if model.showsInspector {
                VStack { Text("Identity"); Text("Type") }.frame(width: 260).layoutName("inspector")
            }
        }
    }
}

struct PipelineEditor: View {
    let detail: String
    var body: some View {
        VStack(spacing: 4) {
            Text(detail).font(.headline).layoutName("title")
            Rectangle().fill(Color.gray).frame(height: 1)
            Text("Lines of the editor, wrapped to the width of the column it is in, so its height follows the width.")
                .layoutName("wrapped")
            Spacer()
        }
        .frame(maxWidth: .infinity)
        .layoutName("editor")
    }
}

struct PipelineRow: View {
    let name: String
    let isSelected: Bool
    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "doc")
            Text(name)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8)
        .frame(height: 24)
        .background(isSelected ? Color.blue : Color.clear)
    }
}

@MainActor
@Suite("B5 frame pipeline (P-200)")
struct FramePipelineTests {
    @MainActor
    struct Twin {
        let model: PipelineModel
        let fast: ViewGraph
        let full: ViewGraph
        init() {
            model = PipelineModel()
            let size = CGSize(width: 1100, height: 700)
            fast = ViewGraph(rootView: PipelineWindow(model: model), layout: HostLayout(.window(size, safeAreaInsets: EdgeInsets())))
            full = ViewGraph(rootView: PipelineWindow(model: model), layout: HostLayout(.window(size, safeAreaInsets: EdgeInsets())))
            fast.reusesLowering = true
            full.reusesLowering = false
            fast.update()
            full.update()
        }

        /// Both graphs updated; their frames and display lists compared.
        func step(_ change: () -> Void) {
            change()
            fast.loweringStats = .init()
            fast.update()
            full.update()
        }

        func same() -> Bool {
            guard let a = fast.layoutResult, let b = full.layoutResult else { return false }
            // Item IDs come from view identity, which differs between the
            // two graphs: the lists are compared without them.
            return a.namedFrames == b.namedFrames && FramePipelineTests.anonymous(fast.displayList().items) == FramePipelineTests.anonymous(full.displayList().items)
        }
    }

    /// The items without IDs, and with groups that only translate (the
    /// incremental list keeps large subtrees as such groups) dissolved.
    static func anonymous(_ items: [DisplayItem]) -> [DisplayItem] {
        items.flatMap { item -> [DisplayItem] in
            if case .group(var g) = item.content, g.transform.a == 1, g.transform.b == 0, g.transform.c == 0, g.transform.d == 1 {
                let t = g.transform
                g.transform = .identity
                if g.isPlain { return anonymous(g.children.map { $0.translated(t.tx, t.ty) }) }
            }
            return [single(item)]
        }
    }

    static func single(_ item: DisplayItem) -> DisplayItem {
        do {
            var content = item.content
            if case .group(var g) = content {
                g.children = anonymous(g.children)
                if let m = g.mask { g.mask = DisplayList(anonymous(m.items)) }
                content = .group(g)
            }
            return DisplayItem(id: .root, content)
        }
    }

    @Test func aSelectionChangeLowersOnlyTheTwoRowsAndTheirPath() {
        let t = Twin()
        #expect(t.same())
        t.step { t.model.selected = 7 }
        #expect(t.same())
        let s = t.fast.loweringStats
        // Two rows' bodies ran; the path to the root and those rows lower
        // again, the other 118 rows (and the editor) reuse their lowering.
        #expect(s.lowered < 120, "lowered \(s.lowered)")
        #expect(s.reused > 0)
    }

    @Test func aSlideStepMatchesAFullLayoutAtEveryWidth() {
        let t = Twin()
        for w in stride(from: 240, through: 40, by: -25) {
            t.step { t.model.sidebarWidth = CGFloat(w) }
            #expect(t.same(), "width \(w)")
        }
        for w in stride(from: 40, through: 300, by: 37) {
            t.step { t.model.sidebarWidth = CGFloat(w) }
            #expect(t.same(), "width \(w)")
        }
        // The rows' subtrees are kept while only the column's width changes.
        #expect(t.fast.loweringStats.reused > 0)
    }

    @Test func insertionsRemovalsAndTextChangesMatchAFullLayout() {
        let t = Twin()
        t.step { t.model.showsInspector = false }
        #expect(t.same())
        t.step { t.model.detail = "Bands.swift — a much longer title than before" }
        #expect(t.same())
        t.step { t.model.rows.insert("New.swift", at: 2) }
        #expect(t.same())
        t.step { t.model.rows.removeLast(10) }
        #expect(t.same())
        t.step { t.model.showsInspector = true }
        #expect(t.same())
        t.step { t.model.selected = 0 }
        #expect(t.same())
    }

    @Test func anUnchangedPassPlacesNothingAgain() throws {
        let t = Twin()
        t.step { t.model.selected = 5 }
        let pass = try #require(t.fast.layoutResult?.context.pass)
        // The editor column did not move or change: its nodes keep their
        // placements from an earlier pass.
        let editor = try #require(t.fast.layoutResult?.node(named: "wrapped"))
        #expect(editor.placedPass < pass, "placed \(editor.placedPass) prepared \(editor.preparedPass) pass \(pass)")
        t.step { t.model.sidebarWidth = 200 }
        let pass2 = try #require(t.fast.layoutResult?.context.pass)
        #expect(t.fast.layoutResult?.node(named: "wrapped")?.placedPass == pass2)
        #expect(t.same())
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["OV_PIPELINE_DEBUG"] != nil))
    func debugWhatLowers() {
        let t = Twin()
        var kinds: [String: Int] = [:]
        t.fast.onLowering = { n in kinds[String(describing: type(of: n.view)).prefix(80).description, default: 0] += 1 }
        t.step { t.model.sidebarWidth = 200 }
        for (k, v) in kinds.sorted(by: { $0.value > $1.value }).prefix(30) { print("lowered \(v) \(k)") }
    }

    @Test func aLiveCanvasDrawsAgainWithoutALayout() {
        final class Box { var width: CGFloat = 10 }
        let box = Box()
        let g = ViewGraph(rootView: VStack {
            Text("Kept")
            Canvas { ctx, _ in ctx.fill(Path(CGRect(x: 0, y: 0, width: box.width, height: 4)), with: .color(.red)) }
                .frame(width: 100, height: 4)
        }, layout: HostLayout(.window(CGSize(width: 300, height: 200), safeAreaInsets: EdgeInsets())))
        g.update()
        let a = g.displayList()
        box.width = 60
        // No update pass: the canvas reads its state when it draws.
        let b = g.displayList()
        #expect(a != b)
        #expect(g.displayList() == b)
    }

    @Test func anAnimatedOpacityIsDrawnAtEveryFrame() {
        @MainActor final class Model: ObservableObject { @Published var dim = false }
        struct V: View {
            @ObservedObject var model: Model
            var body: some View {
                HStack {
                    Text("Left")
                    Text("Fading").opacity(model.dim ? 0.2 : 1).animation(.linear(duration: 0.2), value: model.dim)
                }
            }
        }
        let model = Model()
        let g = ViewGraph(rootView: V(model: model), layout: HostLayout(.window(CGSize(width: 300, height: 200), safeAreaInsets: EdgeInsets())))
        g.update()
        model.dim = true
        g.update()
        var lists: [DisplayList] = [g.displayList()]
        for _ in 0..<6 {
            g.advance()
            lists.append(g.displayList())
        }
        // Each frame draws a new opacity.
        #expect(Set(lists.map { "\($0)" }).count == lists.count)
        g.settle()
        #expect(g.displayList() == g.displayList())
    }

    @Test func turningReuseOffLowersEverything() {
        let t = Twin()
        t.full.loweringStats = .init()
        t.model.selected = 9
        t.full.update()
        #expect(t.full.loweringStats.reused == 0)
        #expect(t.full.loweringStats.lowered > 500)
    }
}
