import Foundation
import Testing
#if OPENVIEWS_RENAMED
@testable import OpenViewsCore
@testable import OpenViews
#else
@testable import SwiftUICore
@testable import SwiftUI
#endif

// 03-architecture.md §3 (`onChange`), §2 (`task(id:)`), §5 (update-cycle
// order) and §7 (preferences; checklist K-2 `df.pref=first,second`).

struct OnChangeProbe: View {
    let log: Log
    let value: Controls<Int>
    var initial = false
    @State var v = 0

    var body: some View {
        let _ = { value.binding = $v }()
        let _ = log("parent.body")
        VStack {
            ReadsValue(log: log, v: v)
        }
        .onChange(of: v, initial: initial) { old, new in log("onChange \(old)->\(new)") }
    }
}

struct ReadsValue: View {
    let log: Log
    let v: Int
    var body: some View {
        let _ = log("child.body")
        Text("\(v)")
    }
}

struct TaskProbe: View {
    let log: Log
    let id: Controls<Int>
    let show: Controls<Bool>
    @State var n = 1
    @State var shown = true

    var body: some View {
        let _ = { id.binding = $n; show.binding = $shown }()
        if shown {
            Text("task")
                .task(id: n) { [n] in
                    log("start \(n)")
                    do {
                        try await Task.sleep(nanoseconds: 60_000_000_000)
                    } catch {
                        log("cancelled \(n)")
                    }
                }
                .onAppear { log("onAppear") }
        }
    }
}

@MainActor
func waitUntil(_ condition: () -> Bool) async {
    for _ in 0..<500 where !condition() {
        try? await Task.sleep(nanoseconds: 2_000_000)
    }
}

@MainActor
@Suite("03 §3, §5 lifecycle actions")
struct LifecycleTests {
    let log = Log()

    @Test("onChange runs with old and new values, after the change, before the content updates")
    func onChangeOrder() {
        let c = Controls<Int>()
        let g = ViewGraph.rendered(OnChangeProbe(log: log, value: c))
        #expect(log.take() == ["parent.body", "child.body"])
        c.value = 5
        g.update()
        #expect(log.take() == ["parent.body", "onChange 0->5", "child.body"])
        c.value = 5
        g.update()
        #expect(log.take() == [])
    }

    @Test("onChange(initial: true) also runs once when the view appears, with old == new")
    func onChangeInitial() {
        let c = Controls<Int>()
        let g = ViewGraph.rendered(OnChangeProbe(log: log, value: c, initial: true))
        #expect(log.take() == ["parent.body", "child.body", "onChange 0->0"])
        c.value = 1
        g.update()
        #expect(log.take() == ["parent.body", "onChange 0->1", "child.body"])
    }

    @Test("task starts on appear, after onAppear; task(id:) change cancels and restarts in the same update")
    func taskRestart() async {
        let id = Controls<Int>(), show = Controls<Bool>()
        let g = ViewGraph.rendered(TaskProbe(log: log, id: id, show: show))
        await waitUntil { log.entries.contains("start 1") }
        #expect(log.take() == ["onAppear", "start 1"])
        id.value = 2
        g.update()
        await waitUntil { log.entries.contains("start 2") && log.entries.contains("cancelled 1") }
        #expect(Set(log.take()) == ["cancelled 1", "start 2"])
        show.value = false
        g.update()
        await waitUntil { log.entries.contains("cancelled 2") }
        #expect(log.take() == ["cancelled 2"])
    }

    @Test("a write from a background task is applied on the main actor in a later update")
    func backgroundWrite() async {
        let c = Controls<Int>()
        let g = ViewGraph.rendered(OnChangeProbe(log: log, value: c))
        _ = log.take()
        let binding = UncheckedBox(c.binding!)
        await Task.detached { binding.value.wrappedValue = 7 }.value
        await waitUntil { g.needsUpdate }
        g.update()
        #expect(log.take() == ["parent.body", "onChange 0->7", "child.body"])
    }
}

// MARK: - Preferences

struct NamesKey: PreferenceKey {
    static var defaultValue: [String] { [] }
    static func reduce(value: inout [String], nextValue: () -> [String]) { value += nextValue() }
}

struct LastKey: PreferenceKey {
    static var defaultValue: String { "default" }
    static func reduce(value: inout String, nextValue: () -> String) { value = nextValue() }
}

struct PreferenceProbe: View {
    let log: Log
    let second: Controls<String>
    @State var secondName = "second"

    var body: some View {
        let _ = { second.binding = $secondName }()
        VStack {
            Text("A").preference(key: NamesKey.self, value: ["first"])
            Text("B").preference(key: NamesKey.self, value: [secondName])
            Text("C")
        }
        .onPreferenceChange(NamesKey.self) { log("pref=" + $0.joined(separator: ",")) }
    }
}

struct PreferenceNesting: View {
    let log: Log
    var body: some View {
        VStack {
            VStack {
                Color.red.preference(key: LastKey.self, value: "inner1")
                Color.red.preference(key: LastKey.self, value: "inner2")
            }
            Color.blue
            Color.green.transformPreference(LastKey.self) { $0 += "+t" }
        }
        .onPreferenceChange(LastKey.self) { log("last=" + $0) }
    }
}

struct PreferenceOverlay: View {
    let log: Log
    var body: some View {
        VStack {
            Text("A").preference(key: NamesKey.self, value: ["x", "y"])
        }
        .overlayPreferenceValue(NamesKey.self) { names in
            // swiftlint:disable:next redundant_discardable_let - a side effect inside a view builder
            let _ = log("overlay \(names.count)")
            Color.clear
        }
    }
}

@MainActor
@Suite("03 §7 preferences (K-2)")
struct PreferenceTests {
    let log = Log()

    @Test("siblings reduce in declaration order: first,second; onPreferenceChange runs once in the initial update")
    func declarationOrder() {
        let c = Controls<String>()
        let g = ViewGraph.rendered(PreferenceProbe(log: log, second: c))
        #expect(log.take() == ["pref=first,second"])
        c.value = "changed"
        g.update()
        #expect(log.take() == ["pref=first,changed"])
        c.value = "changed"
        g.update()
        #expect(log.take() == [])
        #expect(g.rootPreferences[NamesKey.self] == ["first", "changed"])
    }

    @Test("nested reduction and transformPreference")
    func nesting() {
        _ = ViewGraph.rendered(PreferenceNesting(log: log))
        // inner1 reduced with inner2 → inner2; the green colour starts from
        // the default and transforms it; reduced last.
        #expect(log.take() == ["last=default+t"])
    }

    @Test("overlayPreferenceValue builds its view from the reduced value (one extra pass)")
    func overlayPreference() {
        let g = ViewGraph.rendered(PreferenceOverlay(log: log))
        #expect(log.take() == ["overlay 0", "overlay 2"])
        #expect(g.passCount == 2)
    }
}
