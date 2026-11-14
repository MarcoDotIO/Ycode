import AppKit
import CYcodeTestOffscreen
import Foundation
import Testing
@testable import YcodeIDECore
@testable import YcodeUI

/// B2-RUNTIME (#68–#70): the macOS runtime wizard. The first test drives it
/// with stand-in commands. With `YCODE_RUNTIME_SHOTS=<dir>` the second one
/// photographs every step on this Mac (its runtimes read with `simctl
/// runtime list -j`, read-only; nothing is added or removed), and with
/// `YCODE_RUNTIME_TEST_HOST=<user@host>` and `YCODE_RUNTIME_TEST_DATA=<absolute
/// folder>` (`YCODE_RUNTIME_TEST_CONFIG` for simhost.env) it runs the remote
/// flow against that host: its checks, the setup script in report and apply
/// mode, a fake runtime copied, stopped, resumed and removed.
@MainActor
@Suite(.serialized) struct RuntimeSetupWindowTests {
    struct Runner: HeadsetCommandRunner {
        var answers: [(String, HeadsetCommandResult)]
        func run(_ command: String) async -> HeadsetCommandResult {
            answers.first { command.contains($0.0) }?.1 ?? HeadsetCommandResult(status: 1)
        }
    }

    static func ok(_ s: String) -> HeadsetCommandResult { HeadsetCommandResult(status: 0, output: s) }

    static let images = """
    {"A1":{"build":"24A434","identifier":"A1","platformIdentifier":"com.apple.platform.iphonesimulator","runtimeIdentifier":"com.apple.CoreSimulator.SimRuntime.iOS-27-0",
    "runtimeBundlePath":"/rt/iOS 27.0.simruntime","sizeBytes":7873719649,"state":"Ready","supportedArchitectures":["arm64"],"version":"27.0"}}
    """

    func window(_ s: RuntimeSetupSession) -> RuntimeSetupWindowController {
        _ = NSApplication.shared
        let wc = RuntimeSetupWindowController(session: s)
        wc.answerConfirmation = { _ in false }
        return wc
    }

    static func texts(_ v: NSView) -> [String] {
        ((v as? NSTextField).map { [$0.stringValue] } ?? []) + ((v as? NSButton).map { [$0.title] } ?? []) + v.subviews.flatMap(texts)
    }

    static func find(_ id: String, in v: NSView) -> NSView? {
        if v.identifier?.rawValue == id { return v }
        for s in v.subviews { if let f = find(id, in: s) { return f } }
        return nil
    }

    @Test func stepsChecksAndConfirmations() async throws {
        let td = TestDefaults("runtime-wizard")
        defer { td.remove() }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ycode-rt-ui-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let runner = Runner(answers: [("xcrun --find simctl", Self.ok("/x/simctl")), ("simctl runtime list -j", Self.ok(Self.images)),
                                      ("simctl list runtimes -j", Self.ok("{\"runtimes\":[]}")), ("df -Pk", Self.ok("209715200"))])
        let s = RuntimeSetupSession(machine: SetupMachine(isMac: true, architecture: "arm64"), defaults: td.defaults, folder: dir.path, localRunner: runner)
        let wc = window(s)
        defer { wc.window?.close() }
        await s.recheck().value
        let root = try #require(wc.window?.contentView)
        #expect(Self.find("setup-dot-0", in: root) != nil)
        #expect(wc.backButton.isHidden && wc.primaryButton.title == "Continue")
        #expect(Self.find("runtime-platform-iOS", in: root) != nil)
        #expect(Self.find("runtime-check-machine", in: root) != nil)
        wc.next()
        #expect(s.step == .runtimes)
        let all = Self.texts(root)
        #expect(all.contains("iOS 27.0 (24A434)"))
        #expect(all.contains { $0.contains("installed by Xcode; manage it in Xcode") })
        // Xcode's runtime has no Remove.
        #expect(!all.contains("Remove…"))
        wc.next()
        // Get a Runtime (#55): the routes, before Add a Runtime.
        #expect(s.step == .download && Self.find("runtime-download-platform", in: root) != nil)
        wc.next()
        #expect(s.step == .add && Self.find("runtime-choose", in: root) != nil)
        // A disk image: the confirmation (answered No here) shows the exact command.
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let dmg = dir.appendingPathComponent("watchOS 27.0 Simulator Runtime.dmg")
        try Data().write(to: dmg)
        var shown: RuntimeConfirmation?
        wc.answerConfirmation = { shown = $0; return false }
        wc.pickFile = { dmg.path }
        wc.chooseClicked()
        wc.addPickedClicked()
        #expect(shown?.command == "xcrun simctl runtime add '\(dmg.path)'")
        #expect(s.running == nil && s.confirmation == nil)
        let alert = RuntimeSetupWindowController.alert(for: try #require(shown))
        #expect(alert.buttons.map(\.title) == ["Add Runtime", "Cancel"])
        wc.next()
        #expect(s.step == .finish && wc.primaryButton.title == "Done")
        // A simulator host adds its steps.
        s.setUseHost(true)
        #expect(s.steps.contains(.host) && s.steps.contains(.prepare))
        s.show(.host)
        #expect(Self.find("runtime-host", in: root) != nil)
    }

    /// The page dots stand for the steps: one per step of the target, each
    /// with its state, the current one larger; a click jumps to its step.
    @Test func pageDotsShowTheStepsAndJump() async throws {
        let td = TestDefaults("runtime-wizard-dots")
        defer { td.remove() }
        let runner = Runner(answers: [("xcrun --find simctl", Self.ok("/x/simctl")), ("simctl runtime list -j", Self.ok(Self.images)),
                                      ("simctl list runtimes -j", Self.ok("{\"runtimes\":[]}")), ("df -Pk", Self.ok("209715200"))])
        let s = RuntimeSetupSession(machine: SetupMachine(isMac: true, architecture: "arm64"), defaults: td.defaults, folder: "/nonexistent", localRunner: runner)
        let wc = window(s)
        defer { wc.window?.close() }
        let root = try #require(wc.window?.contentView)
        let dots = try #require(Self.find("runtime-steps-panel", in: root) as? SetupPageDots)
        #expect(dots.dots.count == s.steps.count && dots.dots.allSatisfy { $0.dotState == .notChecked })
        await s.recheck().value
        #expect(dots.dots.map(\.dotState) == s.steps.map { RuntimeSetupWindowController.dotState(s.state(of: $0)) })
        #expect(dots.dots[0].isCurrent && dots.dots[0].dotDiameter > dots.dots[1].dotDiameter)
        #expect(dots.dots[1].toolTip?.hasPrefix("Step 2 of \(s.steps.count): Runtimes, ") == true)
        #expect(dots.dots[1].accessibilityLabel() == dots.dots[1].toolTip)
        dots.dots[3].performClick(nil)
        #expect(s.step == s.steps[3] && dots.dots[3].isCurrent && !dots.dots[0].isCurrent)
        // A host's steps: more dots.
        s.setUseHost(true)
        #expect(dots.dots.count == s.steps.count)
    }

    /// The content ends above the footer: the last row of a long step, scrolled
    /// to the end, is above Back, Re-check and Continue, and so is the status line's row.
    @Test func lastRowEndsAboveTheFooter() async throws {
        let td = TestDefaults("runtime-wizard-footer")
        defer { td.remove() }
        let s = RuntimeSetupSession(machine: SetupMachine(isMac: true, architecture: "arm64"), defaults: td.defaults, folder: "/nonexistent",
                                    localRunner: Runner(answers: [("xcrun --find simctl", Self.ok("/x/simctl")), ("df -Pk", Self.ok("209715200"))]))
        // Every host check fails or is unknown: the longest Simulator Host step.
        s.hostRunner = { _ in Runner(answers: [("uname -sm", Self.ok("Linux x86_64")), ("/dev/kvm", Self.ok("absent")), ("df -Pk", Self.ok("1"))]) }
        s.setUseHost(true)
        s.setHost(RuntimeHostSettings(destination: "tester@sim-host", dataDirectory: "/data/ycode"))
        let wc = window(s)
        defer { wc.window?.close() }
        wc.window?.setContentSize(NSSize(width: 700, height: 470))
        await s.recheck().value
        for step in [RuntimeSetupStep.host, .prepare, .runtimes] {
            s.show(step)
            let root = try #require(wc.window?.contentView)
            root.layoutSubtreeIfNeeded()
            let doc = try #require(wc.scroll.documentView)
            doc.scroll(NSPoint(x: 0, y: max(0, doc.bounds.height - wc.scroll.contentView.bounds.height)))
            wc.scroll.reflectScrolledClipView(wc.scroll.contentView)
            let footerTop = wc.footer.convert(wc.footer.bounds, to: nil).maxY
            #expect(wc.scroll.convert(wc.scroll.bounds, to: nil).minY >= footerTop, "\(step): the scroll view reaches under the footer")
            func all(_ v: NSView) -> [NSView] { [v] + v.subviews.flatMap(all) }
            let rows = all(doc).filter { ($0.identifier?.rawValue ?? "").hasPrefix("runtime-check-") }
            if step == .prepare { continue }   // no checks until the script ran; the scroll view's frame is what counts
            let last = try #require(rows.max { $0.convert($0.bounds, to: nil).minY > $1.convert($1.bounds, to: nil).minY }, "\(step): no check rows")
            #expect(last.convert(last.bounds, to: nil).minY >= footerTop, "\(step): \(last.identifier?.rawValue ?? "") ends under the footer")
        }
    }

    nonisolated static let shots = ProcessInfo.processInfo.environment["YCODE_RUNTIME_SHOTS"]
    nonisolated static let host = ProcessInfo.processInfo.environment["YCODE_RUNTIME_TEST_HOST"]
    nonisolated static let data = ProcessInfo.processInfo.environment["YCODE_RUNTIME_TEST_DATA"]

    func shot(_ wc: RuntimeSetupWindowController, _ name: String, to out: URL) async throws {
        let win = try #require(wc.window)
        let look = win.appearance
        defer { win.appearance = look }
        try await photograph(wc, name, to: out)
        // Every step in the other appearance too.
        win.appearance = NSAppearance(named: look?.name == .darkAqua ? .aqua : .darkAqua)
        try await photograph(wc, name + (look?.name == .darkAqua ? "-light" : "-dark"), to: out)
    }

    /// As the window server draws it (the glass buttons need that), placed off
    /// the screens and behind everything; the cached drawing if that fails.
    func photograph(_ wc: RuntimeSetupWindowController, _ name: String, to out: URL) async throws {
        let win = try #require(wc.window)
        wc.assistant.finishTransition()
        win.setFrameOrigin(NSPoint(x: -6000, y: -6000))
        win.orderBack(nil)
        win.contentView?.layoutSubtreeIfNeeded()
        try? await Task.sleep(nanoseconds: 700_000_000)
        let path = out.appendingPathComponent("mac-runtime-\(name).png")
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        p.arguments = ["-x", "-o", "-l", String(win.windowNumber), path.path]
        YcodeOffscreenOpaqueDuringCapture(win) {
            try? p.run()
            p.waitUntilExit()
        }
        if p.terminationStatus == 0, FileManager.default.fileExists(atPath: path.path) { return }
        let frame = try #require(win.contentView?.superview)
        frame.layoutSubtreeIfNeeded()
        let rep = try #require(frame.bitmapImageRepForCachingDisplay(in: frame.bounds))
        frame.cacheDisplay(in: frame.bounds, to: rep)
        try #require(rep.representation(using: .png, properties: [:])).write(to: path)
    }

    func shot(alert c: RuntimeConfirmation, _ name: String, to out: URL) throws {
        let a = RuntimeSetupWindowController.alert(for: c)
        a.layout()
        let v = try #require(a.window.contentView)
        let rep = try #require(v.bitmapImageRepForCachingDisplay(in: v.bounds))
        v.cacheDisplay(in: v.bounds, to: rep)
        try #require(rep.representation(using: .png, properties: [:])).write(to: out.appendingPathComponent("mac-runtime-\(name).png"))
    }

    func settle(_ s: RuntimeSetupSession, timeout: Double = 300) async {
        let start = Date()
        while (s.isChecking || s.running != nil) && Date().timeIntervalSince(start) < timeout { try? await Task.sleep(nanoseconds: 200_000_000) }
        try? await Task.sleep(nanoseconds: 300_000_000)
    }

    @Test(.enabled(if: shots != nil)) func everyStepOnThisMacAndAHost() async throws {
        let out = URL(fileURLWithPath: try #require(Self.shots))
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let td = TestDefaults("runtime-wizard-shots")
        defer { td.remove() }
        let work = FileManager.default.temporaryDirectory.appendingPathComponent("ycode-rt-shots-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: work) }
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        // This Mac, read-only.
        let s = RuntimeSetupSession(defaults: td.defaults, folder: work.appendingPathComponent("rt").path)
        s.setPlatform(.visionOS, on: true)
        s.setPlatform(.tvOS, on: true)
        let wc = window(s)
        wc.answerConfirmation = { _ in nil }
        defer { wc.window?.close() }
        wc.window?.appearance = NSAppearance(named: .aqua)
        await settle(s)
        try await shot(wc, "1-target", to: out)
        s.show(.runtimes)
        try await shot(wc, "2-runtimes", to: out)
        s.show(.add)
        try await shot(wc, "3-add", to: out)
        let dmg = work.appendingPathComponent("iOS 27.0 Simulator Runtime.dmg")
        try Data().write(to: dmg)
        s.pick(path: dmg.path)
        try await shot(wc, "3-add-picked", to: out)
        s.request(try #require(s.pickedAction))
        try shot(alert: try #require(s.confirmation), "3-add-confirm", to: out)
        s.cancelConfirmation()
        s.show(.finish)
        try await shot(wc, "4-finish", to: out)

        // A simulator host.
        guard let host = Self.host, let data = Self.data else { return }
        s.setUseHost(true)
        var h = RuntimeHostSettings(destination: host, dataDirectory: data)
        // The folder that holds simhost.env (YCODE_RUNTIME_TEST_CONFIG, its old name, is still read).
        let env = ProcessInfo.processInfo.environment
        h.configDirectory = env["YCODE_RUNTIME_TEST_CONFIG_DIR"] ?? env["YCODE_RUNTIME_TEST_CONFIG"] ?? ""
        s.show(.host)
        s.setHost(h)
        await settle(s)
        try await shot(wc, "5-host", to: out)
        // Offline: a host that does not answer.
        s.setHost(RuntimeHostSettings(destination: "nobody@192.0.2.1", dataDirectory: data))
        await settle(s, timeout: 60)
        try await shot(wc, "5-host-offline", to: out)
        #expect(s.report?.check("host.reach")?.state == .unknown)
        s.setHost(h)
        await settle(s)
        s.show(.prepare)
        try await shot(wc, "6-prepare", to: out)
        s.runSetupReport()
        await settle(s)
        try await shot(wc, "6-prepare-report", to: out)
        let report = try #require(s.hostSetup)
        print("setup report: \(report.checks.map { "\($0.id)=\($0.state.rawValue)" }) steps=\(report.steps.map(\.id)) sve=\(report.sve ?? [:])")
        #expect(report.mode == "report")
        if !report.userSteps.isEmpty {
            s.request(.provisionApply)
            try shot(alert: try #require(s.confirmation), "6-prepare-apply-confirm", to: out)
            s.confirm()
            await settle(s)
            try await shot(wc, "6-prepare-applied", to: out)
            s.runSetupReport()
            await settle(s)
            #expect(s.hostSetup?.userSteps.isEmpty == true)
            try await shot(wc, "6-prepare-second-run", to: out)
        }
        // A fake runtime of 256 MB, copied, stopped, resumed, then removed.
        let bundle = work.appendingPathComponent("iOS 27.0.simruntime")
        let rootDir = bundle.appendingPathComponent("Contents/Resources/RuntimeRoot")
        try FileManager.default.createDirectory(at: rootDir.appendingPathComponent("System/Library/CoreServices"), withIntermediateDirectories: true)
        try PropertyListSerialization.data(fromPropertyList: ["CFBundleIdentifier": "com.apple.CoreSimulator.SimRuntime.iOS-27-0"], format: .xml, options: 0)
            .write(to: bundle.appendingPathComponent("Contents/Info.plist"))
        try PropertyListSerialization.data(fromPropertyList: ["ProductName": "iPhone OS", "ProductVersion": "27.0", "ProductBuildVersion": "24A434"], format: .xml, options: 0)
            .write(to: rootDir.appendingPathComponent("System/Library/CoreServices/SystemVersion.plist"))
        for i in 0..<64 {
            var bytes = [UInt8](repeating: 0, count: 4 << 20)
            for j in stride(from: 0, to: bytes.count, by: 8) { bytes[j] = UInt8.random(in: 0...255); bytes[j + 1] = UInt8(i) }
            try Data(bytes).write(to: rootDir.appendingPathComponent("blob-\(i).bin"))
        }
        s.show(.add)
        s.pick(path: bundle.path)
        try await shot(wc, "7-add-host-picked", to: out)
        let copy = try #require(s.pickedAction)
        s.request(copy)
        try shot(alert: try #require(s.confirmation), "7-add-host-confirm", to: out)
        s.confirm()
        // Stop after a second and a half, with some of it there.
        let began = Date()
        for _ in 0..<200 {
            try await Task.sleep(nanoseconds: 100_000_000)
            if case .copying(let kb) = s.transferState, kb > 0, Date().timeIntervalSince(began) > 1.5 { break }
        }
        try await shot(wc, "7-add-host-copying", to: out)
        s.stop()
        await settle(s)
        try await shot(wc, "7-add-host-interrupted", to: out)
        guard case .interrupted = s.transferState else { Issue.record("expected an interrupted copy, got \(s.transferState)"); return }
        #expect(s.report?.check("transfer") != nil)
        s.request(copy)
        #expect(s.confirmation?.confirmTitle == "Resume")
        s.confirm()
        await settle(s)
        #expect(s.transferState == .finished)
        try await shot(wc, "7-add-host-finished", to: out)
        s.show(.runtimes)
        let copied = try #require(s.report?.host.first { $0.isRemovable && $0.version == "27.0" })
        #expect(s.report?.check("host.runtime.iOS")?.state == .ok)
        try await shot(wc, "8-runtimes-host", to: out)
        s.request(.remove(copied))
        try shot(alert: try #require(s.confirmation), "8-remove-confirm", to: out)
        s.confirm()
        await settle(s)
        #expect(s.report?.host.contains { $0.isRemovable } == false)
        try await shot(wc, "8-runtimes-host-removed", to: out)
        s.show(.finish)
        try await shot(wc, "9-finish-host", to: out)
    }
}
