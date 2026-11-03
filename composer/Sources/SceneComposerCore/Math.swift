import Foundation

/// A 3-vector of doubles.
public struct Vec3: Hashable, Sendable, CustomStringConvertible {
    public var x, y, z: Double

    public init(_ x: Double, _ y: Double, _ z: Double) {
        self.x = x
        self.y = y
        self.z = z
    }

    public static let zero = Vec3(0, 0, 0)
    public static let one = Vec3(1, 1, 1)

    public static func + (a: Vec3, b: Vec3) -> Vec3 { Vec3(a.x + b.x, a.y + b.y, a.z + b.z) }
    public static func - (a: Vec3, b: Vec3) -> Vec3 { Vec3(a.x - b.x, a.y - b.y, a.z - b.z) }
    public static func * (a: Vec3, s: Double) -> Vec3 { Vec3(a.x * s, a.y * s, a.z * s) }
    public func dot(_ b: Vec3) -> Double { x * b.x + y * b.y + z * b.z }
    public func cross(_ b: Vec3) -> Vec3 { Vec3(y * b.z - z * b.y, z * b.x - x * b.z, x * b.y - y * b.x) }
    public var length: Double { dot(self).squareRoot() }

    public func isClose(to b: Vec3, tolerance: Double = 1e-9) -> Bool {
        abs(x - b.x) <= tolerance && abs(y - b.y) <= tolerance && abs(z - b.z) <= tolerance
    }

    public var description: String { "(\(x), \(y), \(z))" }
}

/// A unit quaternion, real part first (USD's `(real, i, j, k)` text order).
public struct Quat: Hashable, Sendable {
    public var real: Double
    public var imaginary: Vec3

    public init(real: Double, imaginary: Vec3) {
        self.real = real
        self.imaginary = imaginary
    }

    public static let identity = Quat(real: 1, imaginary: .zero)

    /// Rotation of `degrees` about a unit axis (right-handed).
    public init(axis: Vec3, degrees: Double) {
        let h = degrees * .pi / 360
        self.init(real: cos(h), imaginary: axis * sin(h))
    }

    public var normalized: Quat {
        let n = (real * real + imaginary.dot(imaginary)).squareRoot()
        guard n > 0 else { return .identity }
        return Quat(real: real / n, imaginary: imaginary * (1 / n))
    }

    /// Hamilton product: `a * b` applies `b` first, then `a`.
    public static func * (a: Quat, b: Quat) -> Quat {
        Quat(real: a.real * b.real - a.imaginary.dot(b.imaginary),
             imaginary: b.imaginary * a.real + a.imaginary * b.real + a.imaginary.cross(b.imaginary))
    }

    public func isClose(to b: Quat, tolerance: Double = 1e-9) -> Bool {
        // q and -q are the same rotation.
        let same = abs(real - b.real) <= tolerance && imaginary.isClose(to: b.imaginary, tolerance: tolerance)
        let opposite = abs(real + b.real) <= tolerance && imaginary.isClose(to: b.imaginary * -1, tolerance: tolerance)
        return same || opposite
    }
}

/// A 4×4 matrix in USD's convention: row-major, row vectors (`p' = p · M`),
/// translation in the last row; `A · B` applies `A` first.
public struct Matrix4: Hashable, Sendable, CustomStringConvertible {
    public var m: [Double]

    public init(_ m: [Double]) {
        precondition(m.count == 16)
        self.m = m
    }

    public static let identity = Matrix4([1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1])

    public subscript(row: Int, column: Int) -> Double {
        get { m[row * 4 + column] }
        set { m[row * 4 + column] = newValue }
    }

    public static func * (a: Matrix4, b: Matrix4) -> Matrix4 {
        var r = [Double](repeating: 0, count: 16)
        for i in 0..<4 {
            for j in 0..<4 {
                var s = 0.0
                for k in 0..<4 { s += a.m[i * 4 + k] * b.m[k * 4 + j] }
                r[i * 4 + j] = s
            }
        }
        return Matrix4(r)
    }

    public static func *= (a: inout Matrix4, b: Matrix4) { a = a * b }

    public static func translation(_ t: Vec3) -> Matrix4 {
        var r = identity
        r[3, 0] = t.x
        r[3, 1] = t.y
        r[3, 2] = t.z
        return r
    }

    public static func scale(_ s: Vec3) -> Matrix4 {
        var r = identity
        r[0, 0] = s.x
        r[1, 1] = s.y
        r[2, 2] = s.z
        return r
    }

    /// Rotation about one axis (0 = X, 1 = Y, 2 = Z), right-handed, in the
    /// row-vector form.
    public static func rotation(axis: Int, degrees: Double) -> Matrix4 {
        let a = degrees * .pi / 180
        let c = cos(a)
        let s = sin(a)
        var r = identity
        switch axis {
        case 0:
            r[1, 1] = c; r[1, 2] = s; r[2, 1] = -s; r[2, 2] = c
        case 1:
            r[0, 0] = c; r[0, 2] = -s; r[2, 0] = s; r[2, 2] = c
        default:
            r[0, 0] = c; r[0, 1] = s; r[1, 0] = -s; r[1, 1] = c
        }
        return r
    }

    public static func rotation(_ q: Quat) -> Matrix4 {
        let q = q.normalized
        let w = q.real
        let x = q.imaginary.x
        let y = q.imaginary.y
        let z = q.imaginary.z
        // Row-vector form: the transpose of the usual column-vector matrix.
        return Matrix4([
            1 - 2 * (y * y + z * z), 2 * (x * y + w * z), 2 * (x * z - w * y), 0,
            2 * (x * y - w * z), 1 - 2 * (x * x + z * z), 2 * (y * z + w * x), 0,
            2 * (x * z + w * y), 2 * (y * z - w * x), 1 - 2 * (x * x + y * y), 0,
            0, 0, 0, 1,
        ])
    }

    public func transform(point p: Vec3) -> Vec3 {
        Vec3(p.x * m[0] + p.y * m[4] + p.z * m[8] + m[12],
             p.x * m[1] + p.y * m[5] + p.z * m[9] + m[13],
             p.x * m[2] + p.y * m[6] + p.z * m[10] + m[14])
    }

    public var translation: Vec3 { Vec3(m[12], m[13], m[14]) }

    public var determinant3: Double {
        m[0] * (m[5] * m[10] - m[6] * m[9]) - m[1] * (m[4] * m[10] - m[6] * m[8]) + m[2] * (m[4] * m[9] - m[5] * m[8])
    }

    /// General inverse (nil when singular).
    public var inverse: Matrix4? {
        var a = m
        var inv = Matrix4.identity.m
        for col in 0..<4 {
            var pivot = col
            for r in col..<4 where abs(a[r * 4 + col]) > abs(a[pivot * 4 + col]) { pivot = r }
            guard abs(a[pivot * 4 + col]) > 1e-14 else { return nil }
            if pivot != col {
                for k in 0..<4 {
                    a.swapAt(col * 4 + k, pivot * 4 + k)
                    inv.swapAt(col * 4 + k, pivot * 4 + k)
                }
            }
            let d = a[col * 4 + col]
            for k in 0..<4 {
                a[col * 4 + k] /= d
                inv[col * 4 + k] /= d
            }
            for r in 0..<4 where r != col {
                let f = a[r * 4 + col]
                guard f != 0 else { continue }
                for k in 0..<4 {
                    a[r * 4 + k] -= f * a[col * 4 + k]
                    inv[r * 4 + k] -= f * inv[col * 4 + k]
                }
            }
        }
        return Matrix4(inv)
    }

    public func isClose(to b: Matrix4, tolerance: Double = 1e-9) -> Bool {
        zip(m, b.m).allSatisfy { abs($0 - $1) <= tolerance }
    }

    public var description: String {
        "( " + (0..<4).map { r in "(" + (0..<4).map { String(self[r, $0]) }.joined(separator: ", ") + ")" }.joined(separator: ", ") + " )"
    }
}

/// Translation, rotation and scale; matrix = S · R · T (scale first).
public struct TRS: Hashable, Sendable {
    public var translation: Vec3
    public var rotation: Quat
    public var scale: Vec3

    public init(translation: Vec3 = .zero, rotation: Quat = .identity, scale: Vec3 = .one) {
        self.translation = translation
        self.rotation = rotation
        self.scale = scale
    }

    public var matrix: Matrix4 { Matrix4.scale(scale) * Matrix4.rotation(rotation) * Matrix4.translation(translation) }

    /// Decomposes a matrix without shear or projection.
    public init(matrix: Matrix4) {
        let rows = (0..<3).map { r in Vec3(matrix[r, 0], matrix[r, 1], matrix[r, 2]) }
        var s = Vec3(rows[0].length, rows[1].length, rows[2].length)
        if matrix.determinant3 < 0 { s.x = -s.x }
        let r0 = s.x != 0 ? rows[0] * (1 / s.x) : Vec3(1, 0, 0)
        let r1 = s.y != 0 ? rows[1] * (1 / s.y) : Vec3(0, 1, 0)
        let r2 = s.z != 0 ? rows[2] * (1 / s.z) : Vec3(0, 0, 1)
        // Rows of the row-vector rotation matrix are the rotated basis vectors;
        // convert from the transposed form.
        let m00 = r0.x, m01 = r1.x, m02 = r2.x
        let m10 = r0.y, m11 = r1.y, m12 = r2.y
        let m20 = r0.z, m21 = r1.z, m22 = r2.z
        let trace = m00 + m11 + m22
        var q: Quat
        if trace > 0 {
            let k = (trace + 1).squareRoot() * 2
            q = Quat(real: k / 4, imaginary: Vec3((m21 - m12) / k, (m02 - m20) / k, (m10 - m01) / k))
        } else if m00 > m11 && m00 > m22 {
            let k = (1 + m00 - m11 - m22).squareRoot() * 2
            q = Quat(real: (m21 - m12) / k, imaginary: Vec3(k / 4, (m01 + m10) / k, (m02 + m20) / k))
        } else if m11 > m22 {
            let k = (1 + m11 - m00 - m22).squareRoot() * 2
            q = Quat(real: (m02 - m20) / k, imaginary: Vec3((m01 + m10) / k, k / 4, (m12 + m21) / k))
        } else {
            let k = (1 + m22 - m00 - m11).squareRoot() * 2
            q = Quat(real: (m10 - m01) / k, imaginary: Vec3((m02 + m20) / k, (m12 + m21) / k, k / 4))
        }
        if q.real < 0 { q = Quat(real: -q.real, imaginary: q.imaginary * -1) }
        self.init(translation: matrix.translation, rotation: q.normalized, scale: s)
    }
}
