import AppKit

/// The comparison (code review) editor: HEAD on the left, the working copy
/// on the right, rows aligned, removed lines red, added green, changed
/// both. See `specs/ide/comparison.md`.
@MainActor
public final class ComparisonView: NSView, NSTextViewDelegate {
    public let leftView = NSTextView()
    public let rightView = NSTextView()
    let leftScroll = NSScrollView()
    let rightScroll = NSScrollView()
    let leftTitle = NSTextField(labelWithString: "")
    let rightTitle = NSTextField(labelWithString: "")
    public private(set) var rows: [LineDiff.Row] = []
    /// reference-ui-4.md §15.3: the working copy on the left, the
    /// comparison source on the right (false = the older layout).
    public var workingCopyOnLeft = true
    /// The band of ribbons joining change regions across the columns.
    let ribbons = RibbonView()
    /// Ribbon regions in row units (tests).
    public var ribbonChanges: [ReviewChange] { ribbons.changes }
    /// Markers on the side without lines (tests).
    var insertionMarkers: [RibbonView.InsertionMarker] { ribbons.insertionMarkers }
    /// Set while the working-copy column is editable; receives the edited
    /// file text (line numbers and filler rows removed).
    public var onWorkingCopyEdit: ((String) -> Void)? {
        didSet { workingView.isEditable = onWorkingCopyEdit != nil; workingView.isRichText = onWorkingCopyEdit == nil }
    }
    /// The column showing the working copy.
    public var workingView: NSTextView { workingCopyOnLeft ? leftView : rightView }
    private var lastOld = "", lastOldTitle = "", lastNewTitle = ""

    public override init(frame: NSRect) {
        super.init(frame: frame)
        for (tv, sv) in [(leftView, leftScroll), (rightView, rightScroll)] {
            tv.isEditable = false
            tv.isRichText = true
            tv.font = Theme.font
            tv.autoresizingMask = [.width]
            tv.isVerticallyResizable = true
            tv.textContainerInset = NSSize(width: 4, height: 4)
            sv.documentView = tv
            sv.hasVerticalScroller = true
            sv.drawsBackground = true
        }
        for t in [leftTitle, rightTitle] {
            t.font = .boldSystemFont(ofSize: 11)
            t.textColor = .secondaryLabelColor
        }
        let split = NSStackView()
        split.orientation = .horizontal
        split.spacing = 0
        for (title, scroll) in [(leftTitle, leftScroll), (rightTitle, rightScroll)] {
            let column = NSStackView(views: [title, scroll])
            column.orientation = .vertical
            column.alignment = .leading
            column.spacing = 2
            column.edgeInsets = NSEdgeInsets(top: 4, left: 0, bottom: 0, right: 0)
            scroll.widthAnchor.constraint(equalTo: column.widthAnchor).isActive = true
            split.addArrangedSubview(column)
            if title === leftTitle {
                ribbons.widthAnchor.constraint(equalToConstant: 28).isActive = true
                split.addArrangedSubview(ribbons)
            }
        }
        split.translatesAutoresizingMaskIntoConstraints = false
        addSubview(split)
        NSLayoutConstraint.activate([
            split.topAnchor.constraint(equalTo: topAnchor), split.bottomAnchor.constraint(equalTo: bottomAnchor),
            split.leadingAnchor.constraint(equalTo: leadingAnchor), split.trailingAnchor.constraint(equalTo: trailingAnchor),
            leftScroll.widthAnchor.constraint(equalTo: rightScroll.widthAnchor),
        ])
        // Scroll both sides together, whichever side scrolls.
        for (from, to) in [(leftScroll, rightScroll), (rightScroll, leftScroll)] {
            from.contentView.postsBoundsChangedNotifications = true
            NotificationCenter.default.addObserver(forName: NSView.boundsDidChangeNotification, object: from.contentView, queue: .main) { [weak self, weak from, weak to] _ in
                MainActor.assumeIsolated {
                    guard let from, let to, to.contentView.bounds.origin != from.contentView.bounds.origin else { return }
                    to.contentView.scroll(to: from.contentView.bounds.origin)
                    to.reflectScrolledClipView(to.contentView)
                    self?.ribbons.needsDisplay = true
                }
            }
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    /// The file text in an edited working-copy column: each row is a
    /// six-character number column then the line; filler rows (blank
    /// number, no text) are dropped; typed new lines keep their text.
    public static func fileText(fromColumn column: String) -> String {
        var lines = column.components(separatedBy: "\n")
        if lines.last == "" { lines.removeLast() }
        var out: [String] = []
        for l in lines {
            if l == "      " { continue }
            let prefix = l.prefix(6)
            if prefix.count == 6, prefix.hasSuffix("  "), Int(prefix.trimmingCharacters(in: .whitespaces)) != nil {
                out.append(String(l.dropFirst(6)))
            } else {
                out.append(l)
            }
        }
        return out.joined(separator: "\n") + "\n"
    }

    public func textDidChange(_ n: Notification) {
        guard let edit = onWorkingCopyEdit, (n.object as? NSTextView) === workingView else { return }
        let text = Self.fileText(fromColumn: workingView.string)
        edit(text)
        // Re-diff, keeping the caret near where it was.
        let caret = workingView.selectedRange()
        let handler = onWorkingCopyEdit
        show(old: lastOld, new: text, oldTitle: lastOldTitle, newTitle: lastNewTitle)
        onWorkingCopyEdit = handler
        let len = (workingView.string as NSString).length
        workingView.setSelectedRange(NSRange(location: min(caret.location, len), length: 0))
    }

    public func show(old: String, new: String, oldTitle: String, newTitle: String) {
        lastOld = old; lastOldTitle = oldTitle; lastNewTitle = newTitle
        leftView.delegate = self
        rightView.delegate = self
        rows = LineDiff.sideBySide(LineDiff.diff(LineDiff.lines(old), LineDiff.lines(new)))
        leftTitle.stringValue = workingCopyOnLeft ? newTitle : oldTitle
        rightTitle.stringValue = workingCopyOnLeft ? oldTitle : newTitle
        let left = NSMutableAttributedString(), right = NSMutableAttributedString()
        func append(_ to: NSMutableAttributedString, _ side: (number: Int, text: String)?, tint: NSColor?) {
            let number = side.map { String(format: "%4d  ", $0.number) } ?? "      "
            var attrs: [NSAttributedString.Key: Any] = [.font: Theme.font, .foregroundColor: NSColor.textColor]
            if let tint { attrs[.backgroundColor] = tint }
            to.append(NSAttributedString(string: number, attributes: [.font: Theme.gutterFont, .foregroundColor: NSColor.tertiaryLabelColor]))
            to.append(NSAttributedString(string: (side?.text ?? "") + "\n", attributes: side == nil ? [.font: Theme.font, .backgroundColor: NSColor.quaternaryLabelColor.withAlphaComponent(0.06)] : attrs))
        }
        let red = NSColor.systemRed.withAlphaComponent(0.18), green = NSColor.systemGreen.withAlphaComponent(0.18)
        for r in rows {
            switch r.kind {
            case .same: append(left, r.left, tint: nil); append(right, r.right, tint: nil)
            case .changed: append(left, r.left, tint: red); append(right, r.right, tint: green)
            case .removed: append(left, r.left, tint: red); append(right, nil, tint: nil)
            case .added: append(left, nil, tint: nil); append(right, r.right, tint: green)
            }
        }
        leftView.textStorage?.setAttributedString(workingCopyOnLeft ? right : left)
        rightView.textStorage?.setAttributedString(workingCopyOnLeft ? left : right)
        // Ribbons in row units: rows are aligned, so a change spans the same
        // rows on both sides; each side's band covers its non-filler rows.
        var bands: [ReviewChange] = []
        var i = 0
        while i < rows.count {
            guard rows[i].kind != .same else { i += 1; continue }
            var j = i
            while j < rows.count, rows[j].kind != .same { j += 1 }
            let group = rows[i..<j]
            let work = group.filter { $0.right != nil }.count, src = group.filter { $0.left != nil }.count
            let kind: LineDiff.Row.Kind = group.allSatisfy { $0.kind == .added } ? .added : (group.allSatisfy { $0.kind == .removed } ? .removed : .changed)
            bands.append(ReviewChange(kind: kind, newStart: i + 1, newCount: workingCopyOnLeft ? work : src,
                                      oldStart: i + 1, oldCount: workingCopyOnLeft ? src : work))
            i = j
        }
        let lh = NSLayoutManager().defaultLineHeight(for: Theme.font)
        ribbons.lineHeight = lh
        ribbons.leftY = { [weak self] row in
            guard let self else { return 0 }
            return self.ribbons.convert(NSPoint(x: 0, y: CGFloat(row - 1) * lh + 4), from: self.leftView).y
        }
        ribbons.rightY = { [weak self] row in
            guard let self else { return 0 }
            return self.ribbons.convert(NSPoint(x: 0, y: CGFloat(row - 1) * lh + 4), from: self.rightView).y
        }
        ribbons.changes = bands
    }
}
