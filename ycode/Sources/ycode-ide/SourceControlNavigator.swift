import Foundation
import SwiftUI
import YcodeIDECore
import YcodeIDEShell

/// The Source Control navigator (⌘2; `reference-ui-4.md` §2): the
/// Changes | Repositories control, then the repository's tree
/// (`SourceControlShellModel.rows`). Selecting a change shows the commit
/// editor, a branch, tag or stash its history; every row has the core's
/// context menu (`SourceControlRowMenu`).
struct SourceControlNavigator: View {
    var model: WorkspaceShellModel
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let scm = model.sourceControl
        let c = ShellColors(scheme)
        VStack(spacing: 0) {
            TextSegments(titles: SourceControlRows.modeTitles, selected: scm.mode.rawValue, target: "scm mode") { i in
                scm.mode = SourceControlShellModel.Mode(rawValue: i) ?? .changes
            }
            .padding(.horizontal, 10)
            .padding(.top, 8)
            .padding(.bottom, 4)
            if !scm.hasRead {
                EmptyNavigator(lines: ["Source Control", "Reading the repository…"])
            } else if scm.repository == nil {
                VStack(spacing: 10) {
                    EmptyNavigator(lines: ["No Repository", "This workspace is not in a git repository."]).fixedSize(horizontal: false, vertical: true)
                    Button("New Git Repository…") { model.perform(.scmNewRepository) }
                        .shellTarget("scm new repository")
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if scm.mode == .changes, scm.snapshot.changes.isEmpty, scm.collapsed.isEmpty {
                VStack(spacing: 0) {
                    SourceControlOutline(scm: scm, model: model)
                        .frame(height: 56)
                    EmptyNavigator(lines: ["No Changes", "The working copy matches the last commit."])
                }
            } else {
                SourceControlOutline(scm: scm, model: model)
            }
            if scm.snapshot.integration.isInProgress {
                IntegrationBanner(scm: scm)
            }
            if let busy = scm.busy {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text(verbatim: busy).font(ShellFonts.small).foregroundStyle(c.secondaryLabel)
                    Spacer()
                }
                .padding(.horizontal, 12)
                .frame(height: 22)
                .shellTarget("scm busy")
            }
        }
        .task { scm.refresh() }
        .shellTarget("scm navigator")
    }
}

/// A merge, rebase or cherry-pick stopped on conflicts: what is going on,
/// Continue (once every conflict is marked resolved) and Abort.
struct IntegrationBanner: View {
    var scm: SourceControlShellModel
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let c = ShellColors(scheme)
        let state = scm.snapshot.integration
        let conflicts = scm.snapshot.changes.filter { $0.status == .conflicted }.count
        VStack(alignment: .leading, spacing: 6) {
            Text(verbatim: "\(state.verb) in progress").font(ShellFonts.smallBold).foregroundStyle(c.label)
            Text(verbatim: conflicts > 0 ? "\(conflicts) file\(conflicts == 1 ? " has" : "s have") conflicts. Edit, then Mark as Resolved."
                 : "Every conflict is resolved.").font(ShellFonts.small).foregroundStyle(c.secondaryLabel)
            HStack {
                Button("Abort") { scm.perform(.abortIntegration) }.shellTarget("scm abort")
                Spacer()
                Button("Continue") { scm.perform(.continueIntegration) }.disabled(conflicts > 0).shellTarget("scm continue")
            }
            .controlSize(.small)
        }
        .padding(10)
        .background { RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(c.warning, lineWidth: 1) }
        .padding(.horizontal, 10)
        .padding(.bottom, 6)
        .shellTarget("scm integration")
    }
}

/// Text segments in a capsule (the navigator's Changes | Repositories,
/// the commit editor's scope, the history's time scope): the selected one
/// in a pill.
struct TextSegments: View {
    var titles: [String]
    var selected: Int
    var target: String
    var select: (Int) -> Void
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let c = ShellColors(scheme)
        HStack(spacing: 0) {
            ForEach(Array(titles.enumerated()), id: \.offset) { pair in
                let on = pair.offset == selected
                Button { select(pair.offset) } label: {
                    Text(verbatim: pair.element)
                        .font(on ? ShellFonts.small.weight(.semibold) : ShellFonts.small)
                        .foregroundStyle(c.label)
                        .lineLimit(1)
                        .padding(.horizontal, 10)
                        .frame(maxWidth: .infinity)
                        .frame(height: 20)
                        .background {
                            if on { Capsule(style: .continuous).fill(c.selectorPill) }
                        }
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .shellTarget("\(target) \(pair.offset)")
            }
        }
        .padding(2)
        .background { Capsule(style: .continuous).stroke(c.capsuleStroke, lineWidth: 1) }
    }
}

/// The navigator's outline with its context menus: the core's items, and
/// for a change Stage or Unstage and Discard Changes….
struct SourceControlOutline: View {
    var scm: SourceControlShellModel
    var model: WorkspaceShellModel
    @Environment(\.colorScheme) private var scheme
    @FocusState private var hasKeyboard: Bool

    var body: some View {
        let c = ShellColors(scheme)
        let rows = scm.rows
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(rows) { r in
                    OutlineRowView(row: r, isSelected: r.id == scm.selection, colors: c, toggle: { scm.setExpanded($0, $1) })
                        .contentShape(Rectangle())
                        .onTapGesture { select(r) }
                        .contextMenu { menu(r) }
                        .shellTarget("scm row \(r.title)")
                }
            }
            .padding(.top, CGFloat(WorkspaceChrome.firstRowGap))
            .padding(.bottom, 8)
        }
        .scrollIndicators(.hidden)
        .focusable()
        .focused($hasKeyboard)
        .onChange(of: hasKeyboard) { _, on in ShellFocus.outlineHasKeyboard = on }
        .onKeyPress(.downArrow) { move(rows, 1); return .handled }
        .onKeyPress(.upArrow) { move(rows, -1); return .handled }
        .onKeyPress(.rightArrow) { expand(rows, true); return .handled }
        .onKeyPress(.leftArrow) { expand(rows, false); return .handled }
        .shellTarget("scm outline")
    }

    func select(_ r: OutlineRow) {
        // Groups and folders open and close; everything else shows something.
        if r.id.hasPrefix("group:") || r.id.hasPrefix("folder:") || r.id.hasPrefix("remote:") {
            if r.isExpandable { scm.setExpanded(r.id, !r.isExpanded) }
            return
        }
        scm.select(r.id)
    }

    func move(_ rows: [OutlineRow], _ d: Int) {
        guard !rows.isEmpty else { return }
        let i = scm.selection.flatMap { s in rows.firstIndex { $0.id == s } } ?? (d > 0 ? -1 : rows.count)
        scm.select(rows[min(max(i + d, 0), rows.count - 1)].id)
    }

    func expand(_ rows: [OutlineRow], _ on: Bool) {
        guard let s = scm.selection, let r = rows.first(where: { $0.id == s }), r.isExpandable, r.isExpanded != on else { return }
        scm.setExpanded(s, on)
    }

    @ViewBuilder
    func menu(_ r: OutlineRow) -> some View {
        if r.id.hasPrefix("change:") {
            let path = String(r.id.dropFirst(7))
            let change = scm.snapshot.changes.first { $0.path == path }
            if change?.isStaged == true {
                Button("Unstage") { scm.perform(.unstage([path])) }
            }
            if change?.isUnstaged == true {
                Button(change?.status == .untracked ? "Add" : "Stage") { scm.perform(.stage([path])) }
            }
            Button("Discard Changes…") { scm.askDiscard(path) }
            if FileManager.default.fileExists(atPath: path) {
                Divider()
                Button("Show in Editor") { model.open(scm.workspacePath(path)) }
            }
        }
        let items = scm.menu(for: r.id)
        if !items.isEmpty, r.id.hasPrefix("change:") { Divider() }
        ForEach(Array(items.enumerated()), id: \.offset) { pair in
            let item = pair.element
            if let action = item.action {
                Button(item.title) { scm.choose(action) }.disabled(!item.isEnabled)
            } else {
                Divider()
            }
        }
    }
}

/// What a navigator row shows at its right end: a count, a source-control
/// letter (boxed in the Source Control navigator, plain in the project
/// navigator).
struct OutlineRowAccessories: View {
    var row: OutlineRow
    var colors: ShellColors

    var body: some View {
        let c = colors
        HStack(spacing: 6) {
            if let t = row.trailing {
                Text(verbatim: t).font(ShellFonts.small).tracking(ShellFonts.smallTracking).foregroundStyle(c.secondaryLabel)
            }
            if let b = row.badge {
                StatusLetter(letter: b, boxed: row.id.hasPrefix("change:"), colors: c)
            }
            if let s = row.trailingSymbol {
                Image(systemName: s).font(.system(size: 12)).foregroundStyle(c.tint(row.trailingTint))
            }
        }
        .padding(.trailing, row.trailing != nil || row.badge != nil || row.trailingSymbol != nil ? 12 : 0)
        .frame(height: CGFloat(WorkspaceChrome.rowHeight))
    }
}

/// A source-control status letter ("M", "A", "?", "D", "R", "C").
struct StatusLetter: View {
    var letter: String
    var boxed: Bool
    var colors: ShellColors

    var body: some View {
        let c = colors
        let tint = letter == "C" ? c.error : c.secondaryLabel
        Text(verbatim: letter)
            .font(Font.system(size: 10, weight: .semibold))
            .foregroundStyle(tint)
            .frame(width: 14, height: 14)
            .background {
                if boxed { RoundedRectangle(cornerRadius: 3, style: .continuous).stroke(tint, lineWidth: 1) }
            }
            .help(Self.meaning(letter))
    }

    static func meaning(_ l: String) -> String {
        switch l {
        case "M": "Modified"
        case "A": "Added"
        case "D": "Deleted"
        case "R": "Renamed"
        case "?": "Untracked"
        case "C": "Conflicted"
        default: l
        }
    }
}

// MARK: - Dialogs

/// The window's source-control dialogs: a failed command, conflicts, the
/// questions (Check Out…, Delete…), the name prompts and the commit sheet.
struct SourceControlDialogs: ViewModifier {
    var scm: SourceControlShellModel

    func body(content: Content) -> some View {
        content
            .alert("The source control operation failed", isPresented: Binding(get: { scm.errorMessage != nil }, set: { if !$0 { scm.errorMessage = nil } })) {
                Button("OK") { scm.errorMessage = nil }.keyboardShortcut(.defaultAction)
            } message: {
                Text(verbatim: scm.errorMessage ?? "")
            }
            .alert("Conflicts", isPresented: Binding(get: { scm.notice != nil }, set: { if !$0 { scm.notice = nil } })) {
                Button("OK") { scm.notice = nil }.keyboardShortcut(.defaultAction)
            } message: {
                Text(verbatim: scm.notice ?? "")
            }
            .alert(scm.confirmation?.title ?? "", isPresented: Binding(get: { scm.confirmation != nil }, set: { if !$0 { scm.confirmation = nil } })) {
                ForEach(Array((scm.confirmation?.choices ?? []).enumerated()), id: \.offset) { pair in
                    let choice = pair.element
                    Button(choice.title, role: choice.isDestructive ? .destructive : nil) { scm.confirm(choice) }
                }
                Button("Cancel", role: .cancel) { scm.confirmation = nil }
            } message: {
                Text(verbatim: scm.confirmation?.message ?? "")
            }
            .sheet(isPresented: Binding(get: { scm.prompt != nil }, set: { if !$0 { scm.prompt = nil } })) {
                SourceControlPromptSheet(scm: scm)
            }
            .sheet(isPresented: Binding(get: { scm.commitSheet != nil }, set: { if !$0 { scm.commitSheet = nil } })) {
                CommitSheetView(scm: scm)
            }
    }
}

/// New Branch…, New Tag…, Rename…, Add Remote…, Stash Changes….
struct SourceControlPromptSheet: View {
    var scm: SourceControlShellModel
    @FocusState private var first: Bool

    var body: some View {
        let p = scm.prompt
        VStack(alignment: .leading, spacing: 10) {
            Text(verbatim: p?.title ?? "").font(ShellFonts.rowBold)
            Text(verbatim: p?.message ?? "").font(ShellFonts.small)
            ForEach(Array((p?.fields ?? []).enumerated()), id: \.offset) { pair in
                HStack(spacing: 8) {
                    Text(verbatim: pair.element.label + ":").font(ShellFonts.small).frame(width: 60, alignment: .trailing)
                    TextField(pair.element.placeholder, text: Binding(get: { scm.prompt?.fields[safe: pair.offset]?.text ?? "" },
                                                                     set: { scm.prompt?.fields[pair.offset].text = $0 }))
                        .textFieldStyle(.roundedBorder)
                        .focused($first, equals: pair.offset == 0)
                        .onSubmit { scm.confirmPrompt() }
                        .shellTarget("scm prompt field \(pair.offset)")
                }
            }
            HStack {
                Spacer()
                Button("Cancel") { scm.prompt = nil }.keyboardShortcut(.cancelAction).shellTarget("scm prompt cancel")
                Button(p?.button ?? "OK") { scm.confirmPrompt() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!(p?.canConfirm ?? false))
                    .shellTarget("scm prompt confirm")
            }
        }
        .padding(16)
        .frame(width: 380)
        .task { first = true }
    }
}

/// Integrate ▸ Commit… (⌥⌘C): the changed files with checkboxes, status
/// letters and paths, the message, Cancel and Commit Files.
struct CommitSheetView: View {
    var scm: SourceControlShellModel
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let c = ShellColors(scheme)
        let sheet = scm.commitSheet
        VStack(alignment: .leading, spacing: 10) {
            Text("Commit").font(ShellFonts.rowBold)
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(Array((sheet?.files ?? []).enumerated()), id: \.offset) { pair in
                        let f = pair.element
                        HStack(spacing: 8) {
                            Toggle("", isOn: Binding(get: { scm.commitSheet?.files[safe: pair.offset]?.isOn ?? false },
                                                    set: { scm.commitSheet?.files[pair.offset].isOn = $0 }))
                                .toggleStyle(.checkbox)
                                .labelsHidden()
                                .shellTarget("commit sheet file \(pair.offset)")
                            StatusLetter(letter: f.status.rawValue, boxed: true, colors: c)
                            Text(verbatim: f.relativePath).font(ShellFonts.row).foregroundStyle(c.label).lineLimit(1)
                            Spacer(minLength: 0)
                        }
                        .frame(height: 22)
                    }
                }
                .padding(6)
            }
            .frame(height: 160)
            .background { RoundedRectangle(cornerRadius: 6, style: .continuous).stroke(c.fieldStroke, lineWidth: 1) }
            TextEditor(text: Binding(get: { scm.commitSheet?.message ?? "" }, set: { scm.commitSheet?.message = $0 }))
                .font(ShellFonts.row)
                .frame(height: 80)
                .overlay(alignment: .topLeading) {
                    if (sheet?.message ?? "").isEmpty {
                        Text(SourceControlEditorText.placeholder).font(ShellFonts.row).foregroundStyle(c.tertiaryLabel)
                            .padding(.leading, 5).padding(.top, 1).allowsHitTesting(false)
                    }
                }
                .background { RoundedRectangle(cornerRadius: 6, style: .continuous).stroke(c.fieldStroke, lineWidth: 1) }
                .shellTarget("commit sheet message")
            if let e = sheet?.error {
                Text(verbatim: e).font(ShellFonts.small).foregroundStyle(c.error).lineLimit(4)
            }
            HStack {
                Spacer()
                Button("Cancel") { scm.commitSheet = nil }.keyboardShortcut(.cancelAction).shellTarget("commit sheet cancel")
                Button("Commit Files") { scm.commitSheetFiles() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!(sheet?.canCommit ?? false) || scm.busy != nil)
                    .shellTarget("commit sheet commit")
            }
        }
        .padding(16)
        .frame(width: 480)
    }
}

extension Array {
    subscript(safe i: Int) -> Element? { indices.contains(i) ? self[i] : nil }
}
