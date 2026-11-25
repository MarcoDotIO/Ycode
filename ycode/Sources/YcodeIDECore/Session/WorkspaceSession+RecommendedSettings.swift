import Foundation
import YcodeBuild
import YcodeProject

/// The project check behind "Update to recommended settings" (`specs/ide/
/// issues.md` §1, §6; P-120): one file-less project warning for a project
/// whose settings differ from the recommended set (`RecommendedSettings`).
enum RecommendedSettingsCheck {
    static func issues(_ proj: PBXProj, path: String) -> [Diagnostic] {
        let url = URL(fileURLWithPath: path)
        let name = url.deletingPathExtension().lastPathComponent
        guard RecommendedSettings.needsUpdate(proj, projectName: name, projectDirectory: proj.projectDirectory(xcodeprojURL: url)) else { return [] }
        return [Diagnostic(severity: .warning, message: RecommendedSettings.warningMessage)]
    }
}

extension WorkspaceSession {
    /// The issue is the recommended-settings warning (no file, its text).
    public static func isRecommendedSettingsIssue(_ d: Diagnostic) -> Bool {
        d.location == nil && d.message == RecommendedSettings.warningMessage
    }

    /// The first project (by path) whose settings differ from the
    /// recommended set, with the checklist's changes; nil when none does.
    public var recommendedSettingsProject: (path: String, name: String, changes: [RecommendedSettings.Change])? {
        for (path, proj) in model.projects.sorted(by: { $0.key < $1.key }) {
            let url = URL(fileURLWithPath: path)
            let name = url.deletingPathExtension().lastPathComponent
            let changes = RecommendedSettings.changes(in: proj, projectName: name, projectDirectory: proj.projectDirectory(xcodeprojURL: url))
            if !changes.isEmpty { return (path, name, changes) }
        }
        return nil
    }

    /// Perform Changes (§6 item 3): writes the chosen changes into the
    /// project through the pbxproj writer, then re-runs the project checks
    /// (the warning goes once nothing is left to change). Returns the edited
    /// project.
    @discardableResult
    public func performRecommendedSettings(_ changes: [RecommendedSettings.Change], projectPath: String) throws -> PBXProj? {
        guard var proj = model.projects[projectPath] else { return nil }
        guard !changes.isEmpty else { return proj }
        RecommendedSettings.apply(changes, to: &proj)
        model.projects[projectPath] = proj
        try model.saveProjects()
        refreshProjectIssues()
        return proj
    }
}

/// The checklist sheet's state and measures (`issues.md` §5), shared by the
/// macOS and Linux IDEs: the rows (a group heading, then its changes), the
/// checked changes, and the group checkboxes' three states.
public struct RecommendedSettingsChecklist: Equatable, Sendable {
    public enum CheckState: Equatable, Sendable { case on, off, mixed }

    public enum Row: Equatable, Sendable, Identifiable {
        case group(RecommendedSettings.Group)
        case change(RecommendedSettings.Change)
        public var id: String {
            switch self {
            case .group(let g): "group|\(g.rawValue)"
            case .change(let c): c.id
            }
        }
    }

    public let projectPath: String
    public let changes: [RecommendedSettings.Change]
    /// The checked changes' IDs; at first every change the reference checks
    /// (all but the asset-symbol extensions row).
    public var checked: Set<String>

    public init(projectPath: String, changes: [RecommendedSettings.Change]) {
        self.projectPath = projectPath
        self.changes = changes
        checked = Set(changes.filter(\.isCheckedByDefault).map(\.id))
    }

    /// The groups with changes, in order.
    public var groups: [RecommendedSettings.Group] {
        RecommendedSettings.Group.allCases.filter { g in changes.contains { $0.group == g } }
    }

    /// Each group's heading, then its changes.
    public var rows: [Row] {
        groups.flatMap { g in [Row.group(g)] + changes.filter { $0.group == g }.map(Row.change) }
    }

    public func isChecked(_ change: RecommendedSettings.Change) -> Bool { checked.contains(change.id) }

    /// A group's checkbox: on when all its changes are, off when none is.
    public func state(of group: RecommendedSettings.Group) -> CheckState {
        let mine = changes.filter { $0.group == group }
        let on = mine.filter { checked.contains($0.id) }.count
        return on == 0 ? .off : (on == mine.count ? .on : .mixed)
    }

    public mutating func toggle(_ change: RecommendedSettings.Change) {
        if checked.contains(change.id) { checked.remove(change.id) } else { checked.insert(change.id) }
    }

    /// A group's checkbox clicked: every change of the group on, or (when
    /// all are on) off.
    public mutating func toggle(_ group: RecommendedSettings.Group) {
        let ids = changes.filter { $0.group == group }.map(\.id)
        if state(of: group) == .on { checked.subtract(ids) } else { checked.formUnion(ids) }
    }

    /// What Perform Changes writes.
    public var chosen: [RecommendedSettings.Change] { changes.filter { checked.contains($0.id) } }

    /// A change's text as the row shows it: the explanation, then a bullet
    /// line per listed item.
    public static func detail(_ c: RecommendedSettings.Change) -> String {
        ([c.explanation] + c.bullets.map { "\u{2022} \($0)" }).joined(separator: "\n")
    }

    // MARK: Measures (§5)

    public enum Metrics {
        public static let width = 581.0
        public static let height = 364.0
        /// The bordered, scrolling list.
        public static let listWidth = 522.0
        public static let listTop = 20.0
        /// The checkbox column.
        public static let checkboxColumn = 40.0
        /// A group heading's row.
        public static let groupRowHeight = 18.0
        /// A change's row: its bold title and each line of explanation are
        /// 14 tall, with 2 to spare (30 for one line, 44 for two).
        public static let lineHeight = 14.0
        public static func changeRowHeight(explanationLines: Int) -> Double { 2 + lineHeight * Double(1 + max(1, explanationLines)) }
        public static let titleFontSize = 11.0
        public static let cancelSize = (width: 84.0, height: 23.0)
        public static let performSize = (width: 130.0, height: 23.0)
        public static let buttonGap = 12.0
        public static let buttonTrailing = 20.0
        public static let buttonBottom = 17.0
        /// Between the list's foot and the buttons' top.
        public static let listToButtons = 16.0
        public static var listHeight: Double { height - listTop - buttonBottom - cancelSize.height - listToButtons }
        public static var listX: Double { ((width - listWidth) / 2).rounded(.down) }
    }

    public static let cancelTitle = "Cancel"
    public static let performTitle = "Perform Changes"
}
