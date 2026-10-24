import AppKit
import Foundation
import Testing
import YcodeDebug
@testable import YcodeUI

private let ycodeDir = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

let previewSource = """
import SwiftUI

struct Badge: View {
    var text: String
    var body: some View {
        Text(text)
            .padding(12)
            .background(Color.blue)
            .foregroundStyle(.white)
    }
}

// #Preview in a comment is not a preview.
#Preview("Small", traits: .fixedLayout(width: 120, height: 60)) {
    Badge(text: "Hi")
}

#Preview {
    VStack {
        Badge(text: "One { } \\"two\\"")
        Badge(text: "Three")
    }
    .frame(width: 200, height: 140)
    .background(Color.yellow)
}

struct Badge_Previews: PreviewProvider {
    static var previews: some View { Badge(text: "Provider").frame(width: 150, height: 50) }
}
"""

/// Counts pixels that differ from the first pixel (a blank image has none).
func nonBlankPixels(_ png: URL) throws -> Int {
    let rep = try #require(NSBitmapImageRep(data: try Data(contentsOf: png)))
    let first = rep.colorAt(x: 0, y: 0)
    var n = 0
    for y in stride(from: 0, to: rep.pixelsHigh, by: 2) {
        for x in stride(from: 0, to: rep.pixelsWide, by: 2) where rep.colorAt(x: x, y: y) != first { n += 1 }
    }
    return n
}

@MainActor
@Suite(.serialized, .heavyIntegration, .timeLimit(.minutes(10))) struct PreviewTests {
    @Test func discovery() {
        let p = PreviewDiscovery.previews(in: previewSource)
        #expect(p.map(\.name) == ["Small", "Preview", "Badge_Previews"])
        #expect(p[0].fixedSize == CGSize(width: 120, height: 60) && p[1].fixedSize == nil)
        #expect(p[0].line == 14 && p[1].line == 18)
        if case .macro(let body) = p[1].kind { #expect(body.contains("Badge(text: \"Three\")") && body.contains(".background(Color.yellow)")) } else { Issue.record("kind") }
        #expect(p[2].kind == .provider(type: "Badge_Previews"))
        let blank = PreviewDiscovery.blankingPreviews(previewSource)
        #expect(!blank.contains("#Preview(") && blank.contains("struct Badge_Previews") && blank.count == previewSource.count)
    }

    func makePackage(_ name: String, source: String) throws -> URL {
        let dir = ycodeDir.appendingPathComponent(".build-ide/previews/\(name)")
        try? FileManager.default.removeItem(at: dir)
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("Sources/Views"), withIntermediateDirectories: true)
        try """
        // swift-tools-version: 5.9
        import PackageDescription
        let package = Package(name: "Views", platforms: [.macOS(.v14)], products: [.library(name: "Views", targets: ["Views"])],
                              targets: [.target(name: "Views")])

        """.write(to: dir.appendingPathComponent("Package.swift"), atomically: true, encoding: .utf8)
        try source.write(to: dir.appendingPathComponent("Sources/Views/Badge.swift"), atomically: true, encoding: .utf8)
        return dir
    }

    @Test func rendersPreviewsToPNGs() async throws {
        // Heavy work (builds, debugger, language server) takes turns across test processes.
        let heavy = await InterprocessLock.acquire(path: InterprocessLock.debuggerTestLockPath)
        defer { heavy.unlock() }
        let pkg = try makePackage("ok", source: previewSource)
        let file = pkg.appendingPathComponent("Sources/Views/Badge.swift")
        let module = try PreviewRenderer.packageModule(for: file, packageDirectory: pkg)
        #expect(module.name == "Views" && module.sources.count == 1)
        let renderer = PreviewRenderer(workDirectory: ycodeDir.appendingPathComponent(".build-ide/previews/work"))
        let out = try await offMain { try renderer.render(module: module, file: file, previews: PreviewDiscovery.previews(in: previewSource)) }
        #expect(out.map(\.name) == ["Small", "Preview", "Badge_Previews"])
        for r in out { #expect(try nonBlankPixels(r.png) > 50, "\(r.name)") }
        let small = try #require(NSBitmapImageRep(data: try Data(contentsOf: out[0].png)))
        #expect(small.size == NSSize(width: 120, height: 60))
    }

    @Test func canvasInTheWindow() async throws {
        // Heavy work (builds, debugger, language server) takes turns across test processes.
        let heavy = await InterprocessLock.acquire(path: InterprocessLock.debuggerTestLockPath)
        defer { heavy.unlock() }
        _ = NSApplication.shared
        let pkg = try makePackage("canvas", source: previewSource)
        let file = pkg.appendingPathComponent("Sources/Views/Badge.swift")
        let wc = WorkspaceWindowController(session: WorkspaceSession(model: try WorkspaceModel(url: pkg)), loadDestinations: false, startLanguageService: false)
        wc.window?.appearance = NSAppearance(named: .aqua)
        wc.applyDefaultLayout()
        wc.previewWorkDirectory = ycodeDir.appendingPathComponent(".build-ide/previews/work-canvas")
        wc.canvasRefreshDelay = 0.1
        wc.open(path: file.path, line: nil)
        wc.toggleCanvas(nil)
        let canvas = try #require(wc.canvas)
        // Paused until resumed (reference-ui-4.md §10), then building.
        #expect(canvas.isPaused && canvas.names == ["Small", "Preview", "Badge_Previews"])
        #expect(canvas.tabTitles == ["Small", "VStack", "Badge_Previews"])
        canvas.resume()
        #expect(canvas.state == .building && canvas.headerTabs.map(\.badge) == ["spinner", "spinner", "spinner"])
        await wc.previewTask?.value
        guard case .rendered(let list) = canvas.state else { Issue.record("not rendered: \(canvas.state)"); return }
        #expect(list.count == 6 && list.filter { $0.scheme == .dark }.count == 3)
        #expect(canvas.layout == .single && canvas.framedCount == 1 && canvas.headerTabs.allSatisfy { $0.badge == "eye" })
        // All previews at once, as cards.
        canvas.setMode(.grid)
        #expect(canvas.layout == .grid && canvas.cardTitles == ["Small", "Preview", "Badge_Previews"])
        _ = try WindowSnapshotTests().render(wc.window!.contentView!.superview!, to: "preview-canvas-grid.png")
        // Zoom into one; dark variant.
        canvas.select(1, zoom: true)
        #expect(canvas.layout == .single && canvas.cardTitles == ["Preview"])
        canvas.setColorScheme(.dark)
        #expect(canvas.shown.allSatisfy { $0.scheme == .dark })
        _ = try WindowSnapshotTests().render(wc.window!.contentView!.superview!, to: "preview-canvas.png")
        canvas.setColorScheme(.light)

        // A save with a broken view refreshes (debounced) into an error card.
        let tv = wc.editor.textView
        let r = (tv.string as NSString).range(of: "Text(text)")
        tv.insertText("Text(nope)", replacementRange: r)
        try wc.editor.save()
        await wc.pendingCanvasRefresh?.value
        await wc.previewTask?.value
        guard case .failed(let message) = canvas.state else { Issue.record("not failed: \(canvas.state)"); return }
        #expect(message.hasPrefix("Badge.swift:6:") && message.contains("nope"))
        #expect(canvas.statusText == "Build failed")
        _ = try WindowSnapshotTests().render(wc.window!.contentView!.superview!, to: "preview-canvas-error.png")
        wc.toggleCanvas(nil)
        #expect(wc.canvas == nil && wc.editorArea.canvas == nil)
    }

    @Test func buildErrorsAndUnsupportedTargets() async throws {
        // Heavy work (builds, debugger, language server) takes turns across test processes.
        let heavy = await InterprocessLock.acquire(path: InterprocessLock.debuggerTestLockPath)
        defer { heavy.unlock() }
        let broken = previewSource.replacingOccurrences(of: "Text(text)", with: "Text(missingName)")
        let pkg = try makePackage("broken", source: broken)
        let file = pkg.appendingPathComponent("Sources/Views/Badge.swift")
        let renderer = PreviewRenderer(workDirectory: ycodeDir.appendingPathComponent(".build-ide/previews/work-broken"))
        do {
            _ = try renderer.render(module: try PreviewRenderer.packageModule(for: file, packageDirectory: pkg), file: file,
                                    previews: PreviewDiscovery.previews(in: broken))
            Issue.record("expected a build error")
        } catch {
            #expect(error.description.hasPrefix("Badge.swift:6:") && error.description.contains("missingName"))
        }
        #expect(throws: PreviewRenderer.Failure.self) {
            try PreviewRenderer.packageModule(for: pkg.appendingPathComponent("Package.swift"), packageDirectory: pkg)
        }
    }
}
