// Milestone A sample: a small Embedded Swift program (no Swift runtime
// library; it needs only libc's allocator and putchar).
// specs/macos/macos-apps.md §9.1. Ycode's own test program.
struct Fibonacci: Sequence, IteratorProtocol {
    var a = 0, b = 1
    mutating func next() -> Int? {
        defer { (a, b) = (b, a + b) }
        return a
    }
}

final class Counter {
    var hits: [String: Int] = [:]
    func record(_ word: String) { hits[word, default: 0] += 1 }
}

@_extern(c, "exit") func cExit(_ status: Int32)

@main
struct Main {
    static func main() {
        print("hello from Swift on Ycode")
        let fib = Array(Fibonacci().prefix(15))
        var line = "fibonacci:"
        for n in fib { line += " \(n)" }  // Embedded Swift cannot print an Array directly
        print(line)
        let counter = Counter()
        for word in ["a", "b", "a", "c", "a", "b"] { counter.record(word) }
        let keys = counter.hits.keys.sorted()
        for key in keys { print("\(key): \(counter.hits[key]!)") }
        let ok = fib.last == 377 && counter.hits["a"] == 3
        print(ok ? "swift ok" : "swift FAILED")
        cExit(ok ? 0 : 1)
    }
}
