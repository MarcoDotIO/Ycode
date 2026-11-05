import Foundation
import Observation
import YcodeIDECore

/// The Linux IDE's Organizer window (Window ▸ Organizer): the core's
/// `OrganizerState` over the archives folder ycodebuild writes, for the
/// views to draw. See `specs/ide/organizer.md`.
///
/// Distribute App is not offered here yet (#43): its button is shown
/// disabled, as the macOS IDE shows it for an archive it cannot
/// distribute.
@MainActor
@Observable
public final class OrganizerShellModel {
    /// Where the archives are (`~/Library/Developer/Xcode/Archives`, where
    /// `ycodebuild archive` puts them; tests pass their own).
    public var archivesDirectory: URL
    public private(set) var state = OrganizerState()
    /// Shows a file or folder in the desktop's file manager (the view
    /// layer installs it; tests record the calls).
    @ObservationIgnored public var revealInFiles: (URL) -> Void = { _ in }
    /// The archive the last Show in Files asked for.
    public private(set) var lastRevealed: URL?

    public init(archivesDirectory: URL = Organizer.defaultArchivesDirectory) {
        self.archivesDirectory = archivesDirectory
    }

    /// Reads the archives folder again (the window's appearance and Reload).
    public func reload() {
        state.load(Organizer.archives(in: archivesDirectory))
    }

    /// Selects the archive at a path, switching to its application.
    public func select(archiveAt url: URL) {
        reload()
        state.select(archiveAt: url)
    }

    /// Selects a row of the list (headings select nothing).
    public func selectRow(_ row: Int?) { state.selectRow(row) }

    public func chooseApp(_ app: String) { state.chooseApp(app) }

    public func showPage(_ page: String, section: String) {
        state.notificationsShown = false
        state.showPage(page, section: section)
    }

    public func goBack() { state.moveInHistory(-1) }
    public func goForward() { state.moveInHistory(1) }

    public func toggleNotifications() { state.notificationsShown.toggle() }
    public func hideNotifications() { state.notificationsShown = false }

    /// Distribution comes with #43: the button is drawn, disabled.
    public var canDistribute: Bool { false }

    /// Show in Files: the archive at a row (else the selection), selected
    /// in its folder. Returns it (nil: a heading or nothing selected).
    @discardableResult
    public func showInFiles(row: Int? = nil) -> URL? {
        let r = row ?? state.selectedRow
        guard let r, state.rows.indices.contains(r), let a = state.rows[r].archive else { return nil }
        lastRevealed = a.url
        revealInFiles(a.url)
        return a.url
    }
}
