import Foundation

/// Hangs, signpost intervals and the timeline's per-column counts
/// (`specs/ide/profiler.md` §2.2, §2.3, §4.4).
public enum GaugeTimeline {
    // MARK: Hangs

    /// Hangs of `thread` (default: the main thread): maximal runs of samples
    /// in a non-idle state, at least `threshold` long. A run ends at the
    /// first idle sample; its end is the last non-idle sample plus one
    /// sample interval.
    public static func hangs(_ t: GaugeTrace, thread: UInt64? = nil, threshold: UInt64? = nil) -> [GaugeTrace.Hang] {
        guard let tid = thread ?? t.mainThread?.id else { return [] }
        let limit = threshold ?? t.recording.hangThresholdNs
        let step = t.recording.sampleIntervalNs
        var out: [GaugeTrace.Hang] = []
        var begin: UInt64?, last: UInt64 = 0
        // A long gap between samples (the thread did not exist or the
        // recorder paused) also ends a run. Short gaps do not: a sampler
        // under host load, or a kicked vCPU that did not answer, skips a
        // few samples of a thread that kept running.
        let gap = Self.hangGapLimit(interval: step, threshold: limit)
        func close() {
            if let b = begin, last &+ step &- b >= limit { out.append(.init(thread: tid, begin: b, end: last &+ step)) }
            begin = nil
        }
        for i in 0..<t.samples.count where t.samples.thread[i] == tid {
            let time = t.samples.time[i]
            if begin != nil, time > last &+ gap { close() }
            if t.samples.state[i] == .idle {
                close()
            } else {
                if begin == nil { begin = time }
                last = time
            }
        }
        close()
        return out
    }

    /// The longest gap between two samples of a thread that a hang
    /// bridges: max(4 sample intervals, a quarter of the threshold).
    public static func hangGapLimit(interval: UInt64, threshold: UInt64) -> UInt64 {
        max(4 * interval, threshold / 4)
    }

    /// Signpost rows for a timeline: names, the target's own first (its
    /// subsystem is the recorded command, an app's bundle identifier),
    /// then intervals before events, then by count; ties by first
    /// appearance. At most `limit` names.
    public static func signpostRows(_ t: GaugeTrace, limit: Int = .max) -> [String] {
        struct Row { var first: Int; var own = false; var interval = false; var count = 0 }
        var rows: [String: Row] = [:]
        let own = t.recording.command
        for (i, s) in t.signposts.enumerated() {
            var r = rows[s.name] ?? Row(first: i)
            r.count += 1
            if !own.isEmpty && s.subsystem == own { r.own = true }
            if s.kind == .interval { r.interval = true }
            rows[s.name] = r
        }
        let ordered = rows.sorted { a, b in
            if a.value.own != b.value.own { return a.value.own }
            if a.value.interval != b.value.interval { return a.value.interval }
            if a.value.count != b.value.count { return a.value.count > b.value.count }
            return a.value.first < b.value.first
        }
        return ordered.prefix(limit).map(\.key)
    }

    /// "Hang" or "Severe Hang" (4 × the threshold).
    public static func severity(_ h: GaugeTrace.Hang, threshold: UInt64) -> String {
        h.duration >= 4 * threshold ? "Severe Hang" : "Hang"
    }

    // MARK: Signposts

    /// A raw signpost record (as the in-app agent writes it).
    public struct SignpostEvent: Sendable, Equatable {
        public enum Kind: UInt8, Sendable { case event = 0, begin = 1, end = 2 }
        public var time: UInt64
        public var kind: Kind
        public var id: UInt64
        public var thread: UInt64
        public var subsystem: String
        public var category: String
        public var name: String
        public var message: String
        public init(time: UInt64, kind: Kind, id: UInt64, thread: UInt64, subsystem: String, category: String, name: String, message: String) {
            self.time = time
            self.kind = kind
            self.id = id
            self.thread = thread
            self.subsystem = subsystem
            self.category = category
            self.name = name
            self.message = message
        }
    }

    /// `OS_SIGNPOST_ID_EXCLUSIVE` (os/signpost.h).
    public static let exclusiveID: UInt64 = 0xEEEE_B0B5_B2B2_EEEE

    /// Matches begins and ends (§2.3): key (subsystem, category, id, name);
    /// exclusive ids match by (subsystem, category, name). Events stay
    /// events; an unmatched end becomes an event flagged `unmatched`; an
    /// open begin ends at `recordingEnd`, flagged `open`.
    public static func intervals(_ events: [SignpostEvent], recordingEnd: UInt64) -> [GaugeTrace.Signpost] {
        struct Key: Hashable { var subsystem: String; var category: String; var id: UInt64; var name: String }
        var open: [Key: [Int]] = [:]
        var out: [GaugeTrace.Signpost] = []
        for e in events.sorted(by: { $0.time < $1.time }) {
            let key = Key(subsystem: e.subsystem, category: e.category, id: e.id == exclusiveID ? 0 : e.id, name: e.name)
            switch e.kind {
            case .event:
                out.append(.init(name: e.name, subsystem: e.subsystem, category: e.category, id: e.id, thread: e.thread,
                                 begin: e.time, end: e.time, kind: .event, message: e.message))
            case .begin:
                open[key, default: []].append(out.count)
                out.append(.init(name: e.name, subsystem: e.subsystem, category: e.category, id: e.id, thread: e.thread,
                                 begin: e.time, end: nil, kind: .interval, message: e.message))
            case .end:
                if var list = open[key], let i = list.popLast() {
                    out[i].end = e.time
                    if !e.message.isEmpty && out[i].message != e.message {
                        out[i].message = out[i].message.isEmpty ? e.message : out[i].message + " — " + e.message
                    }
                    open[key] = list
                } else {
                    out.append(.init(name: e.name, subsystem: e.subsystem, category: e.category, id: e.id, thread: e.thread,
                                     begin: e.time, end: e.time, kind: .event, message: e.message, flags: ["unmatched"]))
                }
            }
        }
        for i in out.indices where out[i].kind == .interval && out[i].end == nil {
            out[i].end = max(recordingEnd, out[i].begin)
            out[i].flags.append("open")
        }
        return out
    }

    public struct SignpostSummary: Sendable, Equatable {
        public var name: String
        public var count: Int
        public var totalNs: UInt64
        public var maxNs: UInt64
        public var minNs: UInt64
        public var meanNs: UInt64 { totalNs / UInt64(max(1, count)) }

        /// Nothing counted yet.
        public init(name: String) {
            self.name = name
            count = 0
            totalNs = 0
            maxNs = 0
            minNs = .max
        }
    }

    /// Per name: intervals' count, total, min, max (events count with 0).
    public static func summarize(_ s: [GaugeTrace.Signpost]) -> [SignpostSummary] {
        var by: [String: SignpostSummary] = [:]
        for p in s {
            let d = p.kind == .interval ? p.duration : 0
            var e = by[p.name] ?? SignpostSummary(name: p.name)
            e.count += 1
            e.totalNs += d
            e.maxNs = max(e.maxNs, d)
            e.minNs = min(e.minNs, d)
            by[p.name] = e
        }
        return by.values.sorted { $0.totalNs != $1.totalNs ? $0.totalNs > $1.totalNs : $0.name < $1.name }
    }

    // MARK: CPU track

    /// CPU samples per column: `columns` equal slices of [range]; (user, kernel) counts.
    public static func cpuColumns(_ t: GaugeTrace, range: Range<UInt64>, columns: Int,
                                  threads: Set<UInt64>? = nil) -> [(user: Int, kernel: Int)] {
        guard columns > 0, range.upperBound > range.lowerBound else { return [] }
        var out = Array(repeating: (user: 0, kernel: 0), count: columns)
        let span = Double(range.upperBound - range.lowerBound)
        for i in 0..<t.samples.count {
            let time = t.samples.time[i]
            guard range.contains(time), t.samples.state[i].isCPU else { continue }
            if let th = threads, !th.contains(t.samples.thread[i]) { continue }
            let c = min(columns - 1, Int(Double(time - range.lowerBound) / span * Double(columns)))
            if t.samples.state[i] == .user { out[c].user += 1 } else { out[c].kernel += 1 }
        }
        return out
    }

    /// Frame intervals between presents longer than `factor` × the median
    /// interval: (present time, interval ns).
    public static func longFrames(_ presents: [UInt64], factor: Double = 1.5) -> [(time: UInt64, interval: UInt64)] {
        guard presents.count > 2 else { return [] }
        let intervals = zip(presents.dropFirst(), presents).map { $0 &- $1 }
        let sorted = intervals.sorted()
        let median = Double(sorted[sorted.count / 2])
        return zip(presents.dropFirst(), intervals).filter { Double($0.1) > factor * median }.map { ($0.0, $0.1) }
    }
}
