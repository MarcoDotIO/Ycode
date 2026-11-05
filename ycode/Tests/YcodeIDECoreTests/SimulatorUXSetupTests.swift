import Foundation
import Testing
@testable import YcodeIDECore

/// Setup steps of the simulator walk (docs/SIMULATOR-UX.md): the host setup
/// with a simulator tree the user names, and the iOS build script of a
/// release.
@Suite struct SimulatorUXSetupTests {
    #if os(Linux)
    static let onLinux = true
    #else
    static let onLinux = false
    #endif

    static func temp() -> URL {
        let u = FileManager.default.temporaryDirectory.appendingPathComponent("ycode-simux-setup-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }

    static func executable(_ url: URL, _ body: String) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("#!/bin/sh\n\(body)\n".utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    }

    static func run(_ argv: [String], environment: [String: String]) -> (status: Int32, out: String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/bash")
        p.arguments = argv
        p.environment = environment
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        guard (try? p.run()) != nil else { return (-1, "") }
        let text = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        p.waitUntilExit()
        return (p.terminationStatus, text)
    }

    /// `--sim-tree <release>/lib/ycode-sim`: the release's ycode-simhost is
    /// found, Apply links it into the data folder, and the check passes.
    @Test(.enabled(if: onLinux)) func simTreeOfAnUnpackedReleaseBringsItsSimhost() throws {
        let dir = Self.temp()
        defer { try? FileManager.default.removeItem(at: dir) }
        let rel = dir.appendingPathComponent("Ycode-9.9.9-aarch64")
        try Self.executable(rel.appendingPathComponent("bin/ycode-simhost"), "[ \"$1\" = check ] && echo ok && exit 0; exit 64")
        try Self.executable(rel.appendingPathComponent("lib/ycode-sim/scripts/ycode-sim.sh"), "exit 0")
        try Self.executable(rel.appendingPathComponent("lib/ycode-sim/.build/release/ycode-simd"), "exit 0")
        let rt = dir.appendingPathComponent("RuntimeRoot")
        try FileManager.default.createDirectory(at: rt.appendingPathComponent("sbin"), withIntermediateDirectories: true)
        let swift = dir.appendingPathComponent("swiftly")
        try Self.executable(swift.appendingPathComponent("bin/swift"), "echo 'Swift version 6.4 (stand-in)'")
        try Data("export PATH=\"\(swift.path)/bin:/usr/bin:/bin\"\n".utf8).write(to: swift.appendingPathComponent("env.sh"))
        let script = dir.appendingPathComponent("ycode-host-setup")
        try HostSetupScript.text.write(to: script, atomically: true, encoding: .utf8)
        let data = dir.appendingPathComponent("data")
        func setup(_ mode: String) -> HostSetupOutput {
            let r = Self.run([script.path, "--" + mode, "--data-dir", data.path, "--config-dir", dir.appendingPathComponent("config").path,
                              "--sim-tree", rel.appendingPathComponent("lib/ycode-sim").path, "--runtime-root", rt.path,
                              "--no-probe", "--min-free-gb", "0", "--tcp-port", "47892", "--udp-port", "47893"],
                             environment: ["PATH": swift.path + "/bin:/usr/bin:/bin", "HOME": dir.path, "SWIFTLY_HOME_DIR": swift.path,
                                           "YCODE_SETUP_ARCH": "aarch64"])
            return HostSetupOutput.parse(r.out)
        }
        let report = setup("report")
        #expect(report.userSteps.contains { $0.id == "simhost-link" })
        let before = try #require(report.checks.first { $0.id == "setup.simhost" })
        #expect(before.state == .missing && before.reason.contains("Apply links it there"), "\(before)")
        let applied = setup("apply")
        #expect(applied.ran["simhost-link"] == true, "\(applied.ran)")
        #expect(applied.checks.first { $0.id == "setup.simhost" }?.state == .ok)
        #expect(FileManager.default.fileExists(atPath: data.appendingPathComponent("bin/ycode-simhost").path))
    }

    /// The iOS build script of a release (bin/ next to scripts/) uses the
    /// release's ycode and ycode-swb, names DEVELOPER_DIR only, and says
    /// what a missing SDK needs.
    @Test func iOSBuildScriptUsesTheReleasesTools() throws {
        let dir = Self.temp()
        defer { try? FileManager.default.removeItem(at: dir) }
        let pkg = dir.appendingPathComponent("Ycode-9.9.9-x86_64")
        let source = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("scripts/ycode-ios-build-linux")
        try FileManager.default.createDirectory(at: pkg.appendingPathComponent("scripts"), withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: source, to: pkg.appendingPathComponent("scripts/ycode-ios-build-linux"))
        let log = dir.appendingPathComponent("ycode.log")
        try Self.executable(pkg.appendingPathComponent("bin/ycode"),
                            "echo \"YCODE_SWB=$YCODE_SWB DEVELOPER_DIR=$DEVELOPER_DIR EXTRA=${XCODE_EXTRA_PLATFORM_FOLDERS:-none} $*\" > \(log.path)")
        try Self.executable(pkg.appendingPathComponent("bin/ycode-swb"), "exit 0")
        let ld = dir.appendingPathComponent("ld64.lld")
        try Self.executable(ld, "exit 0")
        let sdk = dir.appendingPathComponent("sdk")
        try FileManager.default.createDirectory(at: sdk.appendingPathComponent("Platforms/iPhoneSimulator.platform"), withIntermediateDirectories: true)
        let rt = sdk.appendingPathComponent("Toolchains/XcodeDefault.xctoolchain/usr/lib/clang/21/lib/darwin")
        try FileManager.default.createDirectory(at: rt, withIntermediateDirectories: true)
        try Data().write(to: rt.appendingPathComponent("libclang_rt.iossim.a"))
        let script = pkg.appendingPathComponent("scripts/ycode-ios-build-linux").path
        let base = ["PATH": "/usr/bin:/bin", "HOME": dir.path, "YCODE_LD64": ld.path, "YCODE_SWIFT_BIN": "/usr/bin"]
        let ok = Self.run([script, "/p/A.xcodeproj", "A", "/dd"], environment: base.merging(["YCODE_USER_SDK": sdk.path]) { $1 })
        #expect(ok.status == 0, "\(ok.out)")
        let line = (try? String(contentsOf: log, encoding: .utf8)) ?? ""
        #expect(line.contains("YCODE_SWB=\(pkg.path)/bin/ycode-swb") && line.contains("DEVELOPER_DIR=\(sdk.path)") && line.contains("EXTRA=none"), "\(line)")
        #expect(line.contains("build /p/A.xcodeproj -scheme A"))
        let missing = Self.run([script, "/p/A.xcodeproj", "A", "/dd"], environment: base)
        #expect(missing.status == 2 && missing.out.contains("No iOS SDK: set YCODE_USER_SDK"), "\(missing.out)")
    }

    /// The launcher with a release's simulator tree (lib/ycode-sim): the
    /// shader translator is next to ycode-simd there, not in Translator/build.
    @Test(.enabled(if: onLinux)) func launcherFindsTheReleasesShaderTranslator() throws {
        let dir = Self.temp()
        defer { try? FileManager.default.removeItem(at: dir) }
        let tree = dir.appendingPathComponent("tree")
        try Self.executable(tree.appendingPathComponent(".build/release/ycode-simd"), "echo \"SIMD $*\"")
        try Self.executable(tree.appendingPathComponent(".build/release/ycode-airc"), "exit 0")
        try FileManager.default.createDirectory(at: tree.appendingPathComponent("SimHostLibs/out"), withIntermediateDirectories: true)
        let launcher = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("scripts/ycode-sim.sh")
        let r = Self.run([launcher.path, "--device", dir.appendingPathComponent("data/dev").path, "--runtime-root", dir.appendingPathComponent("rt").path],
                         environment: ["PATH": "/usr/bin:/bin", "HOME": dir.path, "YCODE_SIM_TREE": tree.path,
                                       "YCODE_SIM_DATA": dir.appendingPathComponent("data").path, "YCODE_WARM_BOOT": "0"])
        #expect(r.out.contains("--metal-translator \(tree.path)/.build/release/ycode-airc"), "\(r.out)")
    }
}
