import AppKit
import YcodeIDECore

/// File menu commands of beta 5 (B5-MENUS2, P-001): Save As…, Export…,
/// Open in New Window and Save As Workspace…, enabled where the reference
/// enables them (council round 11). What is written is
/// `FileMenuCommands`' (shared with the Linux IDE).
extension WorkspaceWindowController {
    /// Where the save panels' answers go (tests replace it; nil shows the
    /// panel as a sheet on the window).
    nonisolated(unsafe) static var chooseSaveURL: (@MainActor (_ name: String, _ folder: URL) -> URL?)?

    /// File ▸ Save As… (⌥⇧⌘S, the ⌥ alternate of Duplicate…): the focused
    /// document written to a new place, with its unsaved edits; the editor
    /// then shows the new file and the original stays as it was saved.
    @objc public func saveFileAs(_ sender: Any?) { saveFocusedDocument(switching: true) }

    /// File ▸ Export…: a copy of the focused document; the editor keeps
    /// the original (and its unsaved edits).
    @objc public func exportFile(_ sender: Any?) { saveFocusedDocument(switching: false) }

    func saveFocusedDocument(switching: Bool) {
        guard let url = editor.fileURL else { saveWorkspaceDocument(switching: switching); return }
        chooseDestination(name: url.lastPathComponent, folder: url.deletingLastPathComponent()) { [weak self] dest in
            self?.writeFocusedDocument(to: dest, switching: switching)
        }
    }

    /// Save As… / Export… with no file focused: the project or workspace
    /// bundle itself; Save As… then opens the copy.
    func saveWorkspaceDocument(switching: Bool) {
        guard let doc = FileMenuCommands.containerDocument(session.model.url, kind: session.model.kind) else { NSSound.beep(); return }
        chooseDestination(name: doc.lastPathComponent, folder: doc.deletingLastPathComponent()) { [weak self] dest in
            do {
                try FileMenuCommands.write(text: nil, of: doc, to: dest)
                guard switching, !Self.isTestProcess else { return }
                NSDocumentController.shared.openDocument(withContentsOf: dest, display: true) { _, _, error in
                    if let error { NSApp.presentError(error) }
                }
            } catch {
                self?.presentError(error)
            }
        }
    }

    func writeFocusedDocument(to dest: URL, switching: Bool) {
        guard let url = editor.fileURL else { return }
        do {
            try FileMenuCommands.write(text: hasSourceFile ? editor.textView.string : nil, of: url, to: dest)
            guard switching else { return }
            // The edits went to the new file: the original is not saved.
            editor.isDirty = false
            open(path: dest.path, line: nil)
        } catch {
            presentError(error)
        }
    }

    /// File ▸ Open in New Window: the navigator's selected file (or the
    /// focused one) in a new window on this workspace.
    @objc public func openInNewWindow(_ sender: Any?) {
        guard let path = navigator.selectedPath ?? editor.fileURL?.path else { NSSound.beep(); return }
        let wc = newWorkspaceWindow(sender)
        wc.open(path: path, line: nil)
    }

    /// File ▸ Save As Workspace…: a workspace holding this project (or
    /// package), opened in its own window.
    @objc public func saveAsWorkspace(_ sender: Any?) {
        let container = session.model.url
        let name = container.lastPathComponent == "Package.swift" ? container.deletingLastPathComponent().lastPathComponent
            : container.deletingPathExtension().lastPathComponent
        let folder = container.lastPathComponent == "Package.swift" || container.pathExtension == "xcodeproj"
            ? container.deletingLastPathComponent() : container
        chooseDestination(name: name + ".xcworkspace", folder: folder) { [weak self] dest in
            guard let self else { return }
            do {
                let ws = try FileMenuCommands.saveAsWorkspace(container: container, to: dest)
                guard !Self.isTestProcess else { return }
                NSDocumentController.shared.openDocument(withContentsOf: ws, display: true) { _, _, error in
                    if let error { NSApp.presentError(error) }
                }
            } catch {
                self.presentError(error)
            }
        }
    }

    /// Asks where to save (a save panel as a sheet), then calls `done`.
    func chooseDestination(name: String, folder: URL, done: @escaping @MainActor (URL) -> Void) {
        if let choose = Self.chooseSaveURL {
            if let u = choose(name, folder) { done(u) }
            return
        }
        guard let window else { return }
        let panel = NSSavePanel()
        panel.directoryURL = folder
        panel.nameFieldStringValue = name
        panel.canCreateDirectories = true
        panel.beginSheetModal(for: window) { r in
            guard r == .OK, let u = panel.url else { return }
            MainActor.assumeIsolated { done(u) }
        }
    }

    /// Enablement of these commands; nil = not one of them.
    func validateFileCommand(_ item: NSMenuItem) -> Bool? {
        guard let a = item.action.map(NSStringFromSelector) else { return nil }
        if a == "openInNewWindow:" { return navigator.selectedPath != nil || editor.fileURL != nil }
        return FileMenuCommands.isEnabled(a, hasDocument: editor.fileURL != nil, containerKind: session.model.kind)
    }
}
