import AppKit
import YcodeIDECore

/// The merge sheet (`specs/ide/merge-sheet.md` §2–§9): the conflicted
/// files, the two aligned panes with the gutter's tokens and the Choose
/// menu, the commit footers with the change stepper, and Cancel and
/// Merge. It draws the core's `ConflictEditorState` (which the Linux IDE's
/// sheet draws too) and reads git off the main actor; the window's source
/// control coordinator performs Merge and Cancel.
@MainActor
public final class MergeSheetController: NSViewController, NSTextViewDelegate {
    public let repository: GitRepository
    public private(set) var state = ConflictEditorState(source: .repository)
    /// File list: Flat instead of Hierarchical.
    public private(set) var isFlat = false
    public private(set) var filterText = ""

    public let sheetView = MergeSheetView()
    public let fileList = MergeFileListView()
    public let jumpBar = MergeJumpBarView()
    public let scrollView = NSScrollView()
    public let canvas = MergeCanvasView()
    public let ruler = MergeRulerView()
    public let footer = MergeFooterView()
    public let cancelButton = MergeButton(title: MergeSheetText.cancel)
    public let mergeButton = MergeButton(title: MergeSheetText.merge)
    /// The last Choose menu shown (tests).
    public private(set) var lastChooseMenu: NSMenu?

    var onMerge: (() -> Void)?
    var onCancel: (() -> Void)?
    /// A file was marked resolved (the window reads git again).
    var onResolved: (() -> Void)?

    private var pending: [Int: Task<Void, Never>] = [:]
    private var nextPending = 0
    private var showGeneration = 0
    private let focus: String?

    public init(repository: GitRepository, focus: String? = nil) {
        self.repository = repository
        self.focus = focus
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    // MARK: View

    public override func loadView() {
        sheetView.frame = NSRect(x: 0, y: 0, width: 1352, height: 800)
        sheetView.controller = self
        canvas.controller = self
        fileList.controller = self
        jumpBar.controller = self
        footer.controller = self
        scrollView.documentView = canvas
        scrollView.hasVerticalScroller = false
        scrollView.hasHorizontalScroller = false
        scrollView.drawsBackground = false
        scrollView.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(self, selector: #selector(scrolled), name: NSView.boundsDidChangeNotification, object: scrollView.contentView)
        canvas.handEditor.delegate = self
        ruler.onClick = { [weak self] share in self?.scroll(toShare: share) }
        cancelButton.target = self
        cancelButton.action = #selector(cancel(_:))
        mergeButton.target = self
        mergeButton.action = #selector(merge(_:))
        for v in [fileList, jumpBar, scrollView, ruler, footer] as [NSView] { sheetView.box.addSubview(v) }
        for v in [sheetView.box, cancelButton, mergeButton] as [NSView] { sheetView.addSubview(v) }
        view = sheetView
        reloadFiles()
    }

    @objc func scrolled() { }

    /// Positions everything from the spec's metrics (§2–§9).
    func layoutSheet() {
        typealias M = MergeSheetMetrics
        let size = sheetView.bounds.size
        let boxF = M.contentBox(sheet: (Double(size.width), Double(size.height)))
        // Whole pixels: at 1x the box's 11.5 rounds, so rows and rules stay sharp.
        sheetView.box.frame = sheetView.backingAlignedRect(NSRect(x: boxF.x, y: boxF.y, width: boxF.width, height: boxF.height),
                                                           options: .alignAllEdgesNearest)
        let c = M.columns(boxWidth: boxF.width)
        let h = CGFloat(boxF.height)
        fileList.frame = NSRect(x: c.fileList.start, y: 1, width: c.fileList.length, height: h - 2)
        let jbH = CGFloat(M.jumpBarHeight) + 1
        jumpBar.frame = NSRect(x: c.left.start, y: 1, width: c.right.end - c.left.start, height: jbH)
        jumpBar.gutterX = CGFloat(c.gutter.start - c.left.start)
        let footerH = CGFloat(M.footerHeight) + 1
        footer.frame = NSRect(x: c.left.start, y: h - 1 - footerH, width: c.right.end - c.left.start, height: footerH)
        footer.gutterX = CGFloat(c.gutter.start - c.left.start)
        footer.rightX = CGFloat(c.right.start - c.left.start)
        let paneTop = 1 + jbH, paneH = h - 1 - footerH - paneTop
        scrollView.frame = NSRect(x: c.left.start, y: paneTop, width: c.rightText.end - c.left.start, height: paneH)
        ruler.frame = NSRect(x: c.ruler.start, y: paneTop, width: c.ruler.length, height: paneH)
        canvas.leftWidth = CGFloat(c.left.length)
        canvas.rightWidth = CGFloat(c.rightText.length)
        canvas.relayoutRows()
        let bw = mergeButton.fittingWidth(minimum: CGFloat(M.buttonWidth))
        let by = CGFloat(boxF.maxY + M.buttonGap)
        mergeButton.frame = NSRect(x: CGFloat(boxF.maxX) - bw, y: by, width: bw, height: CGFloat(M.buttonHeight))
        cancelButton.frame = NSRect(x: mergeButton.frame.minX - CGFloat(M.buttonSpacing) - CGFloat(M.buttonWidth), y: by,
                                    width: CGFloat(M.buttonWidth), height: CGFloat(M.buttonHeight))
    }

    // MARK: Loading

    /// Reads the conflicted files, the operation, the footers and every
    /// file's merge (so Merge knows when all are decided), then shows the
    /// focused or first file.
    public func reloadFiles() {
        let repo = repository
        let wanted = state.currentFile ?? focus
        let known = Set(state.files)
        track { [weak self] in
            let read = await Task.detached { () -> ([String], GitRepository.IntegrationState, (MergeSheetFooter?, MergeSheetFooter?), [String: MergeDocument]) in
                let files = repo.conflictedFiles(), integration = repo.integrationState()
                let labels = repo.conflictLabels(integration)
                let footers = MergeSheetFooter.read(repo, integration: integration, oursLabel: labels.ours, theirsLabel: labels.theirs)
                var docs: [String: MergeDocument] = [:]
                for f in files where !known.contains(f) { docs[f] = repo.mergeDocument(forConflictedFile: f) }
                return (files, integration, footers, docs)
            }.value
            guard let self else { return }
            _ = self.state.update(integration: read.1, conflicted: read.0)
            self.state.files = read.0
            self.state.leftFooter = read.2.0
            self.state.rightFooter = read.2.1
            for (f, d) in read.3 { self.state.prefetch(file: f, document: d) }
            let target = ConflictEditorState.target(wanted: wanted, in: read.0)
            if target != self.state.currentFile || self.state.document == nil {
                self.state.show(file: target, document: target.flatMap { read.3[$0] })
                if target != nil, self.state.document == nil, let t = target { await self.show(file: t) }
            }
            self.render()
        }
    }

    /// The window's latest snapshot: a file resolved elsewhere moves on.
    public func update(integration: GitRepository.IntegrationState, conflicted: [String]) {
        guard loading == nil else { return }
        if case .show(let next) = state.update(integration: integration, conflicted: conflicted) {
            track { [weak self] in await self?.show(file: next) }
            return
        }
        render()
    }

    /// Shows one conflicted file, keeping the choices made in the others.
    public func show(file: String?) async {
        let repo = repository
        guard let file else { state.show(file: nil, document: nil); render(); return }
        if state.sheetDocument(file) != nil {
            state.show(file: file, document: nil)
            render()
            return
        }
        showGeneration += 1
        let generation = showGeneration
        await track { [weak self] in
            let doc = await Task.detached { repo.mergeDocument(forConflictedFile: file) }.value
            guard let self, generation == self.showGeneration else { return }
            self.state.show(file: file, document: doc)
            self.render()
        }.value
    }

    public var loading: Task<Void, Never>? { pending.values.first }

    @discardableResult
    func track(_ body: @escaping @MainActor () async -> Void) -> Task<Void, Never> {
        nextPending += 1
        let id = nextPending
        let t = Task { @MainActor [weak self] in
            await body()
            self?.pending[id] = nil
        }
        pending[id] = t
        return t
    }

    /// Waits until no read or write runs (tests).
    public func idle() async {
        while let t = pending.values.first { await t.value }
    }

    // MARK: Changes

    /// Selects a change and scrolls it into view.
    public func selectHunk(_ h: Int?) {
        state.selectHunk(h)
        render()
        scrollToSelection()
    }

    /// The stepper's chevrons (§8).
    @objc public func nextHunk(_ sender: Any?) { state.nextHunk(); render(); scrollToSelection() }
    @objc public func previousHunk(_ sender: Any?) { state.previousHunk(); render(); scrollToSelection() }

    /// A choice for the selected change (§7): the left pane changes in one
    /// frame and the change stays selected.
    public func choose(_ choice: MergeDocument.Choice) {
        state.chooseKeepingSelection(choice)
        render()
    }

    /// The Choose menu of change `h`'s token (§7).
    public func chooseMenu(forHunk h: Int) -> NSMenu {
        let menu = NSMenu(title: "Choose")
        menu.autoenablesItems = false
        for (i, title) in MergeSheetText.chooseTitles.enumerated() {
            let item = NSMenuItem(title: title, action: #selector(chooseItem(_:)), keyEquivalent: "")
            item.target = self
            item.tag = h * 16 + i
            menu.addItem(item)
            if i == MergeSheetText.chooseSeparatorAfter { menu.addItem(.separator()) }
        }
        return menu
    }

    @objc func chooseItem(_ sender: NSMenuItem) {
        let h = sender.tag / 16, i = sender.tag % 16
        guard MergeSheetText.chooseChoices.indices.contains(i) else { return }
        state.choose(MergeSheetText.chooseChoices[i], forHunk: h)
        render()
    }

    /// Clicking a token: selects its change and opens the Choose menu below
    /// it, its top-left at the token's centre and 3 below its bottom.
    func showChooseMenu(forHunk h: Int) {
        selectHunk(h)
        let menu = chooseMenu(forHunk: h)
        lastChooseMenu = menu
        guard let t = canvas.tokenRect(forHunk: h), view.window?.isVisible == true else { return }
        menu.popUp(positioning: nil, at: NSPoint(x: t.midX, y: t.maxY + 3), in: canvas)
    }

    /// Hand editing (Ycode's choice): the selected change's text.
    public func beginEditing() {
        state.beginEditing()
        canvas.handEditor.string = state.editedText
        render()
        view.window?.makeFirstResponder(canvas.handEditor)
    }

    public func setEditedText(_ text: String) {
        guard state.isEditing else { return }
        canvas.handEditor.string = text
        textDidChange(Notification(name: NSText.didChangeNotification, object: canvas.handEditor))
    }

    public func textDidChange(_ notification: Notification) {
        guard (notification.object as? NSTextView) === canvas.handEditor, state.isEditing else { return }
        state.setEditedText(canvas.handEditor.string)
        renderPanes()
        renderButtons()
    }

    // MARK: Files

    public func setFlat(_ flat: Bool) {
        isFlat = flat
        fileList.needsDisplay = true
    }

    public func setFilter(_ text: String) {
        filterText = text
        fileList.needsDisplay = true
    }

    /// The file list's rows as shown.
    public var fileRows: [ConflictEditorState.FileRow] {
        state.fileRows(root: repository.root.path, flat: isFlat, filter: filterText)
    }

    public func selectFile(_ path: String) {
        Task { await show(file: path) }
    }

    // MARK: Buttons

    @objc public func merge(_ sender: Any?) {
        guard state.canMerge else { NSSound.beep(); return }
        onMerge?()
    }

    @objc public func cancel(_ sender: Any?) { onCancel?() }

    /// Mark as Resolved for the shown file (Integrate ▸ Mark as Resolved,
    /// the change row's item): writes its result and stages it.
    @discardableResult
    public func markResolved() async -> Bool {
        guard let file = state.currentFile, let doc = state.document, doc.isResolved else { return false }
        let repo = repository, text = doc.result
        await track { [weak self] in
            let error = await Task.detached { () -> String? in
                do { try repo.resolveConflict(file, text: text); return nil } catch { return "\(error)" }
            }.value
            self?.state.lastError = error
        }.value
        guard state.lastError == nil else { render(); return false }
        onResolved?()
        reloadFiles()
        await idle()
        return true
    }

    /// Writes every decided file and stages it (Merge's first step).
    func writeResolutions() async -> String? {
        let repo = repository, items = state.resolutions
        var error: String?
        await track {
            error = await Task.detached { () -> String? in
                for r in items {
                    do { try repo.resolveConflict(r.file, text: r.text) } catch { return "\(error)" }
                }
                return nil
            }.value
        }.value
        state.lastError = error
        render()
        return error
    }

    // MARK: Rendering

    func render() {
        guard isViewLoaded else { return }
        let name = state.currentFile.map { URL(fileURLWithPath: $0).lastPathComponent } ?? ""
        canvas.reload(state: state, fileName: name)
        ruler.marks = state.rulerMarks(rows: canvas.rows)
        fileList.needsDisplay = true
        jumpBar.needsDisplay = true
        footer.needsDisplay = true
        renderButtons()
        if state.isEditing, canvas.handEditor.string != state.editedText, LineDiff.lines(canvas.handEditor.string) != LineDiff.lines(state.editedText) {
            canvas.handEditor.string = state.editedText
        }
    }

    func renderPanes() {
        let name = state.currentFile.map { URL(fileURLWithPath: $0).lastPathComponent } ?? ""
        canvas.reload(state: state, fileName: name)
        ruler.marks = state.rulerMarks(rows: canvas.rows)
        footer.needsDisplay = true
    }

    func renderButtons() {
        mergeButton.title = state.primaryTitle
        mergeButton.isEnabled = state.canMerge
        mergeButton.isDefaultLook = state.canMerge
        mergeButton.setAccessibilityLabel(state.primaryTitle)
        sheetView.needsLayout = true
    }

    func scrollToSelection() {
        guard let h = state.currentHunk, let r = canvas.rows(ofHunk: h) else { return }
        let rect = canvas.rowRect(r.lowerBound).union(canvas.rowRect(r.upperBound - 1)).insetBy(dx: 0, dy: -CGFloat(MergeSheetMetrics.lineHeight) * 2)
        canvas.scrollToVisible(rect)
    }

    func scroll(toShare share: Double) {
        let y = CGFloat(share) * canvas.bounds.height - scrollView.contentView.bounds.height / 2
        canvas.scroll(NSPoint(x: 0, y: max(0, y)))
    }
}

/// The sheet: white, corner radius 16, a soft shadow, no title (§2).
@MainActor
public final class MergeSheetView: NSView {
    weak var controller: MergeSheetController?
    public let box = MergeBoxView()

    public override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = MergeSheetMetrics.cornerRadius
        layer?.cornerCurve = .continuous
        layer?.masksToBounds = false
        shadow = {
            let s = NSShadow()
            s.shadowBlurRadius = 30
            s.shadowOffset = NSSize(width: 0, height: -8)
            s.shadowColor = NSColor.black.withAlphaComponent(0.28)
            return s
        }()
        setAccessibilityElement(true)
        setAccessibilityRole(.sheet)
        setAccessibilityLabel("Merge")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    public override var isFlipped: Bool { true }
    public override var wantsUpdateLayer: Bool { true }
    public override func updateLayer() {
        layer?.backgroundColor = NSColor(mergeHex: MergeSheetPalette.forDark(effectiveAppearance.isDarkMerge).sheet).cgColor
    }

    public override func layout() {
        super.layout()
        controller?.layoutSheet()
    }

    public override func keyDown(with event: NSEvent) {
        if event.charactersIgnoringModifiers == "\u{1b}" { controller?.cancel(nil) } else { super.keyDown(with: event) }
    }

    public override func cancelOperation(_ sender: Any?) { controller?.cancel(sender) }
}

/// The bordered content box (§2): a 1-point #BFBFBF border, square
/// corners, the 1-point rule after the file list.
@MainActor
public final class MergeBoxView: NSView {
    public override var isFlipped: Bool { true }
    public override func draw(_ dirtyRect: NSRect) {
        let p = MergeSheetPalette.forDark(effectiveAppearance.isDarkMerge)
        NSColor(mergeHex: p.sheet).setFill()
        bounds.fill()
        NSColor(mergeHex: p.boxBorder).setStroke()
        let border = NSBezierPath(rect: bounds.insetBy(dx: 0.5, dy: 0.5))
        border.lineWidth = 1
        border.stroke()
        NSColor(mergeHex: p.columnRule).setFill()
        NSRect(x: 1 + MergeSheetMetrics.fileListWidth, y: 1, width: 1, height: bounds.height - 2).fill()
    }
}

/// Text drawing for the sheet's bars.
@MainActor
enum MergeDraw {
    @discardableResult
    static func text(_ s: String, at p: NSPoint, size: CGFloat = 12, weight: NSFont.Weight = .regular, color: NSColor,
                     maxWidth: CGFloat = .greatestFiniteMagnitude, centredIn height: CGFloat? = nil) -> CGFloat {
        let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: size, weight: weight), .foregroundColor: color]
        let a = NSAttributedString(string: s, attributes: attrs)
        let sz = a.size()
        let y = height.map { p.y + (($0 - sz.height) / 2).rounded() } ?? p.y
        a.draw(with: NSRect(x: p.x, y: y, width: min(sz.width + 1, maxWidth), height: sz.height),
               options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
        return min(sz.width, maxWidth)
    }

    static func width(_ s: String, size: CGFloat = 12, weight: NSFont.Weight = .regular) -> CGFloat {
        (s as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: size, weight: weight)]).width
    }

    /// A symbol tinted with `color`, `size` points tall, centred in `rect`.
    static func symbol(_ name: String, in rect: NSRect, color: NSColor, pointSize: CGFloat = 11) {
        guard let img = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: pointSize, weight: .regular)) else { return }
        let tinted = NSImage(size: img.size, flipped: false) { r in
            img.draw(in: r)
            color.set()
            r.fill(using: .sourceAtop)
            return true
        }
        let s = img.size
        tinted.draw(in: NSRect(x: rect.midX - s.width / 2, y: rect.midY - s.height / 2, width: s.width, height: s.height),
                    from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
    }

    /// Swift sources orange, other files the accent (the navigator's tints).
    static func fileTint(_ name: String) -> NSColor {
        URL(fileURLWithPath: name).pathExtension == "swift" ? NSColor(srgbRed: 0.95, green: 0.42, blue: 0.2, alpha: 1) : .controlAccentColor
    }

    static func chevron(at p: NSPoint, color: NSColor) {
        let path = NSBezierPath()
        path.move(to: NSPoint(x: p.x - 1.5, y: p.y - 3))
        path.line(to: NSPoint(x: p.x + 1.5, y: p.y))
        path.line(to: NSPoint(x: p.x - 1.5, y: p.y + 3))
        path.lineWidth = 1
        color.setStroke()
        path.stroke()
    }
}

/// The file list (§3): "Hierarchical | Flat", 24-point rows with a flush
/// full-width selection, the red "C" badge, and the Filter field.
@MainActor
public final class MergeFileListView: NSView, NSTextFieldDelegate {
    weak var controller: MergeSheetController?
    let filterField = NSTextField()
    typealias M = MergeSheetMetrics

    public override init(frame: NSRect) {
        super.init(frame: frame)
        filterField.placeholderString = MergeSheetText.filter
        filterField.isBordered = false
        filterField.drawsBackground = false
        filterField.focusRingType = .none
        filterField.font = .systemFont(ofSize: 12)
        filterField.delegate = self
        addSubview(filterField)
        setAccessibilityElement(true)
        setAccessibilityRole(.list)
        setAccessibilityLabel("Conflicted files")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    public override var isFlipped: Bool { true }

    /// The segments' frames: Hierarchical (the 74.5-wide pill), Flat.
    public var segmentFrames: (hierarchical: NSRect, flat: NSRect) {
        let hw: CGFloat = 74.5, fw: CGFloat = 40.5
        let x0 = ((bounds.width - hw - fw) / 2).rounded(.down) + 0.5
        let y = (CGFloat(M.fileListHeader) - CGFloat(M.segmentHeight)) / 2
        return (NSRect(x: x0, y: y, width: hw, height: CGFloat(M.segmentHeight)), NSRect(x: x0 + hw, y: y, width: fw, height: CGFloat(M.segmentHeight)))
    }

    public var filterFrame: NSRect {
        NSRect(x: 5.5, y: bounds.height - CGFloat(M.filterBottom) - CGFloat(M.filterHeight), width: bounds.width - 11, height: CGFloat(M.filterHeight))
    }

    /// A file row's frame by index into the controller's rows.
    public func rowFrame(_ i: Int) -> NSRect {
        NSRect(x: 0, y: CGFloat(M.fileListHeader) + 1 + CGFloat(i) * CGFloat(M.fileRowHeight), width: bounds.width, height: CGFloat(M.fileRowHeight))
    }

    public override func layout() {
        super.layout()
        let f = filterFrame
        filterField.frame = NSRect(x: f.minX + 22, y: f.minY + 3, width: f.width - 26, height: f.height - 5)
    }

    public override func draw(_ dirtyRect: NSRect) {
        let p = MergeSheetPalette.forDark(effectiveAppearance.isDarkMerge)
        guard let c = controller else { return }
        NSColor(mergeHex: p.sheet).setFill()
        bounds.fill()
        // Header band and its segments.
        let seg = segmentFrames
        let selected = c.isFlat ? seg.flat : seg.hierarchical
        NSColor(mergeHex: p.segmentPill).setFill()
        NSBezierPath(roundedRect: selected, xRadius: selected.height / 2, yRadius: selected.height / 2).fill()
        for (title, rect, on) in [(MergeSheetText.hierarchical, seg.hierarchical, !c.isFlat), (MergeSheetText.flat, seg.flat, c.isFlat)] {
            let w = MergeDraw.width(title, size: 11)
            MergeDraw.text(title, at: NSPoint(x: rect.midX - w / 2, y: rect.minY), size: 11, color: NSColor(mergeHex: on ? p.accent : p.label),
                           centredIn: rect.height)
        }
        NSColor(mergeHex: p.bandRule).setFill()
        NSRect(x: 0, y: CGFloat(M.fileListHeader), width: bounds.width, height: 1).fill()
        // Rows.
        let rows = c.fileRows
        if rows.isEmpty, c.state.files.isEmpty, c.loading != nil {
            MergeDraw.text(MergeSheetText.loading, at: NSPoint(x: 12, y: CGFloat(M.fileListHeader) + 6), size: 12, color: NSColor(mergeHex: p.secondaryLabel))
        }
        for (i, r) in rows.enumerated() {
            let f = rowFrame(i)
            let isSelected = r.path != nil && r.path == c.state.currentFile
            if isSelected {
                NSColor(mergeHex: p.selection).setFill()
                f.fill()
            }
            let ink = isSelected ? NSColor.white : NSColor(mergeHex: p.label)
            if r.kind == .folder {
                // Disclosure triangle (open), folder symbol, name.
                let tri = NSBezierPath()
                tri.move(to: NSPoint(x: 5, y: f.midY - 2))
                tri.line(to: NSPoint(x: 11, y: f.midY - 2))
                tri.line(to: NSPoint(x: 8, y: f.midY + 2))
                tri.close()
                NSColor(mergeHex: p.secondaryLabel).setFill()
                tri.fill()
                MergeDraw.symbol("folder.fill", in: NSRect(x: 16, y: f.minY, width: 16, height: f.height), color: NSColor(mergeHex: p.folder), pointSize: 12)
                MergeDraw.text(r.title, at: NSPoint(x: 37, y: f.minY), size: 13, color: ink, maxWidth: f.width - 45, centredIn: f.height)
            } else {
                let x = CGFloat(r.depth) * 15
                MergeDraw.symbol(WorkspaceChrome.fileSymbol(r.title), in: NSRect(x: x + CGFloat(M.fileIconX) - 15, y: f.minY, width: 14.5, height: f.height),
                                 color: isSelected ? .white : MergeDraw.fileTint(r.title), pointSize: 10)
                MergeDraw.text(r.title, at: NSPoint(x: x + CGFloat(M.fileNameX) - 15, y: f.minY), size: 13, color: ink,
                               maxWidth: f.width - x - CGFloat(M.fileNameX) - 10, centredIn: f.height)
                if r.isConflicted {
                    let b = NSRect(x: f.maxX - CGFloat(M.badgeTrailing) - CGFloat(M.badgeSize), y: f.midY - CGFloat(M.badgeSize) / 2,
                                   width: CGFloat(M.badgeSize), height: CGFloat(M.badgeSize))
                    NSColor(mergeHex: p.badge).setFill()
                    NSBezierPath(roundedRect: b, xRadius: 3, yRadius: 3).fill()
                    let w = MergeDraw.width("C", size: 9, weight: .bold)
                    MergeDraw.text("C", at: NSPoint(x: b.midX - w / 2, y: b.minY), size: 9, weight: .bold, color: NSColor(mergeHex: p.badgeLetter),
                                   centredIn: b.height)
                }
            }
        }
        // The Filter field.
        let ff = filterFrame
        NSColor(mergeHex: p.filterFill).setFill()
        NSBezierPath(roundedRect: ff, xRadius: 6, yRadius: 6).fill()
        MergeDraw.symbol("line.3.horizontal.decrease.circle", in: NSRect(x: ff.minX + 4.5, y: ff.minY, width: 13, height: ff.height),
                         color: NSColor(mergeHex: p.filterPlaceholder), pointSize: 12)
    }

    public override func mouseDown(with event: NSEvent) {
        guard let c = controller else { return }
        let pt = convert(event.locationInWindow, from: nil)
        let seg = segmentFrames
        if seg.hierarchical.contains(pt) { c.setFlat(false); return }
        if seg.flat.contains(pt) { c.setFlat(true); return }
        for (i, r) in c.fileRows.enumerated() where rowFrame(i).contains(pt) {
            if let p = r.path { c.selectFile(p) }
            return
        }
    }

    public func controlTextDidChange(_ obj: Notification) { controller?.setFilter(filterField.stringValue) }

    // A context menu on a file: Mark as Resolved (Ycode's choice).
    public override func menu(for event: NSEvent) -> NSMenu? {
        guard let c = controller else { return nil }
        let pt = convert(event.locationInWindow, from: nil)
        guard let i = c.fileRows.indices.first(where: { rowFrame($0).contains(pt) }), let path = c.fileRows[i].path else { return nil }
        c.selectFile(path)
        let m = NSMenu()
        let item = NSMenuItem(title: "Mark as Resolved", action: #selector(markResolved(_:)), keyEquivalent: "")
        item.target = self
        m.addItem(item)
        return m
    }

    @objc func markResolved(_ sender: Any?) {
        guard let c = controller else { return }
        Task { await c.markResolved() }
    }
}

/// The comparison's jump bar (§4.1): the grid symbol, back and forward,
/// the path to the file and "No Selection"; over the right pane, the
/// conflict navigator (previous, the conflict mark, next).
@MainActor
public final class MergeJumpBarView: NSView {
    weak var controller: MergeSheetController?
    var gutterX: CGFloat = 524

    public override var isFlipped: Bool { true }

    /// The conflict navigator's previous and next chevrons.
    public var navigatorFrames: (previous: NSRect, next: NSRect) {
        let right = bounds.width - 16
        return (NSRect(x: right - 40, y: 0, width: 10, height: 36), NSRect(x: right - 9, y: 0, width: 10, height: 36))
    }

    public override func draw(_ dirtyRect: NSRect) {
        let p = MergeSheetPalette.forDark(effectiveAppearance.isDarkMerge)
        guard let c = controller else { return }
        NSColor(mergeHex: p.sheet).setFill()
        bounds.fill()
        NSColor(mergeHex: p.bandRule).setFill()
        NSRect(x: 0, y: bounds.height - 1, width: bounds.width, height: 1).fill()
        let h: CGFloat = 36
        let ink = NSColor(mergeHex: p.secondaryLabel), label = NSColor(mergeHex: p.label)
        MergeDraw.symbol("square.grid.2x2", in: NSRect(x: 13, y: 0, width: 13, height: h), color: ink, pointSize: 11)
        NSColor(mergeHex: p.columnRule).setFill()
        NSRect(x: 35, y: 10, width: 1, height: 16).fill()
        MergeDraw.symbol("chevron.left", in: NSRect(x: 44.5, y: 0, width: 6.5, height: h), color: ink, pointSize: 10)
        MergeDraw.symbol("chevron.right", in: NSRect(x: 64, y: 0, width: 6.5, height: h), color: ink, pointSize: 10)
        var x: CGFloat = 82
        let path = c.state.jumpPath(root: c.repository.root.path)
        for (i, part) in path.enumerated() {
            let fileName = c.state.currentFile.map { URL(fileURLWithPath: $0).lastPathComponent } ?? part
            let symbol = i == 0 ? "shippingbox" : i == path.count - 1 ? WorkspaceChrome.fileSymbol(fileName) : "folder.fill"
            let color = i == 0 ? NSColor(mergeHex: p.accent) : i == path.count - 1 ? MergeDraw.fileTint(fileName) : NSColor(mergeHex: p.folder)
            MergeDraw.symbol(symbol, in: NSRect(x: x, y: 0, width: 14, height: h), color: color, pointSize: 11)
            x += 18
            x += MergeDraw.text(part, at: NSPoint(x: x, y: 0), size: 12, color: label, centredIn: h) + 7
            MergeDraw.chevron(at: NSPoint(x: x + 1.5, y: h / 2), color: ink)
            x += 10
        }
        if !path.isEmpty { MergeDraw.text(MergeSheetText.noSelection, at: NSPoint(x: x, y: 0), size: 12, color: label, centredIn: h) }
        // The conflict navigator.
        let nav = navigatorFrames
        MergeDraw.symbol("chevron.left", in: nav.previous, color: ink, pointSize: 10)
        MergeDraw.symbol("chevron.right", in: nav.next, color: ink, pointSize: 10)
        let mark = NSRect(x: nav.previous.maxX + 5, y: h / 2 - 5.5, width: 11, height: 11)
        NSColor(mergeHex: p.badgeLetter).setFill()
        NSBezierPath(ovalIn: mark).fill()
        let cross = NSBezierPath()
        cross.move(to: NSPoint(x: mark.minX + 3.5, y: mark.minY + 3.5))
        cross.line(to: NSPoint(x: mark.maxX - 3.5, y: mark.maxY - 3.5))
        cross.move(to: NSPoint(x: mark.maxX - 3.5, y: mark.minY + 3.5))
        cross.line(to: NSPoint(x: mark.minX + 3.5, y: mark.maxY - 3.5))
        cross.lineWidth = 1.25
        NSColor.white.setStroke()
        cross.stroke()
    }

    public override func mouseDown(with event: NSEvent) {
        let pt = convert(event.locationInWindow, from: nil)
        let nav = navigatorFrames
        if nav.previous.insetBy(dx: -4, dy: 0).contains(pt) { controller?.previousHunk(nil) }
        if nav.next.insetBy(dx: -4, dy: 0).contains(pt) { controller?.nextHunk(nil) }
    }
}

/// The footer row under both panes (§8): each side's repository › branch ›
/// date, author and short hash, and the "‹ n/m ›" stepper centred on the
/// gutter.
@MainActor
public final class MergeFooterView: NSView {
    weak var controller: MergeSheetController?
    var gutterX: CGFloat = 524
    var rightX: CGFloat = 571

    public override var isFlipped: Bool { true }

    /// The stepper: 60 wide, centred on the gutter.
    public var stepperFrame: NSRect {
        NSRect(x: gutterX + CGFloat(MergeSheetMetrics.gutterWidth) / 2 - 30, y: 1, width: 60, height: bounds.height - 1)
    }

    public override func draw(_ dirtyRect: NSRect) {
        let p = MergeSheetPalette.forDark(effectiveAppearance.isDarkMerge)
        guard let c = controller else { return }
        NSColor(mergeHex: p.sheet).setFill()
        bounds.fill()
        NSColor(mergeHex: p.footerRule).setFill()
        NSRect(x: 0, y: 0, width: bounds.width, height: 1).fill()
        let h = bounds.height - 1
        let label = NSColor(mergeHex: p.label), ink = NSColor(mergeHex: p.secondaryLabel)
        func side(_ f: MergeSheetFooter?, x: CGFloat, limit: CGFloat) {
            guard let f else { return }
            var x = x
            for (symbol, text) in [("clock", f.repository), ("arrow.triangle.branch", f.branch), ("smallcircle.filled.circle", f.commitText)] {
                guard x < limit - 20 else { return }
                MergeDraw.symbol(symbol, in: NSRect(x: x, y: 1, width: 12, height: h), color: ink, pointSize: 10)
                x += 15
                x += MergeDraw.text(text, at: NSPoint(x: x, y: 1), size: 11.5, color: label, maxWidth: limit - x, centredIn: h) + 6
                if symbol != "smallcircle.filled.circle" { MergeDraw.chevron(at: NSPoint(x: x + 1.5, y: 1 + h / 2), color: ink); x += 10 }
            }
        }
        let st = stepperFrame
        side(c.state.leftFooter, x: CGFloat(MergeSheetMetrics.footerTextX), limit: st.minX)
        side(c.state.rightFooter, x: rightX + 21.5, limit: bounds.width)
        MergeDraw.symbol("chevron.left", in: NSRect(x: st.minX, y: st.minY, width: 12, height: st.height), color: label, pointSize: 9)
        MergeDraw.symbol("chevron.right", in: NSRect(x: st.maxX - 12, y: st.minY, width: 12, height: st.height), color: label, pointSize: 9)
        let t = c.state.stepperText
        let w = MergeDraw.width(t, size: 11.5, weight: .medium)
        MergeDraw.text(t, at: NSPoint(x: st.midX - w / 2, y: st.minY), size: 11.5, weight: .medium, color: label, centredIn: st.height)
    }

    public override func mouseDown(with event: NSEvent) {
        let pt = convert(event.locationInWindow, from: nil)
        let st = stepperFrame
        guard st.contains(pt) else { return }
        if pt.x < st.minX + 18 { controller?.previousHunk(nil) } else if pt.x > st.maxX - 18 { controller?.nextHunk(nil) }
    }
}
