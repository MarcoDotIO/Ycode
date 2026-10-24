import AppKit

/// Lines of a unified diff with their old and new line numbers.
public enum UnifiedDiffLines {
    public enum Kind: Equatable, Sendable { case context, added, removed, hunk }
    public struct Line: Equatable, Sendable {
        public var kind: Kind
        public var old: Int?
        public var new: Int?
        public var text: String
    }

    public static func parse(_ text: String) -> [Line] {
        var out: [Line] = []
        var old = 0, new = 0
        for raw in text.components(separatedBy: "\n") {
            if raw.hasPrefix("@@") {
                // @@ -a,b +c,d @@
                let parts = raw.split(separator: " ")
                if parts.count >= 3 {
                    old = Int(parts[1].dropFirst().split(separator: ",").first ?? "") ?? 0
                    new = Int(parts[2].dropFirst().split(separator: ",").first ?? "") ?? 0
                    if old == 0 { old = 1 }
                    if new == 0 { new = 1 }
                }
                out.append(Line(kind: .hunk, old: nil, new: nil, text: raw))
            } else if raw.hasPrefix("+") {
                out.append(Line(kind: .added, old: nil, new: new, text: String(raw.dropFirst())))
                new += 1
            } else if raw.hasPrefix("-") {
                out.append(Line(kind: .removed, old: old, new: nil, text: String(raw.dropFirst())))
                old += 1
            } else if raw.hasPrefix(" ") {
                out.append(Line(kind: .context, old: old, new: new, text: String(raw.dropFirst())))
                old += 1
                new += 1
            }
        }
        return out
    }
}

/// The commit editor in the editor area (`reference-ui-4.md` §2.3):
/// author header, Amend switch, Commit, the message, the scope bar with
/// Stage All, and one collapsible diff card per changed file.
@MainActor
public final class CommitEditorController: NSViewController, NSTextViewDelegate {
    public static let scopeTitles = ["All Changes", "Unstaged", "Staged"]
    public static let placeholder = "Commit message (required)"

    public let repository: GitRepository
    public private(set) var changes: [GitRepository.Change] = []
    public let messageView = NSTextView()
    public let placeholderLabel = NSTextField(labelWithString: CommitEditorController.placeholder)
    public let amendSwitch = NSSwitch()
    public let amendLabel = NSTextField(labelWithString: "Amend")
    public let commitButton = NSButton(title: "Commit", target: nil, action: nil)
    public let commitMenuButton = NSButton()
    public let authorLabel = NSTextField(labelWithString: "")
    public let avatar = NSTextField(labelWithString: "")
    public let scope = NSSegmentedControl(labels: CommitEditorController.scopeTitles, trackingMode: .selectOne, target: nil, action: nil)
    public let stageAllButton = NSButton(title: "Stage All", target: nil, action: nil)
    private let cardStack = NSStackView()
    public private(set) var cards: [DiffCardView] = []
    public private(set) var lastError: String?
    /// After a commit, stage or discard: refresh the navigators.
    public var onChanged: (() -> Void)?
    /// The path to show first (selected in the navigator).
    public var focusPath: String?
    /// The background read of the changes and diffs, while it runs.
    public private(set) var loading: Task<Void, Never>?
    private var loadGeneration = 0
    /// A commit, stage or discard running in the background.
    public private(set) var working: Task<Void, Never>?
    private var hasRemote = false

    public init(repository: GitRepository) {
        self.repository = repository
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    public var diffScope: GitRepository.DiffScope { GitRepository.DiffScope(rawValue: scope.selectedSegment) ?? .all }

    public override func loadView() {
        let root = PanelBackgroundView(frame: NSRect(x: 0, y: 0, width: 760, height: 560))
        avatar.stringValue = ""
        avatar.alignment = .center
        avatar.font = .boldSystemFont(ofSize: 13)
        avatar.textColor = .white
        avatar.wantsLayer = true
        avatar.drawsBackground = true
        avatar.backgroundColor = .systemGray
        avatar.layer?.cornerRadius = 14
        authorLabel.maximumNumberOfLines = 2
        amendSwitch.controlSize = .small
        amendSwitch.target = self
        amendSwitch.action = #selector(amendChanged)
        amendSwitch.isEnabled = false   // until HEAD is read (reload)
        commitButton.bezelStyle = .push
        commitButton.target = self
        commitButton.action = #selector(commitClicked)
        commitButton.keyEquivalent = "\r"
        commitButton.keyEquivalentModifierMask = .command
        commitMenuButton.image = NSImage(systemSymbolName: "chevron.down", accessibilityDescription: "Commit options")
        commitMenuButton.bezelStyle = .push
        commitMenuButton.target = self
        commitMenuButton.action = #selector(commitMenuClicked(_:))
        messageView.font = .systemFont(ofSize: 13)
        messageView.isRichText = false
        messageView.delegate = self
        messageView.autoresizingMask = [.width]
        messageView.textContainerInset = NSSize(width: 4, height: 6)
        let messageScroll = NSScrollView()
        messageScroll.documentView = messageView
        messageScroll.hasVerticalScroller = true
        messageScroll.borderType = .bezelBorder
        placeholderLabel.textColor = .placeholderTextColor
        scope.selectedSegment = 0
        scope.controlSize = .small
        scope.target = self
        scope.action = #selector(scopeChanged)
        stageAllButton.controlSize = .small
        stageAllButton.target = self
        stageAllButton.action = #selector(stageAllClicked)
        cardStack.orientation = .vertical
        cardStack.alignment = .leading
        cardStack.spacing = 8
        cardStack.edgeInsets = NSEdgeInsets(top: 8, left: 8, bottom: 8, right: 8)
        let flipped = SCFlippedView()
        flipped.addSubview(cardStack)
        cardStack.translatesAutoresizingMaskIntoConstraints = false
        let cardScroll = NSScrollView()
        cardScroll.documentView = flipped
        cardScroll.hasVerticalScroller = true
        cardScroll.drawsBackground = false
        flipped.translatesAutoresizingMaskIntoConstraints = false
        for v in [avatar, authorLabel, amendSwitch, amendLabel, commitButton, commitMenuButton, messageScroll, placeholderLabel, scope, stageAllButton, cardScroll] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(v)
        }
        root.addSubview(placeholderLabel, positioned: .above, relativeTo: messageScroll)
        NSLayoutConstraint.activate([
            avatar.topAnchor.constraint(equalTo: root.topAnchor, constant: 12),
            avatar.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 12),
            avatar.widthAnchor.constraint(equalToConstant: 28),
            avatar.heightAnchor.constraint(equalToConstant: 28),
            authorLabel.leadingAnchor.constraint(equalTo: avatar.trailingAnchor, constant: 8),
            authorLabel.centerYAnchor.constraint(equalTo: avatar.centerYAnchor),
            commitMenuButton.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -12),
            commitMenuButton.centerYAnchor.constraint(equalTo: avatar.centerYAnchor),
            commitButton.trailingAnchor.constraint(equalTo: commitMenuButton.leadingAnchor, constant: -2),
            commitButton.centerYAnchor.constraint(equalTo: avatar.centerYAnchor),
            amendLabel.trailingAnchor.constraint(equalTo: commitButton.leadingAnchor, constant: -12),
            amendLabel.centerYAnchor.constraint(equalTo: avatar.centerYAnchor),
            amendSwitch.trailingAnchor.constraint(equalTo: amendLabel.leadingAnchor, constant: -4),
            amendSwitch.centerYAnchor.constraint(equalTo: avatar.centerYAnchor),
            authorLabel.trailingAnchor.constraint(lessThanOrEqualTo: amendSwitch.leadingAnchor, constant: -8),
            messageScroll.topAnchor.constraint(equalTo: avatar.bottomAnchor, constant: 10),
            messageScroll.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 12),
            messageScroll.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -12),
            messageScroll.heightAnchor.constraint(equalToConstant: 72),
            placeholderLabel.topAnchor.constraint(equalTo: messageScroll.topAnchor, constant: 7),
            placeholderLabel.leadingAnchor.constraint(equalTo: messageScroll.leadingAnchor, constant: 10),
            scope.topAnchor.constraint(equalTo: messageScroll.bottomAnchor, constant: 10),
            scope.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 12),
            stageAllButton.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -12),
            stageAllButton.centerYAnchor.constraint(equalTo: scope.centerYAnchor),
            cardScroll.topAnchor.constraint(equalTo: scope.bottomAnchor, constant: 6),
            cardScroll.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            cardScroll.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            cardScroll.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            flipped.leadingAnchor.constraint(equalTo: cardScroll.contentView.leadingAnchor),
            flipped.trailingAnchor.constraint(equalTo: cardScroll.contentView.trailingAnchor),
            flipped.topAnchor.constraint(equalTo: cardScroll.contentView.topAnchor),
            cardStack.leadingAnchor.constraint(equalTo: flipped.leadingAnchor),
            cardStack.trailingAnchor.constraint(equalTo: flipped.trailingAnchor),
            cardStack.topAnchor.constraint(equalTo: flipped.topAnchor),
            cardStack.bottomAnchor.constraint(equalTo: flipped.bottomAnchor),
        ])
        view = root
        reload()
    }

    static func initials(_ name: String) -> String {
        String(name.split(separator: " ").prefix(2).compactMap(\.first)).uppercased()
    }

    /// What `reload()` reads from git, off the main thread.
    struct Loaded: Sendable {
        var changes: [GitRepository.Change]
        var diffs: [String: String]
        var author: GitRepository.Author
        var head: String?
        var hasRemote: Bool
    }

    /// Re-reads the changes in the background, then rebuilds the cards for
    /// the current scope (and the author header and Amend label). A later
    /// reload replaces one still reading.
    public func reload() {
        let repo = repository, scope = diffScope
        loadGeneration += 1
        let generation = loadGeneration
        loading = Task { [weak self] in
            let loaded = await Task.detached { () -> Loaded in
                let changes = (try? repo.changes()) ?? []
                var diffs: [String: String] = [:]
                for c in Self.shown(changes, scope: scope) { diffs[c.path] = repo.diff(of: c.path, scope: scope) }
                return Loaded(changes: changes, diffs: diffs, author: repo.author(), head: repo.headHash(),
                              hasRemote: !((try? repo.remotes()) ?? []).isEmpty)
            }.value
            guard let self, generation == self.loadGeneration else { return }
            self.show(loaded, scope: scope)
            self.loading = nil
        }
    }

    nonisolated static func shown(_ changes: [GitRepository.Change], scope: GitRepository.DiffScope) -> [GitRepository.Change] {
        changes.filter { c in
            switch scope {
            case .all: true
            case .unstaged: c.isUnstaged
            case .staged: c.isStaged
            }
        }
    }

    private func show(_ loaded: Loaded, scope: GitRepository.DiffScope) {
        let author = loaded.author
        avatar.stringValue = Self.initials(author.name)
        authorLabel.attributedStringValue = NSAttributedString(string: author.name, attributes: [.font: NSFont.boldSystemFont(ofSize: 12)])
            + NSAttributedString(string: "\n" + author.email, attributes: [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.secondaryLabelColor])
        if let h = loaded.head { amendLabel.stringValue = "Amend \"\(h.prefix(7))\""; amendSwitch.isEnabled = true } else { amendSwitch.isEnabled = false }
        hasRemote = loaded.hasRemote
        changes = loaded.changes
        cards.forEach { $0.removeFromSuperview() }
        cards = Self.shown(changes, scope: scope).map { c in
            let card = DiffCardView(change: c, root: repository.root, diff: loaded.diffs[c.path] ?? "")
            card.onDiscard = { [weak self] path in self?.discard(path) }
            return card
        }
        if let f = focusPath, let i = cards.firstIndex(where: { $0.change.path == f }) { cards.insert(cards.remove(at: i), at: 0) }
        for c in cards {
            cardStack.addArrangedSubview(c)
            c.widthAnchor.constraint(equalTo: cardStack.widthAnchor, constant: -16).isActive = true
        }
        stageAllButton.isEnabled = changes.contains(where: \.isUnstaged)
        updateCommitEnabled()
    }

    /// Waits for the background read and any command (tests).
    public func idle() async {
        while true {
            if let t = working { await t.value; continue }
            if let t = loading { await t.value; continue }
            return
        }
    }

    /// Runs a git command in the background, then reloads and reports.
    private func run(_ body: @escaping @Sendable (GitRepository) throws -> Void) {
        let repo = repository, previous = working
        working = Task { [weak self] in
            await previous?.value
            let failure = await Task.detached { () -> String? in
                do { try body(repo); return nil } catch { return "\(error)" }
            }.value
            guard let self else { return }
            self.lastError = failure
            self.reload()
            self.onChanged?()
            self.working = nil
        }
    }

    /// Commit applies once the message is non-empty (and, unless amending,
    /// there is something to commit).
    public var canCommit: Bool {
        !messageView.string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && (amendSwitch.state == .on || !changes.isEmpty)
    }

    func updateCommitEnabled() {
        commitButton.isEnabled = canCommit
        commitMenuButton.isEnabled = canCommit
        placeholderLabel.isHidden = !messageView.string.isEmpty
    }

    public func textDidChange(_ notification: Notification) { updateCommitEnabled() }

    @objc private func amendChanged() {
        // Amending starts from HEAD's message when the field is empty.
        guard amendSwitch.state == .on, messageView.string.isEmpty else { updateCommitEnabled(); return }
        let repo = repository
        Task { [weak self] in
            let message = await Task.detached { repo.headHash().flatMap { repo.commit($0) }?.message }.value
            guard let self else { return }
            if let message, self.amendSwitch.state == .on, self.messageView.string.isEmpty { self.messageView.string = message }
            self.updateCommitEnabled()
        }
    }

    @objc private func scopeChanged() { reload() }
    @objc private func stageAllClicked() { stageAll() }

    public func stageAll() { run { try $0.stageAll() } }

    public func setScope(_ s: GitRepository.DiffScope) {
        scope.selectedSegment = s.rawValue
        reload()
    }

    public func discard(_ path: String) { run { try $0.discard(path) } }

    /// Commits: with nothing staged, every change is staged first (what the
    /// cards show); otherwise only the staged changes. Git runs in the
    /// background. Returns the hash.
    @discardableResult
    public func commit() async -> String? {
        guard canCommit else { return nil }
        await idle()
        let repo = repository, stageFirst = !changes.contains(where: \.isStaged) && !changes.isEmpty
        let message = messageView.string, amend = amendSwitch.state == .on
        let result = await Task.detached { () -> Result<String, GitRepository.GitError> in
            do {
                if stageFirst { try repo.stageAll() }
                return .success(try repo.commitStaged(message: message, amend: amend))
            } catch { return .failure(GitRepository.GitError(description: "\(error)")) }
        }.value
        switch result {
        case .success(let hash):
            lastError = nil
            messageView.string = ""
            amendSwitch.state = .off
            reload()
            onChanged?()
            return hash
        case .failure(let error):
            lastError = error.description
            return nil
        }
    }

    @objc private func commitClicked() { Task { await commit() } }

    @objc private func commitMenuClicked(_ sender: NSButton) {
        let m = NSMenu()
        m.addItem(withTitle: "Commit", action: #selector(commitClicked), keyEquivalent: "").target = self
        let push = m.addItem(withTitle: "Commit and Push", action: #selector(commitAndPush), keyEquivalent: "")
        push.target = self
        push.isEnabled = hasRemote
        m.autoenablesItems = false
        m.popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.height + 2), in: sender)
    }

    @objc private func commitAndPush() {
        Task {
            guard await commit() != nil else { return }
            run { try $0.push() }
        }
    }
}

/// One file's card: disclosure, icon and name, discard, status letter,
/// and the diff with line numbers and change bars.
@MainActor
public final class DiffCardView: NSView {
    public let change: GitRepository.Change
    public let lines: [UnifiedDiffLines.Line]
    public let disclosure = NSButton()
    public let titleLabel: NSTextField
    public let statusLabel: NSTextField
    public let discardButton = NSButton()
    public let body = NSTextView()
    private var bodyHeight: NSLayoutConstraint!
    public var onDiscard: ((String) -> Void)?
    public var isCollapsed: Bool { body.isHidden }

    public init(change: GitRepository.Change, root: URL, diff: String) {
        self.change = change
        lines = UnifiedDiffLines.parse(diff)
        let rel = SourceControlNavigatorModel.relative(change.path, root: root)
        // A workspace inside a project reads "<project> / project.xcworkspace".
        let comps = rel.split(separator: "/")
        let title: String
        if let i = comps.firstIndex(where: { $0.hasSuffix(".xcodeproj") }), i + 1 < comps.count, comps[i + 1] == "project.xcworkspace" {
            title = "\(comps[i].dropLast(".xcodeproj".count)) / project.xcworkspace"
        } else {
            title = URL(fileURLWithPath: change.path).lastPathComponent
        }
        titleLabel = NSTextField(labelWithString: title)
        statusLabel = NSTextField(labelWithString: " \(change.status.rawValue) ")
        super.init(frame: NSRect(x: 0, y: 0, width: 600, height: 100))
        wantsLayer = true
        layer?.cornerRadius = 6
        layer?.borderWidth = 1
        layer?.borderColor = NSColor.separatorColor.cgColor
        disclosure.bezelStyle = .disclosure
        disclosure.setButtonType(.pushOnPushOff)
        disclosure.title = ""
        disclosure.state = .on
        disclosure.target = self
        disclosure.action = #selector(toggle)
        let icon = NSImageView(image: NSImage(systemSymbolName: SourceControlNavigatorModel.symbol(for: change.path), accessibilityDescription: nil) ?? NSImage())
        titleLabel.font = .boldSystemFont(ofSize: 12)
        titleLabel.toolTip = rel
        statusLabel.font = .boldSystemFont(ofSize: 10)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.wantsLayer = true
        statusLabel.layer?.borderWidth = 1
        statusLabel.layer?.cornerRadius = 3
        statusLabel.layer?.borderColor = NSColor.tertiaryLabelColor.cgColor
        discardButton.image = NSImage(systemSymbolName: "arrow.uturn.backward", accessibilityDescription: "Discard changes")
        discardButton.isBordered = false
        discardButton.toolTip = "Discard Changes"
        discardButton.target = self
        discardButton.action = #selector(discardClicked)
        body.isEditable = false
        body.drawsBackground = false
        body.textContainerInset = NSSize(width: 0, height: 4)
        body.textStorage?.setAttributedString(Self.render(lines))
        let text = body.textStorage?.string ?? ""
        let lineCount = max(1, text.components(separatedBy: "\n").count - 1)
        for v in [disclosure, icon, titleLabel, discardButton, statusLabel, body] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            addSubview(v)
        }
        bodyHeight = body.heightAnchor.constraint(equalToConstant: CGFloat(lineCount) * 15 + 8)
        NSLayoutConstraint.activate([
            disclosure.topAnchor.constraint(equalTo: topAnchor, constant: 6),
            disclosure.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
            icon.leadingAnchor.constraint(equalTo: disclosure.trailingAnchor, constant: 2),
            icon.centerYAnchor.constraint(equalTo: disclosure.centerYAnchor),
            titleLabel.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 4),
            titleLabel.centerYAnchor.constraint(equalTo: disclosure.centerYAnchor),
            statusLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            statusLabel.centerYAnchor.constraint(equalTo: disclosure.centerYAnchor),
            discardButton.trailingAnchor.constraint(equalTo: statusLabel.leadingAnchor, constant: -8),
            discardButton.centerYAnchor.constraint(equalTo: disclosure.centerYAnchor),
            body.topAnchor.constraint(equalTo: disclosure.bottomAnchor, constant: 6),
            body.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 1),
            body.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -1),
            body.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -4),
            bodyHeight,
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    /// Diff text: old and new line numbers, a bar for added/removed lines.
    static func render(_ lines: [UnifiedDiffLines.Line]) -> NSAttributedString {
        let out = NSMutableAttributedString()
        let font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        func num(_ n: Int?) -> String { n.map { String($0).leftPadded(5) } ?? "     " }
        for l in lines {
            var attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.textColor]
            let bar: String
            switch l.kind {
            case .hunk:
                attrs[.foregroundColor] = NSColor.secondaryLabelColor
                out.append(NSAttributedString(string: "           ┄ " + l.text + "\n", attributes: attrs))
                continue
            case .added: bar = "▌"; attrs[.backgroundColor] = NSColor.systemGreen.withAlphaComponent(0.15)
            case .removed: bar = "▌"; attrs[.backgroundColor] = NSColor.systemRed.withAlphaComponent(0.15)
            case .context: bar = " "
            }
            let nums = NSAttributedString(string: num(l.old) + " " + num(l.new), attributes: [.font: font, .foregroundColor: NSColor.tertiaryLabelColor])
            out.append(nums)
            let barColor: NSColor = l.kind == .added ? .systemGreen : l.kind == .removed ? .systemRed : .clear
            out.append(NSAttributedString(string: bar, attributes: [.font: font, .foregroundColor: barColor]))
            out.append(NSAttributedString(string: l.text + "\n", attributes: attrs))
        }
        return out
    }

    @objc func toggle() {
        body.isHidden = disclosure.state == .off
        bodyHeight.constant = body.isHidden ? 0 : CGFloat(max(1, (body.textStorage?.string ?? "").components(separatedBy: "\n").count - 1)) * 15 + 8
    }

    public func setCollapsed(_ c: Bool) { disclosure.state = c ? .off : .on; toggle() }

    @objc private func discardClicked() { onDiscard?(change.path) }
}

final class SCFlippedView: NSView { override var isFlipped: Bool { true } }

extension String {
    func leftPadded(_ n: Int) -> String { count >= n ? self : String(repeating: " ", count: n - count) + self }
}
