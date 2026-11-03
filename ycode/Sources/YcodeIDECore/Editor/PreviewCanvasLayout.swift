import Foundation
import YcodePreviews

/// One tile of a live canvas: a region of the preview device's screen
/// (`PreviewRegion`, device points) shown at the preview's own size.
public struct PreviewLiveTile: Equatable, Sendable {
    public var title: String
    /// The preview's index in the canvas's list (header tabs).
    public var preview: Int
    public var region: PreviewRegion
    public init(title: String, preview: Int, region: PreviewRegion) {
        self.title = title
        self.preview = preview
        self.region = region
    }
    /// The preview's own size in points (the region before the host scaled it).
    public var size: CGSize { CGSize(width: region.width / region.scale, height: region.height / region.scale) }
}
/// The canvas's variants (the Variants button's menu; `previews.md` §Canvas).
public enum PreviewVariantKind: String, CaseIterable, Sendable {
    case colorScheme = "Color Scheme Variants"
    case orientation = "Orientation Variants"
    case dynamicType = "Dynamic Type Variants"

    /// The variants of a kind, given the canvas's base variant.
    public func variants(base: PreviewVariant) -> [PreviewVariant] {
        switch self {
        case .colorScheme:
            return ["light", "dark"].map { var v = base; v.colorScheme = $0; return v }
        case .orientation:
            return [PreviewOrientation.portrait, .landscapeLeft].map {
                PreviewVariant(colorScheme: base.colorScheme, dynamicType: base.dynamicType, orientation: $0)
            }
        case .dynamicType:
            return PreviewVariant.dynamicTypeSizes.filter { PreviewVariant.dynamicTypeVariantSizes.contains($0) }.map { var v = base; v.dynamicType = $0; return v }
        }
    }
}
/// How a live canvas arranges its tiles, in canvas points (Ycode design,
/// `previews.md` §Canvas layout): rows as on the device's screen, each tile
/// at its own size times the zoom; Fit picks the largest zoom (at most 1)
/// that shows every tile.
public enum PreviewCanvasLayout {
    public static let gap: CGFloat = 16
    public static let captionHeight: CGFloat = 18

    /// The tiles grouped in rows (by their region's top, then left).
    public static func rows(_ tiles: [PreviewLiveTile]) -> [[Int]] {
        var rows: [(y: Double, items: [Int])] = []
        for (i, t) in tiles.enumerated() {
            if let r = rows.firstIndex(where: { abs($0.y - t.region.y) < 1 }) { rows[r].items.append(i) } else { rows.append((t.region.y, [i])) }
        }
        return rows.sorted { $0.y < $1.y }.map { $0.items.sorted { tiles[$0].region.x < tiles[$1].region.x } }
    }

    /// The zoom that fits every tile into `area` (at most 1, at least 0.1).
    public static func fitZoom(_ tiles: [PreviewLiveTile], area: CGSize) -> CGFloat {
        guard !tiles.isEmpty, area.width > 0, area.height > 0 else { return 1 }
        let rows = rows(tiles)
        let width = rows.map { r in r.map { tiles[$0].size.width }.reduce(0, +) }.max() ?? 1
        let heights = rows.map { r in r.map { tiles[$0].size.height }.max() ?? 0 }.reduce(0, +)
        let maxCols = rows.map(\.count).max() ?? 1
        let zw = (area.width - gap * CGFloat(maxCols + 1)) / max(width, 1)
        let zh = (area.height - gap * CGFloat(rows.count + 1) - captionHeight * CGFloat(rows.count)) / max(heights, 1)
        return max(0.1, min(1, zw, zh))
    }

    /// Each tile's frame (image part, without the caption) in a flipped
    /// coordinate space whose origin is the top-left of the content; and the
    /// content's size. The content is centred horizontally by the caller.
    public static func frames(_ tiles: [PreviewLiveTile], zoom: CGFloat) -> (frames: [CGRect], size: CGSize) {
        var frames = Array(repeating: CGRect.zero, count: tiles.count)
        var y = gap
        var width: CGFloat = 0
        for row in rows(tiles) {
            var x = gap
            let h = row.map { tiles[$0].size.height * zoom }.max() ?? 0
            for i in row {
                let s = CGSize(width: tiles[i].size.width * zoom, height: tiles[i].size.height * zoom)
                frames[i] = CGRect(x: x, y: y + captionHeight, width: s.width, height: s.height)
                x += s.width + gap
            }
            width = max(width, x)
            y += captionHeight + h + gap
        }
        return (frames, CGSize(width: width, height: y))
    }

    /// A point in a tile (its own points, origin top-left) → device points.
    public static func devicePoint(_ p: CGPoint, in tileSize: CGSize, region: PreviewRegion) -> CGPoint {
        guard tileSize.width > 0, tileSize.height > 0 else { return CGPoint(x: region.x, y: region.y) }
        let x = min(max(p.x, 0), tileSize.width) / tileSize.width * region.width + region.x
        let y = min(max(p.y, 0), tileSize.height) / tileSize.height * region.height + region.y
        return CGPoint(x: x, y: y)
    }

    /// A region of the device's screen (points) → pixels of the stream image.
    public static func pixelRect(_ region: PreviewRegion, screen: CGSize, imageSize: CGSize) -> CGRect {
        guard screen.width > 0, screen.height > 0 else { return .zero }
        let sx = imageSize.width / screen.width, sy = imageSize.height / screen.height
        return CGRect(x: region.x * sx, y: region.y * sy, width: region.width * sx, height: region.height * sy).integral
            .intersection(CGRect(origin: .zero, size: imageSize))
    }
}
