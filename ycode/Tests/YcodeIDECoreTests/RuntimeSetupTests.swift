import Foundation
import Testing
@testable import YcodeIDECore

/// B2-RUNTIME (#68–#70, `specs/simulator/runtime-onboarding.md` §7–§11): the
/// runtime wizard's checklist against stand-in command runners, CoreSimulator's
/// listings, a fake runtime bundle in a temporary folder, the host checks,
/// the copy's commands and states, the setup script's output and the KVM SVE
/// decision. Nothing is added to or removed from this Mac's CoreSimulator.
@Suite struct RuntimeSetupTests {
    typealias R = StandInRunner

    // MARK: Fixtures

    static let images = """
    {"A1":{"build":"24A434","deletable":true,"identifier":"A1","kind":"Patchable Cryptex Disk Image","platformIdentifier":"com.apple.platform.iphonesimulator",
    "runtimeBundlePath":"/Volumes/iOS_24A434/Runtimes/iOS 27.0.simruntime","runtimeIdentifier":"com.apple.CoreSimulator.SimRuntime.iOS-27-0",
    "signatureState":"Verified","sizeBytes":7873719649,"state":"Ready","supportedArchitectures":["arm64"],"version":"27.0","lastUsedAt":"2026-11-01T10:00:00Z"},
    "B2":{"build":"24A94401","identifier":"B2","platformIdentifier":"com.apple.platform.iphonesimulator","runtimeIdentifier":"com.apple.CoreSimulator.SimRuntime.iOS-27-1",
    "sizeBytes":8067000161,"state":"Ready","supportedArchitectures":["arm64"],"version":"27.1"},
    "C3":{"build":"24M362","identifier":"C3","platformIdentifier":"com.apple.platform.xrsimulator","runtimeIdentifier":"com.apple.CoreSimulator.SimRuntime.xrOS-27-0",
    "sizeBytes":7300000000,"state":"Unusable","supportedArchitectures":["arm64"],"version":"27.0"}}
    """

    static let runtimes = """
    {"runtimes":[{"identifier":"com.apple.CoreSimulator.SimRuntime.iOS-27-0","buildversion":"24A434","version":"27.0","platform":"iOS","isAvailable":true,
    "runtimeRoot":"/Volumes/iOS_24A434/Runtimes/iOS 27.0.simruntime/Contents/Resources/RuntimeRoot","lastUsage":{"arm64":"0001-01-01T00:00:00Z"}},
    {"identifier":"com.apple.CoreSimulator.SimRuntime.iOS-27-1","buildversion":"24A94401","version":"27.1","platform":"iOS","isAvailable":false,
    "availabilityError":"runtime profile not found"},
    {"identifier":"com.apple.CoreSimulator.SimRuntime.watchOS-26-5","buildversion":"23T570","version":"26.5","platform":"watchOS","isAvailable":true}]}
    """

    static func plist(_ d: [String: Any]) -> Data {
        try! PropertyListSerialization.data(fromPropertyList: d, format: .xml, options: 0)
    }

    static let systemVersion = plist(["ProductName": "iPhone OS", "ProductVersion": "27.0", "ProductBuildVersion": "24A434"])

    /// A fake `iOS 27.0.simruntime` with a 3-file RuntimeRoot.
    static func fakeBundle(in dir: URL, name: String = "iOS 27.0.simruntime", product: String = "iPhone OS", version: String = "27.0",
                           build: String = "24A434", platformID: String = "com.apple.platform.iphonesimulator") throws -> URL {
        let b = dir.appendingPathComponent(name)
        let fm = FileManager.default
        let root = b.appendingPathComponent("Contents/Resources/RuntimeRoot")
        try fm.createDirectory(at: root.appendingPathComponent("System/Library/CoreServices"), withIntermediateDirectories: true)
        try plist(["CFBundleIdentifier": "com.apple.CoreSimulator.SimRuntime.iOS-27-0", "CFBundleName": "iOS 27.0"])
            .write(to: b.appendingPathComponent("Contents/Info.plist"))
        try plist(["defaultVersionString": version, "platformIdentifier": platformID, "supportedArchs": ["arm64"]])
            .write(to: b.appendingPathComponent("Contents/Resources/profile.plist"))
        try plist(["ProductName": product, "ProductVersion": version, "ProductBuildVersion": build])
            .write(to: root.appendingPathComponent("System/Library/CoreServices/SystemVersion.plist"))
        try fm.createDirectory(at: root.appendingPathComponent("usr/lib"), withIntermediateDirectories: true)
        try Data(repeating: 7, count: 4096).write(to: root.appendingPathComponent("usr/lib/libfake.dylib"))
        return b
    }

    static func temp() -> URL {
        let u = FileManager.default.temporaryDirectory.appendingPathComponent("ycode-runtime-tests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }

    static let mac = SetupMachine(isMac: true, architecture: "arm64")
    static let arm = SetupMachine(isMac: false, architecture: "aarch64")
    static let x86 = SetupMachine(isMac: false, architecture: "x86_64")

    // MARK: Catalog

    @Test func platformsFromEverySpelling() {
        #expect(SimPlatform(name: "iPhone OS") == .iOS)
        #expect(SimPlatform(name: "Watch OS") == .watchOS)
        #expect(SimPlatform(name: "xrOS") == .visionOS)
        #expect(SimPlatform(name: "com.apple.CoreSimulator.SimRuntime.tvOS-27-0") == .tvOS)
        #expect(SimPlatform(name: "macOS") == nil)
        #expect(SimPlatform.visionOS.runtimeToken == "xrOS")
    }

    @Test func sizesAsSimctlPrintsThem() {
        #expect(RuntimeSize.format(7_873_719_649) == "7.3 GB")
        #expect(RuntimeSize.format(512) == "512 bytes")
        #expect(RuntimeSize.format(1536) == "1.5 KB")
    }

    @Test func listingsJoinOnIdentifierAndBuild() {
        let list = SimctlRuntimeListing.parse(images: Data(Self.images.utf8), runtimes: Data(Self.runtimes.utf8))
        #expect(list.map(\.title) == ["iOS 27.1 (24A94401)", "iOS 27.0 (24A434)", "watchOS 26.5 (23T570)", "visionOS 27.0 (24M362)"])
        let ios27 = list[1]
        #expect(ios27.sizeText == "7.3 GB" && ios27.isUsable && ios27.imageUUID == "A1" && ios27.lastUsed == "2026-11-01T10:00:00Z")
        #expect(ios27.runtimeRoot?.hasSuffix("iOS 27.0.simruntime/Contents/Resources/RuntimeRoot") == true)
        #expect(!list[0].isUsable && list[0].availabilityError == "runtime profile not found")
        #expect(!list[3].isUsable)
        // CoreSimulator's runtimes are never Ycode's to remove.
        #expect(!list.contains { $0.isRemovable })
    }

    @Test func fakeBundleIsReadFromItsPropertyLists() throws {
        let dir = Self.temp()
        defer { try? FileManager.default.removeItem(at: dir) }
        let b = try Self.fakeBundle(in: dir)
        #expect(RuntimeBundleReader.kind(of: b.path) == .bundle)
        #expect(RuntimeBundleReader.kind(of: b.path + "/Contents/Resources/RuntimeRoot") == .runtimeRoot)
        #expect(RuntimeBundleReader.kind(of: dir.path + "/iOS 27.0 Simulator Runtime.dmg") == .diskImage)
        #expect(RuntimeBundleReader.kind(of: dir.path) == .unknown)
        let r = try #require(RuntimeBundleReader.read(b.path, measure: true))
        #expect(r.title == "iOS 27.0 (24A434)" && r.identifier == "com.apple.CoreSimulator.SimRuntime.iOS-27-0")
        #expect(r.unpackedBytes ?? 0 >= 4096)
        #expect(r.folderName == "iOS-27.0-24A434")
        let vision = try Self.fakeBundle(in: dir, name: "xrOS 27.0.simruntime", product: "xrOS", build: "24M362", platformID: "com.apple.platform.xrsimulator")
        #expect(RuntimeBundleReader.read(vision.path)?.platform == .visionOS)
    }

    @Test func copyIntoYcodesFolderThenListThenRemove() throws {
        let dir = Self.temp()
        defer { try? FileManager.default.removeItem(at: dir) }
        let b = try Self.fakeBundle(in: dir)
        let r = try #require(RuntimeBundleReader.read(b.path, measure: true))
        let folder = dir.appendingPathComponent("runtimes").path
        let copy = RuntimeCommands.copyLocal(source: r.runtimeRoot!, folder: folder, record: r, markerJSON: RuntimeMarker(r, source: "test").json)
        #expect(shell(copy) == 0)
        let listed = RuntimeBundleReader.ycodeRuntimes(in: folder)
        #expect(listed.map(\.title) == ["iOS 27.0 (24A434)"])
        #expect(listed[0].isRemovable && listed[0].owner == .ycode(folder: folder + "/iOS-27.0-24A434"))
        // Running the copy again (a resume) changes nothing.
        #expect(shell(copy) == 0)
        #expect(RuntimeBundleReader.ycodeRuntimes(in: folder).count == 1)
        // Remove refuses anything but one runtime folder inside Ycode's.
        #expect(RuntimeCommands.remove(path: folder, folder: folder) == nil)
        #expect(RuntimeCommands.remove(path: "/", folder: folder) == nil)
        #expect(RuntimeCommands.remove(path: folder + "/../x", folder: folder) == nil)
        #expect(RuntimeCommands.remove(path: dir.path + "/runtimes-other/x", folder: folder) == nil)
        let rm = try #require(RuntimeCommands.remove(path: folder + "/iOS-27.0-24A434", folder: folder))
        #expect(shell(rm) == 0)
        #expect(RuntimeBundleReader.ycodeRuntimes(in: folder).isEmpty)
        #expect(FileManager.default.fileExists(atPath: b.path))
    }

    func shell(_ cmd: String) -> Int32 {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", cmd]
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try? p.run()
        p.waitUntilExit()
        return p.terminationStatus
    }

    // MARK: This machine's checklist (#68)

    static var macReady: [(String, HeadsetCommandResult)] {
        [("xcrun --find simctl", R.ok("/Applications/Xcode.app/Contents/Developer/usr/bin/simctl\n")),
         ("simctl runtime list -j", R.ok(images)), ("simctl list runtimes -j", R.ok(runtimes)),
         ("df -Pk", R.ok("209715200\n"))]
    }

    func choices(_ ps: Set<SimPlatform>, host: Bool = false) -> RuntimeSetupChoices {
        var c = RuntimeSetupChoices()
        c.platforms = ps
        c.useHost = host
        return c
    }

    @Test func macWithXcodesRuntimes() async {
        let dir = Self.temp()
        defer { try? FileManager.default.removeItem(at: dir) }
        let r = await RuntimeSetupChecker(machine: Self.mac, choices: choices([.iOS, .visionOS, .tvOS]), runner: R(answers: Self.macReady), folder: dir.path).run()
        #expect(r.check("machine")?.state == .ok)
        #expect(r.check("tools")?.state == .ok)
        let ios = r.check("runtime.iOS")
        #expect(ios?.state == .ok && ios?.reason == "iOS 27.0 (24A434), 7.3 GB.")
        let vision = r.check("runtime.visionOS")
        #expect(vision?.state == .missing && vision?.reason.contains("cannot be used") == true)
        // Xcode's runtime is not Ycode's to remove: the fix is words.
        if case .instructions = vision?.fix {} else { Issue.record("expected instructions, got \(String(describing: vision?.fix))") }
        let tv = r.check("runtime.tvOS")
        #expect(tv?.state == .missing && tv?.fix == .step(.add))
        #expect(r.check("disk")?.state == .ok)
        #expect(r.readyPlatforms == [.iOS])
        #expect(r.firstProblemStep(for: .thisMachine) == .runtimes)
        #expect(r.state(of: .target) == .ok)
    }

    @Test func deploymentTargetAboveEveryRuntime() async {
        var c = choices([.iOS])
        c.minimumVersions[.iOS] = "28.0"
        let r = await RuntimeSetupChecker(machine: Self.mac, choices: c, runner: R(answers: Self.macReady), folder: "/nonexistent").run()
        #expect(r.check("runtime.iOS")?.state == .missing)
        #expect(r.check("runtime.iOS")?.reason.contains("older than the deployment target 28.0") == true)
    }

    @Test func noXcodeAndLowDiskThenRetry() async {
        let runner = R(answers: [("df -Pk", R.ok("1048576\n"))])
        let r = await RuntimeSetupChecker(machine: Self.mac, choices: choices([.iOS]), runner: runner, folder: "/nonexistent").run()
        #expect(r.check("tools")?.state == .missing && r.check("tools")?.fix == .command("xcodebuild -runFirstLaunch"))
        #expect(r.check("runtime.iOS")?.state == .missing)
        #expect(r.check("disk")?.state == .missing && r.check("disk")?.reason.hasPrefix("1.0 GB free") == true)
        // Re-check runs every command again.
        let again = await RuntimeSetupChecker(machine: Self.mac, choices: choices([.iOS]), runner: R(answers: Self.macReady), folder: "/nonexistent").run()
        #expect(again.check("tools")?.state == .ok && again.check("runtime.iOS")?.state == .ok)
        let unreadable = await RuntimeSetupChecker(machine: Self.mac, choices: choices([.iOS]), runner: R(answers: []), folder: "/nonexistent").run()
        #expect(unreadable.check("disk")?.state == .unknown)
    }

    @Test func linuxMachines() async throws {
        let dir = Self.temp()
        defer { try? FileManager.default.removeItem(at: dir) }
        // x86-64: the simulator runs elsewhere.
        let x = await RuntimeSetupChecker(machine: Self.x86, choices: choices([.iOS]), runner: R(answers: []), folder: dir.path).run()
        #expect(x.check("machine")?.state == .missing && x.check("machine")?.fix == .step(.host))
        // arm64 without access to /dev/kvm, with a runtime in Ycode's folder.
        let b = try Self.fakeBundle(in: dir)
        let rec = try #require(RuntimeBundleReader.read(b.path))
        let folder = dir.appendingPathComponent("rt").path
        _ = shell(RuntimeCommands.copyLocal(source: rec.runtimeRoot!, folder: folder, record: rec, markerJSON: RuntimeMarker(rec, source: "t").json))
        let a = await RuntimeSetupChecker(machine: Self.arm, choices: choices([.iOS]), runner: R(answers: [("/dev/kvm", R.ok("denied\n")), ("df -Pk", R.ok("99999999\n"))]),
                                          folder: folder).run()
        #expect(a.check("kvm")?.state == .missing && a.check("kvm")?.fix == .command("sudo usermod -aG kvm $USER"))
        #expect(a.check("runtime.iOS")?.state == .ok)
        #expect(a.local.first?.isRemovable == true)
        #expect(a.check("tools") == nil)
    }

    @Test func stepsPerTarget() {
        #expect(RuntimeSetupStep.steps(for: .thisMachine) == [.target, .runtimes, .add, .finish])
        #expect(RuntimeSetupStep.steps(for: .host(RuntimeHostSettings())) == [.target, .host, .prepare, .runtimes, .add, .finish])
        #expect(RuntimeSetupChecker.acquisitionNote(.visionOS).contains("xcodebuild -downloadPlatform visionOS"))
        #expect(RuntimeImportTool.simctl.command(file: "/tmp/iOS 27.dmg") == ["xcrun", "simctl", "runtime", "add", "/tmp/iOS 27.dmg"])
        #expect(RuntimeImportTool.xcodebuild.command(file: "/tmp/a.dmg") == ["xcodebuild", "-importPlatform", "/tmp/a.dmg"])
    }

    // MARK: The host (#69)

    static let host = RuntimeHostSettings(destination: "tester@sim-host", dataDirectory: "/data/ycode")

    static func listing(marker: Bool) -> String {
        let sv = systemVersion.base64EncodedString()
        let m = Data(#"{"platform":"iOS","version":"27.0","build":"24A434","source":"t","copiedAt":"x","sizeBytes":17179869184}"#.utf8).base64EncodedString()
        return "RT\t/data/ycode/runtimes/iOS-27.0-24A434\t-\t\(sv)\t\(marker ? m : "-")\nRT\t/rt/iOS-27.0/RuntimeRoot\t1024\t\(sv)\t-\nIN\t/data/ycode/runtimes/xrOS-27.0-24M362.incoming\t2048\n"
    }

    static var hostReady: [(String, HeadsetCommandResult)] {
        [("uname -sm", R.ok("Linux aarch64\n")), ("/dev/kvm", R.ok("access\n")), ("--version", R.ok("ycode 1.0.0-beta.2 (abc)\n")),
         ("b64()", R.ok(listing(marker: true))), ("df -Pk", R.ok("524288000\n"))]
    }

    @Test func hostReadyWithARuntimeAndAStoppedCopy() async {
        let c = RuntimeHostChecker(host: Self.host, choices: choices([.iOS, .visionOS], host: true), runner: R(answers: Self.hostReady),
                                   pairedHosts: ["sim-host"], localVersion: "1.0.0-beta.2")
        let r = await c.run()
        for id in ["host.reach", "host.link", "host.platform", "host.kvm", "host.version", "host.disk", "host.runtime.iOS"] {
            #expect(r.check(id)?.state == .ok, "\(id): \(r.check(id)?.reason ?? "none")")
        }
        #expect(r.check("host.runtime.visionOS")?.state == .missing)
        #expect(r.check("transfer")?.reason.contains("stopped after 2.0 MB") == true)
        #expect(r.host.count == 2)
        #expect(r.host.filter(\.isRemovable).map(\.runtimeRoot) == ["/data/ycode/runtimes/iOS-27.0-24A434/RuntimeRoot"])
        #expect(r.host.first { !$0.isRemovable }?.owner == .external)
        #expect(r.host[0].unpackedBytes == 17_179_869_184)
    }

    @Test func offlineHostIsUnknownNotMissing() async {
        let r = await RuntimeHostChecker(host: Self.host, choices: choices([.iOS], host: true), runner: R(answers: [])).run()
        #expect(r.check("host.reach")?.state == .unknown && r.check("host.reach")?.reason.contains("offline") == true)
        #expect(r.checks.allSatisfy { $0.state == .unknown })
        #expect(r.check("host.runtime.iOS")?.reason == "The host is offline.")
        let none = await RuntimeHostChecker(host: RuntimeHostSettings(), choices: choices([.iOS], host: true), runner: R(answers: [])).run()
        #expect(none.check("host.reach")?.state == .missing)
    }

    @Test func wrongHostVersionLinkAndPlatform() async {
        var answers = Self.hostReady
        answers[0] = ("uname -sm", R.ok("Linux x86_64\n"))
        answers[2] = ("--version", R.ok("ycode 1.0.0-beta.1\n"))
        let r = await RuntimeHostChecker(host: Self.host, choices: choices([.iOS], host: true), runner: R(answers: answers), localVersion: "1.0.0-beta.2").run()
        #expect(r.check("host.platform")?.state == .missing)
        #expect(r.check("host.version")?.reason == "The host has 1.0.0-beta.1, this machine 1.0.0-beta.2. Prepare Host installs Ycode 1.0.0-beta.2 there.")
        #expect(r.check("host.link")?.fix == .command("ycode sim remote pair sim-host <code> --name sim-host"))
        #expect(RuntimeHostChecker.version(inVersionOutput: "ycode 1.0.0-beta.1 (117f08e)") == "1.0.0-beta.1")
    }

    @Test func transferCommandsAndStates() {
        let rec = SimRuntimeRecord(platform: .iOS, version: "27.0", build: "24A434", unpackedBytes: 16 << 30)
        let t = RuntimeTransfer(source: "/src/RuntimeRoot", record: rec, host: Self.host, totalBytes: 16 << 30)
        #expect(t.incoming == "/data/ycode/runtimes/iOS-27.0-24A434.incoming")
        #expect(t.rsyncArguments(ssh: "/usr/bin/ssh") == ["-a", "--partial", "-e", "/usr/bin/ssh -o BatchMode=yes -o ConnectTimeout=10 -o ServerAliveInterval=15",
                                                          "/src/RuntimeRoot/", "tester@sim-host:/data/ycode/runtimes/iOS-27.0-24A434.incoming/RuntimeRoot/"])
        #expect(t.finishCommand(markerJSON: "{}").hasSuffix("&& mv /data/ycode/runtimes/iOS-27.0-24A434.incoming /data/ycode/runtimes/iOS-27.0-24A434"))
        #expect(t.progressText(copiedKB: 4 << 20) == "4.0 GB of 16.0 GB (25%)")
        #expect(RuntimeTransferState.after(rsyncStatus: 0, copiedKB: 1) == .finished)
        #expect(RuntimeTransferState.after(rsyncStatus: 128 + 15, copiedKB: 5) == .interrupted(copiedKB: 5, reason: "The copy stopped (rsync status 143)."))
        #expect(RuntimeTransferState.after(rsyncStatus: 255, copiedKB: 5) == .interrupted(copiedKB: 5, reason: "The connection to the host was lost."))
        #expect(RuntimeTransferState.after(rsyncStatus: 2, copiedKB: 5) == .failed("rsync failed with status 2."))
    }

    // MARK: Host setup (#70)

    static let setupOutput = """
    some noise from the login shell
    YCODE-SETUP mode=report version=1
    YCODE-FACT arch=aarch64
    YCODE-FACT kernel=6.8.12-tegra
    YCODE-USER data-folders mkdir -p /data/ycode/runtimes
    YCODE-ROOT kvm-group usermod -aG kvm tester
    YCODE-CHECK setup.os ok Linux (ubuntu 24.04).
    YCODE-CHECK setup.kvm missing /dev/kvm belongs to the kvm group; tester is not in it.
    YCODE-CHECK setup.data missing /data/ycode does not exist yet.
    YCODE-CHECK setup.firewall unknown ufw is on.
    YCODE-SVE arch=aarch64 sve=yes kvm=denied kernel=6.8.12-tegra error=no-kvm-access
    YCODE-DONE fail
    """

    @Test func setupOutputRootStepsFirst() {
        let o = HostSetupOutput.parse(Self.setupOutput)
        #expect(o.mode == "report" && o.passed == false && o.facts["kernel"] == "6.8.12-tegra")
        #expect(o.steps.map(\.id) == ["kvm-group", "data-folders"])
        #expect(o.rootSteps.map(\.command) == ["usermod -aG kvm tester"])
        #expect(!o.isSettled)
        let inv = HostSetupInvocation(dataDirectory: "/data/ycode")
        let list = o.checklist(destination: "tester@sim-host", invocation: inv)
        #expect(list.map(\.id) == ["setup.os", "setup.kvm", "setup.data", "setup.firewall", "setup.sve"])
        #expect(list[1].fix == .command("ssh -t tester@sim-host 'sudo bash ~/.cache/ycode/ycode-host-setup --root --data-dir /data/ycode --swift 6.4 --probe-seconds 3'"))
        #expect(list[2].fix == .action(.provisionApply))
        #expect(list[4].state == .unknown)
        #expect(inv.streamedCommand(mode: "report") == "bash -s -- --report --data-dir /data/ycode --swift 6.4 --probe-seconds 3")
        let settled = HostSetupOutput.parse("YCODE-CHECK setup.os ok Linux.\nYCODE-DONE pass\n")
        #expect(settled.isSettled && settled.passed == true)
    }

    @Test func portsVersionAndReleaseSteps() throws {
        #expect(RuntimeHostSettings.ports("47900/47901")! == (47900, 47901))
        #expect(RuntimeHostSettings.ports("47900 47901")! == (47900, 47901))
        #expect(RuntimeHostSettings.ports("47900") == nil && RuntimeHostSettings.ports("0/1") == nil)
        let inv = HostSetupInvocation(dataDirectory: "/data/ycode", ycodeVersion: "1.0.0-beta.2", tcpPort: 47900, udpPort: 47901)
        #expect(inv.arguments(mode: "apply") == ["--apply", "--data-dir", "/data/ycode", "--swift", "6.4", "--probe-seconds", "3",
                                                 "--ycode-version", "1.0.0-beta.2", "--tcp-port", "47900", "--udp-port", "47901"])
        // Older saved settings lack the ports: they keep the defaults.
        let old = try JSONDecoder().decode(RuntimeHostSettings.self, from: Data(#"{"destination":"a@b","dataDirectory":"/d","linkName":"","ycodePath":""}"#.utf8))
        #expect(old.tcpPort == 47800 && old.udpPort == 47801 && old.destination == "a@b")
        let o = HostSetupOutput.parse("""
        YCODE-USER release t=/d/ycode/.download && curl …
        YCODE-USER swift t=$(mktemp -d) && …
        YCODE-CHECK setup.simhost missing No ycode-simhost here.
        YCODE-CHECK setup.swift missing No Swift; Ycode needs Swift 6.4.
        YCODE-CHECK setup.ports missing In use: 47800/tcp by bob (ycode-simhost). Choose free ports with --tcp-port N --udp-port M.
        YCODE-CHECK setup.selftest missing ycode-simhost check: YCODE_SIM_TREE /x has no .build/release/ycode-simd
        """)
        let list = o.checklist(destination: "a@b", invocation: inv)
        #expect(list.map(\.title) == ["ycode-simhost", "Swift toolchain", "Link ports", "Service self-test"])
        #expect(list[0].fix == .action(.provisionApply) && list[1].fix == .action(.provisionApply) && list[3].fix == .action(.provisionApply))
        #expect(list[2].fix == nil)
        #expect(RuntimeHostChecker.Command.version("", dataDirectory: "/d").contains("[ -x /d/bin/ycode ]"))
    }

    /// The release's version comes from its folder (or manifest.json), never
    /// from running its ycode, which may not start outside the Flatpak runtime.
    @Test func hostVersionFromTheReleaseFolder() throws {
        let dir = Self.temp()
        defer { try? FileManager.default.removeItem(at: dir) }
        let fm = FileManager.default
        let top = dir.appendingPathComponent("ycode/Ycode-1.2.3-aarch64")
        try fm.createDirectory(at: top.appendingPathComponent("bin"), withIntermediateDirectories: true)
        try fm.createDirectory(at: dir.appendingPathComponent("bin"), withIntermediateDirectories: true)
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: top.appendingPathComponent("bin/ycode-simhost"))
        // The release's ycode cannot start (its libcurl wants a newer OpenSSL).
        try Data("#!/bin/sh\necho 'version OPENSSL_3.2.0 not found' >&2; exit 1\n".utf8).write(to: top.appendingPathComponent("bin/ycode"))
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: top.appendingPathComponent("bin/ycode").path)
        try fm.createSymbolicLink(atPath: dir.appendingPathComponent("bin/ycode-simhost").path, withDestinationPath: top.appendingPathComponent("bin/ycode-simhost").path)
        try fm.createSymbolicLink(atPath: dir.appendingPathComponent("bin/ycode").path, withDestinationPath: top.appendingPathComponent("bin/ycode").path)
        func run() -> String {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/bin/sh")
            p.arguments = ["-c", RuntimeHostChecker.Command.version("", dataDirectory: dir.path)]
            let out = Pipe()
            p.standardOutput = out
            try? p.run()
            p.waitUntilExit()
            return String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        }
        #expect(RuntimeHostChecker.version(inVersionOutput: run()) == "1.2.3")
        try Data(#"{"name": "Ycode", "version": "1.2.4"}"#.utf8).write(to: top.appendingPathComponent("manifest.json"))
        #expect(RuntimeHostChecker.version(inVersionOutput: run()) == "1.2.4")
    }

    #if os(Linux)
    static let onLinux = true
    #else
    static let onLinux = false
    #endif

    /// On Linux (the script inspects only Linux): a release installed from a
    /// file:// "release" whose ycode cannot start and whose ycode-simhost
    /// predates `check`. The second Apply downloads nothing; the self-test is
    /// unknown, not a failure.
    @Test(.enabled(if: onLinux)) func secondApplyAfterAReleaseRunsNoReleaseStep() throws {
        let dir = Self.temp()
        defer { try? FileManager.default.removeItem(at: dir) }
        let fm = FileManager.default
        let v = "9.9.9", top = "Ycode-9.9.9-aarch64"
        let build = dir.appendingPathComponent("build/\(top)")
        for d in ["bin", "lib/ycode-sim/scripts", "lib/ycode-sim/.build/release", "lib/ycode-sim/SimShim/out"] {
            try fm.createDirectory(at: build.appendingPathComponent(d), withIntermediateDirectories: true)
        }
        func script(_ rel: String, _ body: String) throws {
            try Data("#!/bin/sh\n\(body)\n".utf8).write(to: build.appendingPathComponent(rel))
            try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: build.appendingPathComponent(rel).path)
        }
        try script("bin/ycode-simhost", "echo \"ycode-simhost: unknown command $1\" >&2; exit 64")
        try script("bin/ycode", "echo 'libcurl.so.4: version OPENSSL_3.2.0 not found' >&2; exit 1")
        try script("lib/ycode-sim/scripts/ycode-sim.sh", "exit 0")
        try script("lib/ycode-sim/.build/release/ycode-simd", "exit 0")
        try Data().write(to: build.appendingPathComponent("lib/ycode-sim/SimShim/out/shim.bin"))
        let rel = dir.appendingPathComponent("rel")
        try fm.createDirectory(at: rel, withIntermediateDirectories: true)
        #expect(shell("cd \(dir.appendingPathComponent("build").path.shellQuoted) && tar -cJf \(rel.path.shellQuoted)/\(top).tar.xz \(top) && cd \(rel.path.shellQuoted) && sha256sum \(top).tar.xz > SHA256SUMS.txt") == 0)
        let data = dir.appendingPathComponent("data"), rt = data.appendingPathComponent("runtimes/iOS-27.0-24A434/RuntimeRoot")
        try fm.createDirectory(at: rt.appendingPathComponent("sbin"), withIntermediateDirectories: true)
        try Data().write(to: rt.appendingPathComponent("sbin/launchd_sim"))
        let file = dir.appendingPathComponent("ycode-host-setup")
        try HostSetupScript.text.write(to: file, atomically: true, encoding: .utf8)
        // A stand-in Swift (and no swiftly), so the run never touches this machine's toolchains.
        let fakeSwiftly = dir.appendingPathComponent("swiftly")
        try fm.createDirectory(at: fakeSwiftly.appendingPathComponent("bin"), withIntermediateDirectories: true)
        try Data("#!/bin/sh\necho 'Swift version 6.4.2 (stand-in)'\n".utf8).write(to: fakeSwiftly.appendingPathComponent("bin/swift"))
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fakeSwiftly.appendingPathComponent("bin/swift").path)
        try Data("export PATH=\"\(fakeSwiftly.path)/bin:/usr/bin:/bin\"\n".utf8).write(to: fakeSwiftly.appendingPathComponent("env.sh"))
        func setup(_ mode: String) -> HostSetupOutput {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/bin/bash")
            p.arguments = [file.path, "--" + mode, "--data-dir", data.path, "--config-dir", dir.appendingPathComponent("config").path,
                           "--ycode-version", v, "--release-base", "file://" + rel.path, "--no-probe", "--min-free-gb", "0", "--tcp-port", "47890", "--udp-port", "47891"]
            p.environment = ["PATH": fakeSwiftly.path + "/bin:/usr/bin:/bin", "HOME": dir.path, "SWIFTLY_HOME_DIR": fakeSwiftly.path,
                             "YCODE_SETUP_ARCH": "aarch64"]
            let out = Pipe()
            p.standardOutput = out
            p.standardError = FileHandle.nullDevice
            try? p.run()
            let text = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            p.waitUntilExit()
            return HostSetupOutput.parse(text)
        }
        let first = setup("report")
        #expect(first.userSteps.contains { $0.id == "release" })
        try #require(!first.steps.contains { $0.id == "swift" }, "the stand-in Swift was not used; not applying")
        let applied = setup("apply")
        #expect(applied.ran["release"] == true)
        #expect(applied.facts["ycode_installed"] == v)
        #expect(!applied.userSteps.contains { $0.id == "release" })
        let selftest = try #require(applied.checks.first { $0.id == "setup.selftest" })
        #expect(selftest.state == .unknown && selftest.reason.contains("predates ycode-simhost check"), "\(selftest)")
        #expect(applied.checks.first { $0.id == "setup.service" }?.state == .ok)
        // The second Apply: nothing to download, nothing run.
        let again = setup("apply")
        #expect(again.ran.isEmpty, "\(again.ran)")
        #expect(!again.userSteps.contains { $0.id == "release" })
        #expect(again.checks.first { $0.id == "setup.simhost" }?.state == .ok)
    }

    @Test func sveDecision() {
        typealias F = KVMSVEProbe.Facts
        #expect(KVMSVEProbe.verdict(F(architecture: "x86_64", hasSVE: false, kvm: "access")) ==
                .notApplicable("This host is x86_64; the bug is in KVM on arm64 with SVE."))
        if case .notApplicable = KVMSVEProbe.verdict(F(architecture: "aarch64", hasSVE: false, kvm: "access")) {} else { Issue.record("no SVE") }
        #expect(KVMSVEProbe.verdict(F(architecture: "aarch64", hasSVE: true, kvm: "access", runs: 21_300_000, lost: 149_873)) == .affected(lost: 149_873, runs: 21_300_000))
        #expect(KVMSVEProbe.verdict(F(architecture: "aarch64", hasSVE: true, kvm: "access", runs: 21_700_000, lost: 0)) == .fixed(runs: 21_700_000))
        // One lost run is enough; too few runs without a loss tell nothing.
        #expect(KVMSVEProbe.verdict(F(architecture: "arm64", hasSVE: true, kvm: "access", runs: 50, lost: 1)) == .affected(lost: 1, runs: 50))
        if case .unknown = KVMSVEProbe.verdict(F(architecture: "aarch64", hasSVE: true, kvm: "access", runs: 50, lost: 0)) {} else { Issue.record("few runs") }
        if case .unknown = KVMSVEProbe.verdict(F(architecture: "aarch64", hasSVE: true, kvm: "access", error: "compile-failed")) {} else { Issue.record("error") }
        let affected = KVMSVEProbe.check(F(["arch": "aarch64", "sve": "yes", "kvm": "access", "kernel": "6.8.12-tegra", "runs": "2000000", "lost": "4038"]))
        #expect(affected.state == .missing && affected.reason.contains("mitigations are on") && affected.reason.contains("6.8.12-tegra"))
        #expect(affected.fix == .instructions("How to get a kernel with the fix: \(KVMSVEProbe.postmortem)"))
        #expect(KVMSVEProbe.check(F(["arch": "x86_64", "sve": "no", "kvm": "access", "error": "not-arm64"])).state == .notApplicable)
    }

    @Test func scriptIsValidBashAndOnlyReportsOffLinux() throws {
        let dir = Self.temp()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent(HostSetupScript.fileName)
        try HostSetupScript.text.write(to: url, atomically: true, encoding: .utf8)
        #expect(shell("bash -n \(url.path.shellQuoted)") == 0)
        #expect(HostSetupScript.text.contains("int main(int argc"))
        #expect(!HostSetupScript.text.contains("@PROBE_SOURCE@"))
        // Off Linux (this Mac) it reports and changes nothing.
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/bash")
        p.arguments = [url.path, "--report", "--data-dir", dir.appendingPathComponent("data").path, "--config-dir", dir.appendingPathComponent("conf").path]
        let out = Pipe()
        p.standardOutput = out
        try p.run()
        let text = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        p.waitUntilExit()
        let o = HostSetupOutput.parse(text)
        #if os(macOS)
        #expect(o.checks.first?.id == "setup.os" && o.checks.first?.state == .missing)
        #expect(o.passed == false && o.sve?["error"] == "not-linux")
        #endif
        #expect(!FileManager.default.fileExists(atPath: dir.appendingPathComponent("data").path))
        #expect(!FileManager.default.fileExists(atPath: dir.appendingPathComponent("conf").path))
    }

    // MARK: The session

    @MainActor @Test func sessionConfirmsBeforeAnything() async throws {
        let dir = Self.temp()
        defer { try? FileManager.default.removeItem(at: dir) }
        let d = UserDefaults(suiteName: "ycode-runtime-tests-\(UUID().uuidString)")!
        let s = RuntimeSetupSession(machine: Self.mac, defaults: d, folder: dir.appendingPathComponent("rt").path, localRunner: R(answers: Self.macReady))
        #expect(s.steps == [.target, .runtimes, .add, .finish])
        await s.recheck().value
        #expect(s.report?.check("runtime.iOS")?.state == .ok)
        s.next()
        #expect(s.step == .runtimes && s.state(of: .runtimes) == .ok)
        // A disk image: the confirmation shows the exact command; nothing runs yet.
        let dmg = dir.appendingPathComponent("iOS 27.0 Simulator Runtime.dmg")
        try Data().write(to: dmg)
        s.pick(path: dmg.path)
        #expect(s.pickedAction == .importImage(path: dmg.path, tool: .simctl))
        s.request(s.pickedAction!)
        #expect(s.confirmation?.command == "xcrun simctl runtime add '\(dmg.path)'")
        s.cancelConfirmation()
        #expect(s.confirmation == nil && s.running == nil)
        // A bundle on a Mac is not imported (CoreSimulator takes images).
        let b = try Self.fakeBundle(in: dir)
        s.pick(path: b.path)
        #expect(s.picked?.record?.title == "iOS 27.0 (24A434)" && s.pickedAction == nil)
        // Choosing a host adds its steps and keeps the choice.
        s.setUseHost(true)
        #expect(s.steps == [.target, .host, .prepare, .runtimes, .add, .finish])
        #expect(RuntimeSetupChoices.load(d).useHost)
        s.setHost(Self.host)
        s.pick(path: b.path)
        guard case .copyToHost(let src, let rec, "tester@sim-host")? = s.pickedAction else { Issue.record("expected a copy to the host"); return }
        #expect(src.hasSuffix("Contents/Resources/RuntimeRoot") && rec.folderName == "iOS-27.0-24A434")
        s.request(.copyToHost(source: src, record: rec, host: "tester@sim-host"))
        #expect(s.confirmation?.command.contains("rsync -a --partial") == true)
        s.cancelConfirmation()
        // Remove of a Ycode copy on the host goes through ssh with the guarded command.
        let hostCopy = SimRuntimeRecord(platform: .iOS, version: "27.0", build: "24A434", location: .host("tester@sim-host"),
                                        owner: .ycode(folder: "/data/ycode/runtimes/iOS-27.0-24A434"))
        s.request(.remove(hostCopy))
        #expect(s.confirmation?.isDestructive == true)
        #expect(s.confirmation?.command == "ssh tester@sim-host 'test -f /data/ycode/runtimes/iOS-27.0-24A434/ycode-runtime.json && rm -rf /data/ycode/runtimes/iOS-27.0-24A434'")
        s.cancelConfirmation()
        // An x86-64 Linux computer always uses a host.
        let x = RuntimeSetupSession(machine: Self.x86, defaults: UserDefaults(suiteName: "ycode-runtime-tests-\(UUID().uuidString)")!, folder: dir.path)
        #expect(x.choices.useHost)
        x.setUseHost(false)
        #expect(x.choices.useHost)
    }

    @Test func commandLineShowsTheSameChecklist() async {
        final class Lines: @unchecked Sendable {
            private let lock = NSLock()
            private var all: [String] = []
            func add(_ s: String) { lock.withLock { all.append(s) } }
            var text: String { lock.withLock { all.joined(separator: "\n") } }
        }
        let lines = Lines()
        let status = await RuntimeCLI.main(["check", "--platform", "iOS", "--platform", "visionOS", "--host", "tester@sim-host", "--data", "/data/ycode"],
                                           runner: R(answers: Self.macReady), hostRunner: R(answers: Self.hostReady), machine: Self.mac) { lines.add($0) }
        #expect(status == 1)
        #expect(lines.text.contains("iOS 27.0 (24A434)  7.3 GB  ready  Xcode's (read-only)"))
        #expect(lines.text.contains("ok       Reachable: tester@sim-host answers with your ssh key."))
        #expect(lines.text.contains("MISSING  Runtime for visionOS"))
        let script = Lines()
        #expect(await RuntimeCLI.main(["script"]) { script.add($0) } == 0)
        #expect(script.text.hasPrefix("#!/usr/bin/env bash"))
        #expect(await RuntimeCLI.main(["nonsense"]) { _ in } == 64)
    }

    @MainActor @Test func copiedRuntimeBecomesARuntimeRootOfThatHost() {
        let d = UserDefaults(suiteName: "ycode-runtime-tests-\(UUID().uuidString)")!
        var settings = RemoteSimulatorSettings(destination: "tester@sim-host", dataDirectory: "/data/ycode", runtimeRoot: "/rt/iOS-27.1/RuntimeRoot", simdPath: "/x")
        settings.save(d)
        let s = RuntimeSetupSession(machine: Self.mac, defaults: d, folder: "/nonexistent")
        let rec = SimRuntimeRecord(platform: .iOS, version: "27.0", build: "24A434")
        let root = "/data/ycode/runtimes/iOS-27.0-24A434/RuntimeRoot"
        #expect(!s.registerRemoteRoot(root, record: rec, host: "other@host"))
        #expect(s.registerRemoteRoot(root, record: rec, host: "tester@sim-host"))
        settings = RemoteSimulatorSettings.load(d)
        #expect(settings.otherRuntimeRoots == [root] && settings.runtimeVersion(forRoot: root) == "27.0")
        #expect(settings.targets.contains { $0.runtimeRoot == root })
        s.unregisterRemoteRoot(root, host: "tester@sim-host")
        #expect(RemoteSimulatorSettings.load(d).otherRuntimeRoots.isEmpty)
    }

    @Test func linkHostsFromTrustedPeers() throws {
        let dir = Self.temp()
        defer { try? FileManager.default.removeItem(at: dir) }
        try Data(#"[{"name":"sim-host","publicKey":"AA==","role":"host","added":"x"},{"name":"laptop","publicKey":"AA==","role":"client","added":"x"}]"#.utf8)
            .write(to: dir.appendingPathComponent("trusted-peers.json"))
        #expect(RuntimeSetupSession.linkHosts(environment: ["YCODE_SIM_LINK_HOME": dir.path]) == ["sim-host"])
    }
}
