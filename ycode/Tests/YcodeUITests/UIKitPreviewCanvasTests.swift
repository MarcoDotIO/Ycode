#if os(macOS)
import AppKit
import Foundation
import Testing
@testable import YcodeIDECore
@testable import YcodeUI

private let ycodeDir = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

/// UIKit view and view-controller previews in the macOS IDE (issue #84):
/// they run on the simulator path, also from a package whose run
/// destination is the Mac; with no Ycode simulator set up the canvas says
/// what is needed instead of showing a build error.
@MainActor @Suite(.timeLimit(.minutes(10))) struct UIKitPreviewCanvasTests {
    static let badge = """
    import UIKit

    final class BadgeView: UIView {}

    #Preview("Badge") {
        BadgeView(frame: CGRect(x: 0, y: 0, width: 120, height: 48))
    }

    #Preview("Controller") {
        UIViewController()
    }

    """

    @Test func theNeedsSimulatorCardSaysWhatToSetUpAndOffersSettings() {
        let c = PreviewCanvasController()
        c.view.frame = NSRect(x: 0, y: 0, width: 600, height: 700)
        var opened = 0, refreshed = 0
        c.onOpenSimulatorSettings = { opened += 1 }
        c.onRefresh = { refreshed += 1 }
        c.setNames(["Badge", "Controller"])
        c.resume()
        c.setState(.needsSimulator("UIKit previews run on a Ycode Simulator."))
        #expect(c.statusText == "Needs a simulator")
        #expect(c.simulatorSettingsButton != nil)
        c.simulatorSettingsButton?.performClick(nil)
        #expect(opened == 1)
        #expect(refreshed == 1)   // resume
        // No error card: the header still lists the previews.
        #expect(c.headerTabs.map(\.title) == ["Badge", "Controller"])
    }

    @Test func aPackagesUIKitPreviewRunsOnTheSimulatorPathOrAsksForASimulator() throws {
        _ = NSApplication.shared
        let dir = ycodeDir.appendingPathComponent(".build-ide/previews/uikit-package")
        try? FileManager.default.removeItem(at: dir)
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("Sources/Views"), withIntermediateDirectories: true)
        try "// swift-tools-version: 5.9\nimport PackageDescription\nlet package = Package(name: \"Views\", platforms: [.iOS(.v17)], targets: [.target(name: \"Views\")])\n"
            .write(to: dir.appendingPathComponent("Package.swift"), atomically: true, encoding: .utf8)
        let file = dir.appendingPathComponent("Sources/Views/Badge.swift")
        try Self.badge.write(to: file, atomically: true, encoding: .utf8)
        try "import SwiftUI\nstruct Label: View { var body: some View { Text(\"x\") } }\n#Preview { Label() }\n"
            .write(to: dir.appendingPathComponent("Sources/Views/Label.swift"), atomically: true, encoding: .utf8)
        let wc = WorkspaceWindowController(session: WorkspaceSession(model: try WorkspaceModel(url: dir)), loadDestinations: false, startLanguageService: false)
        wc.previewWorkDirectory = ycodeDir.appendingPathComponent(".build-ide/previews/work-uikit")
        defer { PreviewRenderer.stopMacHosts() }
        wc.open(path: dir.appendingPathComponent("Sources/Views/Label.swift").path, line: nil)
        #expect(wc.previewPlatform == .macOS)
        wc.open(path: file.path, line: nil)
        #expect(wc.previewPlatform == .iOS)
        let canvas = try #require(wc.canvas)
        #expect(canvas.names == ["Badge", "Controller"])
        guard !RemoteSimulatorSettings.load(Preferences.shared.defaults).isConfigured else { return }
        canvas.resume()
        guard case .needsSimulator(let message) = canvas.state else { Issue.record("\(canvas.state)"); return }
        #expect(message.hasPrefix("UIKit previews run on a Ycode Simulator"))
        _ = try WindowSnapshotTests().render(wc.window!.contentView!.superview!, to: "preview-canvas-needs-simulator.png")
    }
}
#endif
