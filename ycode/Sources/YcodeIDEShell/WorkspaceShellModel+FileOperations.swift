import Foundation
import YcodeIDECore
import YcodeProject

/// The Project navigator's file operations on Linux (P-052,
/// `specs/ide/navigators.md` §Ycode implementation: project navigator file
/// operations): New Empty File, New Group (with or without a folder, from
/// the selection), New Folder (from the selection), Add Files…, Delete
/// (Move to Trash or Remove References), Sort, rename, move, Show in Files,
/// with undo and redo. The work is the shared `ProjectFileOperations`
/// (as the macOS window's `WorkspaceWindowController+ProjectNavigatorOps`);
/// this file maps rows to items, writes the project through the pbxproj
/// writer, rebuilds the tree, moves open editors along, stages the change
/// in git and keeps the undo stack.
extension WorkspaceShellModel {
    // MARK: Rows and items

    /// The `.xcodeproj` a row belongs to (nil in a package).
    public func projectPath(ofRow id: String) -> String? {
        switch containerKind {
        case .package: return nil
        case .project: return session.model.url.path
        case .workspace:
            return root.ancestry(ofID: id)?.reversed().first { $0.kind == .container && $0.path?.hasSuffix(".xcodeproj") == true }?.path
        }
    }

    /// A project row as an operation's item, with its project.
    public func projectItem(ofRow id: String) -> (project: String?, item: ProjectItem)? {
        guard let row = root.find(id: id) else { return nil }
        let proj = projectPath(ofRow: id)
        if let proj, let oid = row.objectID { return (proj, .object(oid)) }
        if let p = row.path, proj != nil || containerKind == .package { return (proj, .disk(p)) }
        return nil
    }

    /// The selected project rows, in order: the multiple selection, else
    /// the single selected row.
    public var selectedProjectRowIDs: [String] {
        let multi = navigatorState.multiSelection.filter { root.find(id: $0) != nil }
        if multi.count > 1 { return multi }
        return projectSelection.map { [$0] } ?? []
    }

    /// The rows an operation from a row's context menu acts on: the
    /// selection when the row is in it, else the row alone (P-041).
    public func rowsForMenu(on id: String?) -> [String] {
        guard let id else { return selectedProjectRowIDs }
        let sel = selectedProjectRowIDs
        return sel.contains(id) ? sel : [id]
    }

    /// The rows as items, when they are all in one project (the project
    /// row stands for its main group).
    func navigatorItems(_ ids: [String]) -> (project: String?, items: [ProjectItem])? {
        let mapped = ids.compactMap(projectItem)
        guard !mapped.isEmpty, mapped.count == ids.count, mapped.allSatisfy({ $0.project == mapped[0].project }) else { return nil }
        return (mapped[0].project, mapped.map(\.item))
    }

    /// The project new items go to without a selection: the first one.
    var defaultNavigatorProject: String? { containerKind == .package ? nil : session.model.projects.keys.sorted().first }

    func navigatorOperations(_ project: String?) -> ProjectFileOperations? {
        if let project, let proj = session.model.projects[project] {
            return ProjectFileOperations(project: proj, xcodeprojURL: URL(fileURLWithPath: project), bin: navigatorState.trashBin)
        }
        return containerKind == .package ? ProjectFileOperations(packageDirectory: session.model.url, bin: navigatorState.trashBin) : nil
    }

    /// Where new items go for these rows (default: the selection): after
    /// the last selected file, or into the selected group or folder (else
    /// the main group).
    func navigatorInsertionPoint(_ ids: [String]? = nil) -> (project: String?, container: ProjectItem, index: Int?)? {
        let sel = navigatorItems(ids ?? selectedProjectRowIDs)
        let project = sel?.project ?? defaultNavigatorProject
        guard let ops = navigatorOperations(project) else { return nil }
        let p = ops.insertionPoint(for: sel?.items.last)
        return (project, p.container, p.index)
    }

    // MARK: Running an operation

    /// Runs an operation on a project (nil: the package), applies it and
    /// puts it on the undo stack (unless `registersUndo` is false: a drag
    /// move, P-042). Returns nil (with `lastError` set) on failure.
    @discardableResult
    public func performNavigatorEdit(_ project: String?, registersUndo: Bool = true,
                                     _ body: (inout ProjectFileOperations) throws -> ProjectEdit) -> ProjectEdit? {
        guard var ops = navigatorOperations(project) else {
            navigatorState.lastError = "There is no project to change."
            return nil
        }
        _ = saveAll()   // unsaved text goes to disk first, so a move does not leave it behind
        do {
            let edit = try body(&ops)
            navigatorState.lastError = nil
            applyNavigator(project: project, ops.project, moved: edit.moved, touched: edit.touchedPaths)
            selectNavigatorItems(edit.result)
            if registersUndo {
                navigatorState.undoStack.append(.init(edit: edit, project: project))
                navigatorState.redoStack = []
                navigatorState.undoRevision += 1
            }
            return edit
        } catch {
            navigatorState.lastError = "\(error)"
            return nil
        }
    }

    /// Writes the project through the pbxproj writer, rebuilds the tree,
    /// moves open editors along and stages the change in git.
    func applyNavigator(project: String?, _ proj: PBXProj?, moved: [String: String], touched: [String]) {
        if let project, let proj {
            session.model.projects[project] = proj
            do { try session.model.saveProjects() } catch { navigatorState.lastError = "\(error)" }
            session.refreshProjectIssues()
        }
        rebuildNavigatorTree()
        followMovedFiles(moved)
        stageNavigatorChange(touched)
        sourceControl.refresh()
    }

    /// The navigator's tree again from the projects (or the package folder).
    public func rebuildNavigatorTree() {
        switch containerKind {
        case .project:
            if let proj = session.model.projects[session.model.url.path] {
                session.model.root = NavigatorTree.project(proj, xcodeprojURL: session.model.url)
            }
        case .workspace:
            let old = session.model.root
            let rows = old.children.map { row -> NavigatorNode in
                guard let p = row.path, let proj = session.model.projects[p] else { return row }
                return NavigatorTree.project(proj, xcodeprojURL: URL(fileURLWithPath: p))
            }
            session.model.root = NavigatorNode(name: old.name, kind: old.kind, path: old.path, objectID: old.objectID, children: rows)
        case .package:
            session.model.root = NavigatorTree.package(at: session.model.url)
        }
        root = NavigatorItem(session.model.root)
        navigatorState.packageSectionCache = nil
        navigatorState.multiSelection = navigatorState.multiSelection.filter { root.find(id: $0) != nil }
    }

    /// Editors showing a moved file (or a file in a moved folder) follow it.
    func followMovedFiles(_ moved: [String: String]) {
        guard !moved.isEmpty else { return }
        func newPath(_ current: String) -> String? {
            let c = URL(fileURLWithPath: current).standardizedFileURL.path
            for (old, new) in moved {
                let o = URL(fileURLWithPath: old).standardizedFileURL.path
                if c == o || c.hasPrefix(o + "/") { return new + c.dropFirst(o.count) }
            }
            return nil
        }
        // The open (saved) documents move with their files, keeping their
        // text undo histories (`source-editor.md`, "Text undo belongs to the
        // file").
        for p in openDocuments.keys where newPath(p) != nil {
            guard let d = openDocuments.removeValue(forKey: p), let n = newPath(p) else { continue }
            editedPaths.remove(p)
            let moved = d.moved(to: n)
            openDocuments[n] = moved
            followChanges(of: moved)
            syncEdited(moved)
            if recoveredPaths.remove(p) != nil { recoveredPaths.insert(n) }
            session.language?.close(URL(fileURLWithPath: p))
            if moved.readOnlyReason == nil { session.language?.open(URL(fileURLWithPath: n), text: moved.buffer.text) }
        }
        if let current = document?.path, let p = newPath(current) {
            document = nil
            editor = nil
            open(p)
            if let ids = root.idPath(to: p) {
                expanded.formUnion(ids.dropLast())
                selection = ids.last
            }
        }
    }

    /// Settings ▸ Source Control on: new, moved and trashed paths are staged
    /// (`git add -A`), as git mv and git rm would record them.
    func stageNavigatorChange(_ paths: [String]) {
        guard Preferences.shared.sourceControlEnabled, !paths.isEmpty else { return }
        let dir = containerKind == .package ? session.model.url : session.model.url.deletingLastPathComponent()
        Task.detached(priority: .utility) {
            guard let repo = GitRepository(containing: dir) else { return }
            repo.stageNavigatorChanges(paths)
        }
    }

    /// Selects an operation's items in the navigator (their parents open).
    func selectNavigatorItems(_ items: [ProjectItem]) {
        guard !items.isEmpty else { return }
        var ids: [String] = []
        func walk(_ n: NavigatorItem) {
            let hit = items.contains { item in
                switch item {
                case .object(let id):
                    n.objectID == id || (n.kind == .container && n.objectID != nil
                        && session.model.projects.values.contains { $0.project?.string("mainGroup") == id && $0.rootObject == n.objectID })
                case .disk(let p):
                    n.objectID == nil && n.path.map { URL(fileURLWithPath: $0).standardizedFileURL.path }
                        == URL(fileURLWithPath: p).standardizedFileURL.path
                }
            }
            if hit { ids.append(n.id) }
            for c in n.children ?? [] { walk(c) }
        }
        walk(root)
        guard !ids.isEmpty else { return }
        for id in ids { expanded.formUnion((root.ancestry(ofID: id) ?? []).dropLast().map(\.id)) }
        navigatorState.multiSelection = ids.count > 1 ? ids : []
        navigatorState.anchor = ids.first
        selection = ids.last
    }

    // MARK: Undo

    /// "Undo New Group", … (nil: nothing to undo).
    public var navigatorUndoTitle: String? {
        _ = navigatorState.undoRevision
        return navigatorState.undoStack.last.map { "Undo \($0.edit.actionName)" }
    }

    public var navigatorRedoTitle: String? {
        _ = navigatorState.undoRevision
        return navigatorState.redoStack.last.map { "Redo \($0.edit.actionName)" }
    }

    /// Undoes the last file operation, while the project is still as it
    /// left it (an edit made elsewhere since would otherwise be lost).
    @discardableResult
    public func undoNavigatorEdit() -> Bool {
        guard let done = navigatorState.undoStack.popLast() else { return false }
        defer { navigatorState.undoRevision += 1 }
        if let p = done.project, session.model.projects[p]?.objects != done.edit.after?.objects {
            navigatorState.lastError = "The project changed since; it cannot be undone"
            return false
        }
        do {
            let before = try done.edit.undo(bin: navigatorState.trashBin)
            applyNavigator(project: done.project, before, moved: Dictionary(uniqueKeysWithValues: done.edit.moved.map { ($1, $0) }),
                           touched: done.edit.touchedPaths)
            navigatorState.redoStack.append(done)
            return true
        } catch {
            navigatorState.lastError = "\(error)"
            return false
        }
    }

    @discardableResult
    public func redoNavigatorEdit() -> Bool {
        guard var done = navigatorState.redoStack.popLast() else { return false }
        defer { navigatorState.undoRevision += 1 }
        if let p = done.project, session.model.projects[p]?.objects != done.edit.before?.objects {
            navigatorState.lastError = "The project changed since; it cannot be redone"
            return false
        }
        do {
            let after = try done.edit.redo(bin: navigatorState.trashBin)
            applyNavigator(project: done.project, after, moved: done.edit.moved, touched: done.edit.touchedPaths)
            selectNavigatorItems(done.edit.result)
            navigatorState.undoStack.append(done)
            return true
        } catch {
            navigatorState.lastError = "\(error)"
            return false
        }
    }

    // MARK: New groups, folders and files

    /// File ▸ New ▸ Group / Group without Folder: "New Group" at the
    /// selection, then renamed in place.
    @discardableResult
    public func newNavigatorGroup(withFolder: Bool, rows: [String]? = nil) -> ProjectEdit? {
        guard let p = navigatorInsertionPoint(rows) else { return nil }
        let edit = performNavigatorEdit(p.project) { ops in
            try ops.newGroup(named: ops.defaultName("New Group", in: p.container), in: p.container, at: p.index, withFolder: withFolder)
        }
        renameNewRow(edit)
        return edit
    }

    /// File ▸ New ▸ Folder: in a group a synchronized folder, in a folder a
    /// directory; renamed in place.
    @discardableResult
    public func newNavigatorFolder(rows: [String]? = nil) -> ProjectEdit? {
        guard let p = navigatorInsertionPoint(rows), let ops = navigatorOperations(p.project) else { return nil }
        let name = ops.defaultName("New Folder", in: p.container)
        let edit = performNavigatorEdit(p.project) { try $0.newFolder(named: name, in: p.container, at: p.index) }
        renameNewRow(edit)
        return edit
    }

    /// File ▸ New ▸ Group from Selection (with or without a folder).
    @discardableResult
    public func groupFromNavigatorSelection(withFolder: Bool, rows: [String]? = nil) -> ProjectEdit? {
        guard let sel = navigatorItems(rows ?? selectedProjectRowIDs), let ops = navigatorOperations(sel.project) else { return nil }
        let parent = ops.insertionPoint(for: sel.items[0]).container
        let edit = performNavigatorEdit(sel.project) { o in
            try o.groupFromSelection(sel.items, named: ops.defaultName("New Group", in: parent), withFolder: withFolder)
        }
        renameNewRow(edit)
        return edit
    }

    /// File ▸ New ▸ Folder from Selection.
    @discardableResult
    public func folderFromNavigatorSelection(rows: [String]? = nil) -> ProjectEdit? {
        guard let sel = navigatorItems(rows ?? selectedProjectRowIDs), let ops = navigatorOperations(sel.project) else { return nil }
        let parent: ProjectItem = {
            if case .disk(let p) = sel.items[0] { return .disk((p as NSString).deletingLastPathComponent) }
            return ops.insertionPoint(for: sel.items[0]).container
        }()
        let edit = performNavigatorEdit(sel.project) { o in try o.folderFromSelection(sel.items, named: ops.defaultName("New Folder", in: parent)) }
        renameNewRow(edit)
        return edit
    }

    /// New Empty File: "File" (then "File 2", …) at the selection, opened.
    @discardableResult
    public func newEmptyNavigatorFile(rows: [String]? = nil) -> ProjectEdit? {
        guard let p = navigatorInsertionPoint(rows), let ops = navigatorOperations(p.project), let dir = ops.directory(of: p.container) else { return nil }
        var name = "File", n = 1
        while FileManager.default.fileExists(atPath: dir.appendingPathComponent(name).path) { n += 1; name = "File \(n)" }
        let edit = performNavigatorEdit(p.project) { try $0.newFiles([(name, "")], in: p.container, at: p.index, targets: []) }
        if edit != nil { open(dir.appendingPathComponent(name).path) }
        return edit
    }

    /// A new group or folder's name is edited in place (its row selected).
    func renameNewRow(_ edit: ProjectEdit?) {
        guard edit != nil, let id = selection, navigatorState.multiSelection.count <= 1 else { return }
        expanded.insert(id)   // a new group shows an open triangle (P-043)
        navigatorState.renaming = id
    }

    // MARK: Add Files

    /// The options Add Files… starts from: the last ones, with the targets
    /// of the selected file (else the first target).
    public func addFilesDefaults(rows: [String]? = nil) -> AddFilesOptions {
        var o = navigatorState.lastAddFilesOptions
        guard let p = navigatorInsertionPoint(rows), let proj = p.project.flatMap({ session.model.projects[$0] }) else { o.targets = []; return o }
        var targets: [String] = []
        if case .object(let id)? = navigatorItems(rows ?? selectedProjectRowIDs)?.items.last {
            targets = proj.targets.filter { t in
                proj.buildPhases(ofTarget: t.id).contains { $0.references("files").contains { proj[$0]?.string("fileRef") == id } }
            }.map(\.id)
        }
        o.targets = targets.isEmpty ? Array(proj.targets.prefix(1).map(\.id)) : targets
        return o
    }

    /// Adds files (chosen in Add Files…'s dialog) at the selection.
    @discardableResult
    public func addFilesToNavigator(_ urls: [URL], options: AddFilesOptions? = nil, rows: [String]? = nil) -> ProjectEdit? {
        guard !urls.isEmpty, let p = navigatorInsertionPoint(rows) else { return nil }
        let o = options ?? addFilesDefaults(rows: rows)
        navigatorState.lastAddFilesOptions = o
        return performNavigatorEdit(p.project) { try $0.addFiles(urls, to: p.container, at: p.index, options: o) }
    }

    /// File ▸ Add Files to “<project>”…: the dialog (the view shows it).
    public func showAddFiles() {
        guard navigatorInsertionPoint() != nil else { return }
        navigatorState.isAddFilesShown = true
    }

    // MARK: Delete

    /// Edit ▸ Delete (and Delete in the navigator): asks whether to move the
    /// files to the Trash or only remove their references (items without a
    /// reference can only go to the Trash). The project row is not deleted.
    public func askDeleteNavigatorSelection(rows: [String]? = nil) {
        let ids = rows ?? selectedProjectRowIDs
        guard canDeleteNavigatorRows(ids), let sel = navigatorItems(ids) else { return }
        let referenceOnly = sel.project != nil && sel.items.allSatisfy { if case .object = $0 { true } else { false } }
        let title = ids.count == 1 ? "Delete \u{201C}\(root.find(id: ids[0])?.name ?? "")\u{201D}?" : "Delete \(ids.count) items?"
        navigatorState.deletePrompt = .init(title: title,
                                            message: referenceOnly ? "Move the files to the Trash, or only remove their references from the project?"
                                                : "The items will be moved to the Trash.",
                                            offersRemoveReferences: referenceOnly)
        pendingDeleteRows = ids
    }

    /// The rows Delete's question is about.
    var pendingDeleteRows: [String] {
        get { navigatorState.multiSelectionForDelete }
        set { navigatorState.multiSelectionForDelete = newValue }
    }

    /// Delete's answer (a `DeletePrompt` button title).
    @discardableResult
    public func answerDeletePrompt(_ button: String) -> ProjectEdit? {
        guard navigatorState.deletePrompt != nil else { return nil }
        navigatorState.deletePrompt = nil
        let rows = pendingDeleteRows
        pendingDeleteRows = []
        switch button {
        case ShellNavigatorState.DeletePrompt.moveToTrash: return deleteNavigatorItems(moveToTrash: true, rows: rows)
        case ShellNavigatorState.DeletePrompt.removeReferences: return deleteNavigatorItems(moveToTrash: false, rows: rows)
        default: return nil
        }
    }

    /// Deletes rows (no question).
    @discardableResult
    public func deleteNavigatorItems(moveToTrash: Bool, rows: [String]? = nil) -> ProjectEdit? {
        let ids = rows ?? selectedProjectRowIDs
        guard canDeleteNavigatorRows(ids), let sel = navigatorItems(ids) else { return nil }
        let edit = performNavigatorEdit(sel.project) { try $0.delete(sel.items, moveToTrash: moveToTrash) }
        if edit != nil, let d = document?.path, !FileManager.default.fileExists(atPath: d) {
            closeCurrentDocument(discard: true)
        }
        return edit
    }

    func canDeleteNavigatorRows(_ ids: [String]) -> Bool {
        !ids.isEmpty && ids.allSatisfy { root.find(id: $0).map { $0.kind != .container } ?? false }
    }

    // MARK: Rename, move, sort

    /// Starts renaming a row in place (Return; P-043).
    public func beginNavigatorRename(_ id: String? = nil) {
        guard let id = id ?? (selectedProjectRowIDs.count == 1 ? selectedProjectRowIDs.first : nil),
              let row = root.find(id: id), row.kind != .container else { return }
        navigatorState.renaming = id
    }

    public func cancelNavigatorRename() { navigatorState.renaming = nil }

    /// An inline rename's end: Return commits (an unchanged name is no edit).
    @discardableResult
    public func renameNavigatorRow(_ id: String, to name: String) -> ProjectEdit? {
        navigatorState.renaming = nil
        guard let row = root.find(id: id), row.name != name, let (project, item) = projectItem(ofRow: id) else { return nil }
        return performNavigatorEdit(project) { try $0.rename(item, to: name) }
    }

    /// A drag inside the navigator: rows onto a group or folder row (into
    /// it, at `index`), or onto a file (after it, in its group). The move
    /// is not undoable; the moved file opens with the editor focused
    /// (P-042, `+NavigatorDragMove.swift`).
    @discardableResult
    public func moveNavigatorRows(_ ids: [String], to dest: String, at index: Int? = nil) -> ProjectEdit? {
        guard !ids.contains(dest), let sel = navigatorItems(ids), let (project, target) = projectItem(ofRow: dest), sel.project == project,
              let ops = navigatorOperations(project) else { return nil }
        // Not into itself (or a row under it).
        if ids.contains(where: { root.ancestry(ofID: dest)?.map(\.id).contains($0) == true }) { return nil }
        let destRow = root.find(id: dest)
        let place: (ProjectItem, Int?) = destRow?.isFile == true ? { let p = ops.insertionPoint(for: target); return (p.container, p.index) }() : (target, index)
        guard let edit = performNavigatorEdit(project, registersUndo: false, { try $0.move(sel.items, to: place.0, at: place.1) }) else {
            return nil
        }
        finishNavigatorDragMove(edit, project: project)
        return edit
    }

    /// Edit ▸ Cut in the navigator: remembers the selection to move.
    public func cutNavigatorSelection() {
        guard let sel = navigatorItems(selectedProjectRowIDs) else { return }
        navigatorState.cut = sel
    }

    /// Edit ▸ Paste ▸ Move Item Here: moves the cut rows to the selection.
    @discardableResult
    public func moveCutNavigatorItemsHere() -> ProjectEdit? {
        guard let cut = navigatorState.cut, let p = navigatorInsertionPoint(), p.project == cut.project else { return nil }
        let edit = performNavigatorEdit(p.project) { try $0.move(cut.items, to: p.container, at: p.index) }
        if edit != nil { navigatorState.cut = nil }
        return edit
    }

    /// Edit ▸ Sort ▸ By Name / By Type: the selected group's children.
    @discardableResult
    public func sortNavigatorGroup(_ order: NavigatorSortOrder, rows: [String]? = nil) -> ProjectEdit? {
        guard let p = navigatorInsertionPoint(rows), navigatorItems(rows ?? selectedProjectRowIDs) != nil else { return nil }
        return performNavigatorEdit(p.project) { try $0.sort(p.container, by: order) }
    }

    /// Show in Files: the first row's file selected in the file manager.
    public func showNavigatorRowsInFiles(rows: [String]? = nil) {
        let urls = (rows ?? selectedProjectRowIDs).compactMap { root.find(id: $0)?.path }.map { URL(fileURLWithPath: $0) }
        guard let first = urls.first else { return }
        navigatorState.revealInFiles(first)
    }

    // MARK: Which operations apply

    /// Whether the rows' insertion point is a classic group, where groups
    /// and sorting apply.
    func navigatorSelectionInGroup(_ ids: [String]) -> Bool {
        guard navigatorItems(ids) != nil, let p = navigatorInsertionPoint(ids), let proj = p.project.flatMap({ session.model.projects[$0] }),
              case .object(let id) = p.container else { return false }
        return proj[proj.groupID(id)]?.isa == "PBXGroup"
    }

    /// A context-menu or "+" command's state for these rows (P-041): what
    /// Ycode cannot do on Linux yet is disabled.
    public func isNavigatorCommandEnabled(_ c: ProjectRowMenu.Command, rows ids: [String]) -> Bool {
        let has = navigatorItems(ids) != nil
        switch c {
        case .showInFinder: return ids.contains { root.find(id: $0)?.path != nil }
        case .openInNewTab, .openInNewTabs: return ids.contains { root.find(id: $0)?.isFile == true }
        case .newEmptyFile: return navigatorInsertionPoint(ids.isEmpty ? nil : ids) != nil
        case .addFiles: return navigatorInsertionPoint(ids.isEmpty ? nil : ids) != nil
        case .delete: return has && canDeleteNavigatorRows(ids)
        case .newGroup, .newGroupWithoutFolder, .sortByName, .sortByType: return navigatorSelectionInGroup(ids)
        case .newGroupFromSelection, .newGroupFromSelectionWithoutFolder:
            guard let sel = navigatorItems(ids), let ops = navigatorOperations(sel.project) else { return false }
            return ops.canGroup(sel.items)
        case .newFolder: return has || (containerKind == .package && !ids.isEmpty)
        case .newFolderFromSelection:
            guard let sel = navigatorItems(ids), let ops = navigatorOperations(sel.project) else { return false }
            return ops.canMakeFolder(from: sel.items)
        case .findInSelected: return has
        case .scmCommit, .scmRefreshStatus: return sourceControl.repository != nil
        case .newFileFromTemplate: return navigatorState.newFileFromTemplate != nil
        case .openTerminalAtLocation, .openInNewWindow, .openWithExternalEditor, .addPackageDependencies, .migrateToStringCatalog, .bookmark,
             .scmAdd, .scmMarkResolved:
            return false
        }
    }

    /// Performs a context-menu or "+" command on these rows.
    public func performNavigatorCommand(_ c: ProjectRowMenu.Command, rows ids: [String]) {
        guard isNavigatorCommandEnabled(c, rows: ids) else { return }
        let rows: [String]? = ids.isEmpty ? nil : ids
        switch c {
        case .showInFinder: showNavigatorRowsInFiles(rows: rows)
        case .openInNewTab, .openInNewTabs:
            for id in ids { if let p = root.find(id: id)?.path, root.find(id: id)?.isFile == true { open(p) } }
        case .newEmptyFile: newEmptyNavigatorFile(rows: rows)
        case .newFileFromTemplate:
            if let rows { select(rows) }
            navigatorState.newFileFromTemplate?()
        case .addFiles:
            if let rows { select(rows) }
            showAddFiles()
        case .delete: askDeleteNavigatorSelection(rows: rows)
        case .newGroup: newNavigatorGroup(withFolder: true, rows: rows)
        case .newGroupWithoutFolder: newNavigatorGroup(withFolder: false, rows: rows)
        case .newGroupFromSelection: groupFromNavigatorSelection(withFolder: true, rows: rows)
        case .newGroupFromSelectionWithoutFolder: groupFromNavigatorSelection(withFolder: false, rows: rows)
        case .newFolder: newNavigatorFolder(rows: rows)
        case .newFolderFromSelection: folderFromNavigatorSelection(rows: rows)
        case .sortByName: sortNavigatorGroup(.name, rows: rows)
        case .sortByType: sortNavigatorGroup(.type, rows: rows)
        case .findInSelected: showFindInWorkspace()
        case .scmCommit: perform(.scmCommit)
        case .scmRefreshStatus: perform(.scmRefresh)
        default: break
        }
    }

    /// Selects rows (the context menu's rows before a dialog).
    func select(_ ids: [String]) {
        navigatorState.multiSelection = ids.count > 1 ? ids : []
        selection = ids.last
    }

    // MARK: Menus (B5-MENUS2 routes these selectors here)

    /// The navigator commands of the menu bar by their `CommandTable`
    /// action, as the macOS window answers them.
    static let menuActions: [String: ProjectRowMenu.Command] = [
        "newGroup:": .newGroup, "newGroupWithoutFolder:": .newGroupWithoutFolder,
        "newGroupFromSelection:": .newGroupFromSelection, "newGroupFromSelectionWithoutFolder:": .newGroupFromSelectionWithoutFolder,
        "newFolder:": .newFolder, "newFolderFromSelection:": .newFolderFromSelection, "addFiles:": .addFiles,
        "newEmptyFile:": .newEmptyFile, "sortByName:": .sortByName, "sortByType:": .sortByType,
        "deleteNavigatorSelection:": .delete, "showNavigatorSelectionInFinder:": .showInFinder,
    ]

    /// Whether a menu item with this action is enabled (nil: not one of
    /// the navigator's).
    public func validateProjectNavigatorAction(_ selector: String) -> Bool? {
        let inProject = navigator == .project && isNavigatorShown
        switch selector {
        case "undo:" where inProject && ShellNavigatorFocus.projectOutlineHasKeyboard: return navigatorUndoTitle != nil
        case "redo:" where inProject && ShellNavigatorFocus.projectOutlineHasKeyboard: return navigatorRedoTitle != nil
        case "moveItemHere:": return navigatorState.cut != nil && navigatorInsertionPoint()?.project == navigatorState.cut?.project
        case "cut:" where inProject && ShellNavigatorFocus.projectOutlineHasKeyboard: return navigatorItems(selectedProjectRowIDs) != nil
        default:
            guard let c = Self.menuActions[selector] else { return nil }
            // Add Files… and New Empty File need no navigator selection.
            if c == .addFiles || c == .newEmptyFile { return isNavigatorCommandEnabled(c, rows: []) }
            return inProject && isNavigatorCommandEnabled(c, rows: selectedProjectRowIDs)
        }
    }

    /// The menu bar's navigator conditions: New ▸ Group items hidden while
    /// the selection is in a folder, Paste ▸ Move Item Here shown after a Cut.
    public func fillNavigatorMenuContext(_ c: inout MenuContext) {
        let ids = selectedProjectRowIDs
        c.projectSelectionInFolder = !ids.isEmpty && navigatorItems(ids) != nil && !navigatorSelectionInGroup(ids)
        c.hasItemToMove = navigatorState.cut != nil
    }

    /// Performs a menu item's action; false when it is not the navigator's.
    @discardableResult
    public func performProjectNavigatorAction(_ selector: String) -> Bool {
        guard validateProjectNavigatorAction(selector) == true else { return false }
        switch selector {
        case "undo:": return undoNavigatorEdit()
        case "redo:": return redoNavigatorEdit()
        case "moveItemHere:": return moveCutNavigatorItemsHere() != nil
        case "cut:": cutNavigatorSelection(); return true
        default:
            guard let c = Self.menuActions[selector] else { return false }
            performNavigatorCommand(c, rows: c == .addFiles || c == .newEmptyFile ? [] : selectedProjectRowIDs)
            return true
        }
    }
}

/// Who has the keyboard in the navigators, where the model needs to know
/// (the Edit menu's Cut, Undo and Delete act on the navigator while it has it).
@MainActor
public enum ShellNavigatorFocus {
    public static var projectOutlineHasKeyboard = false
}
