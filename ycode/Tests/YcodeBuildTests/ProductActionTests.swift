import Foundation
import Testing
@testable import YcodeBuild

/// Product ▸ Build For ▸ Testing, Perform Action ▸ Test Without Building
/// and the single-file actions (`specs/ide/reference-ui-5.md` §2.9).
@Suite struct ProductActionCommandTests {
    @Test func testingStepsForPackages() {
        let r = TestRunner()
        var req = BuildRequest(container: .package("/p"), action: .buildForTesting)
        #expect(r.command(for: req).args.suffix(2) == ["build", "--build-tests"])
        req.action = .testWithoutBuilding
        let run = r.command(for: req, only: ["MathTests/testAdds"])
        #expect(run.args.suffix(4) == ["test", "--skip-build", "--filter", "MathTests.testAdds"])
        #expect(run.cwd == "/p")
        // Coverage instruments the build of `swift test` only.
        var cov = r
        cov.coverage = true
        #expect(!cov.command(for: req).args.contains("--enable-code-coverage"))
        req.action = .test
        #expect(cov.command(for: req).args.contains("--enable-code-coverage"))
        // Profiling builds use the release configuration.
        req.action = .buildForTesting
        req.configuration = "Release"
        #expect(r.command(for: req).args.suffix(2) == ["-c", "release"])
    }

    @Test func testingStepsForProjects() {
        var r = TestRunner()
        r.testPlan = "Smoke"
        var req = BuildRequest(container: .project("/a/A.xcodeproj"), scheme: "A", destination: "platform=macOS",
                               action: .buildForTesting, settings: [("X", "1")])
        let build = r.command(for: req, only: ["ATests/T/test"])
        // build-for-testing builds every test; -only-testing is for running.
        #expect(build.args.suffix(4) == ["-testPlan", "Smoke", "build-for-testing", "X=1"])
        req.action = .testWithoutBuilding
        #expect(r.command(for: req, only: ["ATests/T/test"]).args.suffix(5)
                == ["-testPlan", "Smoke", "-only-testing:ATests/T/test", "test-without-building", "X=1"])
        req.action = .build // anything else: build and test
        #expect(r.command(for: req).args.suffix(2) == ["test", "X=1"])
    }

    @Test func swiftFileCommand() throws {
        let runner = FileActionRunner(swiftc: ["swiftc"], clang: ["clang"])
        let ctx = FileBuildContext(moduleName: "App", moduleSources: ["/s/A.swift", "/s/B.swift"], sdkPath: "/SDK",
                                   targetTriple: "arm64-apple-macosx15.0", swiftVersion: "5.0", includePaths: ["/products"],
                                   defines: ["DEBUG"], outputDirectory: "/out")
        let a = try #require(runner.command(.compile, file: "/s/A.swift", context: ctx))
        #expect(a == ["swiftc", "-frontend", "-c", "-primary-file", "/s/A.swift", "/s/B.swift", "-parse-as-library", "-module-name", "App", "-sdk", "/SDK",
                      "-target", "arm64-apple-macosx15.0", "-swift-version", "5", "-I", "/products", "-D", "DEBUG", "-o", "/out/A.o"])
        let s = try #require(runner.command(.assemble, file: "/s/A.swift", context: ctx))
        #expect(s[2] == "-S" && s.last == "/out/A.s")
        // With a main.swift the module has top-level code.
        let script = FileBuildContext(moduleName: "Tool", moduleSources: ["/s/main.swift", "/s/A.swift"], outputDirectory: "/out")
        #expect(runner.command(.compile, file: "/s/A.swift", context: script)?.contains("-parse-as-library") == false)
        // The analyzer and the preprocessor are clang's.
        #expect(runner.command(.analyze, file: "/s/A.swift", context: ctx) == nil)
        #expect(runner.command(.preprocess, file: "/s/A.swift", context: ctx) == nil)
        #expect(runner.command(.compile, file: "/s/notes.txt", context: ctx) == nil)
        #expect(FileBuildContext.swiftLanguageMode("4.2") == "4.2" && FileBuildContext.swiftLanguageMode("6") == "6")
        #expect(FileBuildContext.moduleIdentifier("My App-2") == "My_App_2" && FileBuildContext.moduleIdentifier("9x") == "_9x")
    }

    @Test func cFamilyCommands() throws {
        let runner = FileActionRunner(swiftc: ["swiftc"], clang: ["clang"])
        let ctx = FileBuildContext(moduleName: "M", sdkPath: "/SDK", includePaths: ["/h"], defines: ["A=1"], outputDirectory: "/out")
        #expect(runner.command(.compile, file: "/s/x.c", context: ctx)
                == ["clang", "-x", "c", "-c", "/s/x.c", "-isysroot", "/SDK", "-I", "/h", "-DA=1", "-o", "/out/x.o"])
        #expect(runner.command(.analyze, file: "/s/x.m", context: ctx)?.prefix(6)
                == ["clang", "-x", "objective-c", "--analyze", "-Xclang", "-analyzer-output=text"])
        #expect(runner.command(.preprocess, file: "/s/x.cpp", context: ctx)?.contains("-E") == true)
        #expect(FileActionRunner.outputPath(.preprocess, file: "/s/x.cpp", context: ctx) == "/out/x.i")
    }
}

/// Real compiler and SwiftPM runs (macOS and Linux).
@Suite(.serialized, .timeLimit(.minutes(5))) struct ProductActionRealTests {
    func scratch(_ name: String) -> URL {
        let u = FileManager.default.temporaryDirectory.appendingPathComponent("ycode-\(name)-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }

    func write(_ text: String, _ url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    #if os(macOS)
    static let sdk: String? = {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        p.arguments = ["--sdk", "macosx", "--show-sdk-path"]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return nil }
        p.waitUntilExit()
        return String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }()
    #else
    static let sdk: String? = nil
    #endif

    /// Compile “A.swift” type-checks against the module's other file and
    /// writes only A's object file; an error comes back as a located issue.
    @Test func compileOneSwiftFileOfAModule() async throws {
        let dir = scratch("compile-file")
        defer { try? FileManager.default.removeItem(at: dir) }
        let a = dir.appendingPathComponent("Sources/A.swift"), b = dir.appendingPathComponent("Sources/B.swift")
        try write("func useGreeter() -> String { Greeter().text }\n", a)
        try write("struct Greeter { var text: String { \"hi\" } }\n", b)
        let out = dir.appendingPathComponent("out").path
        let ctx = FileBuildContext(moduleName: "Mod", moduleSources: [a.path, b.path], sdkPath: Self.sdk, swiftVersion: "5.0", outputDirectory: out)
        let runner = FileActionRunner()
        let result = await runner.start(.compile, file: a.path, context: ctx).run()
        #expect(result.status == .succeeded, "\(result.issues)")
        #expect(FileManager.default.fileExists(atPath: out + "/A.o"))
        #expect(!FileManager.default.fileExists(atPath: out + "/B.o"))

        let asm = await runner.start(.assemble, file: a.path, context: ctx).run()
        #expect(asm.status == .succeeded)
        let text = try String(contentsOfFile: out + "/A.s", encoding: .utf8)
        #expect(text.contains("useGreeter"))

        try write("func broken() -> Int { missingName }\n", a)
        var events: [BuildEvent] = []
        let failed = await runner.start(.compile, file: a.path, context: ctx).run { events.append($0) }
        #expect(failed.status == .failed)
        let issue = try #require(failed.issues.first { $0.severity == .error })
        #expect(issue.location?.file.hasSuffix("A.swift") == true && issue.location?.line == 1)
        #expect(issue.message.contains("missingName"))
        #expect(events.first == .activity("Compiling A.swift"))
    }

    @Test func cFileActions() async throws {
        let dir = scratch("c-file")
        defer { try? FileManager.default.removeItem(at: dir) }
        let c = dir.appendingPathComponent("calc.c")
        try write("#define TWICE(x) ((x) * 2)\nint twice(int v) { return TWICE(v); }\n", c)
        let ctx = FileBuildContext(moduleName: "calc", sdkPath: Self.sdk, defines: ["EXTRA=1"], outputDirectory: dir.appendingPathComponent("out").path)
        let runner = FileActionRunner()
        #expect(await runner.start(.compile, file: c.path, context: ctx).run().status == .succeeded)
        #expect(FileManager.default.fileExists(atPath: ctx.outputDirectory + "/calc.o"))
        #expect(await runner.start(.preprocess, file: c.path, context: ctx).run().status == .succeeded)
        let pre = try String(contentsOfFile: ctx.outputDirectory + "/calc.i", encoding: .utf8)
        #expect(pre.contains("((v) * 2)") && !pre.contains("TWICE(v)"))
        // The static analyzer reports a division by zero as a warning.
        try write("int f(int a) { int z = 0; return a / z; }\n", c)
        let analyzed = await runner.start(.analyze, file: c.path, context: ctx).run()
        #expect(analyzed.issues.contains { $0.severity == .warning && $0.message.lowercased().contains("division by zero") }, "\(analyzed.issues)")
    }

    /// Build For Testing, then Test Without Building, on a real package:
    /// the second step runs the tests the first one built.
    @Test func buildForTestingThenTestWithoutBuilding() async throws {
        let dir = scratch("bft")
        defer { try? FileManager.default.removeItem(at: dir) }
        try write("""
        // swift-tools-version: 6.0
        import PackageDescription
        let package = Package(name: "Calc", targets: [.target(name: "Calc"), .testTarget(name: "CalcTests", dependencies: ["Calc"])])

        """, dir.appendingPathComponent("Package.swift"))
        try write("public func sum(_ a: Int, _ b: Int) -> Int { a + b }\n", dir.appendingPathComponent("Sources/Calc/Calc.swift"))
        try write("""
        import XCTest
        @testable import Calc
        final class CalcTests: XCTestCase {
            func testAdds() { XCTAssertEqual(sum(1, 2), 3) }
            func testBroken() { XCTAssertEqual(sum(1, 1), 3) }
        }

        """, dir.appendingPathComponent("Tests/CalcTests/CalcTests.swift"))
        let request = BuildRequest(container: .package(dir.path))
        let runner = TestRunner()

        // Without a build there is nothing to run.
        var withoutBuild = request
        withoutBuild.action = .testWithoutBuilding
        let early = await runner.run(withoutBuild)
        #expect(early.exitCode != 0 && early.outcomes.isEmpty)

        let built = await runner.buildForTesting(request).run()
        #expect(built.status == .succeeded, "\(built.issues)")
        let (code, outcomes) = await runner.run(withoutBuild)
        #expect(code != 0) // one test fails
        #expect(outcomes.first { $0.name == "testAdds" }?.status == .passed)
        #expect(outcomes.first { $0.name == "testBroken" }?.status == .failed)
        let only = await runner.run(withoutBuild, only: ["CalcTests/testAdds"])
        #expect(only.exitCode == 0 && only.outcomes.map(\.name) == ["testAdds"])
    }
}
