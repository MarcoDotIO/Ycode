// HealthKit unit strings for Ycode's health tools (specs/frameworks/healthkit/
// units.md §1–§2): parses a unit string, gives its dimension and converts
// values between compatible units. The host checks every imported sample's
// unit against its type's dimension (health-simulation.md §8.3) and converts
// to the store unit when it seeds a shut-down device (§6.2). The guest agent
// passes the string to HealthKit's own `unitFromString:` unchanged.

import Foundation

/// A parsed unit: base exponents, a scale to the reference units (g, m, s,
/// K, count) and, for temperatures, an offset.
public struct HealthUnit: Sendable, Equatable {
    /// Exponents of the base dimensions.
    public var exponents: [Base: Int]
    public var scale: Double
    /// Kelvin = value × scale + offset (degC, degF alone).
    public var offset: Double
    public let text: String

    public enum Base: String, Sendable, CaseIterable {
        case mass, length, time, temperature, conductance, potential, illuminance, angle, amount
        case soundPressureLevel, hearingLevel, internationalUnit, diopter, prismDiopter, effortScore
    }

    public enum ParseError: Error, Equatable, CustomStringConvertible {
        case empty, trailingSpace, unknownAtom(String), badExponent(String), syntax(String)
        public var description: String {
            switch self {
            case .empty: "an empty unit"
            case .trailingSpace: "a unit with a trailing space"
            case .unknownAtom(let a): "unknown unit '\(a)'"
            case .badExponent(let e): "bad exponent '\(e)'"
            case .syntax(let s): "cannot read the unit '\(s)'"
            }
        }
    }

    static let prefixes: [(String, Double)] = [
        ("da", 1e1), ("mc", 1e-6), ("f", 1e-15), ("p", 1e-12), ("n", 1e-9), ("m", 1e-3), ("c", 1e-2), ("d", 1e-1),
        ("h", 1e2), ("k", 1e3), ("M", 1e6), ("G", 1e9), ("T", 1e12),
    ]

    /// Prefixable atoms: symbol → (exponents, scale in reference units).
    static let prefixable: [String: ([Base: Int], Double)] = [
        "g": ([.mass: 1], 1), "m": ([.length: 1], 1), "L": ([.length: 3], 1e-3), "s": ([.time: 1], 1),
        "J": ([.mass: 1, .length: 2, .time: -2], 1000), "Pa": ([.mass: 1, .length: -1, .time: -2], 1000),
        "S": ([.conductance: 1], 1), "V": ([.potential: 1], 1), "W": ([.mass: 1, .length: 2, .time: -3], 1000),
        "Hz": ([.time: -1], 1), "lx": ([.illuminance: 1], 1), "rad": ([.angle: 1], 1), "mol": ([.amount: 1], 1),
    ]

    /// Fixed atoms (no prefix).
    static let fixed: [String: ([Base: Int], Double)] = [
        "lb": ([.mass: 1], 453.59237), "oz": ([.mass: 1], 28.349523125), "st": ([.mass: 1], 6350.29318),
        "mi": ([.length: 1], 1609.344), "ft": ([.length: 1], 0.3048), "in": ([.length: 1], 0.0254), "yd": ([.length: 1], 0.9144),
        "fl_oz_us": ([.length: 3], 0.0295735295625e-3), "fl_oz_imp": ([.length: 3], 0.0284130625e-3),
        "pt_us": ([.length: 3], 0.473176473e-3), "pt_imp": ([.length: 3], 0.56826125e-3),
        "cup_us": ([.length: 3], 0.2365882365e-3), "cup_imp": ([.length: 3], 0.284130625e-3),
        "min": ([.time: 1], 60), "hr": ([.time: 1], 3600), "d": ([.time: 1], 86400),
        "cal": ([.mass: 1, .length: 2, .time: -2], 4184), "kcal": ([.mass: 1, .length: 2, .time: -2], 4_184_000),
        "Cal": ([.mass: 1, .length: 2, .time: -2], 4_184_000),
        "degC": ([.temperature: 1], 1), "degF": ([.temperature: 1], 5.0 / 9.0), "K": ([.temperature: 1], 1),
        "count": ([:], 1), "%": ([:], 1),
        "mmHg": ([.mass: 1, .length: -1, .time: -2], 133_322.368421), "cmAq": ([.mass: 1, .length: -1, .time: -2], 98_066.496063),
        "atm": ([.mass: 1, .length: -1, .time: -2], 101_325_000), "inHg": ([.mass: 1, .length: -1, .time: -2], 3_386_388.16),
        "dBASPL": ([.soundPressureLevel: 1], 1), "dBHL": ([.hearingLevel: 1], 1), "IU": ([.internationalUnit: 1], 1),
        "deg": ([.angle: 1], Double.pi / 180), "D": ([.diopter: 1], 1), "pD": ([.prismDiopter: 1], 1),
        "appleEffortScore": ([.effortScore: 1], 1),
    ]

    public init(_ text: String) throws {
        self.text = text
        guard !text.hasSuffix(" ") || text.isEmpty else { throw ParseError.trailingSpace }
        let s = text.hasPrefix(" ") ? String(text.drop(while: { $0 == " " })) : text
        guard !s.isEmpty else { throw ParseError.empty }
        var exps: [Base: Int] = [:]
        var scale = 1.0
        let parts = s.split(separator: "/", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
        guard parts.count <= 2, !parts[0].isEmpty, parts.count == 1 || !parts[1].isEmpty else { throw ParseError.syntax(text) }
        for (side, sign) in zip(parts, [1, -1]) {
            var body = side
            if body.hasPrefix("("), body.hasSuffix(")") { body = String(body.dropFirst().dropLast()) }
            if body == "1" { continue }
            for term in body.split(whereSeparator: { $0 == "*" || $0 == "·" }).map(String.init) {
                var atom = term
                var power = 1
                if let caret = term.firstIndex(of: "^") {
                    atom = String(term[..<caret])
                    let e = String(term[term.index(after: caret)...])
                    guard let p = Int(e), p != 0 else { throw ParseError.badExponent(e) }
                    power = p
                }
                if atom.hasPrefix("("), atom.hasSuffix(")") { atom = String(atom.dropFirst().dropLast()) }
                let (e, f) = try Self.atom(atom)
                for (b, x) in e { exps[b, default: 0] += x * power * sign }
                scale *= pow(f, Double(power * sign))
            }
        }
        exponents = exps.filter { $0.value != 0 }
        self.scale = scale
        offset = 0
        if exponents == [.temperature: 1] {
            if s == "degC" { offset = 273.15 } else if s == "degF" { offset = 273.15 - 32 * 5.0 / 9.0 }
        }
    }

    static func atom(_ a: String) throws -> ([Base: Int], Double) {
        if let f = fixed[a] { return f }
        if let p = prefixable[a] { return p }
        // mol<M>: an amount with a molar mass (M g per mol).
        if let lt = a.firstIndex(of: "<"), a.hasSuffix(">") {
            let head = String(a[..<lt]), mass = Double(a[a.index(after: lt)..<a.index(before: a.endIndex)])
            guard let mass, head.hasSuffix("mol") else { throw ParseError.unknownAtom(a) }
            let prefix = String(head.dropLast(3))
            let factor = prefix.isEmpty ? 1 : (prefixes.first { $0.0 == prefix }?.1)
            guard let factor else { throw ParseError.unknownAtom(a) }
            return ([.mass: 1], factor * mass)
        }
        for (p, factor) in prefixes where a.hasPrefix(p) {
            if let base = prefixable[String(a.dropFirst(p.count))] { return (base.0, base.1 * factor) }
        }
        throw ParseError.unknownAtom(a)
    }

    public func isCompatible(with other: HealthUnit) -> Bool { exponents == other.exponents }

    /// `value` in this unit, in `other` (compatible) units.
    public func convert(_ value: Double, to other: HealthUnit) -> Double? {
        guard isCompatible(with: other) else { return nil }
        let reference = value * scale + offset
        return (reference - other.offset) / other.scale
    }

    /// The base exponents of a type's dimension (identifiers.md).
    public static func exponents(of d: HealthDimension) -> [Base: Int] {
        switch d {
        case .energy: [.mass: 1, .length: 2, .time: -2]
        case .time: [.time: 1]
        case .scalar: [:]
        case .temperature: [.temperature: 1]
        case .massConcentration: [.mass: 1, .length: -3]
        case .pressure: [.mass: 1, .length: -1, .time: -2]
        case .mass: [.mass: 1]
        case .speed: [.length: 1, .time: -1]
        case .frequency: [.time: -1]
        case .power: [.mass: 1, .length: 2, .time: -3]
        case .volume: [.length: 3]
        case .length: [.length: 1]
        case .conductance: [.conductance: 1]
        case .soundPressureLevel: [.soundPressureLevel: 1]
        case .effortScore: [.effortScore: 1]
        case .pharmacology: [.internationalUnit: 1]
        case .volumeFlow: [.length: 3, .time: -1]
        case .energyRatePerMass: [.length: 2, .time: -3]
        case .vo2Rate: [.length: 3, .mass: -1, .time: -1]
        }
    }

    public func fits(_ d: HealthDimension) -> Bool { exponents == Self.exponents(of: d) }
}
