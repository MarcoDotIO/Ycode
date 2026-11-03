// AVSync: a test app for the display stream's sound (display-stream.md §15).
// A tap turns the screen white and starts a 1 kHz tone at the same moment,
// both for 200 ms, so a viewer can measure the offset between the picture
// and the sound it receives. The tone is made here (no resources). UIKit
// only: it builds on Linux, where the SDK's SwiftUI macros have no plug-in.

import AVFoundation
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
        w.rootViewController = FlashController()
        w.makeKeyAndVisible()
        window = w
    }
}

/// A 200 ms, 1 kHz sine with 2 ms fades, played through AVAudioEngine.
final class Beeper {
    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private let buffer: AVAudioPCMBuffer

    init() {
        let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2)!
        let frames: AVAudioFrameCount = 9_600
        buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
        buffer.frameLength = frames
        for ch in 0..<2 {
            let p = buffer.floatChannelData![ch]
            for i in 0..<Int(frames) {
                let fade = min(1, Float(min(i, Int(frames) - i)) / 96)
                p[i] = 0.5 * fade * sinf(2 * .pi * 1000 * Float(i) / 48_000)
            }
        }
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: format)
        try? AVAudioSession.sharedInstance().setCategory(.playback)
        try? AVAudioSession.sharedInstance().setActive(true)
        try? engine.start()
    }

    func beep() {
        if !engine.isRunning { try? engine.start() }
        player.scheduleBuffer(buffer, at: nil, options: .interrupts)
        player.play()
    }
}

final class FlashController: UIViewController {
    private let beeper = Beeper()
    private let label = UILabel()
    private var count = 0

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        label.textColor = .white
        label.font = .monospacedDigitSystemFont(ofSize: 22, weight: .semibold)
        label.text = "AVSync · tap to flash and beep"
        label.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(label)
        NSLayoutConstraint.activate([label.centerXAnchor.constraint(equalTo: view.centerXAnchor),
                                     label.centerYAnchor.constraint(equalTo: view.centerYAnchor)])
        view.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(tap)))
    }

    @objc private func tap() {
        count += 1
        label.text = "AVSync · taps \(count)"
        view.backgroundColor = .white
        label.textColor = .black
        beeper.beep()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
            self?.view.backgroundColor = .black
            self?.label.textColor = .white
        }
    }
}
