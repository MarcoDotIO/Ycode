import Foundation
import SwiftUI
import YcodeIDECore
import YcodeIDEShell
import YcodeSubprocess
#if os(Linux)
import OVPlatform
#endif

// YCODE_IDE_POLISH=<prefix>: the beta 2 polish pass, end to end in a
// package (Greeter with an asset catalog), printing "polish <step>: …" and
// writing <prefix>-<step>.png:
//
//   ctrl-y (Ctrl+Y with the editor focused: Debug ▸ Deactivate
//   Breakpoints, the Debug menu open), redo (Ctrl+Shift+Z), symbols-tooltip
//   (⌘3's own symbol and tooltip), console-filter-menu and
//   variables-scope-menu (pull-downs in the bottom bars), assets-add-menu
//   (the asset catalog's "+"), console-row-menu (a console row's Copy
//   items after a run), runtime-copy (the runtime wizard's Copy button),
//   settings-general (the columns form), forced-light (Settings ▸
//   Appearance Light on a dark desktop: the menu bar follows).
extension ShellDriver {
    #if os(Linux)
    static func polish(_ app: ShellAppModel, prefix: String) async {
        guard let w = app.workspace else {
            say("polish: no workspace")
            return
        }
        func shot(_ step: String, window: Int = 0) async {
            await pause(0.6)
            say("polish \(step): " + OpenViewsAutomation.screenshot(window, to: "\(prefix)-\(step).png"))
        }
        let height = OpenViewsAutomation.windowSize()?.points.height ?? 0
        // The clipboard as another program reads it (xclip on X11, where
        // the app owns the selection while it runs), and as the app reads it.
        func clipboard() async -> String {
            await pause(0.3)
            var outside = "-"
            if env["DISPLAY"] != nil, FileManager.default.isExecutableFile(atPath: "/usr/bin/xclip") {
                let p = Process()
                p.executableURL = URL(fileURLWithPath: "/usr/bin/xclip")
                p.arguments = ["-o", "-selection", "clipboard"]
                let out = try? SpawnPipe(childReads: false)
                p.standardOutput = out?.childEnd
                p.standardError = FileHandle.nullDevice
                if let out, (try? p.runWithSignalsUnblocked(closingChildEndsOf: out)) != nil {
                    // xclip asks this app for the selection: keep the run loop going.
                    for _ in 0..<40 where p.isRunning { await pause(0.05) }
                    if p.isRunning { p.terminate() }
                    outside = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                }
            }
            return "copied=\"\(ShellPasteboard.lastCopied ?? "")\" app=\"\(ShellClipboard.string ?? "")\" xclip=\"\(outside)\""
        }
        // The open pop-up's frame in the window (its texts' union).
        func popupFrame() -> CGRect? {
            let t = OpenViewsAutomation.texts().filter(\.inPopup).map(\.frame)
            guard let first = t.first else { return nil }
            return t.dropFirst().reduce(first) { $0.union($1) }
        }
        func reportPopup(_ step: String, below anchor: String) {
            guard let p = popupFrame(), let a = frame(anchor) else {
                say("polish \(step): no pop-up")
                return
            }
            say(String(format: "polish %@: pop-up rows y %.0f–%.0f, button y %.0f–%.0f, window height %.0f, opens %@, inside=%@", step,
                       p.minY, p.maxY, a.minY, a.maxY, height, p.maxY <= a.minY + 1 ? "upward" : "downward", p.maxY <= height ? "yes" : "no"))
        }

        // 1. Ctrl+Y with the editor focused reaches Debug ▸ Deactivate Breakpoints.
        guard let main = w.root.allFiles.first(where: { $0.name == "main.swift" })?.path else {
            say("polish: no main.swift")
            return
        }
        w.open(main)
        await pause(0.6)
        await click("source")
        let before = w.debug.breakpoints.isActive
        OpenViewsAutomation.press(.character("y"), modifiers: [.control])
        await pause(0.4)
        say("polish ctrl-y: breakpoints active \(before) -> \(w.debug.breakpoints.isActive), editor length \(w.editor?.buffer.length ?? 0)")
        await clickText("Debug", inPopup: false)
        await shot("ctrl-y")
        OpenViewsAutomation.press(.escape)
        await pause(0.3)
        OpenViewsAutomation.press(.character("y"), modifiers: [.control])
        await pause(0.3)
        say("polish ctrl-y again: breakpoints active \(w.debug.breakpoints.isActive)")

        // 2. Redo is Ctrl+Shift+Z.
        await click("source")
        let length = w.editor?.buffer.length ?? 0
        OpenViewsAutomation.type("x")
        await pause(0.3)
        OpenViewsAutomation.press(.character("z"), modifiers: [.control])
        await pause(0.3)
        let undone = w.editor?.buffer.length ?? 0
        OpenViewsAutomation.press(.character("z"), modifiers: [.control, .shift])
        await pause(0.3)
        let redone = w.editor?.buffer.length ?? 0
        say("polish redo: length \(length) typed+undo \(undone) redo \(redone) (redo \(redone == length + 1 ? "works" : "FAILED"))")
        await shot("redo")
        OpenViewsAutomation.press(.character("z"), modifiers: [.control])
        await pause(0.3)

        // 3. ⌘3: the Symbol navigator's own symbol and tooltip.
        OpenViewsAutomation.press(.character("3"), modifiers: [.control])
        await pause(0.5)
        if let f = frame("selector 2") {
            OpenViewsAutomation.move(to: CGPoint(x: f.midX, y: f.midY))
            await pause(1.6)
            OpenViewsAutomation.move(to: CGPoint(x: f.midX + 0.5, y: f.midY))
            await pause(0.4)
        }
        say("polish symbols: navigator=\(w.navigator.rawValue) tooltip=\"\(OpenViewsAutomation.texts().first { $0.text.hasPrefix("Show the") }?.text ?? "none")\"")
        await shot("symbols-tooltip")

        // 4. Pull-downs in the debug area's bottom bars open upward.
        w.isDebugAreaShown = true
        await pause(0.5)
        await click("console filter")
        reportPopup("console-filter-menu", below: "console filter")
        await shot("console-filter-menu")
        OpenViewsAutomation.press(.escape)
        await pause(0.3)
        await click("variables scope")
        reportPopup("variables-scope-menu", below: "variables scope")
        await shot("variables-scope-menu")
        OpenViewsAutomation.press(.escape)
        await pause(0.3)

        // 5. The asset catalog's "+" at the window's bottom.
        if let assets = w.root.allFiles.first(where: { $0.name.hasSuffix(".xcassets") })?.path {
            w.isDebugAreaShown = false
            w.open(assets)
            await pause(0.8)
            await click("assets add")
            reportPopup("assets-add-menu", below: "assets add")
            await shot("assets-add-menu")
            OpenViewsAutomation.press(.escape)
            await pause(0.3)
            w.open(main)
            await pause(0.4)
        } else {
            say("polish assets-add-menu: no asset catalog")
        }

        // 6. Run, then copy a console row (its menu, and Debug ▸ Console).
        w.perform(.run)
        for _ in 0..<600 where w.isBusy || !w.console.contains("Hello") { await pause(0.25) }
        w.isDebugAreaShown = true
        w.debugPane = .console
        await pause(0.8)
        let rows = w.debug.consoleRows.map(\.text)
        say("polish console rows: \(rows.prefix(8))")
        if let i = rows.firstIndex(where: { $0.contains("Hello") }) {
            await click("console row \(i)")
            app.perform(.copyConsoleRowWithoutMetadata)
            say("polish copy row: enabled=\(app.isEnabled(.copyConsoleRowWithoutMetadata)) \(await clipboard())")
            if let f = frame("console row \(i)") {
                await OpenViewsAutomation.click(at: CGPoint(x: f.minX + 40, y: f.midY), button: 3)
                await pause(0.5)
                await shot("console-row-menu")
                await clickText("Copy Row with All Metadata", inPopup: true)
                say("polish copy row all metadata: \(await clipboard())")
            }
            await clickText("Debug", inPopup: false)
            if let c = OpenViewsAutomation.texts().first(where: { $0.inPopup && $0.text == "Console" }) {
                OpenViewsAutomation.move(to: CGPoint(x: c.frame.midX, y: c.frame.midY))
                await pause(0.3)
                await OpenViewsAutomation.click(at: CGPoint(x: c.frame.midX, y: c.frame.midY))
                await pause(0.5)
            }
            await shot("debug-console-menu")
            OpenViewsAutomation.press(.escape)
            await pause(0.2)
            OpenViewsAutomation.press(.escape)
            await pause(0.3)
        } else {
            say("polish console: no output row (\(w.console.suffix(200)))")
        }

        // 7. The runtime wizard's Copy buttons.
        let domain = "ycode-ide-polish-walk"
        UserDefaults.standard.removePersistentDomain(forName: domain)
        app.runtimeDefaults = UserDefaults(suiteName: domain) ?? .standard
        app.showRuntimeSetup()
        if let s = app.runtimeSetup {
            for _ in 0..<200 where s.isChecking { await pause(0.2) }
            var copied = false
            for step in s.steps where !copied {
                s.show(step)
                await pause(0.6)
                if frame("runtime command copy") != nil {
                    await click("runtime command copy")
                    say("polish runtime-copy: step=\(step.title) \(await clipboard())")
                    await shot("runtime-copy")
                    copied = true
                }
            }
            if !copied {
                // A host that does not answer: "Reachable" offers its ssh-copy-id command.
                s.show(.host)
                s.ssh = "/bin/false"
                s.setHost(RuntimeHostSettings(destination: "nobody@ycode-host.invalid", dataDirectory: "/data/ycode"))
                for _ in 0..<100 where s.isChecking || s.running != nil { await pause(0.2) }
                await pause(0.8)
                if frame("runtime command copy") != nil {
                    await click("runtime command copy")
                    say("polish runtime-copy: step=\(s.step.title) \(await clipboard())")
                } else {
                    say("polish runtime-copy: no command shown")
                }
                await shot("runtime-copy")
            }
            app.closeRuntimeSetup()
            await pause(0.4)
            say("polish runtime wizard closed")
        }

        // 8. Settings: the columns form; the forced appearance on the menu bar.
        let saved = Preferences.shared.appearance
        OpenViewsAutomation.press(.character(","), modifiers: [.control])
        for _ in 0..<20 where OpenViewsAutomation.windowCount < 2 { await pause(0.2) }
        say("polish settings: windows=\(OpenViewsAutomation.windowCount)")
        await pause(0.6)
        await shot("settings-general", window: 1)
        let desktopDark = env["OV_COLOR_SCHEME"] == "dark"
        Preferences.shared.appearance = desktopDark ? .light : .dark
        await pause(0.8)
        await shot("settings-forced", window: 1)
        await shot(desktopDark ? "forced-light" : "forced-dark")
        await clickText("File", inPopup: false)
        await shot(desktopDark ? "forced-light-menu" : "forced-dark-menu")
        OpenViewsAutomation.press(.escape)
        Preferences.shared.appearance = saved
        await pause(0.4)
        say("polish done")
    }
    #endif
}
