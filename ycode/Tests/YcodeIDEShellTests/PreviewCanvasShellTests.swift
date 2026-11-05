import Foundation
import Testing
import YcodeEditorKit
@testable import YcodeIDECore
@testable import YcodeIDEShell
import YcodePreviews

/// An engine that records requests and answers with the tiles' requested
/// sizes (or a scripted failure), after an optional delay.
final class FakePreviewEngine: PreviewCanvasEngine, @unchecked Sendable {
    let lock = NSLock()
    var requests: [PreviewCanvasRequest] = []
    var failure: PreviewFailure?
    var delay: TimeInterval = 0
    var stopped = false

    func update(_ request: PreviewCanvasRequest, generation: Int, progress: @escaping @Sendable (String) -> Void) async
        -> Result<PreviewCanvasOutcome, PreviewFailure>? {
        lock.withLock { requests.append(request) }
        progress("Compiling the preview")
        if delay > 0 { try? await Task.sleep(nanoseconds: UInt64(delay * 1e9)) }
        if let failure = lock.withLock({ failure }) { return .failure(failure) }
        let pics = request.tiles.indices.map { URL(fileURLWithPath: "/tmp/ycode-fake-\(generation)-\($0)@2x.png") }
        return .success(PreviewCanvasOutcome(pictures: pics, sizes: request.tiles.map(\.size), decision: "reload payload", compile: 0.01, render: 0.01))
    }

    func stop() { lock.withLock { stopped = true } }
    var count: Int { lock.withLock { requests.count } }
    var last: PreviewCanvasRequest? { lock.withLock { requests.last } }
}

@MainActor
@Suite struct PreviewCanvasShellTests {
    static let card = """
    import SwiftUI

    struct Card: View {
        var title: String
        var body: some View { Text(title).padding() }
    }

    #Preview {
        Card(title: "One")
    }

    #Preview("Compact", traits: .sizeThatFitsLayout) {
        Card(title: "Two")
    }

    #Preview("Fixed", traits: .fixedLayout(width: 320, height: 200)) {
        Card(title: "Three")
    }

    """

    func canvas(_ engine: FakePreviewEngine, simulator: FakePreviewEngine? = nil) -> PreviewCanvasShellModel {
        let c = PreviewCanvasShellModel()
        c.makeEngine = { engine }
        c.makeSimulatorEngine = { simulator }
        c.locator = { PreviewModuleLocator(kind: .package, directory: URL(fileURLWithPath: "/tmp/none"), projects: [:]) }
        c.refreshDelay = 0.01
        return c
    }

    func settle(_ c: PreviewCanvasShellModel) async {
        for _ in 0..<200 {
            await c.pendingDebounce?.value
            await c.pendingUpdate?.value
            if !c.isUpdating { return }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
    }

    @Test func aFileWithPreviewsShowsThePausedCanvasAndResumeRendersTheFirstPreview() async {
        let e = FakePreviewEngine()
        let c = canvas(e)
        c.focus(path: "/p/Card.swift", text: Self.card)
        #expect(c.isShown && c.isPaused)
        #expect(c.tabTitles == ["Card", "Compact", "Fixed"])
        #expect(e.count == 0)   // nothing builds before resume
        c.resume()
        await settle(c)
        #expect(c.state == .rendered)
        #expect(c.tiles.count == 1 && c.tiles[0].isDevice && c.tiles[0].image != nil)
        // A device-sized preview is laid out on the automatic device's screen.
        #expect(e.last?.tiles.first?.size == PreviewCanvasShellModel.automaticDevice.panels[0].uprightPointSize)
        #expect(c.timings.count == 1)
    }

    @Test func aFileWithoutPreviewsHidesTheCanvas() {
        let c = canvas(FakePreviewEngine())
        c.focus(path: "/p/Card.swift", text: Self.card)
        c.focus(path: "/p/Model.swift", text: "struct Model {}\n")
        #expect(!c.isShown)
        c.focus(path: "/p/Notes.md", text: "#Preview { }")
        #expect(!c.isShown)
    }

    @Test func editsUpdateAfterThePauseAndTheNewestEditWins() async {
        let e = FakePreviewEngine()
        let c = canvas(e)
        c.focus(path: "/p/Card.swift", text: Self.card)
        c.resume()
        await settle(c)
        let before = e.count
        for i in 0..<5 { c.edited(path: "/p/Card.swift", text: Self.card.replacingOccurrences(of: "\"One\"", with: "\"One \(i)\"")) }
        await settle(c)
        // One update for the burst, with the last text.
        #expect(e.count == before + 1)
        #expect(e.last?.text.contains("\"One 4\"") == true)
        #expect(c.timings.last?.reason == "edit")
    }

    @Test func aCompileErrorShowsABannerOverTheLastPictureAndAFailureWithoutOneShowsTheCard() async {
        let e = FakePreviewEngine()
        let c = canvas(e)
        c.focus(path: "/p/Card.swift", text: Self.card)
        c.resume()
        await settle(c)
        let issue = PreviewIssue(file: URL(fileURLWithPath: "/p/Card.swift"), line: 9, message: "cannot find 'nope' in scope")
        e.failure = .compile([issue])
        c.edited(path: "/p/Card.swift", text: Self.card + "\n")
        await settle(c)
        #expect(c.state == .rendered)
        #expect(c.banner?.title == "Compiling the preview failed")
        #expect(c.banner?.issues == [issue])
        #expect(c.tiles.first?.image != nil)   // the last picture stays
        var opened: (String, Int)?
        c.reveal = { opened = ($0, $1) }
        c.open(issue)
        #expect(opened?.0 == "/p/Card.swift" && opened?.1 == 9)
        // Fixed: the banner goes.
        e.failure = nil
        c.edited(path: "/p/Card.swift", text: Self.card)
        await settle(c)
        #expect(c.banner == nil)
        // Another file that fails before any picture: the error card.
        e.failure = .host("The preview host failed to start")
        c.focus(path: "/p/Other.swift", text: Self.card)
        await settle(c)
        guard case .failed(let title, let message, _) = c.state else { Issue.record("\(c.state)"); return }
        #expect(title == "Preview build failed" && message.contains("failed to start"))
    }

    @Test func uikitPreviewsNeedASimulatorHostAndUseItWhenThereIsOne() async {
        let uikit = """
        import UIKit

        #Preview { UILabel() }
        """
        #expect(PreviewCanvasShellModel.needsSimulator(text: uikit, previews: PreviewDiscovery.previews(in: uikit)))
        let body = "import SwiftUI\n#Preview { let c = UIViewController(); return c }\n"
        #expect(PreviewCanvasShellModel.needsSimulator(text: body, previews: PreviewDiscovery.previews(in: body)))
        #expect(!PreviewCanvasShellModel.needsSimulator(text: Self.card, previews: PreviewDiscovery.previews(in: Self.card)))
        // A comment naming UIKit does not count.
        let commented = "// import UIKit\n" + Self.card
        #expect(!PreviewCanvasShellModel.needsSimulator(text: commented, previews: PreviewDiscovery.previews(in: commented)))

        let e = FakePreviewEngine()
        let c = canvas(e)
        c.focus(path: "/p/Badge.swift", text: uikit)
        c.resume()
        await settle(c)
        #expect(c.state == .needsSimulator(title: PreviewCanvasShellModel.needsSimulatorTitle, message: PreviewCanvasShellModel.needsSimulatorMessage))
        #expect(c.statusText == "Needs a simulator host")
        #expect(e.count == 0)
        // With a simulator host the UIKit engine renders them.
        let s = FakePreviewEngine()
        let c2 = canvas(e, simulator: s)
        c2.focus(path: "/p/Badge.swift", text: uikit)
        c2.resume()
        await settle(c2)
        #expect(c2.state == .rendered && s.count == 1 && e.count == 0)
    }

    @Test func gridVariantsAndDevicesPlanTheTiles() async throws {
        let e = FakePreviewEngine()
        let c = canvas(e)
        c.focus(path: "/p/Card.swift", text: Self.card)
        c.resume()
        await settle(c)
        c.setMode(.grid)
        var t = c.plannedTiles()
        #expect(t.map(\.preview) == [0, 1, 2])
        #expect(t[1].requested == .zero)   // sizeThatFits: the ideal size
        #expect(t[2].requested == CGSize(width: 320, height: 200) && !t[2].isDevice)
        await settle(c)
        #expect(c.tiles.count == 3)
        c.setMode(.variants)   // Color Scheme
        t = c.plannedTiles()
        #expect(!c.isGrid && t.map(\.variant.colorScheme) == ["light", "dark"])
        #expect(t.map(\.caption) == ["Light", "Dark"])
        c.setMode(.variants)   // Orientation
        t = c.plannedTiles()
        let screen = c.screen
        #expect(t.map(\.requested) == [screen, CGSize(width: screen.height, height: screen.width)])
        c.setMode(.variants)   // Dynamic Type
        #expect(c.plannedTiles().map(\.variant.dynamicType) == PreviewVariant.dynamicTypeVariantSizes)
        c.setMode(.variants)   // off
        #expect(c.variantKind == nil && c.plannedTiles().count == 1)
        c.setSetting("Color Scheme", true)
        #expect(c.plannedTiles()[0].variant.colorScheme == "dark")
        c.chooseDevice("ipad-a16")
        let pad = try #require(PreviewCanvasShellModel.devices.first { $0.typeID == "ipad-a16" })
        #expect(c.deviceTitle == "iPad (A16)" && c.plannedTiles()[0].requested == pad.panels[0].uprightPointSize)
        c.chooseDevice(nil)
        #expect(c.deviceTitle == "Automatic – iPhone 18 Pro")
        await settle(c)
        // Every layout change was a request, none a recompile of a new text.
        #expect(Set(e.requests.map(\.text)).count == 1)
    }

    @Test func selectableRevealsThePreviewsLineAndTabsSelect() async {
        let c = canvas(FakePreviewEngine())
        c.focus(path: "/p/Card.swift", text: Self.card)
        c.resume()
        await settle(c)
        var revealed: (String, Int)?
        c.reveal = { revealed = ($0, $1) }
        c.select(2)
        await settle(c)
        #expect(c.selectedIndex == 2 && c.tiles.first?.preview == 2)
        c.tileClicked(c.tiles[0])
        #expect(revealed == nil)   // Live: clicks reach the preview
        c.setMode(.selectable)
        c.tileClicked(c.tiles[0])
        #expect(revealed?.0 == "/p/Card.swift" && revealed?.1 == c.previews[2].line)
    }

    @Test func placementFollowsTheEditorWidthUnlessChosen() {
        let c = PreviewCanvasShellModel()
        #expect(c.placement(forWidth: 1000) == .beside)
        #expect(c.placement(forWidth: 600) == .below)
        c.setLayout(.right)
        #expect(c.placement(forWidth: 600) == .beside)
        c.setLayout(.bottom)
        #expect(c.placement(forWidth: 1000) == .below)
    }

    @Test func fitArrangesTilesAtOneZoomOfAtMostOne() {
        func tile(_ id: Int, _ w: CGFloat, _ h: CGFloat) -> PreviewCanvasShellModel.Tile {
            .init(id: id, preview: id, title: "", caption: "", variant: PreviewVariant(), requested: .zero, image: nil, size: CGSize(width: w, height: h), isDevice: true)
        }
        let one = PreviewCanvasShellModel.arrange([tile(0, 402, 874)], area: CGSize(width: 500, height: 600), zoom: nil)
        #expect(one.zoom < 1 && one.zoom > 0.5)
        #expect(one.frames[0].height <= 600)
        let small = PreviewCanvasShellModel.arrange([tile(0, 100, 50)], area: CGSize(width: 500, height: 600), zoom: nil)
        #expect(small.zoom == 1)
        // Two phones in a wide canvas sit side by side.
        let two = PreviewCanvasShellModel.arrange([tile(0, 402, 874), tile(1, 402, 874)], area: CGSize(width: 1200, height: 900), zoom: nil)
        #expect(two.frames[0].minY == two.frames[1].minY && two.frames[1].minX > two.frames[0].maxX)
        // A set zoom keeps its value and wraps to fit the width.
        let zoomed = PreviewCanvasShellModel.arrange([tile(0, 402, 874), tile(1, 402, 874)], area: CGSize(width: 500, height: 900), zoom: 1)
        #expect(zoomed.zoom == 1 && zoomed.frames[1].minY > zoomed.frames[0].maxY)
    }

    @Test func canvasCommandsAreInTheEditorMenuWithCheckMarks() throws {
        for cmd in [ShellCommand.toggleCanvas, .canvasLayoutAutomatic, .canvasLayoutRight, .canvasLayoutBottom] {
            #expect(cmd.menu == "Editor")
            #expect(cmd.menuCommand != nil, "\(cmd)")
        }
        #expect(ShellCommand.toggleCanvas.menuCommand?.title == "Canvas")
        #expect(ShellCommand.canvasLayoutBottom.menuCommand?.title == "Canvas on Bottom")
        let pkg = try TempPackage()
        defer { pkg.remove() }
        let m = try WorkspaceShellModel(url: pkg.url, engine: ScriptedEngine(lines: [], issues: []))
        #expect(m.isPreviewCommandChecked(.toggleCanvas) == true)
        m.perform(.toggleCanvas)
        #expect(m.isPreviewCommandChecked(.toggleCanvas) == false)
        m.perform(.canvasLayoutBottom)
        #expect(m.isPreviewCommandChecked(.canvasLayoutBottom) == true && m.previewCanvas.layoutChoice == .bottom)
    }

    @Test func theWorkspaceSendsTheFocusedFileAndItsEditsToTheCanvas() async throws {
        let pkg = try TempPackage()
        defer { pkg.remove() }
        let file = pkg.path("Sources/DemoCore/Card.swift")
        try Self.card.write(toFile: file, atomically: true, encoding: .utf8)
        let m = try WorkspaceShellModel(url: pkg.url, engine: ScriptedEngine(lines: [], issues: []))
        m.recovery = EditorRecovery(directory: pkg.url.path + "/.recovery-test")
        let e = FakePreviewEngine()
        m.previewCanvas.makeEngine = { e }
        m.previewCanvas.refreshDelay = 0.01
        m.open(pkg.path("Sources/DemoCore/Greeting.swift"))
        #expect(!m.previewCanvas.isShown)
        m.open(file)
        #expect(m.previewCanvas.isShown && m.previewCanvas.previews.count == 3)
        m.previewCanvas.resume()
        await settle(m.previewCanvas)
        #expect(e.count == 1)
        #expect(e.last?.locator.kind == .package)
        // Typing in the editor (unsaved) reaches the canvas.
        let b = try #require(m.editor?.buffer)
        let r = (b.text as NSString).range(of: "\"One\"")
        b.replace(NSRange(location: r.location + 1, length: 3), with: "Uno")
        await settle(m.previewCanvas)
        #expect(e.count == 2 && e.last?.text.contains("\"Uno\"") == true)
        // Closing the file hides the canvas.
        m.closeCurrentDocument(discard: true)
        #expect(!m.previewCanvas.isShown)
    }

    @Test func theModuleLocatorFindsAPackageTargetsSwiftFilesOrTheFileAlone() throws {
        let pkg = try TempPackage()
        defer { pkg.remove() }
        let file = URL(fileURLWithPath: pkg.path("Sources/DemoCore/Card.swift"))
        try Self.card.write(to: file, atomically: true, encoding: .utf8)
        let loc = PreviewModuleLocator(kind: .package, directory: pkg.url, projects: [:])
        let m = loc.module(for: file)
        #expect(m.name == "DemoCore")
        #expect(Set(m.files.map(\.lastPathComponent)) == ["Card.swift", "Greeting.swift"])
        // Outside a target: the file alone, named after it.
        let loose = URL(fileURLWithPath: pkg.path("Card View.swift"))
        let alone = loc.module(for: loose)
        #expect(alone.name == "Card_View" && alone.files.isEmpty)
        #expect(OpenViewsPreviewEngine.targetFolder(of: file, package: pkg.url)?.lastPathComponent == "DemoCore")
    }

    @Test func theSimulatorPathsSetupProblemsAreACardAndItsPiecesAreStable() async {
        let uikit = "import UIKit\n#Preview { UILabel() }\n"
        let s = FakePreviewEngine()
        s.failure = .unsupported("UIKit previews compile with your own copy of the iOS Simulator SDK: set YCODE_USER_SDK")
        let c = canvas(FakePreviewEngine(), simulator: s)
        c.focus(path: "/p/Badge.swift", text: uikit)
        c.resume()
        await settle(c)
        guard case .needsSimulator(let title, let message) = c.state else { Issue.record("\(c.state)"); return }
        #expect(title == "UIKit Previews Need Setup" && message.contains("YCODE_USER_SDK"))
        #expect(s.last?.deviceTypeID == "iphone-18-pro" && s.last?.screen == c.screen)
        // The pieces: a preview device per type, regions on the screen, the viewer's script.
        #expect(SimulatorPreviewEngine.previewDevice(typeID: "iphone-18-pro") == "ycode-previews-iphone-18-pro")
        let screen = CGSize(width: 402, height: 874)
        let one = SimulatorPreviewEngine.regions([PreviewCanvasTileRequest(preview: 0, variant: PreviewVariant(), size: screen)], screen: screen)
        #expect(one.count == 1 && one[0].scale == 1 && one[0].width == 402)
        let fits = SimulatorPreviewEngine.regions([PreviewCanvasTileRequest(preview: 0, variant: PreviewVariant(), size: .zero)], screen: screen)
        #expect(fits[0].fits == true)
        let script = SimulatorPreviewEngine.shotScript(png: "/w/Shot-1.png", timeout: 900)
        #expect(script.contains("wait-live 900") && script.contains("wait-home 900") && script.contains("server-shot /w/Shot-1.png") && script.hasSuffix("quit\n"))
    }
}
