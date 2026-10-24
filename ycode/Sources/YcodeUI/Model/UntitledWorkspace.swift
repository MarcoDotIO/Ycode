import AppKit
import Foundation

extension WorkspaceModel {
    /// An empty, untitled workspace: the window File ▸ New ▸ Project ▸
    /// Choose Template… opens behind its sheet (reference-ui-5.md §11.3,
    /// P10). Its location is a fresh folder under the temporary directory
    /// that nothing is saved into unless the user saves.
    public static func untitled() -> WorkspaceModel {
        WorkspaceModel(untitledAt: FileManager.default.temporaryDirectory
            .appendingPathComponent("ycode-untitled-\(UUID().uuidString)/Untitled.xcworkspace"))
    }

    init(untitledAt url: URL) {
        self.url = url
        kind = .workspace
        root = NavigatorNode(name: "Untitled", kind: .container, path: url.path, children: [])
        schemeNames = []
    }

    /// Whether this is an untitled workspace (nothing on disk).
    public var isUntitled: Bool { kind == .workspace && !FileManager.default.fileExists(atPath: url.path) && projects.isEmpty }
}

extension NewProjectFlow {
    /// The empty workspace window the template sheet sits on.
    @MainActor
    static func emptyWorkspaceWindow() -> WorkspaceWindowController {
        let wc = WorkspaceWindowController(session: WorkspaceSession(model: .untitled()), loadDestinations: false, startLanguageService: false,
                                           userStateURL: nil)
        wc.window?.title = "Untitled"
        return wc
    }
}
