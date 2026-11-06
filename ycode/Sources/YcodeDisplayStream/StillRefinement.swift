// Lossless once still (display-stream.md §4.2.2): which parts of the screen
// a viewer last received lossy (JPEG tiles, video pictures), and when they
// are due again as lossless tiles. The server keeps one per viewer; it is
// plain bookkeeping on the tile grid, so it is tested on every platform.

/// The lossy parts of a viewer's picture, on the server's tile grid.
public struct StillRefinement: Sendable, Equatable {
    /// A rectangle in device pixels.
    public struct Rect: Equatable, Sendable {
        public var x: Int, y: Int, width: Int, height: Int
        public init(x: Int, y: Int, width: Int, height: Int) { (self.x, self.y, self.width, self.height) = (x, y, width, height) }
    }

    /// How long the screen must stay unchanged (and nothing lossy go out)
    /// before the lossy parts are sent again losslessly. Long enough that a
    /// moving picture (a frame every 16.7 ms, or a busy guest's every 50–100
    /// ms) never pays for lossless frames; short enough to look immediate.
    public static let stillNanoseconds: UInt64 = 200_000_000

    public let width: Int, height: Int, tile: Int
    public let tilesX: Int, tilesY: Int
    private var lossy: [Bool]
    private var lossyTiles = 0
    /// The last time the screen changed or a lossy picture went out.
    public private(set) var lastActivity: UInt64 = 0

    public init(width: Int, height: Int, tile: Int) {
        self.width = max(1, width)
        self.height = max(1, height)
        self.tile = max(1, tile)
        tilesX = (self.width + self.tile - 1) / self.tile
        tilesY = (self.height + self.tile - 1) / self.tile
        lossy = [Bool](repeating: false, count: tilesX * tilesY)
    }

    /// Nothing is waiting to be refined.
    public var isEmpty: Bool { lossyTiles == 0 }

    /// Rectangles were sent lossy at `time` (monotonic ns).
    public mutating func sentLossy(_ rects: [Rect], at time: UInt64) {
        for r in rects { mark(r, lossy: true) }
        lastActivity = max(lastActivity, time)
    }

    /// Rectangles were sent losslessly (zlib tiles): the tiles they cover
    /// completely are exact now.
    public mutating func sentLossless(_ rects: [Rect]) {
        for r in rects { mark(r, lossy: false) }
    }

    /// The guest presented a new picture at `time`: refinement waits until
    /// the screen is still again.
    public mutating func screenChanged(at time: UInt64) {
        lastActivity = max(lastActivity, time)
    }

    /// Whether the lossy parts are due for a lossless picture at `time`.
    public func isDue(at time: UInt64) -> Bool {
        lossyTiles > 0 && time >= lastActivity && time - lastActivity >= Self.stillNanoseconds
    }

    /// The lossy parts as disjoint rectangles (runs of tiles per tile row,
    /// equal runs in consecutive rows joined), and forgets them.
    public mutating func take() -> [Rect] {
        guard lossyTiles > 0 else { return [] }
        var open: [Int: Rect] = [:]   // runs of the previous row by start tile, growing downwards
        var out: [Rect] = []
        for ty in 0..<tilesY {
            var runs: [(Int, Int)] = []
            var tx = 0
            while tx < tilesX {
                guard lossy[ty * tilesX + tx] else { tx += 1; continue }
                let start = tx
                while tx < tilesX && lossy[ty * tilesX + tx] { tx += 1 }
                runs.append((start, tx))
            }
            var next: [Int: Rect] = [:]
            for (a, b) in runs {
                let x = a * tile, w = min(width, b * tile) - x
                let y = ty * tile, h = min(height, y + tile) - y
                if var r = open[a], r.width == w {
                    r.height += h
                    open[a] = nil
                    next[a] = r
                } else {
                    next[a] = Rect(x: x, y: y, width: w, height: h)
                }
            }
            out += open.values
            open = next
        }
        out += open.values
        lossy = [Bool](repeating: false, count: tilesX * tilesY)
        lossyTiles = 0
        return out.sorted { ($0.y, $0.x) < ($1.y, $1.x) }
    }

    /// Marks the tiles a rectangle touches (lossy) or covers completely (exact).
    private mutating func mark(_ r: Rect, lossy value: Bool) {
        let x0 = max(0, r.x), y0 = max(0, r.y)
        let x1 = min(width, r.x + r.width), y1 = min(height, r.y + r.height)
        guard x1 > x0, y1 > y0 else { return }
        var tx0 = x0 / tile, ty0 = y0 / tile
        var tx1 = (x1 - 1) / tile, ty1 = (y1 - 1) / tile
        if !value {
            // Only tiles the rectangle covers to their edges (or the image's).
            if x0 % tile != 0 { tx0 += 1 }
            if y0 % tile != 0 { ty0 += 1 }
            if x1 % tile != 0 && x1 != width { tx1 -= 1 }
            if y1 % tile != 0 && y1 != height { ty1 -= 1 }
            guard tx1 >= tx0, ty1 >= ty0 else { return }
        }
        for ty in ty0...ty1 {
            for tx in tx0...tx1 {
                let i = ty * tilesX + tx
                if lossy[i] != value {
                    lossy[i] = value
                    lossyTiles += value ? 1 : -1
                }
            }
        }
    }
}
