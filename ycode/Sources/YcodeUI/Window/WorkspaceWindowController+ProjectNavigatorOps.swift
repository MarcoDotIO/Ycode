import AppKit
import YcodeIDECore
import YcodeProject

/// The project navigator's file operations in the window: File ▸ New ▸
/// Group / Folder items, Add Files…, Edit ▸ Delete, Sort, inline rename,
/// drag and drop, and the rows' context menu. The model work is
/// `ProjectFileOperations` (YcodeIDECore); this file maps rows to items,
/// writes the project, refreshes the tree, follows open files, stages the
/// change in git and registers undo. See `specs/ide/navigators.md`
/// §Ycode implementation.
extension WorkspaceWindowController {
    /// Where trashed items go: the user's trash (tests use a folder).
    public static var navigatorTrashBin: TrashBin = .user

    /// Connects the navigator's project hooks to this window.
    func wireProjectNavigatorOperations() {
        navigator.projectOps.rowMenu = { [weak self] in self?.projectRowMenuItems() ?? [] }
        navigator.projectOps.delete = { [weak self] in self?.deleteNavigatorSelection(nil) }
        navigator.projectOps.cut = { [weak self] in self?.cutNavigatorSelection() }
        navigator.projectOps.rename = { [weak self] row, name in self?.renameNavigatorRow(row, to: name) }
        navigator.projectOps.move = { [weak self] rows, dest, index in self?.moveNavigatorRows(rows, to: dest, at: index) }
        navigator.projectOps.addFiles = { [weak self] urls, dest, index in self?.addFiles(urls, to: dest, at: index) }
    }

    // MARK: Rows and items

    /// A project row as an operation's item, with its project (nil in a package).
    func projectItem(of row: OutlineItem) -> (project: String?, item: ProjectItem)? {
        let proj = navigator.projectPath(of: row)
        if let proj, let id = row.objectID { return (proj, .object(id)) }
        if let p = row.nodePath, proj != nil || session.model.kind == .package { return (proj, .disk(p)) }
        return nil
    }

    /// The selected project rows as items, when they are all in one project.
    public var navigatorSelectionItems: (project: String?, items: [ProjectItem])? {
        let mapped = navigator.selectedProjectRows.compactMap(projectItem)
        guard !mapped.isEmpty, mapped.count == navigator.selectedProjectRows.count,
              mapped.allSatisfy({ $0.project == mapped[0].project }) else { return nil }
        return (mapped[0].project, mapped.map(\.item))
    }

    /// The project new items go to without a selection: the first one.
    var defaultNavigatorProject: String? { session.model.kind == .package ? nil : session.model.projects.keys.sorted().first }

    func navigatorOperations(_ project: String?) -> ProjectFileOperations? {
        if let project, let proj = session.model.projects[project] {
            return ProjectFileOperations(project: proj, xcodeprojURL: URL(fileURLWithPath: project), bin: Self.navigatorTrashBin)
        }
        return session.model.kind == .package ? ProjectFileOperations(packageDirectory: session.model.url, bin: Self.navigatorTrashBin) : nil
    }

    /// Where new items go: after the selected file, or into the selected
    /// group or folder (else the main group).
    func navigatorInsertionPoint() -> (project: String?, container: ProjectItem, index: Int?)? {
        let sel = navigatorSelectionItems
        let project = sel?.project ?? defaultNavigatorProject
        guard let ops = navigatorOperations(project) else { return nil }
        let p = ops.insertionPoint(for: sel?.items.last)
        return (project, p.container, p.index)
    }

    /// The folder of the navigator's insertion point, when the project
    /// navigator has a selection.
    var navigatorSelectionDirectory: URL? {
        guard navigator.selectedIndex == 0, navigatorSelectionItems != nil, let p = navigatorInsertionPoint(),
              let ops = navigatorOperations(p.project) else { return nil }
        return ops.directory(of: p.container)
    }

    // MARK: Running an operation

    /// Runs an operation on a project (nil: the package), applies it and
    /// registers its undo. Returns nil (and reports the error) on failure.
    @discardableResult
    func performNavigatorEdit(_ project: String?, _ body: (inout ProjectFileOperations) throws -> ProjectEdit) -> ProjectEdit? {
        guard var ops = navigatorOperations(project) else { NSSound.beep(); return nil }
        saveDirtyEditors()
        do {
            let edit = try body(&ops)
            lastNavigatorError = nil
            applyNavigator(project: project, ops.project, moved: edit.moved, touched: edit.touchedPaths)
            selectNavigatorItems(edit.result)
            registerNavigatorUndo(edit, project)
            return edit
        } catch {
            reportNavigatorError(error)
            return nil
        }
    }

    func reportNavigatorError(_ error: Error) {
        lastNavigatorError = "\(error)"
        if let window, window.isVisible {
            let alert = NSAlert()
            alert.messageText = "The operation could not be completed."
            alert.informativeText = "\(error)"
            alert.beginSheetModal(for: window)
        } else {
            NSSound.beep()
        }
    }

    /// Unsaved editor text goes to disk first, so a move or rename does
    /// not leave it behind.
    func saveDirtyEditors() {
        for t in editorArea.tabs { for e in t.editors where e.isDirty { try? e.save() } }
    }

    /// Writes the project, rebuilds the tree, moves open editors along and
    /// stages the change in git.
    func applyNavigator(project: String?, _ proj: PBXProj?, moved: [String: String], touched: [String]) {
        if let project, let proj {
            projectChanged(path: project, proj)
            if session.model.kind == .workspace { rebuildWorkspaceTree() }
        } else {
            session.model.root = NavigatorTree.package(at: session.model.url)
            navigator.setProjectTree(session.model.root, packages: packageSection())
        }
        followMovedFiles(moved)
        stageNavigatorChange(touched)
        refreshWorkspaceIndexAfterNavigatorEdit()
    }

    /// A workspace's tree: one project row per project, in their order.
    func rebuildWorkspaceTree() {
        let rows = session.model.root.children.compactMap { row -> NavigatorNode? in
            guard let p = row.path, let proj = session.model.projects[p] else { return row }
            return NavigatorTree.project(proj, xcodeprojURL: URL(fileURLWithPath: p))
        }
        let old = session.model.root
        session.model.root = NavigatorNode(name: old.name, kind: old.kind, path: old.path, objectID: old.objectID, children: rows)
        navigator.setProjectTree(session.model.root, packages: packageSection())
    }

    /// Editors showing a moved file (or a file in a moved folder) follow it.
    func followMovedFiles(_ moved: [String: String]) {
        guard !moved.isEmpty else { return }
        func newPath(_ url: URL?) -> String? {
            guard let current = url?.standardizedFileURL.path else { return nil }
            for (old, new) in moved {
                let o = URL(fileURLWithPath: old).standardizedFileURL.path
                if current == o || current.hasPrefix(o + "/") { return new + current.dropFirst(o.count) }
            }
            return nil
        }
        for t in editorArea.tabs {
            for e in t.editors where e !== editor { if let p = newPath(e.fileURL) { try? e.open(URL(fileURLWithPath: p)) } }
        }
        if let p = newPath(editor.fileURL) { open(path: p, line: nil) }
    }

    /// Settings ▸ Source Control on: new, moved and trashed paths are
    /// staged (`git add -A`), as git mv and git rm would record them.
    func stageNavigatorChange(_ paths: [String]) {
        guard Preferences.shared.sourceControlEnabled, !paths.isEmpty else { return }
        let dir = session.model.kind == .package ? session.model.url : session.model.url.deletingLastPathComponent()
        Task.detached(priority: .utility) {
            guard let repo = GitRepository(containing: dir) else { return }
            repo.stageNavigatorChanges(paths)
        }
    }

    /// Open Quickly and Find read the file list again.
    func refreshWorkspaceIndexAfterNavigatorEdit() {
        refreshFileStatus(nil)
    }

    /// Selects the operation's items in the navigator.
    func selectNavigatorItems(_ items: [ProjectItem]) {
        guard !items.isEmpty else { return }
        let mains = Set(session.model.projects.values.compactMap { $0.project?.string("mainGroup") })
        navigator.selectProjectRows { row in
            items.contains { item in
                switch item {
                case .object(let id): row.objectID == id || (row.nodeKind == .container && mains.contains(id) && row.objectID != nil)
                case .disk(let p): row.objectID == nil && row.nodePath.map { URL(fileURLWithPath: $0).standardizedFileURL.path }
                    == URL(fileURLWithPath: p).standardizedFileURL.path
                }
            }
        }
    }

    // MARK: Undo

    func registerNavigatorUndo(_ edit: ProjectEdit, _ project: String?) {
        guard let um = window?.undoManager else { return }
        um.registerUndo(withTarget: self) { wc in MainActor.assumeIsolated { wc.revertNavigatorEdit(edit, project) } }
        um.setActionName(edit.actionName)
    }

    /// Undo: only while the project is still as the edit left it (an
    /// edit made elsewhere since would otherwise be lost).
    func revertNavigatorEdit(_ edit: ProjectEdit, _ project: String?) {
        if let project, session.model.projects[project]?.objects != edit.after?.objects { return reportNavigatorError(NavigatorEditError.notAllowed("The project changed since; it cannot be undone")) }
        do {
            let before = try edit.undo(bin: Self.navigatorTrashBin)
            applyNavigator(project: project, before, moved: Dictionary(uniqueKeysWithValues: edit.moved.map { ($1, $0) }), touched: edit.touchedPaths)
            window?.undoManager?.registerUndo(withTarget: self) { wc in MainActor.assumeIsolated { wc.reapplyNavigatorEdit(edit, project) } }
            window?.undoManager?.setActionName(edit.actionName)
        } catch {
            reportNavigatorError(error)
        }
    }

    func reapplyNavigatorEdit(_ edit: ProjectEdit, _ project: String?) {
        if let project, session.model.projects[project]?.objects != edit.before?.objects { return reportNavigatorError(NavigatorEditError.notAllowed("The project changed since; it cannot be redone")) }
        var edit = edit
        do {
            let after = try edit.redo(bin: Self.navigatorTrashBin)
            applyNavigator(project: project, after, moved: edit.moved, touched: edit.touchedPaths)
            selectNavigatorItems(edit.result)
            registerNavigatorUndo(edit, project)
        } catch {
            reportNavigatorError(error)
        }
    }

    // MARK: File ▸ New ▸ Group, Folder

    /// File ▸ New ▸ Group: a group with a folder, named "New Group" and
    /// then renamed in place.
    @objc public func newGroup(_ sender: Any?) { _ = newNavigatorGroup(withFolder: true) }

    /// File ▸ New ▸ Group without Folder.
    @objc public func newGroupWithoutFolder(_ sender: Any?) { _ = newNavigatorGroup(withFolder: false) }

    func newNavigatorGroup(withFolder: Bool) -> ProjectEdit? {
        guard let p = navigatorInsertionPoint() else { NSSound.beep(); return nil }
        let edit = performNavigatorEdit(p.project) { ops in
            try ops.newGroup(named: ops.defaultName("New Group", in: p.container), in: p.container, at: p.index, withFolder: withFolder)
        }
        renameNewRow(edit)
        return edit
    }

    /// File ▸ New ▸ Folder (⌥⌘N): in a group, a new synchronized folder;
    /// in a folder, a directory. Returns the folder.
    @discardableResult
    func newNavigatorFolder() -> URL? {
        guard navigator.selectedIndex == 0, navigatorSelectionItems != nil || session.model.kind == .package,
              let p = navigatorInsertionPoint(), let ops = navigatorOperations(p.project), let dir = ops.directory(of: p.container) else {
            NSSound.beep()
            return nil
        }
        let name = ops.defaultName("New Folder", in: p.container)
        let edit = performNavigatorEdit(p.project) { try $0.newFolder(named: name, in: p.container, at: p.index) }
        renameNewRow(edit)
        return edit == nil ? nil : dir.appendingPathComponent(name)
    }

    /// File ▸ New ▸ Group from Selection (with or without a folder).
    @objc public func newGroupFromSelection(_ sender: Any?) { _ = groupFromNavigatorSelection(withFolder: true) }

    @objc public func newGroupFromSelectionWithoutFolder(_ sender: Any?) { _ = groupFromNavigatorSelection(withFolder: false) }

    func groupFromNavigatorSelection(withFolder: Bool) -> ProjectEdit? {
        guard let sel = navigatorSelectionItems, let ops = navigatorOperations(sel.project) else { NSSound.beep(); return nil }
        let parent = ops.insertionPoint(for: sel.items[0]).container
        let edit = performNavigatorEdit(sel.project) { o in
            try o.groupFromSelection(sel.items, named: ops.defaultName("New Group", in: parent), withFolder: withFolder)
        }
        renameNewRow(edit)
        return edit
    }

    /// File ▸ New ▸ Folder from Selection.
    @objc public func newFolderFromSelection(_ sender: Any?) { _ = folderFromNavigatorSelection() }

    func folderFromNavigatorSelection() -> ProjectEdit? {
        guard let sel = navigatorSelectionItems, let ops = navigatorOperations(sel.project) else { NSSound.beep(); return nil }
        let parent: ProjectItem = {
            if case .disk(let p) = sel.items[0] { return .disk((p as NSString).deletingLastPathComponent) }
            return ops.insertionPoint(for: sel.items[0]).container
        }()
        let edit = performNavigatorEdit(sel.project) { o in
            try o.folderFromSelection(sel.items, named: ops.defaultName("New Folder", in: parent))
        }
        renameNewRow(edit)
        return edit
    }

    /// A new group or folder's name is edited in place (visible windows).
    func renameNewRow(_ edit: ProjectEdit?) {
        guard edit != nil, window?.isVisible == true, navigator.selectedProjectRows.count == 1, let row = navigator.selectedProjectRows.first else { return }
        navigator.beginRename(row)
    }

    // MARK: New files

    /// Writes new files (from a template) into `directory` through the
    /// navigator's operations: into the selected group when it is that
    /// folder's group, else the folder's group, else the main group;
    /// `targets` are target names (nil: the first target with Compile
    /// Sources, for compiled files). In a synchronized folder, unchosen
    /// targets get exceptions. Opens the first file.
    @discardableResult
    func createNavigatorFiles(_ files: [(String, String)], in directory: URL, targets: [String]?) throws -> [URL] {
        let dir = directory.standardizedFileURL
        var top: [String] = []
        for (f, _) in files {
            let first = String(f.split(separator: "/", omittingEmptySubsequences: true).first ?? Substring(f))
            if !top.contains(first) { top.append(first) }
        }
        for t in top where FileManager.default.fileExists(atPath: dir.appendingPathComponent(t).path) {
            throw NewFileError.exists(dir.appendingPathComponent(t).path)
        }
        let project = session.model.kind == .package ? nil : session.model.projects.keys.sorted().first {
            dir.path.hasPrefix(URL(fileURLWithPath: $0).deletingLastPathComponent().path)
        }
        guard let ops = navigatorOperations(project) else {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            for (f, text) in files { try text.write(to: dir.appendingPathComponent(f), atomically: true, encoding: .utf8) }
            return top.map { dir.appendingPathComponent($0) }
        }
        let place = navigatorContainer(for: dir, project: project, ops: ops)
        let ids = targets.map { names in ops.project?.targets.filter { names.contains($0.string("name") ?? "") }.map(\.id) ?? [] }
        if !FileManager.default.fileExists(atPath: dir.path) { try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true) }
        guard let edit = performNavigatorEdit(project, { try $0.newFiles(files, in: place.container, at: place.index, targets: ids) }) else {
            throw NavigatorEditError.notAllowed(lastNavigatorError ?? "The files could not be created")
        }
        _ = edit
        let urls = top.map { dir.appendingPathComponent($0) }
        if let first = urls.first { open(path: first.path, line: nil) }
        return urls
    }

    /// The container whose folder is `dir`: the navigator's insertion
    /// point when it is that folder, else the first group (by ID) of that
    /// folder, a folder on disk, or the main group.
    func navigatorContainer(for dir: URL, project: String?, ops: ProjectFileOperations) -> (container: ProjectItem, index: Int?) {
        let path = dir.standardizedFileURL.path
        if let p = navigatorInsertionPoint(), p.project == project, ops.directory(of: p.container)?.standardizedFileURL.path == path {
            return (p.container, p.index)
        }
        guard let proj = ops.project else { return (.disk(path), nil) }
        let groups = proj.objects.values.filter { $0.isa == "PBXGroup" }.sorted { $0.id < $1.id }
        if let g = groups.first(where: { ops.directory(of: .object($0.id))?.standardizedFileURL.path == path }) { return (.object(g.id), nil) }
        let folders = proj.objects.values.filter { $0.isa == "PBXFileSystemSynchronizedRootGroup" }
        if let f = folders.first(where: { ops.directory(of: .object($0.id)).map { path == $0.path || path.hasPrefix($0.path + "/") } ?? false }) {
            return ops.directory(of: .object(f.id))?.standardizedFileURL.path == path ? (.object(f.id), nil) : (.disk(path), nil)
        }
        return (.object(proj.rootObject), nil)
    }

    // MARK: Add Files

    /// File ▸ Add Files to “<project>”… (⌥⌘A): an open panel with the
    /// options (action, groups, targets), then `addFilesToNavigator`.
    @objc public func addFiles(_ sender: Any?) {
        guard let window, window.isVisible, let p = navigatorInsertionPoint() else { NSSound.beep(); return }
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.prompt = "Add"
        let accessory = AddFilesAccessory(project: p.project.flatMap { session.model.projects[$0] }, options: addFilesDefaults(p))
        panel.accessoryView = accessory.view
        panel.isAccessoryViewDisclosed = true
        panel.beginSheetModal(for: window) { [weak self] r in
            guard r == .OK, let self else { return }
            self.lastAddFilesOptions = accessory.options
            self.addFilesToNavigator(panel.urls, options: accessory.options)
        }
    }

    /// The options to start from: the last ones, with the targets of the
    /// selected file (or the group's files, else the first target).
    func addFilesDefaults(_ p: (project: String?, container: ProjectItem, index: Int?)) -> AddFilesOptions {
        var o = lastAddFilesOptions
        guard let proj = p.project.flatMap({ session.model.projects[$0] }) else { o.targets = []; return o }
        var targets: [String] = []
        if case .object(let id)? = navigatorSelectionItems?.items.last {
            targets = proj.targets.filter { t in proj.buildPhases(ofTarget: t.id).contains { $0.references("files").contains { proj[$0]?.string("fileRef") == id } } }.map(\.id)
        }
        o.targets = targets.isEmpty ? Array(proj.targets.prefix(1).map(\.id)) : targets
        return o
    }

    /// Adds files at the navigator's insertion point.
    @discardableResult
    public func addFilesToNavigator(_ urls: [URL], options: AddFilesOptions) -> ProjectEdit? {
        guard let p = navigatorInsertionPoint() else { NSSound.beep(); return nil }
        return performNavigatorEdit(p.project) { try $0.addFiles(urls, to: p.container, at: p.index, options: options) }
    }

    /// Files dropped from outside onto a row (the last Add Files options,
    /// with the targets of the destination's files).
    @discardableResult
    func addFiles(_ urls: [URL], to dest: OutlineItem, at index: Int?) -> ProjectEdit? {
        guard let (project, item) = projectItem(of: dest) else { NSSound.beep(); return nil }
        var options = lastAddFilesOptions
        if let project, let proj = session.model.projects[project], case .object(let id) = item {
            let kids = Set(proj[proj.groupID(id)]?.references("children") ?? [])
            let found = proj.targets.filter { t in proj.buildPhases(ofTarget: t.id).contains { $0.references("files").contains { proj[$0]?.string("fileRef").map(kids.contains) ?? false } } }
            options.targets = found.map(\.id)
        } else {
            options.targets = []
        }
        return performNavigatorEdit(project) { try $0.addFiles(urls, to: item, at: index, options: options) }
    }

    // MARK: Delete, rename, move, sort

    /// Edit ▸ Delete (⌘⌫) in the navigator: asks whether to move the files
    /// to the Trash or only remove the references (items without a
    /// reference, in a folder or a package, can only go to the Trash).
    @objc public func deleteNavigatorSelection(_ sender: Any?) {
        guard let sel = navigatorSelectionItems else { return NSSound.beep() }
        let referenceOnly = sel.project != nil && sel.items.allSatisfy { if case .object = $0 { true } else { false } }
        guard let window, window.isVisible else { return }
        let alert = NSAlert()
        let count = sel.items.count
        alert.messageText = count == 1 ? "Delete “\(navigator.selectedProjectRows.first.map(navigator.editableName) ?? "")”?"
            : "Delete \(count) items?"
        alert.informativeText = referenceOnly
            ? "Move the files to the Trash, or only remove their references from the project?"
            : "The items will be moved to the Trash."
        alert.addButton(withTitle: "Move to Trash")
        if referenceOnly { alert.addButton(withTitle: "Remove References") }
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: window) { [weak self] r in
            switch r {
            case .alertFirstButtonReturn: self?.deleteNavigatorItems(moveToTrash: true)
            case .alertSecondButtonReturn where referenceOnly: self?.deleteNavigatorItems(moveToTrash: false)
            default: break
            }
        }
    }

    /// Deletes the selected rows (no confirmation).
    @discardableResult
    public func deleteNavigatorItems(moveToTrash: Bool) -> ProjectEdit? {
        guard let sel = navigatorSelectionItems else { NSSound.beep(); return nil }
        return performNavigatorEdit(sel.project) { try $0.delete(sel.items, moveToTrash: moveToTrash) }
    }

    /// The context menu's Rename: edits the row's name in place.
    @objc public func renameNavigatorSelection(_ sender: Any?) {
        guard navigator.selectedProjectRows.count == 1, let row = navigator.selectedProjectRows.first else { return NSSound.beep() }
        navigator.beginRename(row)
    }

    /// An inline rename's end.
    @discardableResult
    public func renameNavigatorRow(_ row: OutlineItem, to name: String) -> ProjectEdit? {
        guard let (project, item) = projectItem(of: row) else { NSSound.beep(); return nil }
        return performNavigatorEdit(project) { try $0.rename(item, to: name) }
    }

    /// A drag inside the navigator: rows onto a group or folder row.
    @discardableResult
    public func moveNavigatorRows(_ rows: [OutlineItem], to dest: OutlineItem, at index: Int?) -> ProjectEdit? {
        let items = rows.compactMap(projectItem)
        guard items.count == rows.count, let (project, target) = projectItem(of: dest), items.allSatisfy({ $0.project == project }) else {
            NSSound.beep()
            return nil
        }
        return performNavigatorEdit(project) { try $0.move(items.map(\.item), to: target, at: index) }
    }

    /// Edit ▸ Cut in the navigator: remembers the selection to move.
    public func cutNavigatorSelection() {
        guard let sel = navigatorSelectionItems else { return NSSound.beep() }
        navigator.itemsToMove = sel
    }

    /// Edit ▸ Paste ▸ Move Item Here (⌥⌘V): moves the cut items to the
    /// navigator's insertion point.
    @objc public func moveItemHere(_ sender: Any?) { _ = moveCutItemsHere() }

    func moveCutItemsHere() -> ProjectEdit? {
        guard let cut = navigator.itemsToMove, let p = navigatorInsertionPoint(), p.project == cut.project else { NSSound.beep(); return nil }
        let edit = performNavigatorEdit(p.project) { try $0.move(cut.items, to: p.container, at: p.index) }
        if edit != nil { navigator.itemsToMove = nil }
        return edit
    }

    /// Edit ▸ Sort ▸ By Name.
    @objc public func sortByName(_ sender: Any?) { _ = sortNavigatorGroup(.name) }

    /// Edit ▸ Sort ▸ By Type.
    @objc public func sortByType(_ sender: Any?) { _ = sortNavigatorGroup(.type) }

    func sortNavigatorGroup(_ order: NavigatorSortOrder) -> ProjectEdit? {
        guard let p = navigatorInsertionPoint(), navigatorSelectionItems != nil else { NSSound.beep(); return nil }
        return performNavigatorEdit(p.project) { try $0.sort(p.container, by: order) }
    }

    // MARK: Convert

    /// The single selected row as an object, with its project.
    var singleNavigatorObject: (project: String, id: String, isa: String)? {
        guard let sel = navigatorSelectionItems, sel.items.count == 1, let project = sel.project, case .object(let id) = sel.items[0],
              let proj = session.model.projects[project], let obj = proj[proj.groupID(id)] else { return nil }
        return (project, obj.id, obj.isa)
    }

    /// Edit ▸ Convert ▸ To Group: the selected synchronized folder.
    @objc public func convertToGroup(_ sender: Any?) { _ = convertNavigatorSelection(toFolder: false) }

    /// Edit ▸ Convert ▸ To Folder: the selected group.
    @objc public func convertToFolder(_ sender: Any?) { _ = convertNavigatorSelection(toFolder: true) }

    func convertNavigatorSelection(toFolder: Bool) -> ProjectEdit? {
        guard let o = singleNavigatorObject else { NSSound.beep(); return nil }
        return performNavigatorEdit(o.project) { toFolder ? try $0.convertToFolder(.object(o.id)) : try $0.convertToGroup(.object(o.id)) }
    }

    /// Edit ▸ Convert ▸ Preflight Conversion to Folder: what would stop
    /// To Folder, in an alert (nil: nothing does).
    @discardableResult
    @objc public func preflightConversionToFolder(_ sender: Any?) -> [String] {
        guard let o = singleNavigatorObject, let ops = navigatorOperations(o.project) else { NSSound.beep(); return ["Select a group."] }
        let problems = ops.folderConversionProblems(.object(o.id))
        if let window, window.isVisible {
            let alert = NSAlert()
            alert.messageText = problems.isEmpty ? "The group can be converted to a folder." : "The group cannot be converted to a folder."
            alert.informativeText = problems.joined(separator: "\n")
            alert.beginSheetModal(for: window)
        }
        return problems
    }

    /// The context menu's Show in Finder: the selected rows' files.
    @objc public func showNavigatorSelectionInFinder(_ sender: Any?) {
        let urls = navigator.selectedProjectRows.compactMap { $0.nodePath.map { URL(fileURLWithPath: $0) } }
        guard window?.isVisible == true, !urls.isEmpty else { return }
        NSWorkspace.shared.activateFileViewerSelecting(urls)
    }

    // MARK: Menus

    /// Whether the selection is a classic group (or in one), where
    /// groups and sorting apply.
    var navigatorSelectionInGroup: Bool {
        guard let p = navigatorInsertionPoint(), navigatorSelectionItems != nil, let ops = navigatorOperations(p.project), ops.project != nil else { return false }
        if case .object(let id) = p.container, let proj = ops.project { return proj[proj.groupID(id)]?.isa == "PBXGroup" }
        return false
    }

    /// Enablement of the navigator's file operations; nil = not one of them.
    func validateProjectNavigatorItem(_ item: NSMenuItem) -> Bool? {
        let hasSelection = navigator.selectedIndex == 0 && navigatorSelectionItems != nil
        switch item.action {
        // With no navigator selection the group and folder items are disabled (reference-ui-6.md §8 item 6).
        case #selector(newGroup(_:)), #selector(newGroupWithoutFolder(_:)): return navigatorSelectionInGroup
        case #selector(newGroupFromSelection(_:)), #selector(newGroupFromSelectionWithoutFolder(_:)):
            guard let sel = navigatorSelectionItems, let ops = navigatorOperations(sel.project) else { return false }
            return ops.canGroup(sel.items)
        case #selector(newFolder(_:)): return hasSelection || (session.model.kind == .package && navigator.selectedIndex == 0 && !navigator.selectedProjectRows.isEmpty)
        case #selector(newFolderFromSelection(_:)):
            guard let sel = navigatorSelectionItems, let ops = navigatorOperations(sel.project) else { return false }
            return ops.canMakeFolder(from: sel.items)
        case #selector(addFiles(_:)): return navigatorInsertionPoint() != nil
        case #selector(sortByName(_:)), #selector(sortByType(_:)): return navigatorSelectionInGroup
        case #selector(deleteNavigatorSelection(_:)), #selector(showNavigatorSelectionInFinder(_:)): return hasSelection
        case #selector(moveItemHere(_:)): return navigator.itemsToMove != nil && navigatorInsertionPoint()?.project == navigator.itemsToMove?.project
        case #selector(convertToGroup(_:)): return singleNavigatorObject?.isa == "PBXFileSystemSynchronizedRootGroup"
        case #selector(convertToFolder(_:)), #selector(preflightConversionToFolder(_:)):
            guard let o = singleNavigatorObject, o.isa == "PBXGroup" else { return false }
            return session.model.projects[o.project]?.project?.string("mainGroup") != o.id
        case #selector(renameNavigatorSelection(_:)): return hasSelection && navigator.selectedProjectRows.count == 1
            && navigator.selectedProjectRows.first?.nodeKind != .container
        default: return nil
        }
    }

    /// The project rows' context menu (Ycode's grouping of the commands).
    func projectRowMenuItems() -> [NSMenuItem] {
        func item(_ title: String, _ action: Selector, target: AnyObject? = nil) -> NSMenuItem {
            let i = NSMenuItem(title: title, action: action, keyEquivalent: "")
            i.target = target ?? self
            return i
        }
        let inFolder = projectSelectionIsInFolder
        var items: [NSMenuItem] = [
            item("Show in Finder", #selector(showNavigatorSelectionInFinder(_:))),
            .separator(),
            item("New File from Template…", #selector(newFile(_:))),
            item("New Empty File", #selector(newEmptyFile(_:))),
            item(MenuTitles.title(generic: "Add Files…", in: menuContext), #selector(addFiles(_:))),
            .separator(),
            item("Rename", #selector(renameNavigatorSelection(_:))),
            item("Delete", #selector(deleteNavigatorSelection(_:))),
            .separator(),
        ]
        if !inFolder {
            items += [item("New Group", #selector(newGroup(_:))), item("New Group without Folder", #selector(newGroupWithoutFolder(_:))),
                      item("New Group from Selection", #selector(newGroupFromSelection(_:))),
                      item("New Group from Selection without Folder", #selector(newGroupFromSelectionWithoutFolder(_:)))]
        }
        items += [item("New Folder", #selector(newFolder(_:))), item("New Folder from Selection", #selector(newFolderFromSelection(_:))),
                  .separator()]
        if !inFolder { items += [item("Sort by Name", #selector(sortByName(_:))), item("Sort by Type", #selector(sortByType(_:))), .separator()] }
        items.append(item(MenuTitles.title(generic: "Find in Selected Groups…", in: menuContext), #selector(findInSelectedGroups(_:))))
        for i in items where !i.isSeparatorItem { i.isEnabled = validateMenuItem(i) }
        return items
    }
}
