import USDCore
import USDStage

/// A material's shading network as UsdShade stores it: a `Material` prim
/// with terminal outputs (`outputs:mtlx:surface`, `outputs:surface`,
/// `outputs:displacement`), `Shader` prims identified by `info:id` (MaterialX
/// `ND_*` node definitions or `UsdPreviewSurface` ids), `NodeGraph`
/// containers, typed `inputs:`/`outputs:` attributes and `.connect` paths.
public struct ShadeNetwork: Equatable, Sendable {
    /// A connection source: a node (path relative to the material, `""` for
    /// the material itself) and one of its ports (`outputs:out`).
    public struct Source: Hashable, Sendable {
        public var node: String
        public var port: String

        public init(node: String, port: String) {
            self.node = node
            self.port = port
        }
    }

    public struct Port: Equatable, Sendable {
        /// Name without the `inputs:`/`outputs:` prefix.
        public var name: String
        public var type: TypeName
        public var value: Value?
        public var source: Source?
        public var isUniform: Bool

        public init(name: String, type: TypeName, value: Value? = nil, source: Source? = nil, isUniform: Bool = false) {
            self.name = name
            self.type = type
            self.value = value
            self.source = source
            self.isUniform = isUniform
        }
    }

    public enum NodeKind: String, Sendable { case shader = "Shader", nodeGraph = "NodeGraph" }

    public struct Node: Equatable, Sendable {
        /// Path relative to the material (`Surface`, `Graph/Noise`).
        public var name: String
        public var kind: NodeKind
        /// `info:id` (empty for node graphs).
        public var id: String
        public var inputs: [Port]
        public var outputs: [Port]

        public init(name: String, kind: NodeKind = .shader, id: String, inputs: [Port] = [], outputs: [Port] = []) {
            self.name = name
            self.kind = kind
            self.id = id
            self.inputs = inputs
            self.outputs = outputs
        }

        public func input(_ name: String) -> Port? { inputs.first { $0.name == name } }
        public func output(_ name: String) -> Port? { outputs.first { $0.name == name } }

        /// A node for a MaterialX definition with its outputs declared.
        public static func make(_ name: String, definition: NodeDefinition) -> Node {
            Node(name: name, id: definition.name, outputs: definition.outputs.compactMap { o in
                MaterialXLibrary.usdType(forMaterialXType: o.type).map { Port(name: o.name, type: $0) }
            })
        }
    }

    public var material: Path
    /// The material's own ports (terminals and interface inputs).
    public var outputs: [Port]
    public var inputs: [Port]
    public var nodes: [Node]

    public init(material: Path, outputs: [Port] = [], inputs: [Port] = [], nodes: [Node] = []) {
        self.material = material
        self.outputs = outputs
        self.inputs = inputs
        self.nodes = nodes
    }

    public func node(_ name: String) -> Node? { nodes.first { $0.name == name } }

    // MARK: Reading

    /// Reads the network below a `Material` prim of one layer.
    public init(layer: Layer, material: Path) throws {
        guard layer.hasSpec(at: material) else { throw USDError("no material at \(material)") }
        self.init(material: material)
        let (ins, outs) = ShadeNetwork.ports(material: material, owner: material) { name in
            layer.propertyNames(of: material).contains(name) ? layer.spec(at: material.appendingProperty(name)) : nil
        } names: { layer.propertyNames(of: material) }
        inputs = ins
        outputs = outs
        for path in layer.primPaths(under: material) where !path.containsVariantSelection {
            guard let kind = layer.field(FieldKey.typeName, at: path)?.stringValue.flatMap(NodeKind.init(rawValue:)) else { continue }
            let (i, o) = ShadeNetwork.ports(material: material, owner: path) { name in
                layer.spec(at: path.appendingProperty(name))
            } names: { layer.propertyNames(of: path) }
            let id = layer.field(FieldKey.defaultValue, at: path.appendingProperty("info:id"))?.stringValue ?? ""
            nodes.append(Node(name: ShadeNetwork.relative(path, to: material), kind: kind, id: id, inputs: i, outputs: o))
        }
    }

    /// Reads the composed network below a `Material` prim of a stage.
    public init(stage: Stage, material: Path) throws {
        guard let prim = stage.prim(at: material) else { throw USDError("no material at \(material)") }
        self.init(material: material)
        func ports(_ p: Prim) -> ([Port], [Port]) {
            var ins: [Port] = []
            var outs: [Port] = []
            for name in p.propertyNames where name.hasPrefix("inputs:") || name.hasPrefix("outputs:") {
                guard let a = p.attribute(name), let type = a.typeName else { continue }
                let isInput = name.hasPrefix("inputs:")
                let port = Port(name: String(name.dropFirst(isInput ? 7 : 8)), type: type, value: a.value(),
                                source: a.targets.first.map { ShadeNetwork.source($0, material: material) },
                                isUniform: a.variability == .uniform)
                if isInput { ins.append(port) } else { outs.append(port) }
            }
            return (ins, outs)
        }
        (inputs, outputs) = ports(prim)
        func visit(_ p: Prim) {
            for child in p.children {
                if let kind = NodeKind(rawValue: child.typeName) {
                    let (i, o) = ports(child)
                    let id = child.attribute("info:id")?.value()?.stringValue ?? ""
                    nodes.append(Node(name: ShadeNetwork.relative(child.path, to: material), kind: kind, id: id, inputs: i, outputs: o))
                }
                visit(child)
            }
        }
        visit(prim)
    }

    static func relative(_ path: Path, to material: Path) -> String {
        path.primNames.dropFirst(material.primNames.count).joined(separator: "/")
    }

    static func source(_ target: Path, material: Path) -> Source {
        Source(node: relative(target.primPath, to: material), port: target.name)
    }

    static func ports(material: Path, owner: Path, spec: (String) -> Spec?, names: () -> [String]) -> ([Port], [Port]) {
        var ins: [Port] = []
        var outs: [Port] = []
        for name in names() where name.hasPrefix("inputs:") || name.hasPrefix("outputs:") {
            guard let s = spec(name), let typeText = s.fields[FieldKey.typeName]?.stringValue, let type = TypeName(typeText) else { continue }
            var source: Source?
            if case .pathListOp(let op)? = s.fields[FieldKey.connectionPaths], let first = op.applied(to: []).first {
                source = ShadeNetwork.source(first, material: material)
            }
            let isInput = name.hasPrefix("inputs:")
            var value = s.fields[FieldKey.defaultValue]
            if value == .valueBlock { value = nil }
            let uniform: Bool = {
                if case .variability(.uniform)? = s.fields[FieldKey.variability] { return true }
                return false
            }()
            let port = Port(name: String(name.dropFirst(isInput ? 7 : 8)), type: type, value: value, source: source, isUniform: uniform)
            if isInput { ins.append(port) } else { outs.append(port) }
        }
        return (ins, outs)
    }

    // MARK: Writing

    /// The stage path of a node.
    public func path(of node: String) -> Path {
        node.split(separator: "/").reduce(material) { $0.appendingChild(String($1)) }
    }

    /// Writes the network into a layer (creating or updating the prims).
    public func write(into layer: inout Layer) throws {
        try layer.createPrim(at: material, typeName: "Material")
        try writePorts(inputs, prefix: "inputs:", owner: material, into: &layer)
        try writePorts(outputs, prefix: "outputs:", owner: material, into: &layer)
        for node in nodes.sorted(by: { $0.name.split(separator: "/").count < $1.name.split(separator: "/").count }) {
            let p = path(of: node.name)
            try layer.createPrim(at: p, typeName: node.kind.rawValue)
            if node.kind == .shader {
                try layer.createAttribute(at: p.appendingProperty("info:id"), typeName: TypeName("token")!, value: .token(node.id),
                                          variability: .uniform)
            }
            try writePorts(node.inputs, prefix: "inputs:", owner: p, into: &layer)
            try writePorts(node.outputs, prefix: "outputs:", owner: p, into: &layer)
        }
    }

    private func writePorts(_ ports: [Port], prefix: String, owner: Path, into layer: inout Layer) throws {
        for port in ports {
            let p = owner.appendingProperty(prefix + port.name)
            try layer.createAttribute(at: p, typeName: port.type, value: port.value, variability: port.isUniform ? .uniform : .varying)
            if let source = port.source {
                let target = path(of: source.node).appendingProperty(source.port)
                layer.setField(FieldKey.connectionPaths, .pathListOp(.explicit([target])), at: p)
            } else {
                layer.setField(FieldKey.connectionPaths, nil, at: p)
            }
        }
    }

    // MARK: Validation

    public struct Diagnostic: Equatable, Sendable, CustomStringConvertible {
        public enum Severity: String, Sendable { case error, warning }
        public var severity: Severity
        public var node: String
        public var message: String
        public var description: String { "\(severity.rawValue): \(node.isEmpty ? "material" : node): \(message)" }
    }

    /// Checks node ids, input names and types against MaterialX definitions,
    /// and that every connection reaches an existing port of a matching type.
    /// `UsdPreviewSurface`-family ids are checked through their `ND_Usd…`
    /// MaterialX definitions; unknown non-MaterialX ids are reported as warnings.
    public func validate(library: MaterialXLibrary = .standard) -> [Diagnostic] {
        var out: [Diagnostic] = []
        func port(_ source: Source) -> Port? {
            if source.node.isEmpty {
                let name = source.port.hasPrefix("inputs:") ? String(source.port.dropFirst(7)) : String(source.port.dropFirst(8))
                return (source.port.hasPrefix("inputs:") ? inputs : outputs).first { $0.name == name }
            }
            guard let n = node(source.node) else { return nil }
            if source.port.hasPrefix("outputs:") { return n.output(String(source.port.dropFirst(8))) }
            if source.port.hasPrefix("inputs:") { return n.input(String(source.port.dropFirst(7))) }
            return nil
        }
        func check(_ p: Port, owner: String) {
            guard let s = p.source else { return }
            guard let target = port(s) else {
                out.append(Diagnostic(severity: .error, node: owner, message: "\(p.name) connects to missing \(s.node):\(s.port)"))
                return
            }
            if target.type.valueType != p.type.valueType || target.type.isArray != p.type.isArray {
                out.append(Diagnostic(severity: .warning, node: owner,
                                      message: "\(p.name) (\(p.type)) connects to \(s.node):\(s.port) (\(target.type))"))
            }
        }
        for p in outputs + inputs { check(p, owner: "") }
        for n in nodes {
            for p in n.inputs + n.outputs { check(p, owner: n.name) }
            guard n.kind == .shader else { continue }
            let definition = library[n.id] ?? library["ND_" + n.id + "_surfaceshader"] ?? library["ND_" + n.id]
            guard let definition else {
                out.append(Diagnostic(severity: n.id.hasPrefix("ND_") ? .error : .warning, node: n.name,
                                      message: "unknown node definition '\(n.id)'"))
                continue
            }
            for input in n.inputs {
                guard let declared = definition.input(input.name) else {
                    out.append(Diagnostic(severity: .error, node: n.name, message: "\(definition.name) has no input '\(input.name)'"))
                    continue
                }
                if let expected = MaterialXLibrary.usdType(forMaterialXType: declared.type),
                   expected.valueType != input.type.valueType || expected.isArray != input.type.isArray {
                    out.append(Diagnostic(severity: .error, node: n.name,
                                          message: "input '\(input.name)' is \(input.type), \(definition.name) declares \(declared.type)"))
                }
            }
            // USD-native ids (UsdPreviewSurface…) name their outputs differently
            // from the MaterialX definitions that describe their inputs.
            for output in n.outputs where n.id.hasPrefix("ND_") && definition.output(output.name) == nil {
                out.append(Diagnostic(severity: .error, node: n.name, message: "\(definition.name) has no output '\(output.name)'"))
            }
        }
        return out
    }
}
