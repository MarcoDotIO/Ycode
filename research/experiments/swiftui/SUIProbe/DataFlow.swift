// SUIProbe dataflow mode: which bodies are re-evaluated after which change,
// view identity and state lifetime, onChange/task/preference ordering.
import SwiftUI
import Combine

final class Counts {
    static var c: [String: Int] = [:]
    static func hit(_ k: String) { c[k, default: 0] += 1 }
    static func snapshot(_ label: String) {
        log("df.\(label)", c.keys.sorted().map { "\($0):\(c[$0]!)" }.joined(separator: " "))
        c = [:]
    }
}

@Observable final class Model {
    var a = 0
    var b = 0
    var items = [1, 2, 3]
}

final class LegacyModel: ObservableObject {
    @Published var a = 0
    @Published var b = 0
}

struct CustomKey: EnvironmentKey { static let defaultValue = 0 }
extension EnvironmentValues {
    var probeValue: Int {
        get { self[CustomKey.self] }
        set { self[CustomKey.self] = newValue }
    }
}

struct NoInputChild: View {
    var body: some View { let _ = Counts.hit("noInputChild"); Text("static") }
}
struct ValueChild: View {
    let v: Int
    var body: some View { let _ = Counts.hit("valueChild"); Text("v \(v)") }
}
struct ClosureChild: View {
    let action: () -> Void
    var body: some View { let _ = Counts.hit("closureChild"); Text("closure") }
}
struct ReadsA: View {
    let m: Model
    var body: some View { let _ = Counts.hit("obsReadsA"); Text("a \(m.a)") }
}
struct ReadsB: View {
    let m: Model
    var body: some View { let _ = Counts.hit("obsReadsB"); Text("b \(m.b)") }
}
struct ReadsNothing: View {
    let m: Model
    var body: some View { let _ = Counts.hit("obsReadsNothing"); Text("nothing") }
}
struct ReadsItems: View {
    let m: Model
    var body: some View { let _ = Counts.hit("obsReadsItemsCount"); Text("n \(m.items.count)") }
}
struct LegacyReadsA: View {
    @ObservedObject var m: LegacyModel
    var body: some View { let _ = Counts.hit("legacyReadsA"); Text("a \(m.a)") }
}
struct LegacyReadsNothing: View {
    @ObservedObject var m: LegacyModel
    var body: some View { let _ = Counts.hit("legacyReadsNothing"); Text("nothing") }
}
struct EnvReader: View {
    @Environment(\.probeValue) var v
    var body: some View { let _ = Counts.hit("envReader"); Text("env \(v)") }
}
struct EnvNonReader: View {
    var body: some View { let _ = Counts.hit("envNonReader"); Text("no env") }
}
struct EqChild: View, Equatable {
    let v: Int
    let ignored: Int
    static func == (l: EqChild, r: EqChild) -> Bool { l.v == r.v }
    var body: some View { let _ = Counts.hit("equatableChild"); Text("eq \(v)") }
}

/// A view with its own state that logs its creation, appearance and state value.
struct Stateful: View {
    let tag: String
    @State var token: Int = {
        let v = Int.random(in: 1000...9999)
        logt("df.stateInit", "token \(v)")
        return v
    }()
    init(tag: String) { self.tag = tag; Counts.hit("statefulInit.\(tag)") }
    var body: some View {
        Text("\(tag) \(token)")
            .onAppear { logt("df.\(tag).onAppear", "token=\(token)") }
            .onDisappear { logt("df.\(tag).onDisappear", "token=\(token)") }
    }
}

struct PrefKey: PreferenceKey {
    static let defaultValue: [String] = []
    static func reduce(value: inout [String], nextValue: () -> [String]) { value.append(contentsOf: nextValue()) }
}

struct OrderChild: View {
    let n: String
    var body: some View {
        Text(n)
            .onAppear { logt("df.order.onAppear", n) }
            .preference(key: PrefKey.self, value: [n])
    }
}

struct DataFlowProbe: View {
    @State var counter = 0
    @State var model = Model()
    @StateObject var legacy = LegacyModel()
    @State var env = 0
    @State var flag = true
    @State var ident = 0
    @State var order = [1, 2, 3]
    @State var eqIgnored = 0
    @State var taskID = 0

    var body: some View {
        let _ = Counts.hit("parent")
        VStack {
            Text("counter \(counter)")
            NoInputChild()
            ValueChild(v: 7)
            ClosureChild { _ = counter }
            ReadsA(m: model); ReadsB(m: model); ReadsNothing(m: model); ReadsItems(m: model)
            LegacyReadsA(m: legacy); LegacyReadsNothing(m: legacy)
            Group { EnvReader(); EnvNonReader() }.environment(\.probeValue, env)
            EqChild(v: 1, ignored: eqIgnored).equatable()
            if flag { Stateful(tag: "ifTrue") } else { Stateful(tag: "ifFalse") }
            Stateful(tag: "modifierBranch").opacity(flag ? 1 : 0.5)
            Stateful(tag: "explicitID").id(ident)
            ForEach(order, id: \.self) { i in Stateful(tag: "forEach\(i)") }
            VStack { OrderChild(n: "first"); OrderChild(n: "second") }
                .onAppear { logt("df.order.onAppear", "parentVStack") }
                .onPreferenceChange(PrefKey.self) { v in logt("df.pref", v.joined(separator: ",")) }
        }
        .onChange(of: counter) { o, n in logt("df.onChange.counter", "\(o)->\(n)") }
        .onChange(of: counter, initial: true) { o, n in logt("df.onChangeInitial.counter", "\(o)->\(n)") }
        .task(id: taskID) {
            logt("df.task.start", taskID)
            do { try await Task.sleep(for: .seconds(100)) } catch { logt("df.task.cancelled", "id was replaced") }
        }
        .onAppear { schedule() }
    }

    func schedule() {
        let steps: [(String, @MainActor () -> Void)] = [
            ("stateCounter", { counter += 1 }),
            ("observableA", { model.a += 1 }),
            ("observableB", { model.b += 1 }),
            ("observableItemsAppend", { model.items.append(4) }),
            ("observableItemsMutateInPlace", { model.items[0] = 9 }),
            ("observableSameValue", { model.a = model.a }),
            ("legacyA", { legacy.a += 1 }),
            ("legacyB", { legacy.b += 1 }),
            ("environment", { env += 1 }),
            ("equatableIgnoredField", { eqIgnored += 1 }),
            ("flagToggle", { flag.toggle() }),
            ("explicitID", { ident += 1 }),
            ("forEachReorder", { order = [3, 1, 2] }),
            ("forEachRemove", { order = [3, 2] }),
            ("taskID", { taskID += 1 }),
            ("stateSameValue", { counter = counter }),
        ]
        after(0.8) { Counts.snapshot("bodies.initialRender") }
        var t = 1.0
        for (label, f) in steps {
            after(t) { Counts.c = [:]; logt("df.step", label); f() }
            after(t + 0.6) { Counts.snapshot("bodies.\(label)") }
            t += 1.0
        }
        after(t + 0.5) { finish() }
    }
}
