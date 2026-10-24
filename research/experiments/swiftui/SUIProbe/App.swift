// SUIProbe: black-box probe of SwiftUI behaviour in the iOS simulator.
// Original Ycode research code (KIT-SWIFTUI). It uses only the public SDK.
// Each run executes one mode (launch argument `-mode <name>`) and prints
// `SUP <key>=<value>` lines to stdout. Timed lines carry `t=<seconds>` since
// App.init. A driver script (run.sh) injects input and changes device
// settings from outside; the app prints `SUP target.<name>=<x>,<y>` (ratios
// of the screen) for the places the script should touch.
import SwiftUI
import UIKit
import QuartzCore
import Darwin
import MachO

// MARK: - logging

let t0 = CACurrentMediaTime()
func elapsed() -> Double { CACurrentMediaTime() - t0 }
func log(_ k: String, _ v: Any) { print("SUP \(k)=\(v)"); fflush(stdout) }
func logt(_ k: String, _ v: Any = "") { print(String(format: "SUP t=%.3f ", elapsed()) + "\(k)=\(v)"); fflush(stdout) }
func f2(_ d: CGFloat) -> String { String(format: "%.2f", Double(d)) }
func f2(_ d: Double) -> String { String(format: "%.2f", d) }
func f4(_ d: Double) -> String { String(format: "%.4f", d) }
func sz(_ s: CGSize) -> String { "\(f2(s.width))x\(f2(s.height))" }
func rc(_ r: CGRect) -> String { "(\(f2(r.minX)),\(f2(r.minY)),\(f2(r.width)),\(f2(r.height)))" }
func ins(_ e: EdgeInsets) -> String { "t\(f2(e.top)) l\(f2(e.leading)) b\(f2(e.bottom)) r\(f2(e.trailing))" }
func after(_ s: Double, _ fn: @escaping @MainActor () -> Void) {
    DispatchQueue.main.asyncAfter(deadline: .now() + s) { MainActor.assumeIsolated { fn() } }
}
func finish() { logt("done", mode) }

let mode: String = {
    let a = ProcessInfo.processInfo.arguments
    if let i = a.firstIndex(of: "-mode"), i + 1 < a.count { return a[i + 1] }
    return "layout"
}()

/// Seconds between exec of this process and now (from the kernel's process start time).
func secondsSinceExec() -> Double {
    var info = kinfo_proc()
    var size = MemoryLayout<kinfo_proc>.stride
    var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()]
    guard sysctl(&mib, 4, &info, &size, nil, 0) == 0 else { return -1 }
    let st = info.kp_proc.p_un.__p_starttime
    var tv = timeval(); gettimeofday(&tv, nil)
    return Double(tv.tv_sec - st.tv_sec) + Double(tv.tv_usec - st.tv_usec) / 1e6
}

/// Screen-ratio coordinates of a global rect's centre (for the input driver).
func target(_ name: String, _ r: CGRect) {
    let s = UIScreen.main.bounds.size
    guard s.width > 0 else { return }
    log("target.\(name)", String(format: "%.4f,%.4f", r.midX / s.width, r.midY / s.height))
}

/// Records the latest value per key; values are printed when a case ends.
final class Rec {
    static var values: [String: String] = [:]
    static var order: [String] = []
    static func set(_ k: String, _ v: String) {
        if values[k] == nil { order.append(k) }
        values[k] = v
    }
    static func flush(prefix: String = "") {
        for k in order where k.hasPrefix(prefix) { log(k, values[k]!) }
        order.removeAll { $0.hasPrefix(prefix) }
        values = values.filter { !$0.key.hasPrefix(prefix) }
    }
}

// MARK: - app

final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        logt("delegate.didFinishLaunching", "state=\(application.applicationState.rawValue)")
        if mode == "lifecycle" || mode == "persist" { observeLifecycleNotifications() }
        if mode == "keyboard" { observeKeyboard() }
        return true
    }
}

func observeLifecycleNotifications() {
    let names: [(String, Notification.Name)] = [
        ("app.willEnterForeground", UIApplication.willEnterForegroundNotification),
        ("app.didBecomeActive", UIApplication.didBecomeActiveNotification),
        ("app.willResignActive", UIApplication.willResignActiveNotification),
        ("app.didEnterBackground", UIApplication.didEnterBackgroundNotification),
        ("app.willTerminate", UIApplication.willTerminateNotification),
        ("app.didReceiveMemoryWarning", UIApplication.didReceiveMemoryWarningNotification),
        ("scene.willConnect", UIScene.willConnectNotification),
        ("scene.didActivate", UIScene.didActivateNotification),
        ("scene.willDeactivate", UIScene.willDeactivateNotification),
        ("scene.didEnterBackground", UIScene.didEnterBackgroundNotification),
        ("scene.willEnterForeground", UIScene.willEnterForegroundNotification),
        ("scene.didDisconnect", UIScene.didDisconnectNotification),
    ]
    for (label, n) in names {
        NotificationCenter.default.addObserver(forName: n, object: nil, queue: .main) { _ in
            logt("note.\(label)", "appState=\(UIApplication.shared.applicationState.rawValue)")
        }
    }
}

@main
struct SUIProbeApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @Environment(\.scenePhase) var appPhase

    init() {
        logt("app.init", String(format: "sinceExec=%.3f", secondsSinceExec()))
        log("mode", mode)
    }

    var body: some Scene {
        let _ = logt("app.body")
        WindowGroup {
            Root()
        }
        .onChange(of: appPhase, initial: true) { o, n in logt("app.scenePhase", "\(o)->\(n)") }
    }
}

struct Root: View {
    @Environment(\.scenePhase) var phase
    var body: some View {
        let _ = logt("root.body")
        content
            .onChange(of: phase, initial: true) { o, n in logt("view.scenePhase", "\(o)->\(n)") }
            .onAppear {
                logt("root.onAppear", String(format: "sinceExec=%.3f", secondsSinceExec()))
                firstFrame()
            }
    }

    @ViewBuilder var content: some View {
        switch mode {
        case "layout": LayoutProbe()
        case "lifecycle": LifecycleProbe()
        case "nav": NavProbe()
        case "split": SplitProbe()
        case "tabs": TabsProbe()
        case "list": ListProbe()
        case "controls": ControlsProbe()
        case "keyboard": KeyboardProbe()
        case "modal": ModalProbe()
        case "anim": AnimProbe()
        case "gesture": GestureProbe()
        case "dataflow": DataFlowProbe()
        case "persist": PersistProbe()
        case "env": EnvProbe()
        case "a11y": A11yProbe()
        case "l10n": L10nProbe()
        case "images": ImagesProbe()
        case "services": ServicesProbe()
        default: Text("unknown mode \(mode)")
        }
    }
}

/// Logs the time of the first display-link callback (≈ first frame).
@MainActor func firstFrame() {
    final class Once: NSObject {
        var link: CADisplayLink?
        var n = 0
        var start = 0.0
        @objc func tick(_ l: CADisplayLink) {
            n += 1
            if n == 1 {
                start = CACurrentMediaTime()
                logt("displaylink.first", String(format: "sinceExec=%.3f fps=%d", secondsSinceExec(), l.preferredFramesPerSecond))
            }
            if n == 121 {
                log("displaylink.rate", String(format: "%.2f", 120.0 / (CACurrentMediaTime() - start)))
                l.invalidate(); link = nil
            }
        }
    }
    let o = Once()
    let l = CADisplayLink(target: o, selector: #selector(Once.tick(_:)))
    o.link = l
    l.add(to: .main, forMode: .common)
    keep.append(o)
}

var keep: [Any] = []

/// Logs every loaded image whose path is under /System or /usr/lib (names only).
func logImages(_ label: String) {
    var names: [String] = []
    for i in 0..<_dyld_image_count() {
        guard let c = _dyld_get_image_name(i) else { continue }
        let p = String(cString: c)
        if let r = p.range(of: "/System/Library/") { names.append(String(p[r.lowerBound...])) }
        else if let r = p.range(of: "/usr/lib/") { names.append(String(p[r.lowerBound...])) }
    }
    log("images.\(label).count", names.count)
    for n in names.sorted() { log("images.\(label)", n) }
}

/// Window-level facts: screen, scale, safe area, size classes.
@MainActor func logWindowFacts(_ label: String) {
    let s = UIScreen.main
    log("\(label).screen", "\(sz(s.bounds.size)) scale=\(f2(s.scale)) native=\(f2(s.nativeScale)) maxFPS=\(s.maximumFramesPerSecond)")
    for sc in UIApplication.shared.connectedScenes {
        guard let ws = sc as? UIWindowScene else { continue }
        log("\(label).scene", "\(type(of: sc)) role=\(sc.session.role.rawValue) state=\(sc.activationState.rawValue) windows=\(ws.windows.count)")
        for w in ws.windows {
            log("\(label).window", "\(rc(w.frame)) safe=\(w.safeAreaInsets) key=\(w.isKeyWindow) level=\(w.windowLevel.rawValue)")
            let tc = w.traitCollection
            log("\(label).traits", "h=\(tc.horizontalSizeClass.rawValue) v=\(tc.verticalSizeClass.rawValue) style=\(tc.userInterfaceStyle.rawValue) contentSize=\(tc.preferredContentSizeCategory.rawValue) idiom=\(tc.userInterfaceIdiom.rawValue) layoutDir=\(tc.layoutDirection.rawValue) displayScale=\(tc.displayScale) gamut=\(tc.displayGamut.rawValue) contrast=\(tc.accessibilityContrast.rawValue) legibility=\(tc.legibilityWeight.rawValue)")
            if let vc = w.rootViewController { log("\(label).rootVC", String(String(describing: type(of: vc)).split(separator: "<").first ?? "")) }
        }
    }
}
