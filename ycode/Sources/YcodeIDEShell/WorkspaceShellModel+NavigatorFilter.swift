import Foundation
import YcodeIDECore

/// The navigators' filter on Linux (P-037, the shared
/// `NavigatorFilterModel`), the Project navigator's multiple selection,
/// expansion of a row and everything under it (P-051), and the model side
/// of click → file shown (P-199).
extension WorkspaceShellModel {
    // MARK: Filter

    /// The navigator shown (its selector index).
    public var navigatorIndex: Int { navigator.selectorIndex }

    /// The field's text in a navigator.
    public func filterText(_ navigator: Int) -> String { navigatorState.filterText[navigator] ?? "" }

    /// The text a navigator's rows follow.
    public func appliedFilter(_ navigator: Int) -> String { navigatorState.appliedFilter[navigator] ?? "" }

    /// Typing in the field: the rows follow `NavigatorFilterModel.settleDelay`
    /// after the last key (at once when the field is cleared).
    public func setFilterText(_ text: String, navigator: Int) {
        let s = navigatorState
        guard s.filterText[navigator] ?? "" != text else { return }
        s.filterText[navigator] = text
        s.lastFilterKeyAt = Date()
        s.settleTasks[navigator]?.cancel()
        if text.isEmpty {
            applyFilter(navigator)
            return
        }
        s.settleTasks[navigator] = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(NavigatorFilterModel.settleDelay * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self?.applyFilter(navigator)
        }
    }

    /// The rows follow the field now (drivers and tests skip the pause).
    public func applyFilter(_ navigator: Int) {
        let text = filterText(navigator)
        navigatorState.appliedFilter[navigator] = text
        navigatorState.lastFilterAppliedAt = Date()
        if navigator == ShellNavigator.symbols.selectorIndex, symbols.filterText != text { symbols.filterText = text }
    }

    /// The filter settled: the field ended editing, or the navigator was
    /// left with text in it. It goes to the front of the recent filters.
    public func noteFilterRecent(_ navigator: Int) {
        navigatorState.recents.note(filterText(navigator), navigator: navigator)
    }

    /// The options menu's entries for a navigator.
    public func filterMenu(_ navigator: Int) -> [NavigatorFilterModel.MenuEntry] {
        NavigatorFilterModel.menu(recents: navigatorState.recents.recents(navigator))
    }

    /// A recent filter chosen in the options menu: back in the field, at once.
    public func chooseRecentFilter(_ text: String, navigator: Int) {
        setFilterText(text, navigator: navigator)
        applyFilter(navigator)
        noteFilterRecent(navigator)
    }

    public func clearFilterRecents(_ navigator: Int) { navigatorState.recents.clear(navigator) }

    /// An in-field toggle (`NavigatorBars.specs[navigator].toggles[index]`).
    public func isFilterToggleOn(_ index: Int, navigator: Int) -> Bool {
        navigatorState.toggles[navigator]?.contains(index)
            ?? (NavigatorBars.specs.indices.contains(navigator) && NavigatorBars.specs[navigator].toggles.indices.contains(index)
                && NavigatorBars.specs[navigator].toggles[index].defaultOn)
    }

    public func setFilterToggle(_ index: Int, on: Bool, navigator: Int) {
        var set = navigatorState.toggles[navigator]
            ?? Set((NavigatorBars.specs.indices.contains(navigator) ? NavigatorBars.specs[navigator].toggles : []).indices.filter {
                NavigatorBars.specs[navigator].toggles[$0].defaultOn
            })
        if on { set.insert(index) } else { set.remove(index) }
        navigatorState.toggles[navigator] = set
    }

    /// The filter options glyph is accent-coloured: text in the field, or a
    /// toggle on that filters.
    public func isFilterActive(_ navigator: Int) -> Bool {
        NavigatorFilterModel.isActive(filterText(navigator))
            || (navigator == ShellNavigator.project.selectorIndex && projectFilterKeep != nil)
    }

    /// The files the Project navigator's toggles keep (nil: no toggle on):
    /// recent files (the files opened in this window), files with a
    /// source-control status.
    var projectFilterKeep: ((NavigatorItem) -> Bool)? {
        let nav = ShellNavigator.project.selectorIndex
        let recent = isFilterToggleOn(0, navigator: nav), status = isFilterToggleOn(1, navigator: nav)
        guard recent || status else { return nil }
        let recentPaths = Set(history.items).union(openDocuments.keys).union(document.map { [$0.path] } ?? [])
        let badges = sourceControl.badges
        return { item in
            guard let p = item.path else { return false }
            return (!recent || recentPaths.contains(p)) && (!status || badges[p] != nil)
        }
    }

    /// The Project navigator's rows as drawn: through the filter and its toggles.
    public var filteredProjectRows: [OutlineRow] {
        OutlineRows.project(root, expanded: expanded, hideExtensions: hidesFileExtensions, edited: editedPaths, badges: sourceControl.badges,
                            filter: appliedFilter(ShellNavigator.project.selectorIndex), keep: projectFilterKeep,
                            sections: packageSection.map { [$0] } ?? [])
    }

    /// The project's Package Dependencies section (L-110): each package
    /// with its checkout's files, after the project row, as on macOS
    /// (`PackageDependencyModel.navigatorSection`).
    public var packageSection: NavigatorItem? {
        if let cached = navigatorState.packageSectionCache { return cached }
        var section: NavigatorItem?
        if containerKind == .project, let proj = session.model.projects[session.model.url.path],
           let node = PackageDependencyModel(proj: proj, xcodeprojURL: session.model.url).navigatorSection() {
            section = NavigatorItem(node)
        }
        navigatorState.packageSectionCache = .some(section)
        return section
    }

    /// A row of the project tree or of the Package Dependencies section.
    func projectOrPackageRow(_ id: String) -> NavigatorItem? { root.find(id: id) ?? packageSection?.find(id: id) }

    /// A navigator's rows through its applied filter.
    public func filtered(_ rows: [OutlineRow], navigator: Int) -> [OutlineRow] {
        OutlineRows.filtered(rows, query: appliedFilter(navigator))
    }

    /// The navigator shown had rows and its filter left none: the
    /// navigator says "No Filter Results" and the inspector "No Selection".
    public var navigatorFilterLeavesNoRows: Bool {
        let nav = navigatorIndex
        let q = appliedFilter(nav)
        if nav == ShellNavigator.project.selectorIndex {
            return isFilterActive(nav) && filteredProjectRows.count <= 1
        }
        guard NavigatorFilterModel.isActive(q) else { return false }
        let rows: [OutlineRow]
        switch navigator {
        case .project: return false
        case .sourceControl: rows = sourceControl.rows
        case .symbols: return false   // the Symbol navigator filters through its own model
        case .find: rows = OutlineRows.find(findRows, collapsed: [])
        case .issues: rows = OutlineRows.issues(issueGroups, collapsed: [])
        case .tests: rows = testing.rows
        case .debug: rows = debug.debugRows.map(\.outline)
        case .breakpoints: rows = debug.breakpointRows.map(\.outline)
        case .reports: rows = testing.reportRows
        }
        return !rows.isEmpty && OutlineRows.filtered(rows, query: q).isEmpty
    }

    // MARK: Multiple selection (P-051)

    /// A click on a project row: alone it selects the row; with Shift it
    /// selects the rows from the anchor to it; with Ctrl (⌘ on the Mac) it
    /// adds the row or takes it out.
    public func clickProjectRow(_ id: String, rows: [OutlineRow], extend: Bool = false, toggle: Bool = false) {
        let s = navigatorState
        s.renaming = nil
        if extend, let anchor = s.anchor ?? projectSelection, let a = rows.firstIndex(where: { $0.id == anchor }),
           let b = rows.firstIndex(where: { $0.id == id }) {
            let ids = rows[min(a, b)...max(a, b)].map(\.id)
            s.multiSelection = ids.count > 1 ? ids : []
            s.anchor = anchor
            selectRowTimed(id)
            return
        }
        if toggle {
            var ids = selectedProjectRowIDs
            if let i = ids.firstIndex(of: id) { ids.remove(at: i) } else { ids.append(id) }
            s.multiSelection = ids.count > 1 ? ids : []
            s.anchor = id
            if let last = ids.last { selectRowTimed(last) }
            return
        }
        s.multiSelection = []
        s.anchor = id
        selectRowTimed(id)
    }

    /// Whether a project row is drawn selected.
    public func isProjectRowSelected(_ id: String) -> Bool {
        navigatorState.multiSelection.count > 1 ? navigatorState.multiSelection.contains(id) : id == projectSelection
    }

    /// Selects a row, timing the model's part of click → file shown (P-199).
    func selectRowTimed(_ id: String) {
        let start = Date()
        navigatorState.lastSelectStarted = start
        selection = id
        // A package's file opens too (the tree's own rows open through `selection`).
        if root.find(id: id) == nil, let item = packageSection?.find(id: id), item.isFile, let p = item.path { open(p) }
        navigatorState.lastSelectModelTime = Date().timeIntervalSince(start)
    }

    // MARK: Expansion (P-051)

    /// ⌥→ / ⌥←: the row and every row under it open or close.
    public func setExpandedRecursively(_ id: String, _ on: Bool) {
        guard let item = root.find(id: id) else { return }
        let ids = [id] + (item.children ?? []).flatMap { [$0.id] + $0.descendantIDs }.filter { root.find(id: $0)?.children != nil }
        if on { expanded.formUnion(ids) } else { expanded.subtract(ids) }
        saveExpansion()
    }
}
