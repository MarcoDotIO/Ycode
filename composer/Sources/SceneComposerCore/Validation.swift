import Foundation
import USDCore
import USDShade
import USDStage

/// A problem found in a scene. The reference tools drop many of these
/// silently (`specs/tools/scene-composer/compile.md` §2.5), so the composer
/// reports them.
public struct SceneDiagnostic: Equatable, Sendable, CustomStringConvertible {
    public enum Severity: String, Sendable, Comparable {
        case error, warning

        public static func < (a: Severity, b: Severity) -> Bool { a == .error && b == .warning }
    }

    public var severity: Severity
    /// A short stable identifier (`missing-asset`, `unknown-component`…).
    public var code: String
    public var path: Path
    public var message: String

    public init(_ severity: Severity, _ code: String, _ path: Path, _ message: String) {
        self.severity = severity
        self.code = code
        self.path = path
        self.message = message
    }

    public var description: String {
        "\(severity.rawValue): [\(code)] \(path.isEmpty || path.isRoot ? "layer" : path.description): \(message)"
    }
}

/// Structural checks of a scene layer and its composed stage.
public enum SceneValidator {
    public static func validate(_ layer: Layer, stage: Stage, catalogue: ComponentCatalogue = .realityKit,
                                library: MaterialXLibrary = .standard) -> [SceneDiagnostic] {
        var out: [SceneDiagnostic] = []
        // Layer conventions (scene-usd.md §1).
        if let name = layer.defaultPrim {
            if !layer.hasSpec(at: Path.root.appendingChild(name)) && stage.prim(at: Path.root.appendingChild(name)) == nil {
                out.append(.init(.error, "default-prim", .root, "defaultPrim \"\(name)\" does not exist"))
            }
        } else if !layer.primChildren(of: .root).isEmpty {
            out.append(.init(.warning, "default-prim", .root, "no defaultPrim (RealityKit loads the stage wrapper's first child)"))
        }
        if let axis = layer.upAxis, axis != "Y", axis != "Z" {
            out.append(.init(.error, "up-axis", .root, "upAxis must be \"Y\" or \"Z\", not \"\(axis)\""))
        }
        if let m = layer.metersPerUnit, !(m > 0) {
            out.append(.init(.error, "meters-per-unit", .root, "metersPerUnit must be positive"))
        }
        // Prims and properties (composing the whole stage).
        for prim in stage.traverse(.all) {
            out += checkPrim(prim, stage: stage)
        }
        for e in stage.errors {
            out.append(.init(.error, "composition", .root, e))
        }
        out += catalogue.validate(layer).map {
            SceneDiagnostic($0.severity == .error ? .error : .warning, "component", $0.path, $0.message)
        }
        for prim in stage.traverse(.all) where prim.typeName == "Material" {
            out += checkMaterial(prim.path, stage: stage, library: library)
        }
        return out.sorted { ($0.severity, $0.path.description) < ($1.severity, $1.path.description) }
    }

    static func checkPrim(_ prim: Prim, stage: Stage) -> [SceneDiagnostic] {
        var out: [SceneDiagnostic] = []
        let p = prim.path
        for set in prim.variantSets {
            if let selection = set.selection, !set.variants.contains(selection) {
                out.append(.init(.warning, "variant", p, "variant set \(set.name) selects missing variant \(selection)"))
            }
        }
        let names = prim.propertyNames
        for name in names {
            guard let a = prim.attribute(name) ?? prim.relationship(name) else { continue }
            if a.isRelationship || a.typeName == nil {
                for t in a.targets where stage.prim(at: t.primPath) == nil {
                    out.append(.init(.error, "target", p.appendingProperty(name), "target <\(t)> does not exist"))
                }
                continue
            }
            for t in a.targets where stage.prim(at: t.primPath) == nil {
                out.append(.init(.error, "connection", p.appendingProperty(name), "connection <\(t)> does not exist"))
            }
            guard let type = a.typeName else {
                out.append(.init(.error, "type", p.appendingProperty(name), "unknown attribute type"))
                continue
            }
            if let v = a.value(), let vt = v.valueType, vt != type.valueType || v.isArray != type.isArray {
                out.append(.init(.error, "type", p.appendingProperty(name), "value is \(vt.baseName)\(v.isArray ? "[]" : ""), declared \(type)"))
            }
        }
        if let order = prim.attribute(Xform.orderAttribute)?.value()?.stringArray {
            for op in order where op != Xform.resetToken {
                let name = op.hasPrefix("!invert!") ? String(op.dropFirst(8)) : op
                if Xform.opType(name) == nil || prim.attribute(name) == nil {
                    out.append(.init(.error, "xform", p, "xformOpOrder names \(op), which is not an authored op"))
                }
            }
        }
        if prim.typeName == "Mesh" {
            let counts = prim.attribute("faceVertexCounts")?.value()?.doubleComponents ?? []
            let indices = prim.attribute("faceVertexIndices")?.value()?.doubleComponents ?? []
            let points = prim.attribute("points")?.value()?.arrayCount ?? 0
            if Int(counts.reduce(0, +)) != indices.count {
                out.append(.init(.error, "mesh", p, "faceVertexCounts sum to \(Int(counts.reduce(0, +))) but there are \(indices.count) indices"))
            }
            if let bad = indices.first(where: { $0 < 0 || Int($0) >= points }) {
                out.append(.init(.error, "mesh", p, "face vertex index \(Int(bad)) is out of range (\(points) points)"))
            }
        }
        if prim.typeName == "Plane" {
            out.append(.init(.warning, "geometry", p, "RealityKit does not load Plane prims"))
        }
        return out
    }

    /// Material checks: MaterialX interfaces plus the RealityKit rules of
    /// `materials.md` (unknown nodes load as a grey fallback material).
    static func checkMaterial(_ path: Path, stage: Stage, library: MaterialXLibrary) -> [SceneDiagnostic] {
        guard let net = try? ShadeNetwork(stage: stage, material: path) else { return [] }
        var out: [SceneDiagnostic] = []
        for d in net.validate(library: library) {
            let nodePath = d.node.isEmpty ? path : net.path(of: d.node)
            // RealityKit node definitions are not bundled in this round:
            // report their ids as unchecked rather than unknown.
            if let node = net.node(d.node), node.id.hasPrefix("ND_realitykit_") || node.id.hasPrefix("ND_RealityKit") || node.id.hasPrefix("ND_MTL_") {
                if d.message.hasPrefix("unknown node definition") {
                    out.append(.init(.warning, "material-node", nodePath, "\(node.id) is not in the bundled MaterialX library; not checked"))
                }
                continue
            }
            out.append(.init(d.severity == .error ? .error : .warning, "material", nodePath, d.message))
        }
        for node in net.nodes where node.id.hasSuffix("_v2") && node.id.hasPrefix("ND_realitykit_pbr_surfaceshader") {
            out.append(.init(.error, "material-node", net.path(of: node.name),
                             "\(node.id) is not accepted by Xcode 27.1 or the macOS 27 runtime (fallback grey material); write ND_realitykit_pbr_surfaceshader_2_0"))
        }
        if !net.outputs.contains(where: { $0.source != nil }) {
            out.append(.init(.warning, "material", path, "no connected surface output"))
        }
        return out
    }
}
