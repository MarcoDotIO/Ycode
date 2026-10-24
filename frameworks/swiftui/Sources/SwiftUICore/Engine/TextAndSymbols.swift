import Foundation

// Symbol measurement seen from layout. Round R5 (rendering) provides the
// real symbol provider; until then a table-driven stub. Text measurement is
// in Text/TextMeasurer.swift (round R4).

/// Metrics of a symbol image at the current font.
package struct SymbolMetrics: Sendable {
    /// Size when not resizable.
    package var size: CGSize
    /// Distance from the bottom edge up to the text baseline.
    package var baselineOffset: CGFloat
    /// Natural size of the artwork, used when resizable.
    package var naturalSize: CGSize

    package init(size: CGSize, baselineOffset: CGFloat, naturalSize: CGSize) {
        self.size = size
        self.baselineOffset = baselineOffset
        self.naturalSize = naturalSize
    }
}

/// Resolves symbol names (`Image(systemName:)`) to metrics.
package protocol SymbolProvider {
    /// Metrics for `name` at `font`; nil for an unknown name (laid out 0 × 0,
    /// 07-text-images-color.md §3).
    func symbol(named name: String, font: TextFont) -> SymbolMetrics?
    /// Spacing preferences above and below a symbol (04 §4.1 table).
    var spacingAbove: SpacingPreference { get }
    var spacingBelow: SpacingPreference { get }
}

/// A table-driven symbol provider for round R3.
package struct StubSymbolProvider: SymbolProvider {
    package var symbols: [String: SymbolMetrics]
    // Image edges: 2.33 below a standard view, 3.33 above one, 0 to text
    // (golden "Default spacing", rows/columns `image`).
    package var spacingAbove = SpacingPreference(kind: .image, towardStandard: 7.0 / 3, towardText: 0)
    package var spacingBelow = SpacingPreference(kind: .image, towardStandard: 10.0 / 3, towardText: 0)

    package init(symbols: [String: SymbolMetrics] = [:]) { self.symbols = symbols }

    package func symbol(named name: String, font: TextFont) -> SymbolMetrics? { symbols[name] }
}
