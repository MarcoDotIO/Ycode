import AppKit

/// Menu-bar commands and states of `specs/ide/reference-ui-6.md` §8
/// (R43): File ▸ New ▸ New File from Clipboard, the Group items hidden in
/// folders, Folder's enablement, Find ▸ Find in Selected File… / Groups…,
/// Edit ▸ Paste ▸ Paste and Preserve Formatting.
extension WorkspaceWindowController {
    /// Where the clipboard commands read text (tests use a private one).
    public static var menuPasteboard: NSPasteboard = .general

    static var pasteboardText: String? { menuPasteboard.string(forType: .string) }

    /// The project navigator's selected row: its location on disk and its
    /// kind. The project row stands for the project's folder.
    public var projectNavigatorSelection: (path: String, kind: NavigatorNode.Kind)? {
        guard navigator.selectedIndex == 0, let item = navigator.selectedItem, let path = item.nodePath ?? item.path else { return nil }
        let kind = item.nodeKind ?? .file
        if kind == .container { return (path.hasSuffix(".xcodeproj") ? (path as NSString).deletingLastPathComponent : path, .group) }
        return (path, kind)
    }

    /// The selection is a folder or inside one (a synchronized folder, a
    /// package directory): groups cannot go there.
    public var projectSelectionIsInFolder: Bool {
        guard let sel = projectNavigatorSelection else { return false }
        return sel.kind == .folder || navigator.selectedItemParent?.nodeKind == .folder
    }

    func fillMenuCleanUpContext(_ c: inout MenuContext) {
        c.pasteboardHasText = Self.pasteboardText != nil
        if let sel = projectNavigatorSelection {
            c.projectSelection = sel.kind == .file ? .file : .group
            c.projectSelectionInFolder = projectSelectionIsInFolder
        }
    }

    /// Enablement of this file's commands (and File ▸ New ▸ Folder); nil =
    /// not one of them.
    func validateMenuCleanUpItem(_ item: NSMenuItem) -> Bool? {
        switch item.action {
        case #selector(newFileFromClipboard(_:)): return Self.pasteboardText != nil
        // With no navigator selection the folder items are disabled (§8 item 6).
        case #selector(newFolder(_:)): return projectNavigatorSelection != nil
        case #selector(findInSelectedGroups(_:)): return projectNavigatorSelection != nil
        case #selector(pasteAndPreserveFormatting(_:)): return hasEditableSource && Self.pasteboardText != nil
        default: return nil
        }
    }

    /// File ▸ New ▸ New File from Clipboard: a new file next to the open
    /// one ("File", "File 2", … as Empty File) holding the pasteboard's
    /// text, opened in the editor.
    @discardableResult
    @objc public func newFileFromClipboard(_ sender: Any?) -> URL? {
        guard let text = Self.pasteboardText else { NSSound.beep(); return nil }
        let dir = newFileDirectory
        var name = "File", n = 1
        while FileManager.default.fileExists(atPath: dir.appendingPathComponent(name).path) { n += 1; name = "File \(n)" }
        guard let url = try? createFile(entry: TemplateEntry("Empty"), name: name, in: dir).first else { NSSound.beep(); return nil }
        do {
            try text.write(to: url, atomically: true, encoding: .utf8)
            if editor.fileURL?.standardizedFileURL == url.standardizedFileURL { try editor.open(url) } else { open(path: url.path, line: nil) }
        } catch {
            NSSound.beep()
        }
        return url
    }

    /// Find ▸ Find in Selected File… / Find in Selected Groups…: the Find
    /// navigator, scoped to the project navigator's selected file, group
    /// or folder.
    @objc public func findInSelectedGroups(_ sender: Any?) {
        guard let sel = projectNavigatorSelection else { NSSound.beep(); return }
        navigatorItem.isCollapsed = false
        navigator.select(3)
        navigator.setFindScope(.group(sel.path))
        window?.makeFirstResponder(navigator.findField)
    }

    /// Edit ▸ Paste ▸ Paste and Preserve Formatting (⌥⇧⌘V): the
    /// pasteboard's text exactly as it is. Ycode's Paste does not
    /// re-indent either; this one never will.
    @objc public func pasteAndPreserveFormatting(_ sender: Any?) {
        guard hasEditableSource, let text = Self.pasteboardText else { NSSound.beep(); return }
        let tv = editor.textView
        tv.insertText(text, replacementRange: tv.selectedRange())
    }
}
