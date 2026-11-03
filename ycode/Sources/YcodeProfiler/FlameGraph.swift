import Foundation

/// A flame graph laid out from a top-down call tree (`specs/ide/profiler.md`
/// §4.4): each node a rectangle at its depth, `start` and `width` in samples,
/// children ordered by name so the same tree always draws the same way.
public struct FlameGraph: Sendable {
    public struct Box: Sendable, Equatable {
        public var depth: Int
        public var start: Int
        public var width: Int
        public var name: String
        public var image: String
        public var kind: GaugeTrace.ImageKind
        /// The node's key path (for selecting the same node elsewhere).
        public var path: [CallTreeNode.Key]
    }

    public let boxes: [Box]
    public let total: Int
    public let maxDepth: Int

    /// `tree` should be top-down (not inverted). Thread nodes (Separate by
    /// Thread) become boxes like any other node.
    public init(tree: CallTree) {
        var boxes: [Box] = []
        var maxDepth = 0
        func visit(_ n: CallTreeNode, depth: Int, start: Int) {
            boxes.append(Box(depth: depth, start: start, width: n.total, name: n.name, image: n.imageName, kind: n.imageKind, path: n.path))
            maxDepth = max(maxDepth, depth)
            var x = start
            for c in n.children.sorted(by: { $0.name != $1.name ? $0.name < $1.name : $0.total > $1.total }) {
                visit(c, depth: depth + 1, start: x)
                x += c.total
            }
        }
        var x = 0
        for c in tree.root.children.sorted(by: { $0.name != $1.name ? $0.name < $1.name : $0.total > $1.total }) {
            visit(c, depth: 0, start: x)
            x += c.total
        }
        self.boxes = boxes
        total = tree.root.total
        self.maxDepth = maxDepth
    }

    /// The box under a point (x in samples, depth).
    public func box(atSample x: Double, depth: Int) -> Box? {
        boxes.first { $0.depth == depth && Double($0.start) <= x && x < Double($0.start + $0.width) }
    }

    /// An SVG drawing: rows 16 points tall, the root row at the bottom
    /// (flames rise), names where they fit, a tooltip per box.
    public func svg(width: Int = 1200, title: String = "Gauge flame graph", intervalNs: UInt64 = 1_000_000) -> String {
        let row = 16, top = 34
        let height = top + (maxDepth + 1) * row + 8
        let scale = total > 0 ? Double(width - 20) / Double(total) : 0
        var out = """
        <?xml version="1.0" encoding="UTF-8"?>
        <svg xmlns="http://www.w3.org/2000/svg" width="\(width)" height="\(height)" viewBox="0 0 \(width) \(height)" font-family="Helvetica, Arial, sans-serif" font-size="11">
        <rect x="0" y="0" width="\(width)" height="\(height)" fill="#fcfcfc"/>
        <text x="\(width / 2)" y="20" text-anchor="middle" font-size="15">\(Self.escape(title))</text>

        """
        for b in boxes {
            let w = Double(b.width) * scale
            guard w >= 0.3 else { continue }
            let x = 10 + Double(b.start) * scale
            let y = height - 8 - (b.depth + 1) * row
            let pct = total > 0 ? 100 * Double(b.width) / Double(total) : 0
            let ms = Double(b.width) * Double(intervalNs) / 1e6
            let label = b.image.isEmpty ? b.name : "\(b.name) (\(b.image))"
            out += "<g><title>\(Self.escape(label)): \(b.width) samples, \(String(format: "%.1f", ms)) ms, \(String(format: "%.2f", pct)) %</title>"
            out += String(format: "<rect x=\"%.2f\" y=\"%d\" width=\"%.2f\" height=\"%d\" rx=\"2\" ", x, y, w, row - 1)
                + "fill=\"\(Self.color(b))\" stroke=\"#ffffff\" stroke-width=\"0.5\"/>"
            let chars = Int((w - 6) / 6.5)
            if chars >= 3 {
                let text = b.name.count <= chars ? b.name : String(b.name.prefix(max(1, chars - 2))) + ".."
                out += String(format: "<text x=\"%.2f\" y=\"%d\">", x + 3, y + row - 4) + Self.escape(text) + "</text>"
            }
            out += "</g>\n"
        }
        out += "</svg>\n"
        return out
    }

    /// Warm colors for app code, cooler for system code, gray for the kernel;
    /// the shade varies by name so neighbors differ.
    static func color(_ b: Box) -> String {
        var h: UInt32 = 2166136261
        for u in b.name.utf8 { h = (h ^ UInt32(u)) &* 16777619 }
        let v = Int(h % 55)
        switch b.kind {
        case .app: return "rgb(\(205 + v / 2),\(80 + v * 2),\(40 + v / 3))"
        case .kernel: return "rgb(\(150 + v / 2),\(150 + v / 2),\(160 + v / 2))"
        case .unknown where b.image.isEmpty: return "rgb(\(120 + v),\(170 + v),\(200 + v / 2))"
        default: return "rgb(\(90 + v),\(150 + v),\(210 - v / 2))"
        }
    }

    static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
    }
}
