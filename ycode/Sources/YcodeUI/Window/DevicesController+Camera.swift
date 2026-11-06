import AppKit
import YcodeIDECore

/// Device Hub: the camera of Ycode's simulators (`specs/ide/devices.md`
/// §Camera; `specs/simulator/camera.md` "Ycode implementation"). A Ycode
/// simulator's Settings tab shows, under FEAT-IMPL's boxes, a Camera box
/// with a pop-up (Off, Host webcam, Synthetic pattern). It is the same
/// setting as Settings ▸ Simulators ▸ Camera, shared by Ycode's simulators,
/// and it applies when a device boots: the next run or start passes
/// `--camera <mode>` (and boots cold once, since the warm-boot fingerprint
/// includes it). It is shown whether or not the device runs.
extension DevicesController {
    public static let cameraTitles = ["Off", "Host webcam", "Synthetic pattern"]
    public static let cameraNote = "Applies the next time the simulator boots."

    /// The setting in `defaults` (the window passes the IDE's preferences).
    public static func cameraSetting(_ defaults: UserDefaults) -> (get: () -> String, set: (String) -> Void) {
        (get: { RemoteSimulatorSettings.load(defaults).camera },
         set: { mode in
             var s = RemoteSimulatorSettings.load(defaults)
             s.camera = mode
             s.cameraChosen = true
             s.save(defaults)
         })
    }

    /// Shown for Ycode's remote simulator rows when the window can read the setting.
    public var cameraControlsShown: Bool { selected?.isYcodeRemote == true && cameraSetting != nil }

    /// The setting's title ("Off", "Host webcam", "Synthetic pattern").
    public var cameraTitle: String {
        let mode = cameraSetting?.get() ?? "off"
        return RemoteSimulatorSettings.cameraModes.firstIndex(of: mode).map { Self.cameraTitles[$0] } ?? "Off"
    }

    /// Chooses a camera by its title; unknown titles are ignored.
    public func chooseCamera(_ title: String) {
        guard let i = Self.cameraTitles.firstIndex(of: title), let cameraSetting else { return }
        cameraSetting.set(RemoteSimulatorSettings.cameraModes[i])
        if isViewLoaded { updateInspector() }
    }

    @objc func cameraChosen(_ sender: NSPopUpButton) {
        if let title = sender.titleOfSelectedItem { chooseCamera(title) }
    }

    /// The Camera card of the Settings tab (as the settings cards: symbol,
    /// label, pop-up; device-hub.md §11.3), with its note under it.
    func cameraControls() -> NSView {
        let popUp = NSPopUpButton(frame: .zero, pullsDown: false)
        popUp.addItems(withTitles: Self.cameraTitles)
        popUp.selectItem(withTitle: cameraTitle)
        popUp.target = self
        popUp.action = #selector(cameraChosen(_:))
        popUp.isBordered = false
        popUp.setAccessibilityLabel("Camera")
        popUp.toolTip = RemoteSimulatorSettings.cameraHelp
        let card = InspectorCard(rows: [.init(symbol: "camera", title: "Camera", control: popUp)], identifier: "camera-card")
        let note = NSTextField(wrappingLabelWithString: Self.cameraNote)
        note.font = .systemFont(ofSize: 11)
        note.textColor = .secondaryLabelColor
        note.preferredMaxLayoutWidth = InspectorCard.width - 20
        let stack = NSStackView(views: [card, note])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 4
        stack.edgeInsets = NSEdgeInsets(top: 0, left: 0, bottom: 0, right: 0)
        stack.identifier = .init("camera-controls")
        return stack
    }
}
