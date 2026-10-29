import Foundation

/// Base of every stored object (`interface.md` §3). Immutable; compared by UUID.
public class HKObject: NSObject, NSSecureCoding, @unchecked Sendable {
    let record: ObjectRecord

    init(record: ObjectRecord) {
        self.record = record
        super.init()
    }

    #if canImport(ObjectiveC)
    @objc public var uuid: UUID { record.uuid }
    #else
    public var uuid: UUID { record.uuid }
    #endif
    /// Assigned when saved; before that the calling app's current revision.
    public var sourceRevision: HKSourceRevision {
        HKSourceRevision(record: record.revision ?? YcodeHealthClient.processDefault.revisionRecord)
    }
    @available(*, deprecated, message: "Use sourceRevision")
    public var source: HKSource { sourceRevision.source }
    public var device: HKDevice? { record.device.map { HKDevice(record: $0) } }
    public var metadata: [String: Any]? { record.metadata?.mapValues(\.anyValue) }

    public override func isEqual(_ object: Any?) -> Bool {
        guard let other = object as? HKObject else { return false }
        return other.uuid == uuid
    }
    public override var hash: Int { uuid.hashValue }

    public class var supportsSecureCoding: Bool { true }
    public func encode(with coder: NSCoder) {
        coder.encode((try? JSONEncoder().encode(record)) ?? Data(), forKey: "record")
    }
    public required init?(coder: NSCoder) {
        guard let d = coder.decodeObject(of: NSData.self, forKey: "record") as Data?,
              let r = try? JSONDecoder().decode(ObjectRecord.self, from: d) else { return nil }
        record = r
        super.init()
    }

    /// Materialize the right class for a record.
    static func make(_ r: ObjectRecord) -> HKObject {
        switch r.kind {
        case .quantity:
            let style = (TypeRegistry.type(r.type) as? HKQuantityType)?.aggregationStyle ?? .cumulative
            return style == .cumulative ? HKCumulativeQuantitySample(record: r) : HKDiscreteQuantitySample(record: r)
        case .category: return HKCategorySample(record: r)
        case .correlation: return HKCorrelation(record: r)
        case .workout: return HKWorkout(record: r)
        }
    }
}

/// An object with a type and a date interval.
public class HKSample: HKObject, @unchecked Sendable {
    public override class var supportsSecureCoding: Bool { true }
    public var sampleType: HKSampleType { TypeRegistry.sampleType(record.type)! }
    #if canImport(ObjectiveC)
    @objc public var startDate: Date { Date(t: record.start) }
    #else
    public var startDate: Date { Date(t: record.start) }
    #endif
    #if canImport(ObjectiveC)
    @objc public var endDate: Date { Date(t: record.end) }
    #else
    public var endDate: Date { Date(t: record.end) }
    #endif
    public var hasUndeterminedDuration: Bool { record.end == Date.distantFuture.t }

    public override var description: String {
        "\(sampleType.identifier) \(startDate) - \(endDate) (\(uuid))"
    }

    static func baseRecord(kind: RecordKind, type: HKSampleType, start: Date, end: Date, device: HKDevice?,
                           metadata: [String: Any]?) throws(HKRaise) -> ObjectRecord {
        try Validation.interval(type, start: start, end: end)
        let md = try Validation.metadata(metadata)
        return ObjectRecord(uuid: UUID(), kind: kind, type: type.identifier, start: start.t, end: end.t,
                            revision: nil, device: device?.record, metadata: md)
    }
}

// MARK: - Quantity samples

/// A sample holding a quantity. Constructors return an `HKCumulativeQuantitySample`
/// or an `HKDiscreteQuantitySample` depending on the type's aggregation style.
public class HKQuantitySample: HKSample, @unchecked Sendable {
    public override class var supportsSecureCoding: Bool { true }
    // swiftlint:disable:next force_cast - the registry holds the subclass registered for this identifier
    public var quantityType: HKQuantityType { TypeRegistry.type(record.type) as! HKQuantityType }
    public var quantity: HKQuantity { HKQuantity(unit: HKUnit(from: record.unit), doubleValue: record.value) }
    #if canImport(ObjectiveC)
    @objc public var count: Int { record.count }
    #else
    public var count: Int { record.count }
    #endif

    public override var description: String {
        "\(quantity) \(sampleType.identifier) \(startDate) - \(endDate) (\(uuid))"
    }

    static func makeRecord(type: HKQuantityType, quantity: HKQuantity, start: Date, end: Date, device: HKDevice?,
                           metadata: [String: Any]?) throws(HKRaise) -> ObjectRecord {
        try Validation.quantity(type, quantity)
        var r = try baseRecord(kind: .quantity, type: type, start: start, end: end, device: device, metadata: metadata)
        r.value = quantity.value
        r.unit = quantity.unit.unitString
        r.ref = quantity.referenceValue
        return r
    }
}

public final class HKCumulativeQuantitySample: HKQuantitySample, @unchecked Sendable {
    public override class var supportsSecureCoding: Bool { true }
    public var sumQuantity: HKQuantity { quantity }
}

public final class HKDiscreteQuantitySample: HKQuantitySample, @unchecked Sendable {
    public override class var supportsSecureCoding: Bool { true }
    public var minimumQuantity: HKQuantity { quantity }
    public var averageQuantity: HKQuantity { quantity }
    public var maximumQuantity: HKQuantity { quantity }
    public var mostRecentQuantity: HKQuantity { quantity }
    public var mostRecentQuantityDateInterval: DateInterval { DateInterval(start: startDate, end: endDate) }
}

public protocol _HKQuantitySampleFactory {}
extension HKQuantitySample: _HKQuantitySampleFactory {}
extension _HKQuantitySampleFactory where Self: HKQuantitySample {
    public init(type quantityType: HKQuantityType, quantity: HKQuantity, start startDate: Date, end endDate: Date,
                device: HKDevice?, metadata: [String: Any]?) {
        let r = hkCheck { () throws(HKRaise) in
            try HKQuantitySample.makeRecord(type: quantityType, quantity: quantity, start: startDate, end: endDate,
                                            device: device, metadata: metadata)
        }
        // swiftlint:disable:next force_cast - HKObject.make builds the subclass the record type names
        self = HKObject.make(r) as! Self
    }
    public init(type quantityType: HKQuantityType, quantity: HKQuantity, start startDate: Date, end endDate: Date,
                metadata: [String: Any]?) {
        self.init(type: quantityType, quantity: quantity, start: startDate, end: endDate, device: nil, metadata: metadata)
    }
    public init(type quantityType: HKQuantityType, quantity: HKQuantity, start startDate: Date, end endDate: Date) {
        self.init(type: quantityType, quantity: quantity, start: startDate, end: endDate, device: nil, metadata: nil)
    }
}

// MARK: - Category samples

public final class HKCategorySample: HKSample, @unchecked Sendable {
    public override class var supportsSecureCoding: Bool { true }
    // swiftlint:disable:next force_cast - the registry holds the subclass registered for this identifier
    public var categoryType: HKCategoryType { TypeRegistry.type(record.type) as! HKCategoryType }
    #if canImport(ObjectiveC)
    @objc public var value: Int { record.categoryValue }
    #else
    public var value: Int { record.categoryValue }
    #endif

    public convenience init(type: HKCategoryType, value: Int, start startDate: Date, end endDate: Date,
                            device: HKDevice?, metadata: [String: Any]?) {
        let r = hkCheck { () throws(HKRaise) in
            try HKCategorySample.makeRecord(type: type, value: value, start: startDate, end: endDate,
                                            device: device, metadata: metadata)
        }
        self.init(record: r)
    }
    public convenience init(type: HKCategoryType, value: Int, start startDate: Date, end endDate: Date,
                            metadata: [String: Any]?) {
        self.init(type: type, value: value, start: startDate, end: endDate, device: nil, metadata: metadata)
    }
    public convenience init(type: HKCategoryType, value: Int, start startDate: Date, end endDate: Date) {
        self.init(type: type, value: value, start: startDate, end: endDate, device: nil, metadata: nil)
    }

    static func makeRecord(type: HKCategoryType, value: Int, start: Date, end: Date, device: HKDevice?,
                           metadata: [String: Any]?) throws(HKRaise) -> ObjectRecord {
        try Validation.category(type, value)
        var r = try baseRecord(kind: .category, type: type, start: start, end: end, device: device, metadata: metadata)
        r.categoryValue = value
        return r
    }

    public override var description: String {
        "\(value) \(sampleType.identifier) \(startDate) - \(endDate) (\(uuid))"
    }
}

// MARK: - Correlations

/// Groups related samples (`interface.md` §3). Saving a correlation saves its members.
public final class HKCorrelation: HKSample, @unchecked Sendable {
    public override class var supportsSecureCoding: Bool { true }
    // swiftlint:disable:next force_cast - the registry holds the subclass registered for this identifier
    public var correlationType: HKCorrelationType { TypeRegistry.type(record.type) as! HKCorrelationType }
    public var objects: Set<HKSample> {
        // swiftlint:disable:next force_cast - correlation members are samples
        Set((record.members ?? []).map { HKObject.make($0) as! HKSample })
    }
    public func objects(for objectType: HKObjectType) -> Set<HKSample> {
        // swiftlint:disable:next force_cast - correlation members are samples
        Set((record.members ?? []).filter { $0.type == objectType.identifier }.map { HKObject.make($0) as! HKSample })
    }

    public convenience init(type correlationType: HKCorrelationType, start startDate: Date, end endDate: Date,
                            objects: Set<HKSample>, device: HKDevice?, metadata: [String: Any]?) {
        let r = hkCheck { () throws(HKRaise) in
            try HKCorrelation.makeRecord(type: correlationType, start: startDate, end: endDate, objects: objects,
                                         device: device, metadata: metadata)
        }
        self.init(record: r)
    }
    public convenience init(type correlationType: HKCorrelationType, start startDate: Date, end endDate: Date,
                            objects: Set<HKSample>, metadata: [String: Any]?) {
        self.init(type: correlationType, start: startDate, end: endDate, objects: objects, device: nil, metadata: metadata)
    }
    public convenience init(type correlationType: HKCorrelationType, start startDate: Date, end endDate: Date,
                            objects: Set<HKSample>) {
        self.init(type: correlationType, start: startDate, end: endDate, objects: objects, device: nil, metadata: nil)
    }

    static func makeRecord(type: HKCorrelationType, start: Date, end: Date, objects: Set<HKSample>,
                           device: HKDevice?, metadata: [String: Any]?) throws(HKRaise) -> ObjectRecord {
        try Validation.correlation(type, objects)
        var r = try baseRecord(kind: .correlation, type: type, start: start, end: end, device: device, metadata: metadata)
        r.members = objects.map(\.record).sorted { ($0.start, $0.type) < ($1.start, $1.type) }
        return r
    }
}

// MARK: - Deleted objects

/// A tombstone returned by anchored queries (`queries.md` §4).
public final class HKDeletedObject: NSObject, NSSecureCoding, @unchecked Sendable {
    let record: TombstoneRecord
    public var uuid: UUID { record.uuid }
    public var metadata: [String: Any]? { record.metadata?.mapValues(\.anyValue) }

    init(record: TombstoneRecord) {
        self.record = record
        super.init()
    }

    public override func isEqual(_ object: Any?) -> Bool { (object as? HKDeletedObject)?.uuid == uuid }
    public override var hash: Int { uuid.hashValue }
    public override var description: String { "<HKDeletedObject \(uuid)>" }

    public static var supportsSecureCoding: Bool { true }
    public func encode(with coder: NSCoder) {
        coder.encode((try? JSONEncoder().encode(record)) ?? Data(), forKey: "record")
    }
    public required init?(coder: NSCoder) {
        guard let d = coder.decodeObject(of: NSData.self, forKey: "record") as Data?,
              let r = try? JSONDecoder().decode(TombstoneRecord.self, from: d) else { return nil }
        record = r
        super.init()
    }
}
