import Foundation
import Testing
@testable import YcodeXcodebuild

@Suite struct ArgumentParserTests {
    @Test func classifiesWords() throws {
        let inv = try ArgumentParser.parse(["-project", "A.xcodeproj", "-scheme=App", "-target", "X", "-target", "Y",
                                            "FOO=bar", "=ignored", "clean", "build", "-quiet"])
        #expect(inv.project == "A.xcodeproj")
        #expect(inv.scheme == "App")
        #expect(inv.targets == ["X", "Y"])
        #expect(inv.overrides.map { "\($0.name)=\($0.value)" } == ["FOO=bar"])
        #expect(inv.actions == [.clean, .build])
        #expect(inv.quiet)
        // `-userdefault=value` for names that are not options.
        let d = try ArgumentParser.parse(["-IDECustomDerivedDataLocation=/tmp/dd", "-=x", "-list"])
        #expect(d.userDefaults.map { "\($0.name)=\($0.value)" } == ["IDECustomDerivedDataLocation=/tmp/dd"])
        #expect(d.has("-list"))
        var ctx = XcodebuildContext(cwd: "/w", environment: [:], toolPath: "/t", developerDirectory: nil, home: "/Users/tester",
                                    user: "tester", hostArchitecture: "arm64", console: CapturingConsole().console)
        #expect(ctx.derivedDataRoot == "/Users/tester/Library/Developer/Xcode/DerivedData")
        ctx.derivedDataLocation = "/w/dd"
        #expect(ResolvePackages.sourcePackagesDirectory(d, name: "A", path: "/w/A.xcodeproj", context: ctx)
            .hasPrefix("/w/dd/A-"))
    }

    @Test func usageErrors() {
        func failure(_ args: [String]) -> XcodebuildFailure? {
            do { _ = try ArgumentParser.parse(args); return nil } catch { return error }
        }
        #expect(failure(["-foo"]) == XcodebuildFailure("invalid option '-foo'", exitCode: 64, withUsage: true))
        #expect(failure(["--list"])?.messages == ["invalid option '--list'"])
        #expect(failure(["-project"]) == XcodebuildFailure("option '-project' requires an argument", exitCode: 64, withUsage: true))
        #expect(failure(["-configuration", "A", "-configuration", "B"])?.messages == ["option '-configuration' may only be provided once"])
        #expect(failure(["-dry-run"])?.messages == ["option '-dry-run' is no longer supported"])
        #expect(failure(["-list", "-sdk"]) == XcodebuildFailure("-sdk must be supplied with an argument unless used with -version", exitCode: 64))
        #expect(failure(["-jobs", "0"])?.messages == ["You cannot specify -jobs with less than 1 job."])
        #expect(failure(["-version", "-sdk"]) == nil)
        #expect(failure(["-only-testing:Tests/A", "-skip-testing", "B"]) == nil)
    }

    @Test func versionSDKForms() throws {
        let a = try ArgumentParser.parse(["-version", "-sdk", "-json"])
        #expect(a.sdkWithoutValue && a.json && a.sdk == nil)
        let b = try ArgumentParser.parse(["-version", "-sdk", "macosx", "Path"])
        #expect(b.sdk == "macosx" && b.infoItems == ["Path"])
    }

    @Test func helpText() {
        #expect(HelpText.usage.hasPrefix("Usage: xcodebuild [-project <projectname>]"))
        #expect(HelpText.usage.split(separator: "\n")[1].hasPrefix("       xcodebuild [-project"))
        let opt = HelpText.options.split(separator: "\n").first { $0.hasPrefix("    -scheme NAME") }!
        #expect(opt.count > 61 && opt.dropFirst(61).hasPrefix("use the scheme"))
    }
}

@Suite struct IdentifierTests {
    @Test func md5() {
        #expect(MD5.hex("") == "d41d8cd98f00b204e9800998ecf8427e")
        #expect(MD5.hex("The quick brown fox jumps over the lazy dog") == "9e107d9d372bb6826bd81d3542a419d6")
        #expect(MD5.hex("Tool.xcodeproj") == "38ec9c10094cae125e36b85dabadc49b")
    }

    @Test func derivedDataFolder() {
        // Observed with the reference tool (specs/xcodebuild/show-build-settings.md §4).
        let path = "/Volumes/OpenDive/Xcode-clean-room-re-project/.claude/worktrees/agent-a9533b18792438340/ycode/.build-xcb-scratch/samples/Multi/Multi.xcodeproj"
        #expect(DerivedDataName.folder(name: "Multi", path: path) == "Multi-cfoytlaklycpeihhlefeyqbxaxdm")
    }

    @Test func relativePaths() {
        #expect(XcodePIF.relativePath("/a/b/C.xcodeproj", from: "/a/b") == "C.xcodeproj")
        #expect(XcodePIF.relativePath("/a/M/M.xcodeproj", from: "/a/WS") == "../M/M.xcodeproj")
    }
}
