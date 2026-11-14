import AppKit
import YcodeIDECore

/// The file glyphs on the macOS IDE (council round 9, rows 208–213;
/// `FileGlyphs`): Ycode's outlines of the languages' line-art logos, its
/// JSON glyph and its folder, drawn as template images that their views
/// tint (the type's tint, white on a focused selection), and the Ycode
/// mark on the project's row. The Linux IDE draws the same outlines
/// (`ycode-ide/NavigatorRowIcons.swift`).
@MainActor
enum NavigatorRowImages {
    private static var cache: [String: NSImage] = [:]

    /// The navigator's image of an icon (nil: a system symbol, drawn as before).
    static func image(_ icon: NavigatorRowIcon) -> NSImage? {
        switch icon {
        case .symbol: return nil
        case .ycodeMark:
            if let i = cache["ycode.mark"] { return i }
            let side = CGFloat(FileGlyphs.navigatorBox(.ycodeMark).width)
            let image = ycodeMark(side: side)
            cache["ycode.mark"] = image
            return image
        case .logo, .json, .markdown, .folder, .image:
            return glyph(icon, box: FileGlyphs.navigatorBox(icon))
        }
    }

    /// A glyph as a template image of `box` points (nil: not one of Ycode's
    /// outlines).
    static func glyph(_ icon: NavigatorRowIcon, box: FileGlyphs.Size) -> NSImage? {
        let key = "\(icon)@\(box.width)x\(box.height)"
        if let i = cache[key] { return i }
        let jumpBar = box == FileGlyphs.jumpBarBox(icon)
        guard let d = jumpBar ? FileGlyphs.jumpBarDrawing(icon) : FileGlyphs.drawing(icon, in: box) else { return nil }
        let image = templateImage(d)
        image.accessibilityDescription = description(icon)
        cache[key] = image
        return image
    }

    /// The icon's accessibility description ("swift", "JSON", "folder").
    static func description(_ icon: NavigatorRowIcon) -> String {
        switch icon {
        case .logo(let name): name
        case .json: "JSON"
        case .markdown: "Markdown"
        case .folder: "folder"
        case .ycodeMark: "Ycode project"
        case .image: "image"
        case .symbol(let s): s
        }
    }

    /// A drawing as a template image (black ink; the view tints it).
    static func templateImage(_ d: GlyphDrawing) -> NSImage {
        let image = NSImage(size: NSSize(width: d.width, height: d.height), flipped: true) { _ in
            fill(d, color: .black)
            return true
        }
        image.isTemplate = true
        return image
    }

    /// Fills and strokes a drawing's paths in `color`, its box at the
    /// origin of the current (flipped) context.
    static func fill(_ d: GlyphDrawing, color: NSColor, offset: NSPoint = .zero) {
        color.set()
        for p in d.paths {
            let b = bezier(p, offset: offset)
            if p.fills {
                b.windingRule = p.evenOdd ? .evenOdd : .nonZero
                b.fill()
            }
            if p.strokeWidth > 0 {
                b.lineWidth = CGFloat(p.strokeWidth)
                b.lineCapStyle = .round
                b.lineJoinStyle = .round
                b.stroke()
            }
        }
    }

    static func bezier(_ p: GlyphPath, offset: NSPoint = .zero) -> NSBezierPath {
        let b = NSBezierPath()
        func q(_ x: Double, _ y: Double) -> NSPoint { NSPoint(x: CGFloat(x) + offset.x, y: CGFloat(y) + offset.y) }
        for e in p.elements {
            switch e {
            case let .move(x, y): b.move(to: q(x, y))
            case let .line(x, y): b.line(to: q(x, y))
            case let .curve(a, c, d, e, x, y): b.curve(to: q(x, y), controlPoint1: q(a, c), controlPoint2: q(d, e))
            case .close: b.close()
            }
        }
        return b
    }

    /// A tint as a colour that follows the appearance (one object per
    /// tint, so the same tint compares equal).
    nonisolated static func color(_ g: GlyphColor) -> NSColor {
        colorLock.lock()
        defer { colorLock.unlock() }
        if let c = colorCache[g] { return c }
        let c = NSColor(name: nil) { a in
            let c = g.rgb(dark: a.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua)
            return NSColor(srgbRed: CGFloat(c.red), green: CGFloat(c.green), blue: CGFloat(c.blue), alpha: 1)
        }
        colorCache[g] = c
        return c
    }

    nonisolated(unsafe) private static var colorCache: [GlyphColor: NSColor] = [:]
    nonisolated private static let colorLock = NSLock()

    /// A file's glyph image and tint wherever a file is listed (the jump
    /// bar, the merge sheet, Open Quickly), at `box` points: nil for a
    /// file Ycode draws with a symbol.
    static func fileGlyph(_ name: String, box: FileGlyphs.Size) -> (image: NSImage, tint: NSColor)? {
        let icon = NavigatorRowIcon.ofFile(name)
        guard icon.isGlyph, let image = glyph(icon, box: box) else { return nil }
        let t = WorkspaceChrome.iconTint(kind: .file, name: name)
        return (image, FileGlyphs.tint(t).map(color) ?? .controlAccentColor)
    }

    /// The small master of the app icon (`ProductIconSmallGeometry`) at `side` points.
    static func ycodeMark(side: CGFloat) -> NSImage {
        let image = NSImage(size: NSSize(width: side, height: side), flipped: true) { _ in
            typealias G = ProductIconSmallGeometry
            let k = side / CGFloat(G.side)
            func p(_ q: (Double, Double)) -> NSPoint { NSPoint(x: CGFloat(q.0) * k, y: CGFloat(q.1) * k) }
            let a = G.fieldMin, b = G.fieldMax, s = G.cornerStart, c = G.cornerControl
            let field = NSBezierPath()
            field.move(to: p((a + s, a)))
            field.line(to: p((b - s, a)))
            field.curve(to: p((b, a + s)), controlPoint1: p((b - c, a)), controlPoint2: p((b, a + c)))
            field.line(to: p((b, b - s)))
            field.curve(to: p((b - s, b)), controlPoint1: p((b, b - c)), controlPoint2: p((b - c, b)))
            field.line(to: p((a + s, b)))
            field.curve(to: p((a, b - s)), controlPoint1: p((a + c, b)), controlPoint2: p((a, b - c)))
            field.line(to: p((a, a + s)))
            field.curve(to: p((a + s, a)), controlPoint1: p((a, a + c)), controlPoint2: p((a + c, a)))
            field.close()
            NSGradient(starting: color(G.fieldTop), ending: color(G.fieldBottom))?.draw(in: field, angle: 90)
            for (points, hex) in [(G.chevron, G.chevronColor), (G.caret, G.caretColor)] {
                let line = NSBezierPath()
                line.move(to: p(points[0]))
                for q in points.dropFirst() { line.line(to: p(q)) }
                line.lineWidth = CGFloat(G.strokeWidth) * k
                line.lineCapStyle = .round
                line.lineJoinStyle = .round
                color(hex).setStroke()
                line.stroke()
            }
            return true
        }
        image.accessibilityDescription = "Ycode project"
        return image
    }

    static func color(_ hex: String) -> NSColor {
        let v = Int(hex.dropFirst(), radix: 16) ?? 0
        return NSColor(srgbRed: CGFloat(v >> 16 & 255) / 255, green: CGFloat(v >> 8 & 255) / 255, blue: CGFloat(v & 255) / 255, alpha: 1)
    }
}

/// The navigator selector's own glyphs (`SelectorGlyphs`, row 192), as
/// template images the selector tints as it tints the symbols.
@MainActor
enum SelectorGlyphImages {
    static func image(forSymbol symbol: String, description: String) -> NSImage? {
        guard let parts = SelectorGlyphs.parts(forSymbol: symbol) else { return nil }
        let image = NSImage(size: NSSize(width: SelectorGlyphs.width, height: SelectorGlyphs.height), flipped: true) { _ in
            NSColor.black.set()
            for part in parts {
                switch part {
                case let .roundedRect(x, y, w, h, r):
                    let p = NSBezierPath(roundedRect: NSRect(x: x, y: y, width: w, height: h), xRadius: r, yRadius: r)
                    p.lineWidth = SelectorGlyphs.lineWidth
                    p.stroke()
                case let .lines(points, closed):
                    let p = NSBezierPath()
                    p.move(to: NSPoint(x: points[0].x, y: points[0].y))
                    for q in points.dropFirst() { p.line(to: NSPoint(x: q.x, y: q.y)) }
                    if closed { p.close() }
                    p.lineWidth = SelectorGlyphs.lineWidth
                    p.lineCapStyle = .round
                    p.lineJoinStyle = .round
                    p.stroke()
                case let .dot(x, y, r):
                    NSBezierPath(ovalIn: NSRect(x: x - r, y: y - r, width: 2 * r, height: 2 * r)).fill()
                }
            }
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = description
        return image
    }
}

/// A file glyph's view outside the navigator (Open Quickly's result row):
/// the type's tint, white while its row is selected (council round 9,
/// row 211: #FFFFFF on the blue row). Drawn without vibrancy, so the
/// colour on screen is the tint given.
final class FileGlyphIconView: NSImageView {
    var tint: NSColor? { didSet { applyTint() } }
    /// The view's row is selected (the glyph turns white).
    var isOnSelection = false { didSet { applyTint() } }

    convenience init(fileName: String, box: FileGlyphs.Size) {
        self.init(frame: NSRect(x: 0, y: 0, width: box.width, height: box.height))
        show(fileName: fileName, box: box)
    }

    /// Shows a file's glyph at `box` points in its type's tint (a reused
    /// row's view): a file without one of Ycode's glyphs its symbol, in the
    /// secondary label colour.
    func show(fileName: String, box: FileGlyphs.Size) {
        let g = NavigatorRowImages.fileGlyph(fileName, box: box)
        image = g?.image ?? NSImage(systemSymbolName: WorkspaceChrome.fileSymbol(fileName), accessibilityDescription: nil) ?? NSImage()
        imageScaling = g == nil ? .scaleProportionallyUpOrDown : .scaleNone
        tint = g?.tint ?? .secondaryLabelColor
    }

    override var allowsVibrancy: Bool { false }

    private func applyTint() { contentTintColor = isOnSelection ? .white : tint }
}
