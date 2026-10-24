// The viewer window: the device view, a button bar (Home, Lock, Volume,
// Rotate, Screenshot), status (connecting / booting / live, frame rate,
// bandwidth, input latency), and the menus with their shortcuts.

#if os(macOS)
import AppKit
import YcodeDisplayStream

@MainActor
final class ViewerController: NSObject, NSWindowDelegate, ViewerConnectionDelegate, DeviceInputHandler {
    let connection: ViewerConnection
    let window: NSWindow
    let deviceView = DeviceView(frame: NSRect(x: 0, y: 0, width: 466, height: 678))
    private let statusLabel = NSTextField(labelWithString: "Connecting…")
    private let rateLabel = NSTextField(labelWithString: "")
    private var rotateButton: NSButton!
    private var hello: DisplayServerHello?
    private var phase = "connecting"
    private var phaseDetail: String?
    private var uptime = 0
    private var hasImage = false
    /// The window scale: view points per device point.
    private(set) var zoom: CGFloat
    static let barHeight: CGFloat = 30

    // Statistics.
    private var frameTimes: [UInt64] = []
    private var lastBytes = 0
    private var lastStatsTime = nowNanoseconds()
    private var bandwidth: Double = 0
    private(set) var rtt: Double?
    /// Inputs whose first visible change is awaited: (sequence, sent at, label).
    private var probes: [(seq: UInt32, sent: UInt64, label: String)] = []
    private(set) var latencies: [(label: String, ms: Double)] = []
    private var lastLatency: Double?
    private var screenshotWaiters: [UInt32: ([UInt8]) -> Void] = [:]
    private var nextScreenshot: UInt32 = 1
    var onFrame: ((DisplayFrame) -> Void)?
    var log: (String) -> Void = { _ in }

    init(connection: ViewerConnection, zoom: CGFloat) {
        self.connection = connection
        self.zoom = zoom
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 466 * zoom, height: 678 * zoom + Self.barHeight),
                          styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        super.init()
        window.title = "Ycode Simulator Viewer"
        window.delegate = self
        window.isReleasedWhenClosed = false
        window.backgroundColor = .windowBackgroundColor
        buildContent()
        applyZoom(zoom)
        window.center()
        deviceView.input = self
        connection.delegate = self
        Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.tick() }
    }

    private func buildContent() {
        let content = NSView()
        window.contentView = content
        deviceView.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(deviceView)
        func button(_ title: String, _ action: Selector, _ tip: String) -> NSButton {
            let b = NSButton(title: title, target: self, action: action)
            b.bezelStyle = .rounded
            b.controlSize = .small
            b.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
            b.toolTip = tip
            b.refusesFirstResponder = true
            return b
        }
        rotateButton = button("Rotate", #selector(rotate(_:)), "Rotate the device (not supported yet)")
        rotateButton.isEnabled = false
        let buttons = [button("Home", #selector(home(_:)), "Home button (⇧⌘H)"),
                       button("Lock", #selector(lock(_:)), "Lock / side button (⌘L)"),
                       button("Vol +", #selector(volumeUp(_:)), "Volume up"),
                       button("Vol −", #selector(volumeDown(_:)), "Volume down"),
                       rotateButton!,
                       button("Screenshot", #selector(screenshot(_:)), "Save a screenshot on the Mac (⌘S)")]
        let bar = NSStackView(views: buttons)
        bar.spacing = 4
        bar.translatesAutoresizingMaskIntoConstraints = false
        statusLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        statusLabel.lineBreakMode = .byTruncatingTail
        statusLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        rateLabel.font = .monospacedDigitSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
        rateLabel.textColor = .secondaryLabelColor
        rateLabel.alignment = .right
        rateLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let status = NSStackView(views: [statusLabel, rateLabel])
        status.translatesAutoresizingMaskIntoConstraints = false
        let footer = NSStackView(views: [bar, status])
        footer.orientation = .vertical
        footer.alignment = .leading
        footer.spacing = 0
        footer.translatesAutoresizingMaskIntoConstraints = false
        // The bar scrolls off narrow windows rather than squeezing the screen.
        footer.setClippingResistancePriority(.defaultLow, for: .horizontal)
        content.addSubview(footer)
        NSLayoutConstraint.activate([
            deviceView.topAnchor.constraint(equalTo: content.topAnchor),
            deviceView.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            deviceView.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            deviceView.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -Self.barHeight * 2),
            footer.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 6),
            footer.trailingAnchor.constraint(lessThanOrEqualTo: content.trailingAnchor, constant: -6),
            status.widthAnchor.constraint(equalTo: content.widthAnchor, constant: -12),
            footer.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -3),
        ])
    }

    var footerHeight: CGFloat { Self.barHeight * 2 }
    var statusIsLive: Bool { phase == "live" }

    /// Sizes the window so the device shows at `z` view points per device point.
    func applyZoom(_ z: CGFloat) {
        zoom = z
        let size = deviceView.pointSize
        let content = NSSize(width: (size.width * z).rounded(), height: (size.height * z).rounded() + footerHeight)
        window.setContentSize(content)
        window.contentMinSize = NSSize(width: 200, height: 200 * size.height / size.width + footerHeight)
    }

    /// Resizing keeps the device's aspect ratio (the bar below has a fixed height).
    func windowWillResize(_ sender: NSWindow, to frameSize: NSSize) -> NSSize {
        let size = deviceView.pointSize
        let content = sender.contentRect(forFrameRect: NSRect(origin: .zero, size: frameSize))
        let width = max(200, content.width.rounded())
        let height = (width * size.height / size.width).rounded() + footerHeight
        return sender.frameRect(forContentRect: NSRect(x: 0, y: 0, width: width, height: height)).size
    }

    func windowDidResize(_ notification: Notification) {
        let w = deviceView.bounds.width
        if w > 0 { zoom = w / deviceView.pointSize.width }
    }

    func windowDidResignKey(_ notification: Notification) { deviceView.cancelInput() }

    func windowWillClose(_ notification: Notification) { NSApp.terminate(nil) }

    // MARK: Status

    private func updateStatus() {
        var text: String
        switch phase {
        case "connecting": text = "Connecting to \(connection.address)…" + (phaseDetail.map { " (\($0))" } ?? "")
        case "disconnected": text = "Disconnected" + (phaseDetail.map { ": \($0)" } ?? "") + "; reconnecting"
        case "booting": text = "Booting… \(uptime / 1000) s"
        case "live": text = hasImage ? "Live" : "Live (waiting for the first frame)"
        case "stopping": text = "The device is shutting down"
        default: text = phase
        }
        if let h = hello, phase == "live" || phase == "booting" {
            text += " · \(h.deviceName) \(h.pixelWidth)×\(h.pixelHeight)"
            if !h.touch { text += " · input not delivered yet" }
        }
        statusLabel.stringValue = text
        let now = nowNanoseconds()
        let fps = frameTimes.filter { now - $0 < 1_000_000_000 }.count
        var rate = "\(fps) fps · " + String(format: "%.0f KB/s", bandwidth / 1000)
        if let lastLatency { rate += String(format: " · input→screen %.0f ms", lastLatency) }
        if let rtt { rate += String(format: " · rtt %.0f ms", rtt) }
        rateLabel.stringValue = rate
    }

    private func tick() {
        let now = nowNanoseconds()
        let bytes = connection.stats.bytes
        bandwidth = Double(bytes - lastBytes) / (Double(now - lastStatsTime) / 1e9)
        lastBytes = bytes
        lastStatsTime = now
        frameTimes.removeAll { now - $0 > 1_000_000_000 }
        probes.removeAll { now - $0.sent > 5_000_000_000 }
        if phase == "live" || phase == "booting" { connection.ping() }
        updateStatus()
    }

    // MARK: ViewerConnectionDelegate

    func connection(_ c: ViewerConnection, phase: String, detail: String?) {
        self.phase = phase
        phaseDetail = detail
        if phase == "disconnected" { hasImage = false }
        updateStatus()
    }

    func connection(_ c: ViewerConnection, hello: DisplayServerHello) {
        self.hello = hello
        log("hello: \(hello.deviceName) \(hello.model) \(hello.pixelWidth)x\(hello.pixelHeight) @\(hello.scale), encodings \(hello.encodings), "
            + "touch \(hello.touch), keyboard \(hello.keyboard), buttons \(hello.buttons)")
        let size = CGSize(width: hello.pointWidth, height: hello.pointHeight)
        if size != deviceView.pointSize {
            deviceView.pointSize = size
            applyZoom(zoom)
        }
        rotateButton.isEnabled = hello.rotation
        updateStatus()
    }

    func connection(_ c: ViewerConnection, status: DisplayStatus) {
        if phase != status.phase { log("phase: \(status.phase) at \(status.uptimeMilliseconds) ms" + (status.message.map { " (\($0))" } ?? "")) }
        phase = status.phase
        uptime = status.uptimeMilliseconds
        updateStatus()
    }

    func connection(_ c: ViewerConnection, image: CGImage, frame: DisplayFrame, receivedAt: UInt64) {
        deviceView.image = image
        if !hasImage { hasImage = true; log("first frame: \(frame.width)x\(frame.height), \(frame.byteCount) bytes") }
        frameTimes.append(nowNanoseconds())
        // Input → first visible change: the first frame read after the input arrived.
        if frame.inputSequence > 0 {
            let shown = nowNanoseconds()
            while let p = probes.first, p.seq <= frame.inputSequence {
                probes.removeFirst()
                let ms = Double(receivedAt - p.sent) / 1e6
                lastLatency = ms
                latencies.append((p.label, ms))
                // Received: the frame's bytes arrived; shown: decoded and handed to the layer.
                log(String(format: "latency: %@ (input #%u) → first change %.0f ms (shown %.0f ms)", p.label, p.seq, ms,
                           Double(shown - p.sent) / 1e6))
            }
        }
        onFrame?(frame)
    }

    func connection(_ c: ViewerConnection, notice: String) {
        log("notice: \(notice)")
        statusLabel.stringValue = notice
    }

    func connection(_ c: ViewerConnection, screenshot png: [UInt8], token: UInt32) {
        screenshotWaiters.removeValue(forKey: token)?(png)
    }

    func connection(_ c: ViewerConnection, pongToken token: UInt64, rttMilliseconds: Double) { rtt = rttMilliseconds }

    // MARK: DeviceInputHandler

    private func probe(_ seq: UInt32, _ label: String?) {
        guard seq != 0, let label else { return }
        probes.append((seq, nowNanoseconds(), label))
    }

    func sendTouch(_ contacts: [TouchContact], label: String?) {
        let seq = connection.sendInput { .touch(sequence: $0, contacts: contacts) }
        probe(seq, label)
    }

    func sendKey(usage: UInt16, down: Bool, label: String?) {
        let seq = connection.sendInput { .key(sequence: $0, down: down, usagePage: KeyMap.keyboardPage, usage: usage) }
        probe(seq, down ? label : nil)
    }

    func press(_ button: DisplayButton) {
        probe(connection.sendInput { .button(sequence: $0, button: button, down: true) }, button.name)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [self] in
            connection.sendInput { .button(sequence: $0, button: button, down: false) }
        }
    }

    // MARK: Actions

    @objc func home(_ sender: Any?) { press(.home) }
    @objc func lock(_ sender: Any?) { press(.lock) }
    @objc func volumeUp(_ sender: Any?) { press(.volumeUp) }
    @objc func volumeDown(_ sender: Any?) { press(.volumeDown) }
    @objc func rotate(_ sender: Any?) { connection.send(.rotate(orientation: 3)) }
    @objc func reconnect(_ sender: Any?) { connection.send(.keyframeRequest) }
    @objc func zoomHalf(_ sender: Any?) { applyZoom(0.5) }
    @objc func zoomPoint(_ sender: Any?) { applyZoom(1) }
    @objc func zoomPixel(_ sender: Any?) {
        applyZoom(CGFloat(hello?.scale ?? 3) / (window.backingScaleFactor > 0 ? window.backingScaleFactor : 2))
    }

    /// Requests a full-resolution PNG from the server (the shown image when
    /// that fails) and calls back with it.
    func requestScreenshot(_ done: @escaping ([UInt8]?) -> Void) {
        let token = nextScreenshot
        nextScreenshot += 1
        var answered = false
        screenshotWaiters[token] = { png in answered = true; done(png.isEmpty ? self.shownPNG() : png) }
        if !connection.send(.screenshotRequest(token: token)) {
            screenshotWaiters.removeValue(forKey: token)
            done(shownPNG())
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 10) { [self] in
            if !answered, screenshotWaiters.removeValue(forKey: token) != nil { done(shownPNG()) }
        }
    }

    func shownPNG() -> [UInt8]? {
        guard let image = deviceView.image else { return nil }
        let rep = NSBitmapImageRep(cgImage: image)
        return rep.representation(using: .png, properties: [:]).map { [UInt8]($0) }
    }

    @objc func screenshot(_ sender: Any?) {
        requestScreenshot { [self] png in
            guard let png else { NSSound.beep(); return }
            let f = DateFormatter()
            f.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
            let dir = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first
                ?? URL(fileURLWithPath: NSHomeDirectory())
            let url = dir.appendingPathComponent("Ycode Screenshot \(f.string(from: Date())).png")
            do {
                try Data(png).write(to: url)
                statusLabel.stringValue = "Saved \(url.lastPathComponent)"
                log("screenshot: \(url.path)")
            } catch {
                statusLabel.stringValue = "Cannot save the screenshot: \(error.localizedDescription)"
            }
        }
    }

    // MARK: Menus

    func buildMenu() -> NSMenu {
        let main = NSMenu()
        func item(_ title: String, _ action: Selector?, _ key: String = "", _ mods: NSEvent.ModifierFlags = [.command],
                  target: AnyObject? = nil) -> NSMenuItem {
            let i = NSMenuItem(title: title, action: action, keyEquivalent: key)
            i.keyEquivalentModifierMask = mods
            i.target = target ?? self
            return i
        }
        let appItem = NSMenuItem()
        let app = NSMenu(title: "Ycode Simulator Viewer")
        app.addItem(item("Hide", #selector(NSApplication.hide(_:)), "h", target: NSApp))
        app.addItem(.separator())
        app.addItem(item("Quit", #selector(NSApplication.terminate(_:)), "q", target: NSApp))
        appItem.submenu = app
        main.addItem(appItem)

        let fileItem = NSMenuItem()
        let file = NSMenu(title: "File")
        file.addItem(item("Save Screenshot", #selector(screenshot(_:)), "s"))
        file.addItem(item("Close", #selector(NSWindow.performClose(_:)), "w", target: window))
        fileItem.submenu = file
        main.addItem(fileItem)

        let deviceItem = NSMenuItem()
        let device = NSMenu(title: "Device")
        device.addItem(item("Home", #selector(home(_:)), "h", [.command, .shift]))
        device.addItem(item("Lock", #selector(lock(_:)), "l"))
        device.addItem(item("Volume Up", #selector(volumeUp(_:)), String(UnicodeScalar(NSUpArrowFunctionKey)!), [.command, .option]))
        device.addItem(item("Volume Down", #selector(volumeDown(_:)), String(UnicodeScalar(NSDownArrowFunctionKey)!), [.command, .option]))
        let rotateItem = item("Rotate Left", #selector(rotate(_:)), String(UnicodeScalar(NSLeftArrowFunctionKey)!))
        device.addItem(rotateItem)
        device.addItem(.separator())
        device.addItem(item("Refresh Display", #selector(reconnect(_:)), "r"))
        deviceItem.submenu = device
        main.addItem(deviceItem)

        let windowItem = NSMenuItem()
        let win = NSMenu(title: "Window")
        win.addItem(item("Half Size", #selector(zoomHalf(_:)), "1"))
        win.addItem(item("Point Accurate", #selector(zoomPoint(_:)), "2"))
        win.addItem(item("Pixel Accurate", #selector(zoomPixel(_:)), "3"))
        win.addItem(.separator())
        win.addItem(item("Minimize", #selector(NSWindow.performMiniaturize(_:)), "m", target: window))
        windowItem.submenu = win
        main.addItem(windowItem)
        return main
    }
}

extension ViewerController: NSMenuItemValidation {
    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        if item.action == #selector(rotate(_:)) { return hello?.rotation ?? false }
        return true
    }
}
#endif
