import AppKit
import Foundation
import Testing
@testable import YcodeIDECore
import YcodeProject
@testable import YcodeUI

private let ycodeDir = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

/// Beta 4 workflow fixes in the project editor (parity inventory P-098,
/// P-100). Windows are ordered in only under the offscreen guard
/// (`CYcodeTestOffscreen`), so nothing reaches a display.
@MainActor
@Suite(.serialized) struct WorkflowsProjectEditorB4Tests {
    func hostedEditor() throws -> (NSWindow, ProjectEditorController) {
        _ = NSApplication.shared
        let pe = ProjectEditorController(model: try ProjectEditorFixture().model())
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 600), styleMask: [.titled, .closable, .resizable],
                         backing: .buffered, defer: false)
        w.isReleasedWhenClosed = false
        w.contentViewController = pe
        w.orderFront(nil)
        pe.select(target: "App", tab: .signing)
        return (w, pe)
    }

    /// The library's panel, while it is shown.
    func libraryPanel(_ w: NSWindow) -> CapabilityLibraryPanel? {
        w.childWindows?.compactMap { $0 as? CapabilityLibraryPanel }.first { $0.isVisible }
    }

    // MARK: P-098: the capability library can be closed

    @Test func escapeClosesTheCapabilityLibraryWithoutAdding() throws {
        let (w, pe) = try hostedEditor()
        defer { w.orderOut(nil) }
        let before = pe.model.capabilities(target: "App", configuration: "Debug")
        let lib = pe.capabilityLibrary()
        let panel = try #require(libraryPanel(w), "the library is a panel over the window, not a sheet")
        #expect(w.attachedSheet == nil)
        WorkflowsB4Shots.save(window: panel, "mac-p098-capability-library")
        // Escape in the filter field (where the panel puts the keyboard).
        let field = try #require(panel.fieldEditor(false, for: lib.searchField) as? NSTextView ?? lib.searchField.currentEditor() as? NSTextView)
        #expect(lib.control(lib.searchField, textView: field, doCommandBy: #selector(NSResponder.cancelOperation(_:))))
        #expect(!panel.isVisible && libraryPanel(w) == nil)
        #expect(pe.model.capabilities(target: "App", configuration: "Debug") == before)
        // ⌘. and Escape anywhere else in the panel reach cancelOperation.
        _ = pe.capabilityLibrary()
        let again = try #require(libraryPanel(w))
        again.cancelOperation(nil)
        #expect(!again.isVisible)
    }

    @Test func aClickOutsideClosesTheLibrary() throws {
        let (w, pe) = try hostedEditor()
        defer { w.orderOut(nil) }
        _ = pe.capabilityLibrary()
        let panel = try #require(libraryPanel(w))
        // Another window takes the keyboard: the panel resigns key and closes.
        panel.resignKey()
        #expect(!panel.isVisible && libraryPanel(w) == nil)
    }

    @Test func aRowDoubleClickAddsThatCapability() throws {
        let (w, pe) = try hostedEditor()
        defer { w.orderOut(nil) }
        let lib = pe.capabilityLibrary()
        let panel = try #require(libraryPanel(w))
        let row = try #require(lib.items.firstIndex(of: .hardenedRuntime))
        lib.table.selectRowIndexes([row], byExtendingSelection: false)
        _ = lib.table.target?.perform(lib.table.doubleAction, with: lib.table)
        #expect(pe.model.capabilities(target: "App", configuration: "Debug").contains(.hardenedRuntime))
        #expect(!panel.isVisible)
    }

    // MARK: P-100: Build Settings keeps the window's width

    func copyHello() throws -> URL {
        let dir = ycodeDir.appendingPathComponent(".build-ide/b4-workflows-project-editor")
        try? FileManager.default.removeItem(at: dir)
        let proj = dir.appendingPathComponent("Hello.xcodeproj")
        try FileManager.default.createDirectory(at: proj, withIntermediateDirectories: true)
        let src = ycodeDir.appendingPathComponent("Tests/YcodeProjectTests/Fixtures/Hello.xcodeproj/project.pbxproj")
        try FileManager.default.copyItem(at: src, to: proj.appendingPathComponent("project.pbxproj"))
        return proj
    }

    @Test func everyTabKeepsTheWindowWidthAndAllowsResizingBack() throws {
        _ = NSApplication.shared
        let projURL = try copyHello()
        let wc = WorkspaceWindowController(session: WorkspaceSession(model: try WorkspaceModel(url: projURL)),
                                           loadDestinations: false, startLanguageService: false)
        let window = try #require(wc.window)
        defer { window.orderOut(nil) }
        window.setFrame(NSRect(x: 0, y: 0, width: 1400, height: 880), display: false)
        wc.applyDefaultLayout()
        window.orderFront(nil)
        wc.open(path: projURL.path, line: nil)
        let pe = try #require(wc.projectEditor)
        pe.select(target: "Hello", tab: .general)
        window.layoutIfNeeded()
        // The narrowest the window can be with General shown: no tab may
        // need more.
        func narrowest() -> CGFloat {
            window.setFrame(NSRect(x: 0, y: 0, width: 900, height: 880), display: false)
            window.layoutIfNeeded()
            let w = window.frame.width
            window.setFrame(NSRect(x: 0, y: 0, width: 1400, height: 880), display: false)
            window.layoutIfNeeded()
            return w
        }
        let baseline = narrowest()
        for tab in ProjectEditorController.tabs(forTarget: true) {
            pe.select(tab: tab)
            window.layoutIfNeeded()
            #expect(window.frame.width == 1400, "\(tab.rawValue) widened the window to \(window.frame.width)")
            let minimum = narrowest()
            #expect(minimum <= baseline, "\(tab.rawValue) needs \(minimum) points, General \(baseline)")
            window.setFrame(NSRect(x: 0, y: 0, width: 1500, height: 880), display: false)
            window.layoutIfNeeded()
            window.setFrame(NSRect(x: 0, y: 0, width: 1400, height: 880), display: false)
            window.layoutIfNeeded()
            #expect(window.frame.width == 1400, "\(tab.rawValue) refused the resize back to 1400")
        }
        pe.select(tab: .buildSettings)
        window.layoutIfNeeded()
        WorkflowsB4Shots.save(window: window, "mac-p100-build-settings-1400")
    }
}
