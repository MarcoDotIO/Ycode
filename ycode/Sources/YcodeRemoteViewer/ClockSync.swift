// The viewer's estimate of the display server's clock (display-stream.md
// §12.2): NTP-style, from pings. A ping leaves at client time t0, the pong
// carries the server's monotonic time s, it arrives at t1. With the server
// time taken half-way, offset = s − (t0 + t1) / 2, uncertain by ± rtt / 2.
// The sample with the smallest round trip among the recent ones wins
// (queueing only ever adds delay), so the estimate's error is bounded by
// half the best round trip.

import Foundation

public struct ClockSync: Sendable, Equatable {
    public struct Sample: Sendable, Equatable {
        public var rtt: Int64
        public var offset: Int64
        public var at: UInt64
    }

    /// Samples older than this (client ns) are dropped: the clocks drift a
    /// few ppm, which over a minute is well under a millisecond.
    public var window: UInt64 = 60_000_000_000
    public private(set) var samples: [Sample] = []

    public init() {}

    /// One ping: sent at `t0`, pong (server time `server`) received at `t1`, all ns.
    public mutating func add(sent t0: UInt64, server: UInt64, received t1: UInt64) {
        guard t1 >= t0 else { return }
        let rtt = Int64(t1 - t0)
        let mid = t0 / 2 + t1 / 2 + (t0 % 2 + t1 % 2) / 2
        let offset = Int64(bitPattern: server &- mid)
        samples.append(Sample(rtt: rtt, offset: offset, at: t1))
        samples.removeAll { t1 &- $0.at > window }
        if samples.count > 64 { samples.removeFirst(samples.count - 64) }
    }

    /// The best sample (smallest round trip), nil before the first pong.
    public var best: Sample? { samples.min { $0.rtt < $1.rtt } }

    /// server − client, ns.
    public var offset: Int64? { best?.offset }

    /// Half the best round trip: the bound on the offset's error, ns.
    public var uncertainty: Int64? { best.map { $0.rtt / 2 } }

    /// A server monotonic time on the client's clock.
    public func clientTime(server: UInt64) -> UInt64? {
        guard let o = offset else { return nil }
        return UInt64(bitPattern: Int64(bitPattern: server) &- o)
    }
}

/// The client's monotonic clock (ns), the same as the server's kind
/// (CLOCK_MONOTONIC on Linux; on macOS the uptime clock).
public func viewerNanoseconds() -> UInt64 {
    var t = timespec()
    #if canImport(Darwin)
    clock_gettime(CLOCK_UPTIME_RAW, &t)
    #else
    clock_gettime(CLOCK_MONOTONIC, &t)
    #endif
    return UInt64(t.tv_sec) * 1_000_000_000 + UInt64(t.tv_nsec)
}
