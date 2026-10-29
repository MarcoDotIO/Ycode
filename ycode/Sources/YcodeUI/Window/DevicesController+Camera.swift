import AppKit

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

    /// The Camera box of the Settings tab (laid out as FEAT-IMPL's boxes:
    /// symbol, label, control; the note below).
    func cameraControls() -> NSView {
        let image = NSImageView(image: NSImage(systemSymbolName: "camera", accessibilityDescription: "Camera") ?? NSImage())
        image.contentTintColor = .secondaryLabelColor
        let label = NSTextField(labelWithString: "Camera")
        label.font = .systemFont(ofSize: 12)
        let popUp = NSPopUpButton(frame: .zero, pullsDown: false)
        popUp.addItems(withTitles: Self.cameraTitles)
        popUp.selectItem(withTitle: cameraTitle)
        popUp.target = self
        popUp.action = #selector(cameraChosen(_:))
        popUp.controlSize = .small
        popUp.setAccessibilityLabel("Camera")
        popUp.toolTip = RemoteSimulatorSettings.cameraHelp
        let note = NSTextField(wrappingLabelWithString: Self.cameraNote)
        note.font = .systemFont(ofSize: 11)
        note.textColor = .secondaryLabelColor
        let grid = NSGridView(views: [[image, label, popUp], [NSGridCell.emptyContentView, NSGridCell.emptyContentView, note]])
        grid.rowSpacing = 6
        grid.columnSpacing = 8
        grid.column(at: 0).width = 18
        grid.column(at: 1).xPlacement = .leading
        let box = NSBox()
        box.titlePosition = .noTitle
        box.contentView = grid
        box.identifier = .init("camera-controls")
        return box
    }
}
