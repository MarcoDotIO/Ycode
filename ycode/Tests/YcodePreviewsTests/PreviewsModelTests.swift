// Previews' model (specs/ide/previews.md): discovery with traits, the payload
// generator (wrappers, line maps, blanking), compiler arguments and issue
// mapping, the host's reports and plan, the update planner, and the screen
// layout. No compiler or device is needed; these run on Linux too.

import Foundation
import Testing
@testable import YcodePreviews

let sample = """
import SwiftUI

@main struct SampleApp: App {
    var body: some Scene { WindowGroup { ContentView() } }
}

fileprivate let greeting = "Hello"

struct ContentView: View {
    var body: some View { Text(greeting) }
}

#Preview("Card", traits: .landscapeLeft, .fixedLayout(width: 300, height: 200)) {
    ContentView()
}

#Preview {
    @Previewable @State var on = true
    Toggle("On", isOn: $on)
}

#Preview(traits: .sizeThatFitsLayout) {
    let vc = UIViewController()
    return vc
}
"""

@Suite(.timeLimit(.minutes(2))) struct DiscoveryTraitTests {
    @Test func traitsOrientationAndLayout() {
        let p = PreviewDiscovery.previews(in: sample)
        #expect(p.map(\.name) == ["Card", "Preview", "Preview 2"])
        #expect(p[0].traits == ["landscapeLeft", "fixedLayout"])
        #expect(p[0].orientation == .landscapeLeft && p[0].layout == .fixed(CGSize(width: 300, height: 200)))
        #expect(p[1].traits.isEmpty && p[1].layout == .device && p[1].orientation == .portrait)
        #expect(p[2].layout == .sizeThatFits)
        // The body starts on the line of its brace.
        #expect(p[1].line == 17 && p[1].bodyLine == 17)
    }

    @Test func entryPointsAndPreviewsAreBlankedKeepingLines() {
        let b = PreviewDiscovery.blankingPreviewsAndEntryPoints(sample)
        #expect(b.utf16.count == sample.utf16.count)
        #expect(!b.contains("@main") && !b.contains("#Preview") && b.contains("struct SampleApp: App"))
        #expect(b.split(separator: "\n", omittingEmptySubsequences: false).count == sample.split(separator: "\n", omittingEmptySubsequences: false).count)
        // A string or comment that mentions @main is left alone.
        let t = "let s = \"@main\" // @main\n@main struct A {}"
        let bt = PreviewDiscovery.blankingPreviewsAndEntryPoints(t)
        #expect(bt == "let s = \"@main\" // @main\n      struct A {}")
        // @mainActor-like identifiers are not entry points.
        #expect(PreviewDiscovery.blankingPreviewsAndEntryPoints("@mainly x").contains("@mainly"))
    }
}

@Suite(.timeLimit(.minutes(2))) struct PayloadGeneratorTests {
    func temp() throws -> URL {
        let d = FileManager.default.temporaryDirectory.appendingPathComponent("ycode-payload-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    @Test func wrappersCoverMacroPreviewableAndProvider() {
        let previews = PreviewDiscovery.previews(in: sample + "\nstruct X_Previews: PreviewProvider { static var previews: some View { Text(\"x\") } }\n")
        let w = PreviewPayloadGenerator.wrappers(previews, first: 5, platform: .iOS)
        #expect(w.contains("@MainActor func __ycodePreview_5() -> UIViewController { __ycodeHost {"))
        #expect(w.contains("struct __YcodePreviewView_6: View {\n    @State var on = true\n"))
        #expect(w.contains("__ycodeHost { __YcodePreviewView_6() }"))
        #expect(w.contains("func __ycodePreview_8() -> UIViewController { __ycodeHost { X_Previews.previews } }"))
        #expect(w.contains("import UIKit"))
        let mac = PreviewPayloadGenerator.wrappers(previews, first: 0, platform: .macOS)
        #expect(mac.contains("-> NSViewController") && mac.contains("import AppKit"))
    }

    @Test func supportFileExportsTheFactories() {
        let s = PreviewPayloadGenerator.supportFile(platform: .iOS, count: 2)
        #expect(s.contains("@_cdecl(\"ycode_preview_count\") public func __ycodePreviewCount() -> Int32 { 2 }"))
        #expect(s.contains("@_cdecl(\"ycode_preview_make\")"))
        #expect(s.contains("case 0: return __ycodePreview_0()") && s.contains("case 1: return __ycodePreview_1()"))
        #expect(s.contains("@_disfavoredOverload @MainActor func __ycodeHost(_ make: @MainActor () -> UIViewController)"))
        #expect(s.contains("UIHostingController(rootView: AnyView(make()))"))
        #expect(PreviewPayloadGenerator.supportFile(platform: .visionOS, count: 0).contains("UIHostingController"))
        #expect(PreviewPayloadGenerator.supportFile(platform: .macOS, count: 0).contains("NSHostingController"))
    }

    @Test func generateWritesChangedFilesOnlyAndMapsLines() throws {
        let dir = try temp()
        let a = dir.appendingPathComponent("ContentView.swift"), b = dir.appendingPathComponent("Model.swift")
        try sample.write(to: a, atomically: true, encoding: .utf8)
        try "struct Model {}\n".write(to: b, atomically: true, encoding: .utf8)
        let previews = PreviewDiscovery.previews(in: sample)
        let out = dir.appendingPathComponent("src")
        let s1 = try PreviewPayloadGenerator.generate(moduleFiles: [a, b], previewed: [PreviewedFile(url: a, previews: previews)],
                                                      platform: .iOS, into: out)
        #expect(s1.files.map(\.lastPathComponent) == ["0_ContentView.swift", "1_Model.swift", "YcodePreviewSupport.swift"])
        #expect(s1.previews.count == 3 && s1.changed.count == 2)
        let copy = try String(contentsOf: s1.files[0], encoding: .utf8)
        #expect(!copy.contains("@main") && copy.contains("__ycodePreview_2()"))
        // An error on a wrapper body's line maps to the #Preview body.
        let map = try #require(s1.lineMaps[s1.files[0].path])
        let copyLines = copy.split(separator: "\n", omittingEmptySubsequences: false)
        let i = try #require(copyLines.firstIndex { $0.contains("func __ycodePreview_0()") })
        #expect(map.fileLine(i + 1) == previews[0].bodyLine)
        #expect(map.fileLine(3) == 3)
        // Nothing changed: nothing is rewritten.
        let s2 = try PreviewPayloadGenerator.generate(moduleFiles: [a, b], previewed: [PreviewedFile(url: a, previews: previews)],
                                                      platform: .iOS, into: out)
        #expect(s2.changed.isEmpty)
        // Unsaved text overrides the file; a stale copy is removed.
        let s3 = try PreviewPayloadGenerator.generate(moduleFiles: [a], previewed: [PreviewedFile(url: a, previews: previews)], platform: .iOS,
                                                      into: out, texts: [a: sample.replacingOccurrences(of: "Hello", with: "Hi")])
        #expect(s3.changed == [a.standardizedFileURL])
        #expect(!FileManager.default.fileExists(atPath: out.appendingPathComponent("1_Model.swift").path))
    }

    @Test func aPinnedFileComesAfterTheFocusedOneWithContinuedIndices() throws {
        let dir = try temp()
        let a = dir.appendingPathComponent("A.swift"), b = dir.appendingPathComponent("B.swift")
        try "import SwiftUI\n#Preview { Text(\"a\") }\n".write(to: a, atomically: true, encoding: .utf8)
        try "import SwiftUI\n#Preview(\"B\") { Text(\"b\") }\n".write(to: b, atomically: true, encoding: .utf8)
        let s = try PreviewPayloadGenerator.generate(
            moduleFiles: [a, b], previewed: [PreviewedFile(url: a, previews: PreviewDiscovery.previews(in: try String(contentsOf: a, encoding: .utf8))),
                                             PreviewedFile(url: b, previews: PreviewDiscovery.previews(in: try String(contentsOf: b, encoding: .utf8)))],
            platform: .iOS, into: dir.appendingPathComponent("src"))
        #expect(s.previews.map(\.name) == ["Preview", "B"])
        #expect(s.previewFiles == [a.standardizedFileURL, b.standardizedFileURL])
        #expect(try String(contentsOf: s.files[1], encoding: .utf8).contains("__ycodePreview_1()"))
    }
}

@Suite(.timeLimit(.minutes(2))) struct CompilerTests {
    @Test func payloadArgumentsForEachPlatform() {
        let c = PreviewCompiler(platform: .iOS, deploymentTarget: "27.0", moduleName: "App", moduleCache: URL(fileURLWithPath: "/tmp/mc/../mc"))
        let args = c.payloadArguments(sources: [URL(fileURLWithPath: "/w/0_A.swift")], output: URL(fileURLWithPath: "/w/payload-3.dylib"))
        #expect(Array(args.prefix(3)) == ["--sdk", "iphonesimulator", "swiftc"])
        #expect(args.contains("arm64-apple-ios27.0-simulator") && args.contains("-emit-library") && args.contains("-wmo"))
        #expect(args.contains("@rpath/payload-3.dylib") && args.last == "/w/0_A.swift")
        // The module cache is absolute and normalized (a "../" in it makes clang see two caches).
        #expect(args.contains("/tmp/mc"))
        #expect(args.firstIndex(of: "-swift-version").map { args[$0 + 1] } == "5")
        #expect(PreviewPlatform.visionOS.targetTriple(deploymentTarget: "27.0") == "arm64-apple-xros27.0-simulator")
        #expect(PreviewPlatform.macOS.sdk == "macosx" && PreviewPlatform(destinationPlatform: "iOS Simulator") == .iOS)
        #expect(PreviewPlatform(destinationPlatform: "watchOS") == nil)
    }

    @Test func issuesMapBackToTheUsersFile() {
        let user = URL(fileURLWithPath: "/p/ContentView.swift")
        let map = PreviewPayloadGenerator.LineMap(original: user, originalLines: 20, bodies: [(25, 14)])
        let log = """
        /w/src/0_ContentView.swift:26:9: error: cannot find 'Nope' in scope
        /w/src/YcodePreviewSupport.swift:3:1: error: something generated
        /w/src/0_ContentView.swift:7:3: error: missing argument
        """
        let issues = PreviewCompiler.issues(from: log, lineMaps: ["/w/src/0_ContentView.swift": map])
        #expect(issues.count == 3)
        #expect(issues[0] == PreviewIssue(file: user, line: 15, column: 9, message: "cannot find 'Nope' in scope"))
        #expect(issues[1].line == 7 && issues[1].description == "ContentView.swift:7: missing argument")
        #expect(issues[2].file == nil)
        // A log without diagnostics still gives one issue.
        #expect(PreviewCompiler.issues(from: "ld: library not found\n", lineMaps: [:]).first?.message == "ld: library not found")
    }
}

@Suite(.timeLimit(.minutes(2))) struct HostAndPlanTests {
    @Test func reports() {
        #expect(PreviewHost.parseReport("YCODE-PREVIEW started") == .started)
        #expect(PreviewHost.parseReport("YCODE-PREVIEW ready 7 92") == .ready(generation: 7, milliseconds: 92))
        #expect(PreviewHost.parseReport("x YCODE-PREVIEW error 3 dlopen failed: no such file") == .error(generation: 3, message: "dlopen failed: no such file"))
        #expect(PreviewHost.parseReport("YCODE-PREVIEW ready x") == nil && PreviewHost.parseReport("hello") == nil)
    }

    @Test func infoPlistAndHostSource() {
        let ios = PreviewHost.infoPlist(platform: .iOS, deploymentTarget: "27.0")
        #expect(ios.contains("<string>dev.ycode.previewhost</string>") && ios.contains("iPhoneSimulator") && ios.contains("<integer>1</integer><integer>2</integer>"))
        #expect(ios.contains("YcodePreviewHost.SceneDelegate") && ios.contains("<key>MinimumOSVersion</key><string>27.0</string>"))
        #expect(PreviewHost.infoPlist(platform: .visionOS, deploymentTarget: "27.0").contains("XRSimulator"))
        #expect(PreviewHost.uikitSource.contains("dlopen(payload, RTLD_NOW | RTLD_LOCAL)") && PreviewHost.uikitSource.contains("\"ycode_preview_make\""))
        #expect(PreviewHost.uikitSource.contains("report(\"ready \\(plan.generation)"))
        let args = PreviewHost.hostArguments(platform: .iOS, deploymentTarget: "27.0", source: URL(fileURLWithPath: "/h/main.swift"),
                                             output: URL(fileURLWithPath: "/h/x"), moduleCache: URL(fileURLWithPath: "/h/mc"))
        #expect(args.contains("YcodePreviewHost") && args.contains("arm64-apple-ios27.0-simulator"))
    }

    @Test func iconIsAValidPNG() {
        let png = PreviewHost.iconPNG(size: 120)
        #expect(png.prefix(8) == Data([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]))
        // Width and height in IHDR; the stored deflate data is at least the raw size.
        #expect(Array(png[16..<24]) == [0, 0, 0, 120, 0, 0, 0, 120] && png.count > 120 * 361)
        #expect(png.suffix(12) == Data([0, 0, 0, 0, 0x49, 0x45, 0x4e, 0x44, 0xae, 0x42, 0x60, 0x82]))
        #expect(PreviewHost.infoPlist(platform: .iOS, deploymentTarget: "27.0").contains("<string>AppIcon60x60</string>"))
    }

    @Test func planJSONRoundTrips() throws {
        let plan = PreviewPlan(generation: 4, payload: "/tmp/ycode-previews/payload-4.dylib",
                               regions: [PreviewRegion(preview: 1, x: 0, y: 0, width: 201, height: 437, scale: 0.5, style: "dark")])
        let back = try JSONDecoder().decode(PreviewPlan.self, from: plan.json())
        #expect(back == plan)
        #expect(String(decoding: plan.json(), as: UTF8.self).contains("\"generation\":4"))
    }
}

@Suite(.timeLimit(.minutes(2))) struct ScreenLayoutTests {
    let phone = CGSize(width: 402, height: 874)

    @Test func oneDeviceTileFillsTheScreen() {
        let r = PreviewScreenLayout.regions([PreviewTile(preview: 0, size: phone)], screen: phone)
        #expect(r == [PreviewRegion(preview: 0, x: 0, y: 0, width: 402, height: 874, scale: 1)])
    }

    @Test func twoDeviceTilesSitSideBySide() {
        let r = PreviewScreenLayout.regions([PreviewTile(preview: 0, size: phone), PreviewTile(preview: 1, variant: PreviewVariant(colorScheme: "dark"), size: phone)],
                                            screen: phone)
        #expect(r.count == 2 && r[0].scale == 0.5 && r[1].scale == 0.5)
        #expect(r[0].x == 0 && r[1].x == 201 && r[0].y == r[1].y)
        #expect(r[0].width == 201 && r[0].height == 437 && r[1].style == "dark")
    }

    @Test func sixVariantsFormAThreeByTwoGrid() {
        let tiles = (0..<6).map { PreviewTile(preview: 0, variant: PreviewVariant(dynamicType: PreviewVariant.dynamicTypeVariantSizes[$0]), size: phone) }
        let r = PreviewScreenLayout.regions(tiles, screen: phone)
        #expect(Set(r.map(\.y)).count == 2 && Set(r.map(\.x)).count == 3)
        #expect(abs(r[0].scale - 1.0 / 3) < 1e-9 && r[5].dynamicType == "accessibility5")
        // Every region stays on the screen.
        #expect(r.allSatisfy { $0.x >= 0 && $0.y >= 0 && $0.x + $0.width <= 402.001 && $0.y + $0.height <= 874.001 })
    }

    @Test func smallFixedTilesAreNotEnlarged() {
        let r = PreviewScreenLayout.regions([PreviewTile(preview: 0, size: CGSize(width: 120, height: 60))], screen: phone)
        #expect(r[0].scale == 1 && r[0].width == 120 && r[0].x == 141)
    }

    @Test func landscapeTurnsTheTile() {
        let p = PreviewDiscovery.previews(in: "#Preview(traits: .landscapeRight) { Text(\"x\") }")[0]
        #expect(PreviewScreenLayout.tileSize(p, screen: phone, variant: PreviewVariant()) == CGSize(width: 874, height: 402))
        #expect(PreviewScreenLayout.tileSize(p, screen: phone, variant: PreviewVariant(orientation: .portrait)) == phone)
    }
}

@Suite(.timeLimit(.minutes(2))) struct UpdatePlannerTests {
    func inputs(_ text: String = "a", layout: [PreviewRegion] = [], destination: String = "d", resources: [String: Int] = [:], linked: Bool = false) -> PreviewInputs {
        PreviewInputs(destination: destination, module: "App", linked: linked, sourceHashes: ["/p/A.swift": PreviewInputs.hash(text)],
                      resourceHashes: resources, previewsHash: 1, layout: layout)
    }
    let running = PreviewHostState(running: true, loads: 1)
    let region = PreviewRegion(preview: 0, x: 0, y: 0, width: 402, height: 874, scale: 1)

    @Test func decisions() {
        #expect(PreviewUpdatePlanner.decide(previous: nil, current: inputs(), host: PreviewHostState(running: false)) == .relaunchHost(reason: "first preview"))
        #expect(PreviewUpdatePlanner.decide(previous: inputs(), current: inputs(), host: running) == PreviewUpdate.none)
        // A body edit: a new payload, no relaunch.
        #expect(PreviewUpdatePlanner.decide(previous: inputs("a"), current: inputs("b"), host: running) == .reloadPayload)
        // Only the layout: a new plan.
        #expect(PreviewUpdatePlanner.decide(previous: inputs(), current: inputs(layout: [region]), host: running) == .relayout)
        // The host crashed or stopped.
        if case .relaunchHost = PreviewUpdatePlanner.decide(previous: inputs("a"), current: inputs("b"), host: PreviewHostState(running: true, failed: true)) {} else { Issue.record("failed host") }
        if case .relaunchHost = PreviewUpdatePlanner.decide(previous: inputs(), current: inputs(), host: PreviewHostState(running: false)) {} else { Issue.record("stopped host") }
        // Another device.
        if case .relaunchHost = PreviewUpdatePlanner.decide(previous: inputs(), current: inputs(destination: "e"), host: running) {} else { Issue.record("device") }
        // Too many images loaded.
        if case .relaunchHost = PreviewUpdatePlanner.decide(previous: inputs("a"), current: inputs("b"),
                                                            host: PreviewHostState(running: true, loads: PreviewUpdatePlanner.maximumLoads)) {} else { Issue.record("loads") }
        // Fallbacks to a rebuild.
        if case .rebuild = PreviewUpdatePlanner.decide(previous: inputs(), current: inputs(resources: ["Assets": 2]), host: running) {} else { Issue.record("resources") }
        if case .rebuild = PreviewUpdatePlanner.decide(previous: nil, current: inputs(linked: true), host: running) {} else { Issue.record("linked") }
    }

    @Test func hashesAreStable() {
        #expect(PreviewInputs.hash("abc") == PreviewInputs.hash("abc") && PreviewInputs.hash("abc") != PreviewInputs.hash("abd"))
        // FNV-1a of "" is the offset basis.
        #expect(UInt64(bitPattern: Int64(PreviewInputs.hash(""))) == 0xcbf2_9ce4_8422_2325)
    }
}
