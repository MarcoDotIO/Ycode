import Foundation

// Deliberate CPU work with its own ground truth: the program times each
// part and prints the shares, which a profile of it should reproduce.
// `collatzSteps` is the hot function (about three quarters of the main
// thread's time), `checksum` the second; a helper thread adds a little.

@inline(never)
func collatzSteps(upTo limit: Int) -> Int {
    var total = 0
    for start in 1...limit {
        var n = start
        while n != 1 {
            n = n & 1 == 0 ? n >> 1 : 3 &* n &+ 1
            total &+= 1
        }
    }
    return total
}

@inline(never)
func checksum(_ values: [UInt64]) -> UInt64 {
    var h: UInt64 = 1469598103934665603
    for _ in 0..<4 {
        for v in values { h = (h ^ v) &* 1099511628211 }
    }
    return h
}

func now() -> Double { Double(DispatchTime.now().uptimeNanoseconds) / 1e9 }

let seconds = CommandLine.arguments.count > 1 ? Double(CommandLine.arguments[1]) ?? 3 : 3
let values = (0..<100_000).map { UInt64($0) }
let helper = Thread {
    Thread.current.name = "helper"
    var x: UInt64 = 0
    while true {
        x &+= checksum(values)
        usleep(20_000)
    }
}
helper.name = "helper"
helper.start()

let start = now()
var rounds = 0, sum = 0
var collatzTime = 0.0, checksumTime = 0.0
var hash: UInt64 = 0
while now() - start < seconds {
    let a = now()
    // The limit changes with the round, so the call cannot be hoisted out of the loop.
    sum &+= collatzSteps(upTo: 30_000 + rounds & 7)
    let b = now()
    hash &+= checksum(values)
    collatzTime += b - a
    checksumTime += now() - b
    rounds += 1
}
let total = now() - start
print(String(format: "HotLoop: %d rounds in %.3f s; collatzSteps %.1f %%, checksum %.1f %% of the main thread (%d %d)",
             rounds, total, 100 * collatzTime / total, 100 * checksumTime / total, sum, hash))
