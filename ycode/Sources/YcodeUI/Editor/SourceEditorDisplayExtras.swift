import AppKit

/// Editing ▸ Display rows drawn by the source editor
/// (`specs/ide/reference-ui-5.md` §9.3): MARK separators, the condition
/// after `#endif`, dimmed inactive code, faded comment delimiters, the code
/// structure headers and the editor overscroll; and General ▸ Issue
/// presentation (inline or minimized).
@MainActor
final class EditorDisplayState {
    var markLines: [Int] = []
    var endifConditions: [Int: String] = [:]
    var inactive: [ClosedRange<Int>] = []
    /// Overscroll as a fraction of the visible height.
    var overscroll: CGFloat = 0
    /// The height last set and the overscroll it holds.
    var lastHeight: CGFloat = -1
    var lastExtra: CGFloat = 0
    /// Issue presentation ▸ Show Minimized: an icon only.
    var minimizedIssues = false
    var header: StructureHeaderView?
    var scrollObserver: NSObjectProtocol?
    var pending: DispatchWorkItem?
}

/// The sticky header at the top of the editor: the lines that open the
/// declarations enclosing the first visible line.
final class StructureHeaderView: NSView {
    let label = NSTextField(labelWithString: "")
    private(set) var lines: [String] = []

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        label.maximumNumberOfLines = 0
        label.lineBreakMode = .byTruncatingTail
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4), label.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor),
            label.topAnchor.constraint(equalTo: topAnchor, constant: 1),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func show(_ lines: [String]) {
        self.lines = lines
        isHidden = lines.isEmpty
        label.attributedStringValue = NSAttributedString(string: lines.joined(separator: "\n"),
                                                         attributes: [.font: Theme.font, .foregroundColor: Theme.textColor])
        layer?.backgroundColor = Theme.backgroundColor.cgColor
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        NSColor.separatorColor.setFill()
        NSRect(x: 0, y: 0, width: bounds.width, height: 1).fill()
    }
}

extension SourceTextView {
    /// MARK separators and #endif conditions, behind the text.
    func drawDisplayExtras(in rect: NSRect) {
        let d = displayState
        if !d.markLines.isEmpty {
            NSColor.separatorColor.setFill()
            for l in d.markLines {
                guard let r = lineRect(l), r.insetBy(dx: 0, dy: -2).intersects(rect) else { continue }
                NSRect(x: textContainerOrigin.x, y: r.minY, width: r.width - textContainerOrigin.x, height: 1).fill()
            }
        }
        if !d.endifConditions.isEmpty {
            let ns = string as NSString
            let attrs: [NSAttributedString.Key: Any] = [.font: Theme.font, .foregroundColor: NSColor.tertiaryLabelColor]
            for (l, cond) in d.endifConditions {
                guard let lr = lineIndex.range(ofLine: l), let r = lineRect(l), r.intersects(rect) else { continue }
                var e = NSMaxRange(lr)
                while e > lr.location, [10, 13].contains(ns.character(at: e - 1)) { e -= 1 }
                guard let end = segmentRects(NSRange(location: max(lr.location, e - 1), length: e > lr.location ? 1 : 0)).first else { continue }
                (" " + cond as NSString).draw(at: NSPoint(x: end.maxX + 4, y: end.minY), withAttributes: attrs)
            }
        }
    }

    /// The height the view needs with the overscroll added: the blank
    /// space after the last line, once the text is taller than the view.
    /// The text view proposes the height its text needs; a proposal equal
    /// to the height set last (a resize that keeps the height) already
    /// holds the overscroll, which is taken out first.
    func heightWithOverscroll(_ proposed: CGFloat) -> CGFloat {
        let d = displayState
        let base = proposed == d.lastHeight ? proposed - d.lastExtra : proposed
        let visible = enclosingScrollView?.contentSize.height ?? 0
        let extra = visible > 0 && base > visible ? (visible * d.overscroll).rounded() : 0
        d.lastExtra = extra
        d.lastHeight = base + extra
        return base + extra
    }
}

extension SourceEditorController {
    var displayState: EditorDisplayState { textView.displayState }

    /// Applies the Display and Issue presentation settings.
    func applyDisplayPreferences() {
        let p = Preferences.shared
        let d = displayState
        d.minimizedIssues = p.issuePresentation == .minimized
        if d.overscroll != p.editorOverscroll.fraction {
            d.overscroll = p.editorOverscroll.fraction
            textView.setFrameSize(textView.frame.size)
        }
        if d.scrollObserver == nil {
            scrollView.contentView.postsBoundsChangedNotifications = true
            d.scrollObserver = NotificationCenter.default.addObserver(forName: NSView.boundsDidChangeNotification, object: scrollView.contentView,
                                                                      queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.updateStructureHeader() }
            }
        }
        updateDisplayExtras()
    }

    /// Recomputes the text-derived extras (after opening, editing or a
    /// settings change). Large files catch up after a short pause.
    func updateDisplayExtras() {
        let d = displayState
        d.pending?.cancel()
        d.pending = nil
        if textView.lineIndex.lineCount > Self.lazyThreshold {
            let work = DispatchWorkItem { [weak self] in self?.computeDisplayExtras() }
            d.pending = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: work)
        } else {
            computeDisplayExtras()
        }
    }

    func computeDisplayExtras() {
        let p = Preferences.shared
        let d = displayState
        d.pending = nil
        let text = textView.string
        let code = fileURL != nil && displayLanguage != .plain
        d.markLines = code && p.showMarkSeparators ? EditorDisplayModel.markSeparatorLines(in: text) : []
        d.endifConditions = code && p.showEndifConditions ? EditorDisplayModel.endifConditions(in: text) : [:]
        d.inactive = code && p.dimInactiveCode ? EditorDisplayModel.inactiveLines(in: text) : []
        applyRenderingColors(code: code)
        updateStructureHeader()
        textView.needsDisplay = true
    }

    /// Dimmed inactive branches and faded delimiters, as rendering colors
    /// over the syntax colors (the text storage is left alone).
    func applyRenderingColors(code: Bool) {
        guard let tlm = textView.textLayoutManager, let tcm = tlm.textContentManager, let storage = textView.textStorage else { return }
        tlm.removeRenderingAttribute(.foregroundColor, for: tlm.documentRange)
        guard code else { return }
        let p = Preferences.shared
        let ns = storage.string as NSString
        func fade(_ r: NSRange, alpha: CGFloat) {
            guard NSMaxRange(r) <= storage.length, r.length > 0 else { return }
            storage.enumerateAttribute(.foregroundColor, in: r) { v, sub, _ in
                let c = (v as? NSColor) ?? Theme.textColor
                guard let start = tcm.location(tcm.documentRange.location, offsetBy: sub.location),
                      let end = tcm.location(start, offsetBy: sub.length), let tr = NSTextRange(location: start, end: end) else { return }
                tlm.addRenderingAttribute(.foregroundColor, value: c.withAlphaComponent(alpha), for: tr)
            }
        }
        if p.fadeDocCommentDelimiters || p.fadeCommentDelimiters {
            let tokens = SourceTokenizer(language: displayLanguage).tokens(in: storage.string)
            let delims = EditorDisplayModel.commentDelimiters(tokens, in: ns)
            if p.fadeDocCommentDelimiters { delims.doc.forEach { fade($0, alpha: 0.45) } }
            if p.fadeCommentDelimiters { delims.plain.forEach { fade($0, alpha: 0.45) } }
        }
        for r in displayState.inactive {
            guard let a = textView.lineIndex.range(ofLine: r.lowerBound), let b = textView.lineIndex.range(ofLine: r.upperBound) else { continue }
            fade(NSRange(location: a.location, length: NSMaxRange(b) - a.location), alpha: 0.4)
        }
    }

    /// Shows or hides the code structure headers for the first visible line.
    func updateStructureHeader() {
        let d = displayState
        guard Preferences.shared.showCodeStructureHeaders, fileURL != nil, !scrollView.isHidden else { d.header?.isHidden = true; return }
        let top = scrollView.contentView.bounds.minY
        guard top > 0 else { d.header?.isHidden = true; return }
        let offset = textView.characterIndexForInsertion(at: NSPoint(x: textView.textContainerOrigin.x + 1, y: top + 1))
        var topLine = textView.lineIndex.line(at: offset)
        let ns = textView.string as NSString
        func text(_ l: Int) -> String { textView.lineIndex.range(ofLine: l).map { ns.substring(with: $0) } ?? "" }
        var lines = EditorDisplayModel.structureHeaderLines(foldRegions, topLine: topLine, lineText: text)
        // The header covers the first lines: look below it once.
        if !lines.isEmpty { topLine += lines.count; lines = EditorDisplayModel.structureHeaderLines(foldRegions, topLine: topLine, lineText: text) }
        let header = d.header ?? {
            let h = StructureHeaderView(frame: .zero)
            scrollView.addFloatingSubview(h, for: .vertical)
            d.header = h
            return h
        }()
        header.show(lines.map { text($0).trimmingCharacters(in: .newlines) })
        let lineHeight = ceil(Theme.font.ascender - Theme.font.descender + Theme.font.leading)
        // A vertical floating subview: its y is fixed at the top of the clip view.
        let clip = scrollView.contentView
        header.frame = NSRect(x: 0, y: clip.frame.minY, width: clip.frame.width, height: lineHeight * CGFloat(lines.count) + 3)
    }

    /// The code structure header lines shown (tests).
    public var structureHeaderLines: [String] { displayState.header.map { $0.isHidden ? [] : $0.lines } ?? [] }
    /// Lines with a MARK separator, `#endif` conditions and inactive
    /// ranges, as drawn (tests).
    public var markSeparatorLines: [Int] { displayState.markLines }
    public var endifConditions: [Int: String] { displayState.endifConditions }
    public var inactiveLineRanges: [ClosedRange<Int>] { displayState.inactive }
    public var showsMinimizedIssues: Bool { displayState.minimizedIssues }
    /// The rendering color drawn at a character, if one overrides the
    /// syntax color (tests).
    public func renderingColor(at offset: Int) -> NSColor? {
        guard let tlm = textView.textLayoutManager, let tcm = tlm.textContentManager,
              let loc = tcm.location(tcm.documentRange.location, offsetBy: offset) else { return nil }
        var found: NSColor?
        tlm.enumerateRenderingAttributes(from: loc, reverse: false) { _, attrs, range in
            if range.location.compare(loc) != .orderedDescending { found = attrs[.foregroundColor] as? NSColor }
            return false
        }
        return found
    }

    /// Convert existing files on save: line endings become LF (the file is
    /// always written as UTF-8). One undo group.
    func convertLineEndings() {
        let s = textView.string
        guard s.contains("\r") else { return }
        let converted = s.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        let all = NSRange(location: 0, length: (s as NSString).length)
        guard textView.shouldChangeText(in: all, replacementString: converted) else { return }
        textView.replaceCharacters(in: all, with: converted)
        textView.didChangeText()
    }
}
