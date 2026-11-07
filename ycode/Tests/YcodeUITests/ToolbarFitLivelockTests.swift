import AppKit
import Foundation
import Testing
@testable import YcodeIDECore
@testable import YcodeUI

/// The toolbar fit settles (`liquid-glass.md` §8.2, `reference-ui-6.md`
/// §2.2): once the window stops changing, the fit stops running. A fit
/// whose own steps fire the notifications that schedule the next fit (the
/// issue capsule's parts, the activity view's natural width, the split
/// view's resize) must not refit forever, one turn of the run loop at a
/// time (B6: the main thread at 100 % in `fitToolbar()` after a split
/// editor, a narrow-and-back resize and another window in front).
@MainActor
@Suite(.serialized) struct ToolbarFitLivelockTests {
    /// Lets the main queue run, as the application's run loop does: the
    /// fits `scheduleToolbarFit()` queues run only while the test is
    /// suspended (a nested `RunLoop.run` inside the test's own main-queue
    /// job never drains the main queue).
    func spin(_ seconds: Double) async {
        try? await Task.sleep(nanoseconds: UInt64(seconds * 1e9))
    }

    /// Fits that run in `seconds` of an idle run loop.
    func idleFits(_ wc: WorkspaceWindowController, _ seconds: Double = 0.5) async -> Int {
        let runs = wc.toolbarControls.fitRuns
        await spin(seconds)
        return wc.toolbarControls.fitRuns - runs
    }

    func window(_ tag: String) async throws -> WorkspaceWindowController {
        let (wc, _) = try CouncilRound5ChromeTests().longWindow("livelock-\(tag)")
        await spin(0.3)
        return wc
    }

    /// A narrow window keeps the glyphs-only step; with nothing changing
    /// the fit runs no more.
    @Test(arguments: [false, true])
    func aNarrowWindowSettles(_ withIssues: Bool) async throws {
        let wc = try await window("narrow-\(withIssues)")
        defer { wc.window?.orderOut(nil) }
        let w = try #require(wc.window)
        if withIssues { wc.issueCapsule.warnings = 1 }
        w.setFrame(NSRect(x: -6000, y: -6000, width: 1100, height: 880), display: true)
        await spin(0.3)
        #expect(wc.toolbarFit.schemeGlyphsOnly)
        let fits = await idleFits(wc)
        print("B6LIVELOCK narrow issues=\(withIssues): \(fits) fits in 0.5 s idle, fit \(wc.toolbarFit)")
        #expect(fits <= 1, "the toolbar fit keeps running in an idle narrow window: \(fits) fits in 0.5 s")
        #expect(wc.toolbarFit.schemeGlyphsOnly && wc.schemeShowsGlyphsOnly && wc.issueCapsule.symbolsOnly)
        // A wider window still undoes the steps.
        w.setFrame(NSRect(x: -6000, y: -6000, width: 1400, height: 880), display: true)
        await spin(0.3)
        #expect(!wc.toolbarFit.schemeGlyphsOnly && !wc.schemeShowsGlyphsOnly && !wc.issueCapsule.symbolsOnly)
        let wideFits = await idleFits(wc)
        #expect(wideFits <= 1)
    }

    /// Changes from outside the fit still refit: new issue counts, a new
    /// activity subtitle (truncated in steps in a narrower window), and
    /// the fit settles again after each.
    @Test func outsideChangesStillRefitAndSettle() async throws {
        let wc = try await window("outside")
        defer {
            wc.session.isPreparingEditorServices = false
            wc.window?.orderOut(nil)
        }
        let w = try #require(wc.window)
        w.setFrame(NSRect(x: -6000, y: -6000, width: 1100, height: 880), display: true)
        await spin(0.3)
        var runs = wc.toolbarControls.fitRuns
        wc.issueCapsule.errors = 2
        await spin(0.3)
        #expect(wc.toolbarControls.fitRuns > runs, "new issue counts refit the toolbar")
        #expect(wc.issueCapsule.symbolsOnly && !wc.issueCapsule.isHidden)
        var fits = await idleFits(wc)
        #expect(fits <= 1, "after the issue counts: \(fits) fits in 0.5 s")
        runs = wc.toolbarControls.fitRuns
        wc.session.isPreparingEditorServices = true
        w.setFrame(NSRect(x: -6000, y: -6000, width: 960, height: 880), display: true)
        await spin(0.3)
        #expect(wc.toolbarControls.fitRuns > runs)
        fits = await idleFits(wc)
        print("B6LIVELOCK activity: \(fits) fits in 0.5 s idle, fit \(wc.toolbarFit), natural \(wc.activityView.naturalWidth)")
        #expect(fits <= 1, "with the activity subtitle: \(fits) fits in 0.5 s")
    }

    /// The observed sequence: two editors, narrowed to 1100 and back,
    /// another window brought in front (the Welcome and Settings windows).
    @Test func theCaptureSequenceSettles() async throws {
        let wc = try await window("sequence")
        defer { wc.window?.orderOut(nil) }
        let w = try #require(wc.window)
        wc.issueCapsule.warnings = 1
        wc.splitEditor(nil)
        await spin(0.3)
        w.setFrame(NSRect(x: -6000, y: -6000, width: 1100, height: 880), display: true)
        await spin(0.3)
        w.setFrame(NSRect(x: -6000, y: -6000, width: 1400, height: 880), display: true)
        await spin(0.3)
        let other = NSWindow(contentRect: NSRect(x: -9000, y: -9000, width: 700, height: 500), styleMask: [.titled, .closable],
                             backing: .buffered, defer: false)
        other.isReleasedWhenClosed = false
        other.isExcludedFromWindowsMenu = true
        defer { other.orderOut(nil) }
        other.makeKeyAndOrderFront(nil)
        await spin(0.3)
        let fits = await idleFits(wc)
        print("B6LIVELOCK sequence: \(fits) fits in 0.5 s idle, fit \(wc.toolbarFit), key \(w.isKeyWindow)")
        #expect(fits <= 1, "the toolbar fit keeps running: \(fits) fits in 0.5 s")
    }
}
