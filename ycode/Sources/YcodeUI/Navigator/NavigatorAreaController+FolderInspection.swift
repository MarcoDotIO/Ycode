import AppKit
import YcodeIDECore

/// Selecting a folder or a group in the project navigator shows its own
/// File inspector (`specs/ide/parity-inventory.md` P-089: the reference's
/// Name, Location, Full Path… for the folder; Ycode kept the last file's).
extension NavigatorAreaController {
    /// The folder or group row selected alone (nil: a file, a project, none
    /// or several).
    var selectedProjectFolder: OutlineItem? {
        guard isViewLoaded, selectedIndex == 0, outline.selectedRowIndexes.count == 1,
              let item = outline.item(atRow: outline.selectedRow) as? OutlineItem, item.path == nil,
              let kind = item.nodeKind, kind != .file, item.nodePath != nil else { return nil }
        return item
    }

    /// The window's inspector shows the selected folder (its File inspector).
    func inspectSelectedProjectFolder() {
        guard !selectionFromOpen.value, let item = selectedProjectFolder, let path = item.nodePath,
              let wc = view.window?.windowController as? WorkspaceWindowController else { return }
        wc.inspector.show(file: URL(fileURLWithPath: path))
    }
}
