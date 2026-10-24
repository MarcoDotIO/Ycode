import Foundation

// Colours (07-text-images-color.md §4). A `Color` is a description that is
// resolved against an environment (colour scheme, contrast) into concrete
// sRGB components. Named system colours adapt to the colour scheme; colours
// built from components do not.

/// A colour value, resolved lazily against the environment.
public struct Color: Hashable, CustomStringConvertible, Sendable {
    package let provider: ColorProvider

    package init(provider: ColorProvider) { self.provider = provider }

    /// The colour spaces component initialisers accept.
    public enum RGBColorSpace: Hashable, Sendable {
        case sRGB
        case sRGBLinear
        case displayP3
    }

    /// A colour from components in `colorSpace` (values outside 0…1 give
    /// extended-range colours).
    public init(_ colorSpace: RGBColorSpace = .sRGB, red: Double, green: Double, blue: Double, opacity: Double = 1) {
        self.init(provider: .resolved(Resolved(colorSpace: colorSpace, red: Float(red), green: Float(green),
                                               blue: Float(blue), opacity: Float(opacity))))
    }

    /// A grey with the given white level.
    public init(_ colorSpace: RGBColorSpace = .sRGB, white: Double, opacity: Double = 1) {
        self.init(colorSpace, red: white, green: white, blue: white, opacity: opacity)
    }

    /// A colour from hue, saturation and brightness (all 0…1), in sRGB.
    public init(hue: Double, saturation: Double, brightness: Double, opacity: Double = 1) {
        let (r, g, b) = hsbToRGB(hue: hue, saturation: saturation, brightness: brightness)
        self.init(.sRGB, red: r, green: g, blue: b, opacity: opacity)
    }

    /// A colour that always resolves to `resolved`.
    public init(_ resolved: Resolved) { self.init(provider: .resolved(resolved)) }

    /// Resolves the colour for the colour scheme and contrast in `environment`.
    public func resolve(in environment: EnvironmentValues) -> Resolved {
        provider.resolve(scheme: environment.colorScheme, contrast: environment.colorSchemeContrast)
    }

    /// The colour with its opacity multiplied by `opacity`.
    public func opacity(_ opacity: Double) -> Color {
        Color(provider: .opacity(provider, opacity))
    }

    public var description: String { provider.description }

    // Named colours (07 §4).
    public static let accentColor = Color(provider: .system(.accentColor))
    public static let red = Color(provider: .system(.red))
    public static let orange = Color(provider: .system(.orange))
    public static let yellow = Color(provider: .system(.yellow))
    public static let green = Color(provider: .system(.green))
    public static let mint = Color(provider: .system(.mint))
    public static let teal = Color(provider: .system(.teal))
    public static let cyan = Color(provider: .system(.cyan))
    public static let blue = Color(provider: .system(.blue))
    public static let indigo = Color(provider: .system(.indigo))
    public static let purple = Color(provider: .system(.purple))
    public static let pink = Color(provider: .system(.pink))
    public static let brown = Color(provider: .system(.brown))
    public static let white = Color(provider: .system(.white))
    public static let gray = Color(provider: .system(.gray))
    public static let black = Color(provider: .system(.black))
    public static let clear = Color(provider: .system(.clear))
    public static let primary = Color(provider: .system(.primary))
    public static let secondary = Color(provider: .system(.secondary))
}

/// What a `Color` is made of.
package indirect enum ColorProvider: Hashable, Sendable, CustomStringConvertible {
    case resolved(Color.Resolved)
    case system(SystemColor)
    case opacity(ColorProvider, Double)

    func resolve(scheme: ColorScheme, contrast: ColorSchemeContrast) -> Color.Resolved {
        switch self {
        case .resolved(let r):
            return r
        case .system(let s):
            return s.resolve(scheme: scheme, contrast: contrast)
        case .opacity(let base, let factor):
            var r = base.resolve(scheme: scheme, contrast: contrast)
            r.opacity *= Float(factor)
            return r
        }
    }

    package var description: String {
        switch self {
        case .resolved(let r): return r.description
        case .system(let s): return s.rawValue
        case .opacity(let base, let f): return "\(Int((f * 100).rounded()))% \(base)"
        }
    }
}

extension Color {
    /// Concrete colour components. Stored as gamma-encoded extended sRGB;
    /// `linearRed`/… give the linear-light values.
    public struct Resolved: Hashable, CustomStringConvertible, Sendable {
        /// Gamma-encoded sRGB components (may lie outside 0…1).
        public var red: Float
        public var green: Float
        public var blue: Float
        public var opacity: Float

        /// Components given in `colorSpace`, converted to extended sRGB.
        public init(colorSpace: RGBColorSpace = .sRGB, red: Float, green: Float, blue: Float, opacity: Float = 1) {
            switch colorSpace {
            case .sRGB:
                (self.red, self.green, self.blue) = (red, green, blue)
            case .sRGBLinear:
                (self.red, self.green, self.blue) = (srgbEncode(red), srgbEncode(green), srgbEncode(blue))
            case .displayP3:
                let lin = DisplayP3.toLinearSRGB(srgbDecode(red), srgbDecode(green), srgbDecode(blue))
                (self.red, self.green, self.blue) = (srgbEncode(lin.0), srgbEncode(lin.1), srgbEncode(lin.2))
            }
            self.opacity = opacity
        }

        public var linearRed: Float {
            get { srgbDecode(red) }
            set { red = srgbEncode(newValue) }
        }
        public var linearGreen: Float {
            get { srgbDecode(green) }
            set { green = srgbEncode(newValue) }
        }
        public var linearBlue: Float {
            get { srgbDecode(blue) }
            set { blue = srgbEncode(newValue) }
        }

        /// `#RRGGBBAA` with components clamped to 0…1 and rounded to 8 bits.
        public var description: String {
            func byte(_ v: Float) -> String {
                let b = Int((min(max(v, 0), 1) * 255).rounded())
                let hex = String(b, radix: 16, uppercase: true)
                return hex.count == 1 ? "0" + hex : hex
            }
            return "#" + byte(red) + byte(green) + byte(blue) + byte(opacity)
        }

        /// A resolved colour from an `RRGGBB` or `RRGGBBAA` hex string.
        package init?(hex: String) {
            var s = Substring(hex)
            if s.hasPrefix("#") { s = s.dropFirst() }
            guard s.count == 6 || s.count == 8, let v = UInt32(s, radix: 16) else { return nil }
            let full = s.count == 6 ? (v << 8 | 0xFF) : v
            func c(_ shift: UInt32) -> Float { Float((full >> shift) & 0xFF) / 255 }
            self.init(red: c(24), green: c(16), blue: c(8), opacity: c(0))
        }
    }
}

extension Color.Resolved: Animatable {
    /// Interpolation happens in linear light.
    public var animatableData: AnimatablePair<Float, AnimatablePair<Float, AnimatablePair<Float, Float>>> {
        get { .init(linearRed, .init(linearGreen, .init(linearBlue, opacity))) }
        set {
            linearRed = newValue.first
            linearGreen = newValue.second.first
            linearBlue = newValue.second.second.first
            opacity = newValue.second.second.second
        }
    }
}

extension Color.Resolved: Codable {
    private enum CodingKeys: String, CodingKey { case red, green, blue, opacity }
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(red: try c.decode(Float.self, forKey: .red), green: try c.decode(Float.self, forKey: .green),
                  blue: try c.decode(Float.self, forKey: .blue), opacity: try c.decode(Float.self, forKey: .opacity))
    }
    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(red, forKey: .red)
        try c.encode(green, forKey: .green)
        try c.encode(blue, forKey: .blue)
        try c.encode(opacity, forKey: .opacity)
    }
}

// MARK: - Transfer functions and colour-space conversion (public standards:
// IEC 61966-2-1 sRGB; Display P3 = DCI-P3 primaries, D65 white, sRGB curve).

/// Gamma-encoded → linear sRGB, extended symmetrically to negative values.
package func srgbDecode(_ v: Float) -> Float {
    let a = abs(v)
    let lin = a <= 0.04045 ? a / 12.92 : powf((a + 0.055) / 1.055, 2.4)
    return v < 0 ? -lin : lin
}

/// Linear → gamma-encoded sRGB, extended symmetrically to negative values.
package func srgbEncode(_ v: Float) -> Float {
    let a = abs(v)
    let enc = a <= 0.0031308 ? a * 12.92 : 1.055 * powf(a, 1 / 2.4) - 0.055
    return v < 0 ? -enc : enc
}

private enum DisplayP3 {
    /// Linear Display P3 → linear sRGB, derived from the two sets of
    /// primaries and the shared D65 white point.
    static let matrix: [[Double]] = {
        let p3 = rgbToXYZ(r: (0.680, 0.320), g: (0.265, 0.690), b: (0.150, 0.060))
        let srgb = rgbToXYZ(r: (0.640, 0.330), g: (0.300, 0.600), b: (0.150, 0.060))
        return multiply(invert(srgb), p3)
    }()

    static func toLinearSRGB(_ r: Float, _ g: Float, _ b: Float) -> (Float, Float, Float) {
        let m = matrix
        let v = [Double(r), Double(g), Double(b)]
        func row(_ i: Int) -> Float { Float(m[i][0] * v[0] + m[i][1] * v[1] + m[i][2] * v[2]) }
        return (row(0), row(1), row(2))
    }

    static func rgbToXYZ(r: (Double, Double), g: (Double, Double), b: (Double, Double)) -> [[Double]] {
        let white = (0.3127, 0.3290)
        func xyz(_ c: (Double, Double)) -> [Double] { [c.0 / c.1, 1, (1 - c.0 - c.1) / c.1] }
        let (xr, xg, xb) = (xyz(r), xyz(g), xyz(b))
        let primaries = [[xr[0], xg[0], xb[0]], [xr[1], xg[1], xb[1]], [xr[2], xg[2], xb[2]]]
        let w = xyz(white)
        let s = apply(invert(primaries), w)
        return (0..<3).map { i in (0..<3).map { j in primaries[i][j] * s[j] } }
    }

    static func apply(_ m: [[Double]], _ v: [Double]) -> [Double] {
        (0..<3).map { i in m[i][0] * v[0] + m[i][1] * v[1] + m[i][2] * v[2] }
    }

    static func multiply(_ a: [[Double]], _ b: [[Double]]) -> [[Double]] {
        (0..<3).map { i in (0..<3).map { j in (0..<3).reduce(0) { $0 + a[i][$1] * b[$1][j] } } }
    }

    static func invert(_ m: [[Double]]) -> [[Double]] {
        let (a, b, c) = (m[0][0], m[0][1], m[0][2])
        let (d, e, f) = (m[1][0], m[1][1], m[1][2])
        let (g, h, i) = (m[2][0], m[2][1], m[2][2])
        let A = e * i - f * h, B = -(d * i - f * g), C = d * h - e * g
        let det = a * A + b * B + c * C
        return [[A / det, -(b * i - c * h) / det, (b * f - c * e) / det],
                [B / det, (a * i - c * g) / det, -(a * f - c * d) / det],
                [C / det, -(a * h - b * g) / det, (a * e - b * d) / det]]
    }
}

/// HSB (a.k.a. HSV) → RGB, the standard hexcone conversion.
private func hsbToRGB(hue: Double, saturation s: Double, brightness v: Double) -> (Double, Double, Double) {
    let h = (hue - hue.rounded(.down)) * 6
    let i = Int(h.rounded(.down)) % 6
    let f = h - h.rounded(.down)
    let p = v * (1 - s), q = v * (1 - s * f), t = v * (1 - s * (1 - f))
    switch i {
    case 0: return (v, t, p)
    case 1: return (q, v, p)
    case 2: return (p, v, t)
    case 3: return (p, q, v)
    case 4: return (t, p, v)
    default: return (v, p, q)
    }
}
