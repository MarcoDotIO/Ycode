import Foundation

/// Integrate menu (`reference-ui-4.md` §3): which items apply.
public struct IntegrateMenuState: Equatable, Sendable {
    public var hasRepository = false
    public var hasRemote = false
    public var hasUnstaged = false
    public var hasStaged = false
    /// Status of the file selected in a navigator, if it has one.
    public var selectedStatus: GitRepository.FileStatus?
    public var selectedIsStaged = false
    public var selectedFileExists = false
    public var selectedCommit: String?
    /// A merge, rebase or cherry-pick stopped on conflicts.
    public var integration: GitRepository.IntegrationState = .none
    /// Files with unresolved conflicts.
    public var conflictCount = 0

    public init() {}

    public var hasChanges: Bool { hasUnstaged || hasStaged }

    /// Whether the item with this action applies.
    public func isEnabled(_ action: String) -> Bool {
        switch action {
        case "showCommitSheet:": hasRepository && hasChanges
        case "scmPush:", "scmPull:", "scmFetch:": hasRepository && hasRemote
        case "refreshFileStatus:": hasRepository
        case "scmStageAll:": hasRepository && hasUnstaged
        case "scmUnstageAll:": hasRepository && hasStaged
        case "scmStageSelected:": hasRepository && selectedStatus != nil && selectedStatus != .untracked
        case "scmUnstageSelected:": hasRepository && selectedIsStaged
        case "scmMarkResolved:": hasRepository && selectedStatus == .conflicted
        case "scmAddSelected:": hasRepository && selectedStatus == .untracked
        case "scmCherryPick:": hasRepository && selectedCommit != nil
        case "scmStash:", "scmDiscardAll:": hasRepository && hasChanges
        case "scmTrashSelected:": selectedFileExists
        case "scmClone:": true
        case "scmNewRepository:": !hasRepository
        // Ycode's conflict section (shown only while an operation is in
        // progress, `MenuCondition.integrationInProgress`).
        case "scmResolveConflicts:": hasRepository && conflictCount > 0
        case "scmContinueIntegration:": hasRepository && integration.isInProgress && conflictCount == 0
        case "scmAbortIntegration:": hasRepository && integration.isInProgress
        default: true
        }
    }

    public static let actions = ["showCommitSheet:", "scmPush:", "scmPull:", "scmFetch:", "refreshFileStatus:", "scmStageAll:",
                                 "scmStageSelected:", "scmUnstageAll:", "scmUnstageSelected:", "scmMarkResolved:", "scmAddSelected:",
                                 "scmCherryPick:", "scmStash:", "scmDiscardAll:", "scmTrashSelected:", "scmClone:", "scmNewRepository:",
                                 "scmResolveConflicts:", "scmContinueIntegration:", "scmAbortIntegration:"]
}
