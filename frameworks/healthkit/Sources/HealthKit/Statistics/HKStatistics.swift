import Foundation

/// Result of a statistics computation over quantity samples (`queries.md` §6).
public final class HKStatistics: NSObject, NSSecureCoding, NSCopying, @unchecked Sendable {
    let result: StatisticsResult

    init(result: StatisticsResult) {
        self.result = result
        super.init()
    }

    // swiftlint:disable:next force_cast - statistics are computed for quantity types only
    public var quantityType: HKQuantityType { TypeRegistry.type(result.type) as! HKQuantityType }
    public var startDate: Date { Date(t: result.start) }
    public var endDate: Date { Date(t: result.end) }
    /// Sources that contributed (only with `.separateBySource`).
    public var sources: [HKSource]? {
        HKStatisticsOptions(rawValue: result.options).contains(.separateBySource)
            ? result.sources.map { HKSource(record: $0) } : nil
    }

    private var unit: HKUnit { HKUnit(from: result.unit) }
    private func q(_ ref: Double?) -> HKQuantity? {
        ref.map { HKQuantity(unit: unit, doubleValue: unit.fromReference($0)) }
    }
    private func values(_ source: HKSource) -> StatValues? { result.perSource[source.bundleIdentifier] }

    public func averageQuantity() -> HKQuantity? { q(result.merged.average) }
    public func averageQuantity(for source: HKSource) -> HKQuantity? { q(values(source)?.average) }
    public func minimumQuantity() -> HKQuantity? { q(result.merged.minimum) }
    public func minimumQuantity(for source: HKSource) -> HKQuantity? { q(values(source)?.minimum) }
    public func maximumQuantity() -> HKQuantity? { q(result.merged.maximum) }
    public func maximumQuantity(for source: HKSource) -> HKQuantity? { q(values(source)?.maximum) }
    public func mostRecentQuantity() -> HKQuantity? { q(result.merged.mostRecent) }
    public func mostRecentQuantity(for source: HKSource) -> HKQuantity? { q(values(source)?.mostRecent) }
    public func mostRecentQuantityDateInterval() -> DateInterval? { interval(result.merged) }
    public func mostRecentQuantityDateInterval(for source: HKSource) -> DateInterval? { values(source).flatMap(interval) }
    public func sumQuantity() -> HKQuantity? { q(result.merged.sum) }
    public func sumQuantity(for source: HKSource) -> HKQuantity? { q(values(source)?.sum) }
    public func duration() -> HKQuantity? { result.merged.duration.map { HKQuantity(unit: .second(), doubleValue: $0) } }
    public func duration(for source: HKSource) -> HKQuantity? {
        values(source)?.duration.map { HKQuantity(unit: .second(), doubleValue: $0) }
    }

    private func interval(_ v: StatValues) -> DateInterval? {
        guard let s = v.mostRecentStart, let e = v.mostRecentEnd else { return nil }
        return DateInterval(start: Date(t: s), end: Date(t: e))
    }

    public override var description: String {
        "<HKStatistics \(result.type) \(startDate) - \(endDate)>"
    }

    public static var supportsSecureCoding: Bool { true }
    public func encode(with coder: NSCoder) {
        coder.encode((try? JSONEncoder().encode(result)) ?? Data(), forKey: "result")
    }
    public required init?(coder: NSCoder) {
        guard let d = coder.decodeObject(of: NSData.self, forKey: "result") as Data?,
              let r = try? JSONDecoder().decode(StatisticsResult.self, from: d) else { return nil }
        result = r
        super.init()
    }
    public func copy(with zone: NSZone? = nil) -> Any { self }
}

/// Statistics laid out in buckets from an anchor date (`queries.md` §6.5).
public final class HKStatisticsCollection: NSObject, @unchecked Sendable {
    let type: HKQuantityType
    let options: HKStatisticsOptions
    let anchor: Date
    let components: DateComponents
    let calendar: Calendar
    let all: [ObjectRecord]
    let merged: [ObjectRecord]
    private let cache = Locked<[Int: HKStatistics]>([:])

    init(type: HKQuantityType, options: HKStatisticsOptions, anchor: Date, components: DateComponents,
         calendar: Calendar, input: StatisticsInput) {
        self.type = type
        self.options = options
        self.anchor = anchor
        self.components = components
        self.calendar = calendar
        self.all = input.records
        self.merged = type.aggregationStyle == .cumulative
            ? StatisticsEngine.deduplicate(input.records, priority: input.priority) : input.records
        super.init()
    }

    // MARK: bucket arithmetic (calendar steps from the anchor)

    private func scaled(_ k: Int) -> DateComponents {
        var c = DateComponents()
        if let v = components.era { c.era = v * k }
        if let v = components.year { c.year = v * k }
        if let v = components.month { c.month = v * k }
        if let v = components.day { c.day = v * k }
        if let v = components.hour { c.hour = v * k }
        if let v = components.minute { c.minute = v * k }
        if let v = components.second { c.second = v * k }
        if let v = components.nanosecond { c.nanosecond = v * k }
        if let v = components.weekOfYear { c.weekOfYear = v * k }
        if let v = components.weekOfMonth { c.weekOfMonth = v * k }
        return c
    }

    func bucketStart(_ k: Int) -> Date {
        k == 0 ? anchor : (calendar.date(byAdding: scaled(k), to: anchor) ?? anchor)
    }

    func bucketIndex(_ date: Date) -> Int {
        let step = bucketStart(1).timeIntervalSince(anchor)
        guard step > 0 else { return 0 }
        var k = Int((date.timeIntervalSince(anchor) / step).rounded(.down))
        while bucketStart(k) > date { k -= 1 }
        while bucketStart(k + 1) <= date { k += 1 }
        return k
    }

    func statistics(bucket k: Int) -> HKStatistics {
        if let hit = cache.withLock({ $0[k] }) { return hit }
        let w = (bucketStart(k).t, bucketStart(k + 1).t)
        let s = HKStatistics(result: StatisticsEngine.compute(type: type, all: all, merged: merged, options: options, window: w))
        cache.withLock { $0[k] = s }
        return s
    }

    /// Buckets touched by at least one sample.
    private var populatedBuckets: [Int] {
        var ks = Set<Int>()
        for r in all {
            let first = bucketIndex(Date(t: r.start))
            if r.start == r.end { ks.insert(first); continue }
            var last = bucketIndex(Date(t: r.end))
            if bucketStart(last).t >= r.end { last -= 1 }
            if last >= first { for k in first...last { ks.insert(k) } }
        }
        return ks.sorted()
    }

    // MARK: API

    /// The statistics of the bucket that contains `date`.
    public func statistics(for date: Date) -> HKStatistics? { statistics(bucket: bucketIndex(date)) }

    /// Visit every bucket from the one containing `startDate` through the one containing `endDate`.
    public func enumerateStatistics(from startDate: Date, to endDate: Date,
                                    with block: (HKStatistics, UnsafeMutablePointer<ObjCBool>) -> Void) {
        let first = bucketIndex(startDate), last = bucketIndex(endDate)
        guard last >= first else { return }
        var stop: ObjCBool = false
        for k in first...last {
            block(statistics(bucket: k), &stop)
            if stop.boolValue { break }
        }
    }

    /// Only the buckets that have data.
    public func statistics() -> [HKStatistics] {
        populatedBuckets.map { statistics(bucket: $0) }.filter(\.result.hasData)
    }

    public func sources() -> Set<HKSource> {
        Set(all.compactMap { $0.revision.map { HKSource(record: $0.source) } })
    }
}
