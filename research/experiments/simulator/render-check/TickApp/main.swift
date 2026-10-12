// Ycode research R6 (original code): an app whose screen changes 5 times a second,
// so the render server always has new content. It shows a large counter on a
// background whose hue steps with the counter. Used to measure whether
// presentation keeps going under each framebuffer/IOSurface variant.
import UIKit

final class TickController: UIViewController {
    let label = UILabel()
    var n = 0
    override func viewDidLoad() {
        super.viewDidLoad()
        label.font = .monospacedDigitSystemFont(ofSize: 96, weight: .bold)
        label.textColor = .white
        label.textAlignment = .center
        label.frame = view.bounds
        label.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(label)
        tick()
        Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in self?.tick() }
    }
    func tick() {
        n += 1
        label.text = "\(n)"
        view.backgroundColor = UIColor(hue: CGFloat(n % 20) / 20, saturation: 0.8, brightness: 0.8, alpha: 1)
    }
}

final class SceneDelegate: UIResponder, UIWindowSceneDelegate {
    var window: UIWindow?
    func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options connectionOptions: UIScene.ConnectionOptions) {
        guard let scene = scene as? UIWindowScene else { return }
        let w = UIWindow(windowScene: scene)
        w.rootViewController = TickController()
        w.makeKeyAndVisible()
        window = w
    }
}

final class AppDelegate: UIResponder, UIApplicationDelegate {}

UIApplicationMain(CommandLine.argc, CommandLine.unsafeArgv, nil, NSStringFromClass(AppDelegate.self))
