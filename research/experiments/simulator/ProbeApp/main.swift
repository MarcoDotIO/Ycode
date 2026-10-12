// Ycode simulator probe: reports what the simulator gives a launched app.
import UIKit
import MachO

func print(_ s: String) { FileHandle.standardError.write(Data((s + "\n").utf8)) }

func report() {
    let info = ProcessInfo.processInfo
    print("== YCODE-PROBE BEGIN")
    print("pid=\(info.processIdentifier) ppid=\(getppid()) uid=\(getuid())")
    print("args=\(CommandLine.arguments)")
    print("bundle=\(Bundle.main.bundlePath)")
    print("home=\(NSHomeDirectory())")
    print("tmp=\(NSTemporaryDirectory())")
    for (k, v) in info.environment.sorted(by: { $0.key < $1.key }) { print("env \(k)=\(v)") }
    let n = _dyld_image_count()
    print("images=\(n)")
    for i in 0..<min(n, 12) { print("image \(i) \(String(cString: _dyld_get_image_name(i)))") }
    var u = utsname(); uname(&u)
    let machine = withUnsafeBytes(of: &u.machine) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
    let release = withUnsafeBytes(of: &u.release) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
    print("uname machine=\(machine) release=\(release)")
    print("device model=\(UIDevice.current.model) system=\(UIDevice.current.systemName) \(UIDevice.current.systemVersion)")
    print("== YCODE-PROBE END")
}

final class SceneDelegate: UIResponder, UIWindowSceneDelegate {
    var window: UIWindow?
    func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options connectionOptions: UIScene.ConnectionOptions) {
        guard let scene = scene as? UIWindowScene else { return }
        let w = UIWindow(windowScene: scene)
        let vc = UIViewController()
        vc.view.backgroundColor = .systemTeal
        w.rootViewController = vc
        w.makeKeyAndVisible()
        window = w
    }
}

final class AppDelegate: UIResponder, UIApplicationDelegate {
    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
        report()
        return true
    }
}

UIApplicationMain(CommandLine.argc, CommandLine.unsafeArgv, nil, NSStringFromClass(AppDelegate.self))
