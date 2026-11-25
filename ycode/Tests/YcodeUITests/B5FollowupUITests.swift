import AppKit
import Foundation
import QuartzCore
import Testing
@testable import YcodeIDECore
@testable import YcodeUI

/// B5-FOLLOWUP on macOS (offscreen): selecting a file draws it before the
/// parser pass and eases the editor over (P-199).
@MainActor
@Suite(.serialized) struct B5FollowupUITests {
    typealias Ops = ProjectNavigatorOperationsTests

    func pump(_ seconds: Double) { RunLoop.main.run(until: Date().addingTimeInterval(seconds)) }

    /// The whole window, toolbar included, to `.build-ide/b5-shots/followup-<name>.png`
    /// (offscreen: the glass and materials do not draw).
    func shot(_ w: NSWindow, _ name: String) {
        guard let v = w.contentView?.superview else { return }
        try? FileManager.default.createDirectory(at: B5NavigatorTests.shots, withIntermediateDirectories: true)
        v.layoutSubtreeIfNeeded()
        guard let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) else { return }
        v.cacheDisplay(in: v.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: B5NavigatorTests.shots.appendingPathComponent("followup-\(name).png"))
    }

    static let longSwift: String = (0..<400).map { "func f\($0)() -> Int { let x = \($0); return x * 2 }\n" }.joined()

    // MARK: P-199 — the file draws first, then the parser colours it

    /// Opening a 400-line Swift file no longer runs the parser before the
    /// first frame: the text has the lexer's colours at once (no uncoloured
    /// frame), the parser pass follows on the run loop. Prints the open's
    /// time against the synchronous pass's (the "before").
    @Test func openingDrawsBeforeTheParserPass() throws {
        let s = try Ops.Sample()
        defer { s.remove() }
        let wc = try s.window()
        try Self.longSwift.write(toFile: s.path("Nav/Helpers.swift"), atomically: true, encoding: .utf8)
        func timed(_ p: String) -> Double {
            let t0 = ProcessInfo.processInfo.systemUptime
            wc.openFromNavigator(path: s.path(p), line: nil, modifiers: [])
            wc.window?.contentView?.layoutSubtreeIfNeeded()
            wc.window?.displayIfNeeded()
            return (ProcessInfo.processInfo.systemUptime - t0) * 1000
        }
        _ = timed("Nav/main.swift")   // warm
        pump(0.1)
        var deferred: [Double] = []
        for _ in 0..<3 {
            deferred.append(timed("Nav/Helpers.swift"))
            // Drawn with the lexer's colours, not parsed yet.
            let doc = try #require(wc.editor.syntax.document)
            #expect(!doc.hasParsed)
            let storage = try #require(wc.editor.textView.textStorage)
            let keyword = storage.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor
            #expect(keyword != nil && keyword != Theme.textColor, "\(String(describing: keyword))")
            // The parser pass follows on its own.
            let end = Date().addingTimeInterval(5)
            while !(wc.editor.syntax.document?.hasParsed ?? false), Date() < end { pump(0.02) }
            #expect(wc.editor.syntax.document?.hasParsed == true)
            _ = timed("Nav/Model.swift")
            pump(0.1)
        }
        // The synchronous pass the open used to run (the "before").
        let t0 = ProcessInfo.processInfo.systemUptime
        wc.editor.textView.string = Self.longSwift
        wc.editor.resetSyntax()
        let syntax = (ProcessInfo.processInfo.systemUptime - t0) * 1000
        print("P-199 400-line open+layout+display ms, parser deferred: \(deferred.map { Int($0) }); the synchronous pass alone: \(Int(syntax))")
        #expect(deferred.min()! < syntax + 150)
    }

    // MARK: P-199 — the ease

    /// Selecting another file cross-fades the text area on the catalogue's
    /// curve: ≈ 95 ms, starting ≈ 36 ms after the press (+93 less Ycode's
    /// input latency), or at once when the open took longer than that.
    /// With Reduce Motion there is none. The test sets Reduce Motion itself:
    /// GitHub's macOS runner images turn it on (`configure-system.sh`), so
    /// the host's setting gave no ease there.
    @Test func selectingAnotherFileEasesTheEditor() throws {
        let s = try Ops.Sample()
        defer { s.remove() }
        defer { WorkspaceWindowController.fileSelectionEaseReducesMotion = nil }
        let wc = try s.window()
        wc.openFromNavigator(path: s.path("Nav/main.swift"), line: nil, modifiers: [])
        pump(0.1)
        let layer = try #require(wc.editor.scrollView.layer)
        layer.removeAllAnimations()
        // What decides the ease, printed with a failure.
        func state() -> String {
            "editor file \(wc.editor.fileURL?.path ?? "none"), host Reduce Motion "
                + "\(NSWorkspace.shared.accessibilityDisplayShouldReduceMotion), override "
                + "\(String(describing: WorkspaceWindowController.fileSelectionEaseReducesMotion)), "
                + "skip: \(wc.fileSelectionEaseSkipReason(to: s.path("Nav/Model.swift"), in: wc.editor) ?? "none")"
        }
        // Reduce Motion: no ease, whatever the host's setting.
        WorkspaceWindowController.fileSelectionEaseReducesMotion = true
        #expect(wc.fileSelectionEase(to: s.path("Nav/Model.swift"), in: wc.editor) == nil, "\(state())")
        WorkspaceWindowController.fileSelectionEaseReducesMotion = false
        #expect(wc.fileSelectionEase(to: s.path("Nav/Model.swift"), in: wc.editor) != nil, "\(state())")
        wc.openFromNavigator(path: s.path("Nav/Model.swift"), line: nil, modifiers: [])
        let fade = try #require(layer.animation(forKey: WorkspaceWindowController.fileSelectionEaseKey) as? CATransition, "\(state())")
        #expect(fade.type == .fade && abs(fade.duration - 0.095) < 0.001)
        #expect(abs(Motion.fileSelectionEase.start - 0.093) < 0.001 && abs(Motion.fileSelectionEase.duration - 0.095) < 0.001)
        // The same file again: nothing to ease.
        layer.removeAllAnimations()
        wc.openFromNavigator(path: s.path("Nav/Model.swift"), line: nil, modifiers: [])
        #expect(layer.animation(forKey: WorkspaceWindowController.fileSelectionEaseKey) == nil)
        // A press just now waits for the curve's start; an old one starts at once.
        let now = ProcessInfo.processInfo.systemUptime
        let early = WorkspaceWindowController.fileSelectionFade(for: layer, press: now)
        #expect(early.beginTime > layer.convertTime(CACurrentMediaTime(), from: nil) + 0.02 && early.fillMode == .backwards)
        let late = WorkspaceWindowController.fileSelectionFade(for: layer, press: now - 0.2)
        #expect(late.beginTime == 0)
    }

    // MARK: P-024 — narrow windows, one coordinated change

    // The interim rule this tested (the navigator shrinking from 850 to
    // ≈ 140, then hiding) is withdrawn by council round 12
    // (`window-layout.md` §4.2): `B5FixLayoutUITests.liveDragCollapsesTheNavigator`.
}
