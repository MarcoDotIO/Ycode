import Foundation
import YcodeIDEShell

/// The Linux panes' part of restoring the workspace window on reopen
/// (`workspace-window.md` W7.1, council row 186): each pane's editor tells
/// the model its first visible line when the workspace is saved, and a
/// restored pane scrolls its saved first line to the top once it has been
/// measured and drawn, as the macOS IDE's panes do.
extension SourceEditorController {
    /// The first logical line whose row shows at the top (1-based): a row
    /// more than half scrolled past counts as gone.
    var firstVisibleLine: Int {
        guard measured, lineHeight > 0 else { return 1 }
        let y = max(0, top - Self.topInset)
        var row = Int((y / lineHeight).rounded(.down))
        if y - CGFloat(row) * lineHeight > lineHeight / 2 { row += 1 }
        guard row < visualRowCount else { return buffer.lineCount }
        return line(atRow: row) + 1
    }

    /// Scrolls so that `line` (1-based) starts at the top (line 1: the
    /// document's top).
    func scroll(toTopLine line: Int) {
        let n = min(max(1, line), max(1, buffer.lineCount))
        scroll(x: left, y: n <= 1 ? 0 : lineTop(n - 1))
    }
}

/// Restored panes waiting for their first measured frame.
@MainActor
enum PaneRestore {
    private static var pending: [ObjectIdentifier: Int] = [:]

    /// The pane's editor appeared: wires the model's question and takes
    /// the pane's saved first line, if any.
    static func paneAppeared(model: WorkspaceShellModel, pane: Int, controller c: SourceEditorController) {
        if model.restore.firstVisibleLine == nil {
            model.restore.firstVisibleLine = { pane, path in PaneControllers.existing(pane: pane, path: path)?.firstVisibleLine }
        }
        if let line = model.restore.takeTopLine(pane: pane, path: c.document.path) { pending[ObjectIdentifier(c)] = line }
    }

    /// Placed panes watched for `guardSeconds` (council round 8, row 202):
    /// one put back at its document's top meanwhile (a later layout or
    /// re-wrap) scrolls to its saved line again, as on macOS.
    private static var guarded: [ObjectIdentifier: (line: Int, until: Date)] = [:]
    static let guardSeconds: TimeInterval = 4

    /// Called after each frame of an editor: the saved line once it can be placed.
    static func frameDrawn(_ c: SourceEditorController) {
        let id = ObjectIdentifier(c)
        if let g = guarded[id] {
            if Date() >= g.until {
                guarded[id] = nil
            } else if c.measured, c.firstVisibleLine == 1 {
                DispatchQueue.main.async { c.scroll(toTopLine: g.line) }
            }
        }
        guard !pending.isEmpty, c.measured, let line = pending[id] else { return }
        pending[id] = nil
        if line > 1 { guarded[id] = (line, Date().addingTimeInterval(guardSeconds)) }
        DispatchQueue.main.async { c.scroll(toTopLine: line) }
    }
}
