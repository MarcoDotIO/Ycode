import Foundation

/// `HKStatisticsOptions` (raw values in `identifiers.md`).
public struct HKStatisticsOptions: OptionSet, Hashable, Sendable {
    public let rawValue: UInt
    public init(rawValue: UInt) { self.rawValue = rawValue }
    public static let separateBySource = HKStatisticsOptions(rawValue: 1)
    public static let discreteAverage = HKStatisticsOptions(rawValue: 2)
    public static let discreteMin = HKStatisticsOptions(rawValue: 4)
    public static let discreteMax = HKStatisticsOptions(rawValue: 8)
    public static let cumulativeSum = HKStatisticsOptions(rawValue: 16)
    public static let mostRecent = HKStatisticsOptions(rawValue: 32)
    @available(*, deprecated, renamed: "mostRecent")
    public static let discreteMostRecent = HKStatisticsOptions(rawValue: 32)
    public static let duration = HKStatisticsOptions(rawValue: 64)
}

/// Values of one statistics object, in the reference unit of the type's dimension.
struct StatValues: Codable, Hashable, Sendable {
    var sum: Double?
    var average: Double?
    var minimum: Double?
    var maximum: Double?
    var mostRecent: Double?
    var mostRecentStart: Double?
    var mostRecentEnd: Double?
    var duration: Double?
}

struct StatisticsResult: Codable, Hashable, Sendable {
    var type: String
    var start: Double
    var end: Double
    var unit: String                  // display unit for returned quantities
    var options: UInt
    var merged: StatValues
    var perSource: [String: StatValues]
    var sources: [SourceRecord]
    var hasData: Bool
}

/// The statistics engine (`queries.md` §6, `design.md` §6.3). Pure functions over
/// records; used by statistics queries, collections and (later) workout builders.
enum StatisticsEngine {
    /// Weight pad of temporally weighted averages (`queries.md` §6.3; fit to all measured cases).
    static let temporalWeightPad: Double = 45

    /// Raise for options the aggregation style does not support (`queries.md` §6.1).
    static func validate(_ options: HKStatisticsOptions, for type: HKQuantityType) throws(HKRaise) {
        let cumulativeOnly: HKStatisticsOptions = [.cumulativeSum]
        let discreteOnly: HKStatisticsOptions = [.discreteAverage, .discreteMin, .discreteMax]
        if type.aggregationStyle == .cumulative {
            let bad = options.intersection(discreteOnly)
            if !bad.isEmpty {
                throw .invalidArgument("Statistics option \(bad.rawValue) is not compatible with cumulative data type \(type.identifier)")
            }
        } else {
            let bad = options.intersection(cumulativeOnly)
            if !bad.isEmpty {
                throw .invalidArgument("Statistics option \(bad.rawValue) is not compatible with discrete data type \(type.identifier)")
            }
        }
    }

    // MARK: merging (`queries.md` §6.4)

    /// Keep, source by source in priority order, the samples that do not intersect
    /// the intervals already kept from higher-priority sources. Samples of the same
    /// source never de-duplicate each other; a dropped sample is dropped whole.
    static func deduplicate(_ records: [ObjectRecord], priority: [String]) -> [ObjectRecord] {
        let bySource = Dictionary(grouping: records, by: \.sourceBundle)
        var order = priority.filter { bySource[$0] != nil }
        order += bySource.keys.filter { !order.contains($0) }.sorted()
        var covered: [(Double, Double)] = []
        var kept: [ObjectRecord] = []
        for source in order {
            let mine = bySource[source]!.filter { r in !covered.contains { intersects(r.start, r.end, $0.0, $0.1) } }
            kept += mine
            covered += mine.map { ($0.start, $0.end) }
        }
        return kept
    }

    static func intersects(_ a0: Double, _ a1: Double, _ b0: Double, _ b1: Double) -> Bool {
        if a0 == a1 { return b0 == b1 ? a0 == b0 : (b0 <= a0 && a0 < b1) }
        if b0 == b1 { return a0 <= b0 && b0 < a1 }
        return a0 < b1 && b0 < a1
    }

    /// Length of the union of intervals.
    static func unionLength(_ intervals: [(Double, Double)]) -> Double {
        let sorted = intervals.sorted { $0.0 < $1.0 }
        var total = 0.0
        var cur: (Double, Double)?
        for i in sorted {
            if let c = cur, i.0 <= c.1 { cur = (c.0, max(c.1, i.1)) } else {
                if let c = cur { total += c.1 - c.0 }
                cur = i
            }
        }
        if let c = cur { total += c.1 - c.0 }
        return total
    }

    // MARK: one statistics object

    /// One contribution: the record and the share of its value that counts (1 = whole).
    struct Part {
        var record: ObjectRecord
        var fraction: Double
        var start: Double
        var end: Double
    }

    /// Contributions of `records` to the window; nil window = whole samples.
    static func parts(_ records: [ObjectRecord], window: (Double, Double)?) -> [Part] {
        guard let (w0, w1) = window else {
            return records.map { Part(record: $0, fraction: 1, start: $0.start, end: $0.end) }
        }
        var out: [Part] = []
        for r in records {
            if r.start == r.end {
                if w0 <= r.start && r.start < w1 { out.append(Part(record: r, fraction: 1, start: r.start, end: r.end)) }
                continue
            }
            let s = max(r.start, w0), e = min(r.end, w1)
            guard e > s else { continue }
            out.append(Part(record: r, fraction: (e - s) / (r.end - r.start), start: s, end: e))
        }
        return out
    }

    static func values(_ parts: [Part], style: HKQuantityAggregationStyle, options: HKStatisticsOptions) -> StatValues {
        var v = StatValues()
        guard !parts.isEmpty else { return v }
        if style == .cumulative {
            if options.contains(.cumulativeSum) { v.sum = parts.reduce(0) { $0 + $1.record.ref * $1.fraction } }
        } else {
            let values = parts.map(\.record.ref)
            if options.contains(.discreteAverage) {
                switch style {
                case .discreteTemporallyWeighted:
                    let w = parts.map { $0.record.duration + temporalWeightPad }
                    v.average = zip(values, w).reduce(0) { $0 + $1.0 * $1.1 } / w.reduce(0, +)
                case .discreteEquivalentContinuousLevel:
                    let w = parts.map { $0.record.duration + temporalWeightPad }
                    let energy = zip(values, w).reduce(0) { $0 + pow(10, $1.0 / 10) * $1.1 } / w.reduce(0, +)
                    v.average = 10 * log10(energy)
                default:
                    v.average = values.reduce(0, +) / Double(values.count)
                }
            }
            if options.contains(.discreteMin) { v.minimum = values.min() }
            if options.contains(.discreteMax) { v.maximum = values.max() }
        }
        if options.contains(.mostRecent), let last = mostRecent(parts.map(\.record)) {
            v.mostRecent = last.ref
            v.mostRecentStart = last.start
            v.mostRecentEnd = last.end
        }
        if options.contains(.duration) { v.duration = unionLength(parts.map { ($0.start, $0.end) }) }
        return v
    }

    /// The sample with the latest end date (ties: later start, then later anchor).
    static func mostRecent(_ records: [ObjectRecord]) -> ObjectRecord? {
        records.max { ($0.end, $0.start, $0.anchor) < ($1.end, $1.start, $1.anchor) }
    }

    /// Compute one statistics object.
    /// - Parameters:
    ///   - all: every matching, readable sample.
    ///   - merged: the de-duplicated set (cumulative types) used for the merged values.
    ///   - window: a collection bucket (prorated) or nil for a statistics query (whole samples).
    static func compute(type: HKQuantityType, all: [ObjectRecord], merged: [ObjectRecord],
                        options: HKStatisticsOptions, window: (Double, Double)?) -> StatisticsResult {
        let style = type.aggregationStyle
        let allParts = parts(all, window: window)
        let mergedParts = style == .cumulative ? parts(merged, window: window) : allParts
        var result = StatisticsResult(type: type.identifier, start: window?.0 ?? 0, end: window?.1 ?? 0,
                                      unit: displayUnit(type, allParts.map(\.record)), options: options.rawValue,
                                      merged: values(mergedParts, style: style, options: options), perSource: [:],
                                      sources: [], hasData: !allParts.isEmpty)
        if window == nil, !allParts.isEmpty {
            result.start = allParts.map(\.record.start).min()!
            result.end = allParts.map(\.record.end).max()!
        }
        if options.contains(.separateBySource) {
            let grouped = Dictionary(grouping: allParts, by: \.record.sourceBundle)
            for (bundle, ps) in grouped {
                result.perSource[bundle] = values(ps, style: style, options: options)
            }
            result.sources = grouped.keys.sorted().compactMap { b in grouped[b]?.first?.record.revision?.source }
        }
        return result
    }

    static func displayUnit(_ type: HKQuantityType, _ records: [ObjectRecord]) -> String {
        if let r = mostRecent(records), !r.unit.isEmpty { return r.unit }
        switch type.quantityDimension {
        case .scalar: return "count"
        case .mass: return "g"
        case .length: return "m"
        case .volume: return "L"
        case .time: return "s"
        case .energy: return "kcal"
        case .temperature: return "degC"
        case .pressure: return "mmHg"
        case .speed: return "m/s"
        case .frequency: return "count/min"
        case .power: return "W"
        case .conductance: return "S"
        case .soundPressureLevel: return "dBASPL"
        case .effortScore: return "appleEffortScore"
        case .pharmacology: return "IU"
        case .volumeFlow: return "L/min"
        case .energyRatePerMass: return "kcal/(kg*hr)"
        case .vo2Rate: return "mL/(kg*min)"
        case .massConcentration: return "mg/dL"
        }
    }
}
