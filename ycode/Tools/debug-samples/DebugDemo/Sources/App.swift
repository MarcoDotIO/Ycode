// DebugDemo: a small UIKit app for the debug stub's end-to-end check
// (specs/simulator/debug-stub.md §9). Once a second the main thread runs
// one round of `work` and shows it. Original Ycode sample code.
import Darwin
import UIKit

/// The plugin's entry point (Plugin.c), found with dlsym.
typealias PluginScale = @convention(c) (Int32) -> Int32

/// The round in which the app loads its plugin with dlopen: the
/// environment's DEBUGDEMO_PLUGIN_ROUND, else 40.
let pluginRound = Int(ProcessInfo.processInfo.environment["DEBUGDEMO_PLUGIN_ROUND"] ?? "") ?? 40

final class DemoController: UIViewController {
    var stats = Stats()
    let label = UILabel()
    var scale: PluginScale?

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        label.frame = view.bounds.insetBy(dx: 20, dy: 120)
        label.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        label.numberOfLines = 0
        label.textAlignment = .center
        label.font = .monospacedDigitSystemFont(ofSize: 22, weight: .medium)
        label.text = "DebugDemo\nwaiting for the first round"
        view.addSubview(label)
        Timer.scheduledTimer(timeInterval: 1, target: self, selector: #selector(tick), userInfo: nil, repeats: true)
    }

    @objc func tick() {
        let value = work(round: stats.rounds, stats: &stats)
        if stats.rounds == pluginRound { loadPlugin() }
        let scaled = scale.map { Int($0(Int32(truncatingIfNeeded: value))) }
        label.text = "DebugDemo\nround \(stats.rounds): \(value)"
        print("DebugDemo: round \(stats.rounds) value \(value)" + (scaled.map { " plugin \($0)" } ?? ""))
    }

    /// Loads libDemoPlugin.dylib from the bundle (an image the debugger
    /// learns about after it attached).
    func loadPlugin() {
        let path = Bundle.main.bundlePath + "/libDemoPlugin.dylib"
        guard let handle = dlopen(path, RTLD_NOW), let symbol = dlsym(handle, "demo_plugin_scale") else {
            print("DebugDemo: cannot load the plugin: \(String(cString: dlerror()))")
            return
        }
        scale = unsafeBitCast(symbol, to: PluginScale.self)
        print("DebugDemo: loaded the plugin")
    }
}

final class SceneDelegate: UIResponder, UIWindowSceneDelegate {
    var window: UIWindow?

    func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options: UIScene.ConnectionOptions) {
        guard let scene = scene as? UIWindowScene else { return }
        let w = UIWindow(windowScene: scene)
        w.rootViewController = DemoController()
        w.makeKeyAndVisible()
        window = w
        print("DebugDemo: launched")
    }
}

@main
final class AppDelegate: UIResponder, UIApplicationDelegate {
    func application(_ application: UIApplication, configurationForConnecting session: UISceneSession,
                     options: UIScene.ConnectionOptions) -> UISceneConfiguration {
        let c = UISceneConfiguration(name: "Default", sessionRole: session.role)
        c.delegateClass = SceneDelegate.self
        return c
    }
}
