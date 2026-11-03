import AppKit

import YcodeIDECore

/// Product ▸ Delete Derived Data…, Build Documentation, Export
/// Localizations…, Import Localizations… (`specs/ide/build.md` §IDE tool
/// actions): panels and confirmations here, the work in
/// `WorkspaceSession+Tools.swift`.
extension WorkspaceWindowController {
    // MARK: Localizations

    /// Export Localizations…: a save panel for the folder to create
    /// ("<project> Localizations"), then one `.xcloc` per language in it.
    @objc public func exportLocalizations(_ sender: Any?) {
        guard let window, window.isVisible, let project = IDEToolActions.localizationProject(session.model) else { NSSound.beep(); return }
        let panel = NSSavePanel()
        panel.title = "Export Localizations"
        panel.prompt = "Export"
        panel.nameFieldStringValue = IDEToolActions.exportFolderName(project: project)
        panel.directoryURL = project.deletingLastPathComponent()
        panel.canCreateDirectories = true
        panel.beginSheetModal(for: window) { [weak self] r in
            guard r == .OK, let url = panel.url else { return }
            Task { await self?.exportLocalizations(into: url) }
        }
    }

    /// Exports into `folder` (created if missing) and shows the folder.
    @discardableResult
    public func exportLocalizations(into folder: URL, runner: @escaping IDEToolActions.Runner = IDEToolActions.inProcess) async -> WorkspaceSession.ToolOutcome? {
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let outcome = await session.exportLocalizations(to: folder, runner: runner)
        if let outcome, window?.isVisible == true { presentToolOutcome(outcome, title: "Export Localizations", reveal: outcome.products.map(URL.init(fileURLWithPath:))) }
        return outcome
    }

    /// Import Localizations…: an open panel for a `.xcloc` (or `.xliff`),
    /// then the import into the project.
    @objc public func importLocalizations(_ sender: Any?) {
        guard let window, window.isVisible, IDEToolActions.localizationProject(session.model) != nil else { NSSound.beep(); return }
        let panel = NSOpenPanel()
        panel.title = "Import Localizations"
        panel.prompt = "Import"
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        panel.treatsFilePackagesAsDirectories = false
        panel.beginSheetModal(for: window) { [weak self] r in
            guard r == .OK, let url = panel.url else { return }
            Task { await self?.importLocalizations(from: url) }
        }
    }

    @discardableResult
    public func importLocalizations(from url: URL, runner: @escaping IDEToolActions.Runner = IDEToolActions.inProcess) async -> WorkspaceSession.ToolOutcome? {
        let outcome = await session.importLocalizations(from: url, runner: runner)
        if let outcome, window?.isVisible == true { presentToolOutcome(outcome, title: "Import Localizations", reveal: []) }
        return outcome
    }

    // MARK: Documentation

    /// Build Documentation (⌃⇧⌘D): `docbuild`, then the archives in Finder.
    @objc public func buildDocumentation(_ sender: Any?) { Task { await buildDocumentation() } }

    @discardableResult
    public func buildDocumentation(runner: @escaping IDEToolActions.Runner = IDEToolActions.inProcess) async -> WorkspaceSession.ToolOutcome? {
        let outcome = await session.buildDocumentation(runner: runner)
        if let outcome, window?.isVisible == true { presentToolOutcome(outcome, title: "Build Documentation", reveal: outcome.products.map(URL.init(fileURLWithPath:))) }
        return outcome
    }

    // MARK: Derived data

    /// Delete Derived Data…: asks, then deletes the workspace's derived data
    /// folder. Returns the alert (shown as a sheet while the window is on
    /// screen) once the folder is known.
    @objc public func deleteDerivedData(_ sender: Any?) { Task { await confirmDeleteDerivedData() } }

    @discardableResult
    public func confirmDeleteDerivedData() async -> NSAlert? {
        guard let build = await buildFolder() else { NSSound.beep(); return nil }
        let folder = IDEToolActions.derivedDataFolder(buildFolder: build)
        let alert = NSAlert()
        alert.messageText = "Delete the derived data of \u{201C}\(session.model.displayName)\u{201D}?"
        alert.informativeText = "\(folder.path) and everything in it is deleted: build products, intermediate files and indexes. The next build builds everything again."
        alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Cancel")
        if let window, window.isVisible {
            alert.beginSheetModal(for: window) { [weak self] r in
                guard r == .alertFirstButtonReturn else { return }
                self?.deleteDerivedData(at: folder)
            }
        }
        return alert
    }

    /// Deletes `folder` (the confirmed derived data) and says so in the console.
    @discardableResult
    public func deleteDerivedData(at folder: URL) -> Bool {
        let ok = IDEToolActions.deleteDerivedData(folder)
        if ok { session.appendConsole("Ycode: deleted the derived data at \(folder.path)\n", kind: .debugger) } else { NSSound.beep() }
        return ok
    }

    // MARK: Results

    /// A failed action shows its last lines in a sheet; a successful one
    /// reveals what it made in Finder.
    func presentToolOutcome(_ outcome: WorkspaceSession.ToolOutcome, title: String, reveal: [URL]) {
        guard let window else { return }
        if outcome.succeeded {
            if !reveal.isEmpty { NSWorkspace.shared.activateFileViewerSelecting(reveal) }
            return
        }
        let alert = NSAlert()
        alert.messageText = "\(title) failed"
        alert.informativeText = outcome.output.split(separator: "\n").suffix(8).joined(separator: "\n")
        alert.beginSheetModal(for: window)
    }

    /// Enablement of these commands; nil = not one of them.
    func validateToolActionItem(_ item: NSMenuItem) -> Bool? {
        switch item.action {
        case #selector(exportLocalizations(_:)), #selector(importLocalizations(_:)):
            return IDEToolActions.localizationProject(session.model) != nil && !session.isBusy
        case #selector(buildDocumentation(_:)): return session.scheme != nil && !session.isBusy
        case #selector(deleteDerivedData(_:)): return !session.isBusy
        default: return nil
        }
    }
}

extension WorkspaceWindowController {
    /// File ▸ Open… of an `.xcresult` with a workspace window in front
    /// (`specs/ide/testing.md` §Result bundles in the IDE): the bundle
    /// becomes a test report, shown on its Tests page.
    @discardableResult
    public func openResultBundle(_ bundle: URL) -> BuildReport? {
        do {
            let r = try session.openResultBundle(bundle)
            openReportPage(0, "Tests")
            return r
        } catch {
            session.appendConsole("Ycode: cannot read \(bundle.lastPathComponent): \(error)\n", kind: .debugger)
            if let window, window.isVisible {
                let alert = NSAlert()
                alert.messageText = "\u{201C}\(bundle.lastPathComponent)\u{201D} could not be read"
                alert.informativeText = "\(error)"
                alert.beginSheetModal(for: window)
            }
            return nil
        }
    }
}
