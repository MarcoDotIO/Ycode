import AppKit
import Foundation
import Testing
@testable import YcodeIDECore
import YcodeProject
@testable import YcodeUI

/// What the public beta asks of the AppKit IDE: nothing enabled that does
/// nothing, the app's own icon and About window, Report a Bug, and unfinished
/// features labelled where they are met.
@MainActor
@Suite(.serialized) struct BetaPolishUITests {
    func window() throws -> WorkspaceWindowController {
        _ = NSApplication.shared
        let model = try WorkspaceModel(url: try WindowSnapshotTests().samplePackage())
        return WorkspaceWindowController(session: WorkspaceSession(model: model), loadDestinations: false, startLanguageService: false, openFirstFile: false)
    }

    func item(_ action: Selector) -> NSMenuItem { NSMenuItem(title: "x", action: action, keyEquivalent: "") }

    @Test func commandsWithNothingToActOnAreDisabled() throws {
        let wc = try window()
        defer { wc.window?.close() }
        let idle: [Selector] = [#selector(WorkspaceWindowController.stepOverInstruction(_:)), #selector(WorkspaceWindowController.stepIntoInstruction(_:)),
                                #selector(WorkspaceWindowController.detachDebugger(_:)), #selector(WorkspaceWindowController.jumpToProgramCounter(_:)),
                                #selector(WorkspaceWindowController.jumpToDefinition(_:) as (WorkspaceWindowController) -> (Any?) -> Void),
                                #selector(WorkspaceWindowController.jumpToOriginalSource(_:)), #selector(WorkspaceWindowController.findSelectedSymbol(_:)),
                                #selector(WorkspaceWindowController.showCallHierarchy(_:)), #selector(WorkspaceWindowController.renameSymbol(_:)),
                                #selector(WorkspaceWindowController.showCodeActions(_:)), #selector(WorkspaceWindowController.fixAllIssues(_:)),
                                #selector(WorkspaceWindowController.jumpToNextBookmark(_:)), #selector(WorkspaceWindowController.jumpToPreviousBookmarkInWorkspace(_:)),
                                #selector(WorkspaceWindowController.bookmarkLine(_:)), #selector(WorkspaceWindowController.bookmarkFile(_:)),
                                #selector(WorkspaceWindowController.jumpToLine(_:)), #selector(WorkspaceWindowController.hideFindBar(_:)),
                                #selector(WorkspaceWindowController.duplicateEditorTab(_:)), #selector(WorkspaceWindowController.openWithExternalEditor(_:)),
                                #selector(WorkspaceWindowController.openInNewTab(_:)),
                                // A package has no archive; no file, no review.
                                #selector(WorkspaceWindowController.archiveProduct(_:)), #selector(WorkspaceWindowController.toggleComparison(_:))]
        for action in idle { #expect(!wc.validateMenuItem(item(action)), "\(action)") }
    }

    @Test func aFileOpenEnablesWhatNeedsOne() throws {
        let wc = try window()
        defer { wc.window?.close() }
        let file = try #require(wc.session.model.root.allFiles.first { $0.name.hasSuffix(".swift") }?.path)
        wc.open(path: file, line: nil)
        for action in [#selector(WorkspaceWindowController.bookmarkLine(_:)), #selector(WorkspaceWindowController.jumpToLine(_:)),
                       #selector(WorkspaceWindowController.duplicateEditorTab(_:)), #selector(WorkspaceWindowController.openInNewTab(_:))] {
            #expect(wc.validateMenuItem(item(action)), "\(action)")
        }
    }

    @Test func helpMenuCommandsOpenTheRepository() throws {
        var opened: [URL] = []
        let old = AppCommands.open
        AppCommands.open = { opened.append($0) }
        defer { AppCommands.open = old }
        let bar = MainMenu.make()
        let help = try #require(bar.item(withTitle: "Help")?.submenu)
        let report = try #require(help.item(withTitle: "Report a Bug…"))
        #expect(report.target === AppCommands.shared)
        AppCommands.shared.reportBug(report)
        #expect(opened.last?.absoluteString.contains("issues/new") == true)
        #expect(opened.last?.absoluteString.contains(ProductIdentity.version) == true)
        #expect(help.item(withTitle: "Ycode Help")?.target === AppCommands.shared)
        #expect(help.item(withTitle: "Release Notes")?.target === AppCommands.shared)
        let ycode = try #require(bar.item(withTitle: "Ycode")?.submenu)
        #expect(ycode.item(withTitle: "About Ycode")?.target === AppCommands.shared)
    }

    @Test func welcomeShowsTheAppIconAndVersion() {
        _ = NSApplication.shared
        let td = TestDefaults("beta-welcome")
        defer { td.remove() }
        let w = WelcomeWindowController(recents: RecentProjects(defaults: td.defaults))
        defer { w.window?.close() }
        #expect(w.iconView.image === ProductIcon.image)
        #expect(w.versionLabel.stringValue == ProductIdentity.versionText)
    }

    @Test func iconDrawsItsColoursAtEverySize() throws {
        _ = NSApplication.shared
        for side in [16, 32, 112, 512] {
            let rep = try #require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: side, pixelsHigh: side, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                                    colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
            ProductIcon.image.draw(in: NSRect(x: 0, y: 0, width: side, height: side))
            NSGraphicsContext.restoreGraphicsState()
            // The corners are clear; the field is dark and opaque in the upper middle's edge.
            #expect(rep.colorAt(x: 0, y: 0)?.alphaComponent == 0)
            let field = try #require(rep.colorAt(x: side / 2, y: side * 15 / 100)?.usingColorSpace(.sRGB))
            #expect(field.alphaComponent > 0.9 && field.brightnessComponent < 0.5)
            // The caret is coral, low in the middle.
            let caret = try #require(rep.colorAt(x: side / 2, y: side * 67 / 100)?.usingColorSpace(.sRGB))
            #expect(caret.redComponent > 0.7 && caret.blueComponent < 0.6)
        }
    }

    @Test func aboutSaysVersionLicenseAndNotAffiliated() throws {
        _ = NSApplication.shared
        var opened: [URL] = []
        let old = AppCommands.open
        AppCommands.open = { opened.append($0) }
        defer { AppCommands.open = old }
        let a = AboutWindowController()
        defer { a.window?.close() }
        func texts(_ v: NSView) -> [String] { ((v as? NSTextField).map { [$0.stringValue] } ?? []) + v.subviews.flatMap(texts) }
        let all = texts(try #require(a.window?.contentView)).joined(separator: "\n")
        #expect(all.contains(ProductIdentity.version))
        #expect(all.contains(ProductIdentity.license))
        #expect(all.contains(ProductIdentity.notAffiliated))
        #expect(a.linkButtons.map(\.title) == ["Repository", "License", "Third-Party Notices"])
        _ = a.linkButtons[0].target?.perform(a.linkButtons[0].action, with: nil)
        #expect(opened == [ProductIdentity.repositoryURL])
    }

    @Test func destinationMenuOffersSimulatorSetupWhenThereIsNone() throws {
        let wc = try window()
        defer { wc.window?.close() }
        wc.rebuildDestinationMenu()
        let setUp = try #require(wc.destinationPopUp.menu?.item(withTitle: WorkspaceWindowController.setUpSimulatorTitle))
        #expect(setUp.subtitle == ExperimentalNotice.label)
        #expect(setUp.toolTip == ExperimentalNotice.simulator)
        #expect(setUp.target === wc)
    }

    @Test func emptyHubSaysWhatADeviceTakes() {
        _ = NSApplication.shared
        let hub = DevicesController(devices: [], simulators: [])
        _ = hub.view
        hub.refreshCanvas()
        #expect(hub.emptyCanvasMessage.contains("Linux arm64"))
        #expect(hub.canvas.stateDescription.contains("No Devices"))
    }

    @Test func simulatorsPaneIsLabelled() throws {
        _ = NSApplication.shared
        let td = TestDefaults("beta-simulators")
        defer { td.remove() }
        let pane = SimulatorsSettingsPane(prefs: Preferences(defaults: td.defaults))
        func texts(_ v: NSView) -> [String] { ((v as? NSTextField).map { [$0.stringValue] } ?? []) + v.subviews.flatMap(texts) }
        let all = texts(pane.view).joined(separator: "\n")
        #expect(all.contains("Experimental"))
        #expect(all.contains("KVM"))
        #expect(!all.contains("reference"))
    }
}
