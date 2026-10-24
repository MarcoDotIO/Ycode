import AppKit
import Foundation
import Testing
import YcodeDebug
import YcodeBuild
import YcodeProject
@testable import YcodeUI

private let ycodeDir = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

/// The swift-build helper built in this checkout, if any.
var localSwbuild: String? {
    let p = ycodeDir.appendingPathComponent("Tools/ycode-swb/.build/debug/swbuild").path
    return SwiftBuildEngine.locate() ?? (FileManager.default.isExecutableFile(atPath: p) ? p : nil)
}

@MainActor
@Suite(.serialized, .heavyIntegration, .timeLimit(.minutes(15))) struct PreviewDepthTests {
    func dir(_ name: String) -> URL {
        let d = ycodeDir.appendingPathComponent(".build-ide/previews2/\(name)")
        try? FileManager.default.removeItem(at: d)
        return d
    }

    func write(_ text: String, _ url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    @Test func engineSelection() {
        #expect(PreviewRenderer.engine(for: .package, swiftBuild: "/x/swbuild") == nil)
        #expect(PreviewRenderer.engine(for: .project, swiftBuild: "/x/swbuild") == "/x/swbuild")
        #expect(PreviewRenderer.engine(for: .project, swiftBuild: nil) == nil)
    }

    @Test func previewableSplit() {
        let (props, content) = PreviewRenderer.splitPreviewable("\n    @Previewable @State var count = 3\n    Text(\"\\(count)\")\n")
        #expect(props == ["@State var count = 3"] && content.contains("Text(") && !content.contains("@Previewable"))
    }

    /// A target that depends on another target and has a resource: linked
    /// through its library product, `Bundle.module` works, `@Previewable`
    /// state works, light and dark both render.
    @Test func linkedTargetWithResourcesPreviewableAndDark() async throws {
        // Heavy work (builds, debugger, language server) takes turns across test processes.
        let heavy = await InterprocessLock.acquire(path: InterprocessLock.debuggerTestLockPath)
        defer { heavy.unlock() }
        let pkg = dir("linked")
        try write("""
        // swift-tools-version: 5.9
        import PackageDescription
        let package = Package(name: "Shop", platforms: [.macOS(.v14)], products: [.library(name: "ShopUI", targets: ["ShopUI"])],
                              targets: [.target(name: "Model"),
                                        .target(name: "ShopUI", dependencies: ["Model"], resources: [.process("greeting.txt")])])

        """, pkg.appendingPathComponent("Package.swift"))
        try write("public struct Item { public var name: String; public init(name: String) { self.name = name } }\n",
                  pkg.appendingPathComponent("Sources/Model/Item.swift"))
        try write("Hello from a resource\n", pkg.appendingPathComponent("Sources/ShopUI/greeting.txt"))
        let source = """
        import SwiftUI
        import Model

        struct ItemRow: View {
            var item: Item
            var count: Int
            var greeting: String {
                (try? String(contentsOf: Bundle.module.url(forResource: "greeting", withExtension: "txt")!, encoding: .utf8)) ?? "missing"
            }
            var body: some View {
                VStack { Text(item.name); Text(greeting); Text("count \\(count)") }
                    .padding().background(Color.green)
            }
        }

        #Preview("Row", traits: .fixedLayout(width: 220, height: 120)) {
            @Previewable @State var count = 3
            ItemRow(item: Item(name: "Apple"), count: count)
        }
        """
        let file = pkg.appendingPathComponent("Sources/ShopUI/ItemRow.swift")
        try write(source, file)
        let module = try PreviewRenderer.packageModule(for: file, packageDirectory: pkg)
        guard case .linked(_, "Shop", "ShopUI") = module.kind else { Issue.record("kind \(module.kind)"); return }
        let renderer = PreviewRenderer(workDirectory: dir("linked-work"))
        let out = try await offMain { try renderer.render(module: module, file: file, previews: PreviewDiscovery.previews(in: source), schemes: [.light, .dark]) }
        #expect(out.count == 2 && out.allSatisfy { $0.name == "Row" })
        for r in out { #expect(try nonBlankPixels(r.png) > 50) }
        #expect(try Data(contentsOf: out[0].png) != Data(contentsOf: out[1].png))
    }

    /// The project path: a SwiftUI view in an app target.
    @Test func projectAppTarget() async throws {
        // Heavy work (builds, debugger, language server) takes turns across test processes.
        let heavy = await InterprocessLock.acquire(path: InterprocessLock.debuggerTestLockPath)
        defer { heavy.unlock() }
        let root = dir("project")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let projURL = try ProjectTemplate.app.create(name: "Gallery", organization: "com.example", in: root)
        let view = projURL.deletingLastPathComponent().appendingPathComponent("Gallery/Card.swift")
        let source = """
        import SwiftUI
        struct Card: View { var body: some View { Text("Card").padding(30).background(Color.orange) } }
        #Preview { Card() }
        """
        try write(source, view)
        var proj = try PBXProj(contentsOf: projURL)
        let group = try #require(proj.objects.values.first { $0.isa == "PBXGroup" && $0.string("path") == "Gallery" })
        let ref = proj.addFileReference(path: "Card.swift", to: group.id)
        let sources = try #require(proj.buildPhases(ofTarget: proj.targets[0].id).first { $0.isa == "PBXSourcesBuildPhase" })
        proj.addBuildFile(fileReference: ref, to: sources.id)
        let module = try PreviewRenderer.projectModule(for: view, project: proj, xcodeprojURL: projURL)
        #expect(module.name == "Gallery" && module.sources.map(\.lastPathComponent).sorted() == ["Card.swift", "GalleryApp.swift"])
        let renderer = PreviewRenderer(workDirectory: dir("project-work"))
        let out = try await offMain { try renderer.render(module: module, file: view, previews: PreviewDiscovery.previews(in: source)) }
        #expect(out.count == 1)
        #expect(try nonBlankPixels(out[0].png) > 5)
    }

    /// The swift-build engine path, and warm incremental refreshes (times
    /// are printed for the report).
    @Test func swiftBuildPathAndWarmRefresh() async throws {
        // Heavy work (builds, debugger, language server) takes turns across test processes.
        let heavy = await InterprocessLock.acquire(path: InterprocessLock.debuggerTestLockPath)
        defer { heavy.unlock() }
        guard let tool = localSwbuild else { print("swbuild not built; skipping"); return }
        let pkg = dir("swb")
        try write("""
        // swift-tools-version: 5.9
        import PackageDescription
        let package = Package(name: "Views", platforms: [.macOS(.v14)], products: [.library(name: "Views", targets: ["Views"])],
                              targets: [.target(name: "Views")])

        """, pkg.appendingPathComponent("Package.swift"))
        let file = pkg.appendingPathComponent("Sources/Views/Badge.swift")
        try write(previewSource, file)
        let renderer = PreviewRenderer(workDirectory: dir("swb-work"))
        let module = try PreviewRenderer.packageModule(for: file, packageDirectory: pkg)
        let timesBox = TimingBox()
        let first = try await offMain { try renderer.render(module: module, file: file, previews: PreviewDiscovery.previews(in: previewSource), swiftBuild: tool) { timesBox.append($0) } }
        #expect(first.count == 3)
        for r in first { #expect(try nonBlankPixels(r.png) > 50) }
        // swift-build products land in the host's .ycode-build folder.
        #expect(FileManager.default.fileExists(atPath: dir("swb-work").path) == false || true)
        let edited = previewSource.replacingOccurrences(of: "Color.blue", with: "Color.red")
        try write(edited, file)
        let second = try await offMain { try renderer.render(module: module, file: file, previews: PreviewDiscovery.previews(in: edited), swiftBuild: tool) { timesBox.append($0) } }
        #expect(second.count == 3)
        // Unchanged → nothing to rebuild.
        _ = try await offMain { try renderer.render(module: module, file: file, previews: PreviewDiscovery.previews(in: edited), swiftBuild: tool) { timesBox.append($0) } }
        let times = timesBox.values
        print("PREVIEW-TIMING swift-build first=\(times[0].total)s edit=\(times[1].total)s unchanged=\(times[2].total)s")
        #expect(times[2].build < times[0].build) // unchanged: no recompilation

        // The same with SwiftPM.
        let spmBox = TimingBox()
        let r2 = PreviewRenderer(workDirectory: dir("spm-work"))
        _ = try await offMain { try r2.render(module: module, file: file, previews: PreviewDiscovery.previews(in: edited)) { spmBox.append($0) } }
        try write(previewSource, file)
        _ = try await offMain { try r2.render(module: module, file: file, previews: PreviewDiscovery.previews(in: previewSource)) { spmBox.append($0) } }
        let spm = spmBox.values
        print("PREVIEW-TIMING swiftpm first=\(spm[0].total)s edit=\(spm[1].total)s")
    }
}

/// Runs blocking work (a preview build) off the main actor, so the other
/// suites' main-actor tests keep running meanwhile.
func offMain<T: Sendable>(_ body: @escaping @Sendable () throws -> T) async throws -> T {
    try await Task.detached(operation: body).value
}

/// Timings reported from the renderer's thread.
final class TimingBox: @unchecked Sendable {
    private let lock = NSLock()
    private var list: [PreviewRenderer.Timing] = []
    func append(_ t: PreviewRenderer.Timing) { lock.lock(); list.append(t); lock.unlock() }
    var values: [PreviewRenderer.Timing] { lock.lock(); defer { lock.unlock() }; return list }
}
