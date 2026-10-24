import Foundation
import Testing
#if OPENVIEWS_RENAMED
@testable import OpenViewsCore
@testable import OpenViews
#else
@testable import SwiftUICore
@testable import SwiftUI
#endif

// 03-architecture.md §2 (identity and lifetime) and checklist K-2/K-3: a
// child with `@State var token` (a fresh number from its initial-value
// expression) that logs onAppear/onDisappear with its token.

@MainActor
final class TokenSource {
    private(set) var made = 0
    func make() -> Int {
        made += 1
        return made
    }
}

struct TokenChild: View {
    let name: String
    let log: Log
    var tick = 0
    @State var token: Int

    init(_ name: String, log: Log, source: TokenSource, tick: Int = 0) {
        self.name = name
        self.log = log
        self.tick = tick
        _token = State(initialValue: source.make())
    }

    var body: some View {
        let _ = log("\(name).body token=\(token)")
        Text(name)
            .onAppear { log("\(name).onAppear token=\(token)") }
            .onDisappear { log("\(name).onDisappear token=\(token)") }
    }
}

@MainActor
final class Flags {
    var flag = Controls<Bool>()
    var number = Controls<Int>()
    var items = Controls<[Int]>()
    var tick = Controls<Int>()
}

struct IdentityProbe: View {
    enum Mode { case unchanged, branch, opacity, explicitID, forEach }
    let mode: Mode
    let log: Log
    let source: TokenSource
    let flags: Flags
    @State var flag = true
    @State var number = 1
    @State var items = [1, 2, 3]
    @State var tick = 0

    var body: some View {
        let _ = publish()
        let _ = log("parent.body")
        VStack {
            switch mode {
            case .unchanged:
                TokenChild("child", log: log, source: source)
                Text("\(tick)")
            case .branch:
                if flag {
                    TokenChild("ifTrue", log: log, source: source)
                } else {
                    TokenChild("ifFalse", log: log, source: source)
                }
            case .opacity:
                TokenChild("opacity", log: log, source: source).opacity(flag ? 1 : 0.5)
            case .explicitID:
                TokenChild("explicitID", log: log, source: source).id(number)
            case .forEach:
                ForEach(items, id: \.self) { i in
                    TokenChild("item\(i)", log: log, source: source, tick: tick)
                }
            }
        }
    }

    private func publish() -> Bool {
        flags.flag.binding = $flag
        flags.number.binding = $number
        flags.items.binding = $items
        flags.tick.binding = $tick
        return true
    }
}

@MainActor
@Suite("03 §2 identity and lifetime (T-DF, K-3)")
struct IdentityLifetimeTests {
    let log = Log()
    let source = TokenSource()
    let flags = Flags()

    private func graph(_ mode: IdentityProbe.Mode) -> ViewGraph {
        let g = ViewGraph.rendered(IdentityProbe(mode: mode, log: log, source: source, flags: flags))
        _ = log.take()
        return g
    }

    @Test("parent re-evaluated, child unchanged: same identity, state kept; the initial-value expression still runs")
    func parentReevaluated() {
        let g = graph(.unchanged)
        #expect(source.made == 1)
        flags.tick.value += 1
        g.update()
        // The parent ran and created a new child value (a new initial token
        // was computed and discarded); the child itself did not re-run.
        #expect(log.take() == ["parent.body"])
        #expect(source.made == 2)
    }

    @Test("state survives re-evaluation of the child itself")
    func stateKeptAcrossChildBody() {
        let g = graph(.forEach)
        flags.tick.value += 1
        g.update()
        let lines = log.take()
        #expect(lines.contains("item1.body token=1"))
        #expect(lines.contains("item2.body token=2"))
        #expect(lines.contains("item3.body token=3"))
        #expect(source.made == 6)
    }

    @Test("if/else toggled: new branch gets new state; its onAppear precedes the old onDisappear")
    func branchToggle() {
        let g = graph(.branch)
        flags.flag.value = false
        g.update()
        #expect(log.take() == ["parent.body", "ifFalse.body token=2", "ifFalse.onAppear token=2",
                               "ifTrue.onDisappear token=1"])
    }

    @Test(".opacity(flag ? 1 : 0.5) toggled: same identity, no appear/disappear")
    func opacityToggle() {
        let g = graph(.opacity)
        flags.flag.value = false
        g.update()
        #expect(log.take() == ["parent.body"])
    }

    @Test(".id(n) changed: new identity, new state, onAppear before onDisappear")
    func explicitID() {
        let g = graph(.explicitID)
        flags.number.value = 2
        g.update()
        #expect(log.take() == ["parent.body", "explicitID.body token=2", "explicitID.onAppear token=2",
                               "explicitID.onDisappear token=1"])
    }

    @Test("ForEach reordered [1,2,3] → [3,1,2]: state follows the IDs, no appear/disappear")
    func forEachReorder() {
        let g = graph(.forEach)
        flags.items.value = [3, 1, 2]
        g.update()
        #expect(log.take() == ["parent.body"])
        flags.tick.value += 1
        g.update()
        #expect(log.take() == ["item3.body token=3", "item1.body token=1", "item2.body token=2"])
        let texts = g.rootLayoutNode().children.compactMap { ($0.behavior as? TextLeaf)?.string }
        #expect(texts == ["item3", "item1", "item2"])
    }

    @Test("ForEach element removed ([3,2]): only the removed element disappears")
    func forEachRemove() {
        let g = graph(.forEach)
        flags.items.value = [3, 2]
        g.update()
        #expect(log.take() == ["parent.body", "item1.onDisappear token=1"])
    }

    @Test("ForEach element inserted: only the new element appears, with new state")
    func forEachInsert() {
        let g = graph(.forEach)
        flags.items.value = [1, 2, 4, 3]
        g.update()
        // The content closure ran for every element (tokens 4–7 were
        // computed); only item 4 is a new identity and keeps its token.
        #expect(log.take() == ["parent.body", "item4.body token=6", "item4.onAppear token=6"])
    }
}

// MARK: - Appearance order (K-2)

struct AppearOrderProbe: View {
    let log: Log
    var body: some View {
        VStack {
            Text("first").onAppear { log("first") }
            Text("second").onAppear { log("second") }
        }
        .onAppear { log("parentVStack") }
    }
}

struct SixSiblings: View {
    let log: Log
    let source: TokenSource
    var body: some View {
        VStack {
            TokenChild("s1", log: log, source: source)
            TokenChild("s2", log: log, source: source)
            TokenChild("s3", log: log, source: source)
            TokenChild("s4", log: log, source: source)
            TokenChild("s5", log: log, source: source)
            TokenChild("s6", log: log, source: source)
        }
    }
}

struct NestedAppear: View {
    let log: Log
    var body: some View {
        VStack {
            VStack {
                Color.red.onAppear { log("a1") }
                Color.red.onAppear { log("a2") }
            }
            .onAppear { log("A") }
            Color.blue.onAppear { log("B") }
        }
        .onAppear { log("root") }
    }
}

struct DisappearProbe: View {
    let log: Log
    let show: Controls<Bool>
    @State var shown = true
    var body: some View {
        let _ = { show.binding = $shown }()
        if shown {
            VStack {
                Color.red.onDisappear { log("first") }
                Color.red.onDisappear { log("second") }
            }
            .onDisappear { log("stack") }
        }
    }
}

@MainActor
@Suite("03 §2 appearance order (K-2)")
struct AppearanceOrderTests {
    let log = Log()

    @Test("VStack { first; second }.onAppear: second, first, parentVStack")
    func siblingsReversedChildrenFirst() {
        _ = ViewGraph.rendered(AppearOrderProbe(log: log))
        #expect(log.take() == ["second", "first", "parentVStack"])
    }

    @Test("six stateful siblings of the root appear last-to-first")
    func sixSiblings() {
        _ = ViewGraph.rendered(SixSiblings(log: log, source: TokenSource()))
        let appears = log.take().filter { $0.contains("onAppear") }.map { String($0.prefix(2)) }
        #expect(appears == ["s6", "s5", "s4", "s3", "s2", "s1"])
    }

    @Test("nested: reverse pre-order (B, a2, a1, A, root)")
    func nested() {
        _ = ViewGraph.rendered(NestedAppear(log: log))
        #expect(log.take() == ["B", "a2", "a1", "A", "root"])
    }

    @Test("removal: disappear actions in the same reverse pre-order (inferred)")
    func disappearOrder() {
        let show = Controls<Bool>()
        let g = ViewGraph.rendered(DisappearProbe(log: log, show: show))
        show.value = false
        g.update()
        #expect(log.take() == ["second", "first", "stack"])
    }
}

// MARK: - Type-erased identity

struct AnyViewProbe: View {
    let log: Log
    let source: TokenSource
    let kind: Controls<Int>
    @State var k = 0
    var body: some View {
        let _ = { kind.binding = $k }()
        if k < 2 {
            // Same wrapped type for k = 0 and 1: same identity.
            AnyView(TokenChild("erased", log: log, source: source, tick: k))
        } else {
            AnyView(TokenChild("erased", log: log, source: source, tick: k).padding())
        }
    }
}

@MainActor
@Suite("03 §2 type-erased identity")
struct AnyViewIdentityTests {
    let log = Log()

    @Test("AnyView keeps the identity while the wrapped type is unchanged; a new type is a new identity")
    func anyView() {
        let kind = Controls<Int>()
        let g = ViewGraph.rendered(AnyViewProbe(log: log, source: TokenSource(), kind: kind))
        #expect(log.take() == ["erased.body token=1", "erased.onAppear token=1"])
        kind.value = 1
        g.update()
        #expect(log.take() == ["erased.body token=1"])
        // k = 2 switches the `if` branch as well; the erased type differs too.
        kind.value = 2
        g.update()
        #expect(log.take() == ["erased.body token=3", "erased.onAppear token=3", "erased.onDisappear token=1"])
    }

    @Test("Layout values are views through callAsFunction")
    func layoutAsView() {
        let r = layoutFrames(HStackLayout(spacing: 0) {
            Color.red.frame(width: 10, height: 10).probe("a")
            Color.blue.frame(width: 10, height: 10).probe("b")
        })
        #expect(r.frames["b"] == CGRect(x: 10, y: 0, width: 10, height: 10))
        let z = layoutFrames(AnyLayout(VStackLayout(spacing: 2)) {
            Color.red.frame(width: 10, height: 10).probe("a")
            Color.blue.frame(width: 10, height: 10).probe("b")
        })
        #expect(z.frames["b"] == CGRect(x: 0, y: 12, width: 10, height: 10))
    }
}
