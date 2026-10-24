import AppKit

/// Menu commands that need no workspace window (`specs/ide/reference-ui-5.md`
/// §2.1, §2.12, §2.13): documentation links, developer tools, Downloads.
/// The menu builder targets these items here directly.
@MainActor
public final class AppCommands: NSObject {
    public static let shared = AppCommands()

    /// Public web pages the Help and Window menus open (Ycode has no
    /// documentation viewer of its own).
    public enum Links {
        public static let developerDocumentation = URL(string: "https://developer.apple.com/documentation/")!
        public static let humanInterfaceGuidelines = URL(string: "https://developer.apple.com/design/human-interface-guidelines/")!
        public static let swiftBook = URL(string: "https://docs.swift.org/swift-book/")!
        public static let moreDeveloperTools = URL(string: "https://developer.apple.com/download/all/")!
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
        "openDeveloperTool:", "showDownloads:",
    ]

    public static func handles(_ action: String) -> Bool { actions.contains(action) }

    /// Window / Help ▸ Developer Documentation (⇧⌘0).
    @objc public func showDeveloperDocumentation(_ sender: Any?) { Self.open(Links.developerDocumentation) }
    /// Help ▸ Human Interface Guidelines (⇧⌘H).
    @objc public func showHumanInterfaceGuidelines(_ sender: Any?) { Self.open(Links.humanInterfaceGuidelines) }
    /// Help ▸ The Swift Programming Language.
    @objc public func showSwiftBook(_ sender: Any?) { Self.open(Links.swiftBook) }
    /// Ycode ▸ Open Developer Tool ▸ More Developer Tools….
    @objc public func openMoreDeveloperTools(_ sender: Any?) { Self.open(Links.moreDeveloperTools) }

    /// Ycode ▸ Open Developer Tool ▸ <tool>: opens that application.
    @objc public func openDeveloperTool(_ sender: Any?) {
        guard let url = (sender as? NSMenuItem)?.representedObject as? URL else { return }
        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
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
}
