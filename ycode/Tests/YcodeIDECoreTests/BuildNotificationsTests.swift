import Foundation
import Testing
@testable import YcodeIDECore

/// `specs/ide/build-notifications.md`: the shared event decision, the
/// notices, the route and the bezel's timing.
@MainActor
@Suite struct BuildNotificationsTests {
    typealias A = WorkspaceSession.Activity

    @Test func buildActivityRaisesStartThenResult() {
        var t = BehaviorEventTracker()
        func ev(_ a: A, _ e: Bool = false, _ w: Bool = false, _ c: Int = 0) -> [Preferences.Event] {
            t.events(for: a, hasErrors: e, hasWarnings: w, consoleEntries: c)
        }
        func out(_ on: Bool) -> Preferences.Event? { t.noteConsoleOutput(targetOutput: on) }
        #expect(ev(.building("Build"), false, false) == [.buildStarts])
        // Progress texts of the same build raise nothing more.
        #expect(ev(.building("Building • 2/3"), false, false).isEmpty)
        #expect(ev(.finished("Build Succeeded"), false, false) == [.buildSucceeds])
        #expect(ev(.building("Build"), false, false) == [.buildStarts])
        #expect(ev(.finished("Build Failed"), true, false) == [.buildErrors, .buildFails])
        #expect(ev(.finished("Build Succeeded"), false, true) == [.buildWarnings, .buildSucceeds])
        #expect(ev(.finished("Clean Succeeded"), false, false) == [.buildSucceeds])
        #expect(ev(.finished("Build Cancelled"), false, false).isEmpty)
    }

    @Test func testAndRunResults() {
        var t = BehaviorEventTracker()
        func ev(_ a: A, _ e: Bool = false, _ w: Bool = false, _ c: Int = 0) -> [Preferences.Event] {
            t.events(for: a, hasErrors: e, hasWarnings: w, consoleEntries: c)
        }
        func out(_ on: Bool) -> Preferences.Event? { t.noteConsoleOutput(targetOutput: on) }
        #expect(ev(.finished("Test Succeeded"), false, false) == [.testSucceeds])
        #expect(ev(.finished("Test Completed"), false, false) == [.testSucceeds])
        #expect(ev(.finished("Test Failed"), true, false) == [.testFails])
        // A run that could not launch is not a failed build.
        #expect(ev(.finished("Run Failed"), false, false) == [.runExitsUnexpectedly])
        #expect(ev(.finished("Run failed"), false, false) == [.runExitsUnexpectedly])
        #expect(ev(.running("Running Tool"), false, false, 3) == [.runStarts])
        #expect(t.consoleEntriesAtRunStart == 3)
        #expect(ev(.running("Running Tool"), false, false).isEmpty)
        #expect(out(false) == nil)
        #expect(out(true) == .runOutput)
        #expect(out(true) == nil)
        #expect(t.runPrintedOutput)
        #expect(ev(.paused("Paused"), false, false) == [.runPauses])
        #expect(ev(.running("Running Tool"), false, false).isEmpty)
        #expect(ev(.finished("Finished running Tool"), false, false) == [.runEnds])
    }

    @Test func eventsAndDefaults() {
        let d = UserDefaults(suiteName: "ycode.build-notifications.\(UUID().uuidString)")!
        let p = Preferences(defaults: d)
        #expect(Preferences.Event.testSucceeds.category == "Testing" && Preferences.Event.buildFails.category == "Build")
        #expect(Preferences.Event.runEnds.category == "Running")
        for e in [Preferences.Event.buildSucceeds, .buildFails, .testSucceeds, .testFails] {
            #expect(p.behavior(e).actionTitles == [Preferences.notifyAction])
        }
        let n = BuildNotificationPolicy.notices(for: [.buildErrors, .buildFails], activity: .finished("Build Failed"), preferences: p)
        #expect(n == [BuildNotice(title: "Build Failed", symbolName: "hammer", outcome: .failed)])
        var b = p.behavior(.buildSucceeds)
        b.notify = false
        p.setBehavior(b, for: .buildSucceeds)
        #expect(BuildNotificationPolicy.notices(for: [.buildSucceeds], activity: .finished("Build Succeeded"), preferences: p).isEmpty)
    }

    @Test func noticeContent() {
        typealias P = BuildNotificationPolicy
        #expect(P.notice(for: .buildSucceeds, activity: "Build Succeeded").title == "Build Succeeded")
        #expect(P.notice(for: .buildSucceeds, activity: "Clean Succeeded").title == "Clean Succeeded")
        #expect(P.notice(for: .buildSucceeds, activity: nil).title == "Build Succeeded")
        #expect(P.notice(for: .buildFails, activity: "Build Failed") == BuildNotice(title: "Build Failed", symbolName: "hammer", outcome: .failed))
        #expect(P.notice(for: .testFails, activity: "Test Failed").symbolName == "xmark.circle")
        #expect(P.notice(for: .testSucceeds, activity: "Test Completed").title == "Test Completed")
        #expect(P.notice(for: .runEnds, activity: "Finished running Tool") == BuildNotice(title: "Running completes", symbolName: "play", outcome: .other))
        #expect(P.notice(for: .buildStarts, activity: nil).title == "Build starts")
    }

    @Test func routeBezelOnlyForTheFrontWindow() {
        typealias W = BuildNotificationPolicy.WindowState
        #expect(BuildNotificationPolicy.route(.frontmost) == .bezel)
        #expect(BuildNotificationPolicy.route(W(isVisible: true, isMinimized: true, isKey: true, appIsActive: true)) == .systemNotification)
        #expect(BuildNotificationPolicy.route(W(isVisible: true, isKey: false, appIsActive: true)) == .systemNotification)
        #expect(BuildNotificationPolicy.route(W(isVisible: true, isKey: true, appIsActive: false)) == .systemNotification)
        #expect(BuildNotificationPolicy.route(W(isVisible: false, isKey: false, appIsActive: true)) == .systemNotification)
    }

    @Test func bezelTimingFadeAndReplacement() {
        var t = BezelTimeline()
        let t0 = Date(timeIntervalSinceReferenceDate: 1000)
        #expect(t.phase(at: t0) == .hidden)
        let ok = BuildNotice(title: "Build Succeeded", symbolName: "hammer", outcome: .succeeded)
        let g1 = t.show(ok, at: t0, reduceMotion: false)
        #expect(t.phase(at: t0) == .shown && t.opacity(at: t0) == 1)
        #expect(t.phase(at: t0 + 1.59) == .shown)
        #expect(t.phase(at: t0 + 1.6) == .fading)
        #expect(abs(t.opacity(at: t0 + 1.6 + 0.175) - 0.5) < 1e-9)
        #expect(t.phase(at: t0 + 1.95) == .hidden && t.opacity(at: t0 + 2) == 0)
        // A second result replaces the first and restarts the time; the
        // first one's timer no longer removes anything.
        let bad = BuildNotice(title: "Build Failed", symbolName: "hammer", outcome: .failed)
        let g2 = t.show(bad, at: t0 + 1.0, reduceMotion: false)
        #expect(g2 == g1 + 1 && t.notice == bad && t.showCount == 2)
        #expect(t.phase(at: t0 + 2.0) == .shown)
        let e1 = t.expire(generation: g1)
        #expect(!e1)
        #expect(t.notice == bad)
        let e2 = t.expire(generation: g2)
        #expect(e2)
        #expect(t.notice == nil && t.phase(at: t0 + 2.0) == .hidden)
        let e3 = t.expire(generation: g2)
        #expect(!e3)
    }

    @Test func reduceMotionHasNoFade() {
        var t = BezelTimeline()
        let t0 = Date(timeIntervalSinceReferenceDate: 0)
        t.show(BuildNotice(title: "Build Failed", symbolName: "hammer", outcome: .failed), at: t0, reduceMotion: true)
        #expect(t.currentFadeDuration == 0 && t.removedAfter == BezelTimeline.visibleDuration)
        #expect(t.phase(at: t0 + 1.59) == .shown)
        #expect(t.phase(at: t0 + 1.6) == .hidden && t.opacity(at: t0 + 1.6) == 0)
    }
}
