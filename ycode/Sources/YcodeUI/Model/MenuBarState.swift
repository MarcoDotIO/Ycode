import Foundation

/// What the menu bar's dynamic titles and conditional items depend on
/// (`specs/ide/reference-ui-5.md` §1.3, §1.5). The key workspace window
/// fills one in; with no workspace window there is none and the generic
/// titles of `CommandTable` show.
public struct MenuContext: Equatable, Sendable {
    public var containerKind: WorkspaceModel.ContainerKind = .project
    /// The workspace's display name (a project's name without extension).
    public var workspaceName = ""
    /// The focused document's file name with extension.
    public var fileName: String?
    /// The caret's 1-based line in the focused source editor.
    public var caretLine: Int?
    public var editorTabCount = 1
    public var editorPaneCount = 1
    /// Window tabs in the window's tab group (1 = none).
    public var windowTabCount = 1
    public var isWindowTabBarVisible = false
    public var isFullScreen = false
    public var sourceEditorFocused = false
    /// The focused editor's kind: which Editor menu shows (§2.7, §2.8).
    public var editorKind: EditorKind = .source
    /// Inline issues are shown (Editor ▸ Show / Hide All Issues).
    public var inlineIssuesShown = true
    public var repositoryHasRemote = false
    public var isDebugging = false
    public var isPaused = false
    public var breakpointsActive = true
    /// Whether every breakpoint on the caret's line is enabled; nil when
    /// the line has none (Debug ▸ Breakpoints, §2.10).
    public var caretLineBreakpointsEnabled: Bool?
    public var navigatorShown = true
    /// The left area shows the Coding Assistant pane (View ▸ Navigators ▸
    /// Hide Coding Assistant, reference-ui-6.md §9.5).
    public var codingAssistantShown = false
    public var inspectorShown = true
    public var debugAreaShown = false
    public var editorTabBarShown = false
    public var editorTabPinned = false
    /// A file row is selected in a navigator (Integrate titles read
    /// "… in Selected Files").
    public var hasNavigatorFileSelection = false
    /// The selected navigator file is untracked (Discard reads "Move
    /// Selected Files to Trash…").
    public var selectedFileIsUntracked = false
    /// The pasteboard holds text (File ▸ New ▸ New File from Clipboard,
    /// reference-ui-6.md §8 item 6).
    public var pasteboardHasText = false
    /// What is selected in the project navigator (Find ▸ Find in Selected
    /// File… / Groups…).
    public var projectSelection: ProjectSelection?
    /// The project navigator's selection is a folder or inside one (a
    /// synchronized folder, a package directory): File ▸ New ▸ hides the
    /// Group items.
    public var projectSelectionInFolder = false
    /// An item was cut for moving (Edit ▸ Paste ▸ Move Item Here).
    public var hasItemToMove = false

    /// A project navigator selection: a file, or a group or folder.
    public enum ProjectSelection: Equatable, Sendable { case file, group }

    public init() {}

    /// "Project", "Workspace" or "Package" (§2.5, §5.4).
    public var scopeName: String {
        switch containerKind {
        case .project: "Project"
        case .workspace: "Workspace"
        case .package: "Package"
        }
    }
}

/// Titles that change with context (§1.3). `title(for:in:)` returns the
/// generic title when there is no context.
public enum MenuTitles {
    static func quoted(_ s: String) -> String { "\u{201C}\(s)\u{201D}" }

    /// The title to show for `c` in context `ctx`.
    public static func title(for c: MenuCommand, in ctx: MenuContext?) -> String {
        title(generic: c.title, in: ctx)
    }

    /// The title to show for an item whose generic title is `g` (for example
    /// "Add Files…" becomes "Add Files to “App”…"); `g` when there is no context
    /// or the title does not vary.
    public static func title(generic g: String, in ctx: MenuContext?) -> String {
        guard let ctx else { return g }
        let file = ctx.fileName
        switch g {
        // File (§2.2)
        case "Add Files…": return "Add Files to \(quoted(ctx.workspaceName))…"
        case "Close Tab, Editor Pane, Window Tab, or Window": return CloseShortcutRule.commandWTitle(tabCount: ctx.editorTabCount)
        case "Close Document": return EditorCloseCommand.document.title(fileName: file, isPackage: false)
        case "Close Window": return ctx.windowTabCount > 1 ? "Close Window Tab" : "Close Window"
        case "Close Workspace": return "Close \(ctx.scopeName)"
        case "Workspace Settings…": return "\(ctx.scopeName) Settings…"
        // reference-ui-6.md §8 item 6 (M6): the enabled title.
        case "File from Clipboard": return ctx.pasteboardHasText ? "New File from Clipboard" : g
        // Edit (§2.3)
        case "Bookmark Line":
            if let file, let n = ctx.caretLine { return "Bookmark \(quoted(file)) Line \(n)" }
        case "Bookmark Line With Dialog":
            if let file, let n = ctx.caretLine { return "Bookmark \(quoted(file)) Line \(n)…" }
        case "Bookmark File":
            if let file { return "Bookmark \(quoted(file))" }
        case "Bookmark File With Dialog":
            if let file { return "Bookmark \(quoted(file))…" }
        // View (§2.4)
        case "Show Editor Tab Bar": return ctx.editorTabBarShown ? "Hide Editor Tab Bar" : g
        case "Pin Editor Tab": return ctx.editorTabPinned ? "Unpin Editor Tab" : g
        case "Show Navigator": return ctx.navigatorShown ? "Hide Navigator" : g
        case "Show Coding Assistant": return ctx.codingAssistantShown ? "Hide Coding Assistant" : g
        case "Show Inspector": return ctx.inspectorShown ? "Hide Inspector" : g
        case "Show Debug Area": return ctx.debugAreaShown ? "Hide Debug Area" : g
        case "Show Window Tab Bar": return ctx.isWindowTabBarVisible ? "Hide Window Tab Bar" : g
        case "Enter Full Screen": return ctx.isFullScreen ? "Exit Full Screen" : g
        // Editor (§2.7)
        case "Show All Issues": return ctx.inlineIssuesShown ? "Hide All Issues" : g
        case "Format Selection", "Format File":
            if let file, file.hasSuffix(".swift") { return g + " with \u{2018}swift-format\u{2019}" }
        // Find (reference-ui-6.md §8 item 6, M6)
        case "Find in Selected Groups…": return ctx.projectSelection == .file ? "Find in Selected File…" : g
        // Navigate (§2.6)
        case "Jump to Line…":
            if let file { return "Jump to Line in \(quoted(file))…" }
        // Product (§2.9)
        case "Compile File", "Analyze File", "Preprocess File", "Assemble File":
            if let file { return g.replacingOccurrences(of: "File", with: quoted(file)) }
        // Debug (§2.10)
        case "Pause": return ctx.isPaused ? "Continue" : g
        case "Deactivate Breakpoints": return ctx.breakpointsActive ? g : "Activate Breakpoints"
        case "Enable Breakpoints at Current Line": return ctx.caretLineBreakpointsEnabled == true ? "Disable Breakpoints at Current Line" : g
        // Integrate (§2.11; reference-ui-4.md §3)
        case "Stage Selected Files":
            if !ctx.hasNavigatorFileSelection, let file { return "Stage Changes in \(quoted(file))" }
            return "Stage Changes in Selected Files"
        case "Unstage Selected Files": return "Unstage Changes in Selected Files"
        case "Mark as Resolved": return "Mark Selected Files as Resolved"
        case "Add": return "Add Selected Files"
        case "Discard Changes in Selected Files…":
            if ctx.hasNavigatorFileSelection && ctx.selectedFileIsUntracked { return "Move Selected Files to Trash…" }
            if !ctx.hasNavigatorFileSelection, let file { return "Discard Changes in \(quoted(file))…" }
        default:
            // Find (§2.5): "in Workspace" names the container.
            if g.hasPrefix("Find"), g.contains(" in Workspace") {
                return g.replacingOccurrences(of: " in Workspace", with: " in \(ctx.scopeName)")
            }
        }
        return g
    }
}

/// Conditional items (§1.5).
public enum MenuConditions {
    /// Whether an item with condition `c` is shown; items without a
    /// condition always are. Without a context the separate Close Window
    /// item and group commands show and the other conditional items hide.
    public static func isShown(_ c: MenuCondition?, in ctx: MenuContext?) -> Bool {
        guard let c else { return true }
        switch c {
        case .sourceEditorFocused: return ctx?.sourceEditorFocused ?? false
        case .repositoryHasRemote: return ctx?.repositoryHasRemote ?? false
        case .debugging: return ctx?.isDebugging ?? false
        case .separateCloseWindow: return ctx.map { CloseShortcutRule.showsSeparateCloseWindow(tabCount: $0.editorTabCount) } ?? true
        case .groupsAllowed: return !(ctx?.projectSelectionInFolder ?? false)
        case .itemToMove: return ctx?.hasItemToMove ?? false
        }
    }

    /// Which separators to show, given whether each item is a separator
    /// and whether each non-separator is visible: around hidden items the
    /// separators collapse to one, and none leads or trails the menu.
    public static func visibleSeparators(isSeparator: [Bool], isVisible: [Bool]) -> [Bool] {
        var out = Array(repeating: false, count: isSeparator.count)
        var sawItem = false
        var pending: Int?
        for i in isSeparator.indices {
            if isSeparator[i] {
                if sawItem && pending == nil { pending = i }
            } else if isVisible[i] {
                if let p = pending { out[p] = true }
                pending = nil
                sawItem = true
            }
        }
        return out
    }
}
