import Foundation
import Testing
import YcodeRelease

/// `ycode/VERSION` is the source of truth; everything that states the version
/// outside the scripts' reach must agree with it.
@Suite struct VersionAgreementTests {
    /// `ycode/` of this checkout.
    private static let package = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    private static let root = package.deletingLastPathComponent()

    private static func text(_ url: URL) throws -> String { try String(contentsOf: url, encoding: .utf8) }
    private static func versionFile() throws -> String {
        try text(package.appendingPathComponent("VERSION")).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    @Test func theConstantMatchesTheVersionFile() throws {
        #expect(YcodeRelease.version == (try Self.versionFile()))
    }

    @Test func theVersionFileIsOneSemanticVersionLine() throws {
        let raw = try Self.text(Self.package.appendingPathComponent("VERSION"))
        #expect(raw.filter { $0 == "\n" }.count == 1)
        #expect(try Self.versionFile().wholeMatch(of: /[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.]+)?/) != nil)
    }

    @Test func theMetainfoNamesThisVersionAsItsNewestRelease() throws {
        let metainfo = Self.root.appendingPathComponent("packaging/flatpak/io.github.MarcoDotIO.Ycode.metainfo.xml")
        guard FileManager.default.fileExists(atPath: metainfo.path) else { return } // an rsync of ycode/ alone
        let first = try Self.text(metainfo).firstMatch(of: /<release[^>]*version="([^"]+)"/)
        #expect(first.map { String($0.output.1) } == (try Self.versionFile()))
    }

    @Test func thePackagingScriptsStateNoVersionOfTheirOwn() throws {
        let scripts = ["ycode/scripts/make-app.sh", "ycode/scripts/make-dmg.sh", "packaging/macos/Info.plist.in",
                       "packaging/flatpak/build-flatpak.sh", "packaging/flatpak/io.github.MarcoDotIO.Ycode.yml"]
        let version = try Self.versionFile()
        for s in scripts {
            let url = Self.root.appendingPathComponent(s)
            guard FileManager.default.fileExists(atPath: url.path) else { continue }
            #expect(try !Self.text(url).contains(version), "\(s) states the version; read ycode/VERSION instead")
        }
    }

    @Test func theVersionLineNamesTheTool() {
        #expect(YcodeRelease.versionLine(tool: "ycodebuild") == "ycodebuild \(YcodeRelease.version)")
    }
}

@Suite struct BundledHelpersTests {
    @Test func theHelpersFolderComesFirstOnThePath() {
        let exe = URL(fileURLWithPath: "/Apps/Ycode.app/Contents/MacOS/Ycode")
        let path = YcodeRelease.pathWithBundledHelpers(executable: exe, path: "/usr/bin") { $0 == "/Apps/Ycode.app/Contents/Helpers" }
        #expect(path == "/Apps/Ycode.app/Contents/Helpers:/usr/bin")
    }

    @Test func aBundleWithoutHelpersLeavesThePathAlone() {
        let exe = URL(fileURLWithPath: "/x/.build/debug/YcodeApp")
        #expect(YcodeRelease.pathWithBundledHelpers(executable: exe, path: "/usr/bin") { _ in false } == nil)
    }

    @Test func aLinuxPackagePutsItsToolsFirstWhereverItIsUnpacked() {
        let exe = URL(fileURLWithPath: "/anywhere/Y/bin/ycode-ide")
        let inFlatpak = YcodeRelease.packageEnvironment(executable: exe, environment: ["PATH": "/usr/bin", "FLATPAK_ID": "x"]) { $0 == "/anywhere/Y/libexec/ycode-host" }
        #expect(inFlatpak["PATH"] == "/anywhere/Y/libexec/ycode-host:/anywhere/Y/bin:/usr/bin")
        #expect(inFlatpak["YCODE_SWB"] == "/anywhere/Y/bin/ycode-swb")
        let plain = YcodeRelease.packageEnvironment(executable: exe, environment: ["PATH": "/usr/bin"]) { $0 == "/anywhere/Y/libexec/ycode-host" }
        #expect(plain["PATH"] == "/anywhere/Y/bin:/usr/bin")
    }

    @Test func aBuildFolderIsNotAPackage() {
        let exe = URL(fileURLWithPath: "/x/.build/release/ycode-ide")
        #expect(YcodeRelease.packageEnvironment(executable: exe, environment: ["PATH": "/usr/bin"]) { _ in false }.isEmpty)
    }

    @Test func noPathStillFindsTheSystem() {
        let exe = URL(fileURLWithPath: "/A.app/Contents/MacOS/Y")
        #expect(YcodeRelease.pathWithBundledHelpers(executable: exe, path: nil) { _ in true }?.hasSuffix(":/usr/bin:/bin:/usr/sbin:/sbin") == true)
    }
}
