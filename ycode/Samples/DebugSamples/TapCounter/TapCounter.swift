// TapCounter: the Linux IDE's simulator debugging sample (specs/ide/debug.md,
// "The Linux IDE: apps on the simulator"). One button in the middle of the
// screen; each tap runs `buttonTapped(_:)`, which counts the tap and shows
// it. The end-to-end test puts its breakpoint in that handler. UIKit only:
// it builds on Linux, where the SDK's SwiftUI macros have no plug-in.
// Original Ycode sample code.

import UIKit

@main
final class AppDelegate: UIResponder, UIApplicationDelegate {
    func application(_ application: UIApplication, configurationForConnecting session: UISceneSession,
                     options: UIScene.ConnectionOptions) -> UISceneConfiguration {
        let c = UISceneConfiguration(name: nil, sessionRole: session.role)
        c.delegateClass = SceneDelegate.self
        return c
    }
}

/// The scene life cycle (required by the iOS 27 SDK's UIKit).
final class SceneDelegate: UIResponder, UIWindowSceneDelegate {
    var window: UIWindow?

    func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options: UIScene.ConnectionOptions) {
        guard let scene = scene as? UIWindowScene else { return }
        let w = UIWindow(windowScene: scene)
        w.rootViewController = CounterController()
        w.makeKeyAndVisible()
        window = w
        print("TapCounter: launched")
    }
}

/// What the taps add up to.
struct Tally {
    var taps = 0
    var lastStep = 0
}

final class CounterController: UIViewController {
    var tally = Tally()
    let label = UILabel()
    let button = UIButton(type: .system)

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        label.text = "No taps yet"
        label.font = .monospacedDigitSystemFont(ofSize: 28, weight: .semibold)
        label.textAlignment = .center
        button.setTitle("Tap Me", for: .normal)
        button.titleLabel?.font = .systemFont(ofSize: 34, weight: .bold)
        button.backgroundColor = .systemBlue
        button.setTitleColor(.white, for: .normal)
        button.layer.cornerRadius = 20
        button.addTarget(self, action: #selector(buttonTapped(_:)), for: .touchUpInside)
        for v in [label, button] {
            v.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(v)
        }
        NSLayoutConstraint.activate([
            button.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            button.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            button.widthAnchor.constraint(equalToConstant: 240),
            button.heightAnchor.constraint(equalToConstant: 120),
            label.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            label.bottomAnchor.constraint(equalTo: button.topAnchor, constant: -40),
        ])
    }

    @objc func buttonTapped(_ sender: UIButton) {
        let step = tally.taps + 1
        tally.taps += 1
        tally.lastStep = step
        let message = "Tapped \(tally.taps) time" + (tally.taps == 1 ? "" : "s")
        label.text = message
        print("TapCounter: \(message)")
    }
}
