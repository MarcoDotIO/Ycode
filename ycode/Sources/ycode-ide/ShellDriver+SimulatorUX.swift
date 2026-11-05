import Foundation
import SwiftUI
import YcodeBuild
import YcodeIDEShell
#if os(Linux)
import OVPlatform
#endif

// YCODE_IDE_SIMUX=<prefix>: the simulator walk of docs/SIMULATOR-UX.md from
// the Linux IDE: the destination menu (a paired host's devices, or the
// device Run makes on a host without one, or an offline host), Product ▸
// Run on a Ycode simulator host with the activity text and the console at
// each phase, then Product ▸ Stop. Each step prints "simux <t> s: …" and
// writes <prefix>-<n>-<state>.png.
//
//   YCODE_IDE_SIMUX_DEST     the destination's name (default: the first of a host)
//   YCODE_IDE_SIMUX_LIMIT    seconds to wait for the device's display (default 900)
//   YCODE_IDE_SIMUX_HOLD     seconds to keep the run before Stop (default 20)
extension ShellDriver {
    #if os(Linux)
    static func simulatorWalk(_ app: ShellAppModel, prefix: String) async {
        let t0 = Date()
        func mark(_ s: String) { say(String(format: "simux %7.1f s: ", Date().timeIntervalSince(t0)) + s) }
        func snap(_ name: String) async {
            await pause(0.6)
            mark("shot \(name) " + OpenViewsAutomation.screenshot(to: "\(prefix)-\(name).png"))
        }
        guard let w = app.workspace else { mark("no workspace"); return }
        let lookup = Date()
        let groups = ShellRemoteRun.destinationGroups()
        mark(String(format: "destination lookup %.2f s: ", Date().timeIntervalSince(lookup))
             + groups.map { "\($0.title): \($0.destinations.map(\.name))" }.joined(separator: "; "))
        await click("tb destination")
        await snap("01-destinations")
        OpenViewsAutomation.press(.escape)
        await pause(0.3)

        // An offline host: its row says so, and Run fails at once with the reason.
        if let offline = w.destinations.first(where: { $0.name.hasSuffix(" is offline") }) {
            w.destination = offline
            let started = Date()
            w.perform(.run)
            for _ in 0..<50 where !w.console.contains("did not answer") { await pause(0.1) }
            mark(String(format: "offline run %.2f s, activity \"%@\", console: %@", Date().timeIntervalSince(started), w.activityText,
                        String(w.console.suffix(240))))
            await snap("02-offline-run")
        }

        let wanted = env["YCODE_IDE_SIMUX_DEST"]
        guard let d = w.destinations.first(where: { $0.name == wanted })
                ?? w.destinations.first(where: { ShellRemoteRun.target(of: $0)?.device.isEmpty == false }) else {
            mark("no simulator host destination in \(w.destinations.map(\.name))")
            return
        }
        w.destination = d
        mark("destination \(d.name) type \(d.deviceType ?? "-") os \(d.osVersion ?? "-")")
        await snap("03-destination-chosen")

        let runStart = Date()
        let before = w.console.count
        await clickText("Product", inPopup: false)
        await clickText("Run", inPopup: true)
        await pause(1)
        if !w.isBusy {
            // The menu was not reachable (an offscreen display): Run as the menu item does.
            OpenViewsAutomation.press(.escape)
            mark("Product ▸ Run not clicked; running through the model")
            w.perform(.run)
        }
        var seen: [String] = []
        let limit = Double(env["YCODE_IDE_SIMUX_LIMIT"] ?? "") ?? 900
        var lastConsole = String(w.console.prefix(before))
        while Date().timeIntervalSince(runStart) < limit {
            await pause(0.25)
            let text = w.activityText
            if !seen.contains(text) {
                seen.append(text)
                mark(String(format: "activity \"%@\" after %.1f s, Stop %@", text, Date().timeIntervalSince(runStart),
                            w.isEnabled(.stop) ? "enabled" : "disabled"))
                await snap(String(format: "04-activity-%02d", seen.count))
            }
            let c = w.console
            if c.count != lastConsole.count {
                for line in c.dropFirst(lastConsole.count).split(separator: "\n") where !line.isEmpty
                    && (line.hasPrefix("Booting") || line.hasPrefix("Creat") || line.contains("is running") || line.contains("failed")
                        || line.contains("display is up") || line.contains(" is open on ") || line.contains("did not open")
                        || line.hasPrefix("Uploaded") || line.hasPrefix("Installing") || line.contains("stopped")) {
                    mark("console: \(line)")
                }
                lastConsole = c
            }
            let since = c.dropFirst(before)
            if since.contains(" is running (") || since.contains(" is open on ") || since.contains("failed") || since.contains("stopped on")
                || since.contains("did not open") { break }
        }
        await snap("05-run")
        let hold = Double(env["YCODE_IDE_SIMUX_HOLD"] ?? "") ?? 20
        await pause(hold)
        await clickText("Product", inPopup: false)
        await snap("06-product-menu")
        await clickText("Stop", inPopup: true)
        await pause(1)
        if w.isBusy {
            OpenViewsAutomation.press(.escape)
            mark("Product ▸ Stop not clicked; stopping through the model")
            w.perform(.stop)
            await pause(1)
        }
        mark("after Stop: activity \"\(w.activityText)\", Stop \(w.isEnabled(.stop) ? "enabled" : "disabled"), Run \(w.isEnabled(.run) ? "enabled" : "disabled"), "
             + "device windows still open: \(childViewers())")
        await snap("07-stopped")
    }

    /// This process's children named ycode-sim-viewer (the device windows), from /proc.
    static func childViewers() -> Int {
        let me = ProcessInfo.processInfo.processIdentifier
        let pids = (try? FileManager.default.contentsOfDirectory(atPath: "/proc")) ?? []
        return pids.filter { p in
            guard Int32(p) != nil, let stat = try? String(contentsOfFile: "/proc/\(p)/stat", encoding: .utf8),
                  let close = stat.lastIndex(of: ")") else { return false }
            let name = stat[stat.index(after: stat.firstIndex(of: "(") ?? stat.startIndex)..<close]
            let rest = stat[stat.index(after: close)...].split(separator: " ")
            return name == "ycode-sim-viewe" && rest.count > 2 && Int32(rest[1]) == me
        }.count
    }
    #endif
}
