import Foundation
import SwiftUI
import YcodeIDECore
import YcodeIDEShell
#if os(Linux)
import OVPlatform
#endif

// Settings ▸ Accounts automation (OpenViews only), started from ShellDriver:
//
//   YCODE_IDE_ACCOUNTS=<p>  open Settings with Ctrl+,, check the pane list's
//                           order, click Accounts in it, photograph the page
//                           (<p>-accounts.png), click + and photograph the
//                           sheet (<p>-accounts-sheet.png), dismiss it with
//                           OK, then the same two in the Dark appearance
//                           (<p>-dark-accounts*.png). Prints one
//                           "accounts: …" line per step and "accounts: ok"
//                           or "accounts: FAILED …" at the end.
//
// Run it with XDG_CONFIG_HOME pointing at a scratch folder: the appearance
// it sets is written to the user defaults.

#if os(Linux)
@MainActor
enum AccountsDriver {
    static var say: (String) -> Void { ShellDriver.say }

    static func run(prefix: String) async {
        var failures: [String] = []
        func check(_ ok: Bool, _ what: String) {
            say("accounts: \(what) \(ok ? "yes" : "NO")")
            if !ok { failures.append(what) }
        }

        let panes = ShellSettingsPane.allCases.map(\.title)
        say("accounts: panes \(panes)")
        check(panes == SettingsPaneOrder.linux, "pane order is the spec's")

        OpenViewsAutomation.press(.character(","), modifiers: [.control])
        for _ in 0..<20 where OpenViewsAutomation.windowCount < 2 { await ShellDriver.pause(0.2) }
        guard OpenViewsAutomation.windowCount >= 2 else {
            say("accounts: FAILED the Settings window did not open")
            return
        }
        await ShellDriver.pause(0.8)
        let model = ShellSettingsModel.shared
        let prefs = Preferences.shared
        let appearance = prefs.appearance

        for dark in [false, true] {
            prefs.appearance = dark ? .dark : .light
            let name = dark ? "dark-accounts" : "accounts"
            if model.pane == .accounts { await SettingsDriver.open(.general) }
            await SettingsDriver.open(.accounts)
            check(model.pane == .accounts, "\(name) shown")
            await ShellDriver.pause(0.4)
            let texts = OpenViewsAutomation.texts(1).map(\.text)
            check(texts.contains(AccountsPage.emptyText), "\(name) says \(AccountsPage.emptyText)")
            if let add = SettingsDriver.frame("settings accounts add") { say("accounts: + \(add.width)x\(add.height) pt at \(add.origin)") }
            await SettingsDriver.shot(prefix, name)

            await SettingsDriver.click("settings accounts add")
            await ShellDriver.pause(0.4)
            check(model.isAccountsSheetShown, "\(name) + shows the sheet")
            let sheet = OpenViewsAutomation.texts(1).map(\.text)
            check(sheet.contains(AccountsPage.sheetTitle), "\(name) sheet title")
            check(sheet.contains(AccountsPage.explanation), "\(name) sheet explanation")
            await SettingsDriver.shot(prefix, "\(name)-sheet")
            if let ok = OpenViewsAutomation.texts(1).last(where: { $0.text == "OK" }) {
                await OpenViewsAutomation.click(at: CGPoint(x: ok.frame.midX, y: ok.frame.midY), window: 1)
            }
            await ShellDriver.pause(0.5)
            check(!model.isAccountsSheetShown, "\(name) OK closes the sheet")
        }
        prefs.appearance = appearance
        say(failures.isEmpty ? "accounts: ok" : "accounts: FAILED \(failures)")
    }
}
#endif
