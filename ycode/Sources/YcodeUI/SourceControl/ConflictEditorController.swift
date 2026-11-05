import AppKit
import YcodeIDECore

/// The three-way conflict editor (`specs/ide/comparison.md`, "Ycode
/// implementation"): for a conflicted file, base / ours (left) / theirs
/// (right) shown two at a time in the comparison view, a choice per hunk
/// (Left, Right, Left + Right, Right + Left, Base, Edit), the merged
/// result below, Mark as Resolved, and Continue or Abort for the
/// operation in progress. The same controller compares and merges any
/// two or three files (Compare Files, Ycode's file-merge tool).
@MainActor
public final class ConflictEditorController: NSViewController, NSTextViewDelegate {
    public enum Source {
        /// A repository's conflicted files.
        case repository(GitRepository)
        /// Two files, or three with a common ancestor.
        case files(left: URL, right: URL, ancestor: URL?)
    }

    /// Which two of the three versions the comparison view shows.
    public typealias Pair = ConflictEditorState.Pair
    public static let pairTitles = ConflictEditorState.pairTitles
    public static let choiceTitles = ConflictEditorState.choiceTitles

    public let source: Source
    /// Everything the editor shows, shared with the Linux IDE
    /// (`ConflictEditorState`).
    public private(set) var state: ConflictEditorState
    /// Conflicted files (repository) and the shown one.
    public var files: [String] { state.files }
    public var currentFile: String? { state.currentFile }
    public var document: MergeDocument? { state.document }
    /// The selected hunk (index into `document.hunks`).
    public var currentHunk: Int? { state.currentHunk }
    public var pair: Pair { state.pair }
    public var integration: GitRepository.IntegrationState { state.integration }
    public var lastError: String? { state.lastError }
    public var isEditing: Bool { state.isEditing }

    public let titleLabel = NSTextField(labelWithString: "")
    public let filePopUp = NSPopUpButton()
    public let previousButton = NSButton()
    public let nextButton = NSButton()
    public let hunkLabel = NSTextField(labelWithString: "")
    public let choiceControl = NSSegmentedControl(labels: ConflictEditorController.choiceTitles, trackingMode: .selectOne, target: nil, action: nil)
    public let pairControl = NSSegmentedControl(labels: ConflictEditorController.pairTitles, trackingMode: .selectOne, target: nil, action: nil)
    public let statusLabel = NSTextField(labelWithString: "")
    public let resolveButton = NSButton(title: "Mark as Resolved", target: nil, action: nil)
    public let continueButton = NSButton(title: "Continue", target: nil, action: nil)
    public let abortButton = NSButton(title: "Abort", target: nil, action: nil)
    public let saveButton = NSButton(title: "Save Merge\u{2026}", target: nil, action: nil)
    public let comparison = ComparisonView()
    public let hunkEditor = NSTextView()
    let hunkEditorScroll = NSScrollView()
    var hunkEditorHeight: NSLayoutConstraint!
    public let resultView = NSTextView()
    let resultScroll = NSScrollView()
    public let resultTitle = NSTextField(labelWithString: "Result")

    /// A file was marked resolved (the window refreshes git's status).
    public var onResolved: (() -> Void)?
    public var onContinue: (() -> Void)?
    public var onAbort: (() -> Void)?
    /// A background git read or write, while one runs. Every task is
    /// tracked until its own body has finished (it removes itself as its
    /// last step), so `idle()` never finds a finished task still listed:
    /// waiting on one would spin the main actor.
    public var loading: Task<Void, Never>? { pending.values.first }
    private var pending: [Int: Task<Void, Never>] = [:]
    private var nextPending = 0
    private var showGeneration = 0
    private let focus: String?

    public init(repository: GitRepository, focus: String? = nil) {
        source = .repository(repository)
        state = ConflictEditorState(source: .repository)
        self.focus = focus
        super.init(nibName: nil, bundle: nil)
    }

    public init(left: URL, right: URL, ancestor: URL? = nil) {
        source = .files(left: left, right: right, ancestor: ancestor)
        state = ConflictEditorState(source: .files(hasAncestor: ancestor != nil))
        focus = nil
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    var repository: GitRepository? { if case .repository(let r) = source { r } else { nil } }
    public var isComparingFiles: Bool { repository == nil }
    var hasBase: Bool { state.hasBase }

    // MARK: View

    public override func loadView() {
        let root = PanelBackgroundView(frame: NSRect(x: 0, y: 0, width: 900, height: 620))
        titleLabel.font = .boldSystemFont(ofSize: 13)
        titleLabel.lineBreakMode = .byTruncatingMiddle
        filePopUp.controlSize = .small
        filePopUp.target = self
        filePopUp.action = #selector(fileChosen)
        for (b, symbol, tip, sel) in [(previousButton, "chevron.left", "Previous Change", #selector(previousHunk(_:))),
                                      (nextButton, "chevron.right", "Next Change", #selector(nextHunk(_:)))] {
            b.image = NSImage(systemSymbolName: symbol, accessibilityDescription: tip)
            b.bezelStyle = .accessoryBarAction
            b.isBordered = false
            b.toolTip = tip
            b.target = self
            b.action = sel
        }
        hunkLabel.textColor = .secondaryLabelColor
        choiceControl.controlSize = .small
        choiceControl.target = self
        choiceControl.action = #selector(choiceChanged)
        choiceControl.setToolTip("Use the left version", forSegment: 0)
        choiceControl.setToolTip("Use the right version", forSegment: 1)
        choiceControl.setToolTip("Use both, left first", forSegment: 2)
        choiceControl.setToolTip("Use both, right first", forSegment: 3)
        choiceControl.setToolTip("Use the common ancestor's version", forSegment: 4)
        choiceControl.setToolTip("Write this change by hand", forSegment: 5)
        pairControl.controlSize = .small
        pairControl.selectedSegment = 0
        pairControl.target = self
        pairControl.action = #selector(pairChanged)
        statusLabel.textColor = .secondaryLabelColor
        for (b, sel) in [(resolveButton, #selector(markResolved(_:))), (continueButton, #selector(continueIntegration(_:))),
                         (abortButton, #selector(abortIntegration(_:))), (saveButton, #selector(saveMerge(_:)))] {
            b.bezelStyle = .push
            b.controlSize = .small
            b.target = self
            b.action = sel
        }
        resolveButton.keyEquivalent = ""
        saveButton.isHidden = !isComparingFiles
        resolveButton.isHidden = isComparingFiles
        continueButton.isHidden = true
        abortButton.isHidden = true
        filePopUp.isHidden = isComparingFiles

        let top = NSStackView(views: [titleLabel, filePopUp, NSView(), statusLabel, resolveButton, continueButton, abortButton, saveButton])
        top.orientation = .horizontal
        top.spacing = 8
        let bar = NSStackView(views: [previousButton, hunkLabel, nextButton, choiceControl, NSView(), pairControl])
        bar.orientation = .horizontal
        bar.spacing = 6

        for (tv, sv) in [(hunkEditor, hunkEditorScroll), (resultView, resultScroll)] {
            tv.isRichText = false
            tv.font = Theme.font
            tv.isAutomaticQuoteSubstitutionEnabled = false
            tv.isAutomaticDashSubstitutionEnabled = false
            tv.isAutomaticTextReplacementEnabled = false
            tv.autoresizingMask = [.width]
            tv.isVerticallyResizable = true
            tv.textContainerInset = NSSize(width: 4, height: 4)
            sv.documentView = tv
            sv.hasVerticalScroller = true
            sv.borderType = .bezelBorder
        }
        hunkEditor.delegate = self
        hunkEditor.setAccessibilityLabel("Edited change")
        resultView.isEditable = false
        resultView.isRichText = true
        resultView.setAccessibilityLabel("Merge result")
        resultTitle.font = .boldSystemFont(ofSize: 11)
        resultTitle.textColor = .secondaryLabelColor

        let stack = NSStackView(views: [top, bar, comparison, hunkEditorScroll, resultTitle, resultScroll])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        stack.edgeInsets = NSEdgeInsets(top: 8, left: 10, bottom: 8, right: 10)
        stack.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(stack)
        hunkEditorHeight = hunkEditorScroll.heightAnchor.constraint(equalToConstant: 0)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: root.topAnchor), stack.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: root.leadingAnchor), stack.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            top.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -20),
            bar.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -20),
            comparison.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -20),
            hunkEditorScroll.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -20),
            resultScroll.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -20),
            comparison.heightAnchor.constraint(equalTo: resultScroll.heightAnchor, multiplier: 1.4),
            resultScroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 80),
            hunkEditorHeight,
        ])
        comparison.workingCopyOnLeft = false
        view = root
        reloadFiles()
    }

    // MARK: Loading

    /// Re-reads the list of conflicted files (repository) or the files
    /// (Compare Files), then shows the focused or first one.
    public func reloadFiles() {
        switch source {
        case .files(let l, let r, let a):
            state.lastError = nil
            do {
                let left = try String(contentsOf: l, encoding: .utf8), right = try String(contentsOf: r, encoding: .utf8)
                if let a {
                    let base = try String(contentsOf: a, encoding: .utf8)
                    state.load(MergeDocument(base: base, ours: left, theirs: right, oursLabel: l.lastPathComponent,
                                             theirsLabel: r.lastPathComponent, baseLabel: a.lastPathComponent))
                } else {
                    state.load(MergeDocument(chunks: ThreeWayMerge.compare(left: LineDiff.lines(left), right: LineDiff.lines(right)),
                                             oursLabel: l.lastPathComponent, theirsLabel: r.lastPathComponent, baseLabel: l.lastPathComponent))
                }
            } catch {
                state.load(nil)
                state.lastError = error.localizedDescription
            }
            titleLabel.stringValue = a.map { "\(l.lastPathComponent) \u{2194} \(r.lastPathComponent) (ancestor \($0.lastPathComponent))" }
                ?? "\(l.lastPathComponent) \u{2194} \(r.lastPathComponent)"
            render()
        case .repository(let repo):
            let wanted = currentFile ?? focus
            track { [weak self] in
                let read = await Task.detached { () -> ([String], GitRepository.IntegrationState) in
                    (repo.conflictedFiles(), repo.integrationState())
                }.value
                guard let self else { return }
                self.state.files = read.0
                self.state.integration = read.1
                await self.show(file: ConflictEditorState.target(wanted: wanted, in: read.0))
            }
        }
    }

    /// The window's latest snapshot: picks up conflicts resolved or added
    /// elsewhere without re-reading the shown file.
    public func update(integration: GitRepository.IntegrationState, conflicted: [String]) {
        guard repository != nil, loading == nil else { return }
        if case .show(let next) = state.update(integration: integration, conflicted: conflicted) {
            track { [weak self] in await self?.show(file: next) }
            return
        }
        render()
    }

    /// Shows one conflicted file (repository mode).
    public func show(file: String?) async {
        guard let repo = repository else { return }
        state.currentFile = file
        guard let file else { state.load(nil); render(); return }
        showGeneration += 1
        let generation = showGeneration
        await track { [weak self] in
            let doc = await Task.detached { repo.mergeDocument(forConflictedFile: file) }.value
            // A later show replaced this one.
            guard let self, generation == self.showGeneration, self.currentFile == file else { return }
            self.state.load(doc)
            self.render()
        }.value
    }

    /// Runs `body` on the main actor as a tracked task (see `loading`).
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

    /// Waits until no read or write runs (tests). Each wait suspends on an
    /// unfinished task, so the main actor stays free.
    public func idle() async {
        while let t = pending.values.first { await t.value }
    }

    // MARK: Hunks

    /// Selects a hunk and shows it.
    public func selectHunk(_ h: Int?) {
        state.selectHunk(h)
        render()
    }

    @objc public func nextHunk(_ sender: Any?) { state.nextHunk(); render() }
    @objc public func previousHunk(_ sender: Any?) { state.previousHunk(); render() }

    /// Applies a choice to the selected hunk; after a decision the next
    /// undecided conflict is selected.
    public func choose(_ choice: MergeDocument.Choice) {
        state.choose(choice)
        render()
    }

    /// Edit: the selected hunk's text becomes hand-written; the editor
    /// below the bar shows it.
    public func beginEditing() {
        state.beginEditing()
        hunkEditor.string = state.editedText
        render()
    }

    /// Replaces the selected hunk's hand-written text.
    public func setEditedText(_ text: String) {
        guard isEditing else { return }
        hunkEditor.string = text
        textDidChange(Notification(name: NSText.didChangeNotification, object: hunkEditor))
    }

    public func textDidChange(_ notification: Notification) {
        guard (notification.object as? NSTextView) === hunkEditor, isEditing else { return }
        state.setEditedText(hunkEditor.string)
        renderResult()
        renderStatus()
    }

    @objc func choiceChanged() {
        state.chooseSegment(choiceControl.selectedSegment)
        if isEditing { hunkEditor.string = state.editedText }
        render()
    }

    @objc func pairChanged() { setPair(Pair(rawValue: pairControl.selectedSegment) ?? .leftRight) }

    public func setPair(_ p: Pair) {
        state.setPair(p)
        pairControl.selectedSegment = pair.rawValue
        renderComparison()
    }

    @objc func fileChosen() {
        let i = filePopUp.indexOfSelectedItem
        guard files.indices.contains(i) else { return }
        Task { await show(file: files[i]) }
    }

    // MARK: Actions

    /// Mark as Resolved: writes the result and stages the file, then shows
    /// the next conflicted file.
    @objc public func markResolved(_ sender: Any?) { Task { await markResolved() } }

    @discardableResult
    public func markResolved() async -> Bool {
        guard let repo = repository, let file = currentFile, let doc = document, doc.isResolved else { NSSound.beep(); return false }
        let text = doc.result
        await track { [weak self] in
            let error = await Task.detached { () -> String? in
                do { try repo.resolveConflict(file, text: text); return nil } catch { return "\(error)" }
            }.value
            self?.state.lastError = error
        }.value
        guard lastError == nil else { render(); return false }
        onResolved?()
        state.currentFile = nil
        reloadFiles()
        await idle()
        return true
    }

    @objc public func continueIntegration(_ sender: Any?) { onContinue?() }
    @objc public func abortIntegration(_ sender: Any?) { onAbort?() }

    /// Compare Files: writes the merged result.
    @objc public func saveMerge(_ sender: Any?) {
        let panel = NSSavePanel()
        if case .files(let l, _, _) = source { panel.directoryURL = l.deletingLastPathComponent(); panel.nameFieldStringValue = l.lastPathComponent }
        guard let w = view.window else { return }
        panel.beginSheetModal(for: w) { [weak self] r in
            MainActor.assumeIsolated {
                guard r == .OK, let url = panel.url else { return }
                do { try self?.save(to: url) } catch { self?.presentError(error) }
            }
        }
    }

    /// Writes the result; refused while conflicts are unresolved.
    public func save(to url: URL) throws {
        guard let doc = document else { return }
        guard doc.isResolved else {
            throw GitRepository.GitError(description: "Choose a version for every conflict before saving.")
        }
        try doc.result.write(to: url, atomically: true, encoding: .utf8)
    }

    // MARK: Rendering

    func render() {
        guard isViewLoaded else { return }
        let names = state.fileNames
        if filePopUp.itemTitles != names {
            filePopUp.removeAllItems()
            filePopUp.addItems(withTitles: names)
        }
        if let f = currentFile, let i = files.firstIndex(of: f) { filePopUp.selectItem(at: i) }
        if repository != nil { titleLabel.stringValue = state.title }
        pairControl.isHidden = !hasBase
        choiceControl.setEnabled(hasBase, forSegment: 4)
        continueButton.title = state.continueTitle
        abortButton.title = state.abortTitle
        continueButton.isHidden = !state.showsIntegrationButtons
        abortButton.isHidden = !state.showsIntegrationButtons
        continueButton.isEnabled = files.isEmpty
        renderStatus()
        renderHunkBar()
        renderComparison()
        renderResult()
    }

    func renderStatus() {
        statusLabel.stringValue = state.statusText
        resolveButton.isEnabled = state.canMarkResolved
    }

    func renderHunkBar() {
        hunkLabel.stringValue = state.hunkLabel
        previousButton.isEnabled = state.hasHunks
        nextButton.isEnabled = state.hasHunks
        choiceControl.isEnabled = currentHunk != nil
        choiceControl.selectedSegment = state.selectedSegment ?? -1
        if isEditing, hunkEditor.string != state.editedText, LineDiff.lines(hunkEditor.string) != LineDiff.lines(state.editedText) {
            hunkEditor.string = state.editedText
        }
        hunkEditorScroll.isHidden = !isEditing
        hunkEditorHeight?.constant = isEditing ? 90 : 0
    }

    func renderComparison() {
        let c = state.comparison
        comparison.show(old: c.old, new: c.new, oldTitle: c.oldTitle, newTitle: c.newTitle)
        // Scroll both columns to the selected hunk's first row.
        guard let row = state.comparisonRow(in: comparison.rows) else { return }
        scroll(comparison.leftView, toLine: row)
    }

    func renderResult() {
        let s = NSMutableAttributedString()
        for line in state.resultLines {
            var attrs: [NSAttributedString.Key: Any] = [.font: Theme.font, .foregroundColor: NSColor.textColor]
            if line.tint != .none {
                let base = line.tint == .unresolved ? NSColor.systemRed : NSColor.systemGreen
                attrs[.backgroundColor] = base.withAlphaComponent(line.isSelected ? 0.28 : 0.12)
            }
            s.append(NSAttributedString(string: line.text + "\n", attributes: attrs))
        }
        resultView.textStorage?.setAttributedString(s)
        if let l = state.resultStartLine { scroll(resultView, toLine: l) }
    }

    func scroll(_ tv: NSTextView, toLine line: Int) {
        let text = tv.string as NSString
        var offset = 0, l = 0
        while l < line, offset < text.length {
            let r = text.lineRange(for: NSRange(location: offset, length: 0))
            offset = NSMaxRange(r)
            l += 1
        }
        tv.scrollRangeToVisible(NSRange(location: min(offset, text.length), length: 0))
    }

    /// The result text as shown (tests).
    public var resultText: String { resultView.string }
}

/// A window comparing and merging two or three files (Ycode ▸ Open
/// Developer Tool ▸ Compare Files…).
@MainActor
public final class CompareFilesWindowController: NSWindowController {
    public let editor: ConflictEditorController
    static var open: [CompareFilesWindowController] = []

    public init(left: URL, right: URL, ancestor: URL? = nil) {
        editor = ConflictEditorController(left: left, right: right, ancestor: ancestor)
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 960, height: 680), styleMask: [.titled, .closable, .resizable, .miniaturizable],
                         backing: .buffered, defer: true)
        w.title = "Compare Files"
        w.isReleasedWhenClosed = false
        w.contentViewController = editor
        super.init(window: w)
        closeObserver = NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: w, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { Self.open.removeAll { $0 === self } }
        }
    }

    private var closeObserver: NSObjectProtocol?

    isolated deinit {
        if let closeObserver { NotificationCenter.default.removeObserver(closeObserver) }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    /// Opens a window for the files and keeps it until it closes.
    @discardableResult
    public static func show(left: URL, right: URL, ancestor: URL? = nil, display: Bool = true) -> CompareFilesWindowController {
        let c = CompareFilesWindowController(left: left, right: right, ancestor: ancestor)
        open.append(c)
        if display {
            c.window?.center()
            c.showWindow(nil)
        }
        return c
    }

    /// Asks for the left and right files, then optionally an ancestor.
    public static func choose() {
        func pick(_ message: String, prompt: String) -> URL? {
            let p = NSOpenPanel()
            p.message = message
            p.prompt = prompt
            p.canChooseFiles = true
            p.canChooseDirectories = false
            p.allowsMultipleSelection = false
            return p.runModal() == .OK ? p.url : nil
        }
        guard let left = pick("Choose the left file.", prompt: "Choose Left"),
              let right = pick("Choose the right file.", prompt: "Choose Right") else { return }
        let ancestor = pick("Choose a common ancestor to merge against, or Cancel to compare two files.", prompt: "Choose Ancestor")
        show(left: left, right: right, ancestor: ancestor)
    }
}

extension AppCommands {
    /// Ycode ▸ Open Developer Tool ▸ Compare Files…: two files, or three
    /// with an ancestor, in a merge window.
    @objc public func compareFiles(_ sender: Any?) { CompareFilesWindowController.choose() }
}
