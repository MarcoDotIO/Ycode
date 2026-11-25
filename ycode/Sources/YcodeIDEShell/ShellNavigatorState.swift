import Foundation
import Observation
import YcodeIDECore

/// What the Linux navigators keep beside the workspace model
/// (B5-NAVIGATOR): the Project navigator's multiple selection, the row
/// being renamed, the Delete question, the file operations' undo and redo,
/// the rows cut for Move Item Here, a drag in progress; and every
/// navigator's filter (its text, the text the rows follow once it settles,
/// the recent filters and the in-field toggles). The operations are
/// `WorkspaceShellModel+FileOperations.swift`, the filter
/// `WorkspaceShellModel+NavigatorFilter.swift`.
@MainActor
@Observable
public final class ShellNavigatorState {
    public init() {}

    // MARK: Project navigator selection and editing

    /// The selected project rows in the order they were added, when more
    /// than the model's single `selection` (⇧-click, Ctrl-click; P-051).
    /// Empty: the selection is `projectSelection` alone.
    public var multiSelection: [String] = []
    /// Where a ⇧-click extends from.
    public var anchor: String?
    /// The row whose name is edited in place (P-043).
    public var renaming: String?
    /// Delete's question (P-052).
    public var deletePrompt: DeletePrompt?
    /// The last operation's error, for the alert and drivers.
    public var lastError: String?
    /// Edit ▸ Cut in the navigator: the rows Move Item Here moves.
    public var cut: (project: String?, items: [ProjectItem])?
    /// The options Add Files… used last (dropped files use them too).
    public var lastAddFilesOptions = AddFilesOptions()
    /// Add Files…'s file dialog is up.
    public var isAddFilesShown = false
    /// Where trashed items go (tests use a folder).
    @ObservationIgnored public var trashBin: TrashBin = .user
    /// The rows Delete's question is about.
    @ObservationIgnored var multiSelectionForDelete: [String] = []
    /// Show in Files: the desktop's file manager (the view sets it).
    @ObservationIgnored public var revealInFiles: (URL) -> Void = { _ in }
    /// New File from Template…: the New File sheet, when the shell has one
    /// (nil: the item is disabled).
    @ObservationIgnored public var newFileFromTemplate: (() -> Void)?

    /// One finished operation on the undo or redo stack.
    struct Done {
        var edit: ProjectEdit
        var project: String?
    }
    @ObservationIgnored var undoStack: [Done] = []
    @ObservationIgnored var redoStack: [Done] = []
    /// Bumped with the stacks so menu titles follow.
    public internal(set) var undoRevision = 0

    /// Delete's question: "Move to Trash", "Remove References" (only when
    /// every item has a reference), "Cancel".
    public struct DeletePrompt: Equatable, Sendable {
        public var title: String
        public var message: String
        public var offersRemoveReferences: Bool
        public static let moveToTrash = "Move to Trash"
        public static let removeReferences = "Remove References"
        public static let cancel = "Cancel"
        /// The buttons, in order.
        public var buttons: [String] {
            [Self.moveToTrash] + (offersRemoveReferences ? [Self.removeReferences] : []) + [Self.cancel]
        }
    }

    /// The Package Dependencies section under the project (L-110), read
    /// once and again after an edit (nil inside: the project has none).
    @ObservationIgnored var packageSectionCache: NavigatorItem??

    // MARK: Drag to move (P-042)

    /// Rows dragged inside the Project navigator, with where they would go.
    public struct Drag: Equatable, Sendable {
        public var rows: [String]
        /// The pointer in the outline's coordinates.
        public var location: CGPoint
        /// A group or folder row the rows would go into (highlighted), or
        /// the row the insertion line is drawn under (`insertAfter`).
        public var target: String?
        public var insertAfter: String?
        /// The insertion line's level (its ring's indentation).
        public var insertLevel = 0

        public init(rows: [String], location: CGPoint, target: String? = nil, insertAfter: String? = nil, insertLevel: Int = 0) {
            self.rows = rows
            self.location = location
            self.target = target
            self.insertAfter = insertAfter
            self.insertLevel = insertLevel
        }
    }
    public var drag: Drag?

    // MARK: Filter (P-037)

    /// The field's text, by navigator (selector index).
    public var filterText: [Int: String] = [:]
    /// The text the rows follow: the field's, `NavigatorFilterModel.settleDelay`
    /// after the last key.
    public var appliedFilter: [Int: String] = [:]
    /// The in-field toggles that are on, by navigator.
    public var toggles: [Int: Set<Int>] = [:]
    /// The recent filters (the options menu).
    public var recents = NavigatorFilterRecents()
    @ObservationIgnored var settleTasks: [Int: Task<Void, Never>] = [:]
    /// The last key in a filter field and when the rows followed it
    /// (drivers measure the settle delay).
    @ObservationIgnored public var lastFilterKeyAt: Date?
    @ObservationIgnored public var lastFilterAppliedAt: Date?

    // MARK: Timing (P-199)

    /// When the last project row was clicked and when its file was shown
    /// (the model side of click → file; drivers print them).
    @ObservationIgnored public var lastSelectStarted: Date?
    @ObservationIgnored public var lastSelectModelTime: TimeInterval?
}
