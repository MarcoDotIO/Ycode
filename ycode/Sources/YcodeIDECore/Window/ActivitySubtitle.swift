import Foundation

extension WorkspaceChrome {
    /// The activity view's subtitle while the workspace is idle
    /// (`editor-area.md` G.9, council row 141): empty, or, while the
    /// language service starts, a line saying so (Ycode's own words) under
    /// the workspace's name. A build or a run replaces it.
    public static func idleActivityText(preparingEditorServices: Bool) -> String {
        preparingEditorServices ? preparingEditorServicesText : ""
    }

    /// The subtitle while the language service starts.
    public static let preparingEditorServicesText = "Starting the language server"
}
