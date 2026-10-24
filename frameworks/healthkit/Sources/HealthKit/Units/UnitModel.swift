import Foundation

// Unit model of `units.md` §1–§3: a unit is a product of factors, each an atom
// (base symbol, optional metric prefix, optional molar mass) raised to a non-zero
// integer power. Every atom has a dimension vector and a scale relative to the
// reference units (g, m, s, K, …); degC/degF also carry an offset.

/// Dimension vector over the base quantities this library distinguishes.
struct Dimension: Hashable, Sendable {
    static let count = 15
    // 0 mass, 1 length, 2 time, 3 temperature, 4 amount (mol without molar mass),
    // 5 conductance, 6 electric potential, 7 illuminance, 8 angle,
    // 9 sound pressure level, 10 hearing level, 11 international unit,
    // 12 optical power (diopter), 13 prism diopter, 14 effort score.
    var exponents: [Int]

    init(_ pairs: [(Int, Int)] = []) {
        exponents = Array(repeating: 0, count: Dimension.count)
        for (i, e) in pairs { exponents[i] += e }
    }

    static let none = Dimension()
    static func + (a: Dimension, b: Dimension) -> Dimension {
        var r = a
        for i in 0..<count { r.exponents[i] += b.exponents[i] }
        return r
    }
    static func * (a: Dimension, n: Int) -> Dimension {
        var r = a
        for i in 0..<count { r.exponents[i] *= n }
        return r
    }
    var isNone: Bool { exponents.allSatisfy { $0 == 0 } }
}

private let M = 0, Lg = 1, T = 2, TEMP = 3, AMOUNT = 4

struct AtomDefinition: Sendable {
    let symbol: String
    let dimension: Dimension
    let scale: Double        // in reference units (g, m, s, K, …)
    let offset: Double       // affine offset to the reference (temperature only)
    let prefixable: Bool
    let rank: Int            // canonical ordering class within a side of `/`
}

/// Ordering classes for `unitString` (`units.md` §3: length and time before mass;
/// the full rule is an open spec question, so this is Ycode's choice).
private enum Rank {
    static let scalar = 0, length = 1, volume = 2, time = 3, energy = 4, pressure = 5,
               other = 6, temperature = 7, mass = 9
}

private func def(_ s: String, _ d: [(Int, Int)], _ scale: Double, offset: Double = 0,
                 prefixable: Bool = false, rank: Int) -> AtomDefinition {
    AtomDefinition(symbol: s, dimension: Dimension(d), scale: scale, offset: offset,
                   prefixable: prefixable, rank: rank)
}

enum UnitTables {
    static let prefixable: [String: AtomDefinition] = {
        let list = [
            def("g", [(M, 1)], 1, prefixable: true, rank: Rank.mass),
            def("m", [(Lg, 1)], 1, prefixable: true, rank: Rank.length),
            def("L", [(Lg, 3)], 0.001, prefixable: true, rank: Rank.volume),
            def("s", [(T, 1)], 1, prefixable: true, rank: Rank.time),
            def("J", [(M, 1), (Lg, 2), (T, -2)], 1000, prefixable: true, rank: Rank.energy),
            def("Pa", [(M, 1), (Lg, -1), (T, -2)], 1000, prefixable: true, rank: Rank.pressure),
            def("S", [(5, 1)], 1, prefixable: true, rank: Rank.other),
            def("V", [(6, 1)], 1, prefixable: true, rank: Rank.other),
            def("W", [(M, 1), (Lg, 2), (T, -3)], 1000, prefixable: true, rank: Rank.energy),
            def("Hz", [(T, -1)], 1, prefixable: true, rank: Rank.time),
            def("lx", [(7, 1)], 1, prefixable: true, rank: Rank.other),
            def("rad", [(8, 1)], 1, prefixable: true, rank: Rank.other),
        ]
        return Dictionary(uniqueKeysWithValues: list.map { ($0.symbol, $0) })
    }()

    static let fixed: [String: AtomDefinition] = {
        let pa = 1000.0  // one pascal in reference units (g/(m·s²))
        let list = [
            def("lb", [(M, 1)], 453.59237, rank: Rank.mass),
            def("oz", [(M, 1)], 28.349523125, rank: Rank.mass),
            def("st", [(M, 1)], 6350.29318, rank: Rank.mass),
            def("mi", [(Lg, 1)], 1609.344, rank: Rank.length),
            def("ft", [(Lg, 1)], 0.3048, rank: Rank.length),
            def("in", [(Lg, 1)], 0.0254, rank: Rank.length),
            def("yd", [(Lg, 1)], 0.9144, rank: Rank.length),
            def("fl_oz_us", [(Lg, 3)], 0.0295735295625e-3, rank: Rank.volume),
            def("fl_oz_imp", [(Lg, 3)], 0.0284130625e-3, rank: Rank.volume),
            def("pt_us", [(Lg, 3)], 0.473176473e-3, rank: Rank.volume),
            def("pt_imp", [(Lg, 3)], 0.56826125e-3, rank: Rank.volume),
            def("cup_us", [(Lg, 3)], 0.2365882365e-3, rank: Rank.volume),
            def("cup_imp", [(Lg, 3)], 0.284130625e-3, rank: Rank.volume),
            def("min", [(T, 1)], 60, rank: Rank.time),
            def("hr", [(T, 1)], 3600, rank: Rank.time),
            def("d", [(T, 1)], 86400, rank: Rank.time),
            def("cal", [(M, 1), (Lg, 2), (T, -2)], 4.184 * 1000, rank: Rank.energy),
            def("kcal", [(M, 1), (Lg, 2), (T, -2)], 4184 * 1000, rank: Rank.energy),
            def("Cal", [(M, 1), (Lg, 2), (T, -2)], 4184 * 1000, rank: Rank.energy),
            def("degC", [(TEMP, 1)], 1, offset: 273.15, rank: Rank.temperature),
            def("degF", [(TEMP, 1)], 5.0 / 9.0, offset: 273.15 - 32.0 * 5.0 / 9.0, rank: Rank.temperature),
            def("K", [(TEMP, 1)], 1, rank: Rank.temperature),
            def("count", [], 1, rank: Rank.scalar),
            def("%", [], 1, rank: Rank.scalar),
            def("mmHg", [(M, 1), (Lg, -1), (T, -2)], 101325.0 / 760.0 * pa, rank: Rank.pressure),
            def("cmAq", [(M, 1), (Lg, -1), (T, -2)], 98.0664960629921 * pa, rank: Rank.pressure),
            def("atm", [(M, 1), (Lg, -1), (T, -2)], 101325 * pa, rank: Rank.pressure),
            def("inHg", [(M, 1), (Lg, -1), (T, -2)], 3386.38816 * pa, rank: Rank.pressure),
            def("dBASPL", [(9, 1)], 1, rank: Rank.other),
            def("dBHL", [(10, 1)], 1, rank: Rank.other),
            def("IU", [(11, 1)], 1, rank: Rank.other),
            def("deg", [(8, 1)], Double.pi / 180, rank: Rank.other),
            def("D", [(12, 1)], 1, rank: Rank.other),
            def("pD", [(13, 1)], 1, rank: Rank.other),
            def("appleEffortScore", [(14, 1)], 1, rank: Rank.other),
        ]
        return Dictionary(uniqueKeysWithValues: list.map { ($0.symbol, $0) })
    }()

    /// Metric prefixes (`units.md` §2.1); `u` is not micro, peta/atto do not exist.
    static let prefixes: [(symbol: String, prefix: HKMetricPrefix, factor: Double)] = [
        ("mc", .micro, 1e-6), ("da", .deca, 1e1),
        ("f", .femto, 1e-15), ("p", .pico, 1e-12), ("n", .nano, 1e-9), ("m", .milli, 1e-3),
        ("c", .centi, 1e-2), ("d", .deci, 1e-1), ("h", .hecto, 1e2), ("k", .kilo, 1e3),
        ("M", .mega, 1e6), ("G", .giga, 1e9), ("T", .tera, 1e12),
    ]

    static func symbol(for prefix: HKMetricPrefix) -> String {
        prefixes.first { $0.prefix == prefix }?.symbol ?? ""
    }
    static func factor(for prefix: HKMetricPrefix) -> Double {
        prefixes.first { $0.prefix == prefix }?.factor ?? 1
    }
}

/// One atom of a unit: base symbol, metric prefix, and for moles the molar mass.
struct UnitAtom: Hashable, Sendable {
    let base: String
    let prefix: HKMetricPrefix
    let molarMass: Double?

    var text: String {
        var s = UnitTables.symbol(for: prefix) + base
        if let mm = molarMass { s += "<\(mm.g16)>" }
        return s
    }

    var rank: Int {
        if base == "mol" { return 9 }
        return (UnitTables.prefixable[base] ?? UnitTables.fixed[base])?.rank ?? 6
    }

    var dimension: Dimension {
        if base == "mol" { return molarMass == nil ? Dimension([(AMOUNT, 1)]) : Dimension([(M, 1)]) }
        return (UnitTables.prefixable[base] ?? UnitTables.fixed[base])!.dimension
    }

    var scale: Double {
        let p = UnitTables.factor(for: prefix)
        if base == "mol" { return p * (molarMass ?? 1) }
        return p * (UnitTables.prefixable[base] ?? UnitTables.fixed[base])!.scale
    }

    var offset: Double {
        prefix == .none ? (UnitTables.fixed[base]?.offset ?? 0) : 0
    }
}

struct UnitFactor: Hashable, Sendable {
    var atom: UnitAtom
    var exponent: Int
}

enum UnitAlgebra {
    /// Combine equal atoms, drop zero exponents, order canonically.
    static func canonical(_ factors: [UnitFactor]) -> [UnitFactor] {
        var order: [String] = []
        var byText: [String: UnitFactor] = [:]
        for f in factors {
            let key = f.atom.text
            if var existing = byText[key] {
                existing.exponent += f.exponent
                byText[key] = existing
            } else {
                byText[key] = f
                order.append(key)
            }
        }
        return order.compactMap { byText[$0] }.filter { $0.exponent != 0 }
            .sorted { ($0.atom.rank, $0.atom.text) < ($1.atom.rank, $1.atom.text) }
    }

    /// `unitString` rules of `units.md` §3.
    static func format(_ factors: [UnitFactor]) -> String {
        func one(_ f: UnitFactor) -> String {
            let e = abs(f.exponent)
            return e == 1 ? f.atom.text : "\(f.atom.text)^\(e)"
        }
        let num = factors.filter { $0.exponent > 0 }
        let den = factors.filter { $0.exponent < 0 }
        if num.isEmpty && den.isEmpty { return "()" }
        let n = num.isEmpty ? "1" : num.map(one).joined(separator: "\u{00B7}")
        if den.isEmpty { return n }
        return n + "/" + den.map(one).joined(separator: "\u{00B7}")
    }
}

/// Parser for the unit-string grammar of `units.md` §2. Accepts `*` and the
/// middle dot `·` (so that every `unitString` parses back).
struct UnitParser {
    private let chars: [Character]
    private var i = 0
    private let original: String

    init(_ s: String) {
        original = s
        chars = Array(s)
    }

    private func fail() -> HKRaise {
        .invalidArgument("Unable to parse factorization string \(original)")
    }

    static func parse(_ s: String) throws(HKRaise) -> [UnitFactor] {
        var p = UnitParser(s)
        return try p.parseUnit()
    }

    private var atEnd: Bool { i >= chars.count }
    private var peek: Character? { atEnd ? nil : chars[i] }

    private static func isMul(_ c: Character) -> Bool { c == "*" || c == "\u{00B7}" }

    mutating func parseUnit() throws(HKRaise) -> [UnitFactor] {
        while let c = peek, c == " " { i += 1 }
        if atEnd { return [] }
        var factors = try parseProduct()
        if peek == "/" {
            i += 1
            let den = try parseProduct()
            factors += den.map { UnitFactor(atom: $0.atom, exponent: -$0.exponent) }
        }
        guard atEnd else { throw fail() }
        return factors
    }

    private mutating func parseProduct() throws(HKRaise) -> [UnitFactor] {
        var out = try parseTerm()
        while let c = peek, UnitParser.isMul(c) {
            i += 1
            out += try parseTerm()
        }
        return out
    }

    private mutating func parseTerm() throws(HKRaise) -> [UnitFactor] {
        if peek == "(" {
            i += 1
            var inner: [UnitFactor] = []
            if peek != ")" { inner = try parseProduct() }
            guard peek == ")" else { throw fail() }
            i += 1
            let e = try parseExponent()
            return inner.map { UnitFactor(atom: $0.atom, exponent: $0.exponent * e) }
        }
        // Token: everything up to an operator, with `<…>` kept whole.
        var tok = ""
        while let c = peek, !UnitParser.isMul(c), c != "/", c != "^", c != "(", c != ")" {
            if c == " " || c == "\t" || c == "\n" { throw fail() }
            if c == "<" {
                while let d = peek, d != ">" { tok.append(d); i += 1 }
                guard peek == ">" else { throw fail() }
            }
            tok.append(chars[i])
            i += 1
        }
        if tok.isEmpty { throw fail() }
        if tok == "1" {
            // "1" stands for the empty product (e.g. `1/min`).
            if peek == "^" { _ = try parseExponent() }
            return []
        }
        let atom = try resolveAtom(tok)
        let e = try parseExponent()
        return [UnitFactor(atom: atom, exponent: e)]
    }

    private mutating func parseExponent() throws(HKRaise) -> Int {
        guard peek == "^" else { return 1 }
        i += 1
        var s = ""
        if peek == "-" { s.append("-"); i += 1 }
        while let c = peek, c.isASCII, c.isNumber { s.append(c); i += 1 }
        guard let v = Int(s) else { throw fail() }
        return v
    }

    private func resolveAtom(_ tok: String) throws(HKRaise) -> UnitAtom {
        if UnitTables.prefixable[tok] != nil { return UnitAtom(base: tok, prefix: .none, molarMass: nil) }
        if UnitTables.fixed[tok] != nil { return UnitAtom(base: tok, prefix: .none, molarMass: nil) }
        // mole, optionally prefixed, optionally with a molar mass
        if let r = tok.range(of: "mol") {
            let pre = String(tok[tok.startIndex..<r.lowerBound])
            let rest = String(tok[r.upperBound...])
            var prefix: HKMetricPrefix = .none
            if !pre.isEmpty {
                guard let p = UnitTables.prefixes.first(where: { $0.symbol == pre }) else { throw fail() }
                prefix = p.prefix
            }
            if rest.isEmpty { return UnitAtom(base: "mol", prefix: prefix, molarMass: nil) }
            guard rest.hasPrefix("<"), rest.hasSuffix(">"),
                  let mm = Double(rest.dropFirst().dropLast()), mm > 0 else { throw fail() }
            return UnitAtom(base: "mol", prefix: prefix, molarMass: mm)
        }
        for p in UnitTables.prefixes where tok.hasPrefix(p.symbol) {
            let rest = String(tok.dropFirst(p.symbol.count))
            if UnitTables.prefixable[rest] != nil {
                return UnitAtom(base: rest, prefix: p.prefix, molarMass: nil)
            }
        }
        throw fail()
    }
}
