import Foundation
import Observation
import YcodeIDECore

/// The SwiftUI shell's "Notify with bezel or system notification"
/// (`specs/ide/build-notifications.md`): the core's event decision and
/// bezel timing, with the state the bezel view reads. No toolkit types: the
/// view (`ycode-ide`) sets the window state, Reduce Motion and the system
/// notification and announcement hooks.
@MainActor
@Observable
public final class ShellBuildNotifier {
    @ObservationIgnored private var tracker = BehaviorEventTracker()
    @ObservationIgnored public private(set) var timeline = BezelTimeline()

    /// The notice the bezel shows, nil when none is.
    public private(set) var bezel: BuildNotice?
    /// The bezel is fading out (the view animates its opacity to 0).
    public private(set) var isFading = false

    /// The window is the one in front (OpenViews: scene phase active).
    @ObservationIgnored public var isWindowActive = true
    /// Accessibility ▸ Reduce Motion.
    @ObservationIgnored public var reduceMotion = false
    /// The workspace's name (the system notification's body).
    @ObservationIgnored public var workspaceName = ""
    /// Posts a system notification; nil = none available.
    @ObservationIgnored public var postSystemNotification: (@MainActor (BuildNotice, String) -> Void)?
    /// Posts an accessibility announcement.
    @ObservationIgnored public var announce: (@MainActor (String) -> Void)?
    /// The settings the behaviors come from (tests substitute their own).
    @ObservationIgnored public var preferences: () -> Preferences = { .shared }
    /// Scales the bezel's durations (tests run faster).
    @ObservationIgnored public var timeScale = 1.0

    /// Every notice, routed: "bezel <title>" or "system <title>".
    public private(set) var log: [String] = []

    public init() {}

    /// The session's activity changed (`WorkspaceShellModel`).
    public func activityChanged(_ a: WorkspaceSession.Activity, hasErrors: Bool, hasWarnings: Bool) {
        let events = tracker.events(for: a, hasErrors: hasErrors, hasWarnings: hasWarnings)
        for n in BuildNotificationPolicy.notices(for: events, activity: a, preferences: preferences()) { notify(n) }
    }

    /// Shows `n` as the bezel when the window is in front, else posts it.
    public func notify(_ n: BuildNotice) {
        let state = BuildNotificationPolicy.WindowState(isVisible: isWindowActive, isKey: isWindowActive, appIsActive: isWindowActive)
        switch BuildNotificationPolicy.route(state) {
        case .bezel: show(n)
        case .systemNotification:
            log.append("system \(n.title)")
            postSystemNotification?(n, workspaceName)
        }
    }

    private func show(_ n: BuildNotice) {
        let g = timeline.show(n, at: Date(), reduceMotion: reduceMotion)
        bezel = n
        isFading = false
        log.append("bezel \(n.title)")
        announce?(n.title)
        let t = timeline, k = timeScale
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(t.fadeStartsAfter * k * 1e9))
            guard let self, self.timeline.generation == g else { return }
            if t.currentFadeDuration > 0 {
                self.isFading = true
                try? await Task.sleep(nanoseconds: UInt64(t.currentFadeDuration * k * 1e9))
            }
            if self.timeline.expire(generation: g) {
                self.bezel = nil
                self.isFading = false
            }
        }
    }
}

extension WorkspaceShellModel {
    /// Settings ▸ Behaviors' Notify action for the activity just reported.
    func noteActivityForNotifications() {
        notifier.workspaceName = workspaceName
        let shown = session.displayedIssues
        notifier.activityChanged(activity, hasErrors: shown.contains { $0.severity == .error },
                                 hasWarnings: shown.contains { $0.severity == .warning })
    }
}
