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

// T-LIFE (10-plan.md §3.2): scene-phase sequences of 06-app-and-components.md
// §1 on the headless host — launch order, deactivate/background/foreground,
// openURL (with the reference's confirmation order), termination, delegate
// adaptors, windows.

@MainActor
enum LifeLog {
    static var entries: [String] = []
    static func add(_ s: String) { entries.append(s) }
}

final class LifeDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
        LifeLog.add("delegate didFinishLaunching \(application.applicationState)")
        return true
    }
    func applicationWillEnterForeground(_ application: UIApplication) { LifeLog.add("delegate willEnterForeground") }
    func applicationDidBecomeActive(_ application: UIApplication) { LifeLog.add("delegate didBecomeActive") }
    func applicationWillResignActive(_ application: UIApplication) { LifeLog.add("delegate willResignActive") }
    func applicationDidEnterBackground(_ application: UIApplication) { LifeLog.add("delegate didEnterBackground") }
    func applicationWillTerminate(_ application: UIApplication) { LifeLog.add("delegate willTerminate") }
}

struct LifeApp: App {
    @UIApplicationDelegateAdaptor(LifeDelegate.self) var delegate
    @Environment(\.scenePhase) var phase

    init() { LifeLog.add("App.init") }

    var body: some Scene {
        // swiftlint:disable:next redundant_discardable_let - a side effect inside a view builder
        let _ = LifeLog.add("App.body \(phase)")
        WindowGroup { LifeRoot() }
            .onChange(of: phase) { old, new in LifeLog.add("App phase \(old)→\(new)") }
        Window("Inspector", id: "inspector") { Color.green }
    }
}

struct LifeRoot: View {
    @Environment(\.scenePhase) var phase
    @Environment(\.openWindow) var openWindow
    @Environment(\.dismissWindow) var dismissWindow

    var body: some View {
        let _ = LifeLog.add("root.body \(phase)")
        VStack {
            LifeChild()
            Button { openWindow(id: "inspector") } label: { Color.red.frame(width: 50, height: 50) }
            Button { dismissWindow(id: "inspector") } label: { Color.blue.frame(width: 50, height: 50) }
        }
        .onAppear { LifeLog.add("root.onAppear") }
        .onChange(of: phase) { old, new in LifeLog.add("view phase \(old)→\(new)") }
        .onOpenURL { LifeLog.add("onOpenURL \($0.absoluteString)") }
    }
}

struct LifeChild: View {
    var body: some View {
        Color.gray.frame(width: 10, height: 10).onAppear { LifeLog.add("child.onAppear") }
    }
}

final class AppKitDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) { LifeLog.add("ns didFinishLaunching") }
    func applicationDidBecomeActive(_ notification: Notification) { LifeLog.add("ns didBecomeActive") }
    func applicationWillResignActive(_ notification: Notification) { LifeLog.add("ns willResignActive") }
    func applicationWillTerminate(_ notification: Notification) { LifeLog.add("ns willTerminate") }
    func application(_ application: NSApplication, open urls: [URL]) { LifeLog.add("ns open \(urls.count)") }
}

struct AppKitStyleApp: App {
    @NSApplicationDelegateAdaptor(AppKitDelegate.self) var delegate
    var body: some Scene { WindowGroup { Color.red } }
}

@MainActor
@Suite("R7 app and scene phases (T-LIFE)", .serialized)
struct AppLifecycleTests {
    private func launch() -> (HeadlessBackend, AppHost) {
        LifeLog.entries = []
        let backend = HeadlessBackend(scale: 1)
        let host = AppHost(LifeApp.self, backend: backend)
        host.makePresenter = { _ in nil }
        host.launch()
        host.run(until: 0.2)
        return (backend, host)
    }

    @Test func launchOrderFollowsTheReference() {
        _ = launch()
        #expect(LifeLog.entries == [
            "App.init",
            "delegate didFinishLaunching background",
            "App.body background",
            "App.body inactive",
            "App phase background→inactive",
            "delegate willEnterForeground",
            "root.body inactive",
            "child.onAppear",
            "root.onAppear",
            "App.body active",
            "App phase inactive→active",
            "root.body active",
            "view phase inactive→active",
            "delegate didBecomeActive",
        ])
    }

    @Test func deactivateBackgroundAndForeground() {
        let (_, host) = launch()
        LifeLog.entries = []
        host.setAppPhase(.inactive)
        #expect(LifeLog.entries == ["delegate willResignActive", "App.body inactive", "App phase active→inactive",
                                    "root.body inactive", "view phase active→inactive"])
        LifeLog.entries = []
        host.setAppPhase(.background)
        #expect(LifeLog.entries == ["App.body background", "App phase inactive→background", "root.body background",
                                    "view phase inactive→background", "delegate didEnterBackground"])
        LifeLog.entries = []
        host.setAppPhase(.inactive)
        host.setAppPhase(.active)
        #expect(LifeLog.entries.filter { $0.hasPrefix("App phase") || $0.hasPrefix("delegate") } == [
            "App phase background→inactive", "delegate willEnterForeground",
            "App phase inactive→active", "delegate didBecomeActive",
        ])
    }

    @Test func minimisingAndRestoringTheWindow() {
        let (backend, host) = launch()
        let id = host.windows[0].platform.id
        LifeLog.entries = []
        backend.post(.window(id, .minimized), at: 1.0)
        host.run(until: 1.0)
        #expect(host.appPhase == .background)
        #expect(LifeLog.entries.filter { $0.hasPrefix("App phase") } == ["App phase active→inactive",
                                                                          "App phase inactive→background"])
        LifeLog.entries = []
        backend.post(.window(id, .restored), at: 2.0)
        host.run(until: 2.0)
        #expect(host.appPhase == .active)
        #expect(LifeLog.entries.filter { $0.hasPrefix("App phase") } == ["App phase background→inactive",
                                                                          "App phase inactive→active"])
    }

    @Test func openURLWithAndWithoutConfirmation() {
        let (backend, host) = launch()
        LifeLog.entries = []
        let url = URL(string: "ovprobe://open/1")!
        host.openURL(url, confirming: true)
        #expect(LifeLog.entries.filter { $0.hasPrefix("App phase") || $0.hasPrefix("onOpenURL") } == [
            "App phase active→inactive", "onOpenURL ovprobe://open/1", "App phase inactive→active",
        ])
        LifeLog.entries = []
        backend.post(.openURL(URL(string: "ovprobe://open/2")!), at: 1.0)
        host.run(until: 1.0)
        #expect(LifeLog.entries == ["onOpenURL ovprobe://open/2"])
    }

    @Test func quittingGoesThroughBackground() {
        let (backend, host) = launch()
        LifeLog.entries = []
        backend.post(.quit, at: 1.0)
        host.run(until: 1.0)
        #expect(host.isFinished)
        #expect(LifeLog.entries.filter { $0.hasPrefix("delegate") || $0.hasPrefix("App phase") } == [
            "delegate willResignActive", "App phase active→inactive",
            "App phase inactive→background", "delegate didEnterBackground", "delegate willTerminate",
        ])
    }

    @Test func openingAndDismissingWindows() {
        let (backend, host) = launch()
        let main = host.windows[0]
        func tap(_ c: Color, at t: Double) {
            var f: CGRect?
            main.graph.root?.forEachNode { n in if f == nil, (n.view as? Color) == c { f = HitTesting.frame(of: n, mirrorWidth: nil) } }
            guard let f else { return }
            backend.post(.pointer(PointerEvent(window: main.platform.id, kind: .touch, phase: .down, location: f.center,
                                               timestamp: t)), at: t)
            backend.post(.pointer(PointerEvent(window: main.platform.id, kind: .touch, phase: .up, location: f.center,
                                               timestamp: t + 0.05)), at: t + 0.05)
            host.run(until: t + 0.1)
        }
        tap(.red, at: 1.0)
        #expect(host.windows.count == 2)
        #expect(host.windows[1].sceneID == "inspector")
        #expect(host.windows[1].phase == .active)
        tap(.red, at: 2.0)
        #expect(host.windows.count == 2)   // a Window scene is unique
        tap(.blue, at: 3.0)
        #expect(host.windows.count == 1)
        // Closing the last window quits.
        backend.post(.window(main.platform.id, .closeRequested), at: 4.0)
        host.run(until: 4.0)
        #expect(host.windows.isEmpty)
        #expect(host.isFinished)
        #expect(LifeLog.entries.last == "delegate willTerminate")
    }

    @Test func resizingRelaysOut() {
        LifeLog.entries = []
        var sizes: [CGSize] = []
        let h = Harness(size: CGSize(width: 300, height: 200)) {
            GeometryReader { g in
                // swiftlint:disable:next redundant_discardable_let - a side effect inside a view builder
                let _ = sizes.append(g.size)
                Color.clear
            }
        }
        #expect(sizes.last == CGSize(width: 300, height: 200))
        h.backend.post(.window(h.windowID, .resized(CGSize(width: 500, height: 250))), at: 1.0)
        h.run(until: 1.1)
        #expect(sizes.last == CGSize(width: 500, height: 250))
    }

    @Test func appKitStyleDelegateAdaptor() {
        LifeLog.entries = []
        let backend = HeadlessBackend(scale: 1)
        let host = AppHost(AppKitStyleApp.self, backend: backend)
        host.makePresenter = { _ in nil }
        host.launch()
        host.openURL(URL(string: "ovprobe://x")!)
        host.terminate()
        #expect(LifeLog.entries == ["ns didFinishLaunching", "ns didBecomeActive", "ns open 1", "ns willResignActive",
                                    "ns willTerminate"])
    }
}
