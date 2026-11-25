import AppKit
import Foundation
import Testing
import YcodeDebug
@testable import YcodeIDECore
@testable import YcodeUI

private let ycodeDir = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

/// B5-EDITOR2 (1.0.0-beta.5): P-054, P-066 of `specs/ide/parity-inventory.md`.
/// Windows stay off every display (the offscreen guard).
@MainActor
@Suite(.serialized) struct Beta5EditorTests {
    static let shots = ycodeDir.appendingPathComponent(".build-ide/b5-shots")

    func window(_ name: String = "B5Editor", dark: Bool = false) throws -> (WorkspaceWindowController, URL) {
        _ = NSApplication.shared
        let dir = try WindowSnapshotTests().samplePackage(directory: name)
        let wc = WorkspaceWindowController(session: WorkspaceSession(model: try WorkspaceModel(url: dir)), loadDestinations: false,
                                           startLanguageService: false)
        wc.window?.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        wc.applyDefaultLayout()
        wc.window?.setFrame(NSRect(x: -6000, y: -6000, width: 1400, height: 880), display: true)
        return (wc, dir.appendingPathComponent("Sources/Sample/main.swift"))
    }

    func shot(_ wc: WorkspaceWindowController, _ name: String) {
        try? FileManager.default.createDirectory(at: Self.shots, withIntermediateDirectories: true)
        guard let v = wc.window?.contentView?.superview, let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) else { return }
        v.cacheDisplay(in: v.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: Self.shots.appendingPathComponent(name))
    }

    func settle(_ wc: WorkspaceWindowController) {
        wc.window?.contentView?.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        wc.window?.contentView?.layoutSubtreeIfNeeded()
    }

    func width(_ e: SourceEditorController, in wc: WorkspaceWindowController) -> CGFloat { e.view.frame.width }

    /// P-066: File ▸ Close "<file>" in a split empties only the focused
    /// pane, which keeps its half of the split and shows "No Editor"; the
    /// assistant with no counterpart takes half the editor area too. A pane
    /// left alone shows the lone editor's start page again.
    @Test func closeEditorInASplitShowsNoEditor() throws {
        let (wc, main) = try window()
        wc.open(path: main.path, line: nil)
        settle(wc)
        let area = wc.editorArea.view.frame.width
        wc.toggleAssistant(nil)
        settle(wc)
        let a = try #require(wc.editorArea.tab.assistant)
        #expect(a.noEditorPlaceholder?.label.stringValue == "No Editor")
        #expect(abs(width(a, in: wc) - area / 2) <= 1.5, "\(width(a, in: wc)) of \(area)")
        shot(wc, "mac-p066-assistant.png")
        wc.toggleAssistant(nil)

        wc.splitEditor(nil)
        settle(wc)
        let tab = wc.editorArea.tab
        #expect(tab.editors.count == 2 && tab.focused == 1)
        wc.closeDocument(nil)
        settle(wc)
        let emptied = tab.editors[1], other = tab.editors[0]
        #expect(tab.editors.count == 2, "the pane stays")
        #expect(emptied.fileURL == nil && emptied.noEditorPlaceholder?.label.stringValue == "No Editor" && emptied.emptyView == nil)
        #expect(other.fileURL?.lastPathComponent == "main.swift" && other.noEditorPlaceholder == nil)
        #expect(tab.editors.allSatisfy { abs(width($0, in: wc) - area / 2) <= 1.5 }, "\(tab.editors.map { width($0, in: wc) })")
        let label = try #require(emptied.noEditorPlaceholder?.label)
        let centre = label.convert(NSPoint(x: label.bounds.midX, y: label.bounds.midY), to: emptied.view)
        #expect(abs(centre.x - emptied.view.bounds.midX) <= 1)
        shot(wc, "mac-p066-close-in-split.png")

        // The other pane closed: the lone editor's start page.
        wc.editorArea.closePane(other)
        settle(wc)
        #expect(tab.editors.count == 1 && tab.editors[0].noEditorPlaceholder == nil && tab.editors[0].emptyView != nil)
    }

    static let docSample = """
    import Foundation

    /// Counts taps on the screen.
    /// - Returns: the number of taps.
    struct Counter {
        // A plain comment stays monospaced.
        var value = 0
    }

    """

    /// P-054: the text after `///` in the proportional system face at the
    /// source size, its `///` and plain comments in the source font; the
    /// comment grey in light and dark.
    @Test(arguments: [false, true]) func docCommentsProportional(dark: Bool) throws {
        let (wc, main) = try window("B5DocComment", dark: dark)
        let file = main.deletingLastPathComponent().appendingPathComponent("Counter.swift")
        try Self.docSample.write(to: file, atomically: true, encoding: .utf8)
        wc.open(path: file.path, line: nil)
        settle(wc)
        let storage = try #require(wc.editor.textView.textStorage)
        let ns = storage.string as NSString
        func font(_ s: String, offset: Int = 0) -> NSFont? {
            let r = ns.range(of: s)
            return r.location == NSNotFound ? nil : storage.attribute(.font, at: r.location + offset, effectiveRange: nil) as? NSFont
        }
        let text = try #require(font("Counts taps"))
        let delimiter = try #require(font("/// Counts"))
        let code = try #require(font("struct Counter"))
        let plain = try #require(font("A plain comment"))
        #expect(!text.isFixedPitch && text.pointSize == code.pointSize, "\(text)")
        #expect(text.familyName == NSFont.systemFont(ofSize: 13).familyName)
        #expect(delimiter.isFixedPitch && plain.isFixedPitch && code.isFixedPitch)
        #expect(font("- Returns").map { !$0.isFixedPitch } == true)
        func rgb(_ s: String) -> String? {
            var out: String?
            wc.window?.effectiveAppearance.performAsCurrentDrawingAppearance {
                let c = (storage.attribute(.foregroundColor, at: ns.range(of: s).location, effectiveRange: nil) as? NSColor)?.usingColorSpace(.sRGB)
                out = c.map { String(format: "%.3f %.3f %.3f", $0.redComponent, $0.greenComponent, $0.blueComponent) }
            }
            return out
        }
        #expect(rgb("Counts taps") != nil && rgb("Counts taps") == rgb("A plain comment"))
        // The line keeps the 18-point pitch.
        #expect(Theme.lineHeight == 18)
        shot(wc, "mac-p054-doc-comments-\(dark ? "dark" : "light").png")
    }

    /// P-167 (one attempt, as the inventory row): while a preview builds
    /// and renders, no process Ycode starts becomes an application that can
    /// take the key window (the workspace "turned inactive with no input").
    /// Observed without bringing anything forward: new running applications
    /// and activations during the canvas's build.
    @Test(.timeLimit(.minutes(5))) func previewBuildActivatesNoOtherApp() async throws {
        let heavy = await InterprocessLock.acquire(path: InterprocessLock.debuggerTestLockPath)
        defer { heavy.unlock() }
        _ = NSApplication.shared
        let pkg = try PreviewTests().makePackage("b5-focus", source: previewSource)
        let file = pkg.appendingPathComponent("Sources/Views/Badge.swift")
        let wc = WorkspaceWindowController(session: WorkspaceSession(model: try WorkspaceModel(url: pkg)), loadDestinations: false, startLanguageService: false)
        wc.applyDefaultLayout()
        wc.previewWorkDirectory = ycodeDir.appendingPathComponent(".build-ide/previews/work-b5-focus")
        defer { PreviewRenderer.stopMacHosts() }
        let before = Set(NSWorkspace.shared.runningApplications.map(\.processIdentifier))
        let me = ProcessInfo.processInfo.processIdentifier
        final class Seen: @unchecked Sendable { var activated: [String] = [] }
        let seen = Seen()
        let token = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { n in
            let app = n.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            if let app, !before.contains(app.processIdentifier), app.executableURL?.path.contains(".build-ide") == true { seen.activated.append(app.executableURL?.lastPathComponent ?? "\(app.processIdentifier)") }
        }
        defer { NSWorkspace.shared.notificationCenter.removeObserver(token) }
        wc.open(path: file.path, line: nil)
        let canvas = try #require(wc.canvas)
        canvas.resume()
        await wc.previewTask?.value
        // Every application that appeared during the build, with its policy.
        // (Only Ycode's own: other applications the user starts meanwhile do not count.)
        let ours = [ycodeDir.path, URL(fileURLWithPath: NSTemporaryDirectory()).resolvingSymlinksInPath().path, NSTemporaryDirectory()]
        let started = NSWorkspace.shared.runningApplications.filter { a in
            guard !before.contains(a.processIdentifier), a.processIdentifier != me, let path = a.executableURL?.resolvingSymlinksInPath().path else { return false }
            return ours.contains { path.hasPrefix($0) }
        }
        let activatable = started.filter { $0.activationPolicy != .prohibited }.map { $0.executableURL?.path ?? "\($0.processIdentifier)" }
        #expect(activatable.isEmpty, "\(activatable)")
        #expect(seen.activated.isEmpty, "\(seen.activated)")
        if case .rendered = canvas.state {} else { Issue.record("not rendered: \(canvas.state)") }
    }
}
