import AppKit
import Foundation
import Testing
import YcodeProject
@testable import YcodeUI

private let ycodeDir = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

/// A package `Kit` (products Kit, KitTools) in a git repository with tags
/// 1.0.0 and 1.1.0: the "remote" for package tests. Never the network.
func makeLocalPackageRemote(in dir: URL) throws -> URL {
    let repo = dir.appendingPathComponent("remote/Kit")
    try FileManager.default.createDirectory(at: repo.appendingPathComponent("Sources/Kit"), withIntermediateDirectories: true)
    try """
    // swift-tools-version:5.9
    import PackageDescription
    let package = Package(name: "Kit", products: [.library(name: "Kit", targets: ["Kit"]), .library(name: "KitTools", targets: ["Kit"])],
                          targets: [.target(name: "Kit")])

    """.write(to: repo.appendingPathComponent("Package.swift"), atomically: true, encoding: .utf8)
    func git(_ args: String...) throws {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        p.arguments = ["git"] + args
        p.currentDirectoryURL = repo
        p.environment = ProcessInfo.processInfo.environment.merging(
            ["GIT_AUTHOR_NAME": "t", "GIT_AUTHOR_EMAIL": "t@t", "GIT_COMMITTER_NAME": "t", "GIT_COMMITTER_EMAIL": "t@t"]) { $1 }
        p.standardOutput = FileHandle.nullDevice
        try p.run()
        p.waitUntilExit()
    }
    try git("init", "-q", "-b", "main")
    for (i, tag) in ["1.0.0", "1.1.0"].enumerated() {
        try "public let v = \(i)\n".write(to: repo.appendingPathComponent("Sources/Kit/Kit.swift"), atomically: true, encoding: .utf8)
        try git("add", "-A")
        try git("commit", "-q", "-m", tag)
        try git("tag", tag)
    }
    return repo
}

@MainActor
@Suite(.serialized, .heavyIntegration) struct PackageDependencyUITests {
    @Test func addRemoteAndLocalPackages() async throws {
        _ = NSApplication.shared
        let dir = ycodeDir.appendingPathComponent(".build-ide/packages")
        try? FileManager.default.removeItem(at: dir)
        let proj = dir.appendingPathComponent("Hello.xcodeproj")
        try FileManager.default.createDirectory(at: proj, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: ycodeDir.appendingPathComponent("Tests/YcodeProjectTests/Fixtures/Hello.xcodeproj/project.pbxproj"),
                                         to: proj.appendingPathComponent("project.pbxproj"))
        let remote = try makeLocalPackageRemote(in: dir)
        let session = WorkspaceSession(model: try WorkspaceModel(url: proj))
        let wc = WorkspaceWindowController(session: session, loadDestinations: false, startLanguageService: false)
        wc.packageCheckoutsDirectory = dir.appendingPathComponent("SourcePackages/checkouts")
        wc.window?.appearance = NSAppearance(named: .aqua)
        wc.applyDefaultLayout()
        // The fixture's package shows in the navigator (unresolved: no version).
        #expect(wc.navigator.rows(0).map(\.title) == ["Hello", "Package Dependencies"])
        #expect(wc.navigator.rows(0)[1].children.map(\.title) == ["swift-argument-parser"])

        let pe = try #require(wc.openProjectEditor(proj.path))
        pe.select(target: nil, tab: .packageDependencies)
        #expect(ProjectEditorController.tabs(forTarget: false) == [.info, .buildSettings, .packageDependencies])
        #expect(pe.packageRows.map(\.rule) == ["1.5.0 – Next Major"])
        pe.removePackage("0F0000000000000000000001")
        #expect(pe.packageRows.isEmpty)

        // Remote (a file:// git URL), up to next minor from 1.0.0 → 1.0.0.
        let sheet = try #require(wc.addPackageDependencies(nil))
        _ = sheet.view
        sheet.locationField.stringValue = remote.absoluteString
        sheet.rule = .upToNextMinor
        sheet.valueField.stringValue = "1.0.0"
        await sheet.add()
        #expect(sheet.errorLabel.stringValue == "")
        #expect(sheet.fetchedProducts == ["Kit", "KitTools"])
        sheet.productChecks[1].state = .off
        await sheet.add()
        await wc.packageWork?.value   // resolution runs in the background
        let pbx = try String(contentsOf: proj.appendingPathComponent("project.pbxproj"), encoding: .utf8)
        #expect(pbx.contains("kind = upToNextMinorVersion;") && pbx.contains("/* XCRemoteSwiftPackageReference \"Kit\" */"))
        #expect(pbx.contains("/* Kit in Frameworks */") && !pbx.contains("KitTools"))
        let resolved = try String(contentsOf: proj.appendingPathComponent("project.xcworkspace/xcshareddata/swiftpm/Package.resolved"), encoding: .utf8)
        #expect(resolved.contains("\"version\" : \"1.0.0\""))
        let section = try #require(wc.navigator.rows(0).last)
        #expect(section.title == "Package Dependencies" && section.children.map(\.title) == ["Kit 1.0.0"])
        #expect(section.children[0].children.map(\.title).contains("Package"))  // extensions hidden by default
        #expect(pe.packageRows.map(\.products) == [["Kit"]])

        // Local path, relative to the project directory.
        let local = try #require(wc.addPackageDependencies(nil))
        _ = local.view
        local.locationField.stringValue = remote.path
        await local.add()
        await local.add()
        await wc.packageWork?.value
        let pbx2 = try String(contentsOf: proj.appendingPathComponent("project.pbxproj"), encoding: .utf8)
        #expect(pbx2.contains("relativePath = remote/Kit;"))
        #expect(wc.navigator.rows(0).last?.children.map(\.title) == ["Kit 1.0.0", "Kit"])
        pe.select(target: nil, tab: .packageDependencies)
        _ = try WindowSnapshotTests().render(wc.window!.contentView!.superview!, to: "project-editor-packages.png")
    }

    @Test func resolveErrorsAndKnownRegions() async throws {
        _ = NSApplication.shared
        let dir = ycodeDir.appendingPathComponent(".build-ide/packages-errors")
        try? FileManager.default.removeItem(at: dir)
        let proj = dir.appendingPathComponent("Hello.xcodeproj")
        try FileManager.default.createDirectory(at: proj, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: ycodeDir.appendingPathComponent("Tests/YcodeProjectTests/Fixtures/Hello.xcodeproj/project.pbxproj"),
                                         to: proj.appendingPathComponent("project.pbxproj"))
        let remote = try makeLocalPackageRemote(in: dir)
        let wc = WorkspaceWindowController(session: WorkspaceSession(model: try WorkspaceModel(url: proj)), loadDestinations: false, startLanguageService: false)
        wc.packageCheckoutsDirectory = dir.appendingPathComponent("checkouts")
        wc.applyDefaultLayout()
        var p = try #require(wc.session.model.projects[proj.path])
        p.removePackage("0F0000000000000000000001")
        p.addRemotePackage(url: remote.absoluteString, requirement: .upToNextMajor(from: "3.0.0"))
        wc.projectChanged(path: proj.path, p)
        #expect(await !wc.resolvePackageVersions())
        #expect(wc.session.displayedIssues.first?.message.contains("no version of kit satisfies the project requires 3.0.0 – Next Major") == true)
        #expect(wc.navigator.rows(4).first?.children.first?.title.contains("Package resolution failed") == true)
        p.setRequirement(.upToNextMajor(from: "1.0.0"), ofPackage: try #require(p.packageReferences.first?.id))
        wc.projectChanged(path: proj.path, p)
        #expect(await wc.resolvePackageVersions())
        #expect(wc.session.packageIssues.isEmpty)
        let resolved = try String(contentsOf: proj.appendingPathComponent("project.xcworkspace/xcshareddata/swiftpm/Package.resolved"), encoding: .utf8)
        #expect(resolved.contains("\"originHash\" : ") && resolved.contains("\"version\" : 3"))

        // Adding a String Catalog language adds it to knownRegions.
        let strings = dir.appendingPathComponent("Hello/Localizable.xcstrings")
        try FileManager.default.createDirectory(at: strings.deletingLastPathComponent(), withIntermediateDirectories: true)
        try StringCatalog().data().write(to: strings)
        wc.open(path: strings.path, line: nil)
        let ed = try #require(wc.stringCatalogEditor)
        ed.addLanguage("de")
        ed.addLanguage("de")
        let pbx = try String(contentsOf: proj.appendingPathComponent("project.pbxproj"), encoding: .utf8)
        #expect(pbx.contains("knownRegions = (\n\t\t\t\ten,\n\t\t\t\tBase,\n\t\t\t\tde,\n\t\t\t);"))
    }

    @Test func sheetRules() throws {
        let s = AddPackageController(targets: ["App"])
        _ = s.view
        s.valueField.stringValue = "1.2.0"
        s.rule = .range
        s.upperField.stringValue = "1.9.0"
        #expect(s.requirement == .range(from: "1.2.0", to: "1.9.0"))
        s.rule = .branch
        #expect(s.requirement == .branch("main"))
        s.rule = .exact
        #expect(s.requirement == .exact("1.0.0"))
        #expect(PackageDependencyModel.isLocalPath("../Kit") && PackageDependencyModel.isLocalPath("/tmp/Kit"))
        #expect(!PackageDependencyModel.isLocalPath("https://example.com/Kit.git") && !PackageDependencyModel.isLocalPath("file:///tmp/Kit"))
        #expect(!PackageDependencyModel.isLocalPath("git@example.com:a/Kit.git"))
    }
}
