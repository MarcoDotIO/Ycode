import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif

/// The traits one shown preview (a **tile**) renders with: a variant of a
/// preview. See `specs/ide/previews.md` §Canvas layout.
public struct PreviewVariant: Codable, Equatable, Hashable, Sendable {
    /// "light", "dark", or nil (the device's appearance).
    public var colorScheme: String?
    /// A `DynamicTypeSize` case name ("xSmall" … "accessibility5"), or nil.
    public var dynamicType: String?
    public var orientation: String?

    public init(colorScheme: String? = nil, dynamicType: String? = nil, orientation: PreviewOrientation? = nil) {
        self.colorScheme = colorScheme
        self.dynamicType = dynamicType
        self.orientation = orientation?.rawValue
    }

    public var isLandscape: Bool { orientation.flatMap(PreviewOrientation.init(rawValue:))?.isLandscape ?? false }

    /// The dynamic type sizes, smallest first (SwiftUI's `DynamicTypeSize` names).
    public static let dynamicTypeSizes = ["xSmall", "small", "medium", "large", "xLarge", "xxLarge", "xxxLarge",
                                          "accessibility1", "accessibility2", "accessibility3", "accessibility4", "accessibility5"]
    /// The sizes the Dynamic Type variants show (a spread of the range).
    public static let dynamicTypeVariantSizes = ["xSmall", "large", "xxxLarge", "accessibility1", "accessibility3", "accessibility5"]

    /// A short label for a tile ("Dark", "Landscape Left", "accessibility3").
    public var label: String {
        var parts: [String] = []
        if let c = colorScheme { parts.append(c == "dark" ? "Dark" : "Light") }
        if let o = orientation {
            parts.append(["portrait": "Portrait", "landscapeLeft": "Landscape Left", "landscapeRight": "Landscape Right"][o] ?? "Upside Down")
        }
        if let d = dynamicType { parts.append(d) }
        return parts.joined(separator: ", ")
    }
}

/// One tile of the canvas: which preview, with which traits, at which
/// size in points (before the screen layout scales it).
public struct PreviewTile: Equatable, Sendable {
    public var preview: Int
    public var variant: PreviewVariant
    /// The size the preview is laid out at (the device's screen, turned for
    /// landscape, or a fixed layout's size).
    public var size: CGSize
    /// Lay out at the view's fitting size inside `size` (`.sizeThatFitsLayout`).
    public var fits: Bool
    public var title: String

    public init(preview: Int, variant: PreviewVariant = PreviewVariant(), size: CGSize, fits: Bool = false, title: String = "") {
        self.preview = preview
        self.variant = variant
        self.size = size
        self.fits = fits
        self.title = title
    }
}

/// Where a tile is drawn on the device's screen, in device points: the
/// host lays the preview out at `width / scale` × `height / scale` and
/// scales it into the region.
public struct PreviewRegion: Codable, Equatable, Sendable {
    public var preview: Int
    public var x: Double, y: Double, width: Double, height: Double
    public var scale: Double
    public var style: String?
    public var dynamicType: String?
    public var orientation: String?
    public var fits: Bool?

    public init(preview: Int, x: Double, y: Double, width: Double, height: Double, scale: Double,
                style: String? = nil, dynamicType: String? = nil, orientation: String? = nil, fits: Bool? = nil) {
        self.preview = preview
        (self.x, self.y, self.width, self.height, self.scale) = (x, y, width, height, scale)
        self.style = style
        self.dynamicType = dynamicType
        self.orientation = orientation
        self.fits = fits
    }

    public var rect: CGRect { CGRect(x: x, y: y, width: width, height: height) }
}

/// What the host shows: the payload to load and the regions. The IDE writes
/// it as `plan.json` next to the payloads; the host polls the file, loads
/// a payload it has not loaded yet, and rebuilds its views.
public struct PreviewPlan: Codable, Equatable, Sendable {
    /// Increases with every plan; the host reports `ready <generation>`.
    public var generation: Int
    /// The payload's path as the host sees it.
    public var payload: String
    public var regions: [PreviewRegion]

    public init(generation: Int, payload: String, regions: [PreviewRegion]) {
        self.generation = generation
        self.payload = payload
        self.regions = regions
    }

    public func json() -> Data {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys]
        return (try? e.encode(self)) ?? Data()
    }
}

/// Lays tiles out on the device's screen: every tile at one common scale,
/// in the grid (columns × rows) that gives the largest scale; ties go to
/// more columns, so two device-sized tiles on a phone sit side by side.
/// A single device-sized tile fills the screen at scale 1.
public enum PreviewScreenLayout {
    public static func regions(_ tiles: [PreviewTile], screen: CGSize, gap: Double = 0) -> [PreviewRegion] {
        guard !tiles.isEmpty, screen.width > 0, screen.height > 0 else { return [] }
        let cellW = tiles.map(\.size.width).max() ?? 1, cellH = tiles.map(\.size.height).max() ?? 1
        var best = (cols: 1, rows: tiles.count, scale: 0.0)
        for cols in 1...tiles.count {
            let rows = (tiles.count + cols - 1) / cols
            let s = min((screen.width - gap * Double(cols - 1)) / (Double(cols) * cellW),
                        (screen.height - gap * Double(rows - 1)) / (Double(rows) * cellH), 1)
            if s >= best.scale - 1e-9 { best = (cols, rows, s) }
        }
        let s = best.scale
        // Centre the grid on the screen.
        let gridW = Double(best.cols) * cellW * s + gap * Double(best.cols - 1)
        let gridH = Double(best.rows) * cellH * s + gap * Double(best.rows - 1)
        let x0 = ((screen.width - gridW) / 2).rounded(.down), y0 = ((screen.height - gridH) / 2).rounded(.down)
        return tiles.enumerated().map { i, t in
            let c = i % best.cols, r = i / best.cols
            let w = t.size.width * s, h = t.size.height * s
            // Each tile is centred in its cell.
            let cx = x0 + Double(c) * (cellW * s + gap) + (cellW * s - w) / 2
            let cy = y0 + Double(r) * (cellH * s + gap) + (cellH * s - h) / 2
            return PreviewRegion(preview: t.preview, x: cx, y: cy, width: w, height: h, scale: s,
                                 style: t.variant.colorScheme, dynamicType: t.variant.dynamicType,
                                 orientation: t.variant.orientation, fits: t.fits ? true : nil)
        }
    }

    /// The tile size of a preview on a screen of `screen` points: the
    /// screen (turned for landscape), or the fixed layout's size.
    public static func tileSize(_ p: PreviewDeclaration, screen: CGSize, variant: PreviewVariant) -> CGSize {
        if case .fixed(let s) = p.layout { return s }
        let landscape = variant.orientation != nil ? variant.isLandscape : p.orientation.isLandscape
        return landscape ? CGSize(width: screen.height, height: screen.width) : screen
    }
}
