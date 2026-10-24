import Foundation
import Testing
@testable import YcodeXcodebuild

/// `-resolvePackageDependencies` against packages in local git
/// repositories (no network).
@Suite(.serialized) struct PackageResolutionTests {
    func sh(_ tool: String, _ args: [String], in dir: URL) throws {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        p.arguments = [tool] + args
        p.currentDirectoryURL = dir
        p.environment = ProcessInfo.processInfo.environment.merging(["GIT_TERMINAL_PROMPT": "0"]) { $1 }
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try p.run()
        p.waitUntilExit()
        if p.terminationStatus != 0 { throw CocoaError(.fileWriteUnknown) }
    }

    /// A package repository with tags 1.0.0, 1.1.0 and 2.0.0.
    func makeRepository(at dir: URL) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: dir.appendingPathComponent("Sources/Shapes"), withIntermediateDirectories: true)
        try "// swift-tools-version: 5.9\nimport PackageDescription\nlet package = Package(name: \"Shapes\", products: [.library(name: \"Shapes\", targets: [\"Shapes\"])], targets: [.target(name: \"Shapes\")])\n"
            .write(to: dir.appendingPathComponent("Package.swift"), atomically: true, encoding: .utf8)
        let git = ["-c", "user.email=t@example.com", "-c", "user.name=t", "-c", "commit.gpgsign=false", "-c", "tag.gpgsign=false"]
        try sh("git", ["init", "-q"], in: dir)
        for (n, tags) in [(1, ["1.0.0"]), (2, ["1.1.0", "2.0.0"])] {
            try "public func area(_ w: Int, _ h: Int) -> Int { w * h * \(n) / \(n) }\n"
                .write(to: dir.appendingPathComponent("Sources/Shapes/Shapes.swift"), atomically: true, encoding: .utf8)
            try sh("git", ["add", "-A"], in: dir)
            try sh("git", git + ["commit", "-q", "-m", "v\(n)"], in: dir)
            for t in tags { try sh("git", git + ["tag", t], in: dir) }
        }
    }

    @Test func remoteReferenceResolves() throws {
        #if os(macOS) || os(Linux)
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("ycodebuild-resolve-\(UUID().uuidString)")
        let repo = root.appendingPathComponent("Shapes")
        guard (try? makeRepository(at: repo)) != nil else { return } // no git: skipped
        // The project: one tool target using the package's product.
        let projDir = root.appendingPathComponent("App")
        try fm.createDirectory(at: projDir.appendingPathComponent("App.xcodeproj"), withIntermediateDirectories: true)
        let pbx = multiProjectText
            .replacingOccurrences(of: "projectDirPath = \"\";", with: "packageReferences = (E10000000000000000000001); projectDirPath = \"\";")
            .replacingOccurrences(of: "\t};\n\trootObject", with: "\t\tE10000000000000000000001 = {isa = XCRemoteSwiftPackageReference; repositoryURL = \"\(repo.path)\"; requirement = {kind = upToNextMajorVersion; minimumVersion = 1.0.0; }; };\n\t};\n\trootObject")
        try pbx.write(to: projDir.appendingPathComponent("App.xcodeproj/project.pbxproj"), atomically: true, encoding: .utf8)
        let cloned = root.appendingPathComponent("SourcePackages").path
        let r = runTool(["-resolvePackageDependencies", "-clonedSourcePackagesDirPath", cloned], cwd: projDir.path)
        #expect(r.code == 0, "\(r.err)")
        #expect(r.out.contains("Resolved source packages:\n  Shapes: \(repo.path) @ 1.1.0\n"))
        #expect(r.out.hasSuffix("resolved source packages: Shapes\n"))
        let resolved = projDir.appendingPathComponent("App.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved")
        let obj = try JSONSerialization.jsonObject(with: Data(contentsOf: resolved)) as? [String: Any]
        let pin = (obj?["pins"] as? [[String: Any]])?.first
        #expect(pin?["identity"] as? String == "shapes")
        #expect((pin?["state"] as? [String: Any])?["version"] as? String == "1.1.0")
        #expect(fm.fileExists(atPath: cloned + "/checkouts/shapes/Package.swift"))
        // No packages: just the summary line.
        let none = try writeMultiProject().deletingLastPathComponent().path
        let n = runTool(["-resolvePackageDependencies"], cwd: none)
        #expect(n.code == 0 && n.out.hasSuffix("\nresolved source packages: \n"))
        #endif
    }
}
