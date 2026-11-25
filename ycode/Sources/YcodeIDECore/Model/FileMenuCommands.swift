import Foundation

/// File menu commands both IDEs perform the same way (P-001, council round
/// 11: Save As…, Export…, Save As Workspace… are enabled in the reference
/// where Ycode disabled them). The panels and dialogs are each toolkit's;
/// what is written is decided here.
public enum FileMenuCommands {
    /// Which commands apply in a workspace: Save As… and Export… act on
    /// the focused document, or with none on the workspace's own document
    /// (a project or workspace bundle; a package folder is not one), as the
    /// reference enables them with nothing open (P-008); Save As
    /// Workspace… needs a project or package (a workspace already is one).
    public static func isEnabled(_ action: String, hasDocument: Bool, containerKind: WorkspaceModel.ContainerKind) -> Bool? {
        switch action {
        case "saveFileAs:", "exportFile:": return hasDocument || containerKind != .package
        case "saveAsWorkspace:": return containerKind != .workspace
        default: return nil
        }
    }

    /// Writes a document's contents to `destination` (Save As… and
    /// Export…): the editor's text when it has one (unsaved edits included),
    /// else a copy of the file as it is on disk.
    public static func write(text: String?, of source: URL, to destination: URL) throws {
        let fm = FileManager.default
        if let text {
            try text.write(to: destination, atomically: true, encoding: .utf8)
            return
        }
        if fm.fileExists(atPath: destination.path) { try fm.removeItem(at: destination) }
        try fm.copyItem(at: source, to: destination)
    }

    /// The workspace's own document, which Save As… and Export… write
    /// with no file focused: the `.xcodeproj` or `.xcworkspace` bundle.
    public static func containerDocument(_ container: URL, kind: WorkspaceModel.ContainerKind) -> URL? {
        kind == .package ? nil : container
    }

    /// File ▸ Save As Workspace…: a `.xcworkspace` at `destination` that
    /// holds the container at `container` (a project bundle or a package
    /// folder), referenced relative to the workspace's folder (the
    /// `contents.xcworkspacedata` format, `specs/formats`). Returns the
    /// workspace's URL, with the extension added when missing.
    @discardableResult
    public static func saveAsWorkspace(container: URL, to destination: URL) throws -> URL {
        let ws = destination.pathExtension == "xcworkspace" ? destination : destination.appendingPathExtension("xcworkspace")
        let base = ws.deletingLastPathComponent().standardizedFileURL.path
        let target = container.lastPathComponent == "Package.swift" ? container.deletingLastPathComponent() : container
        let fm = FileManager.default
        if fm.fileExists(atPath: ws.path) { try fm.removeItem(at: ws) }
        try fm.createDirectory(at: ws, withIntermediateDirectories: true)
        try workspaceData(referencing: [target], base: base).write(to: ws.appendingPathComponent("contents.xcworkspacedata"),
                                                                    atomically: true, encoding: .utf8)
        return ws
    }

    /// The `contents.xcworkspacedata` text of a workspace holding `items`
    /// (paths relative to `base`, the workspace's folder).
    public static func workspaceData(referencing items: [URL], base: String) -> String {
        let refs = items.map { "   <FileRef\n      location = \"group:\(relativePath($0.standardizedFileURL.path, from: base))\">\n   </FileRef>\n" }
        return "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<Workspace\n   version = \"1.0\">\n" + refs.joined() + "</Workspace>\n"
    }

    /// `path` relative to the folder `base` ("../Other/App.xcodeproj").
    static func relativePath(_ path: String, from base: String) -> String {
        let p = path.split(separator: "/"), b = base.split(separator: "/")
        var i = 0
        while i < p.count, i < b.count, p[i] == b[i] { i += 1 }
        return (Array(repeating: "..", count: b.count - i) + p[i...].map(String.init)).joined(separator: "/")
    }
}
