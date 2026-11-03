import Foundation
import USDCore
import USDStage

/// UsdGeom transform operations (`xformOp:*` attributes ordered by
/// `xformOpOrder`), in USD's conventions: the op list is applied from last
/// to first to a point, so the local matrix is `op[n-1] · … · op[0]` in
/// row-vector form; `!resetXformStack!` cuts the parent transform; an
/// `!invert!` prefix inverts an op.
public enum Xform {
    public static let orderAttribute = "xformOpOrder"
    public static let resetToken = "!resetXformStack!"
    static let invertPrefix = "!invert!"

    /// The op type of an op name: `translate` for `xformOp:translate:pivot`.
    public static func opType(_ name: String) -> String? {
        let parts = name.split(separator: ":")
        guard parts.count >= 2, parts[0] == "xformOp" else { return nil }
        return String(parts[1])
    }

    /// The matrix of one op from its value.
    public static func matrix(opType: String, value: Value) -> Matrix4? {
        guard let c = value.doubleComponents else { return nil }
        switch opType {
        case "translate" where c.count == 3: return .translation(Vec3(c[0], c[1], c[2]))
        case "scale" where c.count == 3: return .scale(Vec3(c[0], c[1], c[2]))
        case "scale" where c.count == 1: return .scale(Vec3(c[0], c[0], c[0]))
        case "rotateX" where c.count == 1: return .rotation(axis: 0, degrees: c[0])
        case "rotateY" where c.count == 1: return .rotation(axis: 1, degrees: c[0])
        case "rotateZ" where c.count == 1: return .rotation(axis: 2, degrees: c[0])
        case "orient" where c.count == 4: return .rotation(Quat(real: c[0], imaginary: Vec3(c[1], c[2], c[3])))
        case "transform" where c.count == 16: return Matrix4(c)
        default:
            // rotateXYZ, rotateZYX, …: the first-named axis is applied first.
            guard opType.hasPrefix("rotate"), opType.count == 9, c.count == 3 else { return nil }
            let axes = opType.dropFirst(6).map { "XYZ".firstIndex(of: $0).map { "XYZ".distance(from: "XYZ".startIndex, to: $0) } }
            guard axes.allSatisfy({ $0 != nil }) else { return nil }
            var m = Matrix4.identity
            for a in axes.compactMap({ $0 }) { m *= .rotation(axis: a, degrees: c[a]) }
            return m
        }
    }

    /// The local transform of a composed prim and whether it resets the
    /// parent transform.
    public static func localTransform(_ prim: Prim, time: Double? = nil) -> (matrix: Matrix4, resetsXformStack: Bool) {
        guard let order = prim.attribute(orderAttribute)?.value(at: time)?.stringArray else { return (.identity, false) }
        var m = Matrix4.identity
        var reset = false
        for entry in order {
            if entry == resetToken {
                reset = true
                m = .identity
                continue
            }
            let inverted = entry.hasPrefix(invertPrefix)
            let name = inverted ? String(entry.dropFirst(invertPrefix.count)) : entry
            guard let type = opType(name), let value = prim.attribute(name)?.value(at: time),
                  var op = matrix(opType: type, value: value) else { continue }
            if inverted { op = op.inverse ?? .identity }
            m = op * m
        }
        return (m, reset)
    }

    /// The prim's transform in world space (`local · parentWorld`).
    public static func worldTransform(_ prim: Prim, time: Double? = nil) -> Matrix4 {
        let (local, reset) = localTransform(prim, time: time)
        guard !reset, let parent = prim.parent, !parent.path.isRoot else { return local }
        return local * worldTransform(parent, time: time)
    }

    /// The local transform that places a prim at `world` under its parent.
    public static func local(forWorld world: Matrix4, of prim: Prim, time: Double? = nil) -> Matrix4 {
        guard let parent = prim.parent, !parent.path.isRoot, let inv = worldTransform(parent, time: time).inverse else { return world }
        return world * inv
    }

    /// XYZ Euler angles (degrees, X applied first) of a rotation.
    public static func eulerXYZ(_ q: Quat) -> Vec3 {
        let m = Matrix4.rotation(q)
        let b = asin(max(-1, min(1, -m[0, 2])))
        let a: Double
        let c: Double
        if abs(cos(b)) > 1e-9 {
            a = atan2(m[1, 2], m[2, 2])
            c = atan2(m[0, 1], m[0, 0])
        } else {
            a = atan2(-m[2, 1], m[1, 1])
            c = 0
        }
        return Vec3(a * 180 / .pi, b * 180 / .pi, c * 180 / .pi)
    }

    /// The op stack the composer writes (`scene-usd.md` §1: T·R·S with
    /// `orient`), whatever stack the prim had before.
    public static let canonicalOrder = ["xformOp:translate", "xformOp:orient", "xformOp:scale"]

    /// Writes a TRS on a prim spec of `layer` as `translate` (double3),
    /// `orient` (quatf, real first) and `scale` (float3) ops in that order;
    /// other `xformOp:` attributes of the spec are removed. Existing op
    /// attributes keep their value types. With `time` the values are written
    /// as time samples.
    public static func setTRS(_ trs: TRS, at prim: Path, in layer: inout Layer, time: Double? = nil) throws {
        if !layer.hasSpec(at: prim) { try layer.createPrim(at: prim, specifier: .over) }
        let newOrder = canonicalOrder
        func existingType(_ name: String, _ fallback: String) -> TypeName {
            layer.field(FieldKey.typeName, at: prim.appendingProperty(name))?.stringValue.flatMap(TypeName.init) ?? TypeName(fallback)!
        }
        func set(_ name: String, _ type: TypeName, _ components: [Double]) throws {
            let p = prim.appendingProperty(name)
            let value = Value.numeric(type.valueType, components)
            if !layer.hasSpec(at: p) { try layer.createAttribute(at: p, typeName: type) }
            if let time {
                var samples: [TimeSample] = {
                    if case .timeSamples(let s)? = layer.field(FieldKey.timeSamples, at: p) { return s }
                    return []
                }()
                samples.removeAll { $0.time == time }
                samples.append(TimeSample(time: time, value: value))
                samples.sort { $0.time < $1.time }
                layer.setField(FieldKey.timeSamples, .timeSamples(samples), at: p)
            } else {
                layer.setField(FieldKey.defaultValue, value, at: p)
            }
        }
        for name in newOrder {
            switch name {
            case "xformOp:translate":
                try set(name, existingType(name, "double3"), [trs.translation.x, trs.translation.y, trs.translation.z])
            case "xformOp:orient":
                let q = trs.rotation.normalized
                try set(name, existingType(name, "quatf"), [q.real, q.imaginary.x, q.imaginary.y, q.imaginary.z])
            default:
                try set(name, existingType(name, "float3"), [trs.scale.x, trs.scale.y, trs.scale.z])
            }
        }
        // Ops no longer in the order are removed.
        for name in layer.propertyNames(of: prim) where name.hasPrefix("xformOp:") && !newOrder.contains(name) {
            layer.removeSpec(at: prim.appendingProperty(name))
        }
        let orderPath = prim.appendingProperty(orderAttribute)
        if !layer.hasSpec(at: orderPath) {
            try layer.createAttribute(at: orderPath, typeName: TypeName("token[]")!, variability: .uniform)
        }
        layer.setField(FieldKey.defaultValue, .tokens(newOrder), at: orderPath)
    }
}
