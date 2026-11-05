#if canImport(CoreGraphics)
import CoreGraphics
#endif
import Foundation

/// The Library's Objects tab (`library.md` §Layout, `interface-builder.md`
/// §Inserting objects): each kind's one-line description and its icon,
/// drawn by Ycode from the shapes below (no artwork files). Both IDEs draw
/// the same shapes.
extension IBDocument.NewObject {
    /// The one-line description under the object's name.
    public var summary: String {
        switch self {
        case .label: "Displays a line of read-only text."
        case .button: "Sends an action when clicked."
        case .textField: "Lets the user type a line of text."
        case .imageView: "Displays an image."
        case .view: "A plain rectangular area that holds other views."
        case .stackView: "Arranges its views in a row or column."
        }
    }

    /// The class the object makes, per runtime (shown in the Library's
    /// detail area).
    public func className(iOS: Bool) -> String {
        switch self {
        case .label: iOS ? "UILabel" : "NSTextField"
        case .button: iOS ? "UIButton" : "NSButton"
        case .textField: iOS ? "UITextField" : "NSTextField"
        case .imageView: iOS ? "UIImageView" : "NSImageView"
        case .view: iOS ? "UIView" : "NSView"
        case .stackView: iOS ? "UIStackView" : "NSStackView"
        }
    }

    /// Objects matching a Library filter (name or description, case-insensitive).
    public static func matching(_ filter: String) -> [Self] {
        let q = filter.lowercased().trimmingCharacters(in: .whitespaces)
        return allCases.filter { q.isEmpty || $0.rawValue.lowercased().contains(q) || $0.summary.lowercased().contains(q) }
    }

    /// One shape of an object icon, in a 26 × 26 box (origin top-left).
    public enum IconShape: Equatable, Sendable {
        /// The tinted rounded backdrop every icon has.
        case backdrop(CGRect, radius: CGFloat)
        case fillRoundedRect(CGRect, radius: CGFloat)
        case strokeRect(CGRect)
        case fillRect(CGRect)
        case fillOval(CGRect)
        case fillPolygon([CGPoint])
        /// Bold text ("Aa") with its top-left corner and point size.
        case text(String, at: CGPoint, size: CGFloat)
    }

    /// The icon's shapes, all drawn in the accent colour (the backdrop at 12%).
    public var iconShapes: [IconShape] {
        let box = CGRect(x: 2, y: 2, width: 22, height: 22)
        var out: [IconShape] = [.backdrop(box, radius: 5)]
        switch self {
        case .label: out.append(.text("Aa", at: CGPoint(x: box.minX + 3, y: box.minY + 4), size: 11))
        case .button: out.append(.fillRoundedRect(box.insetBy(dx: 2, dy: 6), radius: 4))
        case .textField:
            out.append(.strokeRect(box.insetBy(dx: 2, dy: 6)))
            out.append(.fillRect(CGRect(x: box.minX + 5, y: box.midY - 3, width: 1, height: 6)))
        case .imageView:
            out.append(.fillPolygon([CGPoint(x: box.minX + 3, y: box.maxY - 4), CGPoint(x: box.midX - 2, y: box.midY), CGPoint(x: box.maxX - 3, y: box.maxY - 4)]))
            out.append(.fillOval(CGRect(x: box.maxX - 8, y: box.minY + 3, width: 4, height: 4)))
        case .view: out.append(.strokeRect(box.insetBy(dx: 4, dy: 4)))
        case .stackView:
            for i in 0..<3 { out.append(.fillRect(CGRect(x: box.minX + 3 + CGFloat(i) * 6.5, y: box.minY + 5, width: 5, height: box.height - 10))) }
        }
        return out
    }
}
