import AppKit
import Foundation
import Testing
@testable import YcodeIDECore
@testable import YcodeUI

/// B3-WIZARD: the paged setup assistant (`liquid-glass-ycode.md` §11) of the
/// runtime and headset setup windows: the centred header, Back hidden on the
/// first step, the page dots, the column's width cap and the page change's
/// direction (a crossfade under Reduce Motion). Nothing is put on screen.
@MainActor
@Suite(.serialized) struct SetupAssistantTests {
    typealias Runner = RuntimeSetupWindowTests.Runner

    func runtimeWindow(_ name: String, size: NSSize? = nil) -> (RuntimeSetupWindowController, RuntimeSetupSession, TestDefaults) {
        _ = NSApplication.shared
        let td = TestDefaults(name)
        let s = RuntimeSetupSession(machine: SetupMachine(isMac: true, architecture: "arm64"), defaults: td.defaults, folder: "/nonexistent",
                                    localRunner: Runner(answers: []))
        let wc = RuntimeSetupWindowController(session: s)
        wc.answerConfirmation = { _ in false }
        if let size { wc.window?.setContentSize(size) }
        wc.window?.contentView?.layoutSubtreeIfNeeded()
        return (wc, s, td)
    }

    /// A view's alignment rect in window coordinates (what layout places).
    func frame(_ v: NSView) -> NSRect {
        guard let sup = v.superview else { return v.convert(v.bounds, to: nil) }
        return sup.convert(v.alignmentRect(forFrame: v.frame), to: nil)
    }

    @Test func windowIsAHelperOfTheRightSize() throws {
        let (wc, _, td) = runtimeWindow("assistant-window")
        defer { wc.window?.close(); td.remove() }
        let w = try #require(wc.window)
        #expect(w.contentLayoutRect.size == SetupAssistant.windowSize || w.contentView?.bounds.size == SetupAssistant.windowSize)
        #expect(w.contentMinSize == SetupAssistant.minimumSize)
        #expect(w.styleMask.contains(.fullSizeContentView) && w.titlebarAppearsTransparent)
        #expect(w.standardWindowButton(.closeButton)?.isHidden == false)
        #expect(w.standardWindowButton(.miniaturizeButton)?.isHidden != false && w.standardWindowButton(.zoomButton)?.isHidden != false)
    }

    /// The glyph, title and summary are centred on the window, at the spec's
    /// distances, at the default size and in a wide window.
    @Test func headerIsCentred() throws {
        for size in [SetupAssistant.windowSize, NSSize(width: 1100, height: 700)] {
            let (wc, s, td) = runtimeWindow("assistant-header", size: size)
            defer { wc.window?.close(); td.remove() }
            let root = try #require(wc.window?.contentView)
            let a = wc.assistant
            let mid = root.bounds.midX
            for v in [a.glyph, a.titleLabel, a.summaryLabel, a.dots] as [NSView] {
                #expect(abs(frame(v).midX - mid) <= 0.5, "\(v.identifier?.rawValue ?? "?") at \(frame(v)) in \(root.bounds.width)")
            }
            let top = root.bounds.maxY
            #expect(abs(top - frame(a.glyph).maxY - SetupAssistant.glyphTop) <= 0.5 && frame(a.glyph).size == NSSize(width: 64, height: 64))
            #expect(abs(frame(a.glyph).minY - frame(a.titleLabel).maxY - SetupAssistant.titleGap) <= 0.5)
            #expect(frame(a.summaryLabel).width <= SetupAssistant.summaryWidth && frame(a.summaryLabel).maxY <= frame(a.titleLabel).minY)
            #expect(frame(a.dots).minY >= frame(a.glyph).maxY, "the dots are above the glyph")
            #expect(a.titleLabel.font?.pointSize == 26 && a.summaryLabel.font?.pointSize == 13)
            #expect(a.titleLabel.stringValue == s.step.title && a.glyph.image != nil)
            #expect(a.summaryLabel.alignment == .center && a.summaryLabel.textColor == .secondaryLabelColor)
        }
    }

    /// Back is hidden (not just disabled) on the first step, and shown after it.
    @Test func backIsHiddenOnTheFirstStep() throws {
        let (wc, s, td) = runtimeWindow("assistant-back")
        defer { wc.window?.close(); td.remove() }
        #expect(s.isFirstStep && wc.backButton.isHidden)
        wc.next()
        #expect(!wc.backButton.isHidden && wc.backButton.isEnabled && wc.primaryButton.title == "Continue")
        wc.back()
        #expect(wc.backButton.isHidden)
        // The footer: Back leading, Re-check just before Continue at the trailing side, Continue the default button.
        wc.next()
        let root = try #require(wc.window?.contentView)
        root.layoutSubtreeIfNeeded()
        let a = wc.assistant
        #expect(abs(frame(a.backButton).minX - SetupAssistant.footerInset) <= 1)
        #expect(abs(root.bounds.maxX - frame(a.continueButton).maxX - SetupAssistant.footerInset) <= 1)
        #expect(abs(frame(a.footer).minY - SetupAssistant.footerInset) <= 1)
        #expect(frame(a.recheckButton).maxX <= frame(a.continueButton).minX && frame(a.recheckButton).maxX > frame(a.continueButton).minX - 12)
        #expect(a.continueButton.keyEquivalent == "\r")

        // The headset window too.
        let ht = TestDefaults("assistant-back-headset")
        defer { ht.remove() }
        let hub = DevicesController(devices: [], simulators: [])
        hub.defaults = ht.defaults
        let h = HeadsetSetupWindowController(hub: hub)
        defer { h.window?.close() }
        #expect(h.step == .viewerHost && h.backButton.isHidden && h.primaryButton.title == "Continue")
        h.next()
        #expect(!h.backButton.isHidden)
        h.show(.connect)
        #expect(h.primaryButton.title == "Finish")
        let dots = try #require(h.window?.contentView?.descendant(id: "headset-steps-panel") as? SetupPageDots)
        #expect(dots.dots.count == HeadsetSetupStep.allCases.count && dots.dots.allSatisfy { $0.dotState == .notChecked })
        dots.dots[1].performClick(nil)
        #expect(h.step == .workstation && dots.dots[1].isCurrent)
        #expect(h.assistant.glyph.image != nil && h.assistant.titleLabel.stringValue == "Workstation")
    }

    /// Every dot state has its own shape and a system colour, and its words.
    @Test func dotStatesDiffer() {
        let states: [SetupDotState] = [.ok, .missing, .unknown, .notChecked, .notApplicable]
        #expect(Set(states.map(\.title)).count == states.count)
        #expect(SetupDotState.ok.color == .systemGreen && SetupDotState.missing.color == .systemOrange && SetupDotState.unknown.color == .systemGray)
        let owner = SetupPageDots()
        // Drawn: a filled circle, a diamond (its corners filled where a circle's are not), a ring (hollow centre).
        func pixels(_ s: SetupDotState) -> (center: CGFloat, top: CGFloat) {
            let d = SetupPageDot(index: 0, target: owner, action: #selector(SetupPageDots.clicked(_:)))
            d.set(state: s, current: true, label: "")
            d.frame = NSRect(x: 0, y: 0, width: 20, height: 20)
            d.appearance = NSAppearance(named: .aqua)
            let rep = d.bitmapImageRepForCachingDisplay(in: d.bounds)!
            d.cacheDisplay(in: d.bounds, to: rep)
            let scale = CGFloat(rep.pixelsWide) / 20
            func alpha(_ x: CGFloat, _ y: CGFloat) -> CGFloat { rep.colorAt(x: Int(x * scale), y: Int(y * scale))?.alphaComponent ?? 0 }
            return (alpha(10, 10), alpha(10, 4.6))
        }
        let ok = pixels(.ok), missing = pixels(.missing), ring = pixels(.unknown)
        #expect(ok.center > 0.9 && missing.center > 0.9 && ring.center < 0.1)
        #expect(missing.top > ok.top, "the diamond's tip reaches higher than the circle")
    }

    /// The dots are clickable where the window puts them (under the title bar's area).
    @Test func dotsReceiveClicks() throws {
        let (wc, _, td) = runtimeWindow("assistant-hit")
        defer { wc.window?.close(); td.remove() }
        let w = try #require(wc.window)
        let dot = wc.assistant.dots.dots[2]
        let p = NSPoint(x: frame(dot).midX, y: frame(dot).midY)
        let frameView = try #require(w.contentView?.superview)
        var hit = frameView.hitTest(frameView.convert(p, from: nil))
        while let h = hit, h !== dot { hit = h.superview }
        #expect(hit === dot)
    }

    /// The column is at most 520 points wide, centred, and its grouped boxes run its width.
    @Test func columnWidthIsCapped() async throws {
        for (size, expected) in [(NSSize(width: 1200, height: 700), SetupAssistant.columnWidth), (SetupAssistant.minimumSize, SetupAssistant.columnWidth)] {
            let td = TestDefaults("assistant-column")
            defer { td.remove() }
            let runner = Runner(answers: [("xcrun --find simctl", RuntimeSetupWindowTests.ok("/x/simctl")),
                                          ("simctl runtime list -j", RuntimeSetupWindowTests.ok(RuntimeSetupWindowTests.images)),
                                          ("simctl list runtimes -j", RuntimeSetupWindowTests.ok("{\"runtimes\":[]}")), ("df -Pk", RuntimeSetupWindowTests.ok("209715200"))])
            let s = RuntimeSetupSession(machine: SetupMachine(isMac: true, architecture: "arm64"), defaults: td.defaults, folder: "/nonexistent", localRunner: runner)
            let wc = RuntimeSetupWindowController(session: s)
            defer { wc.window?.close() }
            wc.window?.setContentSize(size)
            await s.recheck().value
            s.show(.runtimes)
            let root = try #require(wc.window?.contentView)
            root.layoutSubtreeIfNeeded()
            let col = wc.assistant.column
            #expect(abs(frame(col).width - expected) <= 0.5, "\(size): \(frame(col).width)")
            #expect(abs(frame(col).midX - root.bounds.midX) <= 0.5, "centred on the window whether or not the scroller shows")
            let boxes = col.arrangedSubviews.compactMap { $0 as? SetupGroupBox }
            #expect(!boxes.isEmpty)
            for b in boxes { #expect(abs(b.frame.width - frame(col).width) <= 0.5) }
            // Hairlines between rows, none above the first.
            if let checks = boxes.first(where: { $0.identifier?.rawValue == "runtime-checks" }) {
                #expect(checks.separators.count == checks.rows.count - 1)
            }
        }
    }

    /// Continue pushes the new page in from the trailing edge, Back from the
    /// leading edge, a dot in its step's direction; under Reduce Motion the
    /// pages crossfade.
    @Test func pageChangeDirectionAndReduceMotion() throws {
        let (wc, s, td) = runtimeWindow("assistant-motion")
        defer { wc.window?.close(); td.remove() }
        let a = wc.assistant
        a.reduceMotionOverride = false
        func animation() -> CABasicAnimation? { a.page.layer?.animation(forKey: SetupAssistant.animationKey) as? CABasicAnimation }

        wc.next()
        var t = try #require(a.lastTransition)
        #expect(t.style == .push && t.forward && t.offset > 0 && t.offset == a.page.bounds.width)
        #expect(animation()?.keyPath == "transform.translation.x" && (animation()?.fromValue as? CGFloat) == t.offset && animation()?.duration == 0.3)
        let leaving = try #require(a.leavingPage)
        let out = leaving.layer?.animation(forKey: SetupAssistant.animationKey) as? CABasicAnimation
        #expect((out?.toValue as? CGFloat) == -t.offset)
        // The new step's content is there at once.
        #expect(a.titleLabel.stringValue == s.step.title)

        wc.back()
        t = try #require(a.lastTransition)
        #expect(t.style == .push && !t.forward && t.offset < 0 && (animation()?.fromValue as? CGFloat) == t.offset)
        #expect(a.leavingPage !== leaving && leaving.superview == nil, "a second change ends the first")

        a.dots.dots[3].performClick(nil)
        #expect(a.lastTransition?.forward == true && (a.lastTransition?.offset ?? 0) > 0)
        a.dots.dots[1].performClick(nil)
        #expect(a.lastTransition?.forward == false)

        // A refresh on the same step does not move the page.
        let before = a.lastTransition
        a.finishTransition()
        wc.refresh()
        #expect(a.leavingPage == nil && a.lastTransition == before)

        a.reduceMotionOverride = true
        wc.next()
        t = try #require(a.lastTransition)
        #expect(t.style == .crossfade && t.forward && t.offset == 0)
        #expect(animation()?.keyPath == "opacity" && (animation()?.fromValue as? CGFloat) == 0 && animation()?.duration == 0.2)
        a.finishTransition()
        #expect(a.leavingPage == nil && animation() == nil)
    }
}
