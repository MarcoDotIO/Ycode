import AppKit

/// A branch's history in the editor area (`reference-ui-4.md` §2.5–§2.6):
/// a scope bar with a filter, one row per commit, and a commit detail pane
/// below once a commit is selected.
@MainActor
public final class BranchHistoryController: NSViewController, NSTableViewDataSource, NSTableViewDelegate, NSSearchFieldDelegate {
    public let repository: GitRepository
    public let ref: String
    public let scopeBar = NSSegmentedControl(labels: HistoryScope.titles, trackingMode: .selectOne, target: nil, action: nil)
    public let filterField = NSSearchField()
    public let table = NSTableView()
    /// Every commit of the branch (newest first) and those shown.
    public private(set) var allCommits: [GitRepository.Commit] = []
    public private(set) var shown: [GitRepository.Commit] = []
    public private(set) var selectedCommit: GitRepository.Commit?
    public let detailPane = NSView()
    public let pathBar = NSTextField(labelWithString: "")
    public let detailAuthor = NSTextField(labelWithString: "")
    public let detailDate = NSTextField(labelWithString: "")
    public let detailHash = NSTextField(labelWithString: "")
    public let detailMessage = NSTextField(wrappingLabelWithString: "")
    private var detailHeight: NSLayoutConstraint!
    public var onSelectCommit: ((GitRepository.Commit?) -> Void)?
    var now: () -> Date = Date.init
    /// The background read of the log, while it runs.
    public private(set) var loading: Task<Void, Never>?
    private var loadGeneration = 0
    /// The inspector rows of the selection, while they are read.
    var inspectorLoading: Task<Void, Never>?

    public init(repository: GitRepository, ref: String) {
        self.repository = repository
        self.ref = ref
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    public var scope: HistoryScope { HistoryScope(rawValue: scopeBar.selectedSegment) ?? .all }

    public override func loadView() {
        let root = PanelBackgroundView(frame: NSRect(x: 0, y: 0, width: 760, height: 560))
        scopeBar.selectedSegment = 0
        scopeBar.controlSize = .small
        scopeBar.target = self
        scopeBar.action = #selector(refilter)
        filterField.placeholderString = "Filter"
        filterField.controlSize = .small
        filterField.delegate = self
        let col = NSTableColumn(identifier: .init("commit"))
        col.resizingMask = .autoresizingMask
        table.addTableColumn(col)
        table.headerView = nil
        table.rowHeight = 36
        table.dataSource = self
        table.delegate = self
        table.style = .fullWidth
        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        pathBar.font = .systemFont(ofSize: 11)
        pathBar.textColor = .secondaryLabelColor
        detailHash.font = .monospacedSystemFont(ofSize: 10, weight: .medium)
        detailHash.wantsLayer = true
        detailHash.layer?.borderWidth = 1
        detailHash.layer?.cornerRadius = 3
        detailHash.layer?.borderColor = NSColor.tertiaryLabelColor.cgColor
        detailDate.textColor = .secondaryLabelColor
        detailDate.font = .systemFont(ofSize: 11)
        detailAuthor.font = .boldSystemFont(ofSize: 12)
        detailMessage.isSelectable = true
        let sep = NSBox()
        sep.boxType = .separator
        for v in [pathBar, sep, detailAuthor, detailDate, detailHash, detailMessage] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            detailPane.addSubview(v)
        }
        NSLayoutConstraint.activate([
            sep.topAnchor.constraint(equalTo: detailPane.topAnchor),
            sep.leadingAnchor.constraint(equalTo: detailPane.leadingAnchor),
            sep.trailingAnchor.constraint(equalTo: detailPane.trailingAnchor),
            pathBar.topAnchor.constraint(equalTo: sep.bottomAnchor, constant: 4),
            pathBar.leadingAnchor.constraint(equalTo: detailPane.leadingAnchor, constant: 10),
            detailAuthor.topAnchor.constraint(equalTo: pathBar.bottomAnchor, constant: 8),
            detailAuthor.leadingAnchor.constraint(equalTo: detailPane.leadingAnchor, constant: 12),
            detailHash.trailingAnchor.constraint(equalTo: detailPane.trailingAnchor, constant: -12),
            detailHash.centerYAnchor.constraint(equalTo: detailAuthor.centerYAnchor),
            detailDate.topAnchor.constraint(equalTo: detailAuthor.bottomAnchor, constant: 2),
            detailDate.leadingAnchor.constraint(equalTo: detailAuthor.leadingAnchor),
            detailMessage.topAnchor.constraint(equalTo: detailDate.bottomAnchor, constant: 10),
            detailMessage.leadingAnchor.constraint(equalTo: detailAuthor.leadingAnchor),
            detailMessage.trailingAnchor.constraint(equalTo: detailPane.trailingAnchor, constant: -12),
        ])
        for v in [scopeBar, filterField, scroll, detailPane] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(v)
        }
        detailHeight = detailPane.heightAnchor.constraint(equalToConstant: 0)
        NSLayoutConstraint.activate([
            scopeBar.topAnchor.constraint(equalTo: root.topAnchor, constant: 8),
            scopeBar.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 10),
            filterField.centerYAnchor.constraint(equalTo: scopeBar.centerYAnchor),
            filterField.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -10),
            filterField.widthAnchor.constraint(equalToConstant: 180),
            scroll.topAnchor.constraint(equalTo: scopeBar.bottomAnchor, constant: 8),
            scroll.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: detailPane.topAnchor),
            detailPane.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            detailPane.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            detailPane.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            detailHeight,
        ])
        detailPane.isHidden = true
        view = root
        reload()
    }

    /// Re-reads the branch's log in the background, then refilters.
    public func reload() {
        let repo = repository, ref = ref
        loadGeneration += 1
        let generation = loadGeneration
        loading = Task { [weak self] in
            let commits = await Task.detached { repo.log(ref) }.value
            guard let self, generation == self.loadGeneration else { return }
            self.allCommits = commits
            self.refilter()
            self.loading = nil
        }
    }

    /// Waits for the log and the inspector rows (tests).
    public func idle() async {
        while true {
            if let t = loading { await t.value; continue }
            if let t = inspectorLoading { inspectorLoading = nil; await t.value; continue }
            return
        }
    }

    @objc public func refilter() {
        shown = scope.apply(allCommits, filter: filterField.stringValue, now: now())
        table.reloadData()
        if let s = selectedCommit, !shown.contains(s) { select(nil) }
    }

    public func controlTextDidChange(_ obj: Notification) { refilter() }

    public func setScope(_ s: HistoryScope) { scopeBar.selectedSegment = s.rawValue; refilter() }
    public func setFilter(_ text: String) { filterField.stringValue = text; refilter() }

    /// Selects a commit (or none): shows or hides the detail pane.
    public func select(_ commit: GitRepository.Commit?) {
        selectedCommit = commit
        if let c = commit, let row = shown.firstIndex(of: c), table.selectedRow != row {
            table.selectRowIndexes([row], byExtendingSelection: false)
        }
        detailPane.isHidden = commit == nil
        detailHeight.constant = commit == nil ? 0 : 170
        if let c = commit {
            pathBar.stringValue = "Commit › \(repository.root.lastPathComponent) › No Selection"
            detailAuthor.attributedStringValue = NSAttributedString(string: c.authorName, attributes: [.font: NSFont.boldSystemFont(ofSize: 12)])
                + NSAttributedString(string: "  " + c.authorEmail, attributes: [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.secondaryLabelColor])
            detailDate.stringValue = GitDates.detail(c.date)
            detailHash.stringValue = " \(c.shortHash) "
            detailMessage.stringValue = c.message
        }
        onSelectCommit?(commit)
    }

    public func tableViewSelectionDidChange(_ notification: Notification) {
        let r = table.selectedRow
        let c = shown.indices.contains(r) ? shown[r] : nil
        if c != selectedCommit { select(c) }
    }

    public func numberOfRows(in tableView: NSTableView) -> Int { shown.count }

    /// Row texts: author, badges, subject, short hash, relative day.
    public func rowTexts(_ i: Int) -> (author: String, badges: [String], subject: String, hash: String, day: String) {
        let c = shown[i]
        return (c.authorName, c.branches + c.tags, c.subject, c.shortHash, GitDates.relativeDay(c.date, now: now()))
    }

    public func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let t = rowTexts(row)
        let cell = NSView()
        let avatar = NSTextField(labelWithString: CommitEditorController.initials(t.author))
        avatar.alignment = .center
        avatar.font = .boldSystemFont(ofSize: 10)
        avatar.textColor = .white
        avatar.drawsBackground = true
        avatar.backgroundColor = .systemGray
        avatar.wantsLayer = true
        avatar.layer?.cornerRadius = 11
        let author = NSTextField(labelWithString: t.author)
        author.font = .boldSystemFont(ofSize: 11)
        let badges = NSStackView(views: t.badges.map { name in
            let b = NSTextField(labelWithString: " \(name) ")
            b.font = .systemFont(ofSize: 10, weight: .medium)
            b.wantsLayer = true
            b.layer?.cornerRadius = 3
            b.layer?.borderWidth = 1
            b.layer?.borderColor = NSColor.controlAccentColor.cgColor
            return b
        })
        badges.spacing = 4
        let subject = NSTextField(labelWithString: t.subject)
        subject.lineBreakMode = .byTruncatingTail
        subject.font = .systemFont(ofSize: 11)
        let hash = NSTextField(labelWithString: t.hash)
        hash.font = .monospacedSystemFont(ofSize: 10, weight: .regular)
        hash.textColor = .secondaryLabelColor
        let day = NSTextField(labelWithString: t.day)
        day.font = .systemFont(ofSize: 10)
        day.textColor = .secondaryLabelColor
        for v in [avatar, author, badges, subject, hash, day] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            cell.addSubview(v)
        }
        subject.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        NSLayoutConstraint.activate([
            avatar.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 8),
            avatar.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            avatar.widthAnchor.constraint(equalToConstant: 22),
            avatar.heightAnchor.constraint(equalToConstant: 22),
            author.leadingAnchor.constraint(equalTo: avatar.trailingAnchor, constant: 8),
            author.topAnchor.constraint(equalTo: cell.topAnchor, constant: 2),
            badges.leadingAnchor.constraint(equalTo: author.trailingAnchor, constant: 6),
            badges.centerYAnchor.constraint(equalTo: author.centerYAnchor),
            subject.leadingAnchor.constraint(equalTo: author.leadingAnchor),
            subject.topAnchor.constraint(equalTo: author.bottomAnchor, constant: 1),
            subject.trailingAnchor.constraint(lessThanOrEqualTo: hash.leadingAnchor, constant: -8),
            hash.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -8),
            hash.centerYAnchor.constraint(equalTo: author.centerYAnchor),
            day.trailingAnchor.constraint(equalTo: hash.trailingAnchor),
            day.centerYAnchor.constraint(equalTo: subject.centerYAnchor),
        ])
        return cell
    }
}

/// The inspector's Source Control tab: Branch and Commit sections
/// (`reference-ui-4.md` §2.5–§2.6).
@MainActor
public enum SourceControlInspector {
    /// Rows of the Branch section: Name, Remote, Remote Branch.
    public nonisolated static func branchRows(repository: GitRepository, branch: String) -> [(String, String)] {
        [("Name", branch), ("Remote", repository.remote(of: branch) ?? "No Remote"),
         ("Remote Branch", repository.upstream(of: branch) ?? "No Remote Branch")]
    }

    /// Rows of the Commit section.
    public nonisolated static func commitRows(repository: GitRepository, commit c: GitRepository.Commit) -> [(String, String)] {
        let branches = repository.branches(containing: c.hash)
        let files = repository.files(in: c.hash).map { "\($0.status.rawValue)  \($0.path)" }
        return [("Identifier", c.hash), ("Date", GitDates.detail(c.date)), ("Author", "\(c.authorName) <\(c.authorEmail)>"),
                ("Verification", c.verification), ("Branches", branches.joined(separator: "\n")),
                ("Commit Message", c.message), ("Files", files.joined(separator: "\n"))]
    }

    public static func view(sections: [(String, [(String, String)])]) -> NSView {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        stack.edgeInsets = NSEdgeInsets(top: 8, left: 10, bottom: 8, right: 10)
        for (title, rows) in sections {
            let h = NSTextField(labelWithString: title)
            h.font = .boldSystemFont(ofSize: 12)
            stack.addArrangedSubview(h)
            for (k, v) in rows {
                let key = NSTextField(labelWithString: k)
                key.font = .systemFont(ofSize: 11)
                key.textColor = .secondaryLabelColor
                if k == "Files", !v.isEmpty {
                    // reference-ui-4.md §2.6 (P16): icon, name, status letter.
                    stack.addArrangedSubview(key)
                    for f in fileRows(v) { stack.addArrangedSubview(fileRowView(f)) }
                    continue
                }
                let value = NSTextField(wrappingLabelWithString: v.isEmpty ? "—" : v)
                value.font = .systemFont(ofSize: 11)
                value.isSelectable = true
                value.preferredMaxLayoutWidth = 220
                stack.addArrangedSubview(key)
                stack.addArrangedSubview(value)
            }
        }
        return stack
    }

    /// One Files row: the file's icon, its name and its status letter.
    public struct FileRow: Equatable, Sendable {
        public var symbol: String
        public var name: String
        public var path: String
        public var status: String
    }

    /// The Files rows of a commit ("M  path" lines from `commitRows`).
    public static func fileRows(_ text: String) -> [FileRow] {
        text.split(separator: "\n").map { line in
            let parts = line.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
            let status = parts.first.map(String.init) ?? ""
            let path = parts.count > 1 ? parts[1].trimmingCharacters(in: .whitespaces) : ""
            return FileRow(symbol: fileSymbol(path), name: (path as NSString).lastPathComponent, path: path, status: status)
        }
    }

    /// Ycode's own icon for a file, by type (SF Symbols).
    public static func fileSymbol(_ path: String) -> String {
        switch (path as NSString).pathExtension.lowercased() {
        case "swift": "swift"
        case "m", "mm", "c", "cc", "cpp", "h", "hpp", "metal", "s": "chevron.left.forwardslash.chevron.right"
        case "png", "jpg", "jpeg", "gif", "heic", "pdf", "svg", "tiff": "photo"
        case "plist", "json", "xcstrings", "strings", "entitlements", "xcconfig", "yml", "yaml": "list.bullet.rectangle"
        case "storyboard", "xib": "rectangle.on.rectangle"
        case "md", "txt", "rtf": "doc.text"
        case "xcassets": "photo.on.rectangle"
        case "pbxproj", "xcodeproj", "xcworkspace": "hammer"
        case "sh", "py", "rb": "terminal"
        default: "doc"
        }
    }

    static func fileRowView(_ f: FileRow) -> NSView {
        let icon = NSImageView(image: NSImage(systemSymbolName: f.symbol, accessibilityDescription: nil) ?? NSImage())
        icon.contentTintColor = .secondaryLabelColor
        icon.setAccessibilityLabel("\(f.name) icon")
        let name = NSTextField(labelWithString: f.name)
        name.font = .systemFont(ofSize: 11)
        name.lineBreakMode = .byTruncatingMiddle
        name.toolTip = f.path
        let status = NSTextField(labelWithString: f.status)
        status.font = .systemFont(ofSize: 11, weight: .semibold)
        status.textColor = .secondaryLabelColor
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let row = NSStackView(views: [icon, name, spacer, status])
        row.spacing = 4
        row.identifier = .init("commitFile:" + f.path)
        row.widthAnchor.constraint(equalToConstant: 220).isActive = true
        return row
    }
}
