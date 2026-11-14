import Foundation

/// Four of the navigator selector's glyphs in Ycode's own drawings
/// (`navigators.md` round 7 §5, council row 192): the kinds of picture the
/// reference shows, drawn by both IDEs from these parts in an 18 × 16
/// box (top-left origin, 1.3-point lines, round caps and joins):
/// Source Control a rounded square holding a cross mark, Debug a spray
/// can with a cloud of dots at its upper right, Breakpoints a horizontal
/// tag with a pointed right end and no hole, Reports a tall page with
/// lines and a zigzag foot. The other five keep their glyphs.
public enum SelectorGlyphs {
    public enum Part: Equatable, Sendable {
        case roundedRect(x: Double, y: Double, width: Double, height: Double, radius: Double)
        /// A polyline (closed: a polygon), stroked.
        case lines([Point], closed: Bool)
        /// A filled dot.
        case dot(x: Double, y: Double, radius: Double)
    }

    public struct Point: Equatable, Sendable {
        public var x: Double, y: Double
        public init(_ x: Double, _ y: Double) { self.x = x; self.y = y }
    }

    public static let width = 18.0, height = 16.0, lineWidth = 1.3

    /// The selector symbols these drawings replace.
    public static let replaced = ["arrow.triangle.branch", "gauge.with.dots.needle.33percent", "tag", "list.bullet.rectangle"]

    /// The parts for a selector symbol (nil: the symbol stays).
    public static func parts(forSymbol symbol: String) -> [Part]? {
        typealias P = Point
        switch symbol {
        case "arrow.triangle.branch":   // Source Control
            return [.roundedRect(x: 2.5, y: 1.5, width: 13, height: 13, radius: 3.2),
                    .lines([P(9, 4.75), P(9, 11.25)], closed: false), .lines([P(5.75, 8), P(12.25, 8)], closed: false)]
        case "gauge.with.dots.needle.33percent":   // Debug
            return [.roundedRect(x: 3, y: 6.25, width: 7, height: 8.75, radius: 1.6),
                    .roundedRect(x: 4.5, y: 3.5, width: 4, height: 2.75, radius: 0.7),
                    .lines([P(8.5, 4.75), P(10.5, 4.75)], closed: false),
                    .dot(x: 12.6, y: 3.2, radius: 0.8), .dot(x: 15, y: 1.9, radius: 0.8), .dot(x: 15.4, y: 4.6, radius: 0.8),
                    .dot(x: 13.2, y: 6, radius: 0.8), .dot(x: 16.4, y: 7.2, radius: 0.8)]
        case "tag":   // Breakpoints
            return [.lines([P(1.75, 4), P(12, 4), P(16.25, 8), P(12, 12), P(1.75, 12)], closed: true)]
        case "list.bullet.rectangle":   // Reports
            return [.lines([P(4, 1.25), P(14, 1.25), P(14, 13.75), P(12.75, 14.85), P(11.5, 13.75), P(10.25, 14.85), P(9, 13.75),
                            P(7.75, 14.85), P(6.5, 13.75), P(5.25, 14.85), P(4, 13.75)], closed: true),
                    .lines([P(6.5, 4.75), P(11.5, 4.75)], closed: false), .lines([P(6.5, 7.5), P(11.5, 7.5)], closed: false),
                    .lines([P(6.5, 10.25), P(10, 10.25)], closed: false)]
        default:
            return nil
        }
    }
}
