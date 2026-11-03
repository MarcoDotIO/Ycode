import Foundation
import Observation
import YcodeBuild
import YcodeIDECore

/// The app's state: the Welcome screen or one open workspace (L1 opens one
/// workspace per window and one window). A container comes from the
/// command line (`ycode-ide <path>`), the Welcome screen's recent list, or
/// File ▸ Open…, which asks for a path in a sheet: OpenViews has no file
/// dialog yet (its R13 brings the desktop portal's), and the macOS build
/// uses the same sheet so both shells behave alike.
@MainActor
@Observable
public final class ShellAppModel {
    public private(set) var workspace: WorkspaceShellModel?
    /// The Open dialog is up (File ▸ Open…).
    public var isOpenSheetShown = false
    public var openPath = ""
    /// Why the last open failed.
    public private(set) var openError: String?
    public private(set) var recent: [URL] = []
    /// The New Project sheet, while it is up.
    public var newProject: NewProjectShellModel?
    /// The Clone sheet, while it is up.
    public var clone: CloneShellModel?
    /// The About sheet is up.
    public var isAboutShown = false
    /// An alert to show.
    public var notice: ShellNotice?
    /// Hands a URL to the desktop (the views install the toolkit's opener).
    @ObservationIgnored public var openExternally: (URL) -> Void = { _ in }
    /// Where New Project remembers its choices (tests pass their own).
    @ObservationIgnored public var newProjectDefaults: UserDefaults = .standard

    @ObservationIgnored let recentProjects: RecentProjects
    @ObservationIgnored let makeEngine: () -> BuildEngine

    public init(recentProjects: RecentProjects = .shared, engine: @escaping () -> BuildEngine = { ShellBuildSetup.engine() }) {
        self.recentProjects = recentProjects
        makeEngine = engine
        recent = recentProjects.urls
    }

    /// The container path given on the command line: the first argument
    /// that is not an option. A user-defaults pair (`-Key value`, a capital
    /// after the dash) is skipped whole. Relative paths resolve against the
    /// working directory.
    public static func launchPath(_ arguments: [String] = CommandLine.arguments,
                                  workingDirectory: String = FileManager.default.currentDirectoryPath) -> String? {
        var i = 1
        while i < arguments.count {
            let a = arguments[i]
            i += 1
            if a.hasPrefix("-") {
                if a.dropFirst().first?.isUppercase == true { i += 1 }
                continue
            }
            return a.hasPrefix("/") ? a : (workingDirectory as NSString).appendingPathComponent(a)
        }
        return nil
    }

    /// Opens a container. Returns whether it opened; else `openError` says why.
    @discardableResult
    public func open(path: String) -> Bool {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        let expanded = (trimmed as NSString).expandingTildeInPath
        guard !expanded.isEmpty else {
            openError = "Enter the path of a project, workspace or package."
            return false
        }
        let url = URL(fileURLWithPath: expanded)
        do {
            workspace = try WorkspaceShellModel(url: url, engine: makeEngine())
            openError = nil
            isOpenSheetShown = false
            recentProjects.note(url)
            recent = recentProjects.urls
            return true
        } catch {
            openError = "\(url.lastPathComponent) is not a project, workspace or package folder."
            return false
        }
    }

    /// File ▸ Close Project / Workspace / Package: back to Welcome.
    public func closeWorkspace() {
        workspace?.stop()
        workspace = nil
        recent = recentProjects.urls
    }

    public func showOpenSheet() {
        openError = nil
        isOpenSheetShown = true
    }

    /// The error was shown.
    public func clearOpenError() { openError = nil }

    public func isEnabled(_ c: ShellCommand) -> Bool {
        switch c {
        case .open, .welcome, .newProject, .about, .help, .releaseNotes, .reportBug, .swiftBook, .clone: true
        case .closeWorkspace: workspace != nil
        default: workspace?.isEnabled(c) ?? false
        }
    }

    public func perform(_ c: ShellCommand) {
        switch c {
        case .open: showOpenSheet()
        case .newProject: showNewProject()
        case .closeWorkspace: closeWorkspace()
        case .welcome: closeWorkspace()
        case .about: isAboutShown = true
        case .help: openLink(ProductIdentity.helpURL)
        case .releaseNotes: openLink(ProductIdentity.releasesURL)
        case .reportBug: openLink(ProductIdentity.bugReportURL())
        case .swiftBook: if let u = URL(string: "https://docs.swift.org/swift-book/") { openLink(u) }
        case .clone: showClone()
        default: workspace?.perform(c)
        }
    }

    /// The command's title in the current context.
    public func title(_ c: ShellCommand) -> String { c.title(in: workspace?.menuContext) }
}
