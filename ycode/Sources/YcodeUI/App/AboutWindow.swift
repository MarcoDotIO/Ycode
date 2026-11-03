import AppKit
import YcodeIDECore

/// The app icon drawn from its geometry (`ProductIconGeometry`), so the app
/// shows it at any size even when run outside its bundle, where there is no
/// `.icns` to load.
@MainActor
public enum ProductIcon {
    public static let image: NSImage = {
        let image = NSImage(size: NSSize(width: 1024, height: 1024), flipped: true) { rect in
            draw(in: rect)
            return true
        }
        image.accessibilityDescription = ProductIdentity.name
        return image
    }()

    nonisolated static func color(_ hex: String) -> NSColor {
        let v = Int(hex.dropFirst(), radix: 16) ?? 0
        return NSColor(srgbRed: CGFloat(v >> 16 & 255) / 255, green: CGFloat(v >> 8 & 255) / 255, blue: CGFloat(v & 255) / 255, alpha: 1)
    }

    /// Top-left origin: the handler's image is flipped.
    nonisolated static func draw(in rect: NSRect) {
        typealias G = ProductIconGeometry
        let k = rect.width / G.side
        func p(_ x: Double, _ y: Double) -> NSPoint { NSPoint(x: rect.minX + x * k, y: rect.minY + y * k) }
        let a = G.fieldMin, b = G.fieldMax, s = G.cornerStart, c = G.cornerControl
        let field = NSBezierPath()
        field.move(to: p(a + s, a))
        field.line(to: p(b - s, a))
        field.curve(to: p(b, a + s), controlPoint1: p(b - s + (s - c), a), controlPoint2: p(b, a + c))
        field.line(to: p(b, b - s))
        field.curve(to: p(b - s, b), controlPoint1: p(b, b - c), controlPoint2: p(b - c, b))
        field.line(to: p(a + s, b))
        field.curve(to: p(a, b - s), controlPoint1: p(a + c, b), controlPoint2: p(a, b - c))
        field.line(to: p(a, a + s))
        field.curve(to: p(a + s, a), controlPoint1: p(a, a + c), controlPoint2: p(a + c, a))
        field.close()
        // The image is flipped, so 90° runs top to bottom.
        NSGradient(starting: color(G.fieldTop), ending: color(G.fieldBottom))?.draw(in: field, angle: 90)
        func stroke(_ points: [(Double, Double)], _ hex: String) {
            let path = NSBezierPath()
            for (i, q) in points.enumerated() { if i == 0 { path.move(to: p(q.0, q.1)) } else { path.line(to: p(q.0, q.1)) } }
            path.lineWidth = G.strokeWidth * k
            path.lineCapStyle = .round
            path.lineJoinStyle = .round
            color(hex).setStroke()
            path.stroke()
        }
        stroke(G.chevron, G.chevronColor)
        stroke(G.caret, G.caretColor)
    }
}

/// Ycode ▸ About Ycode: the icon, the version, the license, the links and the
/// "not affiliated" line.
@MainActor
public final class AboutWindowController: NSWindowController {
    public static let shared = AboutWindowController()
    public static let size = NSSize(width: 380, height: 390)

    public let versionLabel = NSTextField(labelWithString: ProductIdentity.fullVersionText)
    public let linkButtons: [NSButton]

    public init() {
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: Self.size), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "About \(ProductIdentity.name)"
        window.isReleasedWhenClosed = false
        linkButtons = [("Repository", #selector(openRepository(_:))), ("License", #selector(openLicense(_:))),
                       ("Third-Party Notices", #selector(openNotices(_:)))].map { NSButton(title: $0.0, target: nil, action: $0.1) }
        super.init(window: window)
        build()
        window.center()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    private func build() {
        guard let content = window?.contentView else { return }
        let icon = NSImageView(image: ProductIcon.image)
        icon.imageScaling = .scaleProportionallyUpOrDown
        icon.setAccessibilityLabel("Ycode icon")
        NSLayoutConstraint.activate([icon.widthAnchor.constraint(equalToConstant: 112), icon.heightAnchor.constraint(equalToConstant: 112)])
        let name = NSTextField(labelWithString: ProductIdentity.name)
        name.font = .systemFont(ofSize: 24, weight: .bold)
        versionLabel.font = .systemFont(ofSize: 13)
        versionLabel.textColor = .secondaryLabelColor
        versionLabel.isSelectable = true
        func small(_ text: String) -> NSTextField {
            let l = NSTextField(wrappingLabelWithString: text)
            l.font = .systemFont(ofSize: 11)
            l.textColor = .secondaryLabelColor
            l.alignment = .center
            l.preferredMaxLayoutWidth = Self.size.width - 64
            return l
        }
        for b in linkButtons { b.target = self; b.controlSize = .regular }
        let links = NSStackView(views: linkButtons)
        links.orientation = .horizontal
        links.spacing = 8
        let column = NSStackView(views: [icon, name, versionLabel, small("\(ProductIdentity.copyright)\nReleased under the \(ProductIdentity.license)."),
                                         links, small(ProductIdentity.notAffiliated)])
        column.orientation = .vertical
        column.alignment = .centerX
        column.spacing = 8
        column.setCustomSpacing(16, after: versionLabel)
        column.setCustomSpacing(16, after: links)
        column.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(column)
        NSLayoutConstraint.activate([
            column.topAnchor.constraint(equalTo: content.topAnchor, constant: 24),
            column.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 24),
            column.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -24),
        ])
    }

    @objc func openRepository(_ sender: Any?) { AppCommands.open(ProductIdentity.repositoryURL) }
    @objc func openLicense(_ sender: Any?) { AppCommands.open(ProductIdentity.licenseURL) }
    @objc func openNotices(_ sender: Any?) { AppCommands.open(ProductIdentity.noticesURL) }
}
