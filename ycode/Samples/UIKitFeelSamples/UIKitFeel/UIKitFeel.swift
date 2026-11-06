// UIKitFeel: Ycode's probe of how UIKit feels in the Ycode simulator
// (specs/simulator/uikit-feel-ycode.md; the quantities of uikit-feel.md).
// Original Ycode sample code, written from public UIKit documentation.
//
// The app shows one page at a time and logs what UIKit reports, one line per
// fact, to /tmp/uikitfeel/log.txt (the device's DEV/data/tmp/uikitfeel on the
// host): `<CACurrentMediaTime> <kind> <key=value ...>`. The host drives it by
// appending commands to /tmp/uikitfeel/cmd.txt (`page scroll`, `mark ...`,
// ...; see `Probe.run(_:)`) and by touching the screen through the display
// stream (scripts/ycode-uikit-feel). Every page logs the rectangles of its
// targets (`rect <name> x y w h`, window points) so that the driver knows
// where to touch. UIKit only: it builds on Linux.

import GameController
import UIKit

// MARK: - Log and commands

/// The probe's log: lines are buffered and written by a background queue,
/// so logging never waits for the file system on the main thread.
final class ProbeLog: @unchecked Sendable {
    static let shared = ProbeLog()
    let directory: String
    private let lock = NSLock()
    private var pending: [String] = []
    private var handle: FileHandle?
    private let queue = DispatchQueue(label: "uikitfeel.log")
    private var timer: DispatchSourceTimer?

    private init() {
        let fm = FileManager.default
        var dir = "/tmp/uikitfeel"
        if (try? fm.createDirectory(atPath: dir, withIntermediateDirectories: true)) == nil {
            dir = NSTemporaryDirectory() + "uikitfeel"
            try? fm.createDirectory(atPath: dir, withIntermediateDirectories: true)
        }
        directory = dir
        let path = dir + "/log.txt"
        fm.createFile(atPath: path, contents: nil)
        handle = FileHandle(forWritingAtPath: path)
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + .milliseconds(100), repeating: .milliseconds(100))
        t.setEventHandler { [weak self] in self?.flush() }
        t.resume()
        timer = t
        print("UIKitFeel: log in \(path)")
    }

    func write(_ kind: String, _ fields: String = "", at time: CFTimeInterval = CACurrentMediaTime()) {
        let line = String(format: "%.6f ", time) + kind + (fields.isEmpty ? "" : " " + fields) + "\n"
        lock.lock()
        pending.append(line)
        lock.unlock()
    }

    func flush() {
        lock.lock()
        let lines = pending
        pending.removeAll()
        lock.unlock()
        guard !lines.isEmpty else { return }
        handle?.write(Data(lines.joined().utf8))
    }
}

func log(_ kind: String, _ fields: String = "") { ProbeLog.shared.write(kind, fields) }

func f3(_ v: CGFloat) -> String { String(format: "%.3f", Double(v)) }
func f6(_ v: Double) -> String { String(format: "%.6f", v) }
func rectText(_ r: CGRect) -> String { "\(f3(r.origin.x)) \(f3(r.origin.y)) \(f3(r.width)) \(f3(r.height))" }
func insetText(_ i: UIEdgeInsets) -> String { "\(f3(i.top)) \(f3(i.left)) \(f3(i.bottom)) \(f3(i.right))" }

/// Reads commands the host appends to cmd.txt (one per line) and runs them
/// on the main thread.
final class CommandReader: @unchecked Sendable {
    private let path: String
    private var offset: UInt64 = 0
    private var partial = ""
    private let queue = DispatchQueue(label: "uikitfeel.commands")
    private var timer: DispatchSourceTimer?
    private let handler: (String) -> Void

    init(directory: String, handler: @escaping (String) -> Void) {
        path = directory + "/cmd.txt"
        self.handler = handler
        FileManager.default.createFile(atPath: path, contents: nil)
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + .milliseconds(20), repeating: .milliseconds(20))
        t.setEventHandler { [weak self] in self?.poll() }
        t.resume()
        timer = t
    }

    private func poll() {
        guard let h = FileHandle(forReadingAtPath: path) else { return }
        defer { try? h.close() }
        let end = h.seekToEndOfFile()
        if end < offset { offset = 0 }
        guard end > offset else { return }
        h.seek(toFileOffset: offset)
        let data = h.readData(ofLength: Int(end - offset))
        offset += UInt64(data.count)
        partial += String(decoding: data, as: UTF8.self)
        while let nl = partial.firstIndex(of: "\n") {
            let line = String(partial[..<nl]).trimmingCharacters(in: .whitespaces)
            partial = String(partial[partial.index(after: nl)...])
            if !line.isEmpty { DispatchQueue.main.async { [handler] in handler(line) } }
        }
    }
}

// MARK: - App

@main
final class AppDelegate: UIResponder, UIApplicationDelegate {
    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        log("launch", "pid=\(ProcessInfo.processInfo.processIdentifier)")
        NotificationCenter.default.addObserver(forName: .GCKeyboardDidConnect, object: nil, queue: .main) { _ in
            log("gc-keyboard", "connected=1")
        }
        NotificationCenter.default.addObserver(forName: .GCKeyboardDidDisconnect, object: nil, queue: .main) { _ in
            log("gc-keyboard", "connected=0")
        }
        return true
    }

    func application(_ application: UIApplication, configurationForConnecting session: UISceneSession,
                     options: UIScene.ConnectionOptions) -> UISceneConfiguration {
        let c = UISceneConfiguration(name: nil, sessionRole: session.role)
        c.delegateClass = SceneDelegate.self
        return c
    }

    func application(_ application: UIApplication,
                     supportedInterfaceOrientationsFor window: UIWindow?) -> UIInterfaceOrientationMask { .all }
}

final class SceneDelegate: UIResponder, UIWindowSceneDelegate {
    var window: UIWindow?
    var probe: Probe?

    func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options: UIScene.ConnectionOptions) {
        guard let scene = scene as? UIWindowScene else { return }
        let w = ProbeWindow(windowScene: scene)
        let p = Probe(window: w)
        w.rootViewController = p.container
        w.makeKeyAndVisible()
        window = w
        probe = p
        p.start()
        print("UIKitFeel: launched")
    }

    func windowScene(_ windowScene: UIWindowScene, didUpdate previousCoordinateSpace: UICoordinateSpace,
                     interfaceOrientation previousInterfaceOrientation: UIInterfaceOrientation,
                     traitCollection previousTraitCollection: UITraitCollection) {
        log("scene-geometry", "orientation=\(windowScene.effectiveGeometry.interfaceOrientation.rawValue) "
            + "bounds=\(rectText(windowScene.effectiveGeometry.coordinateSpace.bounds))")
    }
}

/// Logs every touch the window receives: phase, the event's own timestamp
/// (`ts`), and the position in window points.
final class ProbeWindow: UIWindow {
    override func sendEvent(_ event: UIEvent) {
        if event.type == .touches, let touches = event.allTouches {
            let now = CACurrentMediaTime()
            for t in touches {
                let p = t.location(in: self)
                let phase: String
                switch t.phase {
                case .began: phase = "began"
                case .moved: phase = "moved"
                case .stationary: phase = "stationary"
                case .ended: phase = "ended"
                case .cancelled: phase = "cancelled"
                default: phase = "other"
                }
                ProbeLog.shared.write("touch", "phase=\(phase) ts=\(f6(t.timestamp)) x=\(f3(p.x)) y=\(f3(p.y)) "
                    + "id=\(UInt(bitPattern: ObjectIdentifier(t).hashValue) & 0xFFFF)", at: now)
            }
        } else if event.type == .presses {
            log("press-event", "ts=\(f6(event.timestamp))")
        }
        super.sendEvent(event)
    }
}

// MARK: - The probe: pages and commands

final class Probe {
    let window: UIWindow
    let container = ContainerController()
    private var reader: CommandReader?
    private var displayLink: CADisplayLink?
    private var linkTarget: DisplayLinkTarget?

    init(window: UIWindow) { self.window = window }

    func start() {
        reader = CommandReader(directory: ProbeLog.shared.directory) { [weak self] line in self?.run(line) }
        info()
        container.show(PixelsPage())
        log("ready")
    }

    func info() {
        guard let screen = window.windowScene?.screen else { return }
        log("info", "bounds=\(rectText(screen.bounds)) scale=\(f3(screen.scale)) nativeScale=\(f3(screen.nativeScale)) "
            + "nativeBounds=\(rectText(screen.nativeBounds)) maxFPS=\(screen.maximumFramesPerSecond) "
            + "safe=\(insetText(window.safeAreaInsets)) window=\(rectText(window.bounds)) "
            + "gcKeyboard=\(GCKeyboard.coalesced != nil ? 1 : 0)")
    }

    /// One command from the host.
    func run(_ line: String) {
        let w = line.split(separator: " ").map(String.init)
        guard let command = w.first else { return }
        log("cmd", line)
        switch command {
        case "mark":
            break
        case "info":
            info()
        case "page":
            guard w.count >= 2 else { return }
            let page: UIViewController
            switch w[1] {
            case "scroll": page = ScrollPage(paging: false)
            case "paging": page = ScrollPage(paging: true)
            case "gestures": page = GesturesPage()
            case "keyboard": page = KeyboardPage()
            case "rotation": page = RotationPage()
            case "display": page = DisplayPage()
            default: page = PixelsPage()
            }
            container.show(page)
        case "offset":
            // offset <points>: the scroll page's content offset along its axis
            // ("top"/"bottom": the edge rest); paging: offset page <n>.
            (container.page as? ScrollPage)?.setOffset(w.dropFirst().map { $0 })
        case "kb-hide":
            (container.page as? KeyboardPage)?.field.resignFirstResponder()
        case "kb-show":
            (container.page as? KeyboardPage)?.field.becomeFirstResponder()
        case "animate":
            (container.page as? DisplayPage)?.animate()
        case "dl":
            startLink(variant: w.count > 1 ? w[1] : "default")
        case "dl-stop":
            displayLink?.invalidate()
            displayLink = nil
            log("dl-stopped")
        case "flush":
            ProbeLog.shared.flush()
        default:
            log("cmd-unknown", line)
        }
    }

    /// §7.2: a display link on the main run loop in common modes; "max"
    /// asks for 80–120 Hz.
    func startLink(variant: String) {
        displayLink?.invalidate()
        let target = DisplayLinkTarget()
        let link = CADisplayLink(target: target, selector: #selector(DisplayLinkTarget.tick(_:)))
        if variant == "max" {
            link.preferredFrameRateRange = CAFrameRateRange(minimum: 80, maximum: 120, preferred: 120)
        }
        link.add(to: .main, forMode: .common)
        displayLink = link
        linkTarget = target
        log("dl-started", "variant=\(variant)")
    }
}

final class DisplayLinkTarget: NSObject {
    @objc func tick(_ link: CADisplayLink) {
        log("dl", "ts=\(f6(link.timestamp)) target=\(f6(link.targetTimestamp)) dur=\(f6(link.duration))")
    }
}

/// Holds the current page as its only child.
final class ContainerController: UIViewController {
    private(set) var page: UIViewController?

    func show(_ next: UIViewController) {
        if let old = page {
            old.willMove(toParent: nil)
            old.view.removeFromSuperview()
            old.removeFromParent()
        }
        addChild(next)
        next.view.frame = view.bounds
        next.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(next.view)
        next.didMove(toParent: self)
        page = next
        log("page", String(describing: type(of: next)))
    }

    override var supportedInterfaceOrientations: UIInterfaceOrientationMask { .all }

    override func viewWillTransition(to size: CGSize, with coordinator: UIViewControllerTransitionCoordinator) {
        super.viewWillTransition(to: size, with: coordinator)
        log("will-transition", "size=\(f3(size.width))x\(f3(size.height)) duration=\(f6(coordinator.transitionDuration)) "
            + "curve=\(coordinator.completionCurve.rawValue)")
        coordinator.animate(alongsideTransition: { _ in log("transition-alongside") },
                            completion: { _ in log("transition-completion", "bounds=\(rectText(self.view.bounds))") })
    }

    override func viewSafeAreaInsetsDidChange() {
        super.viewSafeAreaInsetsDidChange()
        log("safe-area", insetText(view.safeAreaInsets))
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        registerForTraitChanges([UITraitVerticalSizeClass.self, UITraitHorizontalSizeClass.self]) { (c: Self, _) in
            log("traits", "h=\(c.traitCollection.horizontalSizeClass.rawValue) v=\(c.traitCollection.verticalSizeClass.rawValue)")
        }
    }

    override func viewWillLayoutSubviews() {
        super.viewWillLayoutSubviews()
        log("will-layout", "bounds=\(rectText(view.bounds))")
    }
}

/// Logs a view's rectangle in window points.
func logRect(_ name: String, _ v: UIView) {
    guard let w = v.window else { return }
    log("rect", "\(name) " + rectText(v.convert(v.bounds, to: w)))
}

// MARK: - Scrolling (§3)

final class ScrollPage: UIViewController, UIScrollViewDelegate {
    let paging: Bool
    let scroll = UIScrollView()

    init(paging: Bool) {
        self.paging = paging
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError("not used") }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .white
        scroll.delegate = self
        scroll.frame = view.bounds
        scroll.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        if !paging { scroll.alwaysBounceVertical = true }
        scroll.isPagingEnabled = paging
        view.addSubview(scroll)
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        let size = scroll.bounds.size
        guard size.width > 0 else { return }
        if paging {
            let pages = 10
            if scroll.contentSize.width != size.width * CGFloat(pages) {
                scroll.subviews.forEach { $0.removeFromSuperview() }
                for i in 0..<pages {
                    let v = UIView(frame: CGRect(x: CGFloat(i) * size.width, y: 0, width: size.width, height: size.height))
                    v.backgroundColor = i % 2 == 0 ? UIColor(white: 0.85, alpha: 1) : UIColor(red: 0.7, green: 0.8, blue: 1, alpha: 1)
                    scroll.addSubview(v)
                }
                scroll.contentSize = CGSize(width: size.width * CGFloat(pages), height: size.height)
                scroll.contentOffset = CGPoint(x: size.width * 3, y: 0)
            }
        } else if scroll.contentSize.height != 20_000 {
            for i in 0..<200 {
                let v = UIView(frame: CGRect(x: 0, y: CGFloat(i) * 100, width: size.width, height: 100))
                v.backgroundColor = i % 2 == 0 ? UIColor(white: 0.9, alpha: 1) : UIColor(red: 1, green: 0.85, blue: 0.7, alpha: 1)
                v.autoresizingMask = [.flexibleWidth]
                scroll.addSubview(v)
            }
            scroll.contentSize = CGSize(width: size.width, height: 20_000)
        }
        logConfig()
    }

    func logConfig() {
        log("scroll-config", "paging=\(paging ? 1 : 0) rate=\(f6(Double(scroll.decelerationRate.rawValue))) "
            + "fast=\(f6(Double(UIScrollView.DecelerationRate.fast.rawValue))) delays=\(scroll.delaysContentTouches ? 1 : 0) "
            + "toTop=\(scroll.scrollsToTop ? 1 : 0) inset=\(insetText(scroll.adjustedContentInset)) "
            + "size=\(f3(scroll.bounds.width))x\(f3(scroll.bounds.height)) content=\(f3(scroll.contentSize.width))x\(f3(scroll.contentSize.height)) "
            + "off=\(f3(scroll.contentOffset.x)),\(f3(scroll.contentOffset.y))")
        logRect("scroll", scroll)
    }

    func setOffset(_ args: [String]) {
        guard let a = args.first else { return }
        let inset = scroll.adjustedContentInset
        if paging {
            let page = Double(args.count > 1 ? args[1] : a) ?? 3
            scroll.setContentOffset(CGPoint(x: scroll.bounds.width * page, y: 0), animated: false)
        } else {
            let y: CGFloat
            switch a {
            case "top": y = -inset.top
            case "bottom": y = scroll.contentSize.height + inset.bottom - scroll.bounds.height
            default: y = CGFloat(Double(a) ?? 0)
            }
            scroll.setContentOffset(CGPoint(x: 0, y: y), animated: false)
        }
        logConfig()
    }

    private var axisOffset: CGFloat { paging ? scroll.contentOffset.x : scroll.contentOffset.y }

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        log("did-scroll", "off=\(f3(axisOffset)) tracking=\(scroll.isTracking ? 1 : 0) decel=\(scroll.isDecelerating ? 1 : 0)")
    }
    func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
        let p = scroll.panGestureRecognizer.location(in: view.window)
        log("will-begin-drag", "off=\(f3(axisOffset)) x=\(f3(p.x)) y=\(f3(p.y))")
    }
    func scrollViewWillEndDragging(_ scrollView: UIScrollView, withVelocity velocity: CGPoint,
                                   targetContentOffset: UnsafeMutablePointer<CGPoint>) {
        let v = paging ? velocity.x : velocity.y
        let t = paging ? targetContentOffset.pointee.x : targetContentOffset.pointee.y
        log("will-end-drag", "vel=\(f6(Double(v))) target=\(f3(t)) off=\(f3(axisOffset))")
    }
    func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
        log("did-end-drag", "decelerate=\(decelerate ? 1 : 0) off=\(f3(axisOffset))")
    }
    func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) {
        log("did-end-decel", "off=\(f3(axisOffset))")
    }
    func scrollViewShouldScrollToTop(_ scrollView: UIScrollView) -> Bool {
        log("should-scroll-top", "off=\(f3(axisOffset))")
        return true
    }
    func scrollViewDidScrollToTop(_ scrollView: UIScrollView) {
        log("did-scroll-top", "off=\(f3(axisOffset))")
    }
}

// MARK: - Gestures (§4)

final class ProbeButton: UIButton {
    var name = ""
    override var isHighlighted: Bool {
        didSet { if isHighlighted != oldValue { log("highlight", "\(name) on=\(isHighlighted ? 1 : 0)") } }
    }
    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        log("button-began", "\(name) ts=\(f6(touches.first?.timestamp ?? 0))")
        super.touchesBegan(touches, with: event)
    }
}

final class GesturesPage: UIViewController {
    let plain = ProbeButton(type: .custom)
    let inner = ProbeButton(type: .custom)
    let innerScroll = UIScrollView()
    let longPad = UIView(), tapPad = UIView(), swipePad = UIView(), panPad = UIView(), pinchPad = UIView()

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .white
        for (b, n) in [(plain, "plain"), (inner, "inner")] {
            b.name = n
            b.setTitle(n, for: .normal)
            b.backgroundColor = .systemBlue
            b.setTitleColor(.white, for: .normal)
            b.setTitleColor(.black, for: .highlighted)
            b.addTarget(self, action: #selector(upInside(_:)), for: .touchUpInside)
        }
        view.addSubview(plain)
        innerScroll.alwaysBounceVertical = true
        innerScroll.backgroundColor = UIColor(white: 0.9, alpha: 1)
        innerScroll.addSubview(inner)
        view.addSubview(innerScroll)
        let colors: [UIColor] = [.systemOrange, .systemGreen, .systemPurple, .systemTeal, .systemPink]
        for (i, v) in [longPad, tapPad, swipePad, panPad, pinchPad].enumerated() {
            v.backgroundColor = colors[i].withAlphaComponent(0.4)
            view.addSubview(v)
        }
        let long = UILongPressGestureRecognizer(target: self, action: #selector(longPress(_:)))
        longPad.addGestureRecognizer(long)
        log("long-config", "minimum=\(f6(long.minimumPressDuration)) movement=\(f3(long.allowableMovement))")
        let double = UITapGestureRecognizer(target: self, action: #selector(doubleTap(_:)))
        double.numberOfTapsRequired = 2
        let single = UITapGestureRecognizer(target: self, action: #selector(singleTap(_:)))
        single.require(toFail: double)
        tapPad.addGestureRecognizer(double)
        tapPad.addGestureRecognizer(single)
        for d in [UISwipeGestureRecognizer.Direction.left, .right] {
            let s = UISwipeGestureRecognizer(target: self, action: #selector(swipe(_:)))
            s.direction = d
            swipePad.addGestureRecognizer(s)
        }
        panPad.addGestureRecognizer(UIPanGestureRecognizer(target: self, action: #selector(pan(_:))))
        pinchPad.addGestureRecognizer(UIPinchGestureRecognizer(target: self, action: #selector(pinch(_:))))
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        let b = view.bounds, s = view.safeAreaInsets
        let w = b.width, top = s.top + 20, h = b.height - s.top - s.bottom - 40
        let col = (w - 60) / 2
        plain.frame = CGRect(x: 20, y: top, width: col, height: h * 0.1)
        innerScroll.frame = CGRect(x: 40 + col, y: top, width: col, height: h * 0.1)
        innerScroll.contentSize = CGSize(width: col, height: h * 0.1 + 40)
        inner.frame = CGRect(x: 0, y: 0, width: col, height: h * 0.1)
        longPad.frame = CGRect(x: 20, y: top + h * 0.13, width: col, height: h * 0.17)
        tapPad.frame = CGRect(x: 40 + col, y: top + h * 0.13, width: col, height: h * 0.17)
        swipePad.frame = CGRect(x: 20, y: top + h * 0.33, width: w - 40, height: h * 0.15)
        panPad.frame = CGRect(x: 20, y: top + h * 0.51, width: col, height: h * 0.49)
        pinchPad.frame = CGRect(x: 40 + col, y: top + h * 0.51, width: col, height: h * 0.49)
        for (n, v) in [("plain", plain as UIView), ("inner", inner), ("long", longPad), ("tap", tapPad),
                       ("swipe", swipePad), ("pan", panPad), ("pinch", pinchPad)] { logRect(n, v) }
    }

    @objc func upInside(_ b: ProbeButton) { log("up-inside", b.name) }

    private func stateName(_ s: UIGestureRecognizer.State) -> String {
        switch s {
        case .began: "began"
        case .changed: "changed"
        case .ended: "ended"
        case .cancelled: "cancelled"
        case .failed: "failed"
        default: "possible"
        }
    }

    @objc func longPress(_ g: UILongPressGestureRecognizer) {
        let p = g.location(in: view.window)
        log("long", "state=\(stateName(g.state)) x=\(f3(p.x)) y=\(f3(p.y))")
    }
    @objc func doubleTap(_ g: UITapGestureRecognizer) { log("double-tap") }
    @objc func singleTap(_ g: UITapGestureRecognizer) { log("single-tap") }
    @objc func swipe(_ g: UISwipeGestureRecognizer) {
        let p = g.location(in: view.window)
        log("swipe", "direction=\(g.direction == .left ? "left" : "right") x=\(f3(p.x)) y=\(f3(p.y))")
    }
    @objc func pan(_ g: UIPanGestureRecognizer) {
        let p = g.location(in: view.window), t = g.translation(in: view.window)
        log("pan", "state=\(stateName(g.state)) x=\(f3(p.x)) y=\(f3(p.y)) tx=\(f3(t.x)) ty=\(f3(t.y))")
    }
    @objc func pinch(_ g: UIPinchGestureRecognizer) {
        var d = ""
        if g.numberOfTouches >= 2 {
            let a = g.location(ofTouch: 0, in: view.window), b = g.location(ofTouch: 1, in: view.window)
            d = " distance=\(f3(hypot(a.x - b.x, a.y - b.y)))"
        }
        log("pinch", "state=\(stateName(g.state)) scale=\(f6(Double(g.scale)))" + d)
    }
}

// MARK: - Keyboard (§5)

final class KeyboardPage: UIViewController {
    let field = UITextField()
    let marker = UIView()
    private var link: CADisplayLink?
    private var lastY: CGFloat = -1

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .white
        field.borderStyle = .roundedRect
        field.placeholder = "Type here"
        field.autocorrectionType = .no
        field.translatesAutoresizingMaskIntoConstraints = false
        marker.backgroundColor = .systemRed
        marker.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(field)
        view.addSubview(marker)
        NSLayoutConstraint.activate([
            field.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 40),
            field.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
            field.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20),
            field.heightAnchor.constraint(equalToConstant: 44),
            marker.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            marker.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            marker.heightAnchor.constraint(equalToConstant: 8),
            marker.bottomAnchor.constraint(equalTo: view.keyboardLayoutGuide.topAnchor),
        ])
        let names: [(Notification.Name, String)] = [
            (UIResponder.keyboardWillShowNotification, "will-show"), (UIResponder.keyboardDidShowNotification, "did-show"),
            (UIResponder.keyboardWillHideNotification, "will-hide"), (UIResponder.keyboardDidHideNotification, "did-hide"),
            (UIResponder.keyboardWillChangeFrameNotification, "will-change"),
            (UIResponder.keyboardDidChangeFrameNotification, "did-change"),
        ]
        for (n, label) in names {
            NotificationCenter.default.addObserver(forName: n, object: nil, queue: .main) { note in
                let u = note.userInfo ?? [:]
                let begin = (u[UIResponder.keyboardFrameBeginUserInfoKey] as? CGRect) ?? .null
                let end = (u[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect) ?? .null
                let duration = (u[UIResponder.keyboardAnimationDurationUserInfoKey] as? Double) ?? -1
                let curve = (u[UIResponder.keyboardAnimationCurveUserInfoKey] as? Int) ?? -1
                let local = (u[UIResponder.keyboardIsLocalUserInfoKey] as? Bool) ?? false
                log("kb", "\(label) begin=\(rectText(begin)) end=\(rectText(end)) duration=\(f6(duration)) curve=\(curve) local=\(local ? 1 : 0)")
            }
        }
        let l = CADisplayLink(target: self, selector: #selector(sample(_:)))
        l.add(to: .main, forMode: .common)
        link = l
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        logRect("field", field)
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        link?.invalidate()
    }

    @objc func sample(_ l: CADisplayLink) {
        let y = marker.layer.presentation()?.frame.maxY ?? marker.frame.maxY
        if y != lastY {
            lastY = y
            log("kb-pos", "y=\(f3(y)) ts=\(f6(l.timestamp))")
        }
    }

    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        for p in presses { log("press", "began key=\(p.key?.keyCode.rawValue ?? -1)") }
        super.pressesBegan(presses, with: event)
    }
}

// MARK: - Rotation (§6)

final class RotationPage: UIViewController {
    private var link: CADisplayLink?
    private var last = CGSize.zero

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = UIColor(red: 0.9, green: 1, blue: 0.9, alpha: 1)
        let l = CADisplayLink(target: self, selector: #selector(sample(_:)))
        l.add(to: .main, forMode: .common)
        link = l
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        link?.invalidate()
    }

    @objc func sample(_ l: CADisplayLink) {
        guard let layer = view.window?.layer.presentation() else { return }
        let s = layer.bounds.size
        if s != last {
            last = s
            log("rot-pos", "w=\(f3(s.width)) h=\(f3(s.height)) ts=\(f6(l.timestamp))")
        }
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        log("did-layout", "bounds=\(rectText(view.bounds))")
    }
}

// MARK: - Frame pacing (§7)

final class DisplayPage: UIViewController {
    let box = UIView()

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .white
        box.backgroundColor = .systemIndigo
        box.frame = CGRect(x: 20, y: 200, width: 60, height: 60)
        view.addSubview(box)
    }

    /// A 2 s linear move across the screen and back.
    func animate() {
        let w = view.bounds.width
        box.frame.origin.x = 20
        log("animate-start")
        UIView.animate(withDuration: 2, delay: 0, options: [.curveLinear], animations: {
            self.box.frame.origin.x = w - 80
        }, completion: { _ in log("animate-end") })
    }
}

// MARK: - Pixels (§8)

/// A test pattern with known pixels: 1-px checkerboards, text and hairlines.
final class PixelsPage: UIViewController {
    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .white
    }

    private var built = false

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        guard !built, view.window != nil else { return }
        built = true
        let scale = view.window?.windowScene?.screen.scale ?? 3
        let px = 1 / scale
        // Every row starts on a whole device pixel (the half-pixel cases add
        // their half pixel to an aligned origin).
        var y = view.safeAreaInsets.top + 10
        func align() { y = (y * scale).rounded(.up) / scale }
        func label(_ name: String, _ text: String, _ font: UIFont, x: CGFloat, color: UIColor = .black) {
            align()
            let l = UILabel()
            l.text = text
            l.font = font
            l.textColor = color
            l.backgroundColor = .white
            l.sizeToFit()
            l.frame.origin = CGPoint(x: x, y: y)
            view.addSubview(l)
            logRect(name, l)
        }
        // The pixel-exact pattern for the device window check: 96 × 96 device
        // pixels of a known sequence, pixel-aligned, at the top right (where
        // a window too small for the whole screen still shows it).
        let pattern = Self.pattern(pixels: 96, scale: scale)
        let pv = UIImageView(image: pattern)
        align()
        pv.frame = CGRect(x: ((view.bounds.width - 20 - 96 / scale) * scale).rounded() / scale, y: y, width: 96 / scale, height: 96 / scale)
        view.addSubview(pv)
        logRect("pattern", pv)
        for size in [9, 12, 17, 34] as [CGFloat] {
            label("text\(Int(size))", "Ilmn 0123 Sharp", .systemFont(ofSize: size, weight: size == 34 ? .bold : .regular), x: 20)
            y += size * 1.4 + 6
        }
        label("text17-1px", "Ilmn 0123 Sharp", .systemFont(ofSize: 17), x: 20 + px)
        y += 30
        label("text17-halfpx", "Ilmn 0123 Sharp", .systemFont(ofSize: 17), x: 20 + px / 2)
        y += 30
        label("red17", "Ilmn 0123 Sharp", .systemFont(ofSize: 17), x: 20, color: .red)
        y += 34
        align()
        // A checkerboard drawn at the screen scale, pixel-aligned, and the
        // same image half a pixel lower.
        let checker = Self.checkerboard(pixels: 48, scale: scale)
        for (name, dy) in [("checker", 0.0), ("checker-halfpx", 0.5)] {
            let iv = UIImageView(image: checker)
            iv.frame = CGRect(x: name == "checker" ? 20 : 120, y: y + CGFloat(dy) * px, width: 48 / scale, height: 48 / scale)
            view.addSubview(iv)
            logRect(name, iv)
        }
        // A scale-1 bitmap shown at its point size (magnified) and stretched.
        let small = Self.checkerboard(pixels: 16, scale: 1)
        let mag = UIImageView(image: small)
        mag.frame = CGRect(x: 220, y: y, width: 16, height: 16)
        view.addSubview(mag)
        logRect("magnified", mag)
        let stretched = UIImageView(image: small)
        stretched.contentMode = .scaleToFill
        stretched.frame = CGRect(x: 260, y: y, width: 37, height: 37)
        view.addSubview(stretched)
        logRect("stretched", stretched)
        y += 60
        align()
        // Hairlines: 1 px and 1 pt solid views at a half-pixel offset.
        for (name, h, x) in [("line-1px", px, 20.0), ("line-1pt", 1.0, 140.0)] as [(String, CGFloat, CGFloat)] {
            let v = UIView(frame: CGRect(x: x, y: y + px / 2, width: 100, height: h))
            v.backgroundColor = .black
            view.addSubview(v)
            logRect(name, v)
        }
        y += 20
        log("pixels-ready", "scale=\(f3(scale))")
    }

    static func checkerboard(pixels n: Int, scale: CGFloat) -> UIImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = scale
        format.opaque = true
        let size = CGSize(width: CGFloat(n) / scale, height: CGFloat(n) / scale)
        return UIGraphicsImageRenderer(size: size, format: format).image { ctx in
            UIColor.white.setFill()
            ctx.fill(CGRect(origin: .zero, size: size))
            UIColor.black.setFill()
            for y in 0..<n { for x in 0..<n where (x + y) % 2 == 0 {
                ctx.fill(CGRect(x: CGFloat(x) / scale, y: CGFloat(y) / scale, width: 1 / scale, height: 1 / scale))
            } }
        }
    }

    /// Gray levels from a fixed linear congruential sequence; the host
    /// computes the same (scripts/ycode-uikit-feel, `pattern_pixels`).
    static func pattern(pixels n: Int, scale: CGFloat) -> UIImage {
        var bytes = [UInt8](repeating: 0, count: n * n * 4)
        var s: UInt32 = 12345
        for i in 0..<(n * n) {
            s = s &* 1_103_515_245 &+ 12345
            let g = UInt8((s >> 16) & 0xFF)
            bytes[4 * i] = g
            bytes[4 * i + 1] = g
            bytes[4 * i + 2] = g
            bytes[4 * i + 3] = 255
        }
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        let provider = CGDataProvider(data: Data(bytes) as CFData)!
        let image = CGImage(width: n, height: n, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: 4 * n, space: space,
                            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
        return UIImage(cgImage: image, scale: scale, orientation: .up)
    }
}
