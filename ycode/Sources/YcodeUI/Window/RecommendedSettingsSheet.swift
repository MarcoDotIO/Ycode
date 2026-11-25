import AppKit
import YcodeBuild
import YcodeIDECore
import YcodeProject

/// The "Update to recommended settings" warning's actions (`specs/ide/
/// issues.md` §3–§5, P-120): its issue-navigator row opens the project
/// editor and the checklist sheet over it; the jump bar's stepper, with no
/// issue in a file to go to, opens the project editor alone.
extension WorkspaceWindowController {
    /// The issue navigator's file-less issue row was clicked.
    public func openProjectIssue(_ message: String) {
        guard message == RecommendedSettings.warningMessage else { return }
        showRecommendedSettings()
    }

    /// The project editor of the project to update, then the checklist
    /// sheet over the window. Returns the sheet (also when the window is not
    /// on screen, as in tests); nil when no project needs the update.
    @discardableResult
    public func showRecommendedSettings() -> RecommendedSettingsSheetController? {
        guard let target = session.recommendedSettingsProject else { return nil }
        openProjectEditor(target.path)
        let sheet = RecommendedSettingsSheetController(checklist: RecommendedSettingsChecklist(projectPath: target.path, changes: target.changes))
        sheet.onPerform = { [weak self] chosen in self?.performRecommendedSettings(chosen, projectPath: target.path) }
        pendingRecommendedSettings = sheet
        sheet.onClose = { [weak self] in self?.pendingRecommendedSettings = nil }
        guard let window, window.isVisible else { return sheet }
        let panel = NSWindow(contentViewController: sheet)
        panel.setContentSize(NSSize(width: RecommendedSettingsChecklist.Metrics.width, height: RecommendedSettingsChecklist.Metrics.height))
        sheet.onClose = { [weak self, weak window, weak panel] in
            if let panel { window?.endSheet(panel) }
            self?.pendingRecommendedSettings = nil
        }
        window.beginSheet(panel)
        // Return: Perform Changes, the window's default button (§5).
        sheet.performButton.keyEquivalent = "\r"
        panel.defaultButtonCell = sheet.performButton.cell as? NSButtonCell
        return sheet
    }

    /// Perform Changes: the checked settings written through the pbxproj
    /// writer; the project editor shows them and the check runs again.
    func performRecommendedSettings(_ chosen: [RecommendedSettings.Change], projectPath: String) {
        do {
            guard let proj = try session.performRecommendedSettings(chosen, projectPath: projectPath) else { return }
            projectEditor?.reload(proj: proj)
        } catch {
            presentError(error)
        }
    }

    /// The jump bar's stepper (and Jump to Next / Previous Issue) with no
    /// issue in a file: the recommended-settings warning opens the project
    /// editor, without the sheet (§4). False when there is no such warning.
    func stepToProjectIssue() -> Bool {
        guard session.displayedIssues.contains(where: WorkspaceSession.isRecommendedSettingsIssue),
              let target = session.recommendedSettingsProject else { return false }
        openProjectEditor(target.path)
        return true
    }

    /// The sheet the last `showRecommendedSettings()` opened, while it is up.
    public internal(set) var pendingRecommendedSettings: RecommendedSettingsSheetController? {
        get { objc_getAssociatedObject(self, &RecommendedSettingsSheetController.key) as? RecommendedSettingsSheetController }
        set { objc_setAssociatedObject(self, &RecommendedSettingsSheetController.key, newValue, .OBJC_ASSOCIATION_RETAIN_NONATOMIC) }
    }
}

/// The checklist sheet (§5): 581 × 364, a bordered scrolling list 522 wide
/// whose rows are a group heading (bold, 18 tall, its own checkbox) or a
/// change (a checkbox, the bold title, the grey explanation), then Cancel
/// (84 × 23) and Perform Changes (130 × 23, the default button) at the
/// bottom right, 12 apart, 20 from the right edge and 17 from the bottom.
/// Its measures are `RecommendedSettingsChecklist.Metrics`, shared with the
/// Linux IDE.
@MainActor
public final class RecommendedSettingsSheetController: NSViewController {
    nonisolated(unsafe) static var key: UInt8 = 0
    typealias M = RecommendedSettingsChecklist.Metrics

    public private(set) var checklist: RecommendedSettingsChecklist
    var onPerform: (([RecommendedSettings.Change]) -> Void)?
    var onClose: (() -> Void)?
    /// The checkboxes by row ID (`RecommendedSettingsChecklist.Row.id`).
    public private(set) var checkboxes: [String: NSButton] = [:]
    /// Each row's frame in the list's document view, by row ID (tests).
    public private(set) var rowFrames: [String: NSRect] = [:]
    public private(set) var cancelButton: NSButton!
    public private(set) var performButton: NSButton!
    public private(set) var scrollView: NSScrollView!

    static let titleFont = NSFont.boldSystemFont(ofSize: CGFloat(M.titleFontSize))
    static let detailFont = NSFont.systemFont(ofSize: CGFloat(M.titleFontSize))

    public init(checklist: RecommendedSettingsChecklist) {
        self.checklist = checklist
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    final class FlippedView: NSView { override var isFlipped: Bool { true } }

    public override func loadView() {
        let root = FlippedView(frame: NSRect(x: 0, y: 0, width: M.width, height: M.height))
        let scroll = NSScrollView(frame: NSRect(x: M.listX, y: M.listTop, width: M.listWidth, height: M.listHeight))
        scroll.borderType = .bezelBorder
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = false
        scroll.drawsBackground = true
        scroll.backgroundColor = .controlBackgroundColor
        scrollView = scroll
        root.addSubview(scroll)

        let cancel = NSButton(title: RecommendedSettingsChecklist.cancelTitle, target: self, action: #selector(cancelClicked))
        cancel.bezelStyle = .push
        cancel.keyEquivalent = "\u{1b}"
        let perform = NSButton(title: RecommendedSettingsChecklist.performTitle, target: self, action: #selector(performClicked))
        perform.bezelStyle = .push
        perform.keyEquivalent = "\r"
        let y = M.height - M.buttonBottom - M.performSize.height
        perform.frame = NSRect(x: M.width - M.buttonTrailing - M.performSize.width, y: y, width: M.performSize.width, height: M.performSize.height)
        cancel.frame = NSRect(x: perform.frame.minX - M.buttonGap - M.cancelSize.width, y: y, width: M.cancelSize.width, height: M.cancelSize.height)
        cancelButton = cancel
        performButton = perform
        root.addSubview(cancel)
        root.addSubview(perform)
        view = root
        buildRows()
    }

    /// The text column's width: the list less its checkbox column, scroller
    /// and border.
    var textWidth: CGFloat { CGFloat(M.listWidth - M.checkboxColumn) - NSScroller.scrollerWidth(for: .regular, scrollerStyle: .legacy) - 8 }

    /// The lines a change's detail takes at the text column's width.
    func detailLines(_ c: RecommendedSettings.Change) -> Int {
        let text = RecommendedSettingsChecklist.detail(c)
        let h = (text as NSString).boundingRect(with: NSSize(width: textWidth, height: .greatestFiniteMagnitude),
                                                options: [.usesLineFragmentOrigin], attributes: [.font: Self.detailFont]).height
        let natural = Self.detailFont.ascender - Self.detailFont.descender + Self.detailFont.leading
        return max(1, Int((h / natural).rounded()))
    }

    func buildRows() {
        let doc = FlippedView(frame: .zero)
        var y: CGFloat = 0
        let width = CGFloat(M.listWidth) - NSScroller.scrollerWidth(for: .regular, scrollerStyle: .legacy) - 2
        for row in checklist.rows {
            let box = NSButton(checkboxWithTitle: "", target: self, action: #selector(boxClicked(_:)))
            box.identifier = NSUserInterfaceItemIdentifier(row.id)
            box.controlSize = .small
            let boxSize = box.fittingSize
            let height: CGFloat
            switch row {
            case .group(let g):
                height = CGFloat(M.groupRowHeight)
                box.allowsMixedState = true
                let title = NSTextField(labelWithString: g.rawValue)
                title.font = Self.titleFont
                title.frame = NSRect(x: CGFloat(M.checkboxColumn), y: y + 2, width: textWidth, height: height - 2)
                doc.addSubview(title)
                box.setAccessibilityLabel(g.rawValue)
            case .change(let c):
                let lines = detailLines(c)
                height = CGFloat(M.changeRowHeight(explanationLines: lines))
                let title = NSTextField(labelWithString: c.title)
                title.font = Self.titleFont
                title.lineBreakMode = .byTruncatingTail
                title.frame = NSRect(x: CGFloat(M.checkboxColumn), y: y + 1, width: textWidth, height: CGFloat(M.lineHeight))
                let detail = NSTextField(wrappingLabelWithString: RecommendedSettingsChecklist.detail(c))
                detail.font = Self.detailFont
                detail.textColor = .secondaryLabelColor
                detail.frame = NSRect(x: CGFloat(M.checkboxColumn), y: y + 1 + CGFloat(M.lineHeight), width: textWidth,
                                      height: CGFloat(M.lineHeight) * CGFloat(lines) + 1)
                doc.addSubview(title)
                doc.addSubview(detail)
                box.setAccessibilityLabel(c.title)
            }
            box.frame = NSRect(x: (CGFloat(M.checkboxColumn) - boxSize.width) / 2, y: y + 1, width: boxSize.width, height: boxSize.height)
            doc.addSubview(box)
            checkboxes[row.id] = box
            rowFrames[row.id] = NSRect(x: 0, y: y, width: width, height: height)
            y += height
        }
        doc.frame = NSRect(x: 0, y: 0, width: width, height: max(y, CGFloat(M.listHeight) - 2))
        scrollView.documentView = doc
        syncBoxes()
    }

    /// The checkboxes from the checklist's state.
    func syncBoxes() {
        for row in checklist.rows {
            guard let box = checkboxes[row.id] else { continue }
            switch row {
            case .group(let g):
                switch checklist.state(of: g) {
                case .on: box.state = .on
                case .off: box.state = .off
                case .mixed: box.state = .mixed
                }
            case .change(let c): box.state = checklist.isChecked(c) ? .on : .off
            }
        }
    }

    /// A row's checkbox clicked (tests call it with the row's ID).
    public func toggle(rowID: String) {
        guard let row = checklist.rows.first(where: { $0.id == rowID }) else { return }
        switch row {
        case .group(let g): checklist.toggle(g)
        case .change(let c): checklist.toggle(c)
        }
        syncBoxes()
    }

    @objc func boxClicked(_ b: NSButton) {
        guard let id = b.identifier?.rawValue else { return }
        toggle(rowID: id)
    }

    /// Cancel (Escape): closes; nothing is applied.
    @objc public func cancelClicked() {
        onClose?()
    }

    /// Perform Changes (Return): writes the checked changes, then closes.
    @objc public func performClicked() {
        onPerform?(checklist.chosen)
        onClose?()
    }
}
