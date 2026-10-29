import AppKit

/// Settings rows from `specs/ide/reference-ui-5.md` §9 (General,
/// Navigation, Editing ▸ Display). Values live under `Ycode.` keys like
/// the rest of `Preferences`. Rows the spec marks "(stored)" are kept and
/// shown but change nothing yet.
extension Preferences {
    // MARK: General ▸ Starting Points

    public enum RestoreWindows: String, CaseIterable, Sendable {
        case system = "Use System Setting", always = "Always", never = "Never"
    }
    /// The system's own default: true keeps (restores) windows at quit.
    /// Set in Ycode's domain it overrides the macOS "Close windows when
    /// quitting an application" setting for Ycode alone.
    public static let keepWindowsKey = "NSQuitAlwaysKeepsWindows"

    /// Restore open projects and workspaces (reopens last session's
    /// workspace windows at launch).
    public var restoreWindows: RestoreWindows {
        get { RestoreWindows(rawValue: get("restoreWindows", RestoreWindows.system.rawValue)) ?? .system }
        set {
            switch newValue {
            case .system: defaults.removeObject(forKey: Self.keepWindowsKey)
            case .always: defaults.set(true, forKey: Self.keepWindowsKey)
            case .never: defaults.set(false, forKey: Self.keepWindowsKey)
            }
            set("restoreWindows", newValue.rawValue)
        }
    }

    // MARK: General ▸ Navigation and Files

    public enum NavigatorSize: String, CaseIterable, Sendable {
        case system = "Use System Setting", small = "Small", medium = "Medium", large = "Large"
    }
    /// Row size and font of all navigators.
    public var navigatorSize: NavigatorSize {
        get { NavigatorSize(rawValue: get("navigatorSize", NavigatorSize.system.rawValue)) ?? .system }
        set { set("navigatorSize", newValue.rawValue) }
    }

    /// The detail pop-ups' choices: up to 1–5 lines per row.
    public static let detailLineChoices = Array(1...5)
    /// The pop-up title for `n` lines ("Up to 1 Line", "Up to 3 Lines").
    public static func detailTitle(_ n: Int) -> String { n == 1 ? "Up to 1 Line" : "Up to \(n) Lines" }
    /// The line count a pop-up title names; nil for an unknown title.
    public static func detailLines(fromTitle t: String) -> Int? { detailLineChoices.first { detailTitle($0) == t } }

    private func lines(_ key: String) -> Int { min(5, max(1, get(key, 3))) }
    /// Bookmark / Find / Issue navigator detail: maximum lines per row
    /// before the ellipsis (default Up to 3 Lines).
    public var bookmarkNavigatorDetail: Int { get { lines("bookmarkNavigatorDetail") } set { set("bookmarkNavigatorDetail", min(5, max(1, newValue))) } }
    /// Find navigator detail: maximum lines per row (1–5, default 3).
    public var findNavigatorDetail: Int { get { lines("findNavigatorDetail") } set { set("findNavigatorDetail", min(5, max(1, newValue))) } }
    /// Issue navigator detail: maximum lines per row (1–5, default 3).
    public var issueNavigatorDetail: Int { get { lines("issueNavigatorDetail") } set { set("issueNavigatorDetail", min(5, max(1, newValue))) } }

    /// Window tabs have independent sidebar widths (stored: Ycode's
    /// workspace windows do not share sidebar widths across window tabs).
    public var independentSidebarWidths: Bool { get { get("independentSidebarWidths", false) } set { set("independentSidebarWidths", newValue) } }
    /// Automatically unlock files (stored: Ycode has no locked-file
    /// prompt yet; File ▸ Unlock… is listed disabled).
    public var autoUnlockFiles: Bool { get { get("autoUnlockFiles", false) } set { set("autoUnlockFiles", newValue) } }

    // MARK: General ▸ Issues

    public enum IssuePresentation: String, CaseIterable, Sendable { case inline = "Show Inline", minimized = "Show Minimized" }
    /// Inline issue annotations in full, or as an icon only.
    public var issuePresentation: IssuePresentation {
        get { IssuePresentation(rawValue: get("issuePresentation", IssuePresentation.inline.rawValue)) ?? .inline }
        set { set("issuePresentation", newValue.rawValue) }
    }
    /// Cancels the build at the first error.
    public var stopBuildOnFirstError: Bool { get { get("stopBuildOnFirstError", true) } set { set("stopBuildOnFirstError", newValue) } }

    // MARK: General ▸ Test Parallelization (stored until R36)

    public enum TestParallelization: String, CaseIterable, Sendable { case automatic = "Automatic", off = "Off" }
    /// Test parallelization for Mac destinations (stored; default Automatic).
    public var testParallelizationMac: TestParallelization {
        get { TestParallelization(rawValue: get("testParallelizationMac", "Automatic")) ?? .automatic }
        set { set("testParallelizationMac", newValue.rawValue) }
    }
    /// Test parallelization for simulator destinations (stored; default
    /// Automatic).
    public var testParallelizationSimulator: TestParallelization {
        get { TestParallelization(rawValue: get("testParallelizationSimulator", "Automatic")) ?? .automatic }
        set { set("testParallelizationSimulator", newValue.rawValue) }
    }

    // MARK: General ▸ Report Navigator

    /// The Report Navigator history pop-up's choices, in reports.
    public static let reportHistoryChoices = [10, 20, 50, 100]
    /// The pop-up title for a limit of `n` reports.
    public static func reportHistoryTitle(_ n: Int) -> String { "Up to \(n) Reports" }
    /// Local report history: older reports are pruned (default 20).
    public var reportHistoryLimit: Int {
        get { let n: Int = get("reportHistoryLimit", 20); return Self.reportHistoryChoices.contains(n) ? n : 20 }
        set { set("reportHistoryLimit", newValue) }
    }

    // MARK: General ▸ Settings Import & Export, Reset Ycode

    /// The user-defaults keys that are Ycode's settings: every `Ycode.`
    /// key except the recent-projects list, and the build system.
    public var settingsKeys: [String] {
        defaults.dictionaryRepresentation().keys.filter {
            ($0.hasPrefix("Ycode.") && $0 != RecentProjects.defaultsKey) || $0 == BuildSystemPreference.defaultsKey
        }.sorted()
    }

    /// Settings ▸ General ▸ Export…: Ycode's settings as one JSON object
    /// (`{"format": "ycode-settings", "version": 1, "values": {…}}`; data
    /// values as `{"data": "<base64>"}`).
    public func exportSettings() throws -> Data {
        var values: [String: Any] = [:]
        for k in settingsKeys { if let v = defaults.object(forKey: k) { values[k] = Self.jsonValue(v) } }
        let doc: [String: Any] = ["format": "ycode-settings", "version": 1, "values": values]
        return try JSONSerialization.data(withJSONObject: doc, options: [.prettyPrinted, .sortedKeys])
    }

    /// Settings ▸ General ▸ Import…: replaces Ycode's settings with the
    /// file's. Unknown formats are refused and change nothing.
    public func importSettings(_ data: Data) throws {
        guard let doc = try JSONSerialization.jsonObject(with: data) as? [String: Any], doc["format"] as? String == "ycode-settings",
              let values = doc["values"] as? [String: Any] else { throw CocoaError(.fileReadCorruptFile) }
        for k in settingsKeys { defaults.removeObject(forKey: k) }
        for (k, v) in values where k.hasPrefix("Ycode.") || k == BuildSystemPreference.defaultsKey {
            defaults.set(Self.defaultsValue(v), forKey: k)
        }
        // The restore choice also drives the system key.
        let r = restoreWindows
        restoreWindows = r
        changed()
    }

    /// Reset Settings: clears Ycode's user defaults (the factory values
    /// return). Themes on disk and the recent-projects list are kept.
    public func resetSettings() {
        for k in settingsKeys { defaults.removeObject(forKey: k) }
        defaults.removeObject(forKey: Self.keepWindowsKey)
        changed()
    }

    /// "Don't ask me" warnings: a warning suppressed by its alert's
    /// checkbox is stored as `Ycode.suppress.<id>`.
    public static let suppressionPrefix = "Ycode.suppress."
    /// Whether the warning `id` was suppressed with "Don't ask me".
    public func isWarningSuppressed(_ id: String) -> Bool { defaults.bool(forKey: Self.suppressionPrefix + id) }
    /// Suppresses the warning `id` until Reset All; posts `didChange`.
    public func suppressWarning(_ id: String) { defaults.set(true, forKey: Self.suppressionPrefix + id); changed() }
    /// Reset All: every suppressed warning asks again.
    public func resetSuppressedWarnings() {
        for k in defaults.dictionaryRepresentation().keys where k.hasPrefix(Self.suppressionPrefix) { defaults.removeObject(forKey: k) }
        changed()
    }

    static func jsonValue(_ v: Any) -> Any {
        switch v {
        case let d as Data: return ["data": d.base64EncodedString()]
        case let a as [Any]: return a.map(jsonValue)
        case let m as [String: Any]: return m.mapValues(jsonValue)
        case let date as Date: return ["date": date.timeIntervalSinceReferenceDate]
        default: return v
        }
    }

    static func defaultsValue(_ v: Any) -> Any {
        switch v {
        case let m as [String: Any] where m.count == 1 && m["data"] is String:
            return Data(base64Encoded: m["data"] as? String ?? "") ?? Data()
        case let m as [String: Any] where m.count == 1 && m["date"] is NSNumber:
            return Date(timeIntervalSinceReferenceDate: (m["date"] as? NSNumber)?.doubleValue ?? 0)
        case let m as [String: Any]: return m.mapValues(defaultsValue)
        case let a as [Any]: return a.map(defaultsValue)
        case let n as NSNumber where CFGetTypeID(n) == CFBooleanGetTypeID(): return n.boolValue
        default: return v
        }
    }

    // MARK: Navigation (reference-ui-5.md §9.2)

    public enum NewEditorContent: String, CaseIterable, Sendable { case startPage = "Start Page", sameDocument = "Same Document" }
    /// File ▸ New ▸ Tab shows the Start Page (default) or the current file.
    public var newEditorTabsOpenWith: NewEditorContent {
        get { NewEditorContent(rawValue: get("newEditorTabsOpenWith", NewEditorContent.startPage.rawValue)) ?? .startPage }
        set { set("newEditorTabsOpenWith", newValue.rawValue) }
    }
    /// A new editor pane shows the focused pane's file (default) or the
    /// Start Page.
    public var newEditorPanesOpenWith: NewEditorContent {
        get { NewEditorContent(rawValue: get("newEditorPanesOpenWith", NewEditorContent.sameDocument.rawValue)) ?? .sameDocument }
        set { set("newEditorPanesOpenWith", newValue.rawValue) }
    }

    public enum PinEditorTabs: String, CaseIterable, Sendable { case manually = "Manually", automatically = "Automatically" }
    /// Manually: tabs pin only with ⇧⌘P. Automatically: a tab pins when
    /// its document is edited.
    public var pinEditorTabs: PinEditorTabs {
        get { PinEditorTabs(rawValue: get("pinEditorTabs", PinEditorTabs.manually.rawValue)) ?? .manually }
        set { set("pinEditorTabs", newValue.rawValue) }
    }

    /// What a modified click on code does.
    public enum CodeClick: String, CaseIterable, Sendable { case quickHelp = "Shows Quick Help", definition = "Jumps to Definition" }
    /// Click on Code with ⌥ (default: Shows Quick Help).
    public var optionClickOnCode: CodeClick {
        get { CodeClick(rawValue: get("clickOnCodeOption", CodeClick.quickHelp.rawValue)) ?? .quickHelp }
        set { set("clickOnCodeOption", newValue.rawValue) }
    }
    /// Click on Code with ⌘ (default: Jumps to Definition).
    public var commandClickOnCode: CodeClick {
        get { CodeClick(rawValue: get("clickOnCodeCommand", CodeClick.definition.rawValue)) ?? .definition }
        set { set("clickOnCodeCommand", newValue.rawValue) }
    }
    /// Click on Code with ⌃⌘ (default: Jumps to Definition).
    public var commandControlClickOnCode: CodeClick {
        get { CodeClick(rawValue: get("clickOnCodeCommandControl", CodeClick.definition.rawValue)) ?? .definition }
        set { set("clickOnCodeCommandControl", newValue.rawValue) }
    }
    /// The action for a click on code with these modifiers (nil: a plain
    /// click, or modifiers that are not a Click on Code row).
    public func codeClick(for flags: NSEvent.ModifierFlags) -> CodeClick? {
        switch flags.intersection([.command, .option, .control, .shift]) {
        case .option: optionClickOnCode
        case .command: commandClickOnCode
        case [.command, .control]: commandControlClickOnCode
        default: nil
        }
    }

    /// Navigation: where navigator clicks open.
    public enum NavigationDestination: String, CaseIterable, Sendable { case focusedPane = "Focused Editor Pane" }
    /// Where a plain navigator click opens (only the focused pane so far).
    public var navigationDestination: NavigationDestination {
        get { NavigationDestination(rawValue: get("navigationDestination", NavigationDestination.focusedPane.rawValue)) ?? .focusedPane }
        set { set("navigationDestination", newValue.rawValue) }
    }
    /// What a modified (or double) click in a navigator does.
    public enum NavigationTarget: String, CaseIterable, Sendable {
        case sameAsClick = "Same as Click"
        case focusedPane = "Uses Focused Editor Pane"
        case newUnpinnedTab = "Uses New Unpinned Tab"
        case nextPane = "Uses Next Editor Pane"
    }
    /// Navigator click with ⌥ (default: a new unpinned tab).
    public var navigationWithOption: NavigationTarget {
        get { NavigationTarget(rawValue: get("navigationOption", NavigationTarget.newUnpinnedTab.rawValue)) ?? .newUnpinnedTab }
        set { set("navigationOption", newValue.rawValue) }
    }
    /// Navigator click with ⌥⇧ (default: the next editor pane).
    public var navigationWithOptionShift: NavigationTarget {
        get { NavigationTarget(rawValue: get("navigationOptionShift", NavigationTarget.nextPane.rawValue)) ?? .nextPane }
        set { set("navigationOptionShift", newValue.rawValue) }
    }
    /// Navigator double click (default: same as a click).
    public var navigationWithDoubleClick: NavigationTarget {
        get { NavigationTarget(rawValue: get("navigationDoubleClick", NavigationTarget.sameAsClick.rawValue)) ?? .sameAsClick }
        set { set("navigationDoubleClick", newValue.rawValue) }
    }
    /// Where a navigator click with these modifiers (and click count)
    /// opens: the focused pane, a new unpinned tab or the next pane.
    public func navigationTarget(modifiers: NSEvent.ModifierFlags, clickCount: Int = 1) -> NavigationTarget {
        let m = modifiers.intersection([.command, .option, .control, .shift])
        var t: NavigationTarget = .sameAsClick
        if m == [.option, .shift] { t = navigationWithOptionShift } else if m == .option { t = navigationWithOption }
        else if clickCount >= 2 { t = navigationWithDoubleClick }
        return t == .sameAsClick ? .focusedPane : t
    }

    /// Use Window Tabs In Full Screen (stored).
    public var useWindowTabsInFullScreen: Bool { get { get("useWindowTabsInFullScreen", true) } set { set("useWindowTabsInFullScreen", newValue) } }
    /// Animate Open Quickly With Multiple Editor Panes (stored).
    public var animateOpenQuickly: Bool { get { get("animateOpenQuickly", true) } set { set("animateOpenQuickly", newValue) } }

    // MARK: Editing (reference-ui-5.md §9.3)

    /// Saving converts the file to the default encoding (UTF-8) and line
    /// endings (LF).
    public var convertExistingFilesOnSave: Bool { get { get("convertOnSave", false) } set { set("convertOnSave", newValue) } }
    /// Localized Strings: Automatically generate string catalog comments (stored).
    public var generateStringCatalogComments: Bool { get { get("stringCatalogComments", true) } set { set("stringCatalogComments", newValue) } }

    // MARK: Editing ▸ Display

    /// The sticky header showing the enclosing declarations while scrolling.
    public var showCodeStructureHeaders: Bool { get { get("structureHeaders", true) } set { set("structureHeaders", newValue) } }
    /// A line above `// MARK: -`.
    public var showMarkSeparators: Bool { get { get("markSeparators", true) } set { set("markSeparators", newValue) } }
    /// Code coverage iteration counts (stored).
    public var showCoverageCounts: Bool { get { get("coverageCounts", true) } set { set("coverageCounts", newValue) } }
    /// Shows the `#if` condition after `#endif`.
    public var showEndifConditions: Bool { get { get("endifConditions", true) } set { set("endifConditions", newValue) } }
    /// Scope guides; only None is observed so far (§12).
    public enum ScopeGuides: String, CaseIterable, Sendable { case none = "None" }
    /// Editing ▸ Display ▸ Scope guides (None, the only choice so far).
    public var scopeGuides: ScopeGuides {
        get { ScopeGuides(rawValue: get("scopeGuides", "None")) ?? .none }
        set { set("scopeGuides", newValue.rawValue) }
    }
    /// Reformat code at column (Reformat To Width and the guide); the
    /// former page-guide column.
    public var reformatColumn: Int { get { pageGuideColumn } set { pageGuideColumn = newValue } }
    /// Show reformatting guide: the page guide at `reformatColumn`.
    public var showReformattingGuide: Bool { get { showPageGuide } set { showPageGuide = newValue } }
    /// Automatically reformat when completing (stored).
    public var reformatWhenCompleting: Bool { get { get("reformatWhenCompleting", false) } set { set("reformatWhenCompleting", newValue) } }
    /// Inactive `#if` branches drawn dimmed.
    public var dimInactiveCode: Bool { get { get("dimInactiveCode", true) } set { set("dimInactiveCode", newValue) } }

    public enum EditorOverscroll: String, CaseIterable, Sendable {
        case none = "None", small = "Small", medium = "Medium", large = "Large"
        /// The blank space after the last line, as a fraction of the
        /// visible height.
        public var fraction: CGFloat {
            switch self { case .none: 0; case .small: 0.25; case .medium: 0.5; case .large: 0.75 }
        }
    }
    /// Blank space below the last line of the source editor (default Medium).
    public var editorOverscroll: EditorOverscroll {
        get { EditorOverscroll(rawValue: get("editorOverscroll", EditorOverscroll.medium.rawValue)) ?? .medium }
        set { set("editorOverscroll", newValue.rawValue) }
    }
    /// Documentation Comments ▸ Fade delimiters: `///`, `/**`, `*/` of
    /// documentation comments drawn faded.
    public var fadeDocCommentDelimiters: Bool { get { get("fadeDocDelimiters", true) } set { set("fadeDocDelimiters", newValue) } }
    /// Fade comment delimiters: `//`, `/*`, `*/` of other comments.
    public var fadeCommentDelimiters: Bool { get { get("fadeCommentDelimiters", true) } set { set("fadeCommentDelimiters", newValue) } }
}
