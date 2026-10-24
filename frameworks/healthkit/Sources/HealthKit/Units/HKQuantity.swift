import Foundation

/// A double value with a unit (`units.md` §1). Equality and ordering work across
/// compatible units; mixing incompatible units raises `NSInvalidArgumentException`.
public final class HKQuantity: NSObject, NSSecureCoding, NSCopying, @unchecked Sendable {
    let value: Double
    let unit: HKUnit

    public init(unit: HKUnit, doubleValue value: Double) {
        self.unit = unit
        self.value = value
        super.init()
    }

    public func `is`(compatibleWith unit: HKUnit) -> Bool { self.unit.isCompatible(with: unit) }

    /// The value expressed in `unit`; raises for an incompatible unit.
    public func doubleValue(for unit: HKUnit) -> Double {
        hkCheck { () throws(HKRaise) in try HKUnit.convert(value, from: self.unit, to: unit) }
    }

    public func compare(_ quantity: HKQuantity) -> ComparisonResult {
        hkCheck { () throws(HKRaise) in try compareChecked(quantity) }
    }

    func compareChecked(_ quantity: HKQuantity) throws(HKRaise) -> ComparisonResult {
        guard unit.isCompatible(with: quantity.unit) else {
            throw .invalidArgument("Quantity \(quantity) has incompatible unit \(quantity.unit.unitString) (expected \(unit.unitString))")
        }
        let a = referenceValue, b = quantity.referenceValue
        return a < b ? .orderedAscending : (a > b ? .orderedDescending : .orderedSame)
    }

    /// Value in the dimension's reference units.
    var referenceValue: Double { unit.toReference(value) }

    public override func isEqual(_ object: Any?) -> Bool {
        guard let other = object as? HKQuantity, unit.isCompatible(with: other.unit) else { return false }
        if unit === other.unit { return value == other.value }
        return abs(referenceValue - other.referenceValue) <= 1e-12 * max(abs(referenceValue), 1)
    }
    public override var hash: Int { unit.dimension.hashValue }
    public override var description: String { "\(value.compactText) \(unit.unitString)" }

    public static var supportsSecureCoding: Bool { true }
    public func encode(with coder: NSCoder) {
        coder.encode(value, forKey: "value")
        coder.encode(unit, forKey: "unit")
    }
    public required init?(coder: NSCoder) {
        guard let u = coder.decodeObject(of: HKUnit.self, forKey: "unit") else { return nil }
        unit = HKUnit.make(u.factors)
        value = coder.decodeDouble(forKey: "value")
        super.init()
    }
    public func copy(with zone: NSZone? = nil) -> Any { self }
}
