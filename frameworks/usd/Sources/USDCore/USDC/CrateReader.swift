/// Reads the crate (`.usdc`) binary format into a `Layer`.
public enum USDCReader {
    public static func read(_ bytes: [UInt8], identifier: String = "anonymous.usdc") throws -> Layer {
        let reader = try CrateReader(bytes)
        return try reader.layer(identifier: identifier)
    }

    /// True if the data starts with the crate magic `PXR-USDC`.
    public static func isCrate(_ bytes: some Collection<UInt8>) -> Bool {
        bytes.starts(with: Array("PXR-USDC".utf8))
    }
}

/// Bounds-checked little-endian cursor.
struct ByteCursor {
    let bytes: [UInt8]
    var pos: Int

    init(_ bytes: [UInt8], at pos: Int = 0) {
        self.bytes = bytes
        self.pos = pos
    }

    mutating func need(_ n: Int) throws {
        guard n >= 0, pos >= 0, pos + n <= bytes.count else { throw USDError("crate: read past end of file at \(pos)") }
    }

    mutating func u8() throws -> UInt8 {
        try need(1)
        defer { pos += 1 }
        return bytes[pos]
    }

    mutating func uint(_ size: Int) throws -> UInt64 {
        try need(size)
        var v: UInt64 = 0
        for k in 0..<size { v |= UInt64(bytes[pos + k]) << (8 * UInt64(k)) }
        pos += size
        return v
    }

    mutating func u32() throws -> UInt32 { UInt32(truncatingIfNeeded: try uint(4)) }
    mutating func u64() throws -> UInt64 { try uint(8) }
    mutating func i64() throws -> Int64 { Int64(bitPattern: try uint(8)) }
    mutating func f32() throws -> Float { Float(bitPattern: try u32()) }
    mutating func f64() throws -> Double { Double(bitPattern: try u64()) }
    mutating func f16() throws -> Float { Half.toFloat(UInt16(truncatingIfNeeded: try uint(2))) }

    mutating func slice(_ n: Int) throws -> ArraySlice<UInt8> {
        try need(n)
        defer { pos += n }
        return bytes[pos..<(pos + n)]
    }

    /// A count read from the file, checked against the bytes left.
    mutating func count(minimumElementSize: Int = 1) throws -> Int {
        let n = try u64()
        guard n <= UInt64(bytes.count), Int(n) * minimumElementSize <= bytes.count - pos else {
            throw USDError("crate: implausible count \(n) at \(pos)")
        }
        return Int(n)
    }
}

final class CrateReader {
    let bytes: [UInt8]
    var version = CrateVersion(major: 0, minor: 0, patch: 0)
    var tokens: [String] = []
    var strings: [Int] = []
    var fields: [(token: Int, rep: ValueRep)] = []
    var fieldSets: [Int64] = []
    var paths: [Path] = []
    var specs: [(path: Int, fieldSet: Int, type: UInt32)] = []
    var depth = 0

    init(_ bytes: [UInt8]) throws {
        self.bytes = bytes
        guard bytes.count >= 88, USDCReader.isCrate(bytes) else { throw USDError("crate: not a usdc file") }
        version = CrateVersion(major: bytes[8], minor: bytes[9], patch: bytes[10])
        guard version >= CrateVersion(major: 0, minor: 4, patch: 0), version.major == 0 else {
            throw USDError("crate: unsupported version \(version.major).\(version.minor).\(version.patch)")
        }
        var c = ByteCursor(bytes, at: 16)
        let tocOffset = Int(try c.i64())
        c.pos = tocOffset
        let sectionCount = try c.count(minimumElementSize: 32)
        var sections: [String: (start: Int, size: Int)] = [:]
        for _ in 0..<sectionCount {
            let nameBytes = try c.slice(16)
            let name = String(decoding: nameBytes.prefix { $0 != 0 }, as: UTF8.self)
            sections[name] = (Int(try c.i64()), Int(try c.i64()))
        }
        if let s = sections["TOKENS"] { try readTokens(at: s.start) }
        if let s = sections["STRINGS"] { try readStrings(at: s.start) }
        if let s = sections["FIELDS"] { try readFields(at: s.start) }
        if let s = sections["FIELDSETS"] { try readFieldSets(at: s.start) }
        if let s = sections["PATHS"] { try readPaths(at: s.start) }
        if let s = sections["SPECS"] { try readSpecs(at: s.start) }
    }

    // MARK: Structural sections

    func compressedInts(_ c: inout ByteCursor, count: Int) throws -> [Int64] {
        let size = try c.count()
        return try IntegerCoding.decode32(try c.slice(size), count: count)
    }

    func readTokens(at offset: Int) throws {
        var c = ByteCursor(bytes, at: offset)
        let count = try c.count()
        let uncompressed = try c.count()
        let compressed = try c.count()
        let chars = try LZ4.decompress(try c.slice(compressed), expectedSize: uncompressed)
        tokens.reserveCapacity(count)
        var start = 0
        for (i, b) in chars.enumerated() where b == 0 {
            tokens.append(String(decoding: chars[start..<i], as: UTF8.self))
            start = i + 1
            if tokens.count == count { break }
        }
        guard tokens.count == count else { throw USDError("crate: token table has \(tokens.count) of \(count) tokens") }
    }

    func readStrings(at offset: Int) throws {
        var c = ByteCursor(bytes, at: offset)
        let count = try c.count(minimumElementSize: 4)
        strings = try (0..<count).map { _ in Int(try c.u32()) }
    }

    func readFields(at offset: Int) throws {
        var c = ByteCursor(bytes, at: offset)
        let count = try c.count()
        let tokenIndexes = try compressedInts(&c, count: count)
        let repsSize = try c.count()
        let reps = try LZ4.decompress(try c.slice(repsSize), expectedSize: count * 8)
        guard reps.count == count * 8 else { throw USDError("crate: bad field value reps") }
        var r = ByteCursor(reps)
        fields = try tokenIndexes.map { (Int(UInt32(truncatingIfNeeded: $0)), ValueRep(data: try r.u64())) }
    }

    func readFieldSets(at offset: Int) throws {
        var c = ByteCursor(bytes, at: offset)
        let count = try c.count()
        fieldSets = try compressedInts(&c, count: count)
    }

    func readPaths(at offset: Int) throws {
        var c = ByteCursor(bytes, at: offset)
        let total = try c.count()
        paths = Array(repeating: .empty, count: total)
        let encoded = try c.count()
        let pathIndexes = try compressedInts(&c, count: encoded)
        let elementTokens = try compressedInts(&c, count: encoded)
        let jumps = try compressedInts(&c, count: encoded)
        // Iterative form of the tree walk: siblings are pushed on a stack.
        var stack: [(index: Int, parent: Path)] = []
        if encoded > 0 { stack.append((0, .empty)) }
        while let (start, startParent) = stack.popLast() {
            var index = start
            var parent = startParent
            while true {
                guard index < encoded else { throw USDError("crate: corrupt path tree") }
                let pathIndex = Int(pathIndexes[index])
                guard pathIndex < total else { throw USDError("crate: path index out of range") }
                let path: Path
                if parent.isEmpty {
                    path = .root
                } else {
                    let tokenIndex = Int(elementTokens[index])
                    let isProperty = tokenIndex < 0
                    let t = abs(tokenIndex)
                    guard t < tokens.count else { throw USDError("crate: path token out of range") }
                    path = parent.appendingElementText(tokens[t], isProperty: isProperty)
                }
                paths[pathIndex] = path
                let jump = Int(jumps[index])
                let hasChild = jump > 0 || jump == -1
                let hasSibling = jump >= 0
                if hasChild {
                    if hasSibling { stack.append((index + jump, parent)) }
                    parent = path
                    index += 1
                } else if hasSibling {
                    index += 1
                } else {
                    break
                }
            }
        }
    }

    func readSpecs(at offset: Int) throws {
        var c = ByteCursor(bytes, at: offset)
        let count = try c.count()
        let pathIndexes = try compressedInts(&c, count: count)
        let fieldSetIndexes = try compressedInts(&c, count: count)
        let types = try compressedInts(&c, count: count)
        specs = (0..<count).map { (Int(pathIndexes[$0]), Int(fieldSetIndexes[$0]), UInt32(truncatingIfNeeded: types[$0])) }
    }

    // MARK: Layer

    func layer(identifier: String) throws -> Layer {
        var layer = Layer(identifier: identifier)
        for spec in specs {
            guard spec.path < paths.count else { throw USDError("crate: spec path out of range") }
            let path = paths[spec.path]
            var out = Spec(type: SpecType(rawValue: spec.type) ?? .unknown)
            var i = spec.fieldSet
            while i < fieldSets.count, fieldSets[i] >= 0, fieldSets[i] != Int64(UInt32.max), fieldSets[i] != -1 {
                let fieldIndex = Int(fieldSets[i])
                guard fieldIndex < fields.count, fields[fieldIndex].token < tokens.count else {
                    throw USDError("crate: field index out of range")
                }
                let field = fields[fieldIndex]
                out.fields[tokens[field.token]] = try value(field.rep)
                i += 1
            }
            layer.setSpec(out, at: path)
        }
        return layer
    }

    // MARK: Values

    func token(_ i: Int) throws -> String {
        guard i >= 0, i < tokens.count else { throw USDError("crate: token index out of range") }
        return tokens[i]
    }

    func string(_ i: Int) throws -> String {
        guard i >= 0, i < strings.count else { throw USDError("crate: string index out of range") }
        return try token(strings[i])
    }

    func path(_ i: Int) throws -> Path {
        guard i >= 0, i < paths.count else { throw USDError("crate: path index out of range") }
        return paths[i]
    }

    static func valueType(_ t: CrateType) -> ValueType? {
        if t == .timeCode { return .timecode }
        if t == .pathExpression { return .pathExpression }
        return ValueType(rawValue: t.rawValue)
    }

    func value(_ rep: ValueRep) throws -> Value {
        depth += 1
        defer { depth -= 1 }
        guard depth < 64 else { throw USDError("crate: values nested too deeply") }
        guard let type = CrateType(rawValue: rep.typeNumber) else {
            throw USDError("crate: unknown value type \(rep.typeNumber)")
        }
        if rep.isArrayEdit { throw USDError("crate: array edits are not supported") }
        if rep.isArray {
            guard let vt = CrateReader.valueType(type) else { throw USDError("crate: type \(type) cannot be an array") }
            return .array(vt, try arrayComponents(vt, rep))
        }
        if let vt = CrateReader.valueType(type) {
            return .scalar(vt, try scalarComponents(vt, rep))
        }
        let payload = rep.payload
        if rep.isInlined {
            let x = UInt32(truncatingIfNeeded: payload)
            switch type {
            case .specifier: return .specifier(Specifier(rawValue: x) ?? .def)
            case .permission: return .permission(Permission(rawValue: x) ?? .public)
            case .variability: return .variability(x == 0 ? .varying : .uniform)
            case .dictionary: return .dictionary([:])
            case .valueBlock: return .valueBlock
            default: break
            }
        }
        if type == .valueBlock { return .valueBlock }
        var c = ByteCursor(bytes, at: Int(payload))
        return try structured(type, &c)
    }

    /// Reads a non-array, non-inlined structured value at the cursor.
    func structured(_ type: CrateType, _ c: inout ByteCursor) throws -> Value {
        switch type {
        case .dictionary: return .dictionary(try dictionary(&c))
        case .tokenListOp: return .tokenListOp(try listOp(&c) { try self.token(Int(try $0.u32())) })
        case .stringListOp: return .stringListOp(try listOp(&c) { try self.string(Int(try $0.u32())) })
        case .pathListOp: return .pathListOp(try listOp(&c) { try self.path(Int(try $0.u32())) })
        case .referenceListOp: return .referenceListOp(try listOp(&c) { try self.reference(&$0) })
        case .payloadListOp: return .payloadListOp(try listOp(&c) { try self.payload(&$0) })
        case .intListOp: return .integerListOp(.int, try listOp(&c) { Int64(Int32(bitPattern: try $0.u32())) })
        case .uintListOp: return .integerListOp(.uint, try listOp(&c) { Int64(try $0.u32()) })
        case .int64ListOp: return .integerListOp(.int64, try listOp(&c) { try $0.i64() })
        case .uint64ListOp: return .integerListOp(.uint64, try listOp(&c) { try $0.i64() })
        case .pathVector: return .pathVector(try vector(&c) { try self.path(Int(try $0.u32())) })
        case .tokenVector: return .tokenVector(try vector(&c) { try self.token(Int(try $0.u32())) })
        case .stringVector: return .stringVector(try vector(&c) { try self.string(Int(try $0.u32())) })
        case .doubleVector: return .doubleVector(try vector(&c) { try $0.f64() })
        case .layerOffsetVector: return .layerOffsetVector(try vector(&c) { LayerOffset(offset: try $0.f64(), scale: try $0.f64()) })
        case .specifier: return .specifier(Specifier(rawValue: try c.u32()) ?? .def)
        case .permission: return .permission(Permission(rawValue: try c.u32()) ?? .public)
        case .variability: return .variability(try c.u32() == 0 ? .varying : .uniform)
        case .variantSelectionMap:
            let n = try c.count(minimumElementSize: 8)
            var map: [String: String] = [:]
            for _ in 0..<n {
                let key = try string(Int(try c.u32()))
                map[key] = try string(Int(try c.u32()))
            }
            return .variantSelectionMap(map)
        case .timeSamples: return .timeSamples(try timeSamples(&c))
        case .payload: return .payload(try payload(&c))
        case .value: return try nestedValue(&c)
        case .unregisteredValue:
            let inner = try nestedValue(&c)
            return inner
        default:
            throw USDError("crate: value type \(type) is not supported")
        }
    }

    /// A nested value: a relative offset to its representation.
    func nestedValue(_ c: inout ByteCursor) throws -> Value {
        let start = c.pos
        let offset = Int(try c.i64())
        c.pos = start + offset
        let rep = ValueRep(data: try c.u64())
        return try value(rep)
    }

    func dictionary(_ c: inout ByteCursor) throws -> [String: Value] {
        let n = try c.count(minimumElementSize: 12)
        var dict: [String: Value] = [:]
        for _ in 0..<n {
            let key = try string(Int(try c.u32()))
            dict[key] = try nestedValue(&c)
        }
        return dict
    }

    func vector<T>(_ c: inout ByteCursor, _ element: (inout ByteCursor) throws -> T) throws -> [T] {
        let n = try c.count()
        var out: [T] = []
        out.reserveCapacity(n)
        for _ in 0..<n { out.append(try element(&c)) }
        return out
    }

    func listOp<T>(_ c: inout ByteCursor, _ element: (inout ByteCursor) throws -> T) throws -> ListOp<T> {
        let bits = try c.u8()
        var op = ListOp<T>()
        op.isExplicit = bits & 1 != 0
        if bits & 2 != 0 { op.explicitItems = try vector(&c, element) }
        if bits & 4 != 0 { op.addedItems = try vector(&c, element) }
        if bits & 32 != 0 { op.prependedItems = try vector(&c, element) }
        if bits & 64 != 0 { op.appendedItems = try vector(&c, element) }
        if bits & 8 != 0 { op.deletedItems = try vector(&c, element) }
        if bits & 16 != 0 { op.orderedItems = try vector(&c, element) }
        return op
    }

    func reference(_ c: inout ByteCursor) throws -> Reference {
        let asset = try string(Int(try c.u32()))
        let prim = try path(Int(try c.u32()))
        let offset = LayerOffset(offset: try c.f64(), scale: try c.f64())
        let data = try dictionary(&c)
        return Reference(assetPath: asset, primPath: prim, layerOffset: offset, customData: data)
    }

    func payload(_ c: inout ByteCursor) throws -> Payload {
        let asset = try string(Int(try c.u32()))
        let prim = try path(Int(try c.u32()))
        var offset = LayerOffset()
        if version >= CrateVersion(major: 0, minor: 8, patch: 0) {
            offset = LayerOffset(offset: try c.f64(), scale: try c.f64())
        }
        return Payload(assetPath: asset, primPath: prim, layerOffset: offset)
    }

    func timeSamples(_ c: inout ByteCursor) throws -> [TimeSample] {
        var start = c.pos
        c.pos = start + Int(try c.i64())
        let timesRep = ValueRep(data: try c.u64())
        let times: [Double]
        switch try value(timesRep) {
        case .doubleVector(let v): times = v
        case .array(_, let comps): times = comps.doubles
        default: throw USDError("crate: bad time sample times")
        }
        start = c.pos
        c.pos = start + Int(try c.i64())
        let n = try c.count(minimumElementSize: 8)
        guard n == times.count else { throw USDError("crate: time sample count mismatch") }
        var samples: [TimeSample] = []
        for t in times {
            let rep = ValueRep(data: try c.u64())
            samples.append(TimeSample(time: t, value: try value(rep)))
        }
        return samples
    }

    // MARK: Numeric and string components

    func readComponent(_ vt: ValueType, _ c: inout ByteCursor, into acc: inout ComponentAccumulator) throws {
        switch vt {
        case .bool: acc.bools.append(try c.u8() != 0)
        case .uchar: acc.integers.append(Int64(try c.u8()))
        case .int, .vec2i, .vec3i, .vec4i:
            for _ in 0..<vt.componentCount { acc.integers.append(Int64(Int32(bitPattern: try c.u32()))) }
        case .uint: acc.integers.append(Int64(try c.u32()))
        case .int64, .uint64: acc.integers.append(try c.i64())
        case .half, .vec2h, .vec3h, .vec4h:
            for _ in 0..<vt.componentCount { acc.floats.append(try c.f16()) }
        case .float, .vec2f, .vec3f, .vec4f:
            for _ in 0..<vt.componentCount { acc.floats.append(try c.f32()) }
        case .double, .timecode, .vec2d, .vec3d, .vec4d, .matrix2d, .matrix3d, .matrix4d:
            for _ in 0..<vt.componentCount { acc.doubles.append(try c.f64()) }
        case .quath, .quatf, .quatd:
            // Stored imaginary (i, j, k) then real; kept as real, i, j, k.
            var q: [Double] = []
            for _ in 0..<4 {
                switch vt {
                case .quath: q.append(Double(try c.f16()))
                case .quatf: q.append(Double(try c.f32()))
                default: q.append(try c.f64())
                }
            }
            let ordered = [q[3], q[0], q[1], q[2]]
            if vt == .quatd { acc.doubles += ordered } else { acc.floats += ordered.map { Float($0) } }
        case .string: acc.strings.append(try string(Int(try c.u32())))
        case .token: acc.strings.append(try token(Int(try c.u32())))
        case .asset, .pathExpression: acc.strings.append(try string(Int(try c.u32())))
        }
    }

    func scalarComponents(_ vt: ValueType, _ rep: ValueRep) throws -> Components {
        var acc = ComponentAccumulator(type: vt)
        if rep.isInlined {
            let x = UInt32(truncatingIfNeeded: rep.payload)
            switch vt {
            case .bool: acc.bools.append(x & 0xFF != 0)
            case .uchar: acc.integers.append(Int64(x & 0xFF))
            case .int, .int64: acc.integers.append(Int64(Int32(bitPattern: x)))
            case .uint, .uint64: acc.integers.append(Int64(x))
            case .half: acc.floats.append(Half.toFloat(UInt16(truncatingIfNeeded: x)))
            case .float: acc.floats.append(Float(bitPattern: x))
            case .double, .timecode: acc.doubles.append(Double(Float(bitPattern: x)))
            case .string: acc.strings.append(try string(Int(x)))
            case .token: acc.strings.append(try token(Int(x)))
            case .asset: acc.strings.append(try token(Int(x)))
            case .pathExpression: acc.strings.append(try string(Int(x)))
            case .vec2d, .vec2f, .vec2h, .vec2i, .vec3d, .vec3f, .vec3h, .vec3i, .vec4d, .vec4f, .vec4h, .vec4i:
                let comps = (0..<vt.componentCount).map { Double(Int8(bitPattern: UInt8(truncatingIfNeeded: x >> (8 * UInt32($0))))) }
                return .from(doubles: comps, as: vt)
            case .matrix2d, .matrix3d, .matrix4d:
                let n = vt.matrixRows
                var m = [Double](repeating: 0, count: n * n)
                for i in 0..<n { m[i * n + i] = Double(Int8(bitPattern: UInt8(truncatingIfNeeded: x >> (8 * UInt32(i))))) }
                return .doubles(m)
            case .quatd, .quatf, .quath:
                throw USDError("crate: inlined quaternion")
            }
            return acc.components
        }
        var c = ByteCursor(bytes, at: Int(rep.payload))
        try readComponent(vt, &c, into: &acc)
        return acc.components
    }

    func arrayComponents(_ vt: ValueType, _ rep: ValueRep) throws -> Components {
        var acc = ComponentAccumulator(type: vt)
        guard rep.payload != 0 else { return acc.components }
        var c = ByteCursor(bytes, at: Int(rep.payload))
        if version < CrateVersion(major: 0, minor: 5, patch: 0) { _ = try c.u32() }
        let count = version < CrateVersion(major: 0, minor: 7, patch: 0) ? Int(try c.u32()) : try c.count()
        let compressible: Bool = {
            switch vt {
            case .int, .uint, .int64, .uint64: return version >= CrateVersion(major: 0, minor: 5, patch: 0)
            case .half, .float, .double: return version >= CrateVersion(major: 0, minor: 6, patch: 0)
            default: return false
            }
        }()
        if compressible && rep.isCompressed && count >= 16 {
            switch vt {
            case .int, .uint:
                let size = try c.count()
                let ints = try IntegerCoding.decode32(try c.slice(size), count: count)
                acc.integers = vt == .uint ? ints.map { Int64(UInt32(truncatingIfNeeded: $0)) } : ints
            case .int64, .uint64:
                let size = try c.count()
                acc.integers = try IntegerCoding.decode64(try c.slice(size), count: count)
            default:
                let code = try c.u8()
                if code == UInt8(ascii: "i") {
                    let size = try c.count()
                    let ints = try IntegerCoding.decode32(try c.slice(size), count: count)
                    if vt == .double { acc.doubles = ints.map(Double.init) } else { acc.floats = ints.map(Float.init) }
                } else if code == UInt8(ascii: "t") {
                    let lutSize = Int(try c.u32())
                    var lut = ComponentAccumulator(type: vt)
                    for _ in 0..<lutSize { try readComponent(vt, &c, into: &lut) }
                    let size = try c.count()
                    let indexes = try IntegerCoding.decode32(try c.slice(size), count: count)
                    for i in indexes {
                        let k = Int(UInt32(truncatingIfNeeded: i))
                        if vt == .double {
                            guard k < lut.doubles.count else { throw USDError("crate: lookup index out of range") }
                            acc.doubles.append(lut.doubles[k])
                        } else {
                            guard k < lut.floats.count else { throw USDError("crate: lookup index out of range") }
                            acc.floats.append(lut.floats[k])
                        }
                    }
                } else {
                    throw USDError("crate: corrupt compressed array")
                }
            }
            return acc.components
        }
        for _ in 0..<count { try readComponent(vt, &c, into: &acc) }
        return acc.components
    }
}
