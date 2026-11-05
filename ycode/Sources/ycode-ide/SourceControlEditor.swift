import Foundation
import SwiftUI
import YcodeIDECore
import YcodeIDEShell

/// Texts of the commit editor (`reference-ui-4.md` §2.3).
enum SourceControlEditorText {
    static let placeholder = "Commit message (required)"
    static let scopes = ["All Changes", "Unstaged", "Staged"]
    /// Lines a card shows before "N more lines".
    static let cardLineLimit = 400
}

/// What the editor area shows while a change, branch, tag or stash is
/// selected in the Source Control navigator: the commit editor or the
/// history, with the debug bar under it (as the source editor has it).
struct SourceControlPaneView: View {
    var model: WorkspaceShellModel
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let c = ShellColors(scheme)
        let scm = model.sourceControl
        VStack(spacing: 0) {
            SourceControlPathBar(scm: scm)
            Hairline(color: c.separator)
            Group {
                switch scm.pane {
                case .commit?: CommitEditorView(scm: scm)
                case .history?: BranchHistoryView(scm: scm, model: model)
                case .conflicts?:
                    if let e = scm.conflictEditor { ConflictEditorView(editor: e) } else { Color.clear }
                case nil: Color.clear
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(c.content)
            DebugBar(model: model)
        }
        .shellTarget("editor")
    }
}

/// The band above the pane, where the jump bar is: "Source Control ›
/// <repository> › Uncommitted Changes" or "› <branch>".
struct SourceControlPathBar: View {
    var scm: SourceControlShellModel
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let c = ShellColors(scheme)
        let last: String = switch scm.pane {
        case .commit?: "Uncommitted Changes"
        case .history(_, let title, _)?: title
        case .conflicts?: scm.conflictEditor?.state.title ?? "Conflicts"
        case nil: ""
        }
        HStack(spacing: 4) {
            Image(systemName: "arrow.triangle.branch").font(.system(size: 11)).foregroundStyle(c.secondaryLabel)
            Text("Source Control").font(ShellFonts.small.weight(.medium)).foregroundStyle(c.label)
            chevron(c)
            Image(systemName: "externaldrive").font(.system(size: 11)).foregroundStyle(c.secondaryLabel)
            Text(verbatim: scm.repositoryName).font(ShellFonts.small.weight(.medium)).foregroundStyle(c.label)
            chevron(c)
            Text(verbatim: last).font(ShellFonts.small.weight(.medium)).foregroundStyle(c.label).lineLimit(1)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8)
        .frame(height: CGFloat(WorkspaceChrome.jumpBarBandHeight))
        .overlay(alignment: .top) { Hairline(color: c.separator) }
        .shellTarget("scm path bar")
    }

    func chevron(_ c: ShellColors) -> some View {
        Image(systemName: "chevron.right").font(.system(size: 7, weight: .semibold)).foregroundStyle(c.tertiaryLabel)
    }
}

// MARK: - Commit editor

/// The commit editor (`reference-ui-4.md` §2.3): the author, Amend and
/// Commit (with Commit and Push in its menu); the message; the scope and
/// Stage All; one card per change with its diff.
struct CommitEditorView: View {
    var scm: SourceControlShellModel
    @Environment(\.colorScheme) private var scheme
    @FocusState private var messageFocused: Bool

    var body: some View {
        let c = ShellColors(scheme)
        VStack(alignment: .leading, spacing: 0) {
            header(c)
            message(c)
                .padding(.horizontal, 16)
            HStack(spacing: 10) {
                TextSegments(titles: SourceControlEditorText.scopes, selected: scm.scope.rawValue, target: "scm scope") { i in
                    scm.scope = GitRepository.DiffScope(rawValue: i) ?? .all
                }
                .frame(width: 270)
                Spacer()
                Text(verbatim: summary).font(ShellFonts.small).foregroundStyle(c.secondaryLabel)
                Button("Stage All") { scm.stageAll() }
                    .disabled(!scm.snapshot.changes.contains(where: \.isUnstaged) || scm.busy != nil)
                    .shellTarget("scm stage all")
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            Hairline(color: c.separator)
            if scm.cards.isEmpty {
                Text(verbatim: scm.snapshot.changes.isEmpty ? "No Changes" : "No \(SourceControlEditorText.scopes[scm.scope.rawValue]) Changes")
                    .font(Font.system(size: 15)).foregroundStyle(c.secondaryLabel)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 12) {
                            ForEach(scm.cards) { card in
                                ChangeCardView(card: card, scm: scm).id(card.path)
                            }
                        }
                        .padding(16)
                    }
                    .task(id: focusPath) {
                        if let f = focusPath { proxy.scrollTo(f, anchor: .top) }
                    }
                }
                .shellTarget("scm cards")
            }
        }
        .shellTarget("commit editor")
    }

    var focusPath: String? {
        if case .commit(let f)? = scm.pane, scm.cards.contains(where: { $0.path == f }) { return f }
        return nil
    }

    var summary: String {
        let n = scm.snapshot.changes.count, staged = scm.snapshot.changes.filter(\.isStaged).count
        return "\(n) change\(n == 1 ? "" : "s"), \(staged) staged"
    }

    func header(_ c: ShellColors) -> some View {
        HStack(spacing: 10) {
            let name = scm.author?.name ?? ""
            Text(verbatim: Self.initials(name))
                .font(Font.system(size: 13, weight: .semibold))
                .foregroundStyle(Color.white)
                .frame(width: 32, height: 32)
                .background { Circle().fill(c.secondaryLabel) }
            VStack(alignment: .leading, spacing: 1) {
                Text(verbatim: name.isEmpty ? "No Author" : name).font(ShellFonts.rowBold).foregroundStyle(c.label).lineLimit(1)
                Text(verbatim: scm.author?.email ?? "Set user.name and user.email in git's configuration.").font(ShellFonts.small).foregroundStyle(c.secondaryLabel).lineLimit(1)
            }
            .shellTarget("scm author")
            Spacer()
            HStack(spacing: 8) {
                Text(verbatim: scm.snapshot.head.map { "Amend \u{201C}\($0.prefix(7))\u{201D}" } ?? "Amend").font(ShellFonts.small)
                    .foregroundStyle(scm.snapshot.head == nil ? c.tertiaryLabel : c.label)
                Toggle("", isOn: Binding(get: { scm.amend }, set: { scm.amend = $0 }))
                    .toggleStyle(.switch)
                    .labelsHidden()
                    .controlSize(.small)
                    .disabled(scm.snapshot.head == nil)
                    .shellTarget("scm amend")
            }
            .padding(.trailing, 6)
            HStack(spacing: 0) {
                Button { scm.commit() } label: {
                    Text("Commit").font(ShellFonts.row.weight(.semibold)).foregroundStyle(scm.canCommit ? Color.white : c.tertiaryLabel)
                        .padding(.horizontal, 12).frame(height: 24)
                }
                .buttonStyle(.plain)
                .disabled(!scm.canCommit)
                .keyboardShortcut(.return, modifiers: .command)
                .shellTarget("scm commit")
                Rectangle().fill(Color.white.opacity(0.35)).frame(width: 1, height: 14)
                Menu {
                    Button("Commit") { scm.commit() }.disabled(!scm.canCommit)
                    Button("Commit and Push") { scm.commit(andPush: true) }.disabled(!scm.canCommit || !scm.hasRemote)
                } label: {
                    Image(systemName: "chevron.down").font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(scm.canCommit ? Color.white : c.tertiaryLabel)
                        .frame(width: 22, height: 24)
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .shellTarget("scm commit menu")
            }
            .background { Capsule(style: .continuous).fill(scm.canCommit ? c.accent : c.popUpFill) }
        }
        .padding(.horizontal, 16)
        .padding(.top, 14)
        .padding(.bottom, 10)
    }

    func message(_ c: ShellColors) -> some View {
        TextEditor(text: Binding(get: { scm.message }, set: { scm.message = $0 }))
            .font(ShellFonts.row)
            .focused($messageFocused)
            .frame(height: 72)
            .overlay(alignment: .topLeading) {
                if scm.message.isEmpty {
                    Text(SourceControlEditorText.placeholder).font(ShellFonts.row).foregroundStyle(c.tertiaryLabel)
                        .padding(.leading, 5).padding(.top, 1).allowsHitTesting(false)
                }
            }
            .shellTarget("scm message")
    }

    static func initials(_ name: String) -> String {
        let s = String(name.split(separator: " ").prefix(2).compactMap(\.first)).uppercased()
        return s.isEmpty ? "?" : s
    }
}

/// One change's card: disclosure, icon, name and folder, stage toggle,
/// discard, status letter; the diff with old and new line numbers and a
/// bar beside each added or removed line.
struct ChangeCardView: View {
    var card: ChangeCard
    var scm: SourceControlShellModel
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let c = ShellColors(scheme)
        let open = !scm.collapsedCards.contains(card.path)
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Button { toggle() } label: {
                    Image(systemName: open ? "chevron.down" : "chevron.right").font(.system(size: 9, weight: .semibold)).foregroundStyle(c.chevron)
                        .frame(width: 14, height: 20).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                Image(systemName: card.symbol).font(.system(size: 12)).foregroundStyle(c.accent)
                Text(verbatim: card.title).font(ShellFonts.rowBold).foregroundStyle(c.label).lineLimit(1)
                Text(verbatim: folder).font(ShellFonts.small).foregroundStyle(c.secondaryLabel).lineLimit(1)
                Spacer(minLength: 6)
                let stats = card.stats
                if stats.added + stats.removed > 0 {
                    Text(verbatim: "+\(stats.added) \u{2212}\(stats.removed)").font(ShellFonts.small.monospacedDigit()).foregroundStyle(c.secondaryLabel)
                }
                Button(card.isStaged ? "Unstage" : "Stage") { scm.toggleStaged(card) }
                    .controlSize(.small)
                    .disabled(scm.busy != nil)
                    .shellTarget("scm card stage \(card.title)")
                Button { scm.askDiscard(card.path) } label: {
                    Image(systemName: "arrow.uturn.backward").font(.system(size: 11)).foregroundStyle(c.secondaryLabel)
                }
                .buttonStyle(.plain)
                .help("Discard Changes")
                .shellTarget("scm card discard \(card.title)")
                StatusLetter(letter: card.status.rawValue, boxed: true, colors: c)
            }
            .padding(.horizontal, 10)
            .frame(height: 30)
            .contentShape(Rectangle())
            .onTapGesture { toggle() }
            if open {
                Hairline(color: c.separator)
                DiffLinesView(lines: card.lines, colors: c)
                    .padding(.vertical, 4)
            }
        }
        .background {
            RoundedRectangle(cornerRadius: 8, style: .continuous).fill(c.content)
                .overlay { RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(c.separator, lineWidth: 1) }
        }
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .shellTarget("scm card \(card.title)")
    }

    var folder: String {
        guard let root = scm.repository?.root.path else { return "" }
        let dir = (card.path as NSString).deletingLastPathComponent
        return dir == root ? "" : String(dir.dropFirst(root.count + 1))
    }

    func toggle() {
        if scm.collapsedCards.contains(card.path) { scm.collapsedCards.remove(card.path) } else { scm.collapsedCards.insert(card.path) }
    }
}

/// A diff's lines: old and new numbers, a bar for added and removed lines
/// on a tinted band, a separator line for each hunk.
struct DiffLinesView: View {
    var lines: [UnifiedDiffLines.Line]
    var colors: ShellColors

    var body: some View {
        let c = colors
        let shown = lines.prefix(SourceControlEditorText.cardLineLimit)
        VStack(alignment: .leading, spacing: 0) {
            if lines.isEmpty {
                Text("No differences to show (a binary or empty file).").font(ShellFonts.small).foregroundStyle(c.secondaryLabel)
                    .padding(.horizontal, 12).padding(.vertical, 6)
            }
            ForEach(Array(shown.enumerated()), id: \.offset) { pair in
                row(pair.element, c)
            }
            if lines.count > shown.count {
                Text(verbatim: "\(lines.count - shown.count) more lines").font(ShellFonts.small).foregroundStyle(c.secondaryLabel)
                    .padding(.horizontal, 12).padding(.vertical, 4)
            }
        }
    }

    func row(_ l: UnifiedDiffLines.Line, _ c: ShellColors) -> some View {
        let mono = Font.system(size: 11, design: .monospaced)
        let tint: Color = switch l.kind {
        case .added: Color.green.opacity(0.14)
        case .removed: Color.red.opacity(0.14)
        default: Color.clear
        }
        let bar: Color = switch l.kind {
        case .added: Color.green
        case .removed: Color.red
        default: Color.clear
        }
        return HStack(spacing: 0) {
            if l.kind == .hunk {
                Text(verbatim: "\u{2504}  " + l.text).font(mono).foregroundStyle(c.tertiaryLabel).lineLimit(1)
                    .padding(.leading, 12)
            } else {
                Text(verbatim: l.old.map(String.init) ?? "").font(mono).foregroundStyle(c.tertiaryLabel).frame(width: 40, alignment: .trailing)
                Text(verbatim: l.new.map(String.init) ?? "").font(mono).foregroundStyle(c.tertiaryLabel).frame(width: 40, alignment: .trailing)
                Rectangle().fill(bar).frame(width: 3).padding(.leading, 8).padding(.trailing, 8)
                Text(verbatim: l.text.replacingOccurrences(of: "\t", with: "    ")).font(mono).foregroundStyle(c.label).lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .frame(height: 16)
        .background(tint)
    }
}

// MARK: - History

/// A branch's, tag's or stash's history (`reference-ui-4.md` §2.5–§2.6):
/// the time scope and filter, one row per commit; a selected commit's
/// detail below.
struct BranchHistoryView: View {
    var scm: SourceControlShellModel
    var model: WorkspaceShellModel
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let c = ShellColors(scheme)
        let commits = scm.shownHistory
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                TextSegments(titles: HistoryScope.titles, selected: scm.historyScope.rawValue, target: "scm history scope") { i in
                    scm.historyScope = HistoryScope(rawValue: i) ?? .all
                }
                .frame(width: 400)
                Spacer()
                HStack(spacing: 4) {
                    Image(systemName: "line.3.horizontal.decrease").font(.system(size: 11)).foregroundStyle(c.secondaryLabel)
                    TextField("Filter", text: Binding(get: { scm.historyFilter }, set: { scm.historyFilter = $0 }))
                        .textFieldStyle(.plain).font(ShellFonts.row)
                        .shellTarget("scm history filter")
                }
                .padding(.horizontal, 8)
                .frame(width: 180, height: 22)
                .background { Capsule(style: .continuous).stroke(c.fieldStroke, lineWidth: 1) }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            Hairline(color: c.separator)
            if commits.isEmpty {
                Text(scm.history.isEmpty ? "No Commits" : "No Matching Commits").font(Font.system(size: 15)).foregroundStyle(c.secondaryLabel)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(commits, id: \.hash) { commit in
                            CommitRowView(commit: commit, isSelected: scm.selectedCommit == commit.hash, colors: c)
                                .contentShape(Rectangle())
                                .onTapGesture { scm.selectedCommit = commit.hash }
                                .contextMenu {
                                    Button("Cherry-Pick \u{201C}\(commit.shortHash)\u{201D}") { scm.perform(.cherryPick(commit.hash)) }
                                    Button("New Branch from \u{201C}\(commit.shortHash)\u{201D}…") { scm.choose(.newBranch(from: commit.hash)) }
                                    Button("New Tag from \u{201C}\(commit.shortHash)\u{201D}…") { scm.choose(.newTag(at: commit.hash)) }
                                }
                                .shellTarget("scm commit \(commit.shortHash)")
                        }
                    }
                }
                .frame(maxHeight: .infinity)
                .shellTarget("scm history")
            }
            if let d = scm.commitDetail {
                Hairline(color: c.separator)
                CommitDetailView(detail: d, scm: scm, model: model, colors: c)
                    .frame(height: 230)
            }
        }
    }
}

/// One history row: initials, author, branch and tag badges, subject; the
/// short hash and the relative day at the right.
struct CommitRowView: View {
    var commit: GitRepository.Commit
    var isSelected: Bool
    var colors: ShellColors

    var body: some View {
        let c = colors
        HStack(alignment: .top, spacing: 10) {
            Text(verbatim: CommitEditorView.initials(commit.authorName))
                .font(Font.system(size: 11, weight: .semibold)).foregroundStyle(Color.white)
                .frame(width: 26, height: 26)
                .background { Circle().fill(c.secondaryLabel) }
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(verbatim: commit.authorName).font(ShellFonts.rowBold).foregroundStyle(c.label).lineLimit(1)
                    ForEach(commit.branches, id: \.self) { b in badge(b, symbol: "arrow.triangle.branch", c) }
                    ForEach(commit.tags, id: \.self) { t in badge(t, symbol: "tag", c) }
                }
                Text(verbatim: commit.subject).font(ShellFonts.row).foregroundStyle(c.label).lineLimit(2)
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 2) {
                Text(verbatim: commit.shortHash).font(Font.system(size: 11, design: .monospaced)).foregroundStyle(c.secondaryLabel)
                Text(verbatim: GitDates.relativeDay(commit.date)).font(ShellFonts.small).foregroundStyle(c.secondaryLabel)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 7)
        .background {
            if isSelected { RoundedRectangle(cornerRadius: 6, style: .continuous).fill(c.rowSelection).padding(.horizontal, 6) }
        }
    }

    func badge(_ s: String, symbol: String, _ c: ShellColors) -> some View {
        HStack(spacing: 3) {
            Image(systemName: symbol).font(.system(size: 9))
            Text(verbatim: s).font(ShellFonts.mini.weight(.medium)).lineLimit(1)
        }
        .foregroundStyle(c.secondaryLabel)
        .padding(.horizontal, 6)
        .frame(height: 16)
        .background { Capsule(style: .continuous).stroke(c.capsuleStroke, lineWidth: 1) }
    }
}

/// The selected commit (`reference-ui-4.md` §2.6): "Commit › <repository>",
/// the author, date, short hash and message, then its files.
struct CommitDetailView: View {
    var detail: CommitDetail
    var scm: SourceControlShellModel
    var model: WorkspaceShellModel
    var colors: ShellColors

    var body: some View {
        let c = colors
        let commit = detail.commit
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 4) {
                Text("Commit").font(ShellFonts.small.weight(.medium)).foregroundStyle(c.label)
                Image(systemName: "chevron.right").font(.system(size: 7, weight: .semibold)).foregroundStyle(c.tertiaryLabel)
                Text(verbatim: scm.repositoryName).font(ShellFonts.small.weight(.medium)).foregroundStyle(c.label)
                Image(systemName: "chevron.right").font(.system(size: 7, weight: .semibold)).foregroundStyle(c.tertiaryLabel)
                Text("No Selection").font(ShellFonts.small).foregroundStyle(c.secondaryLabel)
                Spacer()
            }
            .padding(.horizontal, 12)
            .frame(height: 24)
            Hairline(color: c.separator)
            HStack(alignment: .top, spacing: 16) {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        Text(verbatim: commit.authorName).font(ShellFonts.rowBold).foregroundStyle(c.label)
                        Text(verbatim: commit.authorEmail).font(ShellFonts.small).foregroundStyle(c.secondaryLabel)
                    }
                    HStack(spacing: 8) {
                        Text(verbatim: GitDates.detail(commit.date)).font(ShellFonts.small).foregroundStyle(c.secondaryLabel)
                        Text(verbatim: commit.shortHash).font(Font.system(size: 10, design: .monospaced)).foregroundStyle(c.secondaryLabel)
                            .padding(.horizontal, 5).frame(height: 15)
                            .background { Capsule(style: .continuous).stroke(c.capsuleStroke, lineWidth: 1) }
                    }
                    ScrollView {
                        Text(verbatim: commit.message).font(ShellFonts.row).foregroundStyle(c.label)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .padding(.top, 4)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Files").font(ShellFonts.smallBold).foregroundStyle(c.label).padding(.bottom, 2)
                    ScrollView {
                        VStack(alignment: .leading, spacing: 0) {
                            ForEach(detail.files) { f in
                                HStack(spacing: 6) {
                                    Image(systemName: f.symbol).font(.system(size: 11)).foregroundStyle(c.accent)
                                    Text(verbatim: f.name).font(ShellFonts.row).foregroundStyle(c.label).lineLimit(1)
                                    Spacer(minLength: 4)
                                    StatusLetter(letter: f.status.rawValue, boxed: true, colors: c)
                                }
                                .frame(height: 20)
                                .help(f.path)
                                .contentShape(Rectangle())
                                .onTapGesture { openFile(f) }
                            }
                        }
                    }
                }
                .frame(width: 240)
            }
            .padding(12)
        }
        .shellTarget("scm commit detail")
    }

    func openFile(_ f: CommitFile) {
        guard let root = scm.repository?.root else { return }
        let p = root.appendingPathComponent(f.path).path
        if FileManager.default.fileExists(atPath: p) { model.open(scm.workspacePath(p)) }
    }
}

// MARK: - Inspector

/// The History inspector for the open file (`reference-ui-5.md` §7.4):
/// the commits that changed it, newest first.
struct FileHistoryInspector: View {
    var model: WorkspaceShellModel
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let c = ShellColors(scheme)
        let scm = model.sourceControl
        Group {
            if model.document == nil {
                Text("No History").font(Font.system(size: 13)).foregroundStyle(c.secondaryLabel)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if scm.repository == nil {
                Text(scm.hasRead ? "Not in a Repository" : "No History").font(Font.system(size: 13)).foregroundStyle(c.secondaryLabel)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if scm.fileHistory.isEmpty {
                Text("No Commits").font(Font.system(size: 13)).foregroundStyle(c.secondaryLabel)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(scm.fileHistory, id: \.hash) { commit in
                            VStack(alignment: .leading, spacing: 2) {
                                Text(verbatim: commit.subject).font(ShellFonts.small.weight(.semibold)).foregroundStyle(c.label).lineLimit(2)
                                HStack(spacing: 6) {
                                    Text(verbatim: commit.authorName).font(ShellFonts.small).foregroundStyle(c.secondaryLabel).lineLimit(1)
                                    Spacer(minLength: 4)
                                    Text(verbatim: commit.shortHash).font(Font.system(size: 10, design: .monospaced)).foregroundStyle(c.secondaryLabel)
                                }
                                Text(verbatim: GitDates.detail(commit.date)).font(ShellFonts.mini).foregroundStyle(c.tertiaryLabel)
                            }
                            .padding(.horizontal, CGFloat(WorkspaceChrome.inspectorContentInset))
                            .padding(.vertical, 7)
                            Hairline(color: c.separator).padding(.horizontal, 8)
                        }
                    }
                }
            }
        }
        .task(id: model.document?.path) { scm.showFileHistory(for: model.document?.path) }
        .shellTarget("file history")
    }
}

/// The inspector while a history is shown: its branch (Name, Remote,
/// Remote Branch) and the selected commit (Identifier, Date, Author,
/// Verification, Branches, Commit Message, Files).
struct SourceControlInspector: View {
    var scm: SourceControlShellModel
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let c = ShellColors(scheme)
        ScrollView {
            if scm.pane?.isHistory == false {
                changeInspector(c)
                    .padding(.horizontal, CGFloat(WorkspaceChrome.inspectorContentInset))
                    .padding(.top, CGFloat(WorkspaceChrome.inspectorContentTopInset))
            } else {
                historyInspector(c)
            }
        }
        .shellTarget("scm inspector")
    }

    /// The commit editor's selected change and the repository.
    func changeInspector(_ c: ShellColors) -> some View {
        let s = scm.snapshot
        let path = scm.selectedFile
        let change = s.changes.first { $0.path == path }
        let root = scm.repository?.root.path ?? ""
        return VStack(alignment: .leading, spacing: 0) {
            if let path, let change {
                let url = URL(fileURLWithPath: path)
                section("Change", [("Name", url.lastPathComponent), ("Type", WorkspaceChrome.fileTypeName(for: url)),
                                   ("Status", StatusLetter.meaning(change.status.rawValue)),
                                   ("Staged", change.isStaged ? (change.isUnstaged ? "Partly" : "Yes") : "No"),
                                   ("Relative Path", path.hasPrefix(root + "/") ? String(path.dropFirst(root.count + 1)) : path)], c)
                Hairline(color: c.separator).padding(.vertical, 10)
            }
            section("Repository", [("Name", scm.repositoryName), ("Branch", s.currentBranch ?? "HEAD (detached)"),
                                   ("Location", root), ("Remotes", s.remotes.map(\.name).joined(separator: "\n")),
                                   ("Changes", "\(s.changes.count)")], c)
        }
    }

    func historyInspector(_ c: ShellColors) -> some View {
            VStack(alignment: .leading, spacing: 0) {
                if !scm.branchInfo.isEmpty {
                    section("Branch", scm.branchInfo, c)
                }
                if let d = scm.commitDetail {
                    if !scm.branchInfo.isEmpty { Hairline(color: c.separator).padding(.vertical, 10) }
                    section("Commit", scm.commitRows, c)
                    keyed("Commit Message", c)
                    Text(verbatim: d.commit.message).font(ShellFonts.small).foregroundStyle(c.label).padding(.leading, 8).padding(.bottom, 6)
                    keyed("Files", c)
                    ForEach(d.files) { f in
                        HStack(spacing: 6) {
                            Image(systemName: f.symbol).font(.system(size: 11)).foregroundStyle(c.accent)
                            Text(verbatim: f.name).font(ShellFonts.small).foregroundStyle(c.label).lineLimit(1)
                            Spacer(minLength: 4)
                            StatusLetter(letter: f.status.rawValue, boxed: true, colors: c)
                        }
                        .padding(.leading, 8)
                        .frame(height: 18)
                    }
                }
                if scm.branchInfo.isEmpty, scm.commitDetail == nil {
                    Text("No Selection").font(Font.system(size: 13)).foregroundStyle(c.secondaryLabel)
                        .frame(maxWidth: .infinity).padding(.top, 40)
                }
            }
            .padding(.horizontal, CGFloat(WorkspaceChrome.inspectorContentInset))
            .padding(.top, CGFloat(WorkspaceChrome.inspectorContentTopInset))
    }

    func section(_ title: String, _ rows: [(key: String, value: String)], _ c: ShellColors) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(verbatim: title).font(ShellFonts.smallBold).foregroundStyle(c.label).padding(.bottom, 2)
            ForEach(Array(rows.enumerated()), id: \.offset) { pair in
                HStack(alignment: .firstTextBaseline, spacing: CGFloat(WorkspaceChrome.inspectorKeyToValue)) {
                    Text(verbatim: pair.element.key).font(ShellFonts.small).foregroundStyle(c.secondaryLabel)
                        .frame(width: CGFloat(WorkspaceChrome.inspectorKeyColumnWidth), alignment: .trailing)
                    Text(verbatim: pair.element.value.isEmpty ? "—" : pair.element.value).font(ShellFonts.small).foregroundStyle(c.label)
                        .lineLimit(6)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }

    func keyed(_ title: String, _ c: ShellColors) -> some View {
        Text(verbatim: title).font(ShellFonts.small).foregroundStyle(c.secondaryLabel).padding(.top, 8).padding(.bottom, 2)
    }
}
