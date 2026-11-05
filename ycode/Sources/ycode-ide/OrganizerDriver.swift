import Foundation
import SwiftUI
import YcodeIDECore
import YcodeIDEShell
#if os(Linux)
import OVPlatform
#endif

// Organizer automation (OpenViews only), started from ShellDriver:
//
//   YCODE_IDE_ORGANIZER=<p>  open Window ▸ Organizer with the pointer, then in
//                           the Light and then the Dark appearance: select
//                           the newest archive that has an application and
//                           check the list's columns and cells and the
//                           details against the archive's Info.plist
//                           (`Organizer.entry`), open the row's menu and
//                           choose Show in Files, check Distribute App… is
//                           disabled, visit Overview (its empty state),
//                           Back and Forward, the bell's popover and the app
//                           picker. Photographs <p>-[dark-]organizer-*.png
//                           (the menu: <p>-organizer-menu.png). Prints one
//                           "organizer: …" line per check and
//                           "organizer: ok" or "organizer: FAILED …".
//                           Show in Files only prints the path unless
//                           YCODE_IDE_ORGANIZER_REVEAL=1 is set too.
//
// The archives are read where ycodebuild writes them,
// `$HOME/Library/Developer/Xcode/Archives`; run it with HOME (and
// XDG_CONFIG_HOME, since it sets the appearance) pointing at a scratch
// folder that holds them.

#if os(Linux)
@MainActor
enum OrganizerDriver {
    static var say: (String) -> Void { ShellDriver.say }
    static func frame(_ name: String) -> CGRect? { OpenViewsAutomation.identifiedFrames(1)[name] }

    static func click(_ name: String, button: Int = 1) async {
        guard let f = frame(name) else {
            say("organizer: no target \(name)")
            return
        }
        await OpenViewsAutomation.click(at: CGPoint(x: f.midX, y: f.midY), window: 1, button: button)
        await ShellDriver.pause(0.4)
    }

    static func shot(_ prefix: String, _ name: String) async {
        await ShellDriver.pause(0.6)
        say("organizer \(name): " + OpenViewsAutomation.screenshot(1, to: "\(prefix)-\(name).png"))
    }

    static func run(_ app: ShellAppModel, prefix: String) async {
        var failures: [String] = []
        func check(_ ok: Bool, _ what: String) {
            say("organizer: \(what) \(ok ? "yes" : "NO")")
            if !ok { failures.append(what) }
        }
        let model = app.organizer
        let archives = Organizer.archives(in: model.archivesDirectory)
        say("organizer: \(archives.count) archives in \(model.archivesDirectory.path)")
        check(!archives.isEmpty, "archives found")

        // Window ▸ Organizer, with the pointer.
        await ShellDriver.clickText("Window", inPopup: false)
        let item = OpenViewsAutomation.texts().first { $0.inPopup && $0.text == "Organizer" }
        check(item != nil, "Window menu lists Organizer")
        check(OpenViewsAutomation.texts().filter { $0.inPopup && $0.text == "Organizer" }.count == 1, "Window menu lists Organizer once")
        say("organizer: Window menu \(OpenViewsAutomation.texts().filter(\.inPopup).map(\.text))")
        await ShellDriver.pause(0.3)
        say("organizer menu: " + OpenViewsAutomation.screenshot(to: "\(prefix)-organizer-menu.png"))
        await ShellDriver.clickText("Organizer", inPopup: true)
        for _ in 0..<25 where OpenViewsAutomation.windowCount < 2 { await ShellDriver.pause(0.2) }
        guard OpenViewsAutomation.windowCount >= 2 else {
            say("organizer: FAILED the Organizer window did not open")
            return
        }
        await ShellDriver.pause(0.8)
        if let s = OpenViewsAutomation.windowSize(1) { say("organizer: window \(s.points.width)x\(s.points.height) pt") }
        // Show in Files is recorded, not handed to the shared desktop's file
        // manager, unless YCODE_IDE_ORGANIZER_REVEAL=1 asks for it.
        if ShellDriver.env["YCODE_IDE_ORGANIZER_REVEAL"] == nil { model.revealInFiles = { say("organizer: reveal \($0.path)") } }

        let prefs = Preferences.shared
        let appearance = prefs.appearance
        let expected = archives.first(where: \.hasApplication) ?? archives.first
        for dark in [false, true] {
            prefs.appearance = dark ? .dark : .light
            let p = dark ? "dark-organizer" : "organizer"
            await click("organizer page Products Archives")
            check(model.state.page == "Archives", "\(p) Archives shown")

            // The newest archive with an application: its row and details.
            if let e = expected {
                if e.appName != model.state.selectedApp { model.chooseApp(e.appName) }
                await ShellDriver.pause(0.3)
                if let row = model.state.rows.firstIndex(where: { $0.archive?.url == e.url }) {
                    await click("organizer row \(row)")
                    check(model.state.selected?.url == e.url, "\(p) clicked row selects \(e.name)")
                }
                let texts = Set(OpenViewsAutomation.texts(1).filter { !$0.inPopup }.map(\.text))
                let titles = OrganizerState.columns.map(\.title)
                check(titles.allSatisfy(texts.contains), "\(p) columns \(titles)")
                let cells = OrganizerState.columns.map { OrganizerState.cellText(e, column: $0.id) }
                check(cells.allSatisfy(texts.contains), "\(p) row cells \(cells)")
                let fromPlist = Organizer.entry(at: e.url)
                var state = OrganizerState()
                if let fromPlist { state.load([fromPlist]); state.select(archiveAt: fromPlist.url) }
                let details = model.state.detailRows.map { "\($0.0)=\($0.1)" }
                say("organizer: details \(details)")
                check(details == state.detailRows.map { "\($0.0)=\($0.1)" }, "\(p) details match the archive's Info.plist")
                let shown = model.state.detailRows.flatMap { [$0.0, $0.1] }.filter { !$0.isEmpty }
                check(shown.allSatisfy(texts.contains), "\(p) details drawn")
                check(!model.canDistribute, "\(p) Distribute App… disabled")
                await shot(prefix, "\(p)-archives")

                // The row's menu: Show in Files.
                if let row = model.state.selectedRow {
                    await click("organizer row \(row)", button: 3)
                    let menu = OpenViewsAutomation.texts(1).filter(\.inPopup).map(\.text)
                    check(menu.contains(OrganizerState.showInFilesTitle), "\(p) row menu has \(OrganizerState.showInFilesTitle)")
                    await shot(prefix, "\(p)-row-menu")
                    if let t = OpenViewsAutomation.texts(1).first(where: { $0.inPopup && $0.text == OrganizerState.showInFilesTitle }) {
                        await OpenViewsAutomation.click(at: CGPoint(x: t.frame.midX, y: t.frame.midY), window: 1)
                        await ShellDriver.pause(0.6)
                    }
                    check(model.lastRevealed == e.url, "\(p) Show in Files asked for \(e.url.lastPathComponent)")
                }
            }

            // Overview: the empty state; Back and Forward.
            await click("organizer page Insights Overview")
            let empty = model.state.emptyState
            let texts = OpenViewsAutomation.texts(1).map(\.text)
            check(model.state.page == "Overview" && texts.contains(empty.title) && texts.contains(empty.message), "\(p) Overview's empty state")
            await shot(prefix, "\(p)-overview")
            await click("organizer back")
            check(model.state.page == "Archives", "\(p) Back returns to Archives")
            await click("organizer forward")
            check(model.state.page == "Overview", "\(p) Forward goes to Overview")
            await click("organizer page Metrics Hitches")
            await shot(prefix, "\(p)-hitches")
            await click("organizer page Products Archives")

            // The bell: "No Notifications".
            await click("organizer bell")
            check(OpenViewsAutomation.texts(1).contains { $0.text == OrganizerState.noNotificationsText }, "\(p) bell shows \(OrganizerState.noNotificationsText)")
            await shot(prefix, "\(p)-notifications")
            OpenViewsAutomation.press(.escape, window: 1)
            await ShellDriver.pause(0.4)
            if model.state.notificationsShown { model.hideNotifications() }

            // The app picker: one item per application.
            await click("organizer app picker")
            let items = OpenViewsAutomation.texts(1).filter(\.inPopup).map(\.text)
            check(model.state.appPickerTitles.allSatisfy(items.contains), "\(p) app picker lists \(model.state.appPickerTitles)")
            await shot(prefix, "\(p)-app-picker")
            OpenViewsAutomation.press(.escape, window: 1)
            await ShellDriver.pause(0.4)
        }
        prefs.appearance = appearance
        say(failures.isEmpty ? "organizer: ok" : "organizer: FAILED \(failures)")
    }
}
#endif
