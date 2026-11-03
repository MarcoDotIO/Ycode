// The CPU reference of the GPU re-projection (specs/simulator/xr-depth.md
// §5.2): the same grid, the same matrix, the same depth-edge rule and fill
// modes, rasterised in software. Tests check the GPU against it, and the
// viewer measures the disoccluded area with it at low resolution.

import Foundation
import YcodeDisplayStream

public enum XRFillMode: Int32, Sendable {
    /// Triangles across a depth edge stay a rubber sheet (colours smeared between both sides).
    case stretch = 0
    /// At the background's depth, sampled at their own place while unstretched (so a picture at its
    /// own viewpoint shows as sent), and once stretched in one colour of the background, read half a
    /// cell past their farthest corner, away from the nearest.
    case background = 1
    /// At the background's depth and sharp until the move stretches them past `XRWarpSettings.dropStretch`,
    /// then dropped (holes stay black, or show what lies behind: the world cache).
    case discard = 2
}

public struct XRWarpSettings: Equatable, Sendable {
    /// Depth texels per grid cell.
    public var gridStep: Int = 2
    /// A triangle crosses a depth edge when its farthest / nearest distance is above this.
    public var edgeRatio: Double = 1.08
    public var mode: XRFillMode = .background
    /// Discard mode: the stretch beyond which a triangle across a depth edge goes.
    public static let dropStretch = 1.5
    public init(gridStep: Int = 2, edgeRatio: Double = 1.08, mode: XRFillMode = .background) {
        (self.gridStep, self.edgeRatio, self.mode) = (gridStep, edgeRatio, mode)
    }
}

/// The result of a reference warp.
public struct XRWarpResult: Sendable {
    public var width: Int, height: Int
    /// BGRA, rows top to bottom; uncovered pixels (0, 0, 0, 0).
    public var pixels: [UInt8]
    /// Inverse depth per pixel (destination near), 0 uncovered.
    public var depth: [Float]
    /// Pixels drawn, and of them drawn by triangles the move stretched across a depth edge (the disoccluded area).
    public var covered: Int, stretched: Int

    public var stretchedFraction: Double { covered > 0 ? Double(stretched) / Double(covered) : 0 }

    public func pixel(_ x: Int, _ y: Int) -> (b: UInt8, g: UInt8, r: UInt8, a: UInt8) {
        let i = (y * width + x) * 4
        return (pixels[i], pixels[i + 1], pixels[i + 2], pixels[i + 3])
    }
}

public enum XRReferenceWarp {
    /// Re-projects `colour` (BGRA, `colourWidth` × `colourHeight`) with its
    /// depth from `source` to `destination` at `width` × `height`.
    public static func warp(colour: [UInt8], colourWidth: Int, colourHeight: Int, depth: XRDepthImage,
                            source: XRViewGeometry, destination: XRViewGeometry, width: Int, height: Int,
                            settings: XRWarpSettings = XRWarpSettings()) -> XRWarpResult {
        var out = XRWarpResult(width: width, height: height, pixels: [UInt8](repeating: 0, count: width * height * 4),
                               depth: [Float](repeating: 0, count: width * height), covered: 0, stretched: 0)
        var mark = [UInt8](repeating: 0, count: width * height)
        let m = XRReprojection.matrix(from: source, to: destination)
        let step = max(1, settings.gridStep)
        let gw = max(2, depth.width / step + 1), gh = max(2, depth.height / step + 1)
        // Every grid point once: its uv, depth sample and clip position.
        struct Vertex { var u: Double, v: Double, q: UInt16, x: Double, y: Double, z: Double, w: Double }
        var grid: [Vertex] = []
        grid.reserveCapacity(gw * gh)
        for j in 0..<gh {
            for i in 0..<gw {
                let u = Double(i) / Double(gw - 1), v = Double(j) / Double(gh - 1)
                let tx = min(depth.width - 1, Int(u * Double(depth.width))), ty = min(depth.height - 1, Int(v * Double(depth.height)))
                let q = depth.samples[ty * depth.width + tx]
                let c = m.apply(source.point(u: u, v: v, q: q))
                grid.append(Vertex(u: u, v: v, q: q, x: c.x, y: c.y, z: c.z, w: c.w))
            }
        }
        func sample(_ u: Double, _ v: Double) -> (UInt8, UInt8, UInt8) {
            let x = min(colourWidth - 1, max(0, Int(u * Double(colourWidth)))), y = min(colourHeight - 1, max(0, Int(v * Double(colourHeight))))
            let i = (y * colourWidth + x) * 4
            return (colour[i], colour[i + 1], colour[i + 2])
        }
        func triangle(_ a: Vertex, _ b: Vertex, _ c: Vertex) {
            let vs = [a, b, c]
            let ds = vs.map { Double($0.q) / 65535 }
            let dmax = ds.max()!, dmin = ds.min()!
            let edge = dmax > dmin * settings.edgeRatio + 1e-6
            let far = ds.firstIndex(of: dmin)!
            guard vs.allSatisfy({ $0.w > 1e-9 }) else { return }    // the reference does not clip
            // How far the move stretched it: its sides against the same sides flat at the far depth.
            var stretch = 1.0
            if edge && settings.mode != .stretch {
                let flat = vs.map { m.apply(source.point(u: $0.u, v: $0.v, q: vs[far].q)) }
                guard flat.allSatisfy({ $0.w > 1e-9 }) else { return }
                for k in 0..<3 {
                    let n = (k + 1) % 3
                    let qx = vs[n].x / vs[n].w - vs[k].x / vs[k].w, qy = vs[n].y / vs[n].w - vs[k].y / vs[k].w
                    let rx = flat[n].x / flat[n].w - flat[k].x / flat[k].w, ry = flat[n].y / flat[n].w - flat[k].y / flat[k].w
                    stretch = max(stretch, (qx * qx + qy * qy).squareRoot() / max((rx * rx + ry * ry).squareRoot(), 1e-6))
                }
            }
            if edge && settings.mode == .discard && stretch > XRWarpSettings.dropStretch { return }
            var sx = [Double](repeating: 0, count: 3), sy = sx, sz = sx
            var farZ = 0.0
            for k in 0..<3 {
                sx[k] = (vs[k].x / vs[k].w + 1) / 2 * Double(width)
                sy[k] = (vs[k].y / vs[k].w + 1) / 2 * Double(height)
                sz[k] = vs[k].z / vs[k].w
            }
            farZ = sz[far] * 0.999
            let area = (sx[1] - sx[0]) * (sy[2] - sy[0]) - (sx[2] - sx[0]) * (sy[1] - sy[0])
            guard abs(area) > 1e-12 else { return }
            let x0 = max(0, Int(floor(sx.min()!))), x1 = min(width - 1, Int(ceil(sx.max()!)))
            let y0 = max(0, Int(floor(sy.min()!))), y1 = min(height - 1, Int(ceil(sy.max()!)))
            guard x0 <= x1, y0 <= y1 else { return }
            for py in y0...y1 {
                let cy = Double(py) + 0.5
                for px in x0...x1 {
                    let cx = Double(px) + 0.5
                    let w0 = ((sx[1] - cx) * (sy[2] - cy) - (sx[2] - cx) * (sy[1] - cy)) / area
                    let w1 = ((sx[2] - cx) * (sy[0] - cy) - (sx[0] - cx) * (sy[2] - cy)) / area
                    let w2 = 1 - w0 - w1
                    guard w0 >= 0, w1 >= 0, w2 >= 0 else { continue }
                    let z = edge && settings.mode != .stretch ? farZ : w0 * sz[0] + w1 * sz[1] + w2 * sz[2]
                    let idx = py * width + px
                    guard z > Double(out.depth[idx]) || mark[idx] == 0 else { continue }
                    // Perspective-correct uv.
                    let iw = w0 / vs[0].w + w1 / vs[1].w + w2 / vs[2].w
                    var u = (w0 * vs[0].u / vs[0].w + w1 * vs[1].u / vs[1].w + w2 * vs[2].u / vs[2].w) / iw
                    var v = (w0 * vs[0].v / vs[0].w + w1 * vs[1].v / vs[1].w + w2 * vs[2].v / vs[2].w) / iw
                    if edge && settings.mode == .background {
                        let k = max(0, min(1, (stretch - 1) * 2))
                        let nearest = ds.firstIndex(of: dmax)!
                        let mu = max(0, min(1, vs[far].u + (vs[far].u - vs[nearest].u) * 0.5)), mv = max(0, min(1, vs[far].v + (vs[far].v - vs[nearest].v) * 0.5))
                        (u, v) = (u + (mu - u) * k, v + (mv - v) * k)
                    }
                    let (cb, cg, cr) = sample(u, v)
                    out.pixels[idx * 4] = cb
                    out.pixels[idx * 4 + 1] = cg
                    out.pixels[idx * 4 + 2] = cr
                    out.pixels[idx * 4 + 3] = 255
                    out.depth[idx] = Float(z)
                    mark[idx] = edge && stretch > 1.25 ? 2 : 1
                }
            }
        }
        for cy in 0..<(gh - 1) {
            for cx in 0..<(gw - 1) {
                let p00 = grid[cy * gw + cx], p10 = grid[cy * gw + cx + 1]
                let p01 = grid[(cy + 1) * gw + cx], p11 = grid[(cy + 1) * gw + cx + 1]
                triangle(p00, p01, p10)
                triangle(p10, p01, p11)
            }
        }
        for v in mark where v != 0 {
            out.covered += 1
            if v == 2 { out.stretched += 1 }
        }
        return out
    }
}
