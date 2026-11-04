import AppKit
import YcodeIDECore

/// What the project navigator asks its window to do: the file operations of
/// `specs/ide/navigators.md` §Ycode implementation. The window controller
/// fills these in (WorkspaceWindowController+ProjectNavigatorOps.swift).
@MainActor
public struct ProjectNavigatorHooks {
    /// The context menu's items for the selected rows.
    public var rowMenu: (() -> [NSMenuItem])?
    /// Delete (⌘⌫ or ⌫ in the navigator).
    public var delete: (() -> Void)?
    /// An inline rename ended with a new name.
    public var rename: ((OutlineItem, String) -> Void)?
    /// Edit ▸ Cut in the navigator: marks the selection for Move Item Here.
    public var cut: (() -> Void)?
    /// Rows were dragged onto a group or folder (child index, nil: on it).
    public var move: (([OutlineItem], OutlineItem, Int?) -> Void)?
    /// Files were dropped from outside (the Finder).
    public var addFiles: (([URL], OutlineItem, Int?) -> Void)?
    public init() {}
}

/// The navigator's outline: Return renames the selected project row and
/// Delete deletes the selection (the menu's ⌘⌫ reaches `delete(_:)`).
final class NavigatorOutlineView: NSOutlineView {
    var onReturn: (() -> Bool)?
    var onDeleteKey: (() -> Bool)?
    /// After a reload: the first row may have appeared, and with it the
    /// padding the outline's insets are measured against.
    var onReload: (() -> Void)?

    override func reloadData() {
        super.reloadData()
        onReload?()
    }

    override func keyDown(with event: NSEvent) {
        let mods = event.modifierFlags.intersection([.command, .option, .control, .shift])
        switch event.keyCode {
        case 36, 76 where mods.isEmpty:
            if onReturn?() == true { return }
        case 51, 117 where mods.isEmpty:
            if onDeleteKey?() == true { return }
        default: break
        }
        super.keyDown(with: event)
    }
}

/// Ends an inline rename: Return commits, Escape cancels.
@MainActor
final class NavigatorRenameDelegate: NSObject, NSTextFieldDelegate {
    var item: OutlineItem?
    var original = ""
    var cancelled = false
    var onCommit: ((OutlineItem, String) -> Void)?
    var onEnd: (() -> Void)?

    func control(_ control: NSControl, textView: NSTextView, doCommandBy sel: Selector) -> Bool {
        guard sel == #selector(NSResponder.cancelOperation(_:)) else { return false }
        cancelled = true
        (control as? NSTextField)?.stringValue = original
        control.window?.makeFirstResponder(nil)
        return true
    }

    func controlTextDidEndEditing(_ obj: Notification) {
        guard let field = obj.object as? NSTextField, let item else { return }
        self.item = nil
        field.isEditable = false
        field.isSelectable = false
        field.delegate = nil
        let name = field.stringValue
        if cancelled || name == original || name.isEmpty {
            field.stringValue = item.title
        } else {
            onCommit?(item, name)
        }
        cancelled = false
        onEnd?()
    }
}

extension NavigatorAreaController {
    /// The pasteboard type of rows dragged inside the project navigator.
    static let projectRowType = NSPasteboard.PasteboardType("org.ycode.navigator.project-row")

    /// Multiple selection, drags and key handling for the Project navigator.
    func configureProjectOperations(_ index: Int) {
        projectOutline.allowsMultipleSelection = index == 0
        if index == 0 {
            projectOutline.registerForDraggedTypes([Self.projectRowType, .fileURL])
            projectOutline.setDraggingSourceOperationMask(.move, forLocal: true)
            projectOutline.setDraggingSourceOperationMask(.copy, forLocal: false)
        } else {
            projectOutline.unregisterDraggedTypes()
        }
        projectOutline.onReturn = { [weak self] in
            guard let self, self.selectedIndex == 0, self.projectOutline.selectedRowIndexes.count == 1, let item = self.selectedItem,
                  item.nodeKind != .container else { return false }
            self.beginRename(item)
            return true
        }
        projectOutline.onDeleteKey = { [weak self] in
            guard let self, self.selectedIndex == 0, !self.selectedProjectRows.isEmpty, let delete = self.projectOps.delete else { return false }
            delete()
            return true
        }
    }

    private var projectOutline: NavigatorOutlineView { navigatorOutline }

    /// The selected project rows, in row order (the clicked row when the
    /// context menu opens on a row outside the selection).
    public var selectedProjectRows: [OutlineItem] {
        guard isViewLoaded, selectedIndex == 0 else { return [] }
        return projectOutline.selectedRowIndexes.compactMap { projectOutline.item(atRow: $0) as? OutlineItem }
    }

    /// The row's group or folder row, if any.
    public func parentRow(of item: OutlineItem) -> OutlineItem? { projectOutline.parent(forItem: item) as? OutlineItem }

    /// The project (`.xcodeproj` path) a project row belongs to: its
    /// nearest container row that is a project.
    public func projectPath(of item: OutlineItem) -> String? {
        var cur: OutlineItem? = item
        while let c = cur {
            if c.nodeKind == .container, let p = c.nodePath, p.hasSuffix(".xcodeproj") { return p }
            cur = parentRow(of: c)
        }
        return nil
    }

    /// Edit ▸ Cut (⌘X) with the navigator focused: nothing moves until
    /// Edit ▸ Paste ▸ Move Item Here.
    @objc public func cut(_ sender: Any?) {
        guard selectedIndex == 0, !selectedProjectRows.isEmpty, let cut = projectOps.cut else { return NSSound.beep() }
        cut()
    }

    /// Edit ▸ Delete (⌘⌫) with the navigator focused.
    @objc public func delete(_ sender: Any?) {
        guard selectedIndex == 0, !selectedProjectRows.isEmpty, let delete = projectOps.delete else { return NSSound.beep() }
        delete()
    }

    /// Selects the project rows that `match` accepts, expanding their
    /// groups; returns them.
    @discardableResult
    public func selectProjectRows(_ match: (OutlineItem) -> Bool) -> [OutlineItem] {
        guard isViewLoaded, selectedIndex == 0 else { return [] }
        var found: [OutlineItem] = []
        func walk(_ items: [OutlineItem], _ ancestors: [OutlineItem]) {
            for i in items {
                if match(i) {
                    found.append(i)
                    for a in ancestors { projectOutline.expandItem(a) }
                }
                walk(i.children, ancestors + [i])
            }
        }
        walk(rows(0), [])
        let rows = IndexSet(found.map { projectOutline.row(forItem: $0) }.filter { $0 >= 0 })
        // The window's own selection (an opened file, an operation's
        // items) opens nothing by itself.
        selectionFromOpen.value = true
        defer { selectionFromOpen.value = false }
        projectOutline.selectRowIndexes(rows, byExtendingSelection: false)
        if let first = rows.first { projectOutline.scrollRowToVisible(first) }
        return found
    }

    /// Selects the row of the file just opened, expanding its folders,
    /// unless it is already among the selected rows (a multiple selection
    /// the click made stays).
    public func selectOpenFileRow(_ path: String) {
        guard isViewLoaded, selectedIndex == 0 else { return }
        let key = OpenRequestKey.path(URL(fileURLWithPath: path))
        func matches(_ i: OutlineItem) -> Bool { i.path.map { OpenRequestKey.path(URL(fileURLWithPath: $0)) == key } ?? false }
        if projectOutline.selectedRowIndexes.contains(where: { (projectOutline.item(atRow: $0) as? OutlineItem).map(matches) ?? false }) { return }
        var first = true
        selectProjectRows { i in
            guard first, matches(i) else { return false }
            first = false
            return true
        }
    }

    // MARK: Context menu

    func rebuildProjectRowMenu(_ menu: NSMenu) {
        // A right click outside the selection acts on the clicked row.
        let clicked = projectOutline.clickedRow
        if clicked >= 0, !projectOutline.selectedRowIndexes.contains(clicked) {
            projectOutline.selectRowIndexes([clicked], byExtendingSelection: false)
        }
        for item in projectOps.rowMenu?() ?? [] { menu.addItem(item) }
    }

    // MARK: Inline rename

    /// The name a rename starts from: the file's full name (extensions
    /// shown even when the navigator hides them).
    func editableName(_ item: OutlineItem) -> String {
        item.nodeKind == .file ? (item.nodePath.map { ($0 as NSString).lastPathComponent } ?? item.title) : item.title
    }

    /// Turns the row's name into a text field; Return renames it (`projectOps.rename`).
    public func beginRename(_ item: OutlineItem) {
        let row = projectOutline.row(forItem: item)
        guard row >= 0, let cell = projectOutline.view(atColumn: 0, row: row, makeIfNecessary: true) as? NSTableCellView,
              let field = cell.textField else { return }
        let name = editableName(item)
        renameDelegate.item = item
        renameDelegate.original = name
        renameDelegate.cancelled = false
        renameDelegate.onCommit = { [weak self] item, newName in self?.projectOps.rename?(item, newName) }
        renameDelegate.onEnd = { [weak self] in
            guard let self else { return }
            self.view.window?.makeFirstResponder(self.projectOutline)
        }
        field.stringValue = name
        field.isEditable = true
        field.isSelectable = true
        field.delegate = renameDelegate
        view.window?.makeFirstResponder(field)
        // Select the name without its extension, as the Finder does.
        let base = item.nodeKind == .file ? (name as NSString).deletingPathExtension : name
        field.currentEditor()?.selectedRange = NSRange(location: 0, length: (base.isEmpty ? name : base).utf16.count)
    }

    /// The row being renamed, if any (tests).
    public var renamingRow: OutlineItem? { renameDelegate.item }

    /// Ends an inline rename with `name` (tests; Return does it in the field).
    public func commitRename(_ name: String) {
        guard let item = renameDelegate.item else { return }
        let row = projectOutline.row(forItem: item)
        let field = (row >= 0 ? projectOutline.view(atColumn: 0, row: row, makeIfNecessary: false) as? NSTableCellView : nil)?.textField
        field?.stringValue = name
        if let field {
            renameDelegate.controlTextDidEndEditing(Notification(name: NSControl.textDidEndEditingNotification, object: field))
        } else {
            renameDelegate.item = nil
            projectOps.rename?(item, name)
        }
    }

    // MARK: Drag and drop

    public func outlineView(_ o: NSOutlineView, pasteboardWriterForItem item: Any) -> NSPasteboardWriting? {
        guard selectedIndex == 0, let item = item as? OutlineItem, item.nodeKind != .container, item.objectID != nil || item.nodePath != nil
        else { return nil }
        let p = NSPasteboardItem()
        p.setString(item.objectID ?? item.nodePath ?? "", forType: Self.projectRowType)
        return p
    }

    public func outlineView(_ o: NSOutlineView, draggingSession session: NSDraggingSession, willBeginAt screenPoint: NSPoint,
                            forItems draggedItems: [Any]) {
        draggedRows = draggedItems.compactMap { $0 as? OutlineItem }
    }

    public func outlineView(_ o: NSOutlineView, draggingSession session: NSDraggingSession, endedAt screenPoint: NSPoint,
                            operation: NSDragOperation) {
        draggedRows = []
    }

    /// Where a drop lands: a group, folder or project row, and the child
    /// index in it (nil: on the row). A drop on a file goes after it in its group.
    func dropTarget(_ item: Any?, _ index: Int) -> (OutlineItem, Int?)? {
        guard selectedIndex == 0, !projectFilterActive else { return nil }
        guard let row = item as? OutlineItem else { return nil }
        if row.nodeKind == .file {
            guard let parent = parentRow(of: row) else { return nil }
            return (parent, (parent.children.firstIndex { $0 === row } ?? parent.children.count - 1) + 1)
        }
        // A workspace row holds projects, not files.
        if row.nodeKind == .container, row.nodePath?.hasSuffix(".xcworkspace") == true { return nil }
        return (row, index == NSOutlineViewDropOnItemIndex ? nil : index)
    }

    public func outlineView(_ o: NSOutlineView, validateDrop info: NSDraggingInfo, proposedItem item: Any?,
                            proposedChildIndex index: Int) -> NSDragOperation {
        guard let (dest, _) = dropTarget(item, index) else { return [] }
        if info.draggingPasteboard.types?.contains(Self.projectRowType) == true {
            // Not into itself or below itself.
            var cur: OutlineItem? = dest
            while let c = cur {
                if draggedRows.contains(where: { $0 === c }) { return [] }
                cur = parentRow(of: c)
            }
            return .move
        }
        return info.draggingPasteboard.canReadObject(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) ? .copy : []
    }

    public func outlineView(_ o: NSOutlineView, acceptDrop info: NSDraggingInfo, item: Any?, childIndex index: Int) -> Bool {
        guard let (dest, i) = dropTarget(item, index) else { return false }
        if info.draggingPasteboard.types?.contains(Self.projectRowType) == true {
            guard !draggedRows.isEmpty, let move = projectOps.move else { return false }
            move(draggedRows, dest, i)
            return true
        }
        let urls = info.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        guard !urls.isEmpty, let add = projectOps.addFiles else { return false }
        add(urls, dest, i)
        return true
    }
}

/// A flag an extension can set (stored in the controller).
@MainActor final class FlagBox { var value = false }
