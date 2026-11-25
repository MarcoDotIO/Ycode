import Foundation
import Observation
import YcodeBuild
import YcodeIDECore
import YcodeProject

/// The Linux IDE's "Update to recommended settings" checklist sheet
/// (`specs/ide/issues.md` §5, §6; P-120), over the core's
/// `RecommendedSettingsChecklist` as the macOS IDE's sheet is: clicking the
/// warning in the Issue navigator shows it; Perform Changes writes the
/// checked settings through the pbxproj writer; Cancel changes nothing.
@MainActor
@Observable
public final class ShellRecommendedSettings {
    /// The sheet's state while it is up.
    public private(set) var checklist: RecommendedSettingsChecklist?
    /// Why the last Perform Changes failed, if it did.
    public private(set) var lastError: String?
    /// The stepper is moving the Issue navigator's selection: it does not
    /// open the sheet (§4).
    @ObservationIgnored var isStepping = false

    public init() {}

    public var isShown: Bool { checklist != nil }

    /// Shows the sheet for the first project that needs the update; false
    /// when none does.
    @discardableResult
    public func show(_ session: WorkspaceSession) -> Bool {
        guard let target = session.recommendedSettingsProject else { return false }
        lastError = nil
        checklist = RecommendedSettingsChecklist(projectPath: target.path, changes: target.changes)
        return true
    }

    /// A row's checkbox (a group's turns its rows on or off).
    public func toggle(rowID: String) {
        guard var c = checklist, let row = c.rows.first(where: { $0.id == rowID }) else { return }
        switch row {
        case .group(let g): c.toggle(g)
        case .change(let ch): c.toggle(ch)
        }
        checklist = c
    }

    /// Cancel (Escape): closes; nothing is applied.
    public func cancel() { checklist = nil }

    /// Perform Changes (Return): writes the checked changes and closes.
    public func perform(_ session: WorkspaceSession) {
        guard let c = checklist else { return }
        do {
            try session.performRecommendedSettings(c.chosen, projectPath: c.projectPath)
            checklist = nil
        } catch {
            lastError = "\(error)"
        }
    }
}

extension WorkspaceShellModel {
    /// An issue without a file was chosen in the Issue navigator: the
    /// recommended-settings warning shows its sheet; the stepper only
    /// selects it (the Linux IDE has no project editor to open, §4).
    func openFilelessIssue(_ row: IssueRow) {
        guard row.file == nil, row.message == RecommendedSettings.warningMessage, !recommendedSettings.isStepping else { return }
        recommendedSettings.show(session)
    }

    /// Opens the checklist sheet (the walk and tests).
    @discardableResult
    public func showRecommendedSettings() -> Bool { recommendedSettings.show(session) }

    /// Moves the Issue navigator's selection for the stepper.
    func stepSelection(to id: String) {
        recommendedSettings.isStepping = true
        issueSelection = id
        recommendedSettings.isStepping = false
    }
}
