import Foundation
import SwiftUI
import YcodeIDECore
import YcodeIDEShell
#if os(Linux)
import OVPlatform
#endif

// YCODE_IDE_RUNTIME_WALK=<prefix>: the simulator runtime wizard, every step
// and state, photographed as <prefix>-runtime-<n>-<state>.png. The host is
// YCODE_IDE_RUNTIME_HOST (ssh destination), YCODE_IDE_RUNTIME_DATA (its
// data folder) and YCODE_IDE_RUNTIME_CONFIG (simhost.env's folder);
// YCODE_IDE_RUNTIME_SSH replaces ssh and YCODE_IDE_RUNTIME_RSYNC rsync (a
// loopback ssh that runs the command on
// this machine lets one computer play the host); YCODE_IDE_RUNTIME_FAKE is
// a runtime bundle to copy, stop, resume and remove. Without a host only the
// steps of this computer are taken. The wizard's choices go to a throwaway
// defaults domain.
extension ShellDriver {
    #if os(Linux)
    static func runtimeWalk(_ app: ShellAppModel, prefix: String) async {
        func shot(_ name: String) async {
            await pause(0.9)
            let s = app.runtimeSetup
            say("runtime \(name): step=\(s?.step.title ?? "-") status=\"\(s?.status ?? "")\" checks=\(s?.shownChecks.map { "\($0.id)=\($0.state.rawValue)" } ?? []) "
                + OpenViewsAutomation.screenshot(to: "\(prefix)-runtime-\(name).png"))
        }
        func settle(_ s: RuntimeSetupSession, _ limit: Double = 240) async {
            var t = 0.0
            while (s.isChecking || s.running != nil) && t < limit { await pause(0.2); t += 0.2 }
        }
        // With a project open: the destinations of a paired host that is offline.
        if let w = app.workspace {
            say("runtime destinations: \(w.destinations.map(\.name))")
            await click("tb destination")
            await shot("00-destination-menu")
            OpenViewsAutomation.press(.escape)
            await pause(0.3)
            if let offline = w.destinations.first(where: { $0.name.hasSuffix(" is offline") }) {
                w.destination = offline
                w.perform(.run)
                for _ in 0..<40 where w.isBusy || w.console.isEmpty { await pause(0.1) }
                await pause(0.5)
                say("runtime offline run console: \(w.console.suffix(300))")
                await shot("00-offline-run")
            }
        }
        let domain = "ycode-ide-runtime-walk"
        UserDefaults.standard.removePersistentDomain(forName: domain)
        app.runtimeDefaults = UserDefaults(suiteName: domain) ?? .standard
        app.showRuntimeSetup(step: .target)
        guard let s = app.runtimeSetup else { say("runtime: no wizard"); return }
        if let ssh = env["YCODE_IDE_RUNTIME_SSH"] { s.ssh = ssh }
        if let rsync = env["YCODE_IDE_RUNTIME_RSYNC"] { s.rsync = rsync }
        s.setPlatform(.visionOS, on: true)
        await settle(s)
        await shot("01-target")
        for (i, step) in s.steps.enumerated() where step != .target {
            s.show(step)
            await shot(String(format: "%02d-%@", i + 1, step.title.lowercased().replacingOccurrences(of: " ", with: "-")))
        }
        await pagedAssistant(s, prefix: prefix, shot: shot)
        guard let dest = env["YCODE_IDE_RUNTIME_HOST"], let data = env["YCODE_IDE_RUNTIME_DATA"] else {
            app.closeRuntimeSetup()
            OpenViewsAutomation.terminate()
            return
        }
        var host = RuntimeHostSettings(destination: dest, dataDirectory: data)
        host.configDirectory = env["YCODE_IDE_RUNTIME_CONFIG"] ?? ""
        s.show(.host)
        // A host that does not answer: its rows are unknown, with the reason.
        let realSSH = s.ssh
        s.ssh = "/usr/bin/ssh"
        s.setHost(RuntimeHostSettings(destination: "nobody@192.0.2.1", dataDirectory: data))
        await settle(s, 60)
        await shot("10-host-offline")
        s.ssh = realSSH
        s.setHost(host)
        await settle(s)
        await shot("11-host")
        s.show(.prepare)
        s.runSetupReport()
        await settle(s)
        await shot("12-prepare-report")
        if s.hostSetup?.userSteps.isEmpty == false {
            s.request(.provisionApply)
            await shot("13-prepare-apply-confirm")
            s.confirm()
            await settle(s)
            s.runSetupReport()
            await settle(s)
            await shot("14-prepare-second-run")
        }
        s.show(.runtimes)
        await shot("15-runtimes-host")
        if let fake = env["YCODE_IDE_RUNTIME_FAKE"] {
            s.show(.add)
            s.pick(path: fake)
            await shot("16-add-picked")
            guard let copy = s.pickedAction else { say("runtime: the fake runtime gives no action"); return }
            s.request(copy)
            await shot("17-add-confirm")
            s.confirm()
            var t = 0.0
            while t < 60 {
                await pause(0.1)
                t += 0.1
                if case .copying(let kb) = s.transferState, kb > 0, t > 1.5 { break }
            }
            await shot("18-copying")
            s.stop()
            await settle(s)
            await shot("19-interrupted")
            s.request(copy)
            await shot("20-resume-confirm")
            s.confirm()
            await settle(s)
            await shot("21-copied")
            say("runtime transfer: \(s.transferState)")
            s.show(.runtimes)
            await shot("22-runtimes-copied")
            if let mine = s.report?.host.first(where: \.isRemovable) {
                s.request(.remove(mine))
                await shot("23-remove-confirm")
                s.confirm()
                await settle(s)
                await shot("24-removed")
            }
        }
        s.show(.finish)
        await shot("25-finish")
        app.closeRuntimeSetup()
        await pause(0.5)
        OpenViewsAutomation.terminate()
    }

    /// The paged assistant (`liquid-glass-ycode.md` §11): Back hidden on the
    /// first step, the dots (count, state, a click jumps), Continue and Back
    /// (a frame 0.1 s into each page change; with `OV_REDUCE_MOTION=1` the
    /// crossfade's), and the header's centring.
    static func pagedAssistant(_ s: RuntimeSetupSession, prefix: String, shot: (String) async -> Void) async {
        s.show(.target)
        await pause(0.6)
        let dots = (0..<12).compactMap { frame("runtime dot \($0)") }
        say("assistant: dots=\(dots.count) steps=\(s.steps.count) back=\(frame("runtime back") == nil ? "hidden" : "shown") "
            + "window centre=\(OpenViewsAutomation.windowSize().map { "\($0.points.width / 2)" } ?? "-") "
            + "title centre=\(frame("runtime title").map { "\($0.midX)" } ?? "-") glyph=\(frame("runtime glyph").map { "\($0)" } ?? "-") "
            + "continue=\(frame("runtime continue").map { "\($0)" } ?? "-")")
        say("assistant: states=\(s.steps.map { RuntimeSetupSheet.stateWords(s.state(of: $0)) }) dot frames=\(dots.map { "\(Int($0.midX))" })")
        // Mid-page-change frames: clicked without the driver's usual pause.
        func press(_ name: String) async {
            guard let f = frame(name) else { say("no target \(name)"); return }
            await OpenViewsAutomation.click(at: CGPoint(x: f.midX, y: f.midY))
        }
        await press("runtime continue")
        await pause(0.1)
        say("assistant: 0.1 s after Continue " + OpenViewsAutomation.screenshot(to: "\(prefix)-runtime-30-continue-0.1s.png"))
        await pause(0.6)
        say("assistant: after Continue step=\(s.step.title) back=\(frame("runtime back") == nil ? "hidden" : "shown")")
        await press("runtime dot \(s.steps.count - 1)")
        await pause(0.8)
        say("assistant: after the last dot step=\(s.step.title) continue says Done=\(s.isLastStep)")
        await shot("31-dot-jump")
        await press("runtime back")
        await pause(0.1)
        say("assistant: 0.1 s after Back " + OpenViewsAutomation.screenshot(to: "\(prefix)-runtime-32-back-0.1s.png"))
        await pause(0.6)
        say("assistant: after Back step=\(s.step.title)")
    }
    #endif
}
