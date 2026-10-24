import Foundation
import Testing
@testable import YcodeBuild

@Suite(.serialized, .timeLimit(.minutes(5))) struct SwiftBuildAppTests {
    /// An AppKit app with a generated Info.plist and an asset catalog:
    /// builds as a bundle for the host architecture, is signed ad-hoc
    /// (Sign to Run Locally), and launches (headless smoke mode).
    @Test func buildsAndLaunchesAnApp() async throws {
        #if os(macOS)
        guard let tool = SwiftBuildEndToEndTests.swbuild else { return }
        let dir = ideScratch.appendingPathComponent("swiftbuild-app")
        let projURL = try writeAppProject(at: dir)
        let engine = SwiftBuildEngine(swbuild: tool)
        let request = BuildRequest(container: .project(projURL.path), scheme: "SmokeApp", destination: "platform=macOS",
                                   derivedDataPath: dir.appendingPathComponent("dd").path)
        let result = await engine.start(request).run()
        #expect(result.status == .succeeded, "\(result.issues)")
        let exe = try #require(engine.executablePath(for: request))
        #expect(exe.hasSuffix("Products/Debug/SmokeApp.app/Contents/MacOS/SmokeApp"))
        let app = URL(fileURLWithPath: exe).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let info = try #require(NSDictionary(contentsOf: app.appendingPathComponent("Contents/Info.plist")))
        #expect(info["CFBundleIdentifier"] as? String == "org.ycode.SmokeApp")
        #expect(info["CFBundleExecutable"] as? String == "SmokeApp")
        #expect(FileManager.default.fileExists(atPath: app.appendingPathComponent("Contents/Resources/Assets.car").path))

        func run(_ path: String, _ args: [String]) throws -> (Int32, String) {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: path)
            p.arguments = args
            let out = Pipe()
            p.standardOutput = out
            p.standardError = out
            try p.run()
            let data = out.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()
            return (p.terminationStatus, String(decoding: data, as: UTF8.self))
        }
        // One architecture (the host's), and a valid ad-hoc signature.
        #expect(try run("/usr/bin/lipo", ["-archs", exe]).1.trimmingCharacters(in: .whitespacesAndNewlines) == SwiftBuildEngine.hostArchitecture)
        #expect(try run("/usr/bin/codesign", ["--verify", "--strict", app.path]).0 == 0)
        #expect(try run("/usr/bin/codesign", ["-dv", app.path]).1.contains("Signature=adhoc"))
        #expect(try run(exe, ["--ycode-smoke"]) == (0, "launched org.ycode.SmokeApp color=true\n"))
        #endif
    }
}
