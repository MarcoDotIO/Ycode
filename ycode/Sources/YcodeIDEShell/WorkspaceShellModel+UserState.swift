import Foundation
import YcodeIDECore

/// The Linux IDE keeps the Project navigator's expanded rows in the same
/// per-workspace user data as the macOS IDE (`WorkspaceUserState`,
/// `reference-ui-5.md` §5.1 N4), so each group's expanded state comes back
/// with the workspace (`editor-area.md` F.12, checklist row 113). Test
/// runs neither read nor write it.
extension WorkspaceShellModel {
    /// Where the workspace's user data lives (none in tests).
    static func stateFileURL(for model: WorkspaceModel) -> URL? {
        IDEProcess.isTestProcess ? nil : WorkspaceUserState.fileURL(container: model.url, isPackage: model.kind == .package)
    }

    /// The expanded rows to start with: the saved set, else the first-open
    /// default.
    static func initialExpansion(for model: WorkspaceModel, stateURL: URL?) -> Set<String> {
        // Rows below the main group's children open collapsed (navigators.md round 7 §4).
        let saved = stateURL.map(WorkspaceUserState.load(from:))?.expandedRows.map { NavigatorTree.reopenedExpansion($0, root: model.root) }
        return Set(saved ?? NavigatorTree.initiallyExpanded(model.root))
    }

    /// Saves the expanded rows (sorted, so the file is stable).
    func saveExpansion() {
        if let url = userStateURL { Self.save(expansion: expanded, to: url) }
    }

    /// Writes `expansion` into the user data at `url`, keeping its other values.
    static func save(expansion: Set<String>, to url: URL) {
        var state = WorkspaceUserState.load(from: url)
        state.expandedRows = expansion.sorted()
        state.save(to: url)
    }
}
