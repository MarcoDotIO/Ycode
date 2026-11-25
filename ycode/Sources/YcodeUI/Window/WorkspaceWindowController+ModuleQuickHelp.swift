import AppKit
import YcodeIDECore
import YcodeLanguage

/// Quick Help for a module named in an `import` (P-083, `specs/ide/popovers.md`
/// §4.1): ⌥-click on `Foundation` in `import Foundation` shows the module's
/// Quick Help (its abstract and Overview from the module's DocC catalog in
/// the workspace, else its title and the documentation link), never
/// nothing.
extension WorkspaceWindowController {
    /// The module document for position `p` of the editor's file, when `p`
    /// is on an import's module name.
    public func moduleQuickHelp(at p: Position) -> QuickHelpDocument? {
        let text = editor.text
        let offset = ModuleQuickHelp.offset(in: text, line: p.line, character: p.character)
        guard let name = ModuleQuickHelp.moduleName(in: text, at: offset) else { return nil }
        return ModuleQuickHelp.document(module: name, roots: [ModuleQuickHelp.searchRoot(container: session.model.url)])
    }

    /// Shows a module's Quick Help above the word at `anchor` (on screen
    /// only). Returns the document.
    @discardableResult
    func showModuleQuickHelp(_ doc: QuickHelpDocument, anchor: NSRect) -> NSViewController? {
        guard window?.isVisible == true else { return nil }
        return QuickHelpPopover.show(doc, at: anchor, in: editor.textView)
    }
}
