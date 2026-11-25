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
                } else if model.navigatorFilterLeavesNoRows {
                    // P-037: the filter left no row.
                    EmptyNavigator(lines: [NavigatorFilterModel.noResults]).shellTarget("navigator no filter results")
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
            // Rows draw their match in bold, the rest dimmed (P-037).
            .environment(\.navigatorFilterQuery, shownIndex == nil ? model.appliedFilter(index) : "")
            // The Symbol navigator's bar: the filter alone, as the Find navigator's.
            NavigatorFilterBar(model: model, navigator: index,
                               spec: NavigatorBars.specs[shownIndex == nil && model.navigator == .symbols ? ShellNavigator.find.selectorIndex : index],
                               isPlaceholder: shownIndex != nil)   // NavigatorBottomBar.swift
        }
        .onChange(of: model.navigator) { old, _ in
            shownIndex = nil
            model.noteFilterRecent(old.selectorIndex)   // the navigator was left with its filter
        }
        }
    }
}

/// The selector capsule: one icon per navigator, 30 points apart; the
/// selected one in a 30 × 24 grey pill. Every glyph is in the label colour,
/// as the macOS IDE draws them (`cross-platform-parity.md` §3; no accent).
struct SelectorBar: View {
    var selected: Int
    var select: (Int) -> Void
    @Environment(\.colorScheme) private var scheme
    /// Where the grey disc is drawn: it slides to `selected` after a click
    /// (P-193, `Motion.selectorDisc`: +147 → +430 ms, ease-out).
    @State private var disc: Int?
    @State private var width: CGFloat = 0
    @State private var generation = 0
    /// The tabs' inset in the capsule.
    static let inset: CGFloat = 4

    var body: some View {
        let c = ShellColors(scheme)
        let pill = WorkspaceChrome.selectorPillSize
        let count = ShellNavigator.selectorButtons.count
        let tab = max(0, width - 2 * Self.inset) / CGFloat(max(1, count))
        HStack(spacing: 0) {
            // The Linux places (the Symbol navigator's own symbol and tooltip at ⌘3).
            // Equal tabs that give way with the navigator (P-024: the bar
            // compresses to ≈ 135 points).
            ForEach(Array(ShellNavigator.selectorButtons.map(\.symbol).enumerated()), id: \.offset) { pair in
                Button { select(pair.offset) } label: {
                    SelectorGlyphView(symbol: pair.element, color: c.selectorGlyph)   // NavigatorRowIcons.swift (row 192)
                        .frame(minWidth: 15, maxWidth: 30)
                        .frame(maxWidth: .infinity)
                        .frame(height: CGFloat(WorkspaceChrome.selectorHeight))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(ShellNavigator.selectorButtons[pair.offset].toolTip)
                .accessibilityLabel(ShellNavigator.selectorButtons[pair.offset].title)
                .shellTarget("selector \(pair.offset)")
            }
        }
        .padding(.horizontal, Self.inset)
        .frame(maxWidth: .infinity)
        .frame(height: CGFloat(WorkspaceChrome.selectorHeight))
        // The selected tab's disc, under the glyphs.
        .background(alignment: .leading) {
            Capsule(style: .continuous).fill(c.panePill)
                .frame(width: min(CGFloat(pill.width), tab), height: CGFloat(pill.height))
                .offset(x: Self.inset + (CGFloat(disc ?? selected) + 0.5) * tab - min(CGFloat(pill.width), tab) / 2)
        }
        .background { PaneCapsule(height: CGFloat(WorkspaceChrome.selectorHeight)) }   // PaneStyle.swift
        .background { GeometryReader { g in Color.clear.onAppear { width = g.size.width }.onChange(of: g.size.width) { _, w in width = w } } }
        // P-198: the glass lens while held; a tab selects on release (no hover).
        .glassTabLens(.navigator, count: count, selected: selected, leading: Self.inset) { select($0) }
        .onChange(of: selected) { old, new in slideDisc(from: old, to: new) }
    }

    /// The disc stays on the old tab until the curve starts, then eases
    /// to the new one (P-193).
    func slideDisc(from old: Int, to new: Int) {
        generation += 1
        let g = generation
        let curve = Motion.selectorDisc
        let b = curve.bezier
        disc = old
        DispatchQueue.main.asyncAfter(deadline: .now() + curve.delay) {
            guard generation == g else { return }
            withAnimation(.timingCurve(b.x1, b.y1, b.x2, b.y2, duration: curve.duration)) { disc = new }
        }
    }
}

/// A navigator's empty state (P-039, `NavigatorEmptyStyle`): the first
/// line ≈ 16 points medium in #9D9FA1 (dark) or the secondary label
/// colour (light), 4.5 points above the centre; a second line in the
/// small secondary text.
struct EmptyNavigator: View {
    var lines: [String]
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let c = ShellColors(scheme)
        VStack(spacing: 4) {
            ForEach(Array(lines.enumerated()), id: \.offset) { pair in
                Text(verbatim: pair.element)
                    .font(pair.offset == 0 ? Font.system(size: CGFloat(NavigatorEmptyStyle.titleSize), weight: .medium)
                          : Font.system(size: CGFloat(NavigatorEmptyStyle.detailSize)))
                    .foregroundStyle(pair.offset == 0 ? Self.titleColor(scheme) : c.secondaryLabel)
                    .multilineTextAlignment(.center)
            }
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 2 * CGFloat(NavigatorEmptyStyle.raise))
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    static func titleColor(_ scheme: ColorScheme) -> Color {
        IssueSymbol.color(scheme == .dark ? NavigatorEmptyStyle.titleColorDark : NavigatorEmptyStyle.titleColorLight)
    }
}

// MARK: - The outline

/// What the Project navigator adds to an outline (P-041, P-042, P-043,
/// P-051): the multiple selection, rename in place, the rows' context menu,
/// Return, Delete, ⌥←/⌥→ over a row and its descendants, undo, and drag to
/// move.
struct OutlineProjectHooks {
    var model: WorkspaceShellModel
}

/// Rows of a navigator, drawn as the AppKit outline draws them
/// (`WorkspaceChrome`): 22 points tall (taller for wrapped titles), 14
/// points of indentation per level, the disclosure triangle at x 12, a
/// 16-point icon at x 25 and the label at x 45. It takes the keyboard on
/// a click: Up and Down move the selection, Right and Left expand and
/// collapse (with ⌥, the row and everything under it), typing letters
/// selects the next row starting with them; the selection scrolls into
/// view (P-051).
struct NavigatorOutline: View {
    var rows: [OutlineRow]
    var selection: String?
    var select: (String) -> Void
    var toggle: (String, Bool) -> Void
    var target: String
    /// ⌥←/⌥→: the row and everything under it (nil: the row alone).
    var toggleAll: ((String, Bool) -> Void)?
    var project: OutlineProjectHooks?
    @Environment(\.colorScheme) private var scheme
    @FocusState private var hasKeyboard: Bool
    @State private var typed = ""
    @State private var typedAt = Date.distantPast
    @State private var modifiers = PointerModifierProbe()   // ProjectNavigatorViews.swift

    var body: some View {
        let c = ShellColors(scheme)
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(rows) { r in
                        rowView(r, c)
                            .transition(.opacity)
                    }
                }
                .padding(.top, CGFloat(WorkspaceChrome.firstRowGap))
                .padding(.bottom, 8)
                .overlay(alignment: .topLeading) {
                    if let project, let drag = project.model.navigatorState.drag {
                        ProjectDragOverlay(model: project.model, drag: drag, rows: rows)   // ProjectNavigatorViews.swift
                    }
                }
                .simultaneousGesture(dragGesture, isEnabled: project != nil)
            }
            // Scrollers show while scrolling, as everywhere (P-051: no hidden scrollers).
            .background { PointerModifierProbeView(probe: modifiers) }
            .onChange(of: selection) { _, id in
                if let id { proxy.scrollTo(id) }
            }
        }
        .focusable()
        .focused($hasKeyboard)
        // Browsing files with the arrow keys keeps the keyboard here.
        .onChange(of: hasKeyboard) { _, on in
            ShellFocus.outlineHasKeyboard = on
            if project != nil { ShellNavigatorFocus.projectOutlineHasKeyboard = on }
        }
        // The rename field takes the keyboard, and gives it back (P-043).
        .onChange(of: project?.model.navigatorState.renaming) { old, new in
            if new != nil { hasKeyboard = false } else if old != nil { hasKeyboard = true }
        }
        .onKeyPress(keys: [.downArrow, .upArrow, .rightArrow, .leftArrow], phases: [.down, .repeat]) { press in
            guard !isRenaming else { return .ignored }   // the rename field's keys
            switch press.key {
            case .downArrow: move(1)
            case .upArrow: move(-1)
            default: expand(press.key == .rightArrow, all: press.modifiers.contains(.option))
            }
            return .handled
        }
        .onKeyPress(keys: [.return, .delete, .deleteForward, .escape], phases: .down) { press in
            guard let m = project?.model, !isRenaming else { return .ignored }
            switch press.key {
            case .return: m.beginNavigatorRename()
            case .escape: m.cancelNavigatorRename()
            default: m.askDeleteNavigatorSelection()
            }
            return .handled
        }
        .onKeyPress(phases: .down) { press in
            guard !isRenaming else { return .ignored }
            // Ctrl+Z / Ctrl+Shift+Z: the file operations' undo and redo.
            if let m = project?.model, press.modifiers.contains(.command), press.characters.lowercased() == "z" {
                return (press.modifiers.contains(.shift) ? m.redoNavigatorEdit() : m.undoNavigatorEdit()) ? .handled : .ignored
            }
            return typeSelect(press)
        }
        .shellTarget(target)
    }

    @ViewBuilder
    func rowView(_ r: OutlineRow, _ c: ShellColors) -> some View {
        let model = project?.model
        let isSelected = model?.isProjectRowSelected(r.id) ?? (r.id == selection)
        let isDragged = model?.navigatorState.drag?.rows.contains(r.id) ?? false
        // The accent band only while the outline has the keyboard; grey once
        // an editor has it (navigators.md round 3 §1); the dragged rows keep
        // a grey band (P-042).
        OutlineRowView(row: r, isSelected: isSelected || isDragged, colors: c, toggle: { animatedToggle($0, $1, byKey: false) },
                       isFocused: hasKeyboard && !isDragged,
                       rename: model.flatMap { m in m.navigatorState.renaming == r.id ? m : nil })
            .contentShape(Rectangle())
            // A click gives the outline the keyboard (its band turns accent).
            .onTapGesture {
                hasKeyboard = true
                if let model {
                    let m = modifiers.current
                    model.clickProjectRow(r.id, rows: rows, extend: m.contains(.shift), toggle: m.contains(.control) || m.contains(.command))
                } else {
                    select(r.id)
                }
            }
            .contextMenu {
                if let model { ProjectRowContextMenu(model: model, row: r) }   // ProjectNavigatorViews.swift
            }
            .id(r.id)
            .shellTarget("row \(r.title)")
    }

    /// A row's name is being edited: its field has the keys.
    var isRenaming: Bool { project?.model.navigatorState.renaming != nil }

    func move(_ d: Int) {
        guard !rows.isEmpty else { return }
        let i = selection.flatMap { s in rows.firstIndex { $0.id == s } } ?? (d > 0 ? -1 : rows.count)
        let j = min(max(i + d, 0), rows.count - 1)
        if let m = project?.model { m.clickProjectRow(rows[j].id, rows: rows) } else { select(rows[j].id) }
    }

    func expand(_ on: Bool, all: Bool) {
        guard let s = selection, let r = rows.first(where: { $0.id == s }), r.isExpandable else { return }
        if all, let toggleAll {
            withAnimation(.easeOut(duration: OutlineRows.toggleDuration(expanding: on, byKey: true))) { toggleAll(s, on) }
            return
        }
        if r.isExpanded != on { animatedToggle(s, on, byKey: true) }
    }

    /// Expands or collapses a row with the rows below sliding (P-194):
    /// ≈ 75 ms for Left, ≈ 175 ms for Right and the triangle.
    func animatedToggle(_ id: String, _ on: Bool, byKey: Bool) {
        withAnimation(.easeOut(duration: OutlineRows.toggleDuration(expanding: on, byKey: byKey))) { toggle(id, on) }
    }

    /// Type-select: letters typed within a second of each other select the
    /// next row starting with them.
    func typeSelect(_ press: KeyPress) -> KeyPress.Result {
        guard press.modifiers.subtracting([.shift, .capsLock]).isEmpty, press.characters.count == 1,
              let ch = press.characters.first, ch.isLetter || ch.isNumber || (ch == " " && !typed.isEmpty) else { return .ignored }
        let now = Date()
        typed = now.timeIntervalSince(typedAt) < 1 ? typed + press.characters : press.characters
        typedAt = now
        if let id = OutlineRows.typeSelect(rows, current: selection, prefix: typed) {
            if let m = project?.model { m.clickProjectRow(id, rows: rows) } else { select(id) }
        }
        return .handled
    }

    /// Drag to move (P-042): rows dragged onto a group or folder, or
    /// between rows; not while the filter is active.
    var dragGesture: some Gesture {
        DragGesture(minimumDistance: 6)
            .onChanged { v in
                guard let m = project?.model, m.navigatorState.renaming == nil,
                      !m.isFilterActive(ShellNavigator.project.selectorIndex) else { return }
                if m.navigatorState.drag == nil {
                    guard let start = ProjectDrag.row(at: v.startLocation.y, rows: rows), rows[start].level > 0 else { return }
                    let id = rows[start].id
                    let dragged = m.isProjectRowSelected(id) ? m.selectedProjectRowIDs : [id]
                    m.navigatorState.drag = .init(rows: dragged, location: v.location)
                }
                m.navigatorState.drag = ProjectDrag.update(m.navigatorState.drag!, location: v.location, rows: rows, model: m)
            }
            .onEnded { _ in
                guard let m = project?.model, let d = m.navigatorState.drag else { return }
                m.navigatorState.drag = nil
                ProjectDrag.drop(d, rows: rows, model: m)
            }
    }
}

/// Who has the keyboard, where a view elsewhere needs to know.
@MainActor
enum ShellFocus {
    static var outlineHasKeyboard = false
}

struct OutlineRowView: View {
    var row: OutlineRow
    var isSelected: Bool
    var colors: ShellColors
    var toggle: (String, Bool) -> Void
    /// Whether the outline has the keyboard (the selection's accent band).
    var isFocused = false
    /// The row's name is edited in place (P-043).
    var rename: WorkspaceShellModel?
    @Environment(\.navigatorFilterQuery) private var filterQuery

    var body: some View {
        let c = colors.onSelection(isSelected && isFocused && rename == nil)   // +SelectionFocus.swift
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
            NavigatorRowIconView(row: row, tint: c.tint(row.tint), unfocusedSelection: isSelected && !isFocused)   // NavigatorRowIcons.swift (rows 192, 208)
                .frame(width: 16, height: CGFloat(WorkspaceChrome.rowHeight))
            Group {
                if let model = rename {
                    NavigatorRenameField(model: model, row: row, colors: colors)   // ProjectNavigatorViews.swift
                } else {
                    title(c)
                }
            }
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
            // 22 tall, inset 10 on both sides, corners 8 (NavigatorRowView
            // on macOS; `metrics.md` §12.1); renaming, the grey band.
            if isSelected {
                RoundedRectangle(cornerRadius: 8, style: .continuous).fill(isFocused && rename == nil ? colors.accent : c.navigatorBand)
                    .padding(.horizontal, 10)
            }
        }
    }

    /// The filter's emphasis (P-037): the row's own, else from the query
    /// (navigators whose rows are not filtered by the model).
    var emphasis: (match: NavigatorFilterModel.Emphasis?, dimmed: Bool) {
        if row.filterMatch != nil || row.isFilterContext { return (row.filterMatch, row.isFilterContext) }
        guard NavigatorFilterModel.isActive(filterQuery), row.match == nil else { return (nil, false) }
        let e = NavigatorFilterModel.emphasis(row.title, query: filterQuery)
        return (e, e == nil)
    }

    @ViewBuilder
    func title(_ c: ShellColors) -> some View {
        let e = emphasis
        if let m = row.match {
            // The line as the AppKit Find navigator shows it: one weight
            // (the match is the row's subject, not set apart).
            Text(verbatim: m.before + m.match + m.after)
                .font(ShellFonts.row).foregroundStyle(c.navigatorLabel).lineLimit(row.lineLimit)
        } else if let f = e.match {
            // The matched part bold, the rest dimmed (P-037).
            let dim = c.navigatorLabel.opacity(NavigatorFilterModel.unmatchedOpacity)
            (Text(verbatim: f.before).foregroundStyle(dim) + Text(verbatim: f.match).font(ShellFonts.rowBold).foregroundStyle(c.navigatorLabel)
                + Text(verbatim: f.after).foregroundStyle(dim))
                .font(ShellFonts.row).lineLimit(row.lineLimit)
        } else if let detail = row.detail {
            HStack(spacing: 6) {
                Text(verbatim: row.title).font(row.isBold ? ShellFonts.rowBold : ShellFonts.row).foregroundStyle(c.navigatorLabel).lineLimit(1)
                Text(verbatim: detail).font(ShellFonts.row).foregroundStyle(row.detailIsSecondary ? c.secondaryLabel : c.navigatorLabel).lineLimit(1)
            }
            .opacity(e.dimmed ? NavigatorFilterModel.unmatchedOpacity : 1)
        } else {
            Text(verbatim: row.title).font(row.isBold ? ShellFonts.rowBold : ShellFonts.row).foregroundStyle(c.navigatorLabel).lineLimit(row.lineLimit)
                .opacity(e.dimmed ? NavigatorFilterModel.unmatchedOpacity : 1)
        }
    }
}

/// The navigator filter's applied text, for the rows' emphasis.
struct NavigatorFilterQueryKey: EnvironmentKey {
    static let defaultValue = ""
}

extension EnvironmentValues {
    var navigatorFilterQuery: String {
        get { self[NavigatorFilterQueryKey.self] }
        set { self[NavigatorFilterQueryKey.self] = newValue }
    }
}

// MARK: - Navigators

/// The Project navigator: the container row, its groups and files, with
/// the core's initial expansion (`NavigatorTree.initiallyExpanded`).
/// Selecting a file opens it; the open file's row is selected however it
/// was opened (`WorkspaceShellModel.projectSelection`).
struct ProjectNavigator: View {
    @Bindable var model: WorkspaceShellModel

    var body: some View {
        // Settings ▸ General ▸ File extensions applies at once.
        let _ = ShellPreferences.shared.revision
        NavigatorOutline(rows: model.filteredProjectRows, selection: model.projectSelection, select: { model.selection = $0 },
                         toggle: { model.setExpanded($0, $1) }, target: "project navigator",
                         toggleAll: { model.setExpandedRecursively($0, $1) }, project: OutlineProjectHooks(model: model))
            .modifier(ProjectNavigatorPresentations(model: model))   // ProjectNavigatorViews.swift
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
                NavigatorOutline(rows: model.filtered(OutlineRows.find(model.findRows, collapsed: filtering ? [] : collapsed), navigator: 3),
                                 selection: model.findSelection,
                                 select: { id in if model.findRows.contains(where: { $0.id == id }) { return }; model.findSelection = id },
                                 toggle: { id, on in if on { collapsed.remove(id) } else { collapsed.insert(id) } }, target: "find results")
                    .padding(.top, 1)
            }
        }
        // Find in Workspace asks for the field (also when it switched to
        // this navigator, so the request may predate the field).
        .task(id: model.findFocusCount) { if model.findFocusCount > 0 { fieldFocused = true } }
    }

    var filtering: Bool { NavigatorFilterModel.isActive(model.appliedFilter(3)) }

    /// The scope pull-down's title: "In Workspace" for every container,
    /// as the reference words it (P-040).
    var scopeName: String { "Workspace" }
}

/// The Issue navigator: the project and targets, their files, then the
/// issues, each with its severity symbol; selecting one opens its line.
struct IssueNavigator: View {
    @Bindable var model: WorkspaceShellModel
    @State private var collapsed: Set<String> = []
    var filtering: Bool { NavigatorFilterModel.isActive(model.appliedFilter(4)) }

    var body: some View {
        if model.issueGroups.isEmpty {
            EmptyNavigator(lines: NavigatorBars.specs[4].emptyState)
                .shellTarget("issues empty")
        } else {
            NavigatorOutline(rows: model.filtered(OutlineRows.issues(model.issueGroups, collapsed: filtering ? [] : collapsed), navigator: 4),
                             selection: model.issueSelection,
                             select: { id in
                                 if model.allIssues.contains(where: { $0.id == id }) { model.issueSelection = id }
                             },
                             toggle: { id, on in if on { collapsed.remove(id) } else { collapsed.insert(id) } }, target: "issue navigator")
        }
    }
}
