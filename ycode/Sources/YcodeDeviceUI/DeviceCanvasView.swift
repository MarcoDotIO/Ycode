// The canvas (device-hub.md §4): the device in Ycode's frame, centred, the
// device-control row under it, and the canvas's states — the live screen,
// the status view of a stopped simulator (its picture, name, OS and
// Start), the problems while the display connects, "No Selection",
// "Multiple Devices Selected" — plus the feedback banners ("Screenshot
// Saved", "Capturing Keyboard"), the hinge slider and the debug status
// line. Used by the compact window (the window's size sets the scale) and
// by the hub (Zoom to Fit, Actual Size, Zoom In / Out, scrolling when the
// device is larger than the canvas).

#if os(macOS)
import AppKit
import YcodeDeviceModel
import YcodeDisplayStream

/// A flipped plain view (scroll document, containers).
final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}

@MainActor
public final class DeviceCanvasView: NSView, DeviceLiveSessionObserver {
    public enum Mode { case compact, hub }
    public let mode: Mode

    public private(set) var session: DeviceLiveSession?
    /// The device drawn when there is no session (a stopped simulator).
    public private(set) var stoppedSpec: DeviceFrameSpec?
    public let frameView = DeviceFrameView(geometry: DeviceFrameGeometry(spec: .iPhoneDuo))
    public let controls = DeviceControlsRow()

    /// View ▸ Show / Hide Bezels.
    public var showsBezels = true { didSet { if showsBezels != oldValue { refreshGeometry() } } }
    /// The hub's zoom (§4.2); the compact window ignores it.
    public var zoom: DeviceZoomMode = .fit { didSet { if zoom != oldValue { needsLayout = true; onZoomChange?() } } }
    /// The debug status line (More Actions ▸ Show Frame Rate).
    public var showsStatistics = false { didSet { statsLabel.isHidden = !showsStatistics; updateStatistics() } }
    /// Space at the top taken by the window's toolbar (content under it).
    public var topInset: CGFloat = 0 { didSet { needsLayout = true } }
    /// Key equivalents of `DeviceCommand` are handled by the canvas (the
    /// IDE's windows); the viewer's menus have them instead.
    public var handlesKeyEquivalents = false
    /// A command the canvas cannot carry out itself (no session: the IDE's
    /// ssh path), or that its owner wants to see (zoom changes).
    public var commandFallback: ((DeviceCommand) -> Bool)?
    /// The status view's button (Start) was clicked.
    public var onAction: (() -> Void)?
    /// The geometry (panel, rotation, bezels) changed: the compact window reshapes.
    public var onGeometryChange: (() -> Void)?
    public var onZoomChange: (() -> Void)?
    /// Capture Keyboard changed (the toolbar toggle follows).
    public var onCaptureChange: ((Bool) -> Void)?

    private let scroll = NSScrollView()
    private let document = FlippedView()
    private let messageLabel = NSTextField(labelWithString: "")
    private let statusStack = NSStackView()
    private let statusName = NSTextField(labelWithString: "")
    private let statusOS = NSTextField(labelWithString: "")
    private let actionButton = NSButton(title: "Start", target: nil, action: nil)
    private let spinner = NSProgressIndicator()
    private let problemLabel = NSTextField(wrappingLabelWithString: "")
    private let statsLabel = NSTextField(labelWithString: "")
    private var banner: GlassCapsule?
    private let bannerLabel = NSTextField(labelWithString: "")
    private var bannerTimer: Timer?
    private var captureBanner: GlassCapsule?
    private var hingeCapsule: GlassCapsule?
    private let hingeSlider = NSSlider(value: 0, minValue: 0, maxValue: 180, target: nil, action: nil)
    private let hingeLabel = NSTextField(labelWithString: "0°")
    private var hingeStartAngle = 0
    private var message: String?
    private var statusAction: String?
    private var statusBusy = false

    public init(mode: Mode) {
        self.mode = mode
        super.init(frame: NSRect(x: 0, y: 0, width: 400, height: 700))
        wantsLayer = true
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = mode == .hub
        scroll.hasHorizontalScroller = mode == .hub
        scroll.autohidesScrollers = true
        scroll.documentView = document
        scroll.contentView.drawsBackground = false
        addSubview(scroll)
        document.addSubview(frameView)
        problemLabel.alignment = .center
        problemLabel.textColor = .white.withAlphaComponent(0.8)
        problemLabel.font = .systemFont(ofSize: 12)
        frameView.addSubview(problemLabel)
        messageLabel.textColor = .secondaryLabelColor
        messageLabel.font = .systemFont(ofSize: 15)
        messageLabel.alignment = .center
        addSubview(messageLabel)
        statusName.font = .systemFont(ofSize: 17, weight: .semibold)
        statusName.alignment = .center
        statusOS.textColor = .secondaryLabelColor
        statusOS.alignment = .center
        actionButton.bezelStyle = .push
        actionButton.controlSize = .large
        actionButton.target = self
        actionButton.action = #selector(actionClicked)
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false
        statusStack.orientation = .vertical
        statusStack.alignment = .centerX
        statusStack.spacing = 6
        for v in [statusName, statusOS, spinner, actionButton] { statusStack.addArrangedSubview(v) }
        statusStack.setCustomSpacing(14, after: statusOS)
        addSubview(statusStack)
        statsLabel.font = .monospacedDigitSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
        statsLabel.textColor = .secondaryLabelColor
        statsLabel.isHidden = true
        statsLabel.lineBreakMode = .byTruncatingTail
        addSubview(statsLabel)
        addSubview(controls)
        controls.onCommand = { [weak self] c in self?.perform(c) }
        controls.onHingeDrag = { [weak self] d in self?.hingeDrag(d) }
        frameView.onButton = { [weak self] kind, down in self?.frameButton(kind, down: down) }
        frameView.onHingeDrag = { [weak self] d in self?.hingeDrag(d) }
        frameView.screen.onCaptureCancelled = { [weak self] in self?.setCapturesKeyboard(false) }
        hingeSlider.isContinuous = true
        hingeSlider.target = self
        hingeSlider.action = #selector(hingeSlid(_:))
        hingeLabel.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        showMessage("No Selection")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    public override var isFlipped: Bool { true }

    // MARK: What is shown

    /// The live device.
    public func show(session s: DeviceLiveSession) {
        if session !== s {
            session?.removeObserver(self)
            session = s
            s.addObserver(self)
        }
        frameView.screen.input = s
        frameView.screen.image = s.image
        stoppedSpec = nil
        message = nil
        statusAction = nil
        refreshGeometry()
        refreshState()
    }

    /// A device that is not running: its picture, name, OS, and the action
    /// button (`action` nil: none; `busy`: a spinner instead, Q1).
    public func showStopped(spec: DeviceFrameSpec, name: String, os: String, action: String?, busy: Bool = false) {
        detachSession()
        stoppedSpec = spec
        message = nil
        statusName.stringValue = name
        statusOS.stringValue = busy ? "\(os) — Starting…" : os
        statusAction = action
        statusBusy = busy
        refreshGeometry()
        refreshState()
    }

    /// A centred message ("No Selection", "Multiple Devices Selected").
    public func showMessage(_ text: String) {
        detachSession()
        stoppedSpec = nil
        message = text
        refreshState()
    }

    private func detachSession() {
        session?.removeObserver(self)
        session = nil
        frameView.screen.input = nil
        frameView.screen.image = nil
        setCapturesKeyboard(false)
    }

    /// The canvas's current state, for tests: "message: …", "stopped",
    /// "live", "connecting: …".
    public var stateDescription: String {
        if let message { return "message: \(message)" }
        if stoppedSpec != nil { return statusBusy ? "starting" : "stopped" }
        if let s = session { return s.hasImage ? "live" : "connecting: \(s.problemText ?? "")" }
        return "empty"
    }

    private func refreshState() {
        let hasDevice = session != nil || stoppedSpec != nil
        messageLabel.stringValue = message ?? ""
        messageLabel.isHidden = message == nil
        scroll.isHidden = !hasDevice
        statusStack.isHidden = stoppedSpec == nil
        actionButton.title = statusAction ?? ""
        actionButton.isHidden = statusAction == nil || statusBusy
        if statusBusy { spinner.startAnimation(nil) } else { spinner.stopAnimation(nil) }
        controls.isHidden = session == nil
        let problem = session.flatMap { $0.hasImage ? nil : $0.problemText }
        problemLabel.stringValue = problem ?? ""
        problemLabel.isHidden = problem == nil
        if let s = session {
            controls.configure(.init(foldable: s.isFoldable, canRotate: s.canRotate, recording: s.isRecording, posture: s.posture,
                                     enabled: s.isLive, showsRotate: s.spec.family != .vision))
        }
        statsLabel.isHidden = !showsStatistics || session == nil
        updateStatistics()
        needsLayout = true
    }

    private func refreshGeometry() {
        let g: DeviceFrameGeometry
        if let s = session {
            g = s.frameGeometry(bezels: showsBezels)
            frameView.screen.pointSize = s.shownPointSize
            frameView.allowsHingeDrag = s.isFoldable
        } else if let spec = stoppedSpec {
            g = DeviceFrameGeometry(spec: spec, bezels: showsBezels)
            frameView.allowsHingeDrag = false
        } else {
            return
        }
        if g != frameView.geometry {
            frameView.geometry = g
            onGeometryChange?()
        }
        needsLayout = true
    }

    // MARK: DeviceLiveSessionObserver

    public func session(_ s: DeviceLiveSession, changed: DeviceSessionChange) {
        guard s === session else { return }
        switch changed {
        case .image:
            frameView.screen.image = s.image
            if !problemLabel.isHidden { refreshState() }
        case .hello, .displayState:
            frameView.screen.cancelInput()
            refreshGeometry()
            refreshState()
        case .phase:
            if s.phase == "disconnected", s.isRecording {
                s.stopRecording()
                showBanner("Screen recording was stopped because the device disconnected.", seconds: 4)
            }
            refreshState()
        case .recording:
            refreshState()
        case .notice(let text):
            showBanner(text, seconds: 3)
        case .statistics:
            updateStatistics()
        }
    }

    private func updateStatistics() {
        guard showsStatistics, let s = session else { return }
        statsLabel.stringValue = s.statisticsText
    }

    // MARK: Scale and layout

    /// The device's size in device points (frame included).
    public var deviceSize: CGSize { frameView.geometry.size }

    /// The area the device may take (the canvas less the control row).
    var deviceArea: CGRect {
        let b = bounds
        if mode == .compact { return CGRect(x: 0, y: topInset, width: b.width, height: max(1, b.height - topInset)) }
        let bottom = session != nil ? DeviceControlsRow.height + 2 * CompactWindowLayout.controlsGap : 0
        if stoppedSpec != nil { return CGRect(x: 0, y: topInset, width: b.width, height: max(1, (b.height - topInset) * 0.62)) }
        return CGRect(x: 0, y: topInset, width: b.width, height: max(1, b.height - topInset - bottom))
    }

    /// Points per inch of the screen the canvas is on (nil: unknown).
    var displayPointsPerInch: Double? {
        guard let screen = window?.screen ?? NSScreen.main,
              let n = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { return nil }
        let mm = CGDisplayScreenSize(CGDirectDisplayID(n.uint32Value))
        return DeviceZoom.displayPointsPerInch(pointWidth: Double(screen.frame.width), millimetresWide: Double(mm.width))
    }

    /// The scale used now (view points per device point).
    public var effectiveScale: Double {
        let size = deviceSize
        switch mode {
        case .compact:
            return CompactWindowLayout.scale(device: size, windowWidth: Double(bounds.width))
        case .hub:
            switch zoom {
            case .fit: return DeviceZoom.fit(size, in: deviceArea.size)
            case .scale(let s): return s
            case .actual:
                let spec = session?.spec ?? stoppedSpec ?? .iPhoneDuo
                let panel = spec.panels[min(session?.panelIndex ?? 0, spec.panels.count - 1)]
                return DeviceZoom.physical(panel: panel, displayPointsPerInch: displayPointsPerInch ?? 110)
            }
        }
    }

    public override func layout() {
        super.layout()
        let b = bounds
        messageLabel.sizeToFit()
        messageLabel.frame.origin = CGPoint(x: ((b.width - messageLabel.frame.width) / 2).rounded(),
                                            y: (topInset + (b.height - topInset - messageLabel.frame.height) / 2).rounded())
        let area = deviceArea
        let scale = stoppedSpec != nil ? DeviceZoom.fit(deviceSize, in: area.size, margin: 32) : effectiveScale
        frameView.scale = scale
        let size = CGSize(width: (deviceSize.width * scale).rounded(), height: (deviceSize.height * scale).rounded())
        scroll.frame = area
        let doc = CGSize(width: max(area.width, size.width + 2 * DeviceZoom.fitMargin), height: max(area.height, size.height + 2 * DeviceZoom.fitMargin))
        document.frame = CGRect(origin: .zero, size: doc)
        var origin = CGPoint(x: ((doc.width - size.width) / 2).rounded(), y: ((doc.height - size.height) / 2).rounded())
        if mode == .compact {
            origin = CGPoint(x: ((b.width - size.width) / 2).rounded(), y: CompactWindowLayout.topGap)
        }
        frameView.frame = CGRect(origin: origin, size: size)
        frameView.needsLayout = true
        let screenRect = frameView.screen.frame
        problemLabel.frame = screenRect.insetBy(dx: 12, dy: max(0, screenRect.height / 2 - 30))
        // The control row: under the device, inside the canvas.
        let cs = controls.intrinsicContentSize
        let deviceBottom = area.minY + min(area.height, origin.y + size.height - scroll.contentView.bounds.minY)
        var cy = deviceBottom + CompactWindowLayout.controlsGap
        cy = min(cy, b.height - CompactWindowLayout.bottomMargin - DeviceControlsRow.height)
        if mode == .compact { cy = b.height - CompactWindowLayout.bottomMargin - DeviceControlsRow.height }
        controls.frame = CGRect(x: ((b.width - cs.width) / 2).rounded(), y: cy.rounded(), width: cs.width, height: DeviceControlsRow.height)
        // The status view under the picture.
        if stoppedSpec != nil {
            let fs = statusStack.fittingSize
            statusStack.frame = CGRect(x: ((b.width - fs.width) / 2).rounded(), y: (area.maxY + 12).rounded(), width: fs.width, height: fs.height)
        }
        statsLabel.frame = CGRect(x: 10, y: b.height - 18, width: max(10, b.width - 20), height: 16)
        if let banner {
            let s = banner.fittingSize
            banner.frame = CGRect(x: ((b.width - s.width) / 2).rounded(), y: topInset + 12, width: s.width, height: 32)
        }
        if let captureBanner {
            let s = captureBanner.fittingSize
            captureBanner.frame = CGRect(x: ((b.width - s.width) / 2).rounded(), y: topInset + (banner == nil ? 12 : 50), width: s.width, height: 44)
        }
        if let hingeCapsule {
            let w: CGFloat = 220
            hingeCapsule.frame = CGRect(x: ((b.width - w) / 2).rounded(), y: controls.frame.minY - 44, width: w, height: 34)
        }
    }

    // MARK: Zoom

    public func zoomIn() { zoom = .scale(DeviceZoom.zoomIn(from: effectiveScale)) }
    public func zoomOut() { zoom = .scale(DeviceZoom.zoomOut(from: effectiveScale)) }
    public func zoomToFit() { zoom = .fit }
    public func zoomToActualSize() { zoom = .actual }

    // MARK: Commands

    /// Whether a command can be carried out now (menu validation).
    public func canPerform(_ c: DeviceCommand) -> Bool {
        guard let s = session else {
            switch c {
            case .zoomIn, .zoomOut, .zoomToFit, .physicalSize, .toggleBezels: return stoppedSpec != nil
            default: return false
            }
        }
        switch c {
        case .rotateLeft, .rotateRight: return s.isLive && s.canRotate
        case .poseClosed, .posePartiallyOpen, .poseOpen: return s.isLive && s.isFoldable
        case .actionButton: return s.isLive && s.spec.hasActionButton
        case .physicalSize: return s.spec.family != .vision
        case .toggleBezels: return s.spec.hasFrame
        case .zoomIn, .zoomOut, .zoomToFit, .captureKeyboard: return true
        case .start, .restart, .shutDown, .forceShutDown: return false
        default: return s.isLive
        }
    }

    /// Carries out a command (controls, menus, key equivalents).
    public func perform(_ c: DeviceCommand) {
        switch c {
        case .zoomIn: zoomIn(); return
        case .zoomOut: zoomOut(); return
        case .zoomToFit: zoomToFit(); return
        case .physicalSize: zoomToActualSize(); return
        case .toggleBezels: showsBezels.toggle(); return
        case .captureKeyboard: setCapturesKeyboard(!capturesKeyboard); return
        default: break
        }
        guard let s = session, s.isLive else {
            if commandFallback?(c) != true { NSSound.beep() }
            return
        }
        switch c {
        case .home: s.press(.home)
        case .lock: s.press(.lock)
        case .volumeUp: s.press(.volumeUp)
        case .volumeDown: s.press(.volumeDown)
        case .actionButton: s.press(.side)
        case .appSwitcher: s.appSwitcher()
        case .rotateLeft: s.rotate(left: true)
        case .rotateRight: s.rotate(left: false)
        case .poseClosed: s.fold(to: DevicePosture.closed.angle)
        case .posePartiallyOpen: s.fold(to: DevicePosture.halfOpen.angle)
        case .poseOpen: s.fold(to: DevicePosture.openFlat.angle)
        case .screenshot:
            s.saveScreenshot { [weak self] r in
                switch r {
                case .success: self?.showBanner("Screenshot Saved")
                case .failure(let e): self?.showBanner("Screenshot Failed: \(e.localizedDescription)", seconds: 4)
                }
            }
        case .recordScreen:
            if s.isRecording {
                s.stopRecording { [weak self] url in self?.showBanner(url == nil ? "Recording Failed" : "Recording Saved") }
            } else {
                do { try s.startRecording() } catch { showBanner("Cannot Record: \(error.localizedDescription)", seconds: 4) }
            }
        default:
            if commandFallback?(c) != true { NSSound.beep() }
        }
    }

    public override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard handlesKeyEquivalents, window?.isKeyWindow == true, !capturesKeyboard,
              let chars = event.charactersIgnoringModifiers else { return super.performKeyEquivalent(with: event) }
        var mods: DeviceKeyModifiers = []
        let f = event.modifierFlags
        if f.contains(.command) { mods.insert(.command) }
        if f.contains(.shift) { mods.insert(.shift) }
        if f.contains(.option) { mods.insert(.option) }
        if f.contains(.control) { mods.insert(.control) }
        // Shift changes the character of some keys ("S" for "s").
        guard let c = DeviceCommand.bound(to: chars, modifiers: mods), canPerform(c) else { return super.performKeyEquivalent(with: event) }
        perform(c)
        return true
    }

    private func frameButton(_ kind: DeviceFrameGeometry.ButtonKind, down: Bool) {
        guard let s = session, s.isLive else {
            if !down {
                let c: DeviceCommand = kind == .volumeUp ? .volumeUp : kind == .volumeDown ? .volumeDown : kind == .action ? .actionButton : .lock
                if commandFallback?(c) != true { NSSound.beep() }
            }
            return
        }
        let b = DeviceLiveSession.displayButton(for: kind)
        if down { s.buttonDown(b) } else { s.buttonUp(b) }
    }

    @objc private func actionClicked() { onAction?() }

    // MARK: Keyboard capture

    public private(set) var capturesKeyboard = false

    /// Capture Keyboard (§4.6): keys, shortcuts included, go to the device
    /// while on; a notice says so; holding Escape ends it.
    public func setCapturesKeyboard(_ on: Bool) {
        let on = on && session != nil
        guard on != capturesKeyboard else { return }
        capturesKeyboard = on
        frameView.screen.capturesKeyboard = on
        if on {
            window?.makeFirstResponder(frameView.screen)
            let title = NSTextField(labelWithString: "Capturing Keyboard")
            title.font = .systemFont(ofSize: 12, weight: .semibold)
            let sub = NSTextField(labelWithString: "Hold Escape to cancel")
            sub.font = .systemFont(ofSize: 11)
            sub.textColor = .secondaryLabelColor
            let stack = NSStackView(views: [title, sub])
            stack.orientation = .vertical
            stack.spacing = 1
            stack.edgeInsets = NSEdgeInsets(top: 0, left: 10, bottom: 0, right: 10)
            let c = GlassCapsule(content: stack, height: 44)
            c.identifier = .init("capture-banner")
            captureBanner?.removeFromSuperview()
            captureBanner = c
            addSubview(c)
        } else {
            captureBanner?.removeFromSuperview()
            captureBanner = nil
        }
        needsLayout = true
        onCaptureChange?(on)
    }

    /// The capture notice is shown (tests).
    public var showsCaptureNotice: Bool { captureBanner != nil }

    // MARK: Banners

    /// The feedback banner's text (tests; nil: none shown).
    public var bannerText: String? { banner == nil ? nil : bannerLabel.stringValue }

    /// A glass banner over the top of the canvas for a few seconds (Q9,
    /// Ycode decision: "Screenshot Saved" this way).
    public func showBanner(_ text: String, seconds: TimeInterval = 2) {
        bannerTimer?.invalidate()
        banner?.removeFromSuperview()
        bannerLabel.stringValue = text
        bannerLabel.font = .systemFont(ofSize: 12, weight: .medium)
        bannerLabel.lineBreakMode = .byTruncatingTail
        let box = NSStackView(views: [bannerLabel])
        box.edgeInsets = NSEdgeInsets(top: 0, left: 12, bottom: 0, right: 12)
        let c = GlassCapsule(content: box, height: 32)
        c.identifier = .init("feedback-banner")
        banner = c
        addSubview(c)
        needsLayout = true
        bannerTimer = Timer.scheduledTimer(withTimeInterval: seconds, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.banner?.removeFromSuperview()
                self?.banner = nil
            }
        }
    }

    // MARK: The hinge slider (Option-drag, §4.4; Q12: it shows the angle)

    /// Points of drag per degree.
    static let pointsPerDegree: CGFloat = 1.2

    /// The slider is shown (tests).
    public var showsHingeSlider: Bool { hingeCapsule != nil }

    func hingeDrag(_ d: CGFloat?) {
        guard let s = session, s.isFoldable else { return }
        guard let d else {
            // Released: the hinge sweeps to the angle.
            s.fold(to: hingeSlider.integerValue)
            hingeCapsule?.removeFromSuperview()
            hingeCapsule = nil
            return
        }
        if hingeCapsule == nil {
            hingeStartAngle = s.hingeTarget ?? 0
            let stack = NSStackView(views: [hingeSlider, hingeLabel])
            stack.edgeInsets = NSEdgeInsets(top: 0, left: 12, bottom: 0, right: 12)
            hingeSlider.widthAnchor.constraint(equalToConstant: 140).isActive = true
            let c = GlassCapsule(content: stack, height: 34)
            c.identifier = .init("hinge-slider")
            hingeCapsule = c
            addSubview(c)
            needsLayout = true
        }
        let angle = min(180, max(0, hingeStartAngle + Int((d / Self.pointsPerDegree).rounded())))
        hingeSlider.integerValue = angle
        hingeLabel.stringValue = "\(angle)°"
    }

    @objc private func hingeSlid(_ sender: NSSlider) { hingeLabel.stringValue = "\(sender.integerValue)°" }
}
#endif
