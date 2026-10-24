// A latency distribution for diagnostics (the boot profile's thread-start
// and wakeup latencies, specs/simulator/thread-latency.md §2).
//
// Buckets are a quarter of a power of two wide (about 19 % relative
// error), from 1 ns to 2^40 ns; every add takes a short leaf lock, so the
// histogram can be fed from any host thread, with or without locks held.

import Foundation
import Synchronization

public final class LatencyHistogram: Sendable {
    /// Four buckets per power of two, 0 ..< 2^40 ns.
    static let bucketCount = 4 * 40 + 1
    private struct State {
        var buckets = [UInt64](repeating: 0, count: LatencyHistogram.bucketCount)
        var count: UInt64 = 0
        var sum: UInt64 = 0
        var max: UInt64 = 0
    }
    private let state = Mutex(State())
    public let name: String

    public init(_ name: String) { self.name = name }

    /// The bucket of `ns`: 4·log2(ns), rounded down.
    static func bucket(_ ns: UInt64) -> Int {
        guard ns >= 2 else { return 0 }
        let log = 63 - ns.leadingZeroBitCount
        // The two bits below the leading one pick the quarter.
        let quarter = log >= 2 ? Int((ns >> UInt64(log - 2)) & 3) : Int((ns << UInt64(2 - log)) & 3)
        return min(bucketCount - 1, 4 * log + quarter)
    }

    /// The lower bound of bucket `i` (ns).
    static func lowerBound(_ i: Int) -> Double {
        let log = i / 4, quarter = i % 4
        return Double(UInt64(1) << UInt64(log)) * (1 + Double(quarter) / 4)
    }

    public func add(_ ns: UInt64) {
        let b = Self.bucket(ns)
        state.withLock {
            $0.buckets[b] &+= 1
            $0.count &+= 1
            $0.sum &+= ns
            if ns > $0.max { $0.max = ns }
        }
    }

    public var count: UInt64 { state.withLock { $0.count } }
    public var sumNanoseconds: UInt64 { state.withLock { $0.sum } }
    public var maxNanoseconds: UInt64 { state.withLock { $0.max } }

    /// The value below which `fraction` of the samples lie (bucket lower
    /// bound, ns); 0 when empty.
    public func percentile(_ fraction: Double) -> Double {
        let s = state.withLock { $0 }
        guard s.count > 0 else { return 0 }
        let rank = max(1, UInt64((Double(s.count) * fraction).rounded(.up)))
        var seen: UInt64 = 0
        for i in 0..<Self.bucketCount {
            seen &+= s.buckets[i]
            if seen >= rank { return Self.lowerBound(i) }
        }
        return Double(s.max)
    }

    /// One line: name, count, mean, p50, p90, p99, max (µs), sum (ms).
    public var summary: String {
        let n = count
        func us(_ v: Double) -> String { String(format: "%.0f", v / 1000) }
        let mean = n == 0 ? 0 : Double(sumNanoseconds) / Double(n)
        return "\(name): n \(n) mean \(us(mean)) p50 \(us(percentile(0.5))) p90 \(us(percentile(0.9))) "
            + "p99 \(us(percentile(0.99))) max \(us(Double(maxNanoseconds))) us; sum \(String(format: "%.1f", Double(sumNanoseconds) / 1e6)) ms"
    }
}
