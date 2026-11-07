import Foundation
import SwiftUI
import YcodeBuild
import YcodeIDECore
import YcodeIDEShell

/// The navigator column (`navigators.md`, `metrics.md` §2): its toolbar
/// band, the selector capsule with the nine navigators, the selected
/// navigator, and the bottom bar ("+" and the filter capsule). The shell
/// has the Project, Find and Issue navigators; the others show their empty
/// states.
struct NavigatorColumn: View {
    @Bindable var model: WorkspaceShellModel
    @State private var shownIndex: Int?

    var body: some View {
        let index = shownIndex ?? model.navigator.selectorIndex
        if model.assistant.isShown {
            AssistantColumn(model: model)   // AssistantPane.swift
        } else {
        VStack(spacing: 0) {
            NavigatorToolbar(model: model)
            SelectorBar(selected: index) { i in
                if let n = ShellNavigator.allCases.first(where: { $0.selectorIndex == i }) {
                    shownIndex = nil
                    model.navigator = n
                } else {
                    shownIndex = i
                }
            }
            .padding(.horizontal, CGFloat(WorkspaceChrome.selectorInset))
            Group {
                if shownIndex != nil {
                    EmptyNavigator(lines: [CommandTable.navigators[index], ShellText.notInBeta])
                } else {
                    switch model.navigator {
                    case .project: ProjectNavigator(model: model)
                    case .sourceControl: SourceControlNavigator(model: model)
                    case .symbols: SymbolNavigator(model: model)
                    case .find: FindNavigator(model: model)
                    case .issues: IssueNavigator(model: model)
                    case .tests: TestNavigator(model: model)
                    case .debug: DebugNavigator(model: model)
                    case .breakpoints: BreakpointNavigator(model: model)
                    case .reports: ReportNavigator(model: model)
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            if shownIndex == nil, model.navigator == .symbols {
                SymbolFilterBar(symbols: model.symbols)   // SymbolNavigatorView.swift
            } else {
                NavigatorFilterBar(spec: NavigatorBars.specs[index],
                                   addMenu: shownIndex == nil && model.navigator == .breakpoints
                                       ? { AnyView(BreakpointAddMenuItems(model: model)) } : nil)   // DebugEditors.swift
            }
        }
        .onChange(of: model.navigator) { _, _ in shownIndex = nil }
        }
    }
}

/// The selector capsule: one icon per navigator, 30 points apart; the
/// selected one in a 30 × 24 pill, in the accent color.
struct SelectorBar: View {
    var selected: Int
    var select: (Int) -> Void
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let c = ShellColors(scheme)
        let pill = WorkspaceChrome.selectorPillSize
        HStack(spacing: 0) {
            // The Linux places (the Symbol navigator's own symbol and tooltip at ⌘3).
            ForEach(Array(ShellNavigator.selectorButtons.map(\.symbol).enumerated()), id: \.offset) { pair in
                let on = pair.offset == selected
                Button { select(pair.offset) } label: {
                    ZStack {
                        if on {
                            Capsule(style: .continuous).fill(c.selectorPill).frame(width: CGFloat(pill.width), height: CGFloat(pill.height))
                        }
                        Image(systemName: pair.element)
                            .font(.system(size: 14))
                            .foregroundStyle(on ? c.accent : c.toolbarIcon)
                    }
                    .frame(width: 30, height: CGFloat(WorkspaceChrome.selectorHeight))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(ShellNavigator.selectorButtons[pair.offset].toolTip)
                .accessibilityLabel(ShellNavigator.selectorButtons[pair.offset].title)
                .shellTarget("selector \(pair.offset)")
            }
        }
        .padding(.horizontal, 4)
        .frame(maxWidth: .infinity)
        .frame(height: CGFloat(WorkspaceChrome.selectorHeight))
        .background { GlassCapsule(height: CGFloat(WorkspaceChrome.selectorHeight)) }
    }
}

/// The bottom bar: the left pull-down ("+", "…") in a circle when the
/// navigator has one, then the filter capsule with its options pull-down,
/// the field and the navigator's toggles (`NavigatorBars.specs`).
struct NavigatorFilterBar: View {
    var spec: NavigatorBarSpec
    /// The "+" pull-down's items, for a navigator whose "+" works.
    var addMenu: (() -> AnyView)?
    @State private var text = ""
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let c = ShellColors(scheme)
        let h = CGFloat(WorkspaceChrome.filterBarHeight)
        HStack(spacing: CGFloat(WorkspaceChrome.plusToFilter)) {
            if let addMenu {
                // The "+" alone, centred in its circle (metrics.md §15).
                Menu { addMenu() } label: {
                    Image(systemName: "plus").font(.system(size: 13))
                    .foregroundStyle(c.secondaryLabel)
                    .frame(width: CGFloat(WorkspaceChrome.plusCircleWidth), height: h)
                    .background { Capsule(style: .continuous).stroke(c.capsuleStroke, lineWidth: 1) }
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .help("Add")
                .shellTarget("navigator add")
            } else if spec.left != .none {
                Image(systemName: spec.left == .more ? "ellipsis.circle" : "plus").font(.system(size: 13))
                .foregroundStyle(c.tertiaryLabel)
                .help(ShellText.notInBeta(spec.left == .more ? "More" : "Add"))
                .frame(width: CGFloat(WorkspaceChrome.plusCircleWidth), height: h)
                .background { Capsule(style: .continuous).stroke(c.capsuleStroke, lineWidth: 1) }
            }
            HStack(spacing: 3.5) {
                // The lines in a circle and a chevron 1.5 after it, in the
                // secondary colour; "Filter" begins 33.5 in (metrics.md §15).
                HStack(spacing: 0) {
                    Image(systemName: "line.3.horizontal.decrease.circle").font(.system(size: 13))
                    Image(systemName: "chevron.down").font(.system(size: 6))
                }
                // #ABABAC in dark (editor-area.md F.9, row 110).
                .foregroundStyle(scheme == .dark ? Color(.sRGB, red: 0xAB / 255.0, green: 0xAB / 255.0, blue: 0xAC / 255.0) : c.secondaryLabel)
                TextField("Filter", text: $text)
                    .textFieldStyle(.plain)
                    .font(ShellFonts.row)
                    .disabled(true)
                    .help(ShellText.notInBeta("Filter"))
                    .shellTarget("navigator filter")
                ForEach(Array(spec.toggles.enumerated()), id: \.offset) { pair in
                    Image(systemName: pair.element.symbol).font(.system(size: 12)).foregroundStyle(c.tertiaryLabel)
                        .help(ShellText.notInBeta(pair.element.toolTip))
                }
            }
            .padding(.leading, 6.5)
            .padding(.trailing, 9)
            .frame(height: h)
            .background { Capsule(style: .continuous).stroke(c.capsuleStroke, lineWidth: 1) }
        }
        .padding(.leading, CGFloat(WorkspaceChrome.filterBarLeading))
        .padding(.trailing, CGFloat(WorkspaceChrome.filterBarTrailing))
        .padding(.bottom, CGFloat(WorkspaceChrome.filterBarBottomInset))
        .padding(.top, 4)
    }
}

/// A navigator the shell does not have yet: its empty state.
struct EmptyNavigator: View {
    var lines: [String]
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let c = ShellColors(scheme)
        VStack(spacing: 4) {
            ForEach(Array(lines.enumerated()), id: \.offset) { pair in
                Text(verbatim: pair.element)
                    .font(pair.offset == 0 ? Font.system(size: 15, weight: .semibold) : ShellFonts.small)
                    .foregroundStyle(c.secondaryLabel)
                    .multilineTextAlignment(.center)
            }
        }
        .padding(.horizontal, 20)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - The outline

/// Rows of a navigator, drawn as the AppKit outline draws them
/// (`WorkspaceChrome`): 22 points tall (taller for wrapped titles), 12
/// points of indentation per level, the disclosure triangle at x 12, a
/// 16-point icon at x 25 and the label at x 45. Up and Down move the
/// selection; Right and Left expand and collapse.
struct NavigatorOutline: View {
    var rows: [OutlineRow]
    var selection: String?
    var select: (String) -> Void
    var toggle: (String, Bool) -> Void
    var target: String
    @Environment(\.colorScheme) private var scheme
    @FocusState private var hasKeyboard: Bool

    var body: some View {
        let c = ShellColors(scheme)
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(rows) { r in
                    // The accent band only while the outline has the keyboard;
                    // grey once an editor has it (navigators.md round 3 §1).
                    OutlineRowView(row: r, isSelected: r.id == selection, colors: c, toggle: toggle, isFocused: hasKeyboard)
                        .contentShape(Rectangle())
                        // A click gives the outline the keyboard (its band turns accent).
                        .onTapGesture { hasKeyboard = true; select(r.id) }
                        .shellTarget("row \(r.title)")
                }
            }
            .padding(.top, CGFloat(WorkspaceChrome.firstRowGap))
            .padding(.bottom, 8)
        }
        .scrollIndicators(.hidden)
        .focusable()
        .focused($hasKeyboard)
        // Browsing files with the arrow keys keeps the keyboard here.
        .onChange(of: hasKeyboard) { _, on in ShellFocus.outlineHasKeyboard = on }
        .onKeyPress(.downArrow) { move(1); return .handled }
        .onKeyPress(.upArrow) { move(-1); return .handled }
        .onKeyPress(.rightArrow) { expand(true); return .handled }
        .onKeyPress(.leftArrow) { expand(false); return .handled }
        .shellTarget(target)
    }

    func move(_ d: Int) {
        guard !rows.isEmpty else { return }
        let i = selection.flatMap { s in rows.firstIndex { $0.id == s } } ?? (d > 0 ? -1 : rows.count)
        let j = min(max(i + d, 0), rows.count - 1)
        select(rows[j].id)
    }

    func expand(_ on: Bool) {
        guard let s = selection, let r = rows.first(where: { $0.id == s }), r.isExpandable, r.isExpanded != on else { return }
        toggle(s, on)
    }
}

struct OutlineRowView: View {
    var row: OutlineRow
    var isSelected: Bool
    var colors: ShellColors
    var toggle: (String, Bool) -> Void
    /// Whether the outline has the keyboard (the selection's accent band).
    var isFocused = false

    var body: some View {
        let c = colors.onSelection(isSelected && isFocused)   // +SelectionFocus.swift
        let indent = CGFloat(WorkspaceChrome.indentationPerLevel) * CGFloat(row.level)
        HStack(alignment: .top, spacing: 0) {
            Group {
                if row.isExpandable {
                    Image(systemName: row.isExpanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(c.chevron)
                        .frame(width: 13, height: CGFloat(WorkspaceChrome.rowHeight))
                        .contentShape(Rectangle())
                        .onTapGesture { toggle(row.id, !row.isExpanded) }
                } else {
                    Color.clear.frame(width: 13, height: CGFloat(WorkspaceChrome.rowHeight))
                }
            }
            .padding(.leading, CGFloat(WorkspaceChrome.disclosureX) + indent)
            Image(systemName: row.symbol)
                .font(.system(size: 13))
                .foregroundStyle(c.tint(row.tint))
                .frame(width: 16, height: CGFloat(WorkspaceChrome.rowHeight))
            title(c)
                .padding(.leading, 4)
                .padding(.vertical, row.lineLimit > 1 ? 3 : 0)
                .frame(minHeight: CGFloat(WorkspaceChrome.rowHeight), alignment: .leading)
            Spacer(minLength: 6)
            OutlineRowAccessories(row: row, colors: c)
            if row.isEdited {
                Circle().fill(c.secondaryLabel).frame(width: 6, height: 6)
                    .frame(height: CGFloat(WorkspaceChrome.rowHeight))
                    .padding(.trailing, 12)
                    .help("Unsaved changes")
            }
        }
        .opacity(row.isDimmed ? 0.55 : 1)
        .background {
            if isSelected {
                RoundedRectangle(cornerRadius: 5, style: .continuous).fill(isFocused ? colors.accent : c.rowSelection).padding(.horizontal, 6)
            }
        }
    }

    @ViewBuilder
    func title(_ c: ShellColors) -> some View {
        if let m = row.match {
            // The line as the AppKit Find navigator shows it: one weight
            // (the match is the row's subject, not set apart).
            Text(verbatim: m.before + m.match + m.after)
                .font(ShellFonts.row).foregroundStyle(c.label).lineLimit(row.lineLimit)
        } else if let detail = row.detail {
            HStack(spacing: 6) {
                Text(verbatim: row.title).font(row.isBold ? ShellFonts.rowBold : ShellFonts.row).foregroundStyle(c.label).lineLimit(1)
                Text(verbatim: detail).font(ShellFonts.row).foregroundStyle(row.detailIsSecondary ? c.secondaryLabel : c.label).lineLimit(1)
            }
        } else {
            Text(verbatim: row.title).font(row.isBold ? ShellFonts.rowBold : ShellFonts.row).foregroundStyle(c.label).lineLimit(row.lineLimit)
        }
    }
}

// MARK: - Navigators

/// The Project navigator: the container row, its groups and files, with
/// the core's initial expansion (`NavigatorTree.initiallyExpanded`).
/// Selecting a file opens it.
struct ProjectNavigator: View {
    @Bindable var model: WorkspaceShellModel

    var body: some View {
        // Settings ▸ General ▸ File extensions applies at once.
        let _ = ShellPreferences.shared.revision
        NavigatorOutline(rows: model.projectRows, selection: model.selection, select: { model.selection = $0 },
                         toggle: { model.setExpanded($0, $1) }, target: "project navigator")
    }
}

/// The Find navigator (`navigators.md` §Find navigator): "Find › Text ›
/// Containing" with the match-case toggle, the query field, the scope and
/// the count, then one row per file with its matches.
struct FindNavigator: View {
    @Bindable var model: WorkspaceShellModel
    @FocusState private var fieldFocused: Bool
    @State private var collapsed: Set<String> = []
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let c = ShellColors(scheme)
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 5) {
                Text("Find").font(ShellFonts.mini.weight(.semibold))
                Image(systemName: "chevron.right").font(.system(size: 7)).foregroundStyle(c.secondaryLabel)
                Text("Text").font(ShellFonts.mini.weight(.semibold))
                Image(systemName: "chevron.right").font(.system(size: 7)).foregroundStyle(c.secondaryLabel)
                Text("Containing").font(ShellFonts.mini.weight(.semibold))
                Spacer()
                Button { model.findIgnoreCase.toggle() } label: {
                    Text("Aa").font(ShellFonts.small).tracking(ShellFonts.smallTracking).foregroundStyle(model.findIgnoreCase ? c.tertiaryLabel : c.accent)
                }
                .buttonStyle(.plain)
                .help("Match case")
            }
            .foregroundStyle(c.label)
            .padding(.leading, 7)
            .padding(.trailing, 10)
            .frame(height: 14)
            .padding(.top, 7)
            HStack(spacing: 4) {
                Image(systemName: "magnifyingglass").font(.system(size: 12)).foregroundStyle(c.secondaryLabel)
                TextField("Text", text: $model.findText)
                    .textFieldStyle(.plain)
                    .font(ShellFonts.row)
                    .focused($fieldFocused)
                    .onSubmit { model.runFind() }
                    .shellTarget("find field")
                if !model.findText.isEmpty {
                    Button { model.findText = "" } label: {
                        Image(systemName: "xmark.circle.fill").font(.system(size: 12)).foregroundStyle(c.secondaryLabel)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 7)
            .frame(height: 24)
            .background { RoundedRectangle(cornerRadius: 7, style: .continuous).stroke(c.fieldStroke, lineWidth: 1) }
            .padding(.horizontal, 6)
            .padding(.top, 4)
            HStack(spacing: 2) {
                Text(verbatim: "In \(scopeName)").font(ShellFonts.mini.weight(.semibold)).foregroundStyle(c.label)
                Image(systemName: "chevron.up.chevron.down").font(.system(size: 7)).foregroundStyle(c.label)
                Spacer()
                Text(verbatim: model.isSearching ? "Searching…" : model.findCountText).font(ShellFonts.mini).tracking(ShellFonts.smallTracking).foregroundStyle(c.secondaryLabel)
                    .shellTarget("find count")
            }
            .padding(.leading, 7)
            .padding(.trailing, 6)
            .frame(height: 14)
            .padding(.top, 4)
            if model.callHierarchy.tree != nil {
                CallHierarchyOutline(model: model.callHierarchy).padding(.top, 1)   // CallHierarchyView.swift
            } else {
                NavigatorOutline(rows: OutlineRows.find(model.findRows, collapsed: collapsed), selection: model.findSelection,
                                 select: { id in if model.findRows.contains(where: { $0.id == id }) { return }; model.findSelection = id },
                                 toggle: { id, on in if on { collapsed.remove(id) } else { collapsed.insert(id) } }, target: "find results")
                    .padding(.top, 1)
            }
        }
        // Find in Workspace asks for the field (also when it switched to
        // this navigator, so the request may predate the field).
        .task(id: model.findFocusCount) { if model.findFocusCount > 0 { fieldFocused = true } }
    }

    /// The scope pull-down's title, as the AppKit navigator words it (a
    /// package's scope is its project).
    var scopeName: String { model.containerKind == .workspace ? "Workspace" : "Project" }
}

/// The Issue navigator: the project and targets, their files, then the
/// issues, each with its severity symbol; selecting one opens its line.
struct IssueNavigator: View {
    @Bindable var model: WorkspaceShellModel
    @State private var collapsed: Set<String> = []

    var body: some View {
        if model.issueGroups.isEmpty {
            EmptyNavigator(lines: NavigatorBars.specs[4].emptyState)
                .shellTarget("issues empty")
        } else {
            NavigatorOutline(rows: OutlineRows.issues(model.issueGroups, collapsed: collapsed), selection: model.issueSelection,
                             select: { id in
                                 if model.allIssues.contains(where: { $0.id == id }) { model.issueSelection = id }
                             },
                             toggle: { id, on in if on { collapsed.remove(id) } else { collapsed.insert(id) } }, target: "issue navigator")
        }
    }
}

/// Who has the keyboard, where a view elsewhere needs to know.
@MainActor
enum ShellFocus {
    static var outlineHasKeyboard = false
}
