import Foundation
import Observation
import Testing
#if OPENVIEWS_RENAMED
@testable import OpenViewsCore
@testable import OpenViews
#else
@testable import SwiftUICore
@testable import SwiftUI
#endif

// 03-architecture.md §1 (ViewBuilder result types, modifiers, custom
// modifiers), §3 (`@Binding`, `@StateObject`), §2 (`@Namespace`), and the
// geometry part of §5.

// MARK: - ViewBuilder

@MainActor
@Suite("03 §1 ViewBuilder forms")
struct ViewBuilderTests {
    @ViewBuilder func one() -> some View { Text("a") }
    @ViewBuilder func none() -> some View {}
    @ViewBuilder func three() -> some View {
        Text("a")
        Color.red
        Spacer()
    }
    @ViewBuilder func ifOnly(_ f: Bool) -> some View { if f { Text("a") } }
    @ViewBuilder func ifElse(_ f: Bool) -> some View {
        if f { Text("a") } else { Color.red }
    }
    @ViewBuilder func switchForm(_ n: Int) -> some View {
        switch n {
        case 0: Text("zero")
        case 1: Color.red
        default: Spacer()
        }
    }
    @ViewBuilder func available() -> some View {
        if #available(macOS 10.15, *) { Text("new") } else { Color.red }
    }

    @Test("result types: one view is itself, several are a TupleView, none is EmptyView")
    func blocks() {
        #expect(type(of: one()) == Text.self)
        #expect(type(of: none()) == EmptyView.self)
        #expect(type(of: three()) == TupleView<(Text, Color, Spacer)>.self)
    }

    @Test("`if` alone is an Optional; `if`/`else` and `switch` are conditionals")
    func conditionals() {
        #expect(type(of: ifOnly(true)) == Optional<Text>.self)
        #expect(type(of: ifElse(true)) == _ConditionalContent<Text, Color>.self)
        #expect(type(of: switchForm(0)) == _ConditionalContent<_ConditionalContent<Text, Color>, Spacer>.self)
    }

    @Test("lowering follows the built structure")
    func lowering() {
        func kinds<V: View>(_ v: V) -> [String] {
            let n = ViewGraph.layoutNode(for: HStack { v })
            return n.children.map { String(describing: type(of: $0.behavior)) }
        }
        #expect(kinds(three()) == ["TextLeaf", "ShapeLeaf", "SpacerLeaf"])
        #expect(kinds(ifOnly(false)) == [])
        #expect(kinds(ifElse(false)) == ["ShapeLeaf"])
        #expect(kinds(switchForm(2)) == ["SpacerLeaf"])
        #expect(kinds(available()) == ["TextLeaf"])
        #expect(kinds(ForEach(0..<3) { _ in Color.red }) == ["ShapeLeaf", "ShapeLeaf", "ShapeLeaf"])
        #expect(kinds(AnyView(Text("x"))) == ["TextLeaf"])
    }
}

// MARK: - Bindings

struct BindingChild: View {
    let log: Log
    @Binding var value: Int
    var body: some View {
        let _ = log("child \(value)")
        Text("\(value)")
    }
}

struct BindingParent: View {
    let log: Log
    let c: Controls<Int>
    @State var value = 0
    var body: some View {
        let _ = { c.binding = $value }()
        let _ = log("parent")
        BindingChild(log: log, value: $value)
    }
}

struct Profile: Equatable {
    var name = "a"
    var age = 1
}

struct FieldChild: View {
    let log: Log
    @Binding var name: String
    var body: some View {
        let _ = log("name \(name)")
        Text(name)
    }
}

struct FieldParent: View {
    let log: Log
    let c: Controls<Profile>
    @State var profile = Profile()
    var body: some View {
        let _ = { c.binding = $profile }()
        FieldChild(log: log, name: $profile.name)
    }
}

@Observable
final class BindableModel {
    var name = "a"
}

struct BindableChild: View {
    let log: Log
    @Bindable var model: BindableModel
    var body: some View {
        let _ = log("bindable \(model.name)")
        FieldChild(log: log, name: $model.name)
    }
}

@MainActor
@Suite("03 §3 bindings")
struct BindingTests {
    let log = Log()

    @Test("@Binding: the reader of the binding re-runs; the parent that only passes $value does not")
    func readersOfBinding() {
        let c = Controls<Int>()
        let g = ViewGraph.rendered(BindingParent(log: log, c: c))
        #expect(log.take() == ["parent", "child 0"])
        c.value = 3
        g.update()
        #expect(log.take() == ["child 3"])
    }

    @Test("a write through the child's binding updates the owner's storage")
    func writeThrough() {
        let c = Controls<Int>()
        let g = ViewGraph.rendered(BindingParent(log: log, c: c))
        _ = log.take()
        let child = g.root!.children[0]
        let view = child.view as! BindingChild
        view.value = 9
        g.update()
        #expect(c.value == 9)
        #expect(log.take() == ["child 9"])
    }

    @Test("a member binding ($profile.name) follows the whole value; equal writes schedule nothing")
    func memberBinding() {
        let c = Controls<Profile>()
        let g = ViewGraph.rendered(FieldParent(log: log, c: c))
        #expect(log.take() == ["name a"])
        c.value.name = "b"
        g.update()
        #expect(log.take() == ["name b"])
        c.value = c.value
        g.update()
        #expect(log.take() == [])
    }

    @Test("@Bindable: bindings to an @Observable object's properties")
    func bindable() {
        let m = BindableModel()
        let g = ViewGraph.rendered(BindableChild(log: log, model: m))
        #expect(log.take() == ["bindable a", "name a"])
        let field = g.root!.children[0].view as! FieldChild
        field.name = "z"
        g.update()
        #expect(m.name == "z")
        #expect(log.take() == ["bindable z", "name z"])
    }

    @Test("constant bindings compare by value as view inputs")
    func constantBinding() {
        #expect(GraphComparison.valuesEqual(Binding.constant(1), Binding.constant(1)))
        #expect(!GraphComparison.valuesEqual(Binding.constant(1), Binding.constant(2)))
        #expect(!GraphComparison.valuesEqual(Binding(get: { 1 }, set: { _ in }), Binding(get: { 1 }, set: { _ in })))
    }
}

// MARK: - Custom modifiers

struct Bordered: ViewModifier {
    let log: Log
    @State var width: CGFloat = 4
    func body(content: Content) -> some View {
        let _ = log("modifier body")
        content.padding(width)
    }
}

struct ModifiedParent: View {
    let log: Log
    let c: Controls<Int>
    @State var n = 0
    var body: some View {
        let _ = { c.binding = $n }()
        Text("n=\(n)").modifier(Bordered(log: log))
    }
}

struct Outer: ViewModifier {
    func body(content: Content) -> some View { content.padding(1) }
}

struct Inner: ViewModifier {
    func body(content: Content) -> some View { content.frame(width: 10, height: 10) }
}

@MainActor
@Suite("03 §1, §6 custom view modifiers")
struct CustomModifierTests {
    let log = Log()

    @Test("new content reaches the modifier's placeholder without re-running the modifier body")
    func contentWithoutBody() {
        let c = Controls<Int>()
        let g = ViewGraph.rendered(ModifiedParent(log: log, c: c))
        #expect(log.take() == ["modifier body"])
        c.value = 5
        g.update()
        #expect(log.take() == [])
        let text = g.rootLayoutNode().children[0].behavior as? TextLeaf
        #expect(text?.string == "n=5")
        #expect((g.rootLayoutNode().behavior as? PaddingBehavior)?.insets.leading == 4)
    }

    @Test("modifiers compose outward; concat applies the first one first")
    func concat() {
        let node = ViewGraph.layoutNode(for: Color.red.modifier(Inner().concat(Outer())))
        #expect(node.behavior is PaddingBehavior)
        #expect(node.children[0].behavior is FixedFrameBehavior)
    }
}

// MARK: - StateObject, Namespace, geometry

final class Counter: ObservableObject {
    @Published var n = 0
}

@MainActor
final class Made {
    var count = 0
}

struct OwnsObject: View {
    let log: Log
    @StateObject var counter: Counter
    let tick: Int
    init(log: Log, made: Made, tick: Int) {
        self.log = log
        self.tick = tick
        _counter = StateObject(wrappedValue: { made.count += 1; return Counter() }())
    }
    var body: some View {
        let _ = log("owner \(counter.n) tick \(tick)")
        Color.red
    }
}

struct OwnerParent: View {
    let log: Log
    let made: Made
    let c: Controls<Int>
    @State var tick = 0
    var body: some View {
        let _ = { c.binding = $tick }()
        OwnsObject(log: log, made: made, tick: tick)
    }
}

struct NamespaceProbe: View {
    let ids: Controls<Int>
    let seen: (Namespace.ID) -> Void
    @Namespace var ns
    @State var tick = 0
    var body: some View {
        let _ = { ids.binding = $tick }()
        let _ = seen(ns)
        Text("\(tick)")
    }
}

struct GeometryProbe: View {
    let log: Log
    var body: some View {
        GeometryReader { proxy in
            let _ = log("size \(Int(proxy.size.width))x\(Int(proxy.size.height))")
            Color.red
        }
    }
}

@MainActor
@Suite("03 §2–§5 state objects, namespaces, geometry")
struct StateObjectAndGeometryTests {
    let log = Log()

    @Test("@StateObject: created once per identity (its initialiser expression is not re-run)")
    func stateObjectOnce() {
        let made = Made(), c = Controls<Int>()
        let g = ViewGraph.rendered(OwnerParent(log: log, made: made, c: c))
        c.value = 1
        g.update()
        c.value = 2
        g.update()
        #expect(made.count == 1)
        #expect(log.take() == ["owner 0 tick 0", "owner 0 tick 1", "owner 0 tick 2"])
    }

    @Test("@Namespace: stable for an identity across updates")
    func namespace() {
        var seen: [Namespace.ID] = []
        let c = Controls<Int>()
        let g = ViewGraph.rendered(NamespaceProbe(ids: c) { seen.append($0) })
        c.value = 1
        g.update()
        #expect(seen.count == 2 && seen[0] == seen[1])
    }

    @Test("GeometryReader content is rebuilt after layout with the reader's size")
    func geometryReader() {
        let g = ViewGraph(rootView: GeometryProbe(log: log),
                          layout: HostLayout(.window(CGSize(width: 466, height: 678),
                                                     safeAreaInsets: EdgeInsets(top: 0, leading: 0, bottom: 34, trailing: 84))))
        g.update()
        #expect(log.take() == ["size 0x0", "size 382x644"])
    }

    @Test("onGeometryChange reports the first value and later changes")
    func onGeometryChange() {
        let c = Controls<Int>()
        struct Probe: View {
            let log: Log
            let c: Controls<Int>
            @State var w: CGFloat = 50
            var body: some View {
                let _ = { c.binding = Binding(get: { Int(w) }, set: { w = CGFloat($0) }) }()
                Color.red.frame(width: w, height: 10)
                    .onGeometryChange(for: CGFloat.self, of: { $0.size.width }) { log("width \(Int($0))") }
            }
        }
        let g = ViewGraph(rootView: Probe(log: log, c: c),
                          layout: HostLayout(.proposal(ProposedViewSize(width: 300, height: 500))))
        g.update()
        #expect(log.take() == ["width 50"])
        c.value = 70
        g.update()
        #expect(log.take() == ["width 70"])
    }
}
