import AppKit
import YcodeSimFeatures

/// The settings of a Ycode remote simulator as the details pane shows them
/// (the `settings` answer of its control socket).
public struct DeviceSettingsSnapshot: Equatable, Sendable {
    public var state: SimSettingsState
    public var volume: Int
    public var output: String
    public var input: String

    /// From a `settings` reply ("ok appearance light\n…\nvolume 60\noutput system\ninput system\n…").
    public init?(reply: String) {
        let text = reply.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.hasPrefix("ok") else { return nil }
        let lines = text.dropFirst(2).trimmingCharacters(in: .whitespaces).split(separator: "\n").map {
            $0.trimmingCharacters(in: .whitespaces)
        }
        func v(_ k: String) -> String? { lines.first { $0.hasPrefix(k + " ") }.map { String($0.dropFirst(k.count + 1)) } }
        state = SimSettingsState(lines: lines)
        volume = Int(v("volume") ?? "") ?? SimAudio.defaultVolume
        output = v("output") ?? "system"
        input = v("input") ?? "system"
    }
}

/// Devices and Simulators: the settings of a running Ycode simulator
/// (`specs/ide/devices.md` §Settings; `specs/simulator/simulator-features.md`
/// §7.1 and "Ycode implementation"). Three boxes under the details, as in
/// the reference's inspector: Appearance, Liquid Glass, Color Filter, Text
/// Size and the five switches; Location; Sound, Output, Input. Each change
/// is one control command through ssh (`ycode-sim --device DEV --control
/// ui|accessibility|location|audio …`); a failure shows an alert titled as
/// the reference's ("Failed to Set Appearance", …).
extension DevicesController {
    public static let settingsStoppedMessage = "Start the simulator to customize behavior and appearance."

    /// Shown for Ycode's remote simulator rows…
    public var settingsControlsShown: Bool { selected?.isYcodeRemote == true }
    /// …and working while the row's device runs.
    public var settingsControlsEnabled: Bool { settingsControlsShown && selected?.state == "Booted" && deviceSettings != nil }

    /// Reads the device's settings.
    @discardableResult
    public func refreshSettings() -> Task<Void, Never>? {
        guard settingsControlsEnabled, settingsTask == nil, let row = selected, let deviceSettings else { return nil }
        let task = Task { [weak self] in
            let (ok, reply) = await deviceSettings(row, ["settings"])
            guard let self else { return }
            if ok, self.selected?.identifier == row.identifier { self.settingsSnapshot = DeviceSettingsSnapshot(reply: reply) }
            self.settingsTask = nil
            if self.isViewLoaded, self.selected?.identifier == row.identifier { self.showDetails() }
        }
        settingsTask = task
        return task
    }

    /// Sends one settings command; a failure shows `failureTitle`'s alert;
    /// the settings are read again afterwards.
    @discardableResult
    public func applySetting(_ words: [String], failureTitle: String) -> Task<Void, Never>? {
        guard settingsControlsEnabled, let row = selected, let deviceSettings else { return nil }
        let task = Task { [weak self] in
            let (ok, reply) = await deviceSettings(row, words)
            guard let self else { return }
            if !ok || !reply.hasPrefix("ok") {
                self.presentSettingsFailure(failureTitle, reply.hasPrefix("error: ") ? String(reply.dropFirst(7)) : reply)
            }
            let (rok, state) = await deviceSettings(row, ["settings"])
            if rok, self.selected?.identifier == row.identifier { self.settingsSnapshot = DeviceSettingsSnapshot(reply: state) }
            self.settingsTask = nil
            if self.isViewLoaded, self.selected?.identifier == row.identifier { self.showDetails() }
        }
        settingsTask = task
        return task
    }

    static func runSettingsFailureAlert(_ title: String, _ message: String) {
        let a = NSAlert()
        a.messageText = title
        a.informativeText = message
        a.addButton(withTitle: "OK")
        a.runModal()
    }

    // MARK: Actions

    @objc func appearanceChosen(_ sender: NSPopUpButton) {
        applySetting(["ui", "appearance", sender.indexOfSelectedItem == 1 ? "dark" : "light"], failureTitle: "Failed to Set Appearance")
    }
    @objc func liquidGlassMoved(_ sender: NSSlider) {
        applySetting(["ui", "liquid-glass", String(format: "%.2f", sender.doubleValue)], failureTitle: "Failed to Set Liquid Glass")
    }
    @objc func colorFilterChosen(_ sender: NSPopUpButton) {
        let f = ColorFilter.allCases[max(0, sender.indexOfSelectedItem)]
        applySetting(["ui", "color-filter", f.rawValue], failureTitle: "Failed to Set Color Filter")
    }
    @objc func textSizeMoved(_ sender: NSSlider) {
        let size = ContentSize.allCases[min(11, max(0, sender.integerValue))]
        applySetting(["ui", "content_size", size.rawValue], failureTitle: "Failed to Set Text Size")
    }
    @objc func accessibilitySwitched(_ sender: NSSwitch) {
        let s = AccessibilitySwitch.allCases[sender.tag]
        applySetting(["accessibility", s.rawValue, sender.state == .on ? "on" : "off"], failureTitle: "Failed to Set \(s.title)")
    }
    @objc func locationChosen(_ sender: NSPopUpButton) {
        guard let item = sender.selectedItem, let words = item.representedObject as? [String], let row = selected else { return }
        if words == ["custom"] {
            guard let c = Self.askCustomCoordinates() else { showDetails(); return }
            chosenLocations[row.identifier] = "Custom (\(c))"
            applySetting(["location", "set", c.description], failureTitle: "Failed to Set Location")
            return
        }
        chosenLocations[row.identifier] = item.title
        applySetting(["location"] + words, failureTitle: "Failed to Set Location")
    }
    @objc func volumeMoved(_ sender: NSSlider) {
        applySetting(["audio", "volume", String(sender.integerValue)], failureTitle: "Failed to Set Volume")
    }
    @objc func outputChosen(_ sender: NSPopUpButton) {
        guard let v = sender.selectedItem?.representedObject as? String else { return }
        applySetting(["audio", "output", v], failureTitle: "Failed to Set Output")
    }
    @objc func inputChosen(_ sender: NSPopUpButton) {
        guard let v = sender.selectedItem?.representedObject as? String else { return }
        applySetting(["audio", "input", v], failureTitle: "Failed to Set Input")
    }

    static func askCustomCoordinates() -> Coordinate? {
        let alert = NSAlert()
        alert.messageText = "Custom Coordinates"
        alert.informativeText = "Enter a latitude and a longitude in degrees."
        let lat = NSTextField(string: ""), lon = NSTextField(string: "")
        lat.placeholderString = "Latitude"
        lon.placeholderString = "Longitude"
        let stack = NSStackView(views: [lat, lon])
        stack.orientation = .vertical
        stack.frame = NSRect(x: 0, y: 0, width: 220, height: 52)
        alert.accessoryView = stack
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        return Coordinate(argument: "\(lat.stringValue),\(lon.stringValue)")
    }

    /// The location pop-up's items (§7.1): title and the command's words.
    public static var locationChoices: [(title: String, words: [String]?)] {
        var out: [(String, [String]?)] = [("None", ["clear"]), ("-", nil)]
        out += SimLocation.presets.map { ($0.name, ["set", $0.coordinate.description]) }
        out += [("-", nil), ("Trips", nil)]
        out += SimLocation.builtInScenarios.filter { $0 != "Apple" }.map { ($0, ["run", $0]) }
        out += [("-", nil), ("Apple", ["run", "Apple"]), ("-", nil), ("Custom Coordinates…", ["custom"])]
        return out
    }

    // MARK: The controls

    /// The three settings boxes (or the stopped message).
    func settingsControls() -> NSView {
        guard settingsControlsEnabled else {
            let l = NSTextField(wrappingLabelWithString: Self.settingsStoppedMessage)
            l.textColor = .secondaryLabelColor
            l.identifier = .init("settings-stopped")
            return l
        }
        let snap = settingsSnapshot
        let enabled = snap != nil && settingsTask == nil
        func row(_ symbol: String, _ title: String, _ control: NSView) -> [NSView] {
            let image = NSImageView(image: NSImage(systemSymbolName: symbol, accessibilityDescription: title) ?? NSImage())
            image.contentTintColor = .secondaryLabelColor
            let label = NSTextField(labelWithString: title)
            label.font = .systemFont(ofSize: 12)
            if let c = control as? NSControl { c.isEnabled = enabled; c.setAccessibilityLabel(title) }
            return [image, label, control]
        }
        func popup(_ titles: [String], selected: Int, action: Selector) -> NSPopUpButton {
            let p = NSPopUpButton(frame: .zero, pullsDown: false)
            p.addItems(withTitles: titles)
            p.selectItem(at: selected)
            p.target = self
            p.action = action
            p.controlSize = .small
            return p
        }
        func box(_ rows: [[NSView]], id: String) -> NSView {
            let grid = NSGridView(views: rows)
            grid.rowSpacing = 6
            grid.columnSpacing = 8
            grid.column(at: 0).width = 18
            grid.column(at: 1).xPlacement = .leading
            let b = NSBox()
            b.titlePosition = .noTitle
            b.contentView = grid
            b.identifier = .init(id)
            return b
        }
        let st = snap?.state ?? SimSettingsState()
        let appearance = popup(Appearance.allCases.map(\.title), selected: st.appearance == .dark ? 1 : 0, action: #selector(appearanceChosen(_:)))
        let glass = NSSlider(value: st.glassOpacity ?? 0, minValue: 0, maxValue: 1, target: self, action: #selector(liquidGlassMoved(_:)))
        glass.isContinuous = false
        glass.toolTip = "Liquid Glass opacity: translucent … opaque"
        let filter = popup(ColorFilter.allCases.map(\.title), selected: ColorFilter.allCases.firstIndex(of: st.colorFilter) ?? 0,
                           action: #selector(colorFilterChosen(_:)))
        let text = NSSlider(value: Double(st.contentSize.index), minValue: 0, maxValue: 11, target: self, action: #selector(textSizeMoved(_:)))
        text.numberOfTickMarks = 12
        text.allowsTickMarkValuesOnly = true
        text.isContinuous = false
        text.toolTip = st.contentSize.title
        var first: [[NSView]] = [row("circle.lefthalf.filled", "Appearance", appearance), row("drop", "Liquid Glass", glass),
                                 row("camera.filters", "Color Filter", filter), row("textformat.size", "Text Size", text)]
        let symbols: [AccessibilitySwitch: String] = [.reduceMotion: "circle.dotted.and.circle", .increaseContrast: "circle.righthalf.filled",
                                                      .showBorders: "square.dashed", .reduceTransparency: "square.on.square.intersection.dashed",
                                                      .voiceOver: "speaker.wave.2.bubble"]
        for (i, s) in AccessibilitySwitch.allCases.enumerated() {
            let sw = NSSwitch()
            sw.state = st.isOn(s) ? .on : .off
            sw.tag = i
            sw.target = self
            sw.action = #selector(accessibilitySwitched(_:))
            sw.controlSize = .small
            first.append(row(symbols[s] ?? "circle", s.title, sw))
        }
        let location = NSPopUpButton(frame: .zero, pullsDown: false)
        location.controlSize = .small
        location.autoenablesItems = false
        for c in Self.locationChoices {
            if c.title == "-" { location.menu?.addItem(.separator()); continue }
            let item = NSMenuItem(title: c.title, action: nil, keyEquivalent: "")
            item.representedObject = c.words
            item.isEnabled = c.words != nil
            location.menu?.addItem(item)
        }
        let chosen = selected.flatMap { chosenLocations[$0.identifier] } ?? "None"
        if let i = location.itemArray.firstIndex(where: { $0.title == chosen }) { location.selectItem(at: i) }
        location.target = self
        location.action = #selector(locationChosen(_:))
        let volume = NSSlider(value: Double(snap?.volume ?? SimAudio.defaultVolume), minValue: 0, maxValue: 100, target: self,
                              action: #selector(volumeMoved(_:)))
        volume.isContinuous = false
        func audioPopup(_ devices: [(uid: String, name: String)], current: String, action: Selector) -> NSPopUpButton {
            let p = NSPopUpButton(frame: .zero, pullsDown: false)
            p.controlSize = .small
            for (title, value) in [("None", "none"), ("System", "system")] + devices.map({ ($0.name, $0.uid) }) {
                let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
                item.representedObject = value
                p.menu?.addItem(item)
            }
            p.selectItem(at: p.itemArray.firstIndex { ($0.representedObject as? String) == current } ?? 1)
            p.target = self
            p.action = action
            return p
        }
        let output = audioPopup(SimAudio.outputDevices, current: snap?.output ?? "system", action: #selector(outputChosen(_:)))
        let input = audioPopup(SimAudio.inputDevices, current: snap?.input ?? "system", action: #selector(inputChosen(_:)))
        let stack = NSStackView(views: [
            box(first, id: "settings-appearance"),
            box([row("location", "Location", location)], id: "settings-location"),
            box([row("speaker.wave.2", "Sound", volume), row("hifispeaker", "Output", output), row("mic", "Input", input)], id: "settings-sound"),
        ])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.identifier = .init("settings-controls")
        if snap == nil {
            let reading = NSTextField(labelWithString: "Reading the device’s settings…")
            reading.textColor = .secondaryLabelColor
            stack.insertArrangedSubview(reading, at: 0)
        }
        // The boxes can be taller than the pane: they scroll.
        let scroll = NSScrollView()
        scroll.documentView = stack
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        stack.translatesAutoresizingMaskIntoConstraints = false
        scroll.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
            stack.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
            stack.trailingAnchor.constraint(equalTo: scroll.contentView.trailingAnchor),
            scroll.widthAnchor.constraint(equalToConstant: Self.settingsPaneWidth),
            scroll.heightAnchor.constraint(lessThanOrEqualToConstant: 520),
            scroll.heightAnchor.constraint(equalTo: stack.heightAnchor).withPriority(.defaultLow),
        ])
        scroll.identifier = .init("settings-scroll")
        return scroll
    }
}
