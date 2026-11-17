import Foundation
import YcodeIDECore

/// B4-POLISH (1.0.0-beta.4, council round 11), as the macOS IDE.
extension WorkspaceShellModel {
    /// The debugger is paused ("Paused <product>"): the title area shows
    /// the mark, not the ring (`TitleAreaIcon`).
    public var isActivityPaused: Bool {
        if case .paused = activity { return true }
        return false
    }

    /// What the title area's icon shows now.
    public var titleAreaIcon: TitleAreaIcon { TitleAreaIcon.shown(busy: isBusy, paused: isActivityPaused) }
}
