// The viewer's settings menus (specs/simulator/simulator-features.md §7.1,
// "Ycode implementation" §I.5): Accessibility, Appearance, Color Filter,
// Location and Sound items of the Device menu, in the order and with the
// labels of §7.1. Each item sends one control command over the display
// stream (0x90) and shows the answer in the status line; the menus' check
// marks come from the device's `settings` answer, read when the Device menu
// opens.

#if os(macOS)
import AppKit
import YcodeSimFeatures

@MainActor
public final class ViewerSettingsMenu: NSObject, NSMenuDelegate, NSMenuItemValidation {
    /// Sends a command; the closure gets the answer.
    public let send: (String, @escaping @MainActor @Sendable (String) -> Void) -> Void
    /// Shows a result (the viewer's status line).
    public let report: (String) -> Void
    private(set) var state: SimSettingsState?
    private(set) var audio: (volume: Int, output: String, input: String)?

    public init(send: @escaping (String, @escaping @MainActor @Sendable (String) -> Void) -> Void, report: @escaping (String) -> Void) {
        self.send = send
        self.report = report
    }

    private func item(_ title: String, _ command: String?, key: String = "", mods: NSEvent.ModifierFlags = [.command]) -> NSMenuItem {
        let i = NSMenuItem(title: title, action: command == nil ? nil : #selector(run(_:)), keyEquivalent: key)
        i.keyEquivalentModifierMask = mods
        i.target = self
        i.representedObject = command
        return i
    }

    private func submenu(_ title: String, _ items: [NSMenuItem]) -> NSMenuItem {
        let i = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        let m = NSMenu(title: title)
        for x in items { m.addItem(x) }
        i.submenu = m
        return i
    }

    private func header(_ title: String) -> NSMenuItem {
        if #available(macOS 14.0, *) { return NSMenuItem.sectionHeader(title: title) }
        let i = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        i.isEnabled = false
        return i
    }

    /// The items, in §7.1's order: Accessibility ▸, Appearance ▸, Location ▸, Sound ▸ (and Ycode's Color Filter ▸).
    public func items() -> [NSMenuItem] {
        let accessibility = submenu("Accessibility", [
            item("Reduce Motion", "toggle reduce-motion"),
            item("Reduce Transparency", "toggle reduce-transparency"),
            item("Increase Contrast", "toggle increase-contrast"),
            item("Show Borders", "toggle show-borders"),
            item("Increase Text Size", "ui content_size increment", key: "+", mods: [.command, .option]),
            item("Decrease Text Size", "ui content_size decrement", key: "-", mods: [.command, .option]),
            item("VoiceOver", "toggle voiceover"),
        ])
        let appearance = submenu("Appearance", [
            item("Toggle Appearance", "ui appearance toggle", key: "a", mods: [.command, .shift]),
            .separator(),
            item("Light", "ui appearance light"),
            item("Dark", "ui appearance dark"),
        ])
        let filter = submenu("Color Filter", ColorFilter.allCases.map { item($0.title, "ui color-filter \($0.rawValue)") })
        var places: [NSMenuItem] = [item("None", "location clear"), .separator()]
        places += SimLocation.presets.map { item($0.name, "location set \($0.coordinate)") }
        places += [.separator(), header("Trips")]
        places += SimLocation.builtInScenarios.filter { $0 != "Apple" }.map { item($0, "location run \($0)") }
        places += [.separator(), item("Apple", "location run Apple"), .separator(), item("Custom Coordinates…", "custom-location")]
        let location = submenu("Location", places)
        var sound: [NSMenuItem] = [item("Increase Volume", "audio volume up"), item("Decrease Volume", "audio volume down"),
                                   .separator(), header("Input"), item("None", "audio input none"),
                                   item("Use System Settings", "audio input system")]
        sound += SimAudio.inputDevices.map { item($0.name, "audio input \($0.uid)") }
        sound += [.separator(), header("Output"), item("None", "audio output none"), item("Use System Settings", "audio output system")]
        sound += SimAudio.outputDevices.map { item($0.name, "audio output \($0.uid)") }
        return [accessibility, appearance, filter, location, submenu("Sound", sound)]
    }

    @objc func run(_ sender: NSMenuItem) {
        guard var command = sender.representedObject as? String else { return }
        if command == "custom-location" {
            guard let c = askCoordinates() else { return }
            command = "location set \(c)"
        }
        if command.hasPrefix("toggle ") {
            // A switch: the opposite of the device's state.
            let name = String(command.dropFirst(7))
            guard let s = AccessibilitySwitch(argument: name) else { return }
            command = "accessibility \(name) \(state?.isOn(s) == true ? "off" : "on")"
        }
        report("\(command)…")
        send(command) { [weak self] answer in
            self?.report(answer.hasPrefix("ok") ? "\(command): \(answer.dropFirst(2).trimmingCharacters(in: .whitespaces).isEmpty ? "done" : String(answer.dropFirst(3)))" : answer)
            self?.refresh()
        }
    }

    /// Reads the device's settings (check marks).
    public func refresh() {
        send("settings") { [weak self] answer in
            guard let self, answer.hasPrefix("ok ") else { return }
            let lines = answer.dropFirst(3).split(separator: "\n").map(String.init)
            self.state = SimSettingsState(lines: lines)
            func v(_ k: String) -> String? { lines.first { $0.hasPrefix(k + " ") }.map { String($0.dropFirst(k.count + 1)) } }
            self.audio = (Int(v("volume") ?? "") ?? 60, v("output") ?? "system", v("input") ?? "system")
        }
    }

    public func menuNeedsUpdate(_ menu: NSMenu) { refresh() }

    public func validateMenuItem(_ item: NSMenuItem) -> Bool { validate(item) }

    /// Check marks from the last `settings` answer.
    public func validate(_ item: NSMenuItem) -> Bool {
        guard let command = item.representedObject as? String else { return true }
        let st = state
        var on = false
        if command.hasPrefix("toggle "), let s = AccessibilitySwitch(argument: String(command.dropFirst(7))) {
            on = st?.isOn(s) ?? false
        } else if command == "ui appearance light" { on = st?.appearance == .light }
        else if command == "ui appearance dark" { on = st?.appearance == .dark }
        else if command.hasPrefix("ui color-filter ") { on = st.map { "ui color-filter \($0.colorFilter.rawValue)" == command } ?? false }
        else if command.hasPrefix("audio output ") { on = audio.map { "audio output \($0.output)" == command } ?? false }
        else if command.hasPrefix("audio input ") { on = audio.map { "audio input \($0.input)" == command } ?? false }
        item.state = on ? .on : .off
        return true
    }

    private func askCoordinates() -> String? {
        let alert = NSAlert()
        alert.messageText = "Custom Coordinates"
        alert.informativeText = "Enter the latitude and longitude in degrees."
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
        guard let c = Coordinate(argument: "\(lat.stringValue),\(lon.stringValue)") else {
            report("error: not a coordinate")
            return nil
        }
        return c.description
    }
}
#endif
