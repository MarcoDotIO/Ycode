/// Reads the USDA text format into a `Layer`.
///
/// The grammar follows OpenUSD's documented text format: a `#usda 1.0`
/// header, optional layer metadata in parentheses, then prim specs with
/// metadata, properties, children and variant sets. Splines and array edits
/// (USDA 1.1/1.2 additions) are reported as unsupported.
public enum USDAReader {
    public static func read(_ text: String, identifier: String = "anonymous.usda") throws -> Layer {
        var parser = USDAParser(text: text, identifier: identifier)
        return try parser.parseLayer()
    }

    /// Parses a metadata value in USDA syntax (`"component"`, `true`, `0.01`,
    /// `{ string a = "b" }`), typed by the field's known type.
    public static func parseMetadataValue(_ text: String, field: String) throws -> Value {
        var parser = USDAParser(text: text, identifier: "value")
        let value = try parser.parseMetadataValue(field: field)
        parser.s.skip()
        guard parser.s.atEnd else { throw parser.s.error("unexpected text after the value") }
        return value
    }

    /// Parses one value in USDA syntax for a declared type
    /// (`(1, 2, 3)` as `float3`, `[1, 2]` as `int[]`, `None`).
    public static func parseValue(_ text: String, type: TypeName) throws -> Value {
        var parser = USDAParser(text: text, identifier: "value")
        if parser.s.consumeKeyword("None") { return .valueBlock }
        let value = try parser.parseTypedValue(type)
        parser.s.skip()
        guard parser.s.atEnd else { throw parser.s.error("unexpected text after the value") }
        return value
    }
}

/// Untyped metadata values, typed once the field is known.
indirect enum SyntaxValue {
    case number(String)
    case identifier(String)
    case string(String)
    case asset(String)
    case path(Path)
    case tuple([SyntaxValue])
    case list([SyntaxValue])
    case dictionary([String: Value])
    case none
}

struct USDAParser {
    var s: USDAScanner
    var layer: Layer

    init(text: String, identifier: String) {
        s = USDAScanner(text)
        layer = Layer(identifier: identifier)
    }

    static let listOpKeywords: Set<String> = ["add", "delete", "prepend", "append", "reorder"]

    // MARK: Layer

    mutating func parseLayer() throws -> Layer {
        // Header: '#usda <version>' on the first line.
        guard s.peek() == 0x23 else { throw s.error("missing '#usda' header") }
        let start = s.pos
        s.skipToEndOfLine()
        let header = String(decoding: s.bytes[start..<s.pos], as: UTF8.self)
        guard header.hasPrefix("#usda ") else { throw s.error("not a usda file (header \(header))") }
        if s.consume("(") { try parseLayerMetadata() }
        while true {
            s.skip()
            if s.atEnd { break }
            if s.consumeKeyword("reorder") {
                try s.expectKeyword("rootPrims")
                try s.expect("=")
                layer.setField(FieldKey.primOrder, .tokenVector(try parseNameList()), at: .root)
                continue
            }
            try parsePrim(parent: .root)
        }
        return layer
    }

    mutating func parseLayerMetadata() throws {
        while !s.consume(")") {
            if s.atEnd { throw s.error("unterminated layer metadata") }
            if s.atString() {
                layer[metadata: FieldKey.comment] = .string(try s.quotedString())
                continue
            }
            guard let key = s.namespacedName() else { throw s.error("expected layer metadata") }
            if key == "doc" {
                try s.expect("=")
                layer.documentation = try s.quotedString()
            } else if key == "subLayers" {
                try s.expect("=")
                try parseSubLayers()
            } else if USDAParser.listOpKeywords.contains(key), !nextIsAssignment() {
                let field = try s.expectName("metadata name")
                try s.expect("=")
                try applyListOpMetadata(op: key, field: field, at: .root)
            } else {
                try s.expect("=")
                layer[metadata: key] = try parseMetadataValue(field: key)
            }
        }
    }

    /// True if the next non-trivia character is '='.
    mutating func nextIsAssignment() -> Bool {
        s.next() == 0x3D
    }

    mutating func parseSubLayers() throws {
        try s.expect("[")
        var paths: [String] = []
        var offsets: [LayerOffset] = []
        while !s.consume("]") {
            paths.append(try s.assetRef())
            offsets.append(s.consume("(") ? try parseOffsetParameters().0 : LayerOffset())
            _ = s.consume(",")
        }
        layer.subLayers = paths
        layer.subLayerOffsets = offsets
    }

    /// Parses `offset = n; scale = n; customData = {…}` up to ')'.
    mutating func parseOffsetParameters() throws -> (LayerOffset, [String: Value]) {
        var offset = LayerOffset()
        var customData: [String: Value] = [:]
        while !s.consume(")") {
            let key = try s.expectName("offset, scale or customData")
            try s.expect("=")
            switch key {
            case "offset": offset.offset = try s.expectDouble()
            case "scale": offset.scale = try s.expectDouble()
            case "customData": customData = try parseDictionary()
            default: throw s.error("unexpected '\(key)' in layer offset")
            }
        }
        return (offset, customData)
    }

    // MARK: Prims

    mutating func parsePrim(parent: Path) throws {
        guard let keyword = s.identifier(), let specifier = USDAParser.specifier(keyword) else {
            throw s.error("expected 'def', 'over' or 'class'")
        }
        var typeName: String?
        if !s.atString() {
            var name = try s.expectName("prim type name")
            while s.consume(".") { name += "." + (try s.expectName("prim type name")) }
            typeName = name
        }
        let name = try s.quotedString()
        let path = parent.appendingChild(name)
        var spec = Spec(type: .prim)
        spec[FieldKey.specifier] = .specifier(specifier)
        if let typeName { spec[FieldKey.typeName] = .token(typeName) }
        if layer.hasSpec(at: path) { throw s.error("duplicate prim \(path)") }
        layer.insertSpec(spec, at: path)
        if s.consume("(") { try parsePrimMetadata(at: path) }
        try s.expect("{")
        try parsePrimContents(at: path)
        try s.expect("}")
    }

    static func specifier(_ word: String) -> Specifier? {
        switch word {
        case "def": return .def
        case "over": return .over
        case "class": return .class
        default: return nil
        }
    }

    mutating func parsePrimMetadata(at path: Path) throws {
        while !s.consume(")") {
            if s.atEnd { throw s.error("unterminated prim metadata") }
            if s.atString() {
                layer.setField(FieldKey.comment, .string(try s.quotedString()), at: path)
                continue
            }
            let key = try s.expectName("prim metadata")
            if USDAParser.listOpKeywords.contains(key), !nextIsAssignment() {
                let field = try s.expectName("metadata name")
                try s.expect("=")
                try applyListOpMetadata(op: key, field: field, at: path)
                continue
            }
            try s.expect("=")
            switch key {
            case "doc": layer.setField(FieldKey.documentation, .string(try s.quotedString()), at: path)
            case "references", "payload", "inherits", "specializes", "variantSets":
                try applyListOpMetadata(op: "", field: key, at: path)
            case "variants":
                let dict = try parseDictionary()
                var selection: [String: String] = [:]
                for (k, v) in dict { selection[k] = v.stringValue ?? "" }
                layer.setField(FieldKey.variantSelection, .variantSelectionMap(selection), at: path)
            case "permission":
                let word = try s.expectName("permission")
                layer.setField(FieldKey.permission, .permission(word == "private" ? .private : .public), at: path)
            case "symmetryFunction":
                layer.setField("symmetryFunction", .token(s.namespacedName() ?? ""), at: path)
            case "relocates":
                throw s.error("relocates are not supported")
            default:
                layer.setField(key, try parseMetadataValue(field: key), at: path)
            }
        }
    }

    /// `op` is "" for an explicit list, else add/delete/prepend/append/reorder.
    mutating func applyListOpMetadata(op: String, field name: String, at path: Path) throws {
        switch name {
        case "references":
            let items = try parseReferenceList()
            var listOp: ListOp<Reference> = {
                if case .referenceListOp(let l)? = layer.field(FieldKey.references, at: path) { return l }
                return ListOp()
            }()
            USDAParser.assign(&listOp, op: op, items: items)
            layer.setField(FieldKey.references, .referenceListOp(listOp), at: path)
        case "payload":
            let items = try parsePayloadList()
            var listOp: ListOp<Payload> = {
                if case .payloadListOp(let l)? = layer.field(FieldKey.payload, at: path) { return l }
                return ListOp()
            }()
            USDAParser.assign(&listOp, op: op, items: items)
            layer.setField(FieldKey.payload, .payloadListOp(listOp), at: path)
        case "inherits", "specializes":
            let key = name == "inherits" ? FieldKey.inheritPaths : FieldKey.specializes
            let items = try parsePathList().map { $0.makingAbsolute(anchor: path.strippingVariantSelections) }
            var listOp: ListOp<Path> = {
                if case .pathListOp(let l)? = layer.field(key, at: path) { return l }
                return ListOp()
            }()
            USDAParser.assign(&listOp, op: op, items: items)
            layer.setField(key, .pathListOp(listOp), at: path)
        case "variantSets":
            let items = try parseNameListOrNone()
            var listOp: ListOp<String> = {
                if case .stringListOp(let l)? = layer.field(FieldKey.variantSetNames, at: path) { return l }
                return ListOp()
            }()
            USDAParser.assign(&listOp, op: op, items: items)
            layer.setField(FieldKey.variantSetNames, .stringListOp(listOp), at: path)
        default:
            // A generic list-op metadata field (apiSchemas, clipSets…).
            let raw = try parseSyntaxValue()
            let strings: [String]
            switch raw {
            case .none: strings = []
            case .list(let items): strings = items.compactMap { if case .string(let v) = $0 { return v }; return nil }
            case .string(let v): strings = [v]
            default: throw s.error("expected a list for \(name)")
            }
            let isString = MetadataType.known[name] == .stringListOp
            var listOp: ListOp<String> = {
                switch layer.field(name, at: path) {
                case .tokenListOp(let l)?, .stringListOp(let l)?: return l
                default: return ListOp()
                }
            }()
            USDAParser.assign(&listOp, op: op, items: strings)
            layer.setField(name, isString ? .stringListOp(listOp) : .tokenListOp(listOp), at: path)
        }
    }

    static func assign<T>(_ listOp: inout ListOp<T>, op: String, items: [T]) {
        switch op {
        case "": listOp = ListOp(isExplicit: true, explicitItems: items)
        case "add": listOp.addedItems = items
        case "delete": listOp.deletedItems = items
        case "prepend": listOp.prependedItems = items
        case "append": listOp.appendedItems = items
        case "reorder": listOp.orderedItems = items
        default: break
        }
    }

    mutating func parseReferenceList() throws -> [Reference] {
        if s.consumeKeyword("None") { return [] }
        if s.consume("[") {
            var out: [Reference] = []
            while !s.consume("]") {
                out.append(try parseReferenceItem())
                _ = s.consume(",")
            }
            return out
        }
        return [try parseReferenceItem()]
    }

    mutating func parseReferenceItem() throws -> Reference {
        var ref = Reference()
        if s.atPathRef() {
            ref.primPath = try s.pathRef()
        } else {
            ref.assetPath = try s.assetRef()
            if s.atPathRef() { ref.primPath = try s.pathRef() }
        }
        if s.consume("(") { (ref.layerOffset, ref.customData) = try parseOffsetParameters() }
        return ref
    }

    mutating func parsePayloadList() throws -> [Payload] {
        if s.consumeKeyword("None") { return [] }
        if s.consume("[") {
            var out: [Payload] = []
            while !s.consume("]") {
                out.append(try parsePayloadItem())
                _ = s.consume(",")
            }
            return out
        }
        return [try parsePayloadItem()]
    }

    mutating func parsePayloadItem() throws -> Payload {
        var payload = Payload()
        if s.atPathRef() {
            payload.primPath = try s.pathRef()
        } else {
            payload.assetPath = try s.assetRef()
            if s.atPathRef() { payload.primPath = try s.pathRef() }
        }
        if s.consume("(") { payload.layerOffset = try parseOffsetParameters().0 }
        return payload
    }

    mutating func parsePathList() throws -> [Path] {
        if s.consumeKeyword("None") { return [] }
        if s.consume("[") {
            var out: [Path] = []
            while !s.consume("]") {
                out.append(try s.pathRef())
                _ = s.consume(",")
            }
            return out
        }
        return [try s.pathRef()]
    }

    mutating func parseNameList() throws -> [String] {
        if s.consume("[") {
            var out: [String] = []
            while !s.consume("]") {
                out.append(try s.quotedString())
                _ = s.consume(",")
            }
            return out
        }
        return [try s.quotedString()]
    }

    mutating func parseNameListOrNone() throws -> [String] {
        if s.consumeKeyword("None") { return [] }
        return try parseNameList()
    }

    // MARK: Prim contents

    mutating func parsePrimContents(at path: Path) throws {
        while true {
            guard let b = s.next() else { throw s.error("unterminated prim") }
            if b == 0x7D { return } // '}'
            let saved = s.pos
            guard let word = s.identifier() else { throw s.error("expected a property, prim or variantSet") }
            switch word {
            case "def", "over", "class":
                s.pos = saved
                try parsePrim(parent: path)
            case "variantSet":
                try parseVariantSet(on: path)
            case "reorder" where ["nameChildren", "properties"].contains(s.peekIdentifier() ?? ""):
                let which = s.identifier()!
                try s.expect("=")
                let names = try parseNameList()
                layer.setField(which == "nameChildren" ? FieldKey.primOrder : FieldKey.propertyOrder, .tokenVector(names), at: path)
            default:
                s.pos = saved
                try parseProperty(owner: path)
            }
        }
    }

    mutating func parseVariantSet(on prim: Path) throws {
        let setName = try s.quotedString()
        try s.expect("=")
        try s.expect("{")
        let setPath = prim.appendingVariantSelection(set: setName, variant: "")
        if !layer.hasSpec(at: setPath) { layer.insertSpec(Spec(type: .variantSet), at: setPath) }
        while !s.consume("}") {
            if s.atEnd { throw s.error("unterminated variantSet") }
            let variant = try s.quotedString()
            let path = prim.appendingVariantSelection(set: setName, variant: variant)
            if !layer.hasSpec(at: path) { layer.insertSpec(Spec(type: .variant), at: path) }
            if s.consume("(") { try parsePrimMetadata(at: path) }
            try s.expect("{")
            try parsePrimContents(at: path)
            try s.expect("}")
        }
    }

    // MARK: Properties

    mutating func parseProperty(owner: Path) throws {
        var listOp = ""
        if let w = s.peekIdentifier(), USDAParser.listOpKeywords.contains(w) {
            _ = s.identifier()
            listOp = w
        }
        var custom = false
        var variability: Variability = .varying
        var isRelationship = false
        var varying = false
        modifiers: while true {
            let saved = s.pos
            guard let word = s.identifier() else { break }
            switch word {
            case "custom": custom = true
            case "uniform", "config": variability = .uniform
            case "varying": varying = true
            case "rel":
                isRelationship = true
                break modifiers
            default:
                s.pos = saved
                break modifiers
            }
        }
        if isRelationship {
            try parseRelationship(owner: owner, custom: custom, varying: varying, listOp: listOp)
            return
        }
        // Attribute: type name, optional [], property name.
        var typeText = try s.expectName("attribute type")
        if s.consume("[") {
            try s.expect("]")
            typeText += "[]"
        }
        guard let typeName = TypeName(typeText) else { throw s.error("unknown attribute type '\(typeText)'") }
        let name = try s.expectName("attribute name")
        let path = owner.appendingProperty(name)
        var spec = layer.spec(at: path) ?? Spec(type: .attribute)
        if let existing = spec[FieldKey.typeName]?.stringValue, existing != typeText {
            throw s.error("attribute '\(name)' already has type '\(existing)', cannot change to '\(typeText)'")
        }
        spec[FieldKey.typeName] = .token(typeText)
        // Required fields of every attribute spec (as the binary format stores them).
        if spec[FieldKey.variability] == nil || variability == .uniform { spec[FieldKey.variability] = .variability(variability) }
        if spec[FieldKey.custom] == nil || custom { spec[FieldKey.custom] = .bool(custom) }
        if layer.hasSpec(at: path) { layer.setSpec(spec, at: path) } else { layer.insertSpec(spec, at: path) }

        if s.consume(".") {
            let suffix = try s.expectName("timeSamples, connect or spline")
            try s.expect("=")
            switch suffix {
            case "timeSamples":
                layer.setField(FieldKey.timeSamples, .timeSamples(try parseTimeSamples(type: typeName)), at: path)
            case "connect":
                let targets = try parsePathList().map { $0.makingAbsolute(anchor: owner.strippingVariantSelections) }
                var op: ListOp<Path> = {
                    if case .pathListOp(let l)? = layer.field(FieldKey.connectionPaths, at: path) { return l }
                    return ListOp()
                }()
                USDAParser.assign(&op, op: listOp, items: targets)
                layer.setField(FieldKey.connectionPaths, .pathListOp(op), at: path)
            case "spline":
                throw s.error("attribute splines are not supported")
            default:
                throw s.error("unexpected '.\(suffix)'")
            }
            return
        }
        guard listOp.isEmpty else { throw s.error("list operation on an attribute value") }
        if s.consume("=") {
            if s.consumeKeyword("None") {
                layer.setField(FieldKey.defaultValue, .valueBlock, at: path)
            } else if s.consumeKeyword("AnimationBlock") || s.peekIdentifier() == "edit" {
                throw s.error("animation blocks and array edits are not supported")
            } else {
                layer.setField(FieldKey.defaultValue, try parseTypedValue(typeName), at: path)
            }
        }
        if s.consume("(") { try parsePropertyMetadata(at: path) }
    }

    mutating func parseRelationship(owner: Path, custom: Bool, varying: Bool, listOp: String) throws {
        let name = try s.expectName("relationship name")
        let path = owner.appendingProperty(name)
        var spec = layer.spec(at: path) ?? Spec(type: .relationship)
        spec.type = .relationship
        if custom { spec[FieldKey.custom] = .bool(true) }
        if spec[FieldKey.variability] == nil || varying { spec[FieldKey.variability] = .variability(varying ? .varying : .uniform) }
        if layer.hasSpec(at: path) { layer.setSpec(spec, at: path) } else { layer.insertSpec(spec, at: path) }
        if s.consume(".") {
            try s.expectKeyword("default")
            try s.expect("=")
            layer.setField(FieldKey.defaultValue, .path(try s.pathRef()), at: path)
            return
        }
        if s.next() == 0x5B { // '[' target spec (legacy syntax)
            throw s.error("relationship target specs are not supported")
        }
        if s.consume("=") {
            let targets = try parsePathList().map { $0.makingAbsolute(anchor: owner.strippingVariantSelections) }
            var op: ListOp<Path> = {
                if case .pathListOp(let l)? = layer.field(FieldKey.targetPaths, at: path) { return l }
                return ListOp()
            }()
            USDAParser.assign(&op, op: listOp, items: targets)
            layer.setField(FieldKey.targetPaths, .pathListOp(op), at: path)
        }
        if listOp.isEmpty, s.consume("(") { try parsePropertyMetadata(at: path) }
    }

    mutating func parsePropertyMetadata(at path: Path) throws {
        while !s.consume(")") {
            if s.atEnd { throw s.error("unterminated property metadata") }
            if s.atString() {
                layer.setField(FieldKey.comment, .string(try s.quotedString()), at: path)
                continue
            }
            let key = try s.expectName("property metadata")
            if USDAParser.listOpKeywords.contains(key), !nextIsAssignment() {
                let field = try s.expectName("metadata name")
                try s.expect("=")
                try applyListOpMetadata(op: key, field: field, at: path)
                continue
            }
            try s.expect("=")
            switch key {
            case "doc": layer.setField(FieldKey.documentation, .string(try s.quotedString()), at: path)
            case "permission":
                let word = try s.expectName("permission")
                layer.setField(FieldKey.permission, .permission(word == "private" ? .private : .public), at: path)
            case "displayUnit", "symmetryFunction":
                layer.setField(key, .token(s.namespacedName() ?? ""), at: path)
            default:
                layer.setField(key, try parseMetadataValue(field: key), at: path)
            }
        }
    }

    // MARK: Typed values

    mutating func parseTimeSamples(type: TypeName) throws -> [TimeSample] {
        try s.expect("{")
        var samples: [TimeSample] = []
        while !s.consume("}") {
            let time = try s.expectDouble()
            try s.expect(":")
            let value: Value = s.consumeKeyword("None") ? .valueBlock : try parseTypedValue(type)
            samples.append(TimeSample(time: time, value: value))
            _ = s.consume(",")
        }
        samples.sort { $0.time < $1.time }
        return samples
    }

    /// Parses a value of a declared type directly into component storage.
    mutating func parseTypedValue(_ type: TypeName) throws -> Value {
        let vt = type.valueType
        if type.isArray {
            try s.expect("[")
            var acc = ComponentAccumulator(type: vt)
            while !s.consume("]") {
                try parseElement(vt, into: &acc)
                _ = s.consume(",")
            }
            return .array(vt, acc.components)
        }
        var acc = ComponentAccumulator(type: vt)
        try parseElement(vt, into: &acc)
        return .scalar(vt, acc.components)
    }

    mutating func parseElement(_ vt: ValueType, into acc: inout ComponentAccumulator) throws {
        switch vt.storage {
        case .string:
            if vt == .asset {
                acc.strings.append(try s.assetRef())
            } else {
                acc.strings.append(try s.quotedString())
            }
        case .bool:
            if s.consumeKeyword("true") {
                acc.bools.append(true)
            } else if s.consumeKeyword("false") {
                acc.bools.append(false)
            } else {
                acc.bools.append(try s.expectDouble() != 0)
            }
        default:
            if vt.isMatrix {
                try s.expect("(")
                for row in 0..<vt.matrixRows {
                    if row > 0 { try s.expect(",") }
                    try s.expect("(")
                    for col in 0..<vt.matrixRows {
                        if col > 0 { try s.expect(",") }
                        try acc.appendNumber(try numberText())
                    }
                    try s.expect(")")
                }
                _ = s.consume(",")
                try s.expect(")")
            } else if vt.componentCount > 1 {
                try s.expect("(")
                for i in 0..<vt.componentCount {
                    if i > 0 { try s.expect(",") }
                    try acc.appendNumber(try numberText())
                }
                _ = s.consume(",")
                try s.expect(")")
            } else {
                try acc.appendNumber(try numberText())
            }
        }
    }

    mutating func numberText() throws -> String {
        guard let t = s.numberText() else { throw s.error("expected a number") }
        return t
    }

    // MARK: Untyped values (metadata)

    mutating func parseSyntaxValue() throws -> SyntaxValue {
        guard let b = s.next() else { throw s.error("expected a value") }
        switch b {
        case 0x22, 0x27: return .string(try s.quotedString())
        case 0x40: return .asset(try s.assetRef())
        case 0x3C: return .path(try s.pathRef())
        case 0x7B: return .dictionary(try parseDictionary())
        case 0x28:
            s.pos += 1
            var items: [SyntaxValue] = []
            while !s.consume(")") {
                items.append(try parseSyntaxValue())
                _ = s.consume(",")
            }
            return .tuple(items)
        case 0x5B:
            s.pos += 1
            var items: [SyntaxValue] = []
            while !s.consume("]") {
                items.append(try parseSyntaxValue())
                _ = s.consume(",")
            }
            return .list(items)
        default:
            if let n = s.numberText() { return .number(n) }
            if let w = s.namespacedName() { return w == "None" ? .none : .identifier(w) }
            throw s.error("expected a value")
        }
    }

    /// `{ type name = value … }` with nested `dictionary name = { … }`.
    mutating func parseDictionary() throws -> [String: Value] {
        try s.expect("{")
        var dict: [String: Value] = [:]
        while !s.consume("}") {
            if s.atEnd { throw s.error("unterminated dictionary") }
            var typeText = try s.expectName("dictionary value type")
            if typeText == "dictionary" {
                let key = s.atString() ? try s.quotedString() : try s.expectName("dictionary key")
                try s.expect("=")
                dict[key] = .dictionary(try parseDictionary())
                continue
            }
            if s.consume("[") {
                try s.expect("]")
                typeText += "[]"
            }
            let key = s.atString() ? try s.quotedString() : try s.expectName("dictionary key")
            try s.expect("=")
            if s.consumeKeyword("None") {
                dict[key] = .valueBlock
                continue
            }
            if let type = TypeName(typeText) {
                dict[key] = try parseTypedValue(type)
            } else {
                throw s.error("unknown dictionary value type '\(typeText)'")
            }
        }
        return dict
    }

    mutating func parseMetadataValue(field: String) throws -> Value {
        let raw = try parseSyntaxValue()
        if case .none = raw { return .valueBlock }
        return try USDAParser.convert(raw, as: MetadataType.known[field], scanner: s)
    }

    static func convert(_ raw: SyntaxValue, as type: MetadataType?, scanner s: USDAScanner) throws -> Value {
        func strings(_ v: SyntaxValue) throws -> [String] {
            switch v {
            case .list(let items):
                return try items.map {
                    if case .string(let x) = $0 { return x }
                    throw s.error("expected a list of strings")
                }
            case .string(let x): return [x]
            default: throw s.error("expected a list of strings")
            }
        }
        switch type {
        case .token?:
            if case .string(let v) = raw { return .token(v) }
            if case .identifier(let v) = raw { return .token(v) }
        case .string?:
            if case .string(let v) = raw { return .string(v) }
        case .bool?:
            if case .identifier(let v) = raw { return .bool(v == "true" || v == "yes") }
            if case .number(let v) = raw { return .bool(USDAScanner.double(v) != 0) }
        case .double?:
            if case .number(let v) = raw { return .double(USDAScanner.double(v)) }
        case .int?:
            if case .number(let v) = raw { return .int(Int(USDAScanner.double(v))) }
        case .dictionary?:
            if case .dictionary(let d) = raw { return .dictionary(d) }
        case .tokenArray?:
            return .tokens(try strings(raw))
        case .stringArray?:
            return .strings(try strings(raw))
        case .asset?:
            if case .asset(let v) = raw { return .asset(v) }
        case .tokenListOp?:
            return .tokenListOp(.explicit(try strings(raw)))
        case .stringListOp?:
            return .stringListOp(.explicit(try strings(raw)))
        case .tokenVector?:
            return .tokenVector(try strings(raw))
        case nil:
            return try infer(raw, scanner: s)
        }
        throw s.error("unexpected value type for metadata")
    }

    /// Unregistered metadata: the value type follows the literal.
    static func infer(_ raw: SyntaxValue, scanner s: USDAScanner) throws -> Value {
        switch raw {
        case .string(let v): return .string(v)
        case .identifier(let v):
            if v == "true" || v == "false" { return .bool(v == "true") }
            return .token(v)
        case .number(let v):
            if let i = Int64(v), i >= Int64(Int32.min), i <= Int64(Int32.max) { return .int(Int(i)) }
            return .double(USDAScanner.double(v))
        case .asset(let v): return .asset(v)
        case .path(let p): return .path(p)
        case .dictionary(let d): return .dictionary(d)
        case .none: return .valueBlock
        case .tuple(let items):
            let numbers = try items.map { item -> Double in
                if case .number(let n) = item { return USDAScanner.double(n) }
                throw s.error("unsupported tuple metadata")
            }
            let type: ValueType = numbers.count == 2 ? .vec2d : numbers.count == 3 ? .vec3d : .vec4d
            return .scalar(type, .doubles(numbers))
        case .list(let items):
            if items.allSatisfy({ if case .string = $0 { return true }; return false }) {
                return .strings(items.compactMap { if case .string(let v) = $0 { return v }; return nil })
            }
            if items.allSatisfy({ if case .path = $0 { return true }; return false }) {
                return .pathVector(items.compactMap { if case .path(let v) = $0 { return v }; return nil })
            }
            let numbers = try items.map { item -> Double in
                if case .number(let n) = item { return USDAScanner.double(n) }
                throw s.error("unsupported list metadata")
            }
            return .doubles(numbers)
        }
    }
}

/// Collects parsed components for one value type.
struct ComponentAccumulator {
    let type: ValueType
    var bools: [Bool] = []
    var integers: [Int64] = []
    var floats: [Float] = []
    var doubles: [Double] = []
    var strings: [String] = []

    init(type: ValueType) { self.type = type }

    mutating func appendNumber(_ text: String) throws {
        switch type.storage {
        case .integer:
            if let i = Int64(text) {
                integers.append(i)
            } else if let u = UInt64(text) {
                integers.append(Int64(bitPattern: u))
            } else {
                integers.append(Int64(USDAScanner.double(text)))
            }
        case .float:
            let f = Float(text) ?? Float(USDAScanner.double(text))
            floats.append(type == .half || type == .vec2h || type == .vec3h || type == .vec4h || type == .quath ? Half.round(f) : f)
        case .double:
            doubles.append(Double(text) ?? USDAScanner.double(text))
        case .bool:
            bools.append(USDAScanner.double(text) != 0)
        case .string:
            strings.append(text)
        }
    }

    var components: Components {
        switch type.storage {
        case .bool: return .bools(bools)
        case .integer: return .integers(integers)
        case .float: return .floats(floats)
        case .double: return .doubles(doubles)
        case .string: return .strings(strings)
        }
    }
}
