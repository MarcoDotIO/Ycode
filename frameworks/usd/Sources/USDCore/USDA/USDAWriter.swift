/// Writes a `Layer` as USDA text in the layout OpenUSD uses: four-space
/// indentation, metadata in parentheses sorted by field name, properties,
/// then child prims separated by blank lines, then variant sets.
public enum USDAWriter {
    public struct Options: Sendable {
        /// Sort properties and variants by name as OpenUSD's writer does.
        /// Off by default: the authored order is kept so text round trips
        /// are exact.
        public var sortPropertiesAndVariants: Bool

        public init(sortPropertiesAndVariants: Bool = false) {
            self.sortPropertiesAndVariants = sortPropertiesAndVariants
        }
    }

    public static func write(_ layer: Layer, options: Options = Options()) -> String {
        var w = Writer(layer: layer, options: options)
        w.writeLayer()
        return w.out
    }

    /// Text form of one value (used by tools that print attribute values).
    public static func string(for value: Value) -> String {
        var w = Writer(layer: Layer(), options: Options())
        w.writeValue(value, indent: 0)
        return w.out
    }

    /// USDA quoting of a string: double quotes, single quotes when the text
    /// contains `"` only, triple quotes when it contains a newline.
    public static func quote(_ text: String) -> String {
        let hasNewline = text.contains("\n")
        let hasDouble = text.contains("\"")
        let hasSingle = text.contains("'")
        let quote: String
        if hasNewline {
            quote = hasDouble && !hasSingle ? "'''" : "\"\"\""
        } else {
            quote = hasDouble && !hasSingle ? "'" : "\""
        }
        let q = quote.first!
        var out = quote
        for scalar in text.unicodeScalars {
            switch scalar {
            case "\\": out += "\\\\"
            case "\n": out += hasNewline ? "\n" : "\\n"
            case "\t": out += "\\t"
            case "\r": out += "\\r"
            default:
                if Character(scalar) == q {
                    out += "\\" + String(scalar)
                } else if scalar.value < 0x20 || scalar.value == 0x7F {
                    let hex = String(scalar.value, radix: 16)
                    out += "\\x" + (hex.count < 2 ? "0" + hex : hex)
                } else {
                    out.unicodeScalars.append(scalar)
                }
            }
        }
        return out + quote
    }

    /// `@path@`, or `@@@path@@@` when the path contains `@`.
    public static func assetText(_ path: String) -> String {
        guard path.contains("@") else { return "@" + path + "@" }
        return "@@@" + path.replacingOccurrences(of: "@@@", with: "\\@@@") + "@@@"
    }
}

extension String {
    func replacingOccurrences(of target: String, with replacement: String) -> String {
        guard !target.isEmpty else { return self }
        var result = ""
        var rest = Substring(self)
        while let range = rest.range(of: target) {
            result += rest[..<range.lowerBound] + replacement
            rest = rest[range.upperBound...]
        }
        return result + rest
    }
}

extension Substring {
    func range(of target: String) -> Range<Index>? {
        guard !target.isEmpty, count >= target.count else { return nil }
        var i = startIndex
        while i < endIndex {
            if self[i...].hasPrefix(target) {
                return i..<index(i, offsetBy: target.count)
            }
            i = index(after: i)
        }
        return nil
    }
}

/// OpenUSD's "dictionary" ordering for field and property names: compare
/// case-insensitively with digit runs compared by value; ties break on case.
public func dictionaryLessThan(_ a: String, _ b: String) -> Bool {
    let x = Array(a.unicodeScalars)
    let y = Array(b.unicodeScalars)
    var i = 0
    var j = 0
    while i < x.count && j < y.count {
        let cx = x[i]
        let cy = y[j]
        let dx = cx.value >= 48 && cx.value <= 57
        let dy = cy.value >= 48 && cy.value <= 57
        if dx && dy {
            var ni = i
            var nj = j
            while ni < x.count, x[ni].value >= 48, x[ni].value <= 57 { ni += 1 }
            while nj < y.count, y[nj].value >= 48, y[nj].value <= 57 { nj += 1 }
            let vx = UInt64(String(String.UnicodeScalarView(x[i..<ni]))) ?? 0
            let vy = UInt64(String(String.UnicodeScalarView(y[j..<nj]))) ?? 0
            if vx != vy { return vx < vy }
            i = ni
            j = nj
            continue
        }
        let lx = cx.properties.lowercaseMapping
        let ly = cy.properties.lowercaseMapping
        if lx != ly { return lx < ly }
        i += 1
        j += 1
    }
    if x.count - i != y.count - j { return x.count - i < y.count - j }
    return a < b
}

private struct Writer {
    let layer: Layer
    let options: USDAWriter.Options
    var out = ""

    init(layer: Layer, options: USDAWriter.Options) {
        self.layer = layer
        self.options = options
    }

    mutating func put(_ text: String) { out += text }

    mutating func line(_ indent: Int, _ text: String) {
        out += String(repeating: "    ", count: indent) + text + "\n"
    }

    func pad(_ indent: Int) -> String { String(repeating: "    ", count: indent) }

    // MARK: Layer

    static let layerSkip: Set<String> = [FieldKey.primChildren, FieldKey.primOrder, FieldKey.comment]

    mutating func writeLayer() {
        put("#usda 1.0\n")
        let root = layer.pseudoRoot
        let keys = root.fields.keys.filter { !Writer.layerSkip.contains($0) }.sorted(by: dictionaryLessThan)
        if !keys.isEmpty || root[FieldKey.comment] != nil {
            put("(\n")
            if let comment = root[FieldKey.comment]?.stringValue { line(1, USDAWriter.quote(comment)) }
            for key in keys {
                guard let value = root[key] else { continue }
                switch key {
                case FieldKey.documentation:
                    line(1, "doc = " + USDAWriter.quote(value.stringValue ?? ""))
                case FieldKey.subLayers:
                    writeSubLayers()
                case FieldKey.subLayerOffsets:
                    continue
                default:
                    writeField(key, value, indent: 1)
                }
            }
            put(")\n")
        }
        put("\n")
        if let order = root[FieldKey.primOrder]?.stringArray, !order.isEmpty {
            line(0, "reorder rootPrims = " + nameList(order))
            put("\n")
        }
        for child in layer.primChildren(of: .root) {
            let path = Path.root.appendingChild(child)
            guard let spec = layer.spec(at: path) else { continue }
            writePrim(spec, path: path, indent: 0)
            put("\n")
        }
    }

    mutating func writeSubLayers() {
        let paths = layer.subLayers
        let offsets = layer.subLayerOffsets
        line(1, "subLayers = [")
        for (i, p) in paths.enumerated() {
            var text = USDAWriter.assetText(p)
            if i < offsets.count, !offsets[i].isIdentity { text += " " + offsetText(offsets[i]) }
            line(2, text + (i < paths.count - 1 ? "," : ""))
        }
        line(1, "]")
    }

    func offsetText(_ o: LayerOffset) -> String {
        var parts: [String] = []
        if o.offset != 0 { parts.append("offset = " + NumberFormat.format(o.offset)) }
        if o.scale != 1 { parts.append("scale = " + NumberFormat.format(o.scale)) }
        return "(" + parts.joined(separator: "; ") + ")"
    }

    // MARK: Prims

    static let primSkip: Set<String> = FieldKey.childrenFields.union([
        FieldKey.specifier, FieldKey.typeName, FieldKey.primOrder, FieldKey.propertyOrder, FieldKey.comment,
    ])

    mutating func writePrim(_ spec: Spec, path: Path, indent: Int) {
        var head = pad(indent)
        if case .specifier(let s)? = spec[FieldKey.specifier] { head += s.keyword } else { head += "over" }
        if let type = spec[FieldKey.typeName]?.stringValue, !type.isEmpty { head += " " + type }
        head += " " + USDAWriter.quote(path.name)
        put(head)
        writePrimMetadata(spec, indent: indent)
        put("\n")
        line(indent, "{")
        writePrimBody(spec, path: path, indent: indent)
        line(indent, "}")
    }

    /// Writes ` (\n … \n)` after a prim or variant header when there is metadata.
    mutating func writePrimMetadata(_ spec: Spec, indent: Int) {
        let keys = spec.fields.keys.filter { !Writer.primSkip.contains($0) }.sorted(by: dictionaryLessThan)
        let comment = spec[FieldKey.comment]?.stringValue
        guard !keys.isEmpty || comment != nil else { return }
        put(" (\n")
        if let comment { line(indent + 1, USDAWriter.quote(comment)) }
        for key in keys {
            let value = spec.fields[key]!
            switch key {
            case FieldKey.documentation: line(indent + 1, "doc = " + USDAWriter.quote(value.stringValue ?? ""))
            case FieldKey.inheritPaths: writeListOp(value, name: "inherits", indent: indent + 1)
            case FieldKey.variantSetNames: writeListOp(value, name: "variantSets", indent: indent + 1)
            case FieldKey.variantSelection:
                if case .variantSelectionMap(let map) = value {
                    put(pad(indent + 1) + "variants = ")
                    writeDictionary(map.mapValues { Value.string($0) }, indent: indent + 1)
                    put("\n")
                }
            case FieldKey.permission:
                if case .permission(let p) = value { line(indent + 1, "permission = " + (p == .private ? "private" : "public")) }
            default:
                writeField(key, value, indent: indent + 1)
            }
        }
        put(pad(indent) + ")")
    }

    mutating func writePrimBody(_ spec: Spec, path: Path, indent: Int) {
        if let order = spec[FieldKey.propertyOrder]?.stringArray, order.count > 1 {
            line(indent + 1, "reorder properties = " + nameList(order))
        }
        if let order = spec[FieldKey.primOrder]?.stringArray, order.count > 1 {
            line(indent + 1, "reorder nameChildren = " + nameList(order))
        }
        var properties = spec[FieldKey.properties]?.stringArray ?? []
        if options.sortPropertiesAndVariants { properties.sort(by: dictionaryLessThan) }
        var wroteProperty = false
        for name in properties {
            let p = path.appendingProperty(name)
            guard let prop = layer.spec(at: p) else { continue }
            wroteProperty = true
            if prop.type == .relationship {
                writeRelationship(prop, name: name, indent: indent + 1)
            } else {
                writeAttribute(prop, name: name, indent: indent + 1)
            }
        }
        let children = (spec[FieldKey.primChildren]?.stringArray ?? []).filter { layer.hasSpec(at: path.appendingChild($0)) }
        if wroteProperty && !children.isEmpty { put("\n") }
        for (i, child) in children.enumerated() {
            if i > 0 { put("\n") }
            let p = path.appendingChild(child)
            writePrim(layer.spec(at: p)!, path: p, indent: indent + 1)
        }
        for set in spec[FieldKey.variantSetChildren]?.stringArray ?? [] {
            let setPath = path.appendingVariantSelection(set: set, variant: "")
            guard let setSpec = layer.spec(at: setPath) else { continue }
            var variants = setSpec[FieldKey.variantChildren]?.stringArray ?? []
            if options.sortPropertiesAndVariants { variants.sort() }
            guard !variants.isEmpty else { continue }
            line(indent + 1, "variantSet " + USDAWriter.quote(set) + " = {")
            for variant in variants {
                let vPath = path.appendingVariantSelection(set: set, variant: variant)
                guard let vSpec = layer.spec(at: vPath) else { continue }
                put(pad(indent + 2) + USDAWriter.quote(variant))
                writePrimMetadata(vSpec, indent: indent + 2)
                put(" {\n")
                writePrimBody(vSpec, path: vPath, indent: indent + 2)
                put("\n")
                line(indent + 2, "}")
            }
            line(indent + 1, "}")
        }
    }

    // MARK: Properties

    static let attributeSkip: Set<String> = FieldKey.childrenFields.union([
        FieldKey.typeName, FieldKey.defaultValue, FieldKey.timeSamples, FieldKey.connectionPaths, FieldKey.variability,
        FieldKey.custom, FieldKey.comment, "spline",
    ])

    mutating func writeAttribute(_ spec: Spec, name: String, indent: Int) {
        let typeText = spec[FieldKey.typeName]?.stringValue ?? "token"
        let type = TypeName(typeText)
        let uniform: Bool = {
            if case .variability(.uniform)? = spec[FieldKey.variability] { return true }
            return false
        }()
        let variabilityText = uniform ? "uniform " : ""
        let custom = spec[FieldKey.custom]?.boolValue == true
        let keys = spec.fields.keys.filter { !Writer.attributeSkip.contains($0) }.sorted(by: dictionaryLessThan)
        let comment = spec[FieldKey.comment]?.stringValue
        let hasInfo = !keys.isEmpty || comment != nil
        let hasDefault = spec[FieldKey.defaultValue] != nil
        let hasConnections = spec[FieldKey.connectionPaths] != nil
        let hasTimeSamples = spec[FieldKey.timeSamples] != nil
        if hasInfo || hasDefault || custom || (!hasConnections && !hasTimeSamples) {
            put(pad(indent) + (custom ? "custom " : "") + variabilityText + typeText + " " + name)
            if let value = spec[FieldKey.defaultValue] {
                put(" = ")
                writeAttributeValue(value, type: type, indent: indent)
            }
            if hasInfo {
                put(" (\n")
                if let comment { line(indent + 1, USDAWriter.quote(comment)) }
                for key in keys {
                    let value = spec.fields[key]!
                    switch key {
                    case FieldKey.documentation: line(indent + 1, "doc = " + USDAWriter.quote(value.stringValue ?? ""))
                    case FieldKey.permission:
                        if case .permission(let p) = value { line(indent + 1, "permission = " + (p == .private ? "private" : "public")) }
                    case "displayUnit", "symmetryFunction":
                        line(indent + 1, key + " = " + (value.stringValue ?? ""))
                    default: writeField(key, value, indent: indent + 1)
                    }
                }
                put(pad(indent) + ")")
            }
            put("\n")
        }
        if case .timeSamples(let samples)? = spec[FieldKey.timeSamples] {
            line(indent, variabilityText + typeText + " " + name + ".timeSamples = {")
            for sample in samples {
                put(pad(indent + 1) + NumberFormat.format(sample.time) + ": ")
                writeAttributeValue(sample.value, type: type, indent: indent + 1)
                put(",\n")
            }
            line(indent, "}")
        }
        if case .pathListOp(let op)? = spec[FieldKey.connectionPaths] {
            let head = variabilityText + typeText + " " + name + ".connect"
            if op.isExplicit {
                writeTargetStatement(head: head, op: "", items: op.explicitItems, indent: indent, perLine: true)
            } else {
                for (kw, items) in [("delete ", op.deletedItems), ("add ", op.addedItems), ("prepend ", op.prependedItems),
                                    ("append ", op.appendedItems), ("reorder ", op.orderedItems)] where !items.isEmpty {
                    writeTargetStatement(head: head, op: kw, items: items, indent: indent, perLine: true)
                }
            }
        }
    }

    mutating func writeTargetStatement(head: String, op: String, items: [Path], indent: Int, perLine: Bool) {
        put(pad(indent) + op + head + " = ")
        writeTargets(items, indent: indent)
        put("\n")
    }

    mutating func writeTargets(_ items: [Path], indent: Int) {
        if items.isEmpty {
            put("None")
        } else if items.count == 1 {
            put("<\(items[0])>")
        } else {
            put("[\n")
            for p in items { line(indent + 1, "<\(p)>,") }
            put(pad(indent) + "]")
        }
    }

    static let relationshipSkip: Set<String> = FieldKey.childrenFields.union([
        FieldKey.targetPaths, FieldKey.defaultValue, FieldKey.variability, FieldKey.custom, FieldKey.comment,
    ])

    mutating func writeRelationship(_ spec: Spec, name: String, indent: Int) {
        let varying: Bool = {
            if case .variability(.varying)? = spec[FieldKey.variability] { return true }
            return false
        }()
        let varyingText = varying ? "varying " : ""
        let custom = spec[FieldKey.custom]?.boolValue == true
        let keys = spec.fields.keys.filter { !Writer.relationshipSkip.contains($0) }.sorted(by: dictionaryLessThan)
        let comment = spec[FieldKey.comment]?.stringValue
        let hasInfo = !keys.isEmpty || comment != nil
        var listOp: ListOp<Path>?
        if case .pathListOp(let op)? = spec[FieldKey.targetPaths] { listOp = op }
        let explicit = listOp?.isExplicit == true
        let hasListOps = listOp.map { !$0.isExplicit && !$0.isEmpty } ?? false
        if hasInfo || explicit || (!hasListOps && !custom) {
            put(pad(indent) + (custom ? "custom " : "") + varyingText + "rel " + name)
            if let listOp, explicit {
                put(" = ")
                writeTargets(listOp.explicitItems, indent: indent)
            }
            if hasInfo {
                put(" (\n")
                if let comment { line(indent + 1, USDAWriter.quote(comment)) }
                for key in keys {
                    let value = spec.fields[key]!
                    if key == FieldKey.documentation {
                        line(indent + 1, "doc = " + USDAWriter.quote(value.stringValue ?? ""))
                    } else {
                        writeField(key, value, indent: indent + 1)
                    }
                }
                put(pad(indent) + ")")
            }
            put("\n")
        } else if custom {
            line(indent, "custom " + varyingText + "rel " + name)
        }
        if let op = listOp, hasListOps {
            for (kw, items) in [("delete ", op.deletedItems), ("add ", op.addedItems), ("prepend ", op.prependedItems),
                                ("append ", op.appendedItems), ("reorder ", op.orderedItems)] where !items.isEmpty {
                writeTargetStatement(head: varyingText + "rel " + name, op: kw, items: items, indent: indent, perLine: true)
            }
        }
        if case .path(let p)? = spec[FieldKey.defaultValue] {
            line(indent, varyingText + "rel " + name + ".default = <\(p)>")
        }
    }

    // MARK: Fields and values

    /// A `key = value` metadata line (list ops become one line per list).
    mutating func writeField(_ key: String, _ value: Value, indent: Int) {
        switch value {
        case .tokenListOp, .stringListOp, .pathListOp, .referenceListOp, .payloadListOp, .integerListOp:
            writeListOp(value, name: key, indent: indent)
        case .dictionary(let d):
            put(pad(indent) + key + " = ")
            writeDictionary(d, indent: indent)
            put("\n")
        case .scalar(.bool, .bools(let b)) where b.count == 1:
            line(indent, key + " = " + (b[0] ? "true" : "false"))
        default:
            put(pad(indent) + key + " = ")
            writeValue(value, indent: indent)
            put("\n")
        }
    }

    mutating func writeListOp(_ value: Value, name: String, indent: Int) {
        func emit<T>(_ op: ListOp<T>, _ item: (T) -> String, single: Bool, perLine: Bool) {
            func list(_ items: [T]) -> String {
                if items.isEmpty { return "None" }
                if items.count == 1 && single { return item(items[0]) }
                if perLine {
                    return "[\n" + items.map { pad(indent + 1) + item($0) }.joined(separator: ",\n") + "\n" + pad(indent) + "]"
                }
                return "[" + items.map(item).joined(separator: ", ") + "]"
            }
            if op.isExplicit {
                line(indent, name + " = " + list(op.explicitItems))
                return
            }
            for (kw, items) in [("delete", op.deletedItems), ("add", op.addedItems), ("prepend", op.prependedItems),
                                ("append", op.appendedItems), ("reorder", op.orderedItems)] where !items.isEmpty {
                line(indent, kw + " " + name + " = " + list(items))
            }
        }
        switch value {
        case .tokenListOp(let op), .stringListOp(let op):
            emit(op, { USDAWriter.quote($0) }, single: name == "variantSets", perLine: false)
        case .pathListOp(let op):
            emit(op, { "<\($0)>" }, single: true, perLine: false)
        case .referenceListOp(let op):
            emit(op, { referenceText($0, indent: indent + 1) }, single: true, perLine: true)
        case .payloadListOp(let op):
            emit(op, { payloadText($0) }, single: true, perLine: true)
        case .integerListOp(_, let op):
            emit(op, { String($0) }, single: false, perLine: false)
        default:
            break
        }
    }

    func referenceText(_ r: Reference, indent: Int) -> String {
        var text = r.assetPath.isEmpty ? "<\(r.primPath)>" : USDAWriter.assetText(r.assetPath) + (r.primPath.isEmpty ? "" : "<\(r.primPath)>")
        if !r.customData.isEmpty {
            var w = Writer(layer: layer, options: options)
            var parts: [String] = []
            if r.layerOffset.offset != 0 { parts.append("offset = " + NumberFormat.format(r.layerOffset.offset)) }
            if r.layerOffset.scale != 1 { parts.append("scale = " + NumberFormat.format(r.layerOffset.scale)) }
            w.put(" (\n")
            for p in parts { w.line(indent + 1, p) }
            w.put(pad(indent + 1) + "customData = ")
            w.writeDictionary(r.customData, indent: indent + 1)
            w.put("\n" + pad(indent) + ")")
            text += w.out
        } else if !r.layerOffset.isIdentity {
            text += " " + offsetText(r.layerOffset)
        }
        return text
    }

    func payloadText(_ p: Payload) -> String {
        var text = p.assetPath.isEmpty ? "<\(p.primPath)>" : USDAWriter.assetText(p.assetPath) + (p.primPath.isEmpty ? "" : "<\(p.primPath)>")
        if !p.layerOffset.isIdentity { text += " " + offsetText(p.layerOffset) }
        return text
    }

    func nameList(_ names: [String]) -> String {
        "[" + names.map { USDAWriter.quote($0) }.joined(separator: ", ") + "]"
    }

    mutating func writeDictionary(_ dict: [String: Value], indent: Int) {
        put("{\n")
        for key in dict.keys.sorted() {
            let value = dict[key]!
            let keyText = Writer.isIdentifier(key) ? key : USDAWriter.quote(key)
            if case .dictionary(let inner) = value {
                put(pad(indent + 1) + "dictionary " + keyText + " = ")
                writeDictionary(inner, indent: indent + 1)
                put("\n")
                continue
            }
            guard let typeText = Writer.dictionaryTypeName(value) else { continue }
            put(pad(indent + 1) + typeText + " " + keyText + " = ")
            writeValue(value, indent: indent + 1)
            put("\n")
        }
        put(pad(indent) + "}")
    }

    static func isIdentifier(_ s: String) -> Bool {
        guard let first = s.utf8.first, USDAScanner.isIdentStart(first) else { return false }
        return s.utf8.allSatisfy(USDAScanner.isIdentContinue)
    }

    static func dictionaryTypeName(_ value: Value) -> String? {
        switch value {
        case .scalar(let t, _): return t.baseName
        case .array(let t, _): return t.baseName + "[]"
        case .tokenVector: return "token[]"
        case .stringVector: return "string[]"
        case .doubleVector: return "double[]"
        case .valueBlock: return "string"
        default: return nil
        }
    }

    /// Writes an attribute value using its declared type (roles do not
    /// change the text form).
    mutating func writeAttributeValue(_ value: Value, type: TypeName?, indent: Int) {
        writeValue(value, indent: indent)
    }

    mutating func writeValue(_ value: Value, indent: Int) {
        switch value {
        case .valueBlock: put("None")
        case .scalar(let t, let c): put(Writer.elementText(t, c, 0))
        case .array(let t, let c):
            let n = c.count / max(t.componentCount, 1)
            var text = "["
            for i in 0..<n {
                if i > 0 { text += ", " }
                text += Writer.elementText(t, c, i)
            }
            put(text + "]")
        case .dictionary(let d): writeDictionary(d, indent: indent)
        case .tokenVector(let v), .stringVector(let v): put(nameList(v))
        case .doubleVector(let v): put("[" + v.map(NumberFormat.format).joined(separator: ", ") + "]")
        case .pathVector(let v): put("[" + v.map { "<\($0)>" }.joined(separator: ", ") + "]")
        case .path(let p): put("<\(p)>")
        case .specifier(let s): put(s.keyword)
        case .permission(let p): put(p == .private ? "private" : "public")
        case .variability(let v): put(v == .uniform ? "uniform" : "varying")
        case .variantSelectionMap(let m): writeDictionary(m.mapValues { .string($0) }, indent: indent)
        case .tokenListOp(let op), .stringListOp(let op): put(nameList(op.applied(to: [])))
        case .pathListOp(let op): put("[" + op.applied(to: []).map { "<\($0)>" }.joined(separator: ", ") + "]")
        case .referenceListOp(let op): put("[" + op.applied(to: []).map { referenceText($0, indent: indent) }.joined(separator: ", ") + "]")
        case .payloadListOp(let op): put("[" + op.applied(to: []).map(payloadText).joined(separator: ", ") + "]")
        case .integerListOp(_, let op): put("[" + op.applied(to: []).map { String($0) }.joined(separator: ", ") + "]")
        case .layerOffsetVector(let v): put("[" + v.map(offsetText).joined(separator: ", ") + "]")
        case .timeSamples(let samples):
            put("{\n")
            for s in samples {
                put(pad(indent + 1) + NumberFormat.format(s.time) + ": ")
                writeValue(s.value, indent: indent + 1)
                put(",\n")
            }
            put(pad(indent) + "}")
        case .payload(let p): put(payloadText(p))
        }
    }

    static func scalarText(_ t: ValueType, _ c: Components, _ i: Int) -> String {
        switch c {
        case .bools(let a): return a[i] ? "1" : "0"
        case .integers(let a): return t == .uint64 ? String(UInt64(bitPattern: a[i])) : String(a[i])
        case .floats(let a):
            switch t {
            case .half, .vec2h, .vec3h, .vec4h, .quath: return NumberFormat.formatHalf(a[i])
            default: return NumberFormat.format(a[i])
            }
        case .doubles(let a): return NumberFormat.format(a[i])
        case .strings(let a): return t == .asset ? USDAWriter.assetText(a[i]) : USDAWriter.quote(a[i])
        }
    }

    /// Text of element `index` of a scalar or array value.
    static func elementText(_ t: ValueType, _ c: Components, _ index: Int) -> String {
        let width = t.componentCount
        let base = index * width
        if t.isMatrix {
            let n = t.matrixRows
            let rows = (0..<n).map { r in "(" + (0..<n).map { scalarText(t, c, base + r * n + $0) }.joined(separator: ", ") + ")" }
            return "( " + rows.joined(separator: ", ") + " )"
        }
        if width > 1 {
            return "(" + (0..<width).map { scalarText(t, c, base + $0) }.joined(separator: ", ") + ")"
        }
        return scalarText(t, c, base)
    }
}
