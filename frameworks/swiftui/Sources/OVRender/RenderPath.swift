// Paths and images in the display list.

import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif

/// A path: subpaths of lines and Bézier curves.
public struct RenderPath: Equatable, Sendable {
    public enum Element: Equatable, Sendable {
        case move(CGPoint)
        case line(CGPoint)
        case quad(CGPoint, control: CGPoint)
        case cubic(CGPoint, control1: CGPoint, control2: CGPoint)
        case close
    }

    public var elements: [Element]
    public init(_ elements: [Element] = []) { self.elements = elements }
    public var isEmpty: Bool { elements.isEmpty }

    public mutating func move(to p: CGPoint) { elements.append(.move(p)) }
    public mutating func line(to p: CGPoint) { elements.append(.line(p)) }
    public mutating func quad(to p: CGPoint, control: CGPoint) { elements.append(.quad(p, control: control)) }
    public mutating func cubic(to p: CGPoint, control1: CGPoint, control2: CGPoint) {
        elements.append(.cubic(p, control1: control1, control2: control2))
    }
    public mutating func close() { elements.append(.close) }

    /// A rectangle as one closed subpath (clockwise on screen).
    public init(rect r: CGRect) {
        self.init([.move(CGPoint(x: r.minX, y: r.minY)), .line(CGPoint(x: r.maxX, y: r.minY)),
                   .line(CGPoint(x: r.maxX, y: r.maxY)), .line(CGPoint(x: r.minX, y: r.maxY)), .close])
    }

    /// The path with every point transformed.
    public func applying(_ t: RenderTransform) -> RenderPath {
        if t.isIdentity { return self }
        return RenderPath(elements.map { e in
            switch e {
            case .move(let p): return .move(t.apply(p))
            case .line(let p): return .line(t.apply(p))
            case let .quad(p, c): return .quad(t.apply(p), control: t.apply(c))
            case let .cubic(p, c1, c2): return .cubic(t.apply(p), control1: t.apply(c1), control2: t.apply(c2))
            case .close: return .close
            }
        })
    }

    /// Bounds of all points, control points included (a cheap superset of
    /// the exact bounds); `.null` for an empty path.
    public var controlBounds: CGRect {
        var minX = Double.infinity, minY = Double.infinity, maxX = -Double.infinity, maxY = -Double.infinity
        func add(_ p: CGPoint) {
            minX = min(minX, p.x)
            minY = min(minY, p.y)
            maxX = max(maxX, p.x)
            maxY = max(maxY, p.y)
        }
        for e in elements {
            switch e {
            case .move(let p), .line(let p): add(p)
            case let .quad(p, c):
                add(p)
                add(c)
            case let .cubic(p, c1, c2):
                add(p)
                add(c1)
                add(c2)
            case .close: break
            }
        }
        if minX > maxX { return .null }
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }
}

/// Pixels of an image: 8-bit RGBA, premultiplied alpha, rows top to bottom
/// without padding.
public struct PixelImage: Equatable, Sendable {
    public var size: PixelSize
    public var rgba: [UInt8]

    public init(size: PixelSize, rgba: [UInt8]) {
        precondition(rgba.count == size.width * size.height * 4, "PixelImage: wrong buffer size")
        self.size = size
        self.rgba = rgba
    }

    public init(size: PixelSize, fill: RenderColor = .clear) {
        let (r, g, b, a) = fill.rgba8
        let pr = UInt8((Int(r) * Int(a) + 127) / 255), pg = UInt8((Int(g) * Int(a) + 127) / 255), pb = UInt8((Int(b) * Int(a) + 127) / 255)
        var px = [UInt8](repeating: 0, count: max(0, size.width * size.height * 4))
        var i = 0
        while i < px.count {
            px[i] = pr
            px[i + 1] = pg
            px[i + 2] = pb
            px[i + 3] = a
            i += 4
        }
        self.size = size
        self.rgba = px
    }

    /// The premultiplied pixel at (x, y): r, g, b, a.
    public func pixel(x: Int, y: Int) -> (UInt8, UInt8, UInt8, UInt8) {
        let i = (y * size.width + x) * 4
        return (rgba[i], rgba[i + 1], rgba[i + 2], rgba[i + 3])
    }
}

/// An image in the display list: encoded bytes (PNG or JPEG) or pixels.
/// Shared by reference; the rasteriser caches decoded images per instance.
public final class RenderImage: Hashable, Sendable {
    public enum Source: Sendable {
        case png(Data)
        case jpeg(Data)
        case pixels(PixelImage)
    }

    public let source: Source
    /// Size in pixels.
    public let pixelSize: PixelSize

    public init(source: Source, pixelSize: PixelSize) {
        self.source = source
        self.pixelSize = pixelSize
    }

    public static func == (l: RenderImage, r: RenderImage) -> Bool { l === r }
    public func hash(into h: inout Hasher) { h.combine(ObjectIdentifier(self)) }
}
