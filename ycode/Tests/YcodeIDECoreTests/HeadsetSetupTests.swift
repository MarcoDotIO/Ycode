import Foundation
import Testing
@testable import YcodeIDECore

/// XR-HUB (`specs/ide/device-hub.md` §I.12): the headset checklist against a
/// stand-in viewer host (commands answered by their words), the actions'
/// exact commands, the viewer's plan, and the switch's state machine. No
/// network, no headset, nothing installed.
struct StandInRunner: HeadsetCommandRunner {
    /// (substring of the command, answer): the first match answers; else status 1.
    var answers: [(String, HeadsetCommandResult)]
    let log = CommandLog()

    final class CommandLog: @unchecked Sendable {
        private let lock = NSLock()
        private var lines: [String] = []
        func add(_ s: String) { lock.withLock { lines.append(s) } }
        var all: [String] { lock.withLock { lines } }
    }

    func run(_ command: String) async -> HeadsetCommandResult {
        log.add(command)
        return answers.first { command.contains($0.0) }?.1 ?? HeadsetCommandResult(status: 1)
    }

    static func ok(_ s: String = "") -> HeadsetCommandResult { HeadsetCommandResult(status: 0, output: s) }

    /// A complete, working workstation with a Quest Pro on USB and WiVRn 26.9 on both sides.
    static var ready: [(String, HeadsetCommandResult)] {
        [("uname", ok("Linux\n")),
         ("vulkaninfo", ok("GPU0:\n\tdeviceType = PHYSICAL_DEVICE_TYPE_DISCRETE_GPU\n\tdeviceName = NVIDIA GeForce RTX 4060 Ti\nGPU1:\n\tdeviceType = PHYSICAL_DEVICE_TYPE_CPU\n\tdeviceName = llvmpipe\n")),
         ("libopenxr_loader", ok("libopenxr_loader.so.1 (libc6,x86-64) => /usr/lib/x86_64-linux-gnu/libopenxr_loader.so.1\n")),
         ("active_runtime.json", ok("{\"runtime\": {\"name\": \"WiVRn\"}}")),
         ("test -f /usr/share/openxr/1/openxr_wivrn.json", ok()),
         ("wivrn-server --version", ok("WiVRn version 26.9\n")),
         ("pgrep -x wivrn-server", ok("1843547\n")),
         ("--help", ok("usage: ycode-xr-viewer [--connect …] [--state-file <file>]\n")),
         ("ssh -o BatchMode=yes -o ConnectTimeout=5", ok()),
         ("command -v adb", ok("/usr/bin/adb\n")),
         ("lsusb -d 2833:", ok("Bus 004 Device 022: ID 2833:5018 Oculus VR, Inc. Quest Pro\n")),
         ("adb devices -l", ok("List of devices attached\n230YC01DBS006V         device usb:4-2 product:seacliff model:Quest_Pro device:seacliff transport_id:12\n\n")),
         ("pm list packages", ok("package:com.oculus.x\npackage:org.meumeu.wivrn.github\npackage:org.meumeu.wivrn\n")),
         ("dumpsys package org.meumeu.wivrn.github | grep -m1 versionName", ok("    versionName=26.9\n")),
         ("dumpsys package org.meumeu.wivrn | grep -m1 versionName", ok("    versionName=26.6\n")),
         ("TRACKING.*granted", ok("      com.oculus.permission.HAND_TRACKING: granted=true\n        com.oculus.permission.EYE_TRACKING: granted=true, flags=[ USER_SET ]\n")),
         ("HeadsetConnected", ok("b true\n")),
         ("HandTracking", ok("b true\n")),
         ("EyeGaze", ok("b true\n")),
         ("SystemName", ok("s \"Meta Quest Pro\"\n"))]
    }

    /// The ready host with some answers replaced (first match wins: prepend).
    static func ready(with overrides: [(String, HeadsetCommandResult)]) -> StandInRunner { StandInRunner(answers: overrides + ready) }
}

@Suite struct HeadsetChecklistTests {
    func check(_ runner: StandInRunner, host: HeadsetViewerHost = .ssh("tester@workstation"), connection: HeadsetConnectionKind = .usb,
               route: HeadsetRoute? = .sshSocket(destination: "tester@sim-host", socket: "/data/run/vp.sock")) async -> HeadsetReport {
        var s = HeadsetSettings()
        s.connection = connection
        return await HeadsetChecker(host: host, settings: s, route: route, runner: runner).run()
    }

    @Test func aWorkingSetupIsReadyAndConnected() async {
        let r = await check(StandInRunner(answers: StandInRunner.ready))
        #expect(r.checks.map(\.id) == HeadsetCheckID.allCases)
        #expect(r.checks.allSatisfy { $0.state == .ok }, "\(r.checks.filter { $0.state != .ok })")
        #expect(r.isReady && r.isConnected && r.status == .ready)
        #expect(r.check(.vulkan)?.reason == "NVIDIA GeForce RTX 4060 Ti")
        #expect(r.check(.headsetUSB)?.reason == "Quest Pro")
        // The app that matches the server's version is the one used.
        #expect(r.clientPackage == "org.meumeu.wivrn.github" && r.serial == "230YC01DBS006V" && r.serverVersion == "26.9")
        #expect(r.check(.connection)?.reason == "Meta Quest Pro")
        #expect(r.firstProblemStep == .connect)
    }

    @Test func noViewerHostOnAMacSaysWhy() async {
        let r = await check(StandInRunner(answers: StandInRunner.ready), host: .none)
        #expect(r.check(.viewerHost)?.state == .missing)
        #expect(r.check(.viewerHost)?.reason.contains("does not run on macOS") == true)
        #expect(r.checks.dropFirst().allSatisfy { $0.state == .unknown })
        #expect(!r.isReady && r.status == .notSetUp && r.firstProblemStep == .viewerHost)
        // Linux: this machine; a Mac without a host: none.
        #expect(HeadsetSettings().host(hubIsLinux: true) == .thisMachine)
        #expect(HeadsetSettings().host(hubIsLinux: false) == .none)
    }

    @Test func viewerHostStates() async {
        let unreachable = await check(StandInRunner.ready(with: [("uname", HeadsetCommandResult(status: 255))]))
        #expect(unreachable.check(.viewerHost)?.fix == .command("ssh-copy-id tester@workstation"))
        let mac = await check(StandInRunner.ready(with: [("uname", StandInRunner.ok("Darwin\n"))]))
        #expect(mac.check(.viewerHost)?.state == .missing && mac.check(.viewerHost)?.reason.contains("needs Linux") == true)
    }

    @Test func workstationPackagesAreCommandsForTheUser() async {
        let r = await check(StandInRunner.ready(with: [
            ("vulkaninfo", StandInRunner.ok("GPU0:\n\tdeviceType = PHYSICAL_DEVICE_TYPE_CPU\n\tdeviceName = llvmpipe\n")),
            ("libopenxr_loader", HeadsetCommandResult(status: 1)),
            ("active_runtime.json", HeadsetCommandResult(status: 1)), ("test -f", HeadsetCommandResult(status: 1)),
            ("wivrn-server --version", HeadsetCommandResult(status: 127)),
            ("--help", HeadsetCommandResult(status: 127)),
        ]))
        #expect(r.check(.vulkan)?.state == .missing && r.check(.vulkan)?.reason.contains("software renderer") == true)
        #expect(r.check(.openXRLoader)?.fix == .command("sudo apt install libopenxr-loader1"))
        #expect(r.check(.openXRRuntime)?.state == .missing)
        #expect(r.check(.wivrnInstalled)?.fix == .command("sudo apt install wivrn-server wivrn-dashboard"))
        #expect(r.check(.wivrnRunning)?.state == .missing)
        #expect(r.check(.xrViewer)?.state == .missing)
        if case .instructions(let w)? = r.check(.xrViewer)?.fix { #expect(w.contains("swift build -c release --product ycode-xr-viewer")) } else { Issue.record("no build words") }
        #expect(!r.isReady && r.firstProblemStep == .workstation)
        // Ycode never runs these: every fix that installs is a command shown, and only commands carry sudo.
        for c in r.checks { if case .command(let cmd)? = c.fix, cmd.contains("apt") { #expect(cmd.hasPrefix("sudo ")) } }
    }

    @Test func unknownVulkanAndAnotherActiveRuntime() async {
        let r = await check(StandInRunner.ready(with: [("vulkaninfo", HeadsetCommandResult(status: 127)),
                                                       ("active_runtime.json", StandInRunner.ok("{\"runtime\": {\"name\": \"Monado\"}}"))]))
        #expect(r.check(.vulkan)?.state == .unknown && r.check(.vulkan)?.fix == .command("sudo apt install vulkan-tools"))
        // WiVRn's manifest is there: it takes over while connected, and the viewer names it for itself.
        #expect(r.check(.openXRRuntime)?.state == .ok && r.check(.openXRRuntime)?.reason.contains("Another runtime") == true)
        #expect(r.isReady)
    }

    @Test func serverNotRunningAndOldViewer() async {
        let r = await check(StandInRunner.ready(with: [("pgrep -x wivrn-server", HeadsetCommandResult(status: 1)),
                                                       ("--help", StandInRunner.ok("usage: ycode-xr-viewer [--connect <address>]\n"))]))
        #expect(r.check(.wivrnRunning)?.fix == .command("systemctl --user start wivrn"))
        #expect(r.check(.xrViewer)?.reason.contains("--state-file") == true && !r.viewerHasControl)
        #expect(!r.isReady)
    }

    @Test func routeToTheSimulator() async {
        let bad = await check(StandInRunner.ready(with: [("ssh -o BatchMode=yes -o ConnectTimeout=5", HeadsetCommandResult(status: 255))]))
        #expect(bad.check(.simulatorRoute)?.fix == .command("ssh-copy-id tester@sim-host"))
        let link = await check(StandInRunner(answers: StandInRunner.ready), route: .link(device: "vp", host: "thor"))
        #expect(link.check(.simulatorRoute)?.state == .ok)
        let none = await check(StandInRunner(answers: StandInRunner.ready), route: nil)
        #expect(none.check(.simulatorRoute)?.state == .unknown && none.isReady)
    }

    @Test func headsetUSBStates() async {
        let devs = "adb devices -l"
        func usb(_ adb: String, lsusb: Bool = true) async -> HeadsetCheck? {
            await check(StandInRunner.ready(with: [(devs, StandInRunner.ok("List of devices attached\n" + adb)),
                                                   ("lsusb -d", lsusb ? StandInRunner.ok("Bus 004 Device 022: ID 2833:5018\n") : HeadsetCommandResult(status: 1))])).check(.headsetUSB)
        }
        let none = await usb("", lsusb: false)
        #expect(none?.state == .missing && none?.reason == "Not connected.")
        let unauthorized = await usb("230YC01DBS006V unauthorized usb:4-2 transport_id:3\n")
        #expect(unauthorized?.reason == "Unauthorized." && unauthorized?.fix == .instructions("Put the headset on and accept Allow USB debugging (Always allow from this computer)."))
        let developer = await usb("")
        #expect(developer?.reason.contains("developer mode is needed") == true)
        if case .instructions(let w)? = developer?.fix { #expect(w.contains("Meta Horizon app")) } else { Issue.record("no words") }
        let permissions = await usb("230YC01DBS006V no permissions (user in plugdev group; are your udev rules wrong?)\n")
        #expect(permissions?.state == .missing && permissions?.reason.contains("may not open") == true)
        let offline = await usb("230YC01DBS006V offline\n")
        #expect(offline?.reason == "adb says offline.")
        // An emulator is not a headset.
        let emulator = await usb("emulator-5554 device\n", lsusb: false)
        #expect(emulator?.reason == "Not connected.")
        // No adb: missing over USB, optional over Wi-Fi.
        let noADB = await check(StandInRunner.ready(with: [("command -v adb", HeadsetCommandResult(status: 1))]))
        #expect(noADB.check(.adb)?.fix == .command("sudo apt install adb") && !noADB.isReady)
        let wifi = await check(StandInRunner.ready(with: [("command -v adb", HeadsetCommandResult(status: 1)), ("lsusb", HeadsetCommandResult(status: 1))]),
                               connection: .wifi)
        #expect(wifi.check(.adb)?.state == .unknown && wifi.check(.headsetUSB)?.state == .unknown && wifi.check(.clientApp)?.state == .unknown)
        #expect(wifi.isReady)
    }

    @Test func clientAppAndVersions() async {
        let missing = await check(StandInRunner.ready(with: [("pm list packages", StandInRunner.ok("package:com.oculus.x\n"))]))
        #expect(missing.check(.clientApp)?.state == .missing)
        guard case .installClient(let p)? = missing.check(.clientApp)?.fix else { Issue.record("no install offer"); return }
        #expect(p.version == "26.9" && p.url == "https://github.com/WiVRn/WiVRn/releases/download/v26.9/WiVRn-release.apk")
        #expect(p.sha256 == "1df6649ec77224fcc821af0ab4897222bdf3d7eb6ce6ad636461336724111331")
        #expect(p.explanation.contains("GPLv3") && p.explanation.contains("not part of Ycode") && p.explanation.contains("Meta Store"))
        // Only the older app: a version mismatch with the matching install offered.
        let old = await check(StandInRunner.ready(with: [("pm list packages", StandInRunner.ok("package:org.meumeu.wivrn\n"))]))
        #expect(old.check(.clientApp)?.state == .ok && old.clientPackage == "org.meumeu.wivrn")
        #expect(old.check(.clientVersion)?.state == .missing && old.check(.clientVersion)?.reason == "The app is 26.6, the server 26.9; they must be the same version.")
        #expect(old.check(.clientVersion)?.fix == .installClient(HeadsetClientPackage(version: "26.9")))
        // A release Ycode has no checksum for: said so before anything is downloaded.
        #expect(HeadsetClientPackage(version: "27.0").sha256 == nil)
        #expect(HeadsetClientPackage(version: "27.0").explanation.contains("not verified"))
    }

    @Test func trackingStates() async {
        // Before the headset connects: the permissions decide.
        let before = await check(StandInRunner.ready(with: [("HeadsetConnected", StandInRunner.ok("b false\n"))]))
        #expect(before.check(.handTracking)?.state == .unknown && before.check(.eyeTracking)?.state == .unknown)
        #expect(before.check(.connection)?.state == .missing && before.check(.connection)?.fix == .connect)
        #expect(before.isReady && !before.isConnected)
        let denied = await check(StandInRunner.ready(with: [
            ("HeadsetConnected", StandInRunner.ok("b false\n")),
            ("TRACKING.*granted", StandInRunner.ok("com.oculus.permission.HAND_TRACKING: granted=false\ncom.oculus.permission.EYE_TRACKING: granted=false\n"))]))
        #expect(denied.check(.handTracking)?.state == .missing && denied.check(.eyeTracking)?.state == .missing)
        if case .instructions(let w)? = denied.check(.eyeTracking)?.fix { #expect(w.contains("App permissions ▸ Eye Tracking")) } else { Issue.record("no words") }
        // Optional: Ready stays.
        #expect(denied.isReady)
        // A headset without eye tracking.
        let quest3 = await check(StandInRunner.ready(with: [
            ("adb devices -l", StandInRunner.ok("List of devices attached\n2G0Y device usb:1-1 model:Quest_3 \n")),
            ("HeadsetConnected", StandInRunner.ok("b false\n"))]))
        #expect(quest3.check(.eyeTracking)?.reason.contains("Quest 3 has no eye tracking") == true)
        // Connected, the server says what it offers.
        let noEyes = await check(StandInRunner.ready(with: [("EyeGaze", StandInRunner.ok("b false\n"))]))
        #expect(noEyes.check(.eyeTracking)?.state == .missing)
        // No server answering on D-Bus.
        let noBus = await check(StandInRunner.ready(with: [("busctl", HeadsetCommandResult(status: 1))]))
        #expect(noBus.check(.connection)?.state == .unknown)
        // Over Wi-Fi, connecting is the headset's own choice.
        let wifi = await check(StandInRunner.ready(with: [("HeadsetConnected", StandInRunner.ok("b false\n"))]), connection: .wifi)
        if case .instructions? = wifi.check(.connection)?.fix {} else { Issue.record("Wi-Fi should explain") }
    }

    @Test func checksOnlyLook() async {
        let runner = StandInRunner(answers: StandInRunner.ready)
        _ = await check(runner)
        for c in runner.log.all {
            #expect(!c.contains("sudo") && !c.contains("install") && !c.contains("am start") && !c.contains("reverse") && !c.contains("curl"), "\(c)")
        }
    }

    @Test func actionsAreTheExactCommands() {
        #expect(HeadsetActions.connectCommand(serial: "230YC01DBS006V", package: "org.meumeu.wivrn.github")
                == "adb -s 230YC01DBS006V reverse tcp:9757 tcp:9757 && adb -s 230YC01DBS006V shell am start -a android.intent.action.VIEW -d wivrn+tcp://localhost org.meumeu.wivrn.github")
        let install = HeadsetActions.installCommand(serial: "S1", package: HeadsetClientPackage(version: "26.9"))
        #expect(install.contains("curl -fL --retry 2 -o \"$d/WiVRn-release.apk\" https://github.com/WiVRn/WiVRn/releases/download/v26.9/WiVRn-release.apk"))
        #expect(install.contains("sha256sum -c -") && install.contains("adb -s S1 install -r") && install.contains("rm -rf \"$d\""))
        #expect(!install.contains("sudo"))
        #expect("a b'c".shellQuoted == "'a b'\\''c'" && "user@host".shellQuoted == "user@host")
    }

    @Test func onboardingSteps() {
        #expect(HeadsetSetupStep.allCases.map(\.title) == ["Viewer Host", "Workstation", "Headset", "Tracking", "Connect"])
        #expect(Set(HeadsetSetupStep.allCases.flatMap(\.checks)) == Set(HeadsetCheckID.allCases))
        #expect(HeadsetStatus.allCases.map(\.rawValue) == ["Not Set Up", "Ready", "In Headset"])
    }

    /// ssh refuses a control path of 104 bytes or more (`%C` is 40 characters, plus its temporary suffix).
    @Test func sshControlPathFits() throws {
        let args = SSHHeadsetRunner(destination: "tester@workstation").arguments
        let path = try #require(args.first { $0.hasPrefix("ControlPath=") }).dropFirst("ControlPath=".count)
        #expect(path.replacingOccurrences(of: "%C", with: String(repeating: "x", count: 40)).utf8.count + 17 < 104)
    }

    /// A command's end is the shell's exit, even when something it left detached keeps the pipe.
    @Test func aDetachedProcessDoesNotHoldACommand() async {
        let t0 = Date()
        let r = await LocalHeadsetRunner().run("echo started; sleep 6 & exit 0")
        #expect(r.ok && r.output.contains("started") && Date().timeIntervalSince(t0) < 5)
    }

    @Test func settingsPersist() {
        let d = UserDefaults(suiteName: "HeadsetSetupTests-\(UUID().uuidString)")!
        var s = HeadsetSettings()
        s.viewerHost = "tester@workstation"
        s.connection = .wifi
        s.save(d)
        #expect(HeadsetSettings.load(d) == s)
        #expect(s.host(hubIsLinux: false) == .ssh("tester@workstation"))
    }
}

@Suite struct HeadsetSwitchTests {
    @Test func machineBothWays() {
        var m = HeadsetSwitch()
        #expect(m.handle(.viewInHeadset) == [.holdDesktopStream, .startViewer] && m.state == .enteringHeadset)
        #expect(m.handle(.viewerStarted).isEmpty && m.state == .enteringHeadset)
        #expect(m.handle(.viewerPhase(.waitingForHeadset)).isEmpty)
        #expect(m.handle(.viewerPhase(.streaming)).isEmpty && m.state == .inHeadset && m.isInHeadset)
        // A second View in Headset does nothing.
        #expect(m.handle(.viewInHeadset).isEmpty)
        #expect(m.handle(.backToDesktop) == [.resumeDesktopStream, .stopViewer] && m.state == .returningToDesktop)
        #expect(m.handle(.viewerStoppedConfirmed).isEmpty && m.state == .desktop)
    }

    @Test func failuresComeBack() {
        var m = HeadsetSwitch()
        _ = m.handle(.viewInHeadset)
        let failed = m.handle(.viewerFailed("no route"))
        #expect(m.state == .desktop && failed.first == .resumeDesktopStream)
        _ = m.handle(.viewInHeadset)
        #expect(m.handle(.timeout).prefix(2) == [.stopViewer, .resumeDesktopStream] && m.state == .returningToDesktop)
        _ = m.handle(.viewerStoppedConfirmed)
        _ = m.handle(.viewInHeadset)
        _ = m.handle(.viewerPhase(.streaming))
        // The wearer quit, or another viewer took over.
        let ended = m.handle(.viewerPhase(.stopped))
        #expect(m.state == .desktop && ended.first == .resumeDesktopStream)
        _ = m.handle(.viewInHeadset)
        #expect(m.handle(.deviceStopped) == [.stopViewer] && m.state == .desktop)
        #expect(m.handle(.deviceStopped).isEmpty)
    }

    /// A launcher whose viewer streams after `streamsAfter` polls.
    final class StandInLauncher: HeadsetViewerLauncher, @unchecked Sendable {
        let lock = NSLock()
        var calls: [String] = []
        var phase = HeadsetViewerPhase.absent
        var streamsAfter = 2
        var polls = 0
        var failStart = false
        func start() async throws {
            lock.withLock { calls.append("start"); phase = .waitingForHeadset }
            if failStart { throw ScriptHeadsetViewerLauncher.Failure(description: "the viewer host refused") }
        }
        func state() async -> HeadsetViewerState {
            lock.withLock {
                polls += 1
                if phase == .waitingForHeadset, polls >= streamsAfter { phase = .streaming }
                return HeadsetViewerState(phase: phase)
            }
        }
        func stop() async { lock.withLock { calls.append("stop"); phase = .stopped } }
    }

    @MainActor final class Desktop: HeadsetDesktopStream {
        var calls: [String] = []
        func holdForHeadset() { calls.append("hold") }
        func returnFromHeadset() { calls.append("resume") }
    }

    @MainActor @Test func controllerDrivesLauncherAndDesktop() async {
        let l = StandInLauncher()
        let d = Desktop()
        let c = HeadsetSwitchController(launcher: l, desktop: d)
        c.pollInterval = 3600  // polled by hand
        await c.viewInHeadset()
        #expect(c.state == .enteringHeadset && d.calls == ["hold"] && l.calls == ["start"])
        await c.tick()
        #expect(c.state == .enteringHeadset)
        await c.tick()
        #expect(c.state == .inHeadset)
        await c.backToDesktop()
        #expect(c.state == .desktop && d.calls == ["hold", "resume"] && l.calls == ["start", "stop"])
        #expect(c.lastSwitch?.done != nil)
    }

    @MainActor @Test func controllerFailureAndTimeout() async {
        let l = StandInLauncher()
        l.failStart = true
        let d = Desktop()
        let c = HeadsetSwitchController(launcher: l, desktop: d)
        c.pollInterval = 3600
        var notices: [String] = []
        c.onNotice = { notices.append($0) }
        await c.viewInHeadset()
        #expect(c.state == .desktop && d.calls == ["hold", "resume"] && notices.first?.contains("the viewer host refused") == true)
        l.failStart = false
        l.streamsAfter = 1000
        c.enterTimeout = 0
        await c.viewInHeadset()
        await c.tick()
        #expect(c.state == .desktop && l.calls.last == "stop" && notices.last?.contains("did not join") == true)
    }

    @Test func viewerPlanCommands() {
        let p = HeadsetViewerPlan(device: "Vision Pro-vision-pro-27.0", route: .sshSocket(destination: "tester@sim-host", socket: "/data/run/vp.sock"),
                                  viewerPath: "/opt/ycode/ycode-xr-viewer", options: ["--foveate"])
        #expect(p.directory == "${XDG_RUNTIME_DIR:-/tmp}/ycode-headset/Vision_Pro-vision-pro-27.0")
        #expect(p.viewerArguments == ["--connect", "unix:$D/display.sock", "--state-file", "$D/state.json", "--foveate"])
        let s = p.startCommand
        #expect(s.contains("-L \"$D/display.sock:/data/run/vp.sock\" tester@sim-host"))
        #expect(s.contains("export XR_RUNTIME_JSON=/usr/share/openxr/1/openxr_wivrn.json"))
        #expect(s.contains("$S nohup /opt/ycode/ycode-xr-viewer --connect \"unix:$D/display.sock\" --state-file \"$D/state.json\" --foveate"))
        #expect(!s.contains("sudo") && !s.contains("--record"))
        // Stop: only the recorded PIDs, only when they are still those programs.
        #expect(p.stopCommand.contains("[ \"$(cat /proc/$p/comm 2>/dev/null)\" = ycode-xr-viewer ]; then kill -TERM \"$p\""))
        #expect(p.stopCommand.contains("= ssh ]; then kill -TERM \"$f\""))
        #expect(!p.stopCommand.contains("pkill") && !p.stopCommand.contains("killall"))
        let link = HeadsetViewerPlan(device: "vp", route: .link(device: "vp", host: "thor"))
        #expect(link.viewerArguments.prefix(4) == ["--link", "vp", "--host", "thor"])
        #expect(!link.startCommand.contains("ssh -N"))
        #expect(HeadsetViewerPlan.parseState("{\"phase\":\"streaming\",\"pid\":42}\n") == HeadsetViewerState(phase: .streaming, pid: 42))
        #expect(HeadsetViewerPlan.parseState("garbage") == HeadsetViewerState(phase: .absent))
    }

    /// The plan's shell, run for real on this machine with a stand-in viewer
    /// (a shell script that writes the state file and ends on SIGTERM).
    @Test func viewerPlanRunsLocally() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("headset-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let viewer = dir.appendingPathComponent("ycode-xr-viewer")
        try """
        #!/bin/sh
        state=""; while [ $# -gt 0 ]; do [ "$1" = --state-file ] && state=$2; shift; done
        trap 'echo "{\\"phase\\":\\"stopped\\"}" > "$state"; exit 0' TERM
        echo '{"phase":"waitingForHeadset"}' > "$state"; sleep 0.3; echo '{"phase":"streaming"}' > "$state"
        while :; do sleep 0.05; done
        """.write(to: viewer, atomically: true, encoding: .utf8)
        chmod(viewer.path, 0o755)
        var plan = HeadsetViewerPlan(device: "plan-\(getpid())", route: .link(device: "vp", host: nil), viewerPath: viewer.path, runtimeManifest: nil)
        plan.options = []
        let l = ScriptHeadsetViewerLauncher(runner: LocalHeadsetRunner(), plan: plan)
        try await l.start()
        var phase = HeadsetViewerPhase.absent
        for _ in 0..<60 {
            phase = await l.state().phase
            if phase == .streaming { break }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        #expect(phase == .streaming)
        #if os(Linux)
        await l.stop()
        #expect(await l.state().phase == .stopped)
        #else
        // macOS has no /proc: stop's PID check refuses, so end the stand-in by its recorded PID here.
        let pid = await LocalHeadsetRunner().run("cat \"${XDG_RUNTIME_DIR:-/tmp}/ycode-headset/\(plan.device)/viewer.pid\"").output.trimmed
        _ = await LocalHeadsetRunner().run("kill -TERM \(pid)")
        try await Task.sleep(nanoseconds: 300_000_000)
        #expect(await l.state().phase == .stopped)
        _ = await LocalHeadsetRunner().run("rm -rf \"${XDG_RUNTIME_DIR:-/tmp}/ycode-headset/\(plan.device)\"")
        #endif
    }
}

extension HeadsetStatus: CaseIterable {
    public static var allCases: [HeadsetStatus] { [.notSetUp, .ready, .inHeadset] }
}
