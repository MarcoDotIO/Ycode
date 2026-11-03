import Foundation
import OVPlatform
import Testing
#if OPENVIEWS_RENAMED
@testable import OpenViewsCore
@testable import OpenViews
#else
@testable import SwiftUICore
@testable import SwiftUI
#endif

// Round R7 test support: an application host on the headless back end
// (virtual clock, synthetic events). Times are back-end seconds; the host
// launches at t = 0 and interactions start at t = 1.

/// An app whose single window shows `HarnessApp.content`.
struct HarnessApp: App {
    static var content: () -> AnyView = { AnyView(EmptyView()) }
    static var size = CGSize(width: 400, height: 400)

    var body: some Scene {
        WindowGroup { Self.content() }
            .defaultSize(Self.size)
    }
}

/// Records events in order.
@MainActor
final class EventLog {
    private(set) var entries: [String] = []
    func add(_ s: String) { entries.append(s) }
    func clear() { entries = [] }
    func count(_ s: String) -> Int { entries.filter { $0 == s }.count }
    func contains(_ s: String) -> Bool { entries.contains(s) }
}

@MainActor
final class Harness {
    let backend: HeadlessBackend
    let host: AppHost

    init<V: View>(size: CGSize = CGSize(width: 400, height: 400), scale: Double = 1, presenter: Bool = false,
                  @ViewBuilder content: @escaping () -> V) {
        backend = HeadlessBackend(scale: scale)
        HarnessApp.content = { AnyView(content()) }
        HarnessApp.size = size
        host = AppHost(HarnessApp.self, backend: backend)
        if !presenter { host.makePresenter = { _ in nil } }
        host.launch()
        host.run(until: 0.5)
    }

    var window: WindowHost { host.windows[0] }
    var windowID: PlatformWindowID { window.platform.id }
    var now: TimeInterval { backend.now }

    func run(until t: TimeInterval) { host.run(until: t) }

    func pointer(_ phase: PointerPhase, _ p: CGPoint, at t: TimeInterval, pointer: Int = 0, kind: PointerKind = .touch) {
        backend.post(.pointer(PointerEvent(window: windowID, pointer: pointer, kind: kind, phase: phase, location: p,
                                           button: 1, isPressed: phase == .down || phase == .moved, timestamp: t)), at: t)
    }

    func hover(_ p: CGPoint, at t: TimeInterval) {
        backend.post(.pointer(PointerEvent(window: windowID, kind: .mouse, phase: .moved, location: p, button: 0,
                                           isPressed: false, timestamp: t)), at: t)
    }

    /// A press and release `duration` apart; runs until the release.
    func tap(_ p: CGPoint, at t: TimeInterval, duration: TimeInterval = 0.05) {
        pointer(.down, p, at: t)
        pointer(.up, p, at: t + duration)
        run(until: t + duration)
    }

    /// A drag of `steps` moves of `delta` every `interval` seconds, released
    /// at the last point one interval later; runs until the release.
    @discardableResult
    func drag(from p: CGPoint, delta: CGSize, steps: Int, interval: TimeInterval = 1.0 / 60, at t: TimeInterval) -> TimeInterval {
        pointer(.down, p, at: t)
        var q = p
        for i in 1...steps {
            q.x += delta.width
            q.y += delta.height
            pointer(.moved, q, at: t + Double(i) * interval)
        }
        let end = t + Double(steps) * interval
        pointer(.up, q, at: end)
        run(until: end)
        return end
    }

    func key(_ k: Key, modifiers: KeyModifiers = [], at t: TimeInterval) {
        backend.post(.key(KeyEvent(window: windowID, key: k, modifiers: modifiers, timestamp: t)), at: t)
        run(until: t)
    }

    /// Types `text`: a key press and the committed text per character.
    func type(_ text: String, at t: TimeInterval, interval: TimeInterval = 0.05) {
        var time = t
        for c in text {
            backend.post(.key(KeyEvent(window: windowID, key: .character(Character(c.lowercased())), timestamp: time)),
                         at: time)
            backend.post(.textInput(TextInputEvent(window: windowID, text: String(c), timestamp: time)), at: time)
            time += interval
        }
        run(until: time)
    }

    /// The window frame of the first view node whose view satisfies `match`.
    func frame(where match: (any View) -> Bool) -> CGRect? {
        var out: CGRect?
        window.graph.root?.forEachNode { n in
            if out == nil, match(n.view) { out = HitTesting.frame(of: n, mirrorWidth: nil) }
        }
        return out
    }

    func frame(of color: Color) -> CGRect? { frame { ($0 as? Color) == color } }
}

extension CGRect {
    var center: CGPoint { CGPoint(x: midX, y: midY) }
}
