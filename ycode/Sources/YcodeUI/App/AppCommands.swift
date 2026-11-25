import AppKit
import YcodeIDECore

/// Menu commands that need no workspace window (`specs/ide/reference-ui-5.md`
/// §2.1, §2.12, §2.13): documentation links, developer tools, Downloads.
/// The menu builder targets these items here directly.
@MainActor
public final class AppCommands: NSObject {
    public static let shared: AppCommands = {
        restoreQuitPreference()
        return AppCommands()
    }()

    /// Public web pages the Help and Window menus open (Ycode has no
    /// documentation viewer of its own).
    public enum Links {
        public static let developerDocumentation = HelpLinks.developerDocumentation
        public static let humanInterfaceGuidelines = HelpLinks.humanInterfaceGuidelines
        public static let swiftBook = HelpLinks.swiftBook
        public static let moreDeveloperTools = HelpLinks.moreDeveloperTools
        /// The documentation search for a phrase.
        public static func documentationSearch(_ q: String) -> URL? {
            var c = URLComponents(string: "https://developer.apple.com/search/")!
            c.queryItems = [URLQueryItem(name: "q", value: q)]
            return c.url
        }
    }

    /// Where opened URLs go (tests replace it).
    public static var open: (URL) -> Void = { NSWorkspace.shared.open($0) }

    static let actions: Set<String> = [
        "showDeveloperDocumentation:", "showHumanInterfaceGuidelines:", "showSwiftBook:", "openMoreDeveloperTools:",
        "openDeveloperTool:", "showDownloads:", "compareFiles:", "showAboutWindow:", "showYcodeHelp:", "showReleaseNotes:", "reportBug:",
        "terminateKeepingWindows:",
    ]

    public static func handles(_ action: String) -> Bool { actions.contains(action) }

    /// Window / Help ▸ Developer Documentation (⇧⌘0).
    @objc public func showDeveloperDocumentation(_ sender: Any?) { Self.open(Links.developerDocumentation) }
    /// Help ▸ Human Interface Guidelines (⇧⌘H).
    @objc public func showHumanInterfaceGuidelines(_ sender: Any?) { Self.open(Links.humanInterfaceGuidelines) }
    /// Help ▸ The Swift Programming Language.
    @objc public func showSwiftBook(_ sender: Any?) { Self.open(Links.swiftBook) }
    /// Ycode ▸ About Ycode.
    @objc public func showAboutWindow(_ sender: Any?) { AboutWindowController.shared.showWindow(sender) }
    /// Help ▸ Ycode Help: the repository's README.
    @objc public func showYcodeHelp(_ sender: Any?) { Self.open(ProductIdentity.helpURL) }
    /// Help ▸ Release Notes: the repository's releases.
    @objc public func showReleaseNotes(_ sender: Any?) { Self.open(ProductIdentity.releasesURL) }
    /// Help ▸ Report a Bug…: the new-issue page, with the version and platform.
    @objc public func reportBug(_ sender: Any?) { Self.open(ProductIdentity.bugReportURL()) }
    /// Ycode ▸ Open Developer Tool ▸ More Developer Tools….
    @objc public func openMoreDeveloperTools(_ sender: Any?) { Self.open(Links.moreDeveloperTools) }

    /// Ycode ▸ Open Developer Tool ▸ <tool>: opens that application.
    @objc public func openDeveloperTool(_ sender: Any?) {
        guard let url = (sender as? NSMenuItem)?.representedObject as? URL else { return }
        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
    }

    /// The system preference that keeps windows open across a quit.
    static let keepWindowsKey = "NSQuitAlwaysKeepsWindows"
    /// Set while Quit and Keep Windows changed that preference for one quit.
    static let keepWindowsOnceKey = "YcodeQuitKeepsWindowsOnce"

    /// Ycode ▸ Quit and Keep Windows (⌥⌘Q, the ⌥ alternate of Quit, P-002):
    /// quits as Quit does, keeping the open windows for the next launch.
    @objc public func terminateKeepingWindows(_ sender: Any?) {
        let d = UserDefaults.standard
        if d.object(forKey: Self.keepWindowsKey) == nil { d.set(true, forKey: Self.keepWindowsOnceKey) }
        d.set(true, forKey: Self.keepWindowsKey)
        NSApp.terminate(sender)
        // Still running: the quit was cancelled (unsaved changes).
        Self.restoreQuitPreference()
    }

    /// Puts back the preference one Quit and Keep Windows changed (after a
    /// cancelled quit, or at the next launch).
    static func restoreQuitPreference(_ d: UserDefaults = .standard) {
        guard d.bool(forKey: keepWindowsOnceKey) else { return }
        d.removeObject(forKey: keepWindowsKey)
        d.removeObject(forKey: keepWindowsOnceKey)
    }

    /// Window ▸ Downloads (⇧⌘9): Settings ▸ Components.
    @objc public func showDownloads(_ sender: Any?) { SettingsWindowController.shared.show(pane: "Components") }
}

extension AppDelegate {
    /// ⌘W with no workspace window ("Close Tab, Editor Pane, Window Tab,
    /// or Window"): closes the key window (Settings, Organizer, …).
    @objc public func closeTab(_ sender: Any?) { NSApp.keyWindow?.performClose(sender) }

    /// Ycode ▸ Behaviors ▸ Edit Behaviors… with no workspace window.
    @objc public func showBehaviorsSettings(_ sender: Any?) { SettingsWindowController.shared.show(pane: "Behaviors") }

    /// File ▸ Open… (⌘O): the document controller's open panel. The
    /// application delegate answers before the document controller does,
    /// so Open… is enabled whichever controller became the shared one (an
    /// unbundled AppKit controller has no document types and disables it).
    @objc public func openDocument(_ sender: Any?) { NSDocumentController.shared.openDocument(sender) }
}
