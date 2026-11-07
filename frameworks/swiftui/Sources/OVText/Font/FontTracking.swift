import Foundation
import Synchronization

// Metric adjustment of a font family (B5-OPENVIEWS;
// `specs/ide/cross-platform-parity.md` §15 OV-4): extra tracking per size
// and weight so that text set in an open font takes the widths of the
// desktop UI font Ycode's macOS IDE uses. Widths decide wrapping and
// truncation, so the IDE's labels, pop-up values and alert messages break and
// truncate where the macOS IDE's do.
//
// The tracking is added between characters (as `tracking(_:)` is) to text
// set in the system font (no explicit family) when the face that renders it
// belongs to the adjusted family.
//
// `desktopUI` (Inter, bundled): measured on Ycode's macOS host with Core
// Text, the system font at each size and weight against the bundled Inter
// faces, over 47 strings of the IDE (labels, menu titles, inspector values,
// the alphabet, digits; 645 characters): the tracking that makes the sums
// equal. At 11 points Inter runs 5.3 % narrower (12.8 % in the jump bar's
// ink, where the IDE's own 0.35 tracking was its earlier correction); from
// 17 points on the system font is the narrower one.
//
// `desktopMonospaced` (Noto Sans Mono, bundled): the system monospaced font
// advances 0.6182 em (8.036 at 13 points), Noto Sans Mono 0.600 em: 0.0182
// em of tracking per character. For the source editor (B5-EDITOR's choice).

/// Extra tracking (points) per font size and weight.
public struct FontTracking: Sendable, Equatable {
    /// Sizes (points), ascending.
    public let sizes: [Double]
    /// Tracking per size for each OpenType weight class (400, 500, …).
    public let byWeight: [Int: [Double]]
    /// Tracking proportional to the size (em units), when set.
    public let perEm: Double?

    public init(sizes: [Double], byWeight: [Int: [Double]]) {
        self.sizes = sizes
        self.byWeight = byWeight
        perEm = nil
    }

    /// The same tracking in em units at every size and weight.
    public init(perEm: Double) {
        sizes = []
        byWeight = [:]
        self.perEm = perEm
    }

    /// The tracking for a size and weight class: linear between the measured
    /// sizes and weights; outside the sizes, the nearest row scaled with the
    /// size.
    public func tracking(size: Double, weight: Int) -> Double {
        if let perEm { return perEm * size }
        let weights = byWeight.keys.sorted()
        guard let lo = weights.last(where: { $0 <= weight }) ?? weights.first,
              let hi = weights.first(where: { $0 >= weight }) ?? weights.last else { return 0 }
        let a = row(byWeight[lo] ?? [], size: size), b = row(byWeight[hi] ?? [], size: size)
        guard hi != lo else { return a }
        let t = Double(min(max(weight, lo), hi) - lo) / Double(hi - lo)
        return a + (b - a) * t
    }

    private func row(_ values: [Double], size: Double) -> Double {
        guard values.count == sizes.count, let first = sizes.first, let last = sizes.last else { return 0 }
        if size <= first { return values[0] * size / first }
        if size >= last { return values[values.count - 1] * size / last }
        let i = sizes.lastIndex { $0 <= size } ?? 0
        let t = (size - sizes[i]) / (sizes[i + 1] - sizes[i])
        return values[i] + (values[i + 1] - values[i]) * t
    }

    /// Inter (bundled) measured to the macOS IDE's system font (see above).
    public static let desktopUI = FontTracking(
        sizes: [9, 10, 11, 12, 13, 14, 15, 17, 20, 22],
        byWeight: [
            400: [0.3791, 0.3475, 0.3127, 0.2653, 0.2053, 0.1473, 0.0789, -0.0897, -0.3364, -0.5134],
            500: [0.4229, 0.3962, 0.3663, 0.3238, 0.2686, 0.2155, 0.1519, -0.0069, -0.2302, -0.3846],
            600: [0.4315, 0.4057, 0.3767, 0.3351, 0.2809, 0.2288, 0.1661, 0.0092, -0.2048, -0.3480],
            700: [0.4746, 0.4537, 0.4295, 0.3927, 0.3433, 0.2960, 0.2381, 0.0908, -0.1000, -0.2207],
        ])

    /// Noto Sans Mono (bundled) to the macOS IDE's monospaced advance.
    public static let desktopMonospaced = FontTracking(perEm: 0.0182)

    /// The family `desktopUI` is measured for.
    public static let desktopUIFamily = "Inter 24pt"
    /// The family `desktopMonospaced` is measured for.
    public static let desktopMonospacedFamily = "Noto Sans Mono"
}

extension FontCatalog {
    /// Adjusts system-font text set in `family` (a face's family name) by
    /// `tracking`; nil removes the adjustment. Set it once at launch, before
    /// text is laid out (as `setFamilies`). Example, the Linux IDE:
    /// `FontCatalog.shared.setTracking(.desktopUI, forFamily: FontTracking.desktopUIFamily)`.
    public func setTracking(_ tracking: FontTracking?, forFamily family: String) {
        trackingTable.withLock { $0[family.lowercased()] = tracking }
    }

    /// The adjustment for text in `family` at `size` and `weight` (0 when
    /// the family has none).
    public func trackingAdjustment(family: String, size: Double, weight: Int) -> Double {
        guard let t = trackingTable.withLock({ $0[family.lowercased()] }) else { return 0 }
        return t.tracking(size: size, weight: weight)
    }

    /// Whether any family is adjusted.
    public var hasTrackingAdjustments: Bool { trackingTable.withLock { !$0.isEmpty } }

    /// `OV_FONT_METRICS=desktop`: adjusts Inter and Noto Sans Mono to the
    /// macOS IDE's widths (drivers and demos; apps call `setTracking`).
    public func applyMetricsFromEnvironment() {
        guard ProcessInfo.processInfo.environment["OV_FONT_METRICS"]?.lowercased() == "desktop" else { return }
        setTracking(.desktopUI, forFamily: FontTracking.desktopUIFamily)
        setTracking(.desktopMonospaced, forFamily: FontTracking.desktopMonospacedFamily)
    }
}
