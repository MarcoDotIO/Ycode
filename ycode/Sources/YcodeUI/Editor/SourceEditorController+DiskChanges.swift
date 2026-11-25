import AppKit
import YcodeIDECore

/// An unedited file follows the disk (P-068, `specs/ide/parity-inventory.md`):
/// when the file shown in an editor is replaced or rewritten on disk and
/// the editor has no unsaved changes, the editor shows the new text at once
/// (within a second), keeping the insertion point and the first visible
/// line, so builds and inline issues refer to the text on screen. An
/// edited editor keeps its text. The Linux IDE does the same
/// (`WorkspaceShellModel.checkOpenFilesOnDisk`).
extension SourceEditorController {
    /// What was last seen of the shown file on disk.
    struct DiskStamp: Equatable {
        var path: String
        var modified: Date?
        var size: Int?
    }

    /// The stamps of the editors, by editor (an extension cannot add
    /// stored properties).
    @MainActor static var diskStamps: [ObjectIdentifier: DiskStamp] = [:]

    static func stamp(of url: URL) -> DiskStamp {
        let a = try? FileManager.default.attributesOfItem(atPath: url.path)
        return DiskStamp(path: url.standardizedFileURL.path, modified: a?[.modificationDate] as? Date, size: (a?[.size] as? NSNumber)?.intValue)
    }

    /// Looks at the shown file on disk; reloads it when it changed and the
    /// editor has nothing unsaved. True when the text was replaced.
    @discardableResult
    public func followDiskIfUnedited() -> Bool {
        let key = ObjectIdentifier(self)
        guard isViewLoaded, let url = fileURL, auxiliary == nil else {
            Self.diskStamps[key] = nil
            return false
        }
        let now = Self.stamp(of: url)
        let before = Self.diskStamps[key]
        Self.diskStamps[key] = now
        // Same file, same date and size: nothing to read.
        if let before, before == now { return false }
        guard !isDirty, now.modified != nil, let disk = try? String(contentsOf: url, encoding: .utf8), disk != textView.string else { return false }
        return reloadFromDisk(disk)
    }

    /// Replaces the text with the disk's, the caret and the first visible
    /// line kept; the editor stays unedited and the file's undo history is
    /// cleared (`source-editor.md`, "Text undo belongs to the file").
    func reloadFromDisk(_ disk: String) -> Bool {
        let top = firstVisibleLine
        let caret = textView.selectedRange()
        guard replaceText(with: disk, actionName: "Reload") else { return false }
        if let url = fileURL { textUndo.clear(url) }
        let len = (textView.string as NSString).length
        textView.setSelectedRange(NSRange(location: min(caret.location, len), length: 0))
        scroll(toTopLine: top)
        isDirty = false
        return true
    }
}
