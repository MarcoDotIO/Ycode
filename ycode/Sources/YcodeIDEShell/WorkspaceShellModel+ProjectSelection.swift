import Foundation
import YcodeIDECore

/// The Project navigator follows the open document as the macOS IDE's does
/// (`selectOpenFileRow`; `navigators.md` "Council round 1" §3,
/// `cross-platform-parity.md` §3): a file opened any other way (Open
/// Quickly, Find, an issue, history, the jump bar) moves the selection band
/// to its row when the row is shown.
extension WorkspaceShellModel {
    /// The project row drawn as selected: the open file's row, unless the
    /// person selected a group or folder row since (a file row other than
    /// the open file's follows the document).
    public var projectSelection: String? {
        let documentRow = document.flatMap { root.idPath(to: $0.path)?.last }
        guard let s = selection else { return documentRow }
        if let documentRow, s != documentRow, root.find(id: s)?.isFile == true { return documentRow }
        return s
    }
}
