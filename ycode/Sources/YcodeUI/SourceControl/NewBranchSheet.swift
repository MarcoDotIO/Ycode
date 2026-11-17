import AppKit
import YcodeIDECore

/// New Branch… (parity inventory P-132): a sheet "Create new branch in
/// “<repository>”:" with From (the branch or commit it starts at) and To
/// (the new name); Create stays disabled until a name is typed.
@MainActor
public final class NewBranchSheetController: NSViewController, NSTextFieldDelegate {
    public let repositoryName: String
    public let source: String
    public let nameField = NSTextField(string: "")
    public let createButton = NSButton(title: "Create", target: nil, action: nil)
    public let cancelButton = NSButton(title: "Cancel", target: nil, action: nil)
    /// Create was pressed with this name.
    public var onCreate: ((String) -> Void)?

    public init(repositoryName: String, source: String) {
        self.repositoryName = repositoryName
        self.source = source
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    /// The sheet's title line.
    public static func title(repository: String) -> String { "Create new branch in \u{201C}\(repository)\u{201D}:" }

    /// Whether `name` can be created: not empty once trimmed.
    public static func canCreate(_ name: String) -> Bool { !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    public override func loadView() {
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 420, height: 150))
        let title = NSTextField(labelWithString: Self.title(repository: repositoryName))
        title.font = .boldSystemFont(ofSize: 13)
        let fromLabel = NSTextField(labelWithString: "From:")
        let toLabel = NSTextField(labelWithString: "To:")
        for l in [fromLabel, toLabel] { l.alignment = .right; l.widthAnchor.constraint(equalToConstant: 44).isActive = true }
        let from = NSTextField(labelWithString: source)
        from.lineBreakMode = .byTruncatingMiddle
        nameField.placeholderString = "Branch name"
        nameField.delegate = self
        nameField.setAccessibilityIdentifier("newBranchName")
        let fromRow = NSStackView(views: [fromLabel, from])
        fromRow.alignment = .firstBaseline
        let toRow = NSStackView(views: [toLabel, nameField])
        toRow.alignment = .firstBaseline
        cancelButton.target = self
        cancelButton.action = #selector(cancel(_:))
        cancelButton.keyEquivalent = "\u{1b}"
        createButton.target = self
        createButton.action = #selector(create(_:))
        createButton.keyEquivalent = "\r"
        createButton.isEnabled = false
        // Cancel and Create at the trailing edge, as the Linux sheet.
        let buttons = NSStackView()
        buttons.setViews([cancelButton, createButton], in: .trailing)
        let stack = NSStackView(views: [title, fromRow, toRow, buttons])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 20, right: 20)
        stack.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: root.topAnchor), stack.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: root.leadingAnchor), stack.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            nameField.widthAnchor.constraint(equalToConstant: 320),
            buttons.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -40),
        ])
        view = root
    }

    /// Types a name (as the field would) and updates Create.
    public func setName(_ name: String) {
        _ = view
        nameField.stringValue = name
        updateCreate()
    }

    func updateCreate() { createButton.isEnabled = Self.canCreate(nameField.stringValue) }

    public func controlTextDidChange(_ obj: Notification) { updateCreate() }

    @objc public func create(_ sender: Any?) {
        let name = nameField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard Self.canCreate(name) else { NSSound.beep(); return }
        dismissSheet()
        onCreate?(name)
    }

    @objc public func cancel(_ sender: Any?) { dismissSheet() }

    public override func cancelOperation(_ sender: Any?) { dismissSheet() }

    func dismissSheet() {
        guard isViewLoaded, let w = view.window else { return }
        if let p = w.sheetParent { p.endSheet(w) } else { w.orderOut(nil) }
    }
}

extension SourceControlCoordinator {
    /// New Branch…: the sheet over the window (P-132); Create makes the
    /// branch from `start` (else the current branch) and checks it out.
    @discardableResult
    public func presentNewBranchSheet(from start: String?) -> NewBranchSheetController {
        let name = repository?.root.lastPathComponent ?? owner.session.model.url.deletingPathExtension().lastPathComponent
        let sheet = NewBranchSheetController(repositoryName: name, source: start ?? snapshot.currentBranch ?? "HEAD")
        sheet.onCreate = { [weak self] branch in self?.createBranch(branch, from: start, checkout: true) }
        if let w = owner.window, w.isVisible {
            let panel = NSPanel(contentViewController: sheet)
            panel.styleMask = [.titled, .docModalWindow]
            panel.isReleasedWhenClosed = false
            w.beginSheet(panel)
            panel.makeFirstResponder(sheet.nameField)
        }
        return sheet
    }
}
