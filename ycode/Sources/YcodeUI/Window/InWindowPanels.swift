import AppKit
import YcodeIDECore

// The in-window panels of `specs/ide/popovers.md` §5, §10 and §11.2 on
// macOS: glass capsules centred on the window under its toolbar (Jump to
// Line, Quick Actions, Quick New Project), a borderless field after a
// magnifier (no focus ring), results growing downward. Each is a child
// panel of the workspace window that never becomes main, so the workspace
// keeps its active look (§8, P-031); a click elsewhere closes it.

/// One result row of a palette.
public struct PaletteRow: Equatable, Sendable {
    public var title: String
    public var detail: String
    public var trailing: String
    public var symbol: String?

    public init(title: String, detail: String = "", trailing: String = "", symbol: String? = nil) {
        self.title = title
        self.detail = detail
        self.trailing = trailing
        self.symbol = symbol
    }
}

/// A capsule with a field and, under it, the rows for the field's text.
@MainActor
public class PaletteController: NSViewController, NSTextFieldDelegate {
    public let spec: InWindowPanel
    public let field = NSTextField()
    public let glyph = NSImageView()
    public let resultsView = PaletteRowsView()
    /// The rows for a query.
    let rows: (String) -> [PaletteRow]
    /// Two-line rows (Quick New Project) are this tall; one-line rows
    /// `InWindowPanel.resultRowHeight`.
    let rowHeight: Double
    /// Return with the field's text and the selected row (nil: none).
    public var onSubmit: ((String, Int?) -> Void)?
    public var onCancel: (() -> Void)?
    /// The panel's new height (it grows downward with results).
    public var onResize: ((CGFloat) -> Void)?
    public var shown: [PaletteRow] { resultsView.rows }
    public var selected: Int { resultsView.selected }

    public init(_ spec: InWindowPanel, symbol: String = "magnifyingglass", rowHeight: Double = InWindowPanel.resultRowHeight,
                rows: @escaping (String) -> [PaletteRow] = { _ in [] }) {
        self.spec = spec
        self.rows = rows
        self.rowHeight = rowHeight
        super.init(nibName: nil, bundle: nil)
        glyph.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: CGFloat(InWindowPanel.magnifierSize), weight: .regular))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    public override func loadView() {
        let root = FlippedView(frame: NSRect(x: 0, y: 0, width: spec.width, height: spec.height))
        let s = CGFloat(InWindowPanel.magnifierSize)
        glyph.frame = NSRect(x: CGFloat(InWindowPanel.magnifierX), y: (CGFloat(spec.height) - s) / 2, width: s, height: s)
        glyph.contentTintColor = .secondaryLabelColor
        // §5: a borderless search field, no focus ring, the caret only.
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = .systemFont(ofSize: CGFloat(InWindowPanel.fieldFontSize))
        field.placeholderString = spec.placeholder
        field.delegate = self
        field.cell?.usesSingleLineMode = true
        let fh = field.intrinsicContentSize.height
        let ff = spec.fieldFrame
        field.frame = NSRect(x: ff.minX, y: ff.minY + (ff.height - fh) / 2, width: ff.width, height: fh)
        field.setAccessibilityIdentifier("palette.field")
        resultsView.rowHeight = CGFloat(rowHeight)
        resultsView.onClick = { [weak self] i in
            self?.resultsView.selected = i
            self?.submit()
        }
        root.addSubview(glyph)
        root.addSubview(field)
        root.addSubview(resultsView)
        view = root
        reload()
    }

    /// The panel's height for the current rows.
    public var panelHeight: CGFloat {
        let n = resultsView.rows.count
        guard n > 0 else { return CGFloat(spec.height) }
        return CGFloat(spec.height + InWindowPanel.resultInset * 2 + Double(min(n, InWindowPanel.maximumVisibleRows)) * rowHeight)
    }

    func reload() {
        resultsView.rows = rows(field.stringValue)
        resultsView.selected = 0
        let h = panelHeight
        view.setFrameSize(NSSize(width: CGFloat(spec.width), height: h))
        resultsView.frame = NSRect(x: CGFloat(InWindowPanel.resultInset), y: CGFloat(spec.height + InWindowPanel.resultInset),
                                   width: CGFloat(spec.width - 2 * InWindowPanel.resultInset),
                                   height: max(0, h - CGFloat(spec.height + 2 * InWindowPanel.resultInset)))
        resultsView.isHidden = resultsView.rows.isEmpty
        preferredContentSize = view.frame.size
        onResize?(h)
    }

    /// Types `text` into the field.
    public func setQuery(_ text: String) {
        _ = view
        field.stringValue = text
        reload()
    }

    public func controlTextDidChange(_ obj: Notification) { reload() }

    public func control(_ control: NSControl, textView: NSTextView, doCommandBy sel: Selector) -> Bool {
        switch sel {
        case #selector(NSResponder.moveDown(_:)): move(1); return true
        case #selector(NSResponder.moveUp(_:)): move(-1); return true
        case #selector(NSResponder.insertNewline(_:)): submit(); return true
        case #selector(NSResponder.cancelOperation(_:)): onCancel?(); return true
        default: return false
        }
    }

    public func move(_ d: Int) {
        guard !resultsView.rows.isEmpty else { return }
        resultsView.selected = min(max(resultsView.selected + d, 0), resultsView.rows.count - 1)
    }

    public func submit() {
        onSubmit?(field.stringValue, resultsView.rows.isEmpty ? nil : resultsView.selected)
    }
}

/// A palette's rows: a glyph, the title (and a second line, or a detail
/// column and a shortcut), the selected one on an accent rounded
/// rectangle.
@MainActor
public final class PaletteRowsView: NSView {
    public var rows: [PaletteRow] = [] { didSet { needsDisplay = true } }
    public var selected = 0 { didSet { needsDisplay = true } }
    var rowHeight = CGFloat(InWindowPanel.resultRowHeight)
    var onClick: ((Int) -> Void)?

    public override var isFlipped: Bool { true }

    public override func mouseUp(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        let i = Int(p.y / rowHeight)
        if rows.indices.contains(i) { onClick?(i) }
    }

    public override func draw(_ dirtyRect: NSRect) {
        let twoLines = rowHeight > 40
        for (i, r) in rows.enumerated() {
            let f = NSRect(x: 0, y: CGFloat(i) * rowHeight, width: bounds.width, height: rowHeight)
            guard f.intersects(dirtyRect) else { continue }
            let lit = i == selected
            if lit {
                NSColor.controlAccentColor.setFill()
                NSBezierPath(roundedRect: f, xRadius: twoLines ? CGFloat(QuickNewProject.rowCornerRadius) : 8,
                             yRadius: twoLines ? CGFloat(QuickNewProject.rowCornerRadius) : 8).fill()
            }
            let ink: NSColor = lit ? .white : .labelColor, dim: NSColor = lit ? .white.withAlphaComponent(0.85) : .secondaryLabelColor
            var x: CGFloat = 14
            if let symbol = r.symbol, let image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(pointSize: twoLines ? 20 : 13, weight: .regular)) {
                let s = image.size
                let box = NSRect(x: x, y: f.midY - s.height / 2, width: s.width, height: s.height)
                let tinted = NSImage(size: s, flipped: false) { rect in
                    image.draw(in: rect)
                    ink.set()
                    rect.fill(using: .sourceAtop)
                    return true
                }
                tinted.draw(in: box, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
                x += twoLines ? 40 : 24
            }
            func text(_ s: String, _ size: CGFloat, _ color: NSColor, _ weight: NSFont.Weight, x: CGFloat, y: CGFloat, width: CGFloat) {
                NSAttributedString(string: s, attributes: [.font: NSFont.systemFont(ofSize: size, weight: weight), .foregroundColor: color])
                    .draw(with: NSRect(x: x, y: y, width: max(0, width), height: size + 6), options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
            }
            if twoLines {
                text(r.title, 15, ink, .semibold, x: x, y: f.minY + 9, width: f.width - x - 14)
                text(r.detail, 12, dim, .regular, x: x, y: f.minY + 30, width: f.width - x - 14)
            } else {
                let y = f.midY - 9
                text(r.title, 14, ink, .regular, x: x, y: y, width: f.width * 0.55 - x)
                text(r.detail, 12, dim, .regular, x: f.width * 0.55, y: y + 1, width: f.width * 0.3)
                let a = NSAttributedString(string: r.trailing, attributes: [.font: NSFont.systemFont(ofSize: 12), .foregroundColor: dim])
                a.draw(at: NSPoint(x: f.maxX - 12 - a.size().width, y: y + 1))
            }
        }
    }

    public override func isAccessibilityElement() -> Bool { true }
    public override func accessibilityRole() -> NSAccessibility.Role? { .list }
    public override func accessibilityLabel() -> String? { "Results" }
}

@available(macOS 26, *)
extension GlassPanel {
    /// Shows the panel under `window`'s toolbar, centred on the window
    /// (§5): its top `spec.topBelowToolbar` below the toolbar's bottom.
    func show(over window: NSWindow, spec: InWindowPanel) {
        let toolbarBottom = window.contentView.map { $0.bounds.height - window.contentLayoutRect.height } ?? CGFloat(InWindowPanel.toolbarBottom)
        show(over: window, top: (toolbarBottom > 0 ? toolbarBottom : CGFloat(InWindowPanel.toolbarBottom)) + CGFloat(spec.topBelowToolbar))
    }
}

extension WorkspaceWindowController {
    /// Shows a palette as a glass panel over the window (on macOS 26 and
    /// later; earlier, as a sheet), wiring Escape and resizing. `fade`:
    /// Escape fades it out (Jump to Line, §5) instead of one frame.
    func present(palette c: PaletteController, fade: Bool = false) {
        _ = c.view
        guard let window, window.isVisible else { return }
        if #available(macOS 26, *) {
            let panel = GlassPanel(content: c, cornerRadius: CGFloat(c.spec.cornerRadius))
            c.onResize = { [weak panel] h in panel?.setHeightKeepingTop(h) }
            c.onCancel = { [weak panel] in
                guard let panel else { return }
                guard fade else { panel.close(); return }
                NSAnimationContext.runAnimationGroup { ctx in
                    ctx.duration = Motion.jumpToLineFadeOut
                    ctx.timingFunction = CAMediaTimingFunction(name: .easeIn)
                    panel.animator().alphaValue = 0
                }
                // Closed when the fade ends (by the clock: a window kept off
                // the displays may not report the animation's end).
                Timer.scheduledTimer(withTimeInterval: Motion.jumpToLineFadeOut, repeats: false) { [weak panel] _ in
                    MainActor.assumeIsolated { panel?.close() }
                }
            }
            let submit = c.onSubmit
            c.onSubmit = { [weak panel] text, i in
                panel?.close()
                submit?(text, i)
            }
            panel.show(over: window, spec: c.spec)
            panel.makeFirstResponder(c.field)
        } else {
            contentViewController?.presentAsSheet(c)
            c.onCancel = { [weak c] in c.map { $0.presentingViewController?.dismiss($0) } }
        }
    }

    // MARK: Jump to Line (⌘L, P-086)

    /// Navigate ▸ Jump to Line…: the 640-point capsule, "Line Number";
    /// Return jumps and closes in one frame, Escape fades it out.
    @discardableResult
    public func showJumpToLinePanel() -> PaletteController {
        let c = PaletteController(.jumpToLine)
        c.onSubmit = { [weak self] text, _ in
            guard let self, let n = JumpToLineInput.line(text, lineCount: self.editor.text.split(separator: "\n", omittingEmptySubsequences: false).count) else { NSSound.beep(); return }
            self.editor.reveal(line: n)
            self.window?.makeFirstResponder(self.editor.textView)
        }
        present(palette: c, fade: true)
        return c
    }

    // MARK: Quick New Project (⌘⇧N with a workspace open, P-180)

    /// The 640 × 355 panel over the compact picker's rows; choosing one
    /// does what the picker's row does (App makes the untitled project;
    /// Choose Template… opens the sheet).
    @discardableResult
    public func showQuickNewProject() -> PaletteController {
        let rows = QuickNewProject.rows
        let c = PaletteController(.quickNewProject, symbol: QuickNewProject.headerSymbol, rowHeight: QuickNewProject.rowHeight) { q in
            var list = QuickNewProject.list()
            list.setQuery(q)
            return list.shown.map { PaletteRow(title: $0.title, detail: $0.subtitle, symbol: $0.symbol) }
        }
        c.onSubmit = { [weak self, weak c] _, i in
            guard let i, let self, let c else { return }
            let title = c.shown[i].title
            guard let row = rows.first(where: { $0.title == title }) else { return }
            RunLoop.main.perform { MainActor.assumeIsolated { _ = self.projectPickerChose(row.index) } }
        }
        present(palette: c)
        return c
    }
}
