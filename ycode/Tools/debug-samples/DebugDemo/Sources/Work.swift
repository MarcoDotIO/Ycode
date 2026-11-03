// DebugDemo: the work the debugger looks at (specs/simulator/debug-stub.md
// §9). Original Ycode sample code.

struct Stats {
    var rounds = 0
    var total = 0
    var largest = 0
}

func fibonacci(_ n: Int) -> Int {
    var a = 0
    var b = 1
    for _ in 0..<n {
        let next = a &+ b
        a = b
        b = next
    }
    return a
}

func work(round: Int, stats: inout Stats) -> Int {
    let n = 10 + round % 20
    let value = fibonacci(n)
    stats.rounds += 1
    stats.total &+= value
    if value > stats.largest { stats.largest = value }
    return value
}
