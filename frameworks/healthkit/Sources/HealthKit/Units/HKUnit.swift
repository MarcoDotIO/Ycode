import Foundation

/// Molar mass of glucose used for blood-glucose units (`units.md` §4).
public let HKUnitMolarMassBloodGlucose: Double = 180.15588000005408

/// A unit of measure (`units.md`). Units are interned: equal unit strings give the
/// same object (also through `HKUnit(from:)`).
public final class HKUnit: NSObject, NSSecureCoding, NSCopying, @unchecked Sendable {
    let factors: [UnitFactor]
    /// Canonical text form (`units.md` §3).
    public let unitString: String
    let dimension: Dimension
    let scale: Double
    let offset: Double

    private init(canonical factors: [UnitFactor]) {
        self.factors = factors
        self.unitString = UnitAlgebra.format(factors)
        var d = Dimension.none
        var s = 1.0
        for f in factors {
            // swiftlint:disable:next shorthand_operator - Dimension defines + but not +=
            d = d + f.atom.dimension * f.exponent
            s *= pow(f.atom.scale, Double(f.exponent))
        }
        dimension = d
        scale = s
        // Affine conversion applies only to a bare temperature atom.
        if factors.count == 1, factors[0].exponent == 1 { offset = factors[0].atom.offset } else { offset = 0 }
        super.init()
    }

    // MARK: interning

    private static let cache = Locked<[String: HKUnit]>([:])

    static func make(_ factors: [UnitFactor]) -> HKUnit {
        let canonical = UnitAlgebra.canonical(factors)
        let key = UnitAlgebra.format(canonical)
        return cache.withLock { c in
            if let u = c[key] { return u }
            let u = HKUnit(canonical: canonical)
            c[key] = u
            return u
        }
    }

    /// Parse a unit string (throws the exception HealthKit raises).
    static func parse(_ string: String) throws(HKRaise) -> HKUnit {
        if let hit = cache.withLock({ $0["in:" + string] }) { return hit }
        let unit = make(try UnitParser.parse(string))
        cache.withLock { $0["in:" + string] = unit }
        return unit
    }

    static func atom(_ base: String, _ prefix: HKMetricPrefix = .none, molarMass: Double? = nil) -> HKUnit {
        make([UnitFactor(atom: UnitAtom(base: base, prefix: prefix, molarMass: molarMass), exponent: 1)])
    }

    // MARK: NSObject

    public override func isEqual(_ object: Any?) -> Bool {
        guard let other = object as? HKUnit else { return false }
        return other === self || other.unitString == unitString
    }
    public override var hash: Int { unitString.hashValue }
    public override var description: String { unitString }

    /// The null unit `()` has no factors.
    public func isNull() -> Bool { factors.isEmpty }

    // MARK: coding

    public static var supportsSecureCoding: Bool { true }
    public func encode(with coder: NSCoder) { coder.encode(unitString as NSString, forKey: "unitString") }
    public required convenience init?(coder: NSCoder) {
        guard let s = coder.decodeObject(of: NSString.self, forKey: "unitString") as String?,
              let factors = try? UnitParser.parse(s) else { return nil }
        self.init(canonical: UnitAlgebra.canonical(factors))
    }
    public func copy(with zone: NSZone? = nil) -> Any { self }

    // MARK: conversion

    func isCompatible(with other: HKUnit) -> Bool { dimension == other.dimension }

    static func convert(_ value: Double, from: HKUnit, to: HKUnit) throws(HKRaise) -> Double {
        guard from.dimension == to.dimension else {
            throw .invalidArgument("Attempt to convert incompatible units: \(from.unitString), \(to.unitString)")
        }
        if from === to { return value }
        return ((value * from.scale + from.offset) - to.offset) / to.scale
    }

    /// Value in the dimension's reference units (g, m, s, K, …).
    func toReference(_ value: Double) -> Double { value * scale + offset }
    func fromReference(_ value: Double) -> Double { (value - offset) / scale }
}

/// `HKUnit(from:)` returns the interned unit; Swift class initializers cannot
/// return an existing object, so this initializer lives in a protocol extension.
public protocol _HKUnitInterning {}
extension HKUnit: _HKUnitInterning {}
extension _HKUnitInterning where Self: HKUnit {
    /// Parses a unit string (`units.md` §2); raises `NSInvalidArgumentException` when it does not parse.
    public init(from string: String) {
        // swiftlint:disable:next force_cast - HKUnit.parse returns an HKUnit, and units are not subclassed
        self = hkCheck { () throws(HKRaise) in try HKUnit.parse(string) } as! Self
    }
}

// MARK: - Constructors (`api-inventory.md`, HKUnit categories)

extension HKUnit {
    // Mass
    public class func gramUnit(with prefix: HKMetricPrefix) -> HKUnit { atom("g", prefix) }
    public class func gram() -> HKUnit { atom("g") }
    public class func ounce() -> HKUnit { atom("oz") }
    public class func pound() -> HKUnit { atom("lb") }
    public class func stone() -> HKUnit { atom("st") }
    public class func moleUnit(with prefix: HKMetricPrefix, molarMass gramsPerMole: Double) -> HKUnit {
        atom("mol", prefix, molarMass: gramsPerMole)
    }
    public class func moleUnit(withMolarMass gramsPerMole: Double) -> HKUnit { atom("mol", molarMass: gramsPerMole) }
    // Length
    public class func meterUnit(with prefix: HKMetricPrefix) -> HKUnit { atom("m", prefix) }
    public class func meter() -> HKUnit { atom("m") }
    public class func inch() -> HKUnit { atom("in") }
    public class func foot() -> HKUnit { atom("ft") }
    public class func yard() -> HKUnit { atom("yd") }
    public class func mile() -> HKUnit { atom("mi") }
    // Volume
    public class func literUnit(with prefix: HKMetricPrefix) -> HKUnit { atom("L", prefix) }
    public class func liter() -> HKUnit { atom("L") }
    public class func fluidOunceUS() -> HKUnit { atom("fl_oz_us") }
    public class func fluidOunceImperial() -> HKUnit { atom("fl_oz_imp") }
    public class func pintUS() -> HKUnit { atom("pt_us") }
    public class func pintImperial() -> HKUnit { atom("pt_imp") }
    public class func cupUS() -> HKUnit { atom("cup_us") }
    public class func cupImperial() -> HKUnit { atom("cup_imp") }
    // Pressure
    public class func pascalUnit(with prefix: HKMetricPrefix) -> HKUnit { atom("Pa", prefix) }
    public class func pascal() -> HKUnit { atom("Pa") }
    public class func millimeterOfMercury() -> HKUnit { atom("mmHg") }
    public class func centimeterOfWater() -> HKUnit { atom("cmAq") }
    public class func atmosphere() -> HKUnit { atom("atm") }
    public class func decibelAWeightedSoundPressureLevel() -> HKUnit { atom("dBASPL") }
    public class func inchesOfMercury() -> HKUnit { atom("inHg") }
    // Time
    public class func secondUnit(with prefix: HKMetricPrefix) -> HKUnit { atom("s", prefix) }
    public class func second() -> HKUnit { atom("s") }
    public class func minute() -> HKUnit { atom("min") }
    public class func hour() -> HKUnit { atom("hr") }
    public class func day() -> HKUnit { atom("d") }
    // Energy
    public class func jouleUnit(with prefix: HKMetricPrefix) -> HKUnit { atom("J", prefix) }
    public class func joule() -> HKUnit { atom("J") }
    public class func kilocalorie() -> HKUnit { atom("kcal") }
    public class func smallCalorie() -> HKUnit { atom("cal") }
    public class func largeCalorie() -> HKUnit { atom("Cal") }
    @available(*, deprecated, renamed: "smallCalorie")
    public class func calorie() -> HKUnit { atom("cal") }
    // Temperature
    public class func degreeCelsius() -> HKUnit { atom("degC") }
    public class func degreeFahrenheit() -> HKUnit { atom("degF") }
    public class func kelvin() -> HKUnit { atom("K") }
    // Conductance
    public class func siemenUnit(with prefix: HKMetricPrefix) -> HKUnit { atom("S", prefix) }
    public class func siemen() -> HKUnit { atom("S") }
    // Pharmacology
    public class func internationalUnit() -> HKUnit { atom("IU") }
    // Scalar
    public class func count() -> HKUnit { atom("count") }
    public class func percent() -> HKUnit { atom("%") }
    // Hearing sensitivity
    public class func decibelHearingLevel() -> HKUnit { atom("dBHL") }
    // Frequency
    public class func hertzUnit(with prefix: HKMetricPrefix) -> HKUnit { atom("Hz", prefix) }
    public class func hertz() -> HKUnit { atom("Hz") }
    // Electric potential difference
    public class func voltUnit(with prefix: HKMetricPrefix) -> HKUnit { atom("V", prefix) }
    public class func volt() -> HKUnit { atom("V") }
    // Power
    public class func wattUnit(with prefix: HKMetricPrefix) -> HKUnit { atom("W", prefix) }
    public class func watt() -> HKUnit { atom("W") }
    // Optical power
    public class func diopter() -> HKUnit { atom("D") }
    public class func prismDiopter() -> HKUnit { atom("pD") }
    // Angle
    public class func radianAngleUnit(with prefix: HKMetricPrefix) -> HKUnit { atom("rad", prefix) }
    public class func radianAngle() -> HKUnit { atom("rad") }
    public class func degreeAngle() -> HKUnit { atom("deg") }
    // Illuminance
    public class func luxUnit(with prefix: HKMetricPrefix) -> HKUnit { atom("lx", prefix) }
    public class func lux() -> HKUnit { atom("lx") }
    // Unitless
    public class func appleEffortScore() -> HKUnit { atom("appleEffortScore") }

    // MARK: Math (`units.md` §4)

    public func unitMultiplied(by unit: HKUnit) -> HKUnit { HKUnit.make(factors + unit.factors) }
    public func unitDivided(by unit: HKUnit) -> HKUnit {
        HKUnit.make(factors + unit.factors.map { UnitFactor(atom: $0.atom, exponent: -$0.exponent) })
    }
    public func unitRaised(toPower power: Int) -> HKUnit {
        HKUnit.make(factors.map { UnitFactor(atom: $0.atom, exponent: $0.exponent * power) })
    }
    public func reciprocal() -> HKUnit { unitRaised(toPower: -1) }
}
