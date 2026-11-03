import AppKit
import YcodeIDECore

/// Commands that would do nothing in the window's present state show
/// disabled instead (a tester's rule: no menu item is a silent no-op).
extension WorkspaceWindowController {
    /// Whether the language service can answer for the focused editor.
    var canAskLanguageService: Bool { hasSourceFile && session.language != nil }

    /// Enablement of the commands whose actions need a state; nil = not one
    /// of them.
    func validateAvailability(_ item: NSMenuItem) -> Bool? {
        switch item.action {
        case #selector(stepOverInstruction(_:)), #selector(stepIntoInstruction(_:)):
            return session.stoppedThread != nil
        case #selector(detachDebugger(_:)):
            return session.debugClient != nil
        case #selector(jumpToProgramCounter(_:)):
            return session.currentLocation != nil
        case #selector(jumpToDefinition(_:) as (Any?) -> Void), #selector(jumpToOriginalSource(_:)), #selector(findSelectedSymbol(_:)),
             #selector(showCallHierarchy(_:)), #selector(renameSymbol(_:)), #selector(showCodeActions(_:)):
            return canAskLanguageService
        case #selector(fixAllIssues(_:)):
            guard let path = editor.fileURL?.standardizedFileURL.path else { return false }
            return session.displayedIssues.contains { issue in
                !issue.fixIts.isEmpty && issue.location.map { URL(fileURLWithPath: $0.file).standardizedFileURL.path } == path
            }
        case #selector(jumpToNextBookmark(_:)), #selector(jumpToPreviousBookmark(_:)),
             #selector(jumpToNextBookmarkInWorkspace(_:)), #selector(jumpToPreviousBookmarkInWorkspace(_:)):
            return !bookmarks.all.isEmpty
        case #selector(bookmarkLine(_:)), #selector(bookmarkLineWithDialog(_:)), #selector(bookmarkFile(_:)), #selector(bookmarkFileWithDialog(_:)),
             #selector(jumpToLine(_:)):
            return hasSourceFile
        case #selector(hideFindBar(_:)):
            return editor.isShowingFindBar
        case #selector(duplicateEditorTab(_:)), #selector(openWithExternalEditor(_:)):
            return editor.fileURL != nil
        case #selector(archiveProduct(_:)):
            return session.model.kind != .package && session.scheme != nil && !session.isBusy
        case #selector(toggleComparison(_:)):
            item.state = editor.isShowingComparison || editor.isShowingInlineComparison ? .on : .off
            return item.state == .on || (editor.fileURL != nil && sourceControl.snapshot.repository != nil)
        case #selector(openInNewTab(_:)):
            return navigator.selectedPath != nil || editor.fileURL != nil
        default:
            return nil
        }
    }
}
