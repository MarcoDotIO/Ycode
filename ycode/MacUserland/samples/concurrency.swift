// concurrency.swift - a stage-B sample (specs/macos/swift-runtime.md §9): actors,
// task groups, Task.sleep on dispatch timers, detached tasks, the main
// actor. Built by swift/build.sh; run-samples.sh checks concurrency.expected.
actor Counter { var n = 0; func add(_ k: Int) { n += k } }
@main struct Main {
  static func main() async {
    let c = Counter()
    await withTaskGroup(of: Void.self) { g in for i in 1...100 { g.addTask { await c.add(i) } } }
    print("sum", await c.n)
    let start = ContinuousClock.now
    try? await Task.sleep(for: .milliseconds(50))
    print("slept >= 50ms:", ContinuousClock.now - start >= .milliseconds(50))
    let r = await Task.detached { (1...10).reduce(1, *) }.value
    print("factorial", r)
    await MainActor.run { print("on main actor") }
  }
}
