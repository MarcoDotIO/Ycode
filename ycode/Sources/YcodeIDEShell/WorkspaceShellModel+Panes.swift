import Foundation
import Observation
import YcodeEditorKit
import YcodeIDECore
import YcodeSyntax

/// One editor pane of the Linux IDE: the file it shows (nil: none).
public struct ShellEditorPane: Identifiable, Equatable, Sendable {
    public let id: Int
    public var path: String?
}

/// The editor panes of the workspace window, as the macOS IDE's editor
/// area has them (`specs/ide/editor-area.md` E.2; `cross-platform-parity.md`
/// §4): one pane at first; View ▸ Editor ▸ Editor Pane On Right or Below
/// (and the toolbar's Add Editor) adds one after the focused pane, which
/// takes focus; each pane has its own jump bar and close button; the
/// focused pane is the one the window's commands act on. The model's
/// `document` and `editor` are always the focused pane's.
@MainActor
@Observable
public final class ShellEditorPanes {
    public internal(set) var panes: [ShellEditorPane] = [ShellEditorPane(id: 0, path: nil)]
    /// The focused pane's index in `panes`.
    public internal(set) var focused = 0
    /// Side by side (true) or one below the other; set by the first split.
    public internal(set) var sideBySide = true
    @ObservationIgnored var nextID = 1

    public init() {}

    public var isSplit: Bool { panes.count > 1 }
    public var focusedPane: ShellEditorPane { panes[min(focused, panes.count - 1)] }
    public func isFocused(_ pane: ShellEditorPane) -> Bool { focusedPane.id == pane.id }
}

extension WorkspaceShellModel {
    /// The focused pane shows `path` (or nothing): called whenever the
    /// model's document changes.
    func syncFocusedPane() {
        let p = panes
        let path = document?.path
        if p.panes[p.focused].path != path { p.panes[p.focused].path = path }
    }

    /// Adds a pane after the focused one (side by side or below; the first
    /// split decides for the window, as in the macOS IDE) and focuses it.
    /// It shows the focused file when Settings ▸ Navigation's new editor
    /// panes open with the same document, else nothing.
    public func splitEditor(sideBySide: Bool) {
        sourceControl.hidePane()
        testing.hideReport()
        let p = panes
        if p.panes.count == 1 { p.sideBySide = sideBySide }
        let path = Preferences.shared.newEditorPanesOpenWith == .sameDocument ? document?.path : nil
        let pane = ShellEditorPane(id: p.nextID, path: path)
        p.nextID += 1
        p.panes.insert(pane, at: p.focused + 1)
        p.focused += 1
        if path == nil { showNoFile() }
        editorFocusCount += 1
    }

    /// Focuses the pane with `id` (a click in it): the window's document
    /// becomes the pane's.
    public func focusPane(_ id: Int) {
        let p = panes
        guard let i = p.panes.firstIndex(where: { $0.id == id }), i != p.focused else { return }
        p.focused = i
        showFocusedPane()
    }

    /// Closes the pane with `id` (its jump bar's close button); the pane
    /// before it takes focus when it had it. The last pane stays.
    public func closePane(_ id: Int) {
        let p = panes
        guard p.panes.count > 1, let i = p.panes.firstIndex(where: { $0.id == id }) else { return }
        let wasFocused = i == p.focused
        p.panes.remove(at: i)
        if wasFocused {
            p.focused = max(0, i - 1)
        } else if i < p.focused {
            p.focused -= 1
        }
        if wasFocused { showFocusedPane() }
    }

    /// Shows the focused pane's file in the model (its document, editor,
    /// find bar and issues), or nothing.
    func showFocusedPane() {
        if let path = panes.focusedPane.path {
            if document?.path != path { showFile(path) }
        } else {
            showNoFile()
        }
        editorFocusCount += 1
    }

    /// The window shows no file (a new empty pane): the documents stay open.
    func showNoFile() {
        editor = nil
        document = nil
        structuredEditor = nil
        findBar.documentChanged(to: nil)
        syncEditorIssues()
        sourceControl.noteText(of: nil)
        syncFocusedPane()
    }

    /// Whether a pane other than the focused one shows `path`.
    func otherPaneShows(_ path: String) -> Bool {
        let p = panes
        return p.panes.enumerated().contains { $0.offset != p.focused && $0.element.path == path }
    }

    /// What a pane shows.
    public enum PaneContent {
        case none
        case text(EditorDocument)
        case image(String)
        case message(String)
    }

    /// The content of a pane that is not focused (the focused one shows the
    /// model's document): its open document, its image, or why it cannot
    /// be shown.
    public func content(of pane: ShellEditorPane) -> PaneContent {
        guard let path = pane.path else { return .none }
        if ShellImageFile.handles(path) { return .image(path) }
        if let d = openDocuments[path] { return .text(d) }
        if path == document?.path, let m = document?.message { return .message(m) }
        return .message((path as NSString).lastPathComponent)
    }

    /// The jump bar's components for `path` (as `jumpPath` for the focused file).
    public func jumpPath(for path: String?) -> [(title: String, symbol: String)] {
        guard let path else { return [] }
        return WorkspaceChrome.jumpPath(for: URL(fileURLWithPath: path), root: session.model.root, workspaceName: workspaceName,
                                        hideExtension: hidesFileExtensions).map { (title: $0.0, symbol: $0.1) }
    }

    // MARK: The image editor

    /// Shows `path` in the image editor when it is an image: the window's
    /// document has no text and no message (EditorArea draws the image).
    func showImage(_ path: String) -> Bool {
        guard ShellImageFile.handles(path) else { return false }
        editor = nil
        structuredEditor = nil
        document = SourceDocument(path: path, language: SyntaxLanguage(fileName: (path as NSString).lastPathComponent), lines: [])
        findBar.documentChanged(to: nil)
        syncEditorIssues()
        sourceControl.noteText(of: path)
        return true
    }

    /// The open image's path, when the focused pane shows an image.
    public var imagePath: String? {
        guard let d = document, editor == nil, d.message == nil, ShellImageFile.handles(d.path) else { return nil }
        return d.path
    }
}
