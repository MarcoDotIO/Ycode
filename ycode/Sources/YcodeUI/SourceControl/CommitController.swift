import AppKit

/// The commit sheet (Integrate ▸ Commit…, ⌥⌘C): changed files with a
/// checkbox each, a message field, and Commit. See
/// `specs/ide/source-control.md`.
@MainActor
public final class CommitController: NSViewController, NSTableViewDataSource, NSTableViewDelegate {
    public struct Row: Equatable { public var path: String; public var status: GitRepository.FileStatus; public var selected: Bool }

    public let repository: GitRepository
    public private(set) var rows: [Row]
    public let messageView = NSTextView()
    private let table = NSTableView()
    /// The diff of the selected file (unified, colored).
    public let diffView = NSTextView()
    public var onCommitted: ((String) -> Void)?
    public private(set) var lastError: String?

    public init(repository: GitRepository, status: [String: GitRepository.FileStatus]) {
        self.repository = repository
        rows = status.keys.sorted().map { Row(path: $0, status: status[$0]!, selected: true) }
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    public override func loadView() {
        let root = PanelBackgroundView(frame: NSRect(x: 0, y: 0, width: 860, height: 460))
        for (id, title, w) in [("on", "", 24.0), ("status", "", 24.0), ("path", "File", 520.0)] {
            let c = NSTableColumn(identifier: .init(id))
            c.title = title
            c.width = w
            table.addTableColumn(c)
        }
        table.dataSource = self
        table.delegate = self
        table.rowSizeStyle = .small
        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.borderType = .bezelBorder
        messageView.font = .systemFont(ofSize: 12)
        messageView.isRichText = false
        diffView.isEditable = false
        diffView.font = Theme.font
        diffView.autoresizingMask = [.width]
        let diffScroll = NSScrollView()
        diffScroll.documentView = diffView
        diffScroll.hasVerticalScroller = true
        diffScroll.borderType = .bezelBorder
        let messageScroll = NSScrollView()
        messageScroll.documentView = messageView
        messageScroll.borderType = .bezelBorder
        messageView.autoresizingMask = [.width]
        let placeholder = NSTextField(labelWithString: "Enter commit message here")
        placeholder.textColor = .tertiaryLabelColor
        let cancel = NSButton(title: "Cancel", target: self, action: #selector(cancel(_:)))
        cancel.keyEquivalent = "\u{1b}"
        let commit = NSButton(title: "Commit Files", target: self, action: #selector(commitClicked))
        commit.keyEquivalent = "\r"
        for v in [scroll, diffScroll, placeholder, messageScroll, cancel, commit] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(v)
        }
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: root.topAnchor, constant: 16),
            scroll.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 16),
            scroll.widthAnchor.constraint(equalToConstant: 260),
            scroll.heightAnchor.constraint(equalToConstant: 260),
            diffScroll.topAnchor.constraint(equalTo: scroll.topAnchor),
            diffScroll.leadingAnchor.constraint(equalTo: scroll.trailingAnchor, constant: 8),
            diffScroll.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -16),
            diffScroll.bottomAnchor.constraint(equalTo: scroll.bottomAnchor),
            placeholder.topAnchor.constraint(equalTo: scroll.bottomAnchor, constant: 10),
            placeholder.leadingAnchor.constraint(equalTo: scroll.leadingAnchor),
            messageScroll.topAnchor.constraint(equalTo: placeholder.bottomAnchor, constant: 4),
            messageScroll.leadingAnchor.constraint(equalTo: scroll.leadingAnchor),
            messageScroll.trailingAnchor.constraint(equalTo: diffScroll.trailingAnchor),
            messageScroll.bottomAnchor.constraint(equalTo: commit.topAnchor, constant: -12),
            commit.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -16),
            commit.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -14),
            cancel.trailingAnchor.constraint(equalTo: commit.leadingAnchor, constant: -8),
            cancel.bottomAnchor.constraint(equalTo: commit.bottomAnchor),
        ])
        view = root
        if !rows.isEmpty {
            table.reloadData()
            table.selectRowIndexes([0], byExtendingSelection: false)
            showDiff(for: 0)
        }
    }

    /// The diff read in progress, if any.
    public private(set) var diffLoading: Task<Void, Never>?
    private var diffGeneration = 0

    /// Shows the selected file's changes against HEAD (git diff runs in
    /// the background; a later selection replaces an earlier one).
    public func showDiff(for row: Int) {
        guard rows.indices.contains(row) else { return }
        let repo = repository, path = rows[row].path
        diffGeneration += 1
        let generation = diffGeneration
        diffLoading = Task { [weak self] in
            let text = await Task.detached { repo.diff(of: path) }.value
            guard let self, generation == self.diffGeneration else { return }
            self.diffLoading = nil
            self.show(diff: text)
        }
    }

    /// Waits for the diff (tests).
    public func diffIdle() async {
        while let t = diffLoading { await t.value }
    }

    private func show(diff text: String) {
        let out = NSMutableAttributedString()
        for line in text.components(separatedBy: "\n") {
            var attrs: [NSAttributedString.Key: Any] = [.font: Theme.font, .foregroundColor: NSColor.textColor]
            if line.hasPrefix("+") { attrs[.backgroundColor] = NSColor.systemGreen.withAlphaComponent(0.18) }
            if line.hasPrefix("-") { attrs[.backgroundColor] = NSColor.systemRed.withAlphaComponent(0.18) }
            if line == "…" { attrs[.foregroundColor] = NSColor.tertiaryLabelColor }
            out.append(NSAttributedString(string: line + "\n", attributes: attrs))
        }
        diffView.textStorage?.setAttributedString(out)
    }

    public func tableViewSelectionDidChange(_ notification: Notification) {
        if table.selectedRow >= 0 { showDiff(for: table.selectedRow) }
    }

    /// A path as the file list shows it: relative to the repository.
    public func relativePath(_ path: String) -> String {
        path.hasPrefix(repository.root.path + "/") ? String(path.dropFirst(repository.root.path.count + 1)) : path
    }

    /// Selects or deselects a file (the checkbox).
    public func setSelected(_ selected: Bool, path: String) {
        guard let i = rows.firstIndex(where: { $0.path == path }) else { return }
        rows[i].selected = selected
        if isViewLoaded { table.reloadData() }
    }

    /// Commits the selected files with the message. Returns the commit hash.
    /// git commit runs in the background (hooks may take a while).
    @discardableResult
    public func commit() async -> String? {
        let files = rows.filter(\.selected).map(\.path)
        let repo = repository, message = messageView.string
        let result = await Task.detached { () -> Result<String, GitRepository.GitError> in
            do { return .success(try repo.commit(files: files, message: message)) } catch {
                return .failure(error as? GitRepository.GitError ?? GitRepository.GitError(description: "\(error)"))
            }
        }.value
        switch result {
        case .success(let hash):
            lastError = nil
            onCommitted?(hash)
            if presentingViewController != nil { dismiss(nil) }
            return hash
        case .failure(let error):
            lastError = "\(error)"
            if isViewLoaded, view.window != nil { presentError(error) }
            return nil
        }
    }

    @objc private func commitClicked() { Task { await commit() } }
    @objc private func cancel(_ sender: Any?) { if presentingViewController != nil { dismiss(nil) } }

    @objc private func toggled(_ b: NSButton) {
        rows[b.tag].selected = b.state == .on
    }

    public func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    public func tableView(_ tableView: NSTableView, viewFor c: NSTableColumn?, row: Int) -> NSView? {
        let r = rows[row]
        switch c?.identifier.rawValue {
        case "on":
            let b = NSButton(checkboxWithTitle: "", target: self, action: #selector(toggled(_:)))
            b.state = r.selected ? .on : .off
            b.tag = row
            return b
        case "status":
            let l = NSTextField(labelWithString: r.status.rawValue)
            l.font = .boldSystemFont(ofSize: 11)
            l.textColor = .secondaryLabelColor
            return l
        default:
            return NSTextField(labelWithString: relativePath(r.path))
        }
    }
}
