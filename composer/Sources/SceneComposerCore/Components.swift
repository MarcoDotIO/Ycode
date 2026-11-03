import Foundation
import USDCore

/// The RealityKit component catalogue (`Resources/components.json`): for
/// each `info:id`, the field names, USD types, editor defaults and whether a
/// run verified them (`specs/tools/scene-composer/scene-usd.md` §4.3, §6.3).
public struct ComponentCatalogue: Decodable, Sendable {
    public struct Field: Decodable, Sendable, Equatable {
        public var name: String
        public var type: String
        /// USDA value text written for a new component when listed in `alwaysWrite`.
        public var `default`: String?
        public var allowed: [String]?
        public var verified: Bool
    }

    public struct Struct: Decodable, Sendable {
        public var name: String
        public var fields: [Field]?
        public var structs: [Struct]?
    }

    public struct Relationship: Decodable, Sendable {
        public var name: String
        public var verified: Bool
    }

    public struct Kind: Decodable, Sendable {
        public var id: String
        public var primName: String
        public var runtime: String
        public var alwaysWrite: [String]?
        public var fields: [Field]?
        public var structs: [Struct]?
        public var relationships: [Relationship]?
        /// Fields are specified elsewhere (particles, audio, timelines);
        /// the validator does not judge them yet.
        public var openFields: Bool?
        /// The spec file that will define those fields.
        public var fieldsSpec: String?

        /// Every field by dotted key (`Shape.pose.position`).
        public var fieldsByKey: [String: Field] {
            var out: [String: Field] = [:]
            for f in fields ?? [] { out[f.name] = f }
            func visit(_ s: Struct, _ prefix: String) {
                for f in s.fields ?? [] { out[prefix + s.name + "." + f.name] = f }
                for inner in s.structs ?? [] { visit(inner, prefix + s.name + ".") }
            }
            for s in structs ?? [] { visit(s, "") }
            return out
        }

        public var structKeys: Set<String> {
            var out: Set<String> = []
            func visit(_ s: Struct, _ prefix: String) {
                out.insert(prefix + s.name)
                for inner in s.structs ?? [] { visit(inner, prefix + s.name + ".") }
            }
            for s in structs ?? [] { visit(s, "") }
            return out
        }
    }

    public var components: [Kind]

    public func kind(_ id: String) -> Kind? { components.first { $0.id == id } }

    /// The bundled RealityKit catalogue.
    public static let realityKit: ComponentCatalogue = {
        guard let url = Bundle.module.url(forResource: "components", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let catalogue = try? JSONDecoder().decode(ComponentCatalogue.self, from: data) else {
            return ComponentCatalogue(components: [])
        }
        return catalogue
    }()

    /// A new component with the fields the reference always writes.
    public func makeComponent(_ id: String) throws -> Component {
        guard let kind = kind(id) else { throw USDError("unknown component \(id)") }
        var c = Component(primName: kind.primName, id: id)
        let fields = kind.fieldsByKey
        for key in kind.alwaysWrite ?? [] {
            guard let f = fields[key], let type = TypeName(f.type) else { continue }
            c.types[key] = type
            if let text = f.default { c.values[key] = try USDAReader.parseValue(text, type: type) }
        }
        return c
    }
}

/// One component of an entity: a `RealityKitComponent` (or, for app-defined
/// components, `RealityKitCustomComponent`) child prim. Fields of nested
/// `RealityKitStruct` prims use dotted keys (`Shape.extent`).
public struct Component: Equatable, Sendable {
    public var primName: String
    public var id: String
    public var isCustom: Bool
    public var values: [String: Value]
    public var types: [String: TypeName]
    public var relationships: [String: [Path]]

    public init(primName: String, id: String, isCustom: Bool = false, values: [String: Value] = [:],
                types: [String: TypeName] = [:], relationships: [String: [Path]] = [:]) {
        self.primName = primName
        self.id = id
        self.isCustom = isCustom
        self.values = values
        self.types = types
        self.relationships = relationships
    }

    public mutating func set(_ key: String, _ value: Value, type: TypeName) {
        values[key] = value
        types[key] = type
    }
}

/// Where components live in USD. The RealityKit encoding is the only one
/// for now; the protocol keeps the document model independent of it.
public protocol ComponentStorage: Sendable {
    func components(of prim: Path, in layer: Layer) -> [Component]
    func write(_ component: Component, to prim: Path, in layer: inout Layer) throws
    func remove(_ primName: String, from prim: Path, in layer: inout Layer)
}

/// `scene-usd.md` §4.1: a component is a child prim of the entity with
/// `uniform token info:id`, attributes named after the runtime's fields,
/// nested `RealityKitStruct` prims and relationships for entity references.
public struct RealityKitComponentStorage: ComponentStorage {
    public static let componentType = "RealityKitComponent"
    public static let customComponentType = "RealityKitCustomComponent"
    public static let structType = "RealityKitStruct"

    public init() {}

    public func components(of prim: Path, in layer: Layer) -> [Component] {
        layer.primChildren(of: prim).compactMap { name in
            let p = prim.appendingChild(name)
            guard let type = layer.field(FieldKey.typeName, at: p)?.stringValue,
                  type == Self.componentType || type == Self.customComponentType else { return nil }
            var c = Component(primName: name, id: layer.field(FieldKey.defaultValue, at: p.appendingProperty("info:id"))?.stringValue ?? "",
                              isCustom: type == Self.customComponentType)
            func read(_ owner: Path, prefix: String) {
                for property in layer.propertyNames(of: owner) where property != "info:id" {
                    let pp = owner.appendingProperty(property)
                    guard let spec = layer.spec(at: pp) else { continue }
                    if spec.type == .relationship {
                        if case .pathListOp(let op)? = spec.fields[FieldKey.targetPaths] { c.relationships[prefix + property] = op.applied(to: []) }
                        continue
                    }
                    if let t = spec.fields[FieldKey.typeName]?.stringValue.flatMap(TypeName.init) { c.types[prefix + property] = t }
                    if let v = spec.fields[FieldKey.defaultValue] { c.values[prefix + property] = v }
                }
                for child in layer.primChildren(of: owner) {
                    let cp = owner.appendingChild(child)
                    if layer.field(FieldKey.typeName, at: cp)?.stringValue == Self.structType { read(cp, prefix: prefix + child + ".") }
                }
            }
            read(p, prefix: "")
            return c
        }
    }

    public func write(_ component: Component, to prim: Path, in layer: inout Layer) throws {
        let p = prim.appendingChild(component.primName)
        try layer.createPrim(at: p, typeName: component.isCustom ? Self.customComponentType : Self.componentType)
        let idPath = p.appendingProperty("info:id")
        if !layer.hasSpec(at: idPath) {
            try layer.createAttribute(at: idPath, typeName: TypeName("token")!, variability: .uniform)
        }
        layer.setField(FieldKey.defaultValue, .token(component.id), at: idPath)
        func owner(for key: String) throws -> (Path, String) {
            var parts = key.split(separator: ".").map(String.init)
            let name = parts.removeLast()
            var o = p
            for s in parts {
                o = o.appendingChild(s)
                if !layer.hasSpec(at: o) { try layer.createPrim(at: o, typeName: Self.structType) }
            }
            return (o, name)
        }
        for key in component.values.keys.sorted() {
            guard let type = component.types[key] else { throw USDError("component field \(key) has no type") }
            let (o, name) = try owner(for: key)
            try layer.createAttribute(at: o.appendingProperty(name), typeName: type, value: component.values[key])
        }
        for (key, targets) in component.relationships.sorted(by: { $0.key < $1.key }) {
            let (o, name) = try owner(for: key)
            try layer.createRelationship(at: o.appendingProperty(name), targets: targets)
        }
    }

    public func remove(_ primName: String, from prim: Path, in layer: inout Layer) {
        layer.removeSpec(at: prim.appendingChild(primName))
    }
}

/// Checks component prims against the catalogue: everything the reference
/// would drop silently (`compile.md` §2.5) is reported.
public struct ComponentDiagnostic: Equatable, Sendable, CustomStringConvertible {
    public enum Severity: String, Sendable { case error, warning }
    public var severity: Severity
    public var path: Path
    public var message: String
    public var description: String { "\(severity.rawValue): \(path): \(message)" }
}

extension ComponentCatalogue {
    public func validate(_ layer: Layer, storage: RealityKitComponentStorage = .init()) -> [ComponentDiagnostic] {
        var out: [ComponentDiagnostic] = []
        for prim in layer.primPaths() {
            let type = layer.field(FieldKey.typeName, at: prim)?.stringValue
            guard type != RealityKitComponentStorage.componentType, type != RealityKitComponentStorage.customComponentType,
                  type != RealityKitComponentStorage.structType else { continue }
            for c in storage.components(of: prim, in: layer) {
                let path = prim.appendingChild(c.primName)
                if c.id.isEmpty {
                    out.append(.init(severity: .error, path: path, message: "component prim without info:id (ignored at load)"))
                    continue
                }
                if c.isCustom {
                    if c.id.hasPrefix("RealityKit.") {
                        out.append(.init(severity: .error, path: path, message: "\(c.id) is a built-in id on a \(RealityKitComponentStorage.customComponentType) prim"))
                    }
                    continue
                }
                guard let kind = kind(c.id) else {
                    let severity: ComponentDiagnostic.Severity = c.id.hasPrefix("RealityKit.") ? .warning : .error
                    let hint = c.id.hasPrefix("RealityKit.") ? "not in the catalogue (ignored at load if the runtime does not know it)"
                        : "custom component id on a \(RealityKitComponentStorage.componentType) prim (not created at load; use \(RealityKitComponentStorage.customComponentType))"
                    out.append(.init(severity: severity, path: path, message: "unknown component \(c.id): \(hint)"))
                    continue
                }
                if kind.openFields == true { continue }
                let fields = kind.fieldsByKey
                for key in c.values.keys.sorted() {
                    guard let f = fields[key] else {
                        out.append(.init(severity: .warning, path: path, message: "\(c.id) has no field '\(key)' (ignored at load)"))
                        continue
                    }
                    if let t = c.types[key], let expected = TypeName(f.type), t.valueType != expected.valueType || t.isArray != expected.isArray {
                        out.append(.init(severity: .error, path: path, message: "'\(key)' is \(t), expected \(f.type) (reads as zero at load)"))
                    }
                    if let allowed = f.allowed, let token = c.values[key]?.stringValue, !allowed.contains(token) {
                        out.append(.init(severity: .warning, path: path, message: "'\(key)' = \"\(token)\" is not one of \(allowed.joined(separator: ", "))"))
                    }
                    if !f.verified, !(kind.alwaysWrite ?? []).contains(key) {
                        out.append(.init(severity: .warning, path: path, message: "'\(key)' is not verified to load (scene-usd.md §4.3)"))
                    }
                }
                let knownRelationships = Set((kind.relationships ?? []).map(\.name))
                for key in c.relationships.keys.sorted() where !knownRelationships.contains(key) {
                    out.append(.init(severity: .warning, path: path, message: "\(c.id) has no relationship '\(key)' (ignored at load)"))
                }
            }
        }
        return out
    }
}
