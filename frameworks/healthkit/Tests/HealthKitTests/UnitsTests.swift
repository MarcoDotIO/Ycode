import Foundation
import Testing
@testable import HealthKit

/// C-UNITS: `units.md` §2–§6.
@Suite("C-UNITS units.md")
struct UnitsTests {
    static func parses(_ s: String) -> Bool { (try? HKUnit.parse(s)) != nil }

    @Test("units.md §3 canonical unitString", arguments: [
        ("count/min", "count/min"),
        ("kg*m^2", "m^2·kg"),
        ("(kg*m)/s^2", "m·kg/s^2"),
        ("count/min*kg", "count/min·kg"),
        ("mL/(kg*min)", "mL/min·kg"),
        ("kcal/(kg*hr)", "kcal/hr·kg"),
        ("m^-1", "1/m"),
        ("1/min", "1/min"),
        ("", "()"),
        ("mmol<180.15588000005408>/L", "mmol<180.1558800000541>/L"),
    ])
    func canonical(input: String, expected: String) throws {
        #expect(try HKUnit.parse(input).unitString == expected)
        // every canonical string parses back to the same unit
        #expect(try HKUnit.parse(expected) === HKUnit.parse(input))
    }

    @Test("units.md §3 algebra")
    func algebra() {
        let m = HKUnit.meter(), kg = HKUnit.gramUnit(with: .kilo), min = HKUnit.minute()
        #expect(kg.unitMultiplied(by: m).unitString == "m·kg")
        #expect(m.unitRaised(toPower: 3).unitString == "m^3")
        #expect(m.unitRaised(toPower: 0).unitString == "()")
        #expect(m.unitRaised(toPower: 0).isNull())
        #expect(m.unitRaised(toPower: -2).unitString == "1/m^2")
        #expect(min.reciprocal().unitString == "1/min")
        #expect(HKUnit(from: "count/min").reciprocal().unitString == "min/count")
        #expect(m.unitDivided(by: m).unitString == "()")
        #expect(HKUnit.count().unitDivided(by: .count()).isNull())
        #expect(HKUnit.count().unitMultiplied(by: .count()).unitString == "count^2")
        #expect(HKUnit.moleUnit(with: .milli, molarMass: HKUnitMolarMassBloodGlucose).unitString == "mmol<180.1558800000541>")
        #expect(!HKUnit.count().isNull())
    }

    @Test("units.md §1 interning, equality and description")
    func interning() {
        #expect(HKUnit(from: "count/min") === HKUnit(from: "count/min"))
        #expect(HKUnit(from: "count") === HKUnit.count())
        #expect(HKUnit(from: "kg") == HKUnit.gramUnit(with: .kilo))
        #expect(HKUnit(from: "m·kg/s^2") === HKUnit(from: "(kg*m)/s^2"))
        #expect(HKUnit(from: "count/min").description == "count/min")
        #expect(HKUnit.kilocalorie().unitString == "kcal")
        #expect(HKUnit.largeCalorie().unitString == "Cal")
        #expect(HKUnit.smallCalorie().unitString == "cal")
        #expect(HKUnit.kilocalorie() != HKUnit.largeCalorie())
    }

    @Test("units.md §2 grammar: rejected strings", arguments: [
        "count ", "KG", "Kg", "kilogram", "diopter", "prismDiopter", "ug", "um", "uS", "uV", "Pg", "am", "count/",
        "m^", "(m", "m)", "kg m", "mol<abc>",
    ])
    func rejected(_ s: String) {
        #expect(!Self.parses(s))
        #expect(throws: HKRaise.invalidArgument("Unable to parse factorization string \(s)")) { try HKUnit.parse(s) }
    }

    @Test("units.md §2 grammar: accepted strings", arguments: [
        " count", "mmol", "1/min", "m^-1", "count/min*kg", "D", "pD", "appleEffortScore", "dBASPL", "dBHL", "IU",
        "fl_oz_us", "fl_oz_imp", "pt_us", "pt_imp", "cup_us", "cup_imp", "mcg", "mcS", "das", "klx", "mV", "kW", "kHz",
        "deg", "rad", "lx", "%", "inHg", "cmAq", "atm", "mmHg", "degC", "degF", "K", "st", "yd", "ft", "in", "mi",
    ])
    func accepted(_ s: String) { #expect(Self.parses(s)) }

    @Test("units.md §2 mole without molar mass is not convertible to mass")
    func moleWithoutMass() {
        #expect(!HKQuantity(unit: HKUnit(from: "mmol"), doubleValue: 1).is(compatibleWith: .gram()))
        #expect(HKQuantity(unit: HKUnit(from: "mmol<180.15588000005408>"), doubleValue: 1).is(compatibleWith: .gram()))
    }

    @Test("units.md §6 golden conversions", arguments: [
        (100.0, "degC", "degF", 212.0),
        (0, "degC", "K", 273.15),
        (98.6, "degF", "degC", 37.0000000000001),
        (1, "degC", "K", 274.15),
        (1, "degF", "K", 255.927777778),
        (1, "mi", "m", 1609.344),
        (1, "lb", "kg", 0.45359237),
        (1, "st", "lb", 14),
        (1, "kcal", "kJ", 4.184),
        (1, "Cal", "cal", 1000),
        (1, "atm", "mmHg", 760),
        (1, "inHg", "mmHg", 25.4000000157908),
        (1, "cmAq", "Pa", 98.0664960629921),
        (1, "fl_oz_us", "mL", 29.5735295625),
        (1, "fl_oz_imp", "mL", 28.4130625),
        (1, "cup_us", "mL", 236.5882365),
        (1, "cup_imp", "mL", 284.130625),
        (1, "pt_us", "mL", 473.176473),
        (1, "pt_imp", "mL", 568.26125),
        (1, "d", "s", 86400),
        (100, "mg/dL", "mmol<180.15588000005408>/L", 5.55074860726),
        (1, "deg", "rad", 0.0174532925199433),
        (1, "count/min", "count/s", 0.0166666666666667),
        (60, "count/min", "Hz", 1),
        (10, "km/hr", "m/s", 2.77777777777778),
        (1, "oz", "g", 28.349523125),
        (1, "yd", "m", 0.9144),
        (50, "%", "count", 50),
        (1, "kcal/hr", "J/s", 1.16222222222),
        (1, "g/dL", "g/L", 10),
        (1, "mi/hr", "m/s", 0.44704),
    ])
    func conversion(value: Double, from: String, to: String, expected: Double) {
        let q = HKQuantity(unit: HKUnit(from: from), doubleValue: value)
        #expect(close(q.doubleValue(for: HKUnit(from: to)), expected, 1e-10))
    }

    @Test("units.md §6 incompatible conversions raise")
    func incompatible() throws {
        #expect(!HKQuantity(unit: HKUnit(from: "dBASPL"), doubleValue: 1).is(compatibleWith: .pascal()))
        #expect(throws: HKRaise.invalidArgument("Attempt to convert incompatible units: g, m")) {
            try HKUnit.convert(1, from: .gram(), to: .meter())
        }
        #expect(throws: HKRaise.self) {
            try HKQuantity(unit: .gram(), doubleValue: 1).compareChecked(HKQuantity(unit: .meter(), doubleValue: 1))
        }
    }

    @Test("units.md §6 prefix scale checks", arguments: [
        ("Mg", "g", 1e6), ("Gg", "g", 1e9), ("Tm", "m", 1e12), ("fs", "s", 1e-15), ("cs", "s", 1e-2), ("ds", "s", 1e-1),
        ("das", "s", 1e1), ("hs", "s", 1e2), ("ks", "s", 1e3), ("Ms", "s", 1e6), ("Gs", "s", 1e9), ("Ts", "s", 1e12),
        ("ps", "s", 1e-12), ("fJ", "J", 1e-15), ("mcS", "S", 1e-6), ("klx", "lx", 1000),
    ])
    func prefixes(unit: String, base: String, factor: Double) {
        #expect(close(HKQuantity(unit: HKUnit(from: unit), doubleValue: 1).doubleValue(for: HKUnit(from: base)), factor, 1e-12))
    }

    @Test("units.md §1 quantities compare across compatible units")
    func quantities() {
        let g1000 = HKQuantity(unit: .gram(), doubleValue: 1000)
        let kg1 = HKQuantity(unit: .gramUnit(with: .kilo), doubleValue: 1)
        #expect(g1000 == kg1)
        #expect(g1000.compare(kg1) == .orderedSame)
        #expect(g1000.description == "1000 g")
        #expect(HKQuantity(unit: .meter(), doubleValue: 3).description == "3 m")
        #expect(HKQuantity(unit: .percent(), doubleValue: 1).doubleValue(for: .count()) == 1)
        #expect(HKQuantity(unit: .count(), doubleValue: 5).compare(HKQuantity(unit: .count(), doubleValue: 6)) == .orderedAscending)
    }

    @Test("units.md §2.1 HKMetricPrefix raw values")
    func prefixRawValues() {
        #expect(HKMetricPrefix.femto.rawValue == 13)
        #expect(HKMetricPrefix.micro.rawValue == 3)
        #expect(HKMetricPrefix.kilo.rawValue == 9)
        #expect(HKMetricPrefix.tera.rawValue == 12)
        #expect(HKUnit.gramUnit(with: .micro).unitString == "mcg")
        #expect(HKUnit.secondUnit(with: .deca).unitString == "das")
    }

    @Test("units.md: secure coding round trip")
    func coding() throws {
        let q = HKQuantity(unit: HKUnit(from: "count/min"), doubleValue: 72)
        let data = try NSKeyedArchiver.archivedData(withRootObject: q, requiringSecureCoding: true)
        let back = try #require(try NSKeyedUnarchiver.unarchivedObject(ofClasses: [HKQuantity.self, HKUnit.self], from: data) as? HKQuantity)
        #expect(back == q)
        #expect(back.description == "72 count/min")
    }
}
