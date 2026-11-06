import Foundation
import SwiftUI
#if canImport(UniformTypeIdentifiers)
import UniformTypeIdentifiers
#endif
import YcodeIDECore
import YcodeIDEShell

// Settings ▸ General, Navigation, Notifications and Behaviors on Linux:
// the macOS IDE's panes (YcodeUI `SettingsPanes.swift`,
// `specs/ide/reference-ui-5.md` §9) over the same `Preferences`.

// MARK: General

/// Settings ▸ General (reference-ui-5.md §9.1).
struct GeneralSettingsPane: View {
    @State private var exporting = false
    @State private var importing = false
    @State private var confirmReset = false
    @State private var confirmWarnings = false
    @State private var failure: String?

    /// The Test Parallelization row for the computer Ycode runs on.
    #if os(Linux)
    static let hostTestingTitle = "Testing on My Computer"
    #else
    static let hostTestingTitle = "Testing on Mac"
    #endif

    var body: some View {
        let _ = ShellPreferences.shared.revision
        SettingsForm {
            SettingsSection("Starting Points") {
                CasePicker(title: "Restore open projects and workspaces", selection: setting(\.restoreWindows), target: "settings restore windows",
                           help: Self.restoreHelp)
            }
            SettingsSection("Navigation and Files") {
                CasePicker(title: "Navigator size", selection: setting(\.navigatorSize), target: "settings navigator size")
                detailPicker("Bookmark navigator detail", \.bookmarkNavigatorDetail)
                detailPicker("Find navigator detail", \.findNavigatorDetail)
                detailPicker("Issue navigator detail", \.issueNavigatorDetail)
                CheckRow(title: "Window tabs have independent sidebar widths", isOn: setting(\.independentSidebarWidths),
                         target: "settings sidebar widths", help: Self.sidebarWidthsHelp)
                CheckRow(title: "Automatically unlock files", isOn: setting(\.autoUnlockFiles), target: "settings unlock files")
                CasePicker(title: "File extensions", selection: setting(\.fileExtensions), target: "settings file extensions")
            }
            SettingsSection("Issues") {
                CasePicker(title: "Issue presentation", selection: setting(\.issuePresentation), target: "settings issue presentation")
                CheckRow(title: "Predictive Issues", isOn: setting(\.showLiveIssues), target: "settings live issues")
                CheckRow(title: "Stop build on first error", isOn: setting(\.stopBuildOnFirstError), target: "settings stop on error")
            }
            SettingsSection("Test Parallelization") {
                CasePicker(title: Self.hostTestingTitle, selection: setting(\.testParallelizationMac), target: "settings tests host")
                CasePicker(title: "Testing on Simulator", selection: setting(\.testParallelizationSimulator), target: "settings tests simulator")
            }
            SettingsSection("Report Navigator") {
                PickerRow(title: "Local report history", selection: setting(\.reportHistoryLimit),
                          options: Preferences.reportHistoryChoices.map { ($0, Preferences.reportHistoryTitle($0)) }, target: "settings report history")
            }
            SettingsSection("Settings Import & Export", content: {
                SettingsRow("Settings file") {
                    HStack(spacing: 8) {
                        Button("Export…") { exporting = true }.shellTarget("settings export")
                        Button("Import…") { importing = true }.shellTarget("settings import")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
            }, footer: {
                if let failure { FootNote(text: failure) }
            })
            SettingsSection("Reset Ycode") {
                SettingsRow("Reset Settings") {
                    Button("Reset…") { confirmReset = true }.buttonStyle(.bordered).controlSize(.small).shellTarget("settings reset")
                }
                SettingsRow("\u{201C}Don\u{2019}t ask me\u{201D} warnings") {
                    Button("Reset All") { confirmWarnings = true }.buttonStyle(.bordered).controlSize(.small).shellTarget("settings reset warnings")
                }
            }
        }
        .fileExporter(isPresented: $exporting, document: exporting ? SettingsFile(data: (try? Preferences.shared.exportSettings()) ?? Data()) : nil,
                      contentType: .json, defaultFilename: "Ycode Settings.json") { result in
            if case .failure(let e) = result { failure = "Could not export the settings: \(e.localizedDescription)" }
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.json]) { result in
            guard case .success(let url) = result else { return }
            do {
                try Preferences.shared.importSettings(Data(contentsOf: url))
                failure = nil
            } catch {
                failure = "\u{201C}\(url.lastPathComponent)\u{201D} is not a Ycode settings file."
            }
        }
        .alert("Reset all Ycode settings to their defaults?", isPresented: $confirmReset) {
            Button("Reset", role: .destructive) { Preferences.shared.resetSettings() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(verbatim: "Settings return to their factory values. Themes and recent projects are kept.")
        }
        .alert("Show all warnings you chose not to be asked about again?", isPresented: $confirmWarnings) {
            Button("Reset", role: .destructive) { Preferences.shared.resetSuppressedWarnings() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(verbatim: "Warnings you suppressed with \u{201C}Don\u{2019}t ask me\u{201D} will be shown again.")
        }
    }

    func detailPicker(_ title: String, _ key: ReferenceWritableKeyPath<Preferences, Int>) -> some View {
        PickerRow(title: title, selection: setting(key), options: Preferences.detailLineChoices.map { ($0, Preferences.detailTitle($0)) },
                  target: "settings \(title.lowercased())")
    }

    /// The help under Restore open projects and workspaces (the macOS
    /// IDE's text, with the desktop's own setting named).
    #if os(Linux)
    static let restoreHelp = "Use System Setting reopens them, as the desktop restores its other apps' windows."
    #else
    static let restoreHelp = "Use System Setting reopens them unless \u{201C}Close windows when quitting an application\u{201D} is on in "
        + "System Settings \u{25B8} Desktop & Dock."
    #endif
    /// The help under Window tabs have independent sidebar widths.
    static let sidebarWidthsHelp = "Each tab of a window keeps its own navigator and inspector widths, so the tab bar moves when you "
        + "switch between tabs."
}

/// A file of bytes for the file dialogs' Export.
struct SettingsFile: FileDocument {
    static var readableContentTypes: [UTType] { [.json] }
    var data: Data

    init(data: Data) { self.data = data }

    init(configuration: ReadConfiguration) throws {
        data = configuration.file.regularFileContents ?? Data()
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper { FileWrapper(regularFileWithContents: data) }
}

// MARK: Navigation

/// Settings ▸ Navigation (reference-ui-5.md §9.2).
struct NavigationSettingsPane: View {
    var body: some View {
        let _ = ShellPreferences.shared.revision
        SettingsForm {
            SettingsSection {
                CasePicker(title: "New Editor Tabs Open With", selection: setting(\.newEditorTabsOpenWith), target: "settings new tabs")
                CasePicker(title: "New Editor Panes Open With", selection: setting(\.newEditorPanesOpenWith), target: "settings new panes")
                CasePicker(title: "Pin Editor Tabs", selection: setting(\.pinEditorTabs), target: "settings pin tabs")
            }
            SettingsSection("Click on Code") {
                CasePicker(title: "With \(Self.option)", selection: setting(\.optionClickOnCode), target: "settings click option")
                CasePicker(title: "With \(Self.command)", selection: setting(\.commandClickOnCode), target: "settings click command")
                CasePicker(title: "With \(Self.command) & \(Self.control)", selection: setting(\.commandControlClickOnCode),
                           target: "settings click command control")
            }
            SettingsSection("Navigation") {
                CasePicker(title: "Destination", selection: setting(\.navigationDestination), target: "settings destination")
                CasePicker(title: "With \(Self.option)", selection: setting(\.navigationWithOption), target: "settings navigation option")
                CasePicker(title: "With \(Self.option) & Shift", selection: setting(\.navigationWithOptionShift),
                           target: "settings navigation option shift")
                CasePicker(title: "With Double-click", selection: setting(\.navigationWithDoubleClick), target: "settings navigation double")
            }
            SettingsSection {
                CheckRow(title: "Use Window Tabs In Full Screen", isOn: setting(\.useWindowTabsInFullScreen), target: "settings full screen tabs")
                CheckRow(title: "Animate Open Quickly With Multiple Editor Panes", isOn: setting(\.animateOpenQuickly),
                         target: "settings animate open quickly")
            }
        }
    }

    // The modifier keys' names on the host's keyboard (on Linux ⌘ is Ctrl,
    // ⌥ Alt and ⌃ Super; ShortcutNotation).
    #if os(Linux)
    static let option = "Alt", command = "Ctrl", control = "Super"
    #else
    static let option = "Option", command = "Command", control = "Control"
    #endif
}

// MARK: Notifications

/// Settings ▸ Notifications: one checkbox per event, its Behaviors Notify
/// action.
struct NotificationsSettingsPane: View {
    var body: some View {
        let _ = ShellPreferences.shared.revision
        SettingsForm {
            ForEach(["Build", "Testing", "Running"], id: \.self) { category in
                SettingsSection(category) {
                    ForEach(Preferences.Event.allCases.filter { $0.category == category }, id: \.self) { e in
                        CheckRow(title: e.notificationTitle, isOn: Binding(get: { Preferences.shared.behavior(e).notify }, set: { on in
                            var b = Preferences.shared.behavior(e)
                            b.notify = on
                            Preferences.shared.setBehavior(b, for: e)
                        }), target: "settings notify \(e)")
                    }
                }
            }
            SettingsNote(text: "A notification is the result bezel over the workspace window, or a desktop notification when Ycode is not in front.")
        }
    }
}

// MARK: Behaviors

/// Settings ▸ Behaviors: the events by category with their actions; an
/// event opens its page, where each action is set.
struct BehaviorsSettingsPane: View {
    @Bindable var model: ShellSettingsModel

    /// The categories that have Ycode events.
    static let categories = ["Build", "Testing", "Running"]

    var body: some View {
        let _ = ShellPreferences.shared.revision
        if let e = model.behaviorEvent {
            BehaviorEventPage(event: e) { model.behaviorEvent = nil }
        } else {
            SettingsForm {
                ForEach(Self.categories, id: \.self) { c in
                    let events = Preferences.Event.allCases.filter { $0.category == c }
                    let n = events.filter { !Preferences.shared.behavior($0).actionTitles.isEmpty }.count
                    SettingsSection("\(c)  \u{00B7}  \(n) behavior\(n == 1 ? "" : "s")") {
                        ForEach(events, id: \.self) { e in
                            DrillRow(title: e.rawValue, detail: Self.summary(Preferences.shared.behavior(e)), target: "settings behavior \(e)") {
                                model.behaviorEvent = e
                            }
                        }
                    }
                }
                SettingsNote(text: "Ycode raises no events in \(Preferences.behaviorCategories.filter { !Self.categories.contains($0) }.joined(separator: ", ")) yet.")
            }
        }
    }

    /// The actions in a few words ("Notify, Issue Navigator").
    static func summary(_ b: Preferences.Behavior) -> String {
        var parts: [String] = []
        if let n = b.showNavigator, CommandTable.navigators.indices.contains(n) { parts.append(CommandTable.navigators[n]) }
        if let d = b.showDebugArea { parts.append(d ? "Show debugger" : "Hide debugger") }
        if b.hideDebugAreaIfNoOutput { parts.append("Hide debugger if no output") }
        if let s = b.sound { parts.append("Sound \(s)") }
        if b.notify { parts.append("Notify") }
        return parts.isEmpty ? "No actions" : parts.joined(separator: ", ")
    }
}

/// One event's actions.
struct BehaviorEventPage: View {
    var event: Preferences.Event
    var back: () -> Void

    /// The debug area choices: no change, show, hide, hide if the run
    /// printed nothing.
    enum DebugArea: String, CaseIterable { case none = "No Change", show = "Show", hide = "Hide", hideIfNoOutput = "Hide If No Output" }

    var body: some View {
        let _ = ShellPreferences.shared.revision
        let b = Preferences.shared.behavior(event)
        SettingsForm {
            BackRow(title: "Behaviors", target: "settings behaviors back", action: back)
            SettingsSection(event.category) {
                ValueRow(title: "Event", value: event.rawValue)
                PickerRow(title: "Show navigator", selection: binding(\.showNavigator, b),
                          options: [(Int?.none, "None")] + CommandTable.navigators.enumerated().map { (Int?.some($0.offset), $0.element) },
                          target: "settings behavior navigator")
                PickerRow(title: "Debug area", selection: Binding(get: { Self.debugArea(b) }, set: { d in
                    update { b in
                        b.showDebugArea = d == .show ? true : (d == .hide ? false : nil)
                        b.hideDebugAreaIfNoOutput = d == .hideIfNoOutput
                    }
                }), options: DebugArea.allCases.map { ($0, $0.rawValue) }, target: "settings behavior debug area")
                PickerRow(title: "Play sound", selection: binding(\.sound, b),
                          options: [(String?.none, "None")] + Preferences.Behavior.soundNames.map { (String?.some($0), $0) }, target: "settings behavior sound")
                CheckRow(title: "Notify with bezel or desktop notification", isOn: binding(\.notify, b), target: "settings behavior notify")
            }
            SettingsSection {
                SettingsRow("Default actions") {
                    Button("Restore Default Actions") {
                        Preferences.shared.setBehavior(Preferences.defaultBehaviors[event] ?? Preferences.Behavior(), for: event)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(b == (Preferences.defaultBehaviors[event] ?? Preferences.Behavior()))
                    .shellTarget("settings behavior restore")
                }
            }
        }
    }

    static func debugArea(_ b: Preferences.Behavior) -> DebugArea {
        if b.hideDebugAreaIfNoOutput { return .hideIfNoOutput }
        return b.showDebugArea.map { $0 ? .show : .hide } ?? .none
    }

    func binding<T>(_ key: WritableKeyPath<Preferences.Behavior, T>, _ b: Preferences.Behavior) -> Binding<T> {
        Binding(get: { b[keyPath: key] }, set: { v in update { $0[keyPath: key] = v } })
    }

    func update(_ f: (inout Preferences.Behavior) -> Void) {
        var b = Preferences.shared.behavior(event)
        f(&b)
        Preferences.shared.setBehavior(b, for: event)
    }
}
