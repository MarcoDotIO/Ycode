import Foundation
import USDCore

/// One MaterialX node definition (`<nodedef>`): the interface of a node
/// such as `ND_standard_surface_surfaceshader`.
public struct NodeDefinition: Sendable, Equatable {
    public struct Port: Sendable, Equatable {
        public var name: String
        /// MaterialX type name (`color3`, `float`, `filename`, `surfaceshader`…).
        public var type: String
        /// Default value as MaterialX text (`0.8, 0.8, 0.8`), if any.
        public var value: String?
        public var isUniform: Bool
        public var defaultGeomProp: String?
        public var enumValues: [String]
    }

    public var name: String
    /// The node category (`image`, `standard_surface`, `multiply`).
    public var node: String
    public var nodeGroup: String?
    public var version: String?
    public var inputs: [Port]
    public var outputs: [Port]
    /// The definition this one inherits ports from (`inherit`), resolved on load.
    public var inherits: String?

    public func input(_ name: String) -> Port? { inputs.first { $0.name == name } }
    public func output(_ name: String) -> Port? { outputs.first { $0.name == name } }
}

/// A set of MaterialX node definitions. `standard` holds the definitions of
/// the open MaterialX libraries (stdlib, pbrlib and the bxdf shading models,
/// MaterialX 1.39.5, Apache-2.0) bundled with this package; RealityKit's own
/// nodes are added later from a definitions document of our own.
public struct MaterialXLibrary: Sendable {
    public private(set) var definitions: [String: NodeDefinition] = [:]

    public init(definitions: [NodeDefinition] = []) {
        for d in definitions { self.definitions[d.name] = d }
    }

    public subscript(name: String) -> NodeDefinition? { definitions[name] }

    /// Definitions of a node category (all type variants of `multiply`…).
    public func definitions(ofNode node: String) -> [NodeDefinition] {
        definitions.values.filter { $0.node == node }.sorted { $0.name < $1.name }
    }

    /// Adds every `<nodedef>` of a MaterialX document.
    public mutating func load(mtlx text: String) throws {
        let root = try MXElement.parse(text)
        guard root.name == "materialx" else { throw USDError("not a MaterialX document") }
        for element in root.children where element.name == "nodedef" {
            guard let name = element.attributes["name"], let node = element.attributes["node"] else { continue }
            func port(_ e: MXElement) -> NodeDefinition.Port {
                NodeDefinition.Port(name: e.attributes["name"] ?? "", type: e.attributes["type"] ?? "", value: e.attributes["value"],
                                    isUniform: e.attributes["uniform"] == "true", defaultGeomProp: e.attributes["defaultgeomprop"],
                                    enumValues: e.attributes["enum"].map { $0.split(separator: ",").map { String($0).trimmingCharacters(in: .whitespaces) } } ?? [])
            }
            var outputs = element.children.filter { $0.name == "output" }.map(port)
            if outputs.isEmpty, let type = element.attributes["type"] {
                // Older documents put a single output's type on the nodedef.
                outputs = [NodeDefinition.Port(name: "out", type: type, value: nil, isUniform: false, defaultGeomProp: nil, enumValues: [])]
            }
            definitions[name] = NodeDefinition(name: name, node: node, nodeGroup: element.attributes["nodegroup"],
                                               version: element.attributes["version"],
                                               inputs: element.children.filter { $0.name == "input" }.map(port), outputs: outputs,
                                               inherits: element.attributes["inherit"])
        }
        resolveInheritance()
    }

    /// Gives definitions that `inherit` another the parent's ports, their own
    /// ports overriding by name.
    mutating func resolveInheritance() {
        func resolved(_ name: String, depth: Int) -> NodeDefinition? {
            guard var d = definitions[name] else { return nil }
            guard let parentName = d.inherits, depth < 16, let parent = resolved(parentName, depth: depth + 1) else { return d }
            var inputs = parent.inputs
            for i in d.inputs {
                if let k = inputs.firstIndex(where: { $0.name == i.name }) { inputs[k] = i } else { inputs.append(i) }
            }
            d.inputs = inputs
            if d.outputs.isEmpty || (d.outputs.count == 1 && d.outputs[0].name == "out" && !parent.outputs.isEmpty) {
                d.outputs = parent.outputs
            }
            return d
        }
        for name in definitions.keys where definitions[name]?.inherits != nil {
            definitions[name] = resolved(name, depth: 0)
        }
    }

    static let bundledFiles = ["stdlib_defs", "pbrlib_defs", "standard_surface", "usd_preview_surface", "open_pbr_surface", "gltf_pbr"]

    /// The bundled open MaterialX definitions.
    public static let standard: MaterialXLibrary = {
        var library = MaterialXLibrary()
        for name in bundledFiles {
            guard let url = Bundle.module.url(forResource: "MaterialX/" + name, withExtension: "mtlx")
                ?? Bundle.module.url(forResource: name, withExtension: "mtlx"),
                let data = try? Data(contentsOf: url) else { continue }
            try? library.load(mtlx: String(decoding: data, as: UTF8.self))
        }
        return library
    }()

    /// The USD attribute type of a MaterialX type (as UsdShade stores
    /// MaterialX inputs and outputs).
    public static func usdType(forMaterialXType type: String) -> TypeName? {
        switch type {
        case "boolean": return TypeName("bool")
        case "integer": return TypeName("int")
        case "float": return TypeName("float")
        case "color3": return TypeName("color3f")
        case "color4": return TypeName("color4f")
        case "vector2": return TypeName("float2")
        case "vector3": return TypeName("float3")
        case "vector4": return TypeName("float4")
        case "matrix33": return TypeName("matrix3d")
        case "matrix44": return TypeName("matrix4d")
        case "string", "geomname": return TypeName("string")
        case "filename": return TypeName("asset")
        case "integerarray": return TypeName("int[]")
        case "floatarray": return TypeName("float[]")
        case "color3array": return TypeName("color3f[]")
        case "color4array": return TypeName("color4f[]")
        case "vector2array": return TypeName("float2[]")
        case "vector3array": return TypeName("float3[]")
        case "vector4array": return TypeName("float4[]")
        case "stringarray": return TypeName("string[]")
        case "surfaceshader", "displacementshader", "volumeshader", "lightshader", "material", "BSDF", "EDF", "VDF":
            return TypeName("token")
        default: return nil
        }
    }

    /// Parses a MaterialX value string into a USD value of the mapped type.
    public static func usdValue(_ text: String, materialXType: String) -> Value? {
        guard let type = usdType(forMaterialXType: materialXType) else { return nil }
        let vt = type.valueType
        if type.isArray {
            let parts = text.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
            if vt.storage == .string { return .array(vt, .strings(parts)) }
            return .array(vt, .from(doubles: parts.compactMap(Double.init), as: vt))
        }
        switch vt.storage {
        case .string: return .scalar(vt, .strings([text]))
        case .bool: return .bool(text == "true")
        default:
            let numbers = text.split(separator: ",").compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
            guard numbers.count == vt.componentCount else { return nil }
            return .numeric(vt, numbers)
        }
    }
}

/// A minimal XML reader for MaterialX documents: elements, attributes,
/// comments, the XML declaration and the five predefined entities.
struct MXElement {
    var name: String
    var attributes: [String: String] = [:]
    var children: [MXElement] = []

    static func parse(_ text: String) throws -> MXElement {
        var p = MiniXMLParser(Array(text.utf8))
        return try p.document()
    }
}

private struct MiniXMLParser {
    let b: [UInt8]
    var i = 0

    init(_ b: [UInt8]) { self.b = b }

    mutating func skipSpace() {
        while i < b.count, b[i] == 0x20 || b[i] == 0x09 || b[i] == 0x0A || b[i] == 0x0D { i += 1 }
    }

    func starts(_ s: String) -> Bool {
        let u = Array(s.utf8)
        return i + u.count <= b.count && Array(b[i..<(i + u.count)]) == u
    }

    mutating func skipPast(_ s: String) throws {
        let u = Array(s.utf8)
        while i + u.count <= b.count {
            if Array(b[i..<(i + u.count)]) == u {
                i += u.count
                return
            }
            i += 1
        }
        throw USDError("xml: missing \(s)")
    }

    /// Skips text, comments and declarations until the next element tag.
    mutating func skipMisc() throws {
        while i < b.count {
            if starts("<!--") {
                try skipPast("-->")
            } else if starts("<?") {
                try skipPast("?>")
            } else if starts("<!") {
                try skipPast(">")
            } else if b[i] == 0x3C {
                return
            } else {
                i += 1
            }
        }
    }

    mutating func name() -> String {
        let start = i
        while i < b.count, !(b[i] == 0x20 || b[i] == 0x09 || b[i] == 0x0A || b[i] == 0x0D || b[i] == 0x3E || b[i] == 0x2F || b[i] == 0x3D) {
            i += 1
        }
        return String(decoding: b[start..<i], as: UTF8.self)
    }

    static func unescape(_ s: String) -> String {
        guard s.contains("&") else { return s }
        return s.replacingOccurrences(of: "&lt;", with: "<").replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"").replacingOccurrences(of: "&apos;", with: "'")
            .replacingOccurrences(of: "&amp;", with: "&")
    }

    mutating func document() throws -> MXElement {
        try skipMisc()
        guard i < b.count else { throw USDError("xml: no root element") }
        return try element()
    }

    mutating func element() throws -> MXElement {
        guard i < b.count, b[i] == 0x3C else { throw USDError("xml: expected '<'") }
        i += 1
        var e = MXElement(name: name())
        while true {
            skipSpace()
            guard i < b.count else { throw USDError("xml: unterminated tag <\(e.name)>") }
            if b[i] == 0x2F, i + 1 < b.count, b[i + 1] == 0x3E {
                i += 2
                return e
            }
            if b[i] == 0x3E {
                i += 1
                break
            }
            let key = name()
            skipSpace()
            guard i < b.count, b[i] == 0x3D else { throw USDError("xml: expected '=' after \(key)") }
            i += 1
            skipSpace()
            guard i < b.count, b[i] == 0x22 || b[i] == 0x27 else { throw USDError("xml: expected a quoted value") }
            let quote = b[i]
            i += 1
            let start = i
            while i < b.count, b[i] != quote { i += 1 }
            guard i < b.count else { throw USDError("xml: unterminated attribute") }
            e.attributes[key] = MiniXMLParser.unescape(String(decoding: b[start..<i], as: UTF8.self))
            i += 1
        }
        while true {
            try skipMisc()
            guard i < b.count else { throw USDError("xml: unterminated element <\(e.name)>") }
            if starts("</") {
                try skipPast(">")
                return e
            }
            e.children.append(try element())
        }
    }
}
