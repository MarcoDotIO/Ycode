/// Writes a `Layer` in the crate (`.usdc`) binary format, version 0.8.0
/// (0.9.0 when the layer holds timecode values, 0.10.0 for path
/// expressions), with compressed structural sections and compressed
/// integer and floating-point arrays.
public enum USDCWriter {
    public static func write(_ layer: Layer) throws -> [UInt8] {
        let writer = CrateWriter()
        return try writer.write(layer)
    }
}

final class CrateWriter {
    var out = [UInt8](repeating: 0, count: 88)
    var tokens: [String] = []
    var tokenIndex: [String: Int] = [:]
    var strings: [Int] = []
    var stringIndex: [String: Int] = [:]
    var paths: [Path] = []
    var pathIndex: [Path: Int] = [:]
    var fields: [(token: Int, rep: UInt64)] = []
    var fieldIndex: [[UInt64]: Int] = [:]
    var fieldSets: [Int64] = []
    var fieldSetIndex: [[Int]: Int] = [:]
    var specs: [(path: Int, fieldSet: Int, type: UInt32)] = []
    var version = CrateVersion(major: 0, minor: 8, patch: 0)

    init() {
        // A first token that is never a path element: a property element
        // token is stored negated, so index 0 must not be one.
        _ = token(";-)")
    }

    // MARK: Tables

    func token(_ s: String) -> Int {
        if let i = tokenIndex[s] { return i }
        tokens.append(s)
        tokenIndex[s] = tokens.count - 1
        return tokens.count - 1
    }

    func string(_ s: String) -> Int {
        if let i = stringIndex[s] { return i }
        strings.append(token(s))
        stringIndex[s] = strings.count - 1
        return strings.count - 1
    }

    func path(_ p: Path) -> Int {
        if let i = pathIndex[p] { return i }
        var p = p
        if p.kind == .relative { p = p.makingAbsolute(anchor: .root) }
        if let i = pathIndex[p] { return i }
        if !p.isEmpty && !p.isRoot { _ = path(p.parent) }
        if !p.isEmpty {
            if p.isPrimPropertyPath {
                _ = token(p.name)
            } else if let last = p.last {
                _ = token(Path.text(of: last))
            }
        }
        paths.append(p)
        pathIndex[p] = paths.count - 1
        return paths.count - 1
    }

    // MARK: Output

    func align(_ n: Int) {
        while out.count % n != 0 { out.append(0) }
    }

    func put<T: FixedWidthInteger>(_ v: T) {
        var le = v.littleEndian
        withUnsafeBytes(of: &le) { out.append(contentsOf: $0) }
    }

    func putF32(_ v: Float) { put(v.bitPattern) }
    func putF64(_ v: Double) { put(v.bitPattern) }
    func putF16(_ v: Float) { put(Half.fromFloat(v)) }

    func patch64(at offset: Int, _ value: Int64) {
        let u = UInt64(bitPattern: value)
        for k in 0..<8 { out[offset + k] = UInt8(truncatingIfNeeded: u >> (8 * UInt64(k))) }
    }

    // MARK: Layer

    func write(_ layer: Layer) throws -> [UInt8] {
        // Specs in depth-first order of the namespace.
        let ordered = layer.allPaths.sorted { a, b in
            a.elements.count != b.elements.count ? a.description < b.description : a.description < b.description
        }
        _ = path(.root)
        for p in ordered { _ = path(p) }
        for p in ordered {
            guard let spec = layer.spec(at: p) else { continue }
            var indexes: [Int] = []
            for key in spec.fields.keys.sorted() {
                let rep = try pack(spec.fields[key]!)
                let t = token(key)
                let fieldKey = [UInt64(t), rep.data]
                if let existing = fieldIndex[fieldKey] {
                    indexes.append(existing)
                } else {
                    fields.append((t, rep.data))
                    fieldIndex[fieldKey] = fields.count - 1
                    indexes.append(fields.count - 1)
                }
            }
            let setIndex: Int
            if let existing = fieldSetIndex[indexes] {
                setIndex = existing
            } else {
                setIndex = fieldSets.count
                fieldSets += indexes.map(Int64.init) + [Int64(UInt32.max)]
                fieldSetIndex[indexes] = setIndex
            }
            specs.append((path(p), setIndex, spec.type.rawValue))
        }
        // Empty path last so it never takes part in the tree.
        _ = path(.empty)

        var sections: [(String, Int, Int)] = []
        func section(_ name: String, _ body: () -> Void) {
            let start = out.count
            body()
            sections.append((name, start, out.count - start))
        }
        section("TOKENS") {
            var chars: [UInt8] = []
            for t in tokens { chars += Array(t.utf8) + [0] }
            put(UInt64(tokens.count))
            put(UInt64(chars.count))
            let compressed = LZ4.compress(chars)
            put(UInt64(compressed.count))
            out += compressed
        }
        section("STRINGS") {
            put(UInt64(strings.count))
            for s in strings { put(UInt32(s)) }
        }
        section("FIELDS") {
            put(UInt64(fields.count))
            writeCompressedInts(fields.map { Int64($0.token) })
            var reps: [UInt8] = []
            for f in fields {
                for k in 0..<8 { reps.append(UInt8(truncatingIfNeeded: f.rep >> (8 * UInt64(k)))) }
            }
            let compressed = LZ4.compress(reps)
            put(UInt64(compressed.count))
            out += compressed
        }
        section("FIELDSETS") {
            put(UInt64(fieldSets.count))
            writeCompressedInts(fieldSets)
        }
        section("PATHS") { writePaths() }
        section("SPECS") {
            put(UInt64(specs.count))
            writeCompressedInts(specs.map { Int64($0.path) })
            writeCompressedInts(specs.map { Int64($0.fieldSet) })
            writeCompressedInts(specs.map { Int64($0.type) })
        }
        let tocOffset = out.count
        put(UInt64(sections.count))
        for (name, start, size) in sections {
            var nameBytes = Array(name.utf8)
            nameBytes += [UInt8](repeating: 0, count: 16 - nameBytes.count)
            out += nameBytes
            put(Int64(start))
            put(Int64(size))
        }
        // Bootstrap.
        let magic = Array("PXR-USDC".utf8)
        for (i, b) in magic.enumerated() { out[i] = b }
        out[8] = version.major
        out[9] = version.minor
        out[10] = version.patch
        patch64(at: 16, Int64(tocOffset))
        return out
    }

    func writeCompressedInts(_ values: [Int64]) {
        let compressed = IntegerCoding.encode32(values)
        put(UInt64(compressed.count))
        out += compressed
    }

    func writePaths() {
        put(UInt64(paths.count))
        // Children of each path, in table order.
        var children: [Int: [Int]] = [:]
        for (i, p) in paths.enumerated() where !p.isEmpty && !p.isRoot {
            children[pathIndex[p.parent]!, default: []].append(i)
        }
        var pathIndexes: [Int64] = []
        var elementTokens: [Int64] = []
        var jumps: [Int64] = []
        func visit(_ i: Int, hasSibling: Bool) {
            let me = pathIndexes.count
            let p = paths[i]
            pathIndexes.append(Int64(i))
            if p.isRoot {
                elementTokens.append(0)
            } else if p.isPrimPropertyPath {
                elementTokens.append(-Int64(token(p.name)))
            } else {
                elementTokens.append(Int64(token(Path.text(of: p.last!))))
            }
            jumps.append(0)
            let kids = children[i] ?? []
            for (k, child) in kids.enumerated() { visit(child, hasSibling: k < kids.count - 1) }
            let hasChild = !kids.isEmpty
            switch (hasChild, hasSibling) {
            case (true, true): jumps[me] = Int64(pathIndexes.count - me)
            case (false, true): jumps[me] = 0
            case (true, false): jumps[me] = -1
            case (false, false): jumps[me] = -2
            }
        }
        if let root = pathIndex[.root] { visit(root, hasSibling: false) }
        put(UInt64(pathIndexes.count))
        writeCompressedInts(pathIndexes)
        writeCompressedInts(elementTokens)
        writeCompressedInts(jumps)
    }

    // MARK: Values

    static func crateType(_ vt: ValueType) -> CrateType {
        switch vt {
        case .timecode: return .timeCode
        case .pathExpression: return .pathExpression
        default: return CrateType(rawValue: vt.rawValue)!
        }
    }

    func requireVersion(minor: UInt8) {
        if version.minor < minor { version.minor = minor }
    }

    func pack(_ value: Value) throws -> ValueRep {
        switch value {
        case .scalar(let vt, let c): return try packScalar(vt, c)
        case .array(let vt, let c): return try packArray(vt, c)
        case .valueBlock: return ValueRep(type: .valueBlock, inlined: true)
        case .specifier(let s): return ValueRep(type: .specifier, inlined: true, payload: UInt64(s.rawValue))
        case .permission(let p): return ValueRep(type: .permission, inlined: true, payload: UInt64(p.rawValue))
        case .variability(let v): return ValueRep(type: .variability, inlined: true, payload: UInt64(v.rawValue))
        case .dictionary(let d):
            if d.isEmpty { return ValueRep(type: .dictionary, inlined: true) }
            // Nested values are written before the dictionary body.
            return try packStructured(.dictionary) { try self.writeDictionary(d) }
        case .tokenListOp(let op):
            return try packStructured(.tokenListOp) { try self.writeListOp(op) { self.put(UInt32(self.token($0))) } }
        case .stringListOp(let op):
            return try packStructured(.stringListOp) { try self.writeListOp(op) { self.put(UInt32(self.string($0))) } }
        case .pathListOp(let op):
            return try packStructured(.pathListOp) { try self.writeListOp(op) { self.put(UInt32(self.path($0))) } }
        case .referenceListOp(let op):
            return try packStructured(.referenceListOp) { try self.writeListOp(op) { try self.writeReference($0) } }
        case .payloadListOp(let op):
            return try packStructured(.payloadListOp) { try self.writeListOp(op) { self.writePayload($0) } }
        case .integerListOp(let vt, let op):
            let type: CrateType = vt == .int64 ? .int64ListOp : vt == .uint ? .uintListOp : vt == .uint64 ? .uint64ListOp : .intListOp
            let wide = vt == .int64 || vt == .uint64
            return try packStructured(type) {
                try self.writeListOp(op) { wide ? self.put($0) : self.put(UInt32(truncatingIfNeeded: $0)) }
            }
        case .path(let p):
            // Single paths only occur as relationship defaults; store as a vector of one.
            return try packStructured(.pathVector) {
                self.put(UInt64(1))
                self.put(UInt32(self.path(p)))
            }
        case .pathVector(let v):
            return try packStructured(.pathVector) {
                self.put(UInt64(v.count))
                for p in v { self.put(UInt32(self.path(p))) }
            }
        case .tokenVector(let v):
            return try packStructured(.tokenVector) {
                self.put(UInt64(v.count))
                for t in v { self.put(UInt32(self.token(t))) }
            }
        case .stringVector(let v):
            return try packStructured(.stringVector) {
                self.put(UInt64(v.count))
                for s in v { self.put(UInt32(self.string(s))) }
            }
        case .doubleVector(let v):
            return try packStructured(.doubleVector) {
                self.put(UInt64(v.count))
                for d in v { self.putF64(d) }
            }
        case .layerOffsetVector(let v):
            return try packStructured(.layerOffsetVector) {
                self.put(UInt64(v.count))
                for o in v {
                    self.putF64(o.offset)
                    self.putF64(o.scale)
                }
            }
        case .variantSelectionMap(let m):
            return try packStructured(.variantSelectionMap) {
                self.put(UInt64(m.count))
                for key in m.keys.sorted() {
                    self.put(UInt32(self.string(key)))
                    self.put(UInt32(self.string(m[key]!)))
                }
            }
        case .timeSamples(let samples):
            return try packTimeSamples(samples)
        case .payload(let p):
            return try packStructured(.payload) { self.writePayload(p) }
        }
    }

    /// Writes a structured value at the end of the output and returns its rep.
    func packStructured(_ type: CrateType, _ body: () throws -> Void) throws -> ValueRep {
        let start = out.count
        try body()
        return ValueRep(type: type, payload: UInt64(start))
    }

    /// The crate's nested-value layout: an int64 forward offset, any data the
    /// value needs, then the value's rep.
    func writeNested(_ value: Value) throws {
        let offsetLocation = out.count
        put(Int64(0))
        let rep = try pack(value)
        patch64(at: offsetLocation, Int64(out.count - offsetLocation))
        put(rep.data)
    }

    func writeDictionary(_ d: [String: Value]) throws {
        put(UInt64(d.count))
        for key in d.keys.sorted() {
            put(UInt32(string(key)))
            try writeNested(d[key]!)
        }
    }

    func writeListOp<T>(_ op: ListOp<T>, _ item: (T) throws -> Void) throws {
        var bits: UInt8 = op.isExplicit ? 1 : 0
        if !op.explicitItems.isEmpty { bits |= 2 }
        if !op.addedItems.isEmpty { bits |= 4 }
        if !op.deletedItems.isEmpty { bits |= 8 }
        if !op.orderedItems.isEmpty { bits |= 16 }
        if !op.prependedItems.isEmpty { bits |= 32 }
        if !op.appendedItems.isEmpty { bits |= 64 }
        out.append(bits)
        for list in [op.explicitItems, op.addedItems, op.prependedItems, op.appendedItems, op.deletedItems, op.orderedItems]
        where !list.isEmpty {
            put(UInt64(list.count))
            for x in list { try item(x) }
        }
    }

    func writeReference(_ r: Reference) throws {
        put(UInt32(string(r.assetPath)))
        put(UInt32(path(r.primPath)))
        putF64(r.layerOffset.offset)
        putF64(r.layerOffset.scale)
        try writeDictionary(r.customData)
    }

    func writePayload(_ p: Payload) {
        put(UInt32(string(p.assetPath)))
        put(UInt32(path(p.primPath)))
        putF64(p.layerOffset.offset)
        putF64(p.layerOffset.scale)
    }

    func packTimeSamples(_ samples: [TimeSample]) throws -> ValueRep {
        let start = out.count
        // Times.
        put(Int64(0))
        let timesRep = try pack(.doubleVector(samples.map(\.time)))
        patch64(at: start, Int64(out.count - start))
        put(timesRep.data)
        // Values.
        let valuesStart = out.count
        put(Int64(0))
        var reps: [ValueRep] = []
        for s in samples { reps.append(try pack(s.value)) }
        patch64(at: valuesStart, Int64(out.count - valuesStart))
        put(UInt64(reps.count))
        for r in reps { put(r.data) }
        return ValueRep(type: .timeSamples, payload: UInt64(start))
    }

    // MARK: Scalars and arrays

    func inlineInt8s(_ values: [Double]) -> UInt32? {
        var payload: UInt32 = 0
        for (i, v) in values.enumerated() {
            guard v >= -128, v <= 127, v == v.rounded() else { return nil }
            payload |= UInt32(UInt8(bitPattern: Int8(v))) << (8 * UInt32(i))
        }
        return payload
    }

    func packScalar(_ vt: ValueType, _ c: Components) throws -> ValueRep {
        let type = CrateWriter.crateType(vt)
        if vt == .timecode { requireVersion(minor: 9) }
        if vt == .pathExpression { requireVersion(minor: 10) }
        func inline(_ payload: UInt32) -> ValueRep { ValueRep(type: type, inlined: true, payload: UInt64(payload)) }
        switch (vt, c) {
        case (.bool, .bools(let a)): return inline(a.first == true ? 1 : 0)
        case (.uchar, .integers(let a)): return inline(UInt32(truncatingIfNeeded: a.first ?? 0) & 0xFF)
        case (.int, .integers(let a)): return inline(UInt32(bitPattern: Int32(truncatingIfNeeded: a.first ?? 0)))
        case (.uint, .integers(let a)): return inline(UInt32(truncatingIfNeeded: a.first ?? 0))
        case (.int64, .integers(let a)):
            let v = a.first ?? 0
            if v >= Int64(Int32.min) && v <= Int64(Int32.max) { return inline(UInt32(bitPattern: Int32(v))) }
        case (.uint64, .integers(let a)):
            let v = UInt64(bitPattern: a.first ?? 0)
            if v <= UInt64(UInt32.max) { return inline(UInt32(v)) }
        case (.half, .floats(let a)): return inline(UInt32(Half.fromFloat(a.first ?? 0)))
        case (.float, .floats(let a)): return inline((a.first ?? 0).bitPattern)
        case (.double, .doubles(let a)):
            let v = a.first ?? 0
            if let f = Float(exactly: v) { return inline(f.bitPattern) }
        case (.string, .strings(let a)): return inline(UInt32(string(a.first ?? "")))
        case (.token, .strings(let a)): return inline(UInt32(token(a.first ?? "")))
        case (.asset, .strings(let a)): return inline(UInt32(token(a.first ?? "")))
        default:
            if vt.storage != .string, !vt.isQuaternion {
                let comps = c.doubles
                if vt.isMatrix {
                    let n = vt.matrixRows
                    let offDiagonalZero = (0..<(n * n)).allSatisfy { $0 % (n + 1) == 0 || comps[$0] == 0 }
                    if offDiagonalZero, let payload = inlineInt8s((0..<n).map { comps[$0 * (n + 1)] }) { return inline(payload) }
                } else if vt.componentCount > 1, let payload = inlineInt8s(comps) {
                    return inline(payload)
                }
            }
        }
        let start = out.count
        try writeElements(vt, c, from: 0, count: 1)
        return ValueRep(type: type, payload: UInt64(start))
    }

    func writeElements(_ vt: ValueType, _ c: Components, from: Int, count: Int) throws {
        let w = vt.componentCount
        switch c {
        case .bools(let a):
            for i in from..<(from + count) { out.append(a[i] ? 1 : 0) }
        case .integers(let a):
            for i in (from * w)..<((from + count) * w) {
                switch vt {
                case .uchar: out.append(UInt8(truncatingIfNeeded: a[i]))
                case .int64, .uint64: put(a[i])
                default: put(UInt32(truncatingIfNeeded: a[i]))
                }
            }
        case .floats(let a):
            for e in from..<(from + count) {
                var comps = Array(a[(e * w)..<((e + 1) * w)])
                if vt.isQuaternion { comps = [comps[1], comps[2], comps[3], comps[0]] }
                for v in comps {
                    if vt == .half || vt == .vec2h || vt == .vec3h || vt == .vec4h || vt == .quath { putF16(v) } else { putF32(v) }
                }
            }
        case .doubles(let a):
            for e in from..<(from + count) {
                var comps = Array(a[(e * w)..<((e + 1) * w)])
                if vt.isQuaternion { comps = [comps[1], comps[2], comps[3], comps[0]] }
                for v in comps { putF64(v) }
            }
        case .strings(let a):
            for i in from..<(from + count) {
                put(UInt32(vt == .token ? token(a[i]) : string(a[i])))
            }
        }
    }

    func packArray(_ vt: ValueType, _ c: Components) throws -> ValueRep {
        let type = CrateWriter.crateType(vt)
        if vt == .timecode { requireVersion(minor: 9) }
        if vt == .pathExpression { requireVersion(minor: 10) }
        let count = c.count / max(vt.componentCount, 1)
        if count == 0 { return ValueRep(type: type, array: true) }
        switch (vt, c) {
        case (.int, .integers(let a)), (.uint, .integers(let a)), (.int64, .integers(let a)), (.uint64, .integers(let a)):
            var rep = ValueRep(type: type, array: true, payload: UInt64(out.count))
            put(UInt64(count))
            if count < 16 {
                try writeElements(vt, c, from: 0, count: count)
            } else {
                let compressed = vt == .int64 || vt == .uint64 ? IntegerCoding.encode64(a) : IntegerCoding.encode32(a)
                put(UInt64(compressed.count))
                out += compressed
                rep.setCompressed()
            }
            return rep
        case (.float, _), (.double, _), (.half, _):
            let values = c.doubles
            if count >= 16, values.allSatisfy({ $0 >= -2_147_483_648 && $0 <= 2_147_483_647 && $0 == $0.rounded() }) {
                var rep = ValueRep(type: type, array: true, payload: UInt64(out.count))
                put(UInt64(count))
                out.append(UInt8(ascii: "i"))
                writeCompressedInts(values.map { Int64($0) })
                rep.setCompressed()
                return rep
            }
        default:
            break
        }
        align(8)
        let rep = ValueRep(type: type, array: true, payload: UInt64(out.count))
        put(UInt64(count))
        try writeElements(vt, c, from: 0, count: count)
        return rep
    }
}
