import AppKit

/// User settings beyond Locations, kept in `UserDefaults` (key prefix
/// `Ycode.`). Changing any value posts `Preferences.didChange`; open
/// editors, consoles, windows and the menu bar apply it at once. See
/// `specs/ide/settings.md`.
@MainActor
public final class Preferences {
    public static let didChange = Notification.Name("YcodePreferencesDidChange")
    public static var shared = Preferences()

    public let defaults: UserDefaults
    /// Where user themes (`.ycodetheme`) live.
    public let themesDirectory: URL

    public init(defaults: UserDefaults = .standard, themesDirectory: URL? = nil) {
        self.defaults = defaults
        self.themesDirectory = themesDirectory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Ycode/Themes")
    }

    func changed() { NotificationCenter.default.post(name: Self.didChange, object: self) }

    func get<T>(_ key: String, _ fallback: T) -> T { defaults.object(forKey: "Ycode.\(key)") as? T ?? fallback }
    func set(_ key: String, _ value: Any?) { defaults.set(value, forKey: "Ycode.\(key)"); changed() }

    // MARK: General

    public enum Appearance: String, CaseIterable, Sendable { case system = "System", light = "Light", dark = "Dark" }
    public var appearance: Appearance {
        get { Appearance(rawValue: get("appearance", "System")) ?? .system }
        set { set("appearance", newValue.rawValue) }
    }
    /// The NSAppearance to apply (nil follows the system).
    public var nsAppearance: NSAppearance? {
        switch appearance { case .system: nil; case .light: NSAppearance(named: .aqua); case .dark: NSAppearance(named: .darkAqua) }
    }
    public enum FileExtensions: String, CaseIterable, Sendable { case hide = "Hide All", show = "Show All" }
    /// Settings ▸ General ▸ File extensions; Hide All is the factory
    /// default (reference-ui-5.md §5.1, N2).
    public var fileExtensions: FileExtensions {
        get { FileExtensions(rawValue: get("fileExtensions", FileExtensions.hide.rawValue)) ?? .hide }
        set { set("fileExtensions", newValue.rawValue) }
    }
    /// Issues: show live issues (language server) in the editor and navigator.
    public var showLiveIssues: Bool { get { get("showLiveIssues", true) } set { set("showLiveIssues", newValue) } }

    // MARK: Behaviors

    public enum Event: String, CaseIterable, Sendable {
        case buildStarts = "When build starts", buildErrors = "When build generates errors"
        case buildWarnings = "When build generates warnings", buildSucceeds = "When build succeeds", buildFails = "When build fails"
        case runStarts = "When running starts", runPauses = "When running pauses", runOutput = "When running generates output"
        case runEnds = "When running completes", runExitsUnexpectedly = "When running exits unexpectedly"

        /// The Behaviors category the event belongs to.
        public var category: String { rawValue.contains("build") ? "Build" : "Running" }
    }

    /// Behaviors categories in reference-ui.md §4 order, then Intelligence
    /// and Playgrounds (reference-ui-5.md §9.4); Ycode's own events exist
    /// for Build and Running, the others are listed empty.
    public static let behaviorCategories = ["Build", "Testing", "Running", "Search", "Localization Import / Export", "File",
                                            "Intelligence", "Playgrounds"]

    /// Behaviors action labels (reference-ui-5.md §9.4).
    nonisolated public static let showDebuggerAction = "Debugger: Show Current Views"
    nonisolated public static let hideDebuggerAction = "Debugger: Hide Debugger"
    nonisolated public static let hideDebuggerIfNoOutputAction = "Debugger: Hide Debugger If No Output"
    nonisolated public static let notifyAction = "Notify with bezel or system notification"

    /// What happens on an event.
    public struct Behavior: Codable, Equatable, Sendable {
        /// Navigator index to show (0 Project … 8 Report), nil = none.
        public var showNavigator: Int?
        public var showDebugArea: Bool?
        /// A system sound name (e.g. "Glass"), nil = none.
        public var sound: String?
        public var notify = false
        /// Running completes: hide the debug area only if the run printed nothing.
        public var hideDebugAreaIfNoOutput = false
        public init(showNavigator: Int? = nil, showDebugArea: Bool? = nil, sound: String? = nil, notify: Bool = false,
                    hideDebugAreaIfNoOutput: Bool = false) {
            self.showNavigator = showNavigator
            self.showDebugArea = showDebugArea
            self.sound = sound
            self.notify = notify
            self.hideDebugAreaIfNoOutput = hideDebugAreaIfNoOutput
        }
        public init(from d: Decoder) throws {
            let c = try d.container(keyedBy: CodingKeys.self)
            showNavigator = try c.decodeIfPresent(Int.self, forKey: .showNavigator)
            showDebugArea = try c.decodeIfPresent(Bool.self, forKey: .showDebugArea)
            sound = try c.decodeIfPresent(String.self, forKey: .sound)
            notify = try c.decodeIfPresent(Bool.self, forKey: .notify) ?? false
            hideDebugAreaIfNoOutput = try c.decodeIfPresent(Bool.self, forKey: .hideDebugAreaIfNoOutput) ?? false
        }

        /// The actions as the Behaviors pane lists them.
        public var actionTitles: [String] {
            var a: [String] = []
            if let n = showNavigator, CommandTable.navigators.indices.contains(n) { a.append("Navigator: \(CommandTable.navigators[n])") }
            if let d = showDebugArea { a.append(d ? Preferences.showDebuggerAction : Preferences.hideDebuggerAction) }
            if hideDebugAreaIfNoOutput { a.append(Preferences.hideDebuggerIfNoOutputAction) }
            if let s = sound { a.append("Play Sound: \(s)") }
            if notify { a.append(Preferences.notifyAction) }
            return a
        }
    }

    /// Defaults (reference-ui.md §4): errors show the Issues navigator;
    /// success and failure notify; pausing shows the Debug navigator and
    /// the debug area; output shows the debug area; completion hides it
    /// only when there was no output.
    public static let defaultBehaviors: [Event: Behavior] = [
        .buildErrors: Behavior(showNavigator: 4), .buildSucceeds: Behavior(notify: true), .buildFails: Behavior(notify: true),
        .runPauses: Behavior(showNavigator: 6, showDebugArea: true), .runOutput: Behavior(showDebugArea: true),
        .runEnds: Behavior(hideDebugAreaIfNoOutput: true),
    ]

    public func behavior(_ e: Event) -> Behavior {
        if let data = defaults.data(forKey: "Ycode.behavior.\(e)"), let b = try? JSONDecoder().decode(Behavior.self, from: data) { return b }
        return Self.defaultBehaviors[e] ?? Behavior()
    }

    public func setBehavior(_ b: Behavior, for e: Event) {
        defaults.set(try? JSONEncoder().encode(b), forKey: "Ycode.behavior.\(e)")
        changed()
    }

    // MARK: Navigation

    // The Navigation pane's rows (reference-ui-5.md §9.2) are in
    // Preferences+Reference.swift; they replace Activation and Navigation Style.

    // MARK: Text editing

    public var showLineNumbers: Bool { get { get("lineNumbers", true) } set { set("lineNumbers", newValue) } }
    public var showFoldingRibbon: Bool { get { get("foldingRibbon", false) } set { set("foldingRibbon", newValue) } }
    public var showMinimap: Bool { get { get("minimap", false) } set { set("minimap", newValue) } }
    public var showPageGuide: Bool { get { get("pageGuide", false) } set { set("pageGuide", newValue) } }
    public var pageGuideColumn: Int { get { get("pageGuideColumn", 80) } set { set("pageGuideColumn", max(1, newValue)) } }
    public var indentWithTabs: Bool { get { get("indentWithTabs", false) } set { set("indentWithTabs", newValue) } }
    public var tabWidth: Int { get { get("tabWidth", 4) } set { set("tabWidth", max(1, min(16, newValue))) } }
    public var indentWidth: Int { get { get("indentWidth", 4) } set { set("indentWidth", max(1, min(16, newValue))) } }
    public var trimTrailingWhitespace: Bool { get { get("trimWhitespace", true) } set { set("trimWhitespace", newValue) } }
    public var wrapLines: Bool { get { get("wrapLines", true) } set { set("wrapLines", newValue) } }
    /// Spaces wrapped lines are indented by (Editing ▸ Display).
    public var wrappedLineIndent: Int { get { get("wrappedLineIndent", 4) } set { set("wrappedLineIndent", max(0, min(16, newValue))) } }
    public var highlightSelectedSymbol: Bool { get { get("highlightSelectedSymbol", true) } set { set("highlightSelectedSymbol", newValue) } }
    /// Seconds before instances of the selected symbol are highlighted.
    public var highlightDelay: Double { get { get("highlightDelay", 0.25) } set { set("highlightDelay", max(0, min(5, newValue))) } }
    public var trimWhitespaceOnlyLines: Bool { get { get("trimWhitespaceOnlyLines", false) } set { set("trimWhitespaceOnlyLines", newValue) } }

    /// Editor ▸ Font Size (`reference-ui-5.md` §6.4): the source editor's
    /// font size for every editor, nil = the theme's size. A user setting,
    /// not a theme edit.
    public var sourceFontSize: Double? {
        get { (defaults.object(forKey: "Ycode.sourceFontSize") as? NSNumber)?.doubleValue }
        set { set("sourceFontSize", newValue.map { max(Self.fontSizeRange.lowerBound, min(Self.fontSizeRange.upperBound, $0)) }) }
    }
    /// Font Size ▸ Increase / Decrease stay within these sizes.
    public static let fontSizeRange: ClosedRange<Double> = 6...48

    /// One indentation step as text.
    public var indentUnit: String { indentWithTabs ? "\t" : String(repeating: " ", count: indentWidth) }

    // MARK: Source control

    public var sourceControlEnabled: Bool { get { get("sourceControl", true) } set { set("sourceControl", newValue) } }

    // MARK: Debugger

    /// Variables view: also list register scopes.
    public var showRegisters: Bool { get { get("showRegisters", false) } set { set("showRegisters", newValue) } }

    // MARK: Themes

    public var themeName: String {
        get { get("theme", EditorTheme.builtIns[0].name) }
        set { set("theme", newValue) }
    }

    /// Built-in themes, then user themes (by name).
    public var themes: [EditorTheme] {
        let user = ((try? FileManager.default.contentsOfDirectory(at: themesDirectory, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension == "ycodetheme" }
            .compactMap { try? EditorTheme.read($0) }
            .sorted { $0.name < $1.name }
        return EditorTheme.builtIns + user.filter { u in !EditorTheme.builtIns.contains { $0.name == u.name } }
    }

    public var theme: EditorTheme { themes.first { $0.name == themeName } ?? EditorTheme.builtIns[0] }

    /// Saves a user theme (built-in names are refused) and selects it.
    public func save(_ t: EditorTheme) throws {
        guard !EditorTheme.builtIns.contains(where: { $0.name == t.name }) else { throw CocoaError(.fileWriteNoPermission) }
        try FileManager.default.createDirectory(at: themesDirectory, withIntermediateDirectories: true)
        try t.write(to: themesDirectory.appendingPathComponent(t.fileName))
        themeName = t.name
    }

    /// Duplicate: a copy named "<name> Copy" (numbered when taken).
    @discardableResult
    public func duplicate(_ t: EditorTheme) throws -> EditorTheme {
        var copy = t
        var n = "\(t.name) Copy", i = 2
        while themes.contains(where: { $0.name == n }) { n = "\(t.name) Copy \(i)"; i += 1 }
        copy.name = n
        try save(copy)
        return copy
    }

    public func deleteTheme(named name: String) {
        guard let t = themes.first(where: { $0.name == name }), !EditorTheme.builtIns.contains(where: { $0.name == name }) else { return }
        try? FileManager.default.removeItem(at: themesDirectory.appendingPathComponent(t.fileName))
        if themeName == name { themeName = EditorTheme.builtIns[0].name } else { changed() }
    }

    /// Import: copies a `.ycodetheme` file into the themes folder.
    @discardableResult
    public func importTheme(from url: URL) throws -> EditorTheme {
        let t = try EditorTheme.read(url)
        try save(t)
        return t
    }

    public func exportTheme(_ t: EditorTheme, to url: URL) throws { try t.write(to: url) }

    // MARK: Key bindings

    /// Custom shortcuts by command id (`action#tag`): `"⇧⌘K"`-style text
    /// is not stored; `key` and modifier bits are.
    public struct Shortcut: Codable, Equatable, Hashable, Sendable {
        public var key: String
        public var modifiers: Int
        public init(key: String, modifiers: MenuCommand.Modifiers) {
            self.key = key.lowercased()
            self.modifiers = modifiers.rawValue
        }
        public var mods: MenuCommand.Modifiers { MenuCommand.Modifiers(rawValue: modifiers) }
    }

    public var keyBindingOverrides: [String: Shortcut] {
        get {
            guard let d = defaults.data(forKey: "Ycode.keyBindings"), let m = try? JSONDecoder().decode([String: Shortcut].self, from: d) else { return [:] }
            return m
        }
        set { defaults.set(try? JSONEncoder().encode(newValue), forKey: "Ycode.keyBindings"); changed() }
    }
}

/// A source editor and console theme (`.ycodetheme`, JSON). Colors are
/// `#RRGGBB` hex; an empty map entry falls back to the system color.
public struct EditorTheme: Codable, Equatable, Sendable {
    public var name: String
    public var fontName: String
    public var fontSize: Double
    public var background: String?
    public var foreground: String?
    public var selection: String?
    public var currentLine: String?
    /// Token colors by `SourceTokenizer.Kind` raw name.
    public var tokens: [String: String]
    public var consoleFontName: String
    public var consoleFontSize: Double
    public var consoleBackground: String?
    public var consoleText: String?
    /// Per token kind (`SourceTokenizer.Kind` raw name): a font other than
    /// the source font (Settings ▸ Appearance ▸ Fonts). Absent: the source
    /// font (keywords bold).
    public var tokenFonts: [String: FontSpec]? = nil

    /// A font by name (empty: the monospaced system font) and size.
    public struct FontSpec: Codable, Equatable, Sendable {
        public var name: String
        public var size: Double
        public init(name: String, size: Double) {
            self.name = name
            self.size = size
        }
        public var font: NSFont {
            let s = CGFloat(size)
            return name.isEmpty ? .monospacedSystemFont(ofSize: s, weight: .regular) : (NSFont(name: name, size: s) ?? .monospacedSystemFont(ofSize: s, weight: .regular))
        }
    }

    public var fileName: String { name.replacingOccurrences(of: "/", with: "-") + ".ycodetheme" }

    public static func read(_ url: URL) throws -> EditorTheme {
        try JSONDecoder().decode(EditorTheme.self, from: Data(contentsOf: url))
    }

    public func write(to url: URL) throws {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        try e.encode(self).write(to: url, options: .atomic)
    }

    public var font: NSFont {
        let size = CGFloat(fontSize)
        return fontName.isEmpty ? .monospacedSystemFont(ofSize: size, weight: .regular) : (NSFont(name: fontName, size: size) ?? .monospacedSystemFont(ofSize: size, weight: .regular))
    }

    public var consoleFont: NSFont {
        let size = CGFloat(consoleFontSize)
        return consoleFontName.isEmpty ? .monospacedSystemFont(ofSize: size, weight: .regular) : (NSFont(name: consoleFontName, size: size) ?? .monospacedSystemFont(ofSize: size, weight: .regular))
    }

    public static func color(_ hex: String?) -> NSColor? {
        guard var h = hex?.trimmingCharacters(in: .whitespaces), !h.isEmpty else { return nil }
        if h.hasPrefix("#") { h.removeFirst() }
        guard h.count == 6, let v = UInt32(h, radix: 16) else { return nil }
        return NSColor(srgbRed: CGFloat(v >> 16 & 0xFF) / 255, green: CGFloat(v >> 8 & 0xFF) / 255, blue: CGFloat(v & 0xFF) / 255, alpha: 1)
    }

    public static func hex(_ c: NSColor) -> String {
        let s = c.usingColorSpace(.sRGB) ?? c
        return String(format: "#%02X%02X%02X", Int((s.redComponent * 255).rounded()), Int((s.greenComponent * 255).rounded()), Int((s.blueComponent * 255).rounded()))
    }

    /// Ycode's own themes (colors chosen for Ycode, not taken from any
    /// other product). "Ycode Default" uses system colors (follows light
    /// and dark appearance).
    public static let builtIns: [EditorTheme] = [
        EditorTheme(name: "Ycode Default", fontName: "", fontSize: 12, background: nil, foreground: nil, selection: nil, currentLine: nil,
                    tokens: [:], consoleFontName: "", consoleFontSize: 11, consoleBackground: nil, consoleText: nil),
        EditorTheme(name: "Ycode Paper", fontName: "", fontSize: 13, background: "#FBF8F1", foreground: "#2B2A27", selection: "#E3DCC8", currentLine: "#F2ECDD",
                    tokens: ["keyword": "#8A2D5E", "comment": "#8C8778", "docComment": "#5E7A3A", "string": "#A3471B", "number": "#2F5E9E",
                             "preprocessor": "#9A5B12", "attribute": "#6E5A2E", "typeName": "#4E3F94"],
                    consoleFontName: "", consoleFontSize: 11, consoleBackground: "#FBF8F1", consoleText: "#2B2A27"),
        EditorTheme(name: "Ycode Dusk", fontName: "", fontSize: 12, background: "#1E2128", foreground: "#D8DCE3", selection: "#3A4252", currentLine: "#262A33",
                    tokens: ["keyword": "#E58AB8", "comment": "#7A8291", "docComment": "#93B87A", "string": "#E9A37A", "number": "#8DB4F0",
                             "preprocessor": "#E2B86B", "attribute": "#C9A97A", "typeName": "#B9A6F2"],
                    consoleFontName: "", consoleFontSize: 11, consoleBackground: "#1A1C22", consoleText: "#D8DCE3"),
        EditorTheme(name: "Ycode High Contrast", fontName: "", fontSize: 13, background: "#000000", foreground: "#FFFFFF", selection: "#264F9E", currentLine: "#1A1A1A",
                    tokens: ["keyword": "#FF6FB5", "comment": "#B0B0B0", "docComment": "#7CFC7C", "string": "#FFB070", "number": "#7FD4FF",
                             "preprocessor": "#FFD75E", "attribute": "#E8C890", "typeName": "#C8A8FF"],
                    consoleFontName: "", consoleFontSize: 12, consoleBackground: "#000000", consoleText: "#FFFFFF"),
    ]
}

/// Every menu command and its effective shortcut (Settings ▸ Key Bindings).
@MainActor
public enum KeyBindings {
    public struct Entry: Equatable, Sendable {
        public var id: String
        public var title: String
        public var menu: String
        public var command: MenuCommand
        /// Whether the user changed it.
        public var customized: Bool
    }

    /// `action#tag`, unique per command.
    static func id(_ c: MenuCommand) -> String { "\(c.action)#\(c.tag)" }

    /// The menu commands with overrides applied, in menu order. Commands
    /// Ycode does not perform are left out unless `includingUnavailable`.
    public static func entries(_ prefs: Preferences = .shared, includingUnavailable: Bool = false) -> [Entry] {
        let overrides = prefs.keyBindingOverrides
        var out: [Entry] = []
        func walk(_ items: [MenuItemSpec], _ path: String) {
            for i in items {
                switch i {
                case .separator, .label: break
                case .submenu(let t, let sub): walk(sub, path + " ▸ " + t)
                case .command(var c) where c.isAvailable || includingUnavailable:
                    let id = id(c)
                    if let o = overrides[id] { c.key = o.key; c.modifiers = o.key.isEmpty ? [] : o.mods }
                    out.append(Entry(id: id, title: c.title, menu: path, command: c, customized: overrides[id] != nil))
                case .command: break
                }
            }
        }
        for (menu, items) in CommandTable.menus { walk(items, menu) }
        return out
    }

    /// Entries whose title or menu contains the query (case-insensitive).
    public static func search(_ q: String, _ prefs: Preferences = .shared) -> [Entry] {
        let t = q.lowercased()
        return entries(prefs).filter { t.isEmpty || $0.title.lowercased().contains(t) || $0.menu.lowercased().contains(t) || $0.command.shortcutText.lowercased().contains(t) }
    }

    /// Other commands already using a shortcut (the same keystroke in any
    /// spelling, "⌘{" = "⇧⌘["). Commands Ycode lists disabled keep their
    /// reference shortcut, so they count too (reference-ui-5.md §1.1).
    public static func conflicts(key: String, modifiers: MenuCommand.Modifiers, excluding id: String, _ prefs: Preferences = .shared) -> [Entry] {
        guard !key.isEmpty else { return [] }
        let wanted = Shortcut.canonical(key: key, modifiers: modifiers)
        // A command listed in two menus (Window and Help ▸ Developer Documentation) is one conflict.
        var seen = Set<String>()
        return entries(prefs, includingUnavailable: true).filter {
            $0.id != id && $0.command.canonicalShortcut == wanted && seen.insert($0.id).inserted
        }
    }

    /// Sets (or clears, with an empty key) a command's shortcut. Returns
    /// the conflicting commands; nothing is saved when there are any.
    @discardableResult
    public static func set(_ id: String, key: String, modifiers: MenuCommand.Modifiers, _ prefs: Preferences = .shared) -> [Entry] {
        let c = conflicts(key: key, modifiers: modifiers, excluding: id, prefs)
        guard c.isEmpty else { return c }
        var o = prefs.keyBindingOverrides
        o[id] = Preferences.Shortcut(key: key, modifiers: key.isEmpty ? [] : modifiers)
        prefs.keyBindingOverrides = o
        return []
    }

    public static func reset(_ id: String, _ prefs: Preferences = .shared) {
        var o = prefs.keyBindingOverrides
        o[id] = nil
        prefs.keyBindingOverrides = o
    }

    /// The effective shortcut for a menu command.
    public static func effective(_ c: MenuCommand, _ prefs: Preferences = .shared) -> MenuCommand {
        guard let o = prefs.keyBindingOverrides[id(c)] else { return c }
        var c = c
        c.key = o.key
        c.modifiers = o.key.isEmpty ? [] : o.mods
        return c
    }
}
