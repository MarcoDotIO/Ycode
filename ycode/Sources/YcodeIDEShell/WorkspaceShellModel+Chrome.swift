import Foundation
import YcodeIDECore

/// What the shell's chrome shows, from the same rules the AppKit IDE uses
/// (`WorkspaceChrome`): the outlines' rows, the jump bar, the File
/// inspector's rows.
extension WorkspaceShellModel {
    /// File names in the navigator and the jump bar follow Settings ▸
    /// General ▸ File Extensions (hidden by default).
    public var hidesFileExtensions: Bool { Preferences.shared.fileExtensions == .hide }

    public var projectRows: [OutlineRow] {
        OutlineRows.project(root, expanded: expanded, hideExtensions: hidesFileExtensions, edited: editedPaths, badges: sourceControl.badges)
    }

    /// The jump bar's components for the open file (title, symbol).
    public var jumpPath: [(title: String, symbol: String)] {
        guard let d = document else { return [] }
        return WorkspaceChrome.jumpPath(for: URL(fileURLWithPath: d.path), root: session.model.root, workspaceName: workspaceName,
                                        hideExtension: hidesFileExtensions).map { (title: $0.0, symbol: $0.1) }
    }

    // The File inspector: WorkspaceShellModel+FileInspector.swift.
}
