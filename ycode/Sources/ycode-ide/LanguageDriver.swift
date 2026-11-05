import Foundation
import SwiftUI
import YcodeIDECore
import YcodeIDEShell
import YcodeLanguage
#if os(Linux)
import OVPlatform
#endif

// YCODE_IDE_LSP=<prefix>: drives the language features and the Symbol
// navigator with synthetic input in a package opened by the app (a file
// with a documented function called from another file), printing the
// state after each step and writing <prefix>-<step>.png:
//
//   file, quickhelp-popover (⌥-click), quickhelp-inspector (⌥⌘3),
//   jump-definition (Ctrl-click), document-items (the jump bar's
//   symbol), references, callers, menu-navigate, menu-refactor,
//   rename-sheet, rename-preview, rename-applied, symbols (⌘3),
//   symbols-opened, symbols-filtered
//
// YCODE_IDE_LSP_FILE names the file to start in (default main.swift) and
// YCODE_IDE_LSP_SYMBOL the symbol to work on there (default greet);
// YCODE_IDE_LSP_NEW_NAME the rename's new name (default welcome).

#if os(Linux)
@MainActor
enum LanguageDriver {
    static let env = ProcessInfo.processInfo.environment

    static func say(_ s: String) { ShellDriver.say(s) }
    static func pause(_ s: Double) async { await ShellDriver.pause(s) }

    static func run(_ app: ShellAppModel, prefix: String) async {
        guard let w = app.workspace else {
            say("lsp: no workspace")
            return
        }
        func shot(_ step: String) async {
            await pause(0.6)
            say("lsp \(step): \(ShellDriver.state(app)) \(details(w)) " + OpenViewsAutomation.screenshot(to: "\(prefix)-\(step).png"))
        }
        let fileName = env["YCODE_IDE_LSP_FILE"] ?? "main.swift"
        let symbol = env["YCODE_IDE_LSP_SYMBOL"] ?? "greet"
        let newName = env["YCODE_IDE_LSP_NEW_NAME"] ?? "welcome"
        guard let file = w.root.allFiles.first(where: { $0.name == fileName }), let path = file.path else {
            say("lsp: no file \(fileName)")
            return
        }
        // The server, then its first answer (sourcekit-lsp loads the package first).
        for _ in 0..<240 where w.session.language == nil { await pause(0.25) }
        say("lsp: server \(w.session.language == nil ? "missing" : "started")")
        w.open(path)
        await pause(0.5)
        guard let start = offset(of: symbol, in: w) else {
            say("lsp: no \(symbol) in \(fileName)")
            return
        }
        let url = URL(fileURLWithPath: path)
        let began = Date()
        var ready = false
        for _ in 0..<120 {
            if let d = w.editor { w.session.language?.change(url, text: d.buffer.text) }
            if await w.session.hover(url, at: position(start, in: w)) != nil { ready = true; break }
            await pause(1)
        }
        say("lsp: server answered=\(ready) after \(Int(Date().timeIntervalSince(began))) s")
        await shot("file")

        // ⌥-click on the symbol: Quick Help in a popover.
        await clickSymbol(at: start + 1, in: w, modifiers: [.option])
        for _ in 0..<40 where w.languageFeatures.popover == nil { await pause(0.25) }
        await shot("quickhelp-popover")
        // The declaration's menu copies it (the macOS IDE's selectable text).
        if let f = ShellDriver.frame("quickhelp declaration") {
            OpenViewsAutomation.press(.escape)
            await pause(0.2)
            await clickSymbol(at: start + 1, in: w, modifiers: [.option])
            for _ in 0..<40 where w.languageFeatures.popover == nil { await pause(0.25) }
            await OpenViewsAutomation.click(at: CGPoint(x: f.midX, y: f.midY), button: 3)
            await pause(0.5)
            await shot("quickhelp-copy-menu")
            await ShellDriver.clickText("Copy", inPopup: true)
            say("lsp: copied declaration=\"\(ShellPasteboard.lastCopied ?? "")\" clipboard=\"\(ShellClipboard.string ?? "")\"")
        }
        if w.languageFeatures.popover != nil { OpenViewsAutomation.press(.escape) }
        await pause(0.4)
        say("lsp: popover after Escape=\(w.languageFeatures.popover != nil)")

        // ⌥⌘3: the Quick Help inspector follows the insertion point.
        w.perform(.showQuickHelpInspector)
        await w.quickHelpInspectorSettled()
        await shot("quickhelp-inspector")

        // Ctrl-click: Jump to Definition.
        await clickSymbol(at: start + 1, in: w, modifiers: [.control])
        for _ in 0..<40 where w.document?.name == fileName { await pause(0.25) }
        await pause(0.4)
        await shot("jump-definition")
        // The jump bar's symbol: the file's declarations.
        await ShellDriver.click("jump bar symbol")
        await shot("document-items")
        OpenViewsAutomation.press(.escape)
        await pause(0.3)
        w.perform(.goBack)
        await pause(0.5)

        // The menus with the new commands enabled.
        await ShellDriver.clickText("Navigate", inPopup: false)
        await shot("menu-navigate")
        OpenViewsAutomation.press(.escape)
        await pause(0.3)
        await ShellDriver.clickText("Editor", inPopup: false)
        if let r = OpenViewsAutomation.texts().first(where: { $0.inPopup && $0.text == "Refactor" }) {
            OpenViewsAutomation.move(to: CGPoint(x: r.frame.midX, y: r.frame.midY))
            await pause(0.3)
            await OpenViewsAutomation.click(at: CGPoint(x: r.frame.midX, y: r.frame.midY))
            await pause(0.5)
        }
        await shot("menu-refactor")
        OpenViewsAutomation.press(.escape)
        await pause(0.2)
        OpenViewsAutomation.press(.escape)
        await pause(0.4)

        // References and callers in the Find navigator.
        w.open(path)
        if let o = offset(of: symbol, in: w) { w.editor?.buffer.setCaret(o + 1) }
        w.perform(.findSelectedSymbol)
        for _ in 0..<80 where w.findResultsTitle == nil { await pause(0.25) }
        await shot("references")
        w.perform(.showCallHierarchy)
        for _ in 0..<80 where !(w.findResultsTitle ?? "").hasPrefix("Callers") { await pause(0.25) }
        await shot("callers")

        // Rename across files: the sheet, the preview, applied.
        w.open(path)
        if let o = offset(of: symbol, in: w) { w.editor?.buffer.setCaret(o + 1) }
        w.perform(.renameSymbol)
        for _ in 0..<40 where w.languageFeatures.rename == nil { await pause(0.25) }
        await shot("rename-sheet")
        if w.languageFeatures.rename != nil {
            if let field = ShellDriver.frame("rename field") {
                await OpenViewsAutomation.click(at: CGPoint(x: field.midX, y: field.midY))
                await pause(0.2)
            }
            OpenViewsAutomation.press(.character("a"), modifiers: [.control])
            await pause(0.1)
            OpenViewsAutomation.type(newName)
            await pause(0.3)
            OpenViewsAutomation.press(.return)
            for _ in 0..<40 where w.languageFeatures.renamePreview == nil && w.languageFeatures.rename != nil { await pause(0.25) }
            await shot("rename-preview")
            if w.languageFeatures.renamePreview != nil {
                await ShellDriver.click("rename go")
                for _ in 0..<20 where w.languageFeatures.rename != nil { await pause(0.25) }
            }
        }
        await shot("rename-applied")
        let renamed = w.root.allFiles.compactMap(\.path).filter { ($0 as NSString).pathExtension == "swift" }
            .map { p in "\((p as NSString).lastPathComponent)=\((w.currentText(of: p)?.components(separatedBy: newName + "(").count ?? 1) - 1)" }
        say("lsp: occurrences of \(newName)( after rename: \(renamed.joined(separator: " ")) edited=\(w.editedPaths.count)")
        _ = w.saveAll()

        // The Symbol navigator (⌘3): the files' declarations, then filtered.
        await ShellDriver.click("selector 2")
        for _ in 0..<40 where w.symbols.rows.isEmpty { await pause(0.25) }
        await shot("symbols")
        if let row = w.symbols.rows.first(where: { $0.title == "greetAll" }) {
            await ShellDriver.click("symbol row \(row.title)")
        }
        await shot("symbols-opened")
        if let field = ShellDriver.frame("symbol filter") {
            await OpenViewsAutomation.click(at: CGPoint(x: field.midX, y: field.midY))
            await pause(0.2)
            OpenViewsAutomation.type("gre")
            await pause(0.3)
        }
        await w.symbols.serverQuerySettled()
        await shot("symbols-filtered")
        say("lsp: symbols \(w.symbols.rows.map { String(repeating: " ", count: $0.level) + $0.title }.joined(separator: " | "))")
    }

    /// The model's language state, for the log.
    static func details(_ w: WorkspaceShellModel) -> String {
        let f = w.languageFeatures
        return "lsp[popover=\(f.popover?.document.title ?? "none") inspector=\(f.inspectorHelp?.title ?? "none") tab=\(f.inspectorTab) "
            + "rename=\(f.rename?.oldName ?? "none") preview=\(f.renamePreview?.summary ?? "none") highlights=\(f.highlights.count) "
            + "results=\"\(w.findResultsTitle ?? "")\" notice=\"\(f.notice ?? "")\" symbol=\(f.caretSymbol?.name ?? "none") "
            + "symbolRows=\(w.symbols.rows.count) filter=\"\(w.symbols.filterText)\"]"
    }

    /// The first whole-word occurrence of `name` in the open file.
    static func offset(of name: String, in w: WorkspaceShellModel) -> Int? {
        guard let text = w.editor?.buffer.text else { return nil }
        let ns = text as NSString
        var r = ns.range(of: name)
        while r.location != NSNotFound {
            let before = r.location > 0 ? ns.character(at: r.location - 1) : 32
            let after = NSMaxRange(r) < ns.length ? ns.character(at: NSMaxRange(r)) : 32
            func ident(_ u: unichar) -> Bool { (u >= 48 && u <= 57) || (u >= 65 && u <= 90) || (u >= 97 && u <= 122) || u == 95 }
            if !ident(before), !ident(after) { return r.location }
            r = ns.range(of: name, range: NSRange(location: NSMaxRange(r), length: ns.length - NSMaxRange(r)))
        }
        return nil
    }

    static func position(_ offset: Int, in w: WorkspaceShellModel) -> Position {
        guard let b = w.editor?.buffer else { return Position(line: 0, character: 0) }
        let n = b.document.line(containing: offset)
        return Position(line: n, character: offset - b.document.lineStart(n))
    }

    /// Clicks the character at `offset` of the open file with `modifiers` held.
    static func clickSymbol(at offset: Int, in w: WorkspaceShellModel, modifiers: KeyModifiers) async {
        guard let editor = w.editor, let source = ShellDriver.frame("source") else {
            say("lsp: no editor to click")
            return
        }
        let c = SourceEditorController.of(editor)
        let a = c.symbolAnchor(offset)
        let p = CGPoint(x: source.minX + a.x + 3, y: source.minY + a.y + c.lineHeight / 2)
        await OpenViewsAutomation.click(at: p, modifiers: modifiers)
        await pause(0.3)
    }
}
#endif
