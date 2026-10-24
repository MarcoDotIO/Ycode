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

// T-DF / K-1: the body re-evaluation sets of 03-architecture.md §4.1. The
// probe's structure is rebuilt here: a parent holding `@State counter`, an
// `@Observable` model in `@State`, a `@StateObject` legacy model, an
// environment value it injects, a field ignored by a custom `==`, and
// children that each log their body.

@Observable
final class DFModel {
    var a = 0
    var b = 0
    var items: [Int] = [1]
}

final class DFLegacy: ObservableObject {
    @Published var a = 0
    @Published var b = 0
}

private struct DFValueKey: EnvironmentKey { static let defaultValue = 0 }

extension EnvironmentValues {
    var dfValue: Int {
        get { self[DFValueKey.self] }
        set { self[DFValueKey.self] = newValue }
    }
}

/// What the test drives: the parent's state through bindings it publishes.
@MainActor
final class DFDriver {
    var counter = Controls<Int>()
    var envValue = Controls<Int>()
    var ignored = Controls<Int>()
    var model: DFModel?
    var legacy: DFLegacy?
}

struct DFNoInput: View {
    let log: Log
    var body: some View {
        let _ = log("noInput")
        Color.red
    }
}

struct DFIntInput: View {
    let log: Log
    let value: Int
    var body: some View {
        let _ = log("intInput")
        Text("\(value)")
    }
}

struct DFClosure: View {
    let log: Log
    let action: () -> Void
    var body: some View {
        let _ = log("closure")
        Color.blue
    }
}

struct DFReadsA: View {
    let log: Log
    let model: DFModel
    var body: some View {
        let _ = log("readsA")
        Text("\(model.a)")
    }
}

struct DFReadsB: View {
    let log: Log
    let model: DFModel
    var body: some View {
        let _ = log("readsB")
        Text("\(model.b)")
    }
}

struct DFReadsItems: View {
    let log: Log
    let model: DFModel
    var body: some View {
        let _ = log("readsItems")
        Text("\(model.items.count)")
    }
}

struct DFLegacyReadsA: View {
    let log: Log
    @ObservedObject var legacy: DFLegacy
    var body: some View {
        let _ = log("legacyReadsA")
        Text("\(legacy.a)")
    }
}

struct DFLegacyReadsNothing: View {
    let log: Log
    @ObservedObject var legacy: DFLegacy
    var body: some View {
        let _ = log("legacyReadsNothing")
        Color.green
    }
}

struct DFEnvReader: View {
    let log: Log
    @Environment(\.dfValue) var value
    var body: some View {
        let _ = log("envReader")
        Text("\(value)")
    }
}

struct DFEnvSibling: View {
    let log: Log
    var body: some View {
        let _ = log("envSibling")
        Color.gray
    }
}

/// `==` ignores `ignored`. All stored properties are plain values, as in
/// the probe (the log is reached through a static).
struct DFEquatable: View, Equatable {
    @MainActor static var log: Log?
    let shown: Int
    let ignored: Int
    nonisolated static func == (a: DFEquatable, b: DFEquatable) -> Bool { a.shown == b.shown }
    var body: some View {
        let _ = DFEquatable.log?("equatable")
        Text("\(shown)")
    }
}

struct DFRoot: View {
    let log: Log
    let driver: DFDriver
    @State var counter = 0
    @State var model = DFModel()
    @StateObject var legacy = DFLegacy()
    @State var envValue = 0
    @State var ignored = 0
    @Environment(\.scenePhase) var phase

    var body: some View {
        let _ = log("parent")
        let _ = { DFEquatable.log = log }()
        let _ = phase
        let _ = publish()
        VStack {
            Text("\(counter)")
            DFNoInput(log: log)
            DFIntInput(log: log, value: 5)
            DFClosure(log: log, action: {})
            DFReadsA(log: log, model: model)
            DFReadsB(log: log, model: model)
            DFReadsItems(log: log, model: model)
            DFLegacyReadsA(log: log, legacy: legacy)
            DFLegacyReadsNothing(log: log, legacy: legacy)
            DFEnvReader(log: log)
            DFEnvSibling(log: log)
            DFEquatable(shown: 1, ignored: ignored).equatable()
        }
        .environment(\.dfValue, envValue)
    }

    private func publish() -> Bool {
        driver.counter.binding = $counter
        driver.envValue.binding = $envValue
        driver.ignored.binding = $ignored
        driver.model = model
        driver.legacy = legacy
        return true
    }
}

@MainActor
@Suite("03 §4.1 re-evaluation counts (T-DF, K-1)")
struct DataFlowCountTests {
    let log = Log()
    let driver = DFDriver()
    let graph: ViewGraph

    init() {
        var env = EnvironmentValues()
        env.scenePhase = .inactive
        graph = ViewGraph(rootView: DFRoot(log: log, driver: driver), environment: env)
    }

    /// Initial render, then the scene becomes active (06 §1).
    private func start() {
        graph.update()
        graph.updateEnvironment { $0.scenePhase = .active }
        graph.update()
        _ = log.take()
    }

    private func bodies(_ change: () -> Void) -> [String] {
        change()
        graph.update()
        return log.take().sorted()
    }

    @Test("initial render: parent ×2, every child ×1, closure child ×2")
    func initialRender() {
        graph.update()
        graph.updateEnvironment { $0.scenePhase = .active }
        graph.update()
        var counts: [String: Int] = [:]
        for e in log.take() { counts[e, default: 0] += 1 }
        #expect(counts == ["parent": 2, "closure": 2, "noInput": 1, "intInput": 1, "readsA": 1, "readsB": 1,
                           "readsItems": 1, "legacyReadsA": 1, "legacyReadsNothing": 1, "envReader": 1,
                           "envSibling": 1, "equatable": 1])
    }

    @Test("parent @State changed: parent and the closure child only")
    func parentState() {
        start()
        #expect(bodies { driver.counter.value += 1 } == ["closure", "parent"])
    }

    @Test("@Observable a changed: only the reader of a")
    func observableA() {
        start()
        #expect(bodies { driver.model!.a += 1 } == ["readsA"])
    }

    @Test("@Observable b changed: only the reader of b")
    func observableB() {
        start()
        #expect(bodies { driver.model!.b += 1 } == ["readsB"])
    }

    @Test("@Observable array appended or mutated in place: only the reader of the array")
    func observableArray() {
        start()
        #expect(bodies { driver.model!.items.append(2) } == ["readsItems"])
        #expect(bodies { driver.model!.items[0] += 10 } == ["readsItems"])
    }

    @Test("@Observable property set to its current value: none")
    func observableSameValue() {
        start()
        #expect(bodies { driver.model!.a = driver.model!.a } == [])
    }

    @Test("@Published a changed: owner, both observers, closure child")
    func publishedA() {
        start()
        #expect(bodies { driver.legacy!.a += 1 } == ["closure", "legacyReadsA", "legacyReadsNothing", "parent"])
    }

    @Test("@Published b changed: the same set (per-object granularity)")
    func publishedB() {
        start()
        #expect(bodies { driver.legacy!.b += 1 } == ["closure", "legacyReadsA", "legacyReadsNothing", "parent"])
    }

    @Test("environment value changed: parent, reader, closure child; not the sibling")
    func environmentValue() {
        start()
        #expect(bodies { driver.envValue.value += 1 } == ["closure", "envReader", "parent"])
    }

    @Test("field ignored by a custom == changed under .equatable(): the child re-runs")
    func equatableIgnoredField() {
        start()
        #expect(bodies { driver.ignored.value += 1 } == ["closure", "equatable", "parent"])
    }

    @Test("parent @State set to its current value: none")
    func parentStateSameValue() {
        start()
        #expect(bodies { driver.counter.value = driver.counter.value } == [])
    }

    @Test("§4.2 rule 5: writes in one turn coalesce into one update")
    func coalescing() {
        start()
        let passes = graph.passCount
        #expect(bodies {
            driver.counter.value += 1
            driver.counter.value += 1
            driver.envValue.value += 1
        } == ["closure", "envReader", "parent"])
        #expect(graph.passCount == passes + 1)
    }

    @Test("parent order: bodies re-evaluate top-down")
    func topDown() {
        start()
        driver.counter.value += 1
        graph.update()
        #expect(log.take() == ["parent", "closure"])
    }
}
