import Foundation
import Observation
import YcodeIDECore

/// File ▸ Save As…, Export… and Save As Workspace… on Linux (beta 5,
/// B5-MENUS2, P-001), as the macOS IDE performs them
/// (`WorkspaceWindowController+FileCommands.swift`; what is written is
/// `FileMenuCommands`'). Choosing one asks the view layer for a save dialog
/// (`request`); its answer comes back through `ShellAppModel.completeSave`.
/// The commands stay disabled until a view shows those dialogs
/// (`dialogsInstalled`), so none is a silent no-op.
@MainActor
@Observable
public final class ShellFileCommands {
    public static let shared = ShellFileCommands()

    public enum Kind: Sendable, Equatable { case saveAs, export, workspace }

    /// A save dialog the view layer should show.
    public struct Request: Equatable, Sendable {
        public var kind: Kind
        /// The name the dialog proposes.
        public var defaultName: String
    }

    public var request: Request?
    /// A view shows the save dialogs (`ShellSaveDialogs`).
    public var dialogsInstalled = false

    public init() {}

    /// The table actions of the commands.
    public static let actions: [String: Kind] = ["saveFileAs:": .saveAs, "exportFile:": .export, "saveAsWorkspace:": .workspace]
}

extension ShellAppModel {
    /// Enablement of the File commands of `ShellFileCommands` (nil: not
    /// one of them). Open in New Window stays disabled: the Linux IDE has
    /// one workspace window (L-225).
    public func fileCommandState(_ action: String) -> Bool? {
        let ours = action == "openInNewWindow:" || ShellFileCommands.actions[action] != nil
        guard ours else { return nil }
        guard let w = workspace, action != "openInNewWindow:" else { return false }
        guard ShellFileCommands.actions[action] != nil,
              let enabled = FileMenuCommands.isEnabled(action, hasDocument: w.document != nil, containerKind: w.session.model.kind) else { return nil }
        return enabled && ShellFileCommands.shared.dialogsInstalled
    }

    /// Asks for the save dialog of a File command.
    public func requestSave(_ action: String) {
        guard let kind = ShellFileCommands.actions[action], fileCommandState(action) == true, let w = workspace else { return }
        let name: String
        switch kind {
        case .saveAs, .export:
            name = (w.document?.path).map { URL(fileURLWithPath: $0).lastPathComponent } ?? w.session.model.url.lastPathComponent
        case .workspace: name = Self.workspaceName(w.session.model.url) + ".xcworkspace"
        }
        ShellFileCommands.shared.request = .init(kind: kind, defaultName: name)
    }

    static func workspaceName(_ container: URL) -> String {
        container.lastPathComponent == "Package.swift" ? container.deletingLastPathComponent().lastPathComponent
            : container.deletingPathExtension().lastPathComponent
    }

    /// The dialog's answer: writes what the request asked for at `url`.
    /// Save As… then edits the new file (the original keeps what was
    /// saved); Save As Workspace… opens the new workspace.
    public func completeSave(_ request: ShellFileCommands.Request, to url: URL) throws {
        ShellFileCommands.shared.request = nil
        guard let w = workspace else { return }
        switch request.kind {
        case .saveAs, .export:
            guard let path = w.document?.path else {
                // With no file open: the project or workspace bundle itself.
                guard let doc = FileMenuCommands.containerDocument(w.session.model.url, kind: w.session.model.kind) else { return }
                try FileMenuCommands.write(text: nil, of: doc, to: url)
                if request.kind == .saveAs { _ = open(path: url.path) }
                return
            }
            let source = URL(fileURLWithPath: path)
            try FileMenuCommands.write(text: w.editor?.buffer.text, of: source, to: url)
            guard request.kind == .saveAs else { return }
            if w.editor?.isDirty == true { w.revertToSaved() }
            w.open(url.path)
        case .workspace:
            let ws = try FileMenuCommands.saveAsWorkspace(container: w.session.model.url, to: url)
            _ = open(path: ws.path)
        }
    }
}
