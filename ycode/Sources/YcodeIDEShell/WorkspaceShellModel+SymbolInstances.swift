import Foundation
import YcodeIDECore

/// Editing ▸ Display ▸ Highlight instances of selected symbol in the Linux
/// IDE, as the macOS editor does it (`SymbolInstances`; council row 227;
/// `source-editor.md` §Evidence): after the highlighting delay (0.25 s by
/// default) with the insertion point in an identifier in code, every
/// instance of it in code is highlighted; a word in a comment or a string
/// highlights nothing. Skipped while the find bar is shown, and for a
/// selection.
extension WorkspaceShellModel {
    func scheduleSymbolInstances() {
        let f = languageFeatures
        f.symbolInstancesTask?.cancel()
        if !f.symbolInstances.isEmpty { f.symbolInstances = [] }
        let p = Preferences.shared
        guard p.highlightSelectedSymbol, !findBar.isShown, let d = editor, d.buffer.selection.isEmpty else { return }
        let language = SourceTokenizer.Language(fileName: (d.path as NSString).lastPathComponent)
        guard language.isCode else { return }
        let path = d.path, revision = d.buffer.textRevision, caret = d.buffer.caret
        let delay = p.highlightDelay
        f.symbolInstancesTask = Task { [weak self] in
            if delay > 0 { try? await Task.sleep(nanoseconds: UInt64(delay * 1e9)) }
            guard !Task.isCancelled, let self, let d = self.editor, d.path == path, d.buffer.textRevision == revision,
                  d.buffer.selection.isEmpty, d.buffer.caret == caret else { return }
            self.languageFeatures.symbolInstances = SymbolInstances.ranges(in: d.buffer.text, caret: caret, language: language)
        }
    }

    /// Waits for the pending highlight (tests).
    public func symbolInstancesSettled() async { await languageFeatures.symbolInstancesTask?.value }
}
