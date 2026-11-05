import AppKit
import Foundation
import Testing
@testable import YcodeIDECore
@testable import YcodeUI

/// Screenshots of the macOS IDE's Settings ▸ Accounts for comparison with
/// the Linux IDE's (`ycode-ide`, `YCODE_IDE_ACCOUNTS`). With
/// `YCODE_ACCOUNTS_SHOTS` set to a folder it writes, per appearance,
/// `mac-<appearance>-accounts.png` (the Settings window on Accounts) and
/// `mac-<appearance>-accounts-sheet.png` (the sheet + shows), drawn with
/// `cacheDisplay`, so no window is put on screen. It never runs without
/// the variable.
@MainActor
@Suite(.serialized) struct AccountsPaneShotTests {
    nonisolated static let outDir = ProcessInfo.processInfo.environment["YCODE_ACCOUNTS_SHOTS"]

    @Test func accountsPane() throws {
        let td = TestDefaults("accounts-pane")
        defer { td.remove() }
        let pane = AccountsSettingsPane(prefs: Preferences(defaults: td.defaults))
        _ = pane.view
        pane.addClicked()
        #expect(pane.shownMessage == AccountsPage.explanation(keychain: true))
        let alert = pane.makeAlert()
        #expect(alert.messageText == AccountsPage.sheetTitle && alert.informativeText.contains("never asks for or stores passwords"))
    }

    @Test(.enabled(if: outDir != nil)) func shots() throws {
        _ = NSApplication.shared
        let out = URL(fileURLWithPath: try #require(Self.outDir))
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let td = TestDefaults("accounts-shots")
        defer { td.remove() }
        for appearance in ["light", "dark"] {
            let look = NSAppearance(named: appearance == "dark" ? .darkAqua : .aqua)
            let settings = SettingsWindowController(prefs: Preferences(defaults: td.defaults), components: [])
            let sw = try #require(settings.window)
            sw.appearance = look
            settings.select(try #require(SettingsWindowController.paneTitles.firstIndex(of: AccountsPage.title)))
            #expect(settings.selectedPane == AccountsPage.title)
            try Self.write(try #require(sw.contentView?.superview), "mac-\(appearance)-accounts", to: out)
            let pane = try #require(settings.pane(AccountsSettingsPane.self))
            let alert = pane.makeAlert()
            alert.window.appearance = look
            alert.layout()
            try Self.write(try #require(alert.window.contentView?.superview), "mac-\(appearance)-accounts-sheet", to: out)
            sw.close()
        }
    }

    static func write(_ view: NSView, _ name: String, to out: URL) throws {
        view.layoutSubtreeIfNeeded()
        let rep = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: rep)
        try #require(rep.representation(using: .png, properties: [:])).write(to: out.appendingPathComponent("\(name).png"))
    }
}
