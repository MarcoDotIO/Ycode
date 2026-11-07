import AppKit
import YcodeIDECore

/// Device Hub's pairing actions for Ycode's remote simulators
/// (`specs/simulator/device-pairing.md` P-8, §13): each is one `ycode-sim`
/// pairing command through ssh (`RemoteSimulator.pairCommand`,
/// `unpairCommand`, `activateCommand`), its output in the console, then the
/// pairs are read again (`list-pairs --json`, `RemotePairsStore`), which
/// also relists the phone-with-watch run destinations.
extension WorkspaceWindowController {
    func configureRemotePairing(_ c: DevicesController, defaults: UserDefaults, ssh: String?) {
        func settings() -> RemoteSimulatorSettings {
            var s = RemoteSimulatorSettings.load(defaults)
            if let ssh { s.ssh = ssh }
            return s
        }
        func remote(_ row: DeviceRow) -> RemoteSimulator? {
            let s = settings()
            return RemoteSimulator.hub(s).first { "\(s.destination):\($0.remoteDevicePath)" == row.identifier }
        }
        let store = RemotePairsStore.shared
        store.defaults = defaults
        let p = c.pairing
        p.pairs = store.current()
        p.readPairs = {
            let s = settings()
            guard s.isConfigured else { return nil }
            return await store.refresh(RemoteSimulator(settings: s)) ? store.current() : nil
        }
        p.runtimeChoices = { platform in
            let s = settings()
            return s.runtimeRoots(platform: platform).compactMap { root, version in
                let types = s.newDeviceTypes(platform: platform, root: root).map { HubRuntimeChoice.TypeChoice(id: $0.id, name: $0.name) }
                return types.isEmpty ? nil : HubRuntimeChoice(root: root, title: "\(platform) \(version ?? "")".trimmingCharacters(in: .whitespaces), types: types)
            }
        }
        p.createDevice = { [weak c] name, typeID, root in
            guard let type = YcodeSimulatorDeviceType.named(typeID) else { return nil }
            let created = RemoteSimulatorSettings.createDevice(name: name, type: type, runtimeRoot: root, defaults)
            c?.reloadRemoteRows()
            let s = settings()
            return RemoteSimulator.hub(s).first { $0.deviceDirectoryName == created.directoryName }.map { DeviceRow.ycodeRemote($0, running: false) }
        }
        p.pairDevices = { [weak self] phoneRow, watchRow in
            guard let phone = remote(phoneRow), let watch = remote(watchRow) else { return (false, "Set the remote simulator in Settings ▸ Components ▸ Simulator Host first.") }
            self?.session.appendConsole("Ycode: pairing \(watchRow.name) with \(phoneRow.name)\n", kind: .debugger)
            let (status, out) = await Task.detached { phone.runPairing(phone.pairCommand(watch: watch)) }.value
            let text = out.trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty { self?.session.appendConsole(text + "\n", kind: .debugger) }
            guard status == 0, let id = RemoteSimulator.pairID(fromPairOutput: text) else {
                return (false, text.split(separator: "\n").last.map(String.init) ?? "ycode-sim pair failed (\(status))")
            }
            return (true, "Paired (\(id))")
        }
        p.unpairPair = { [weak self] pair in
            let s = settings()
            let r = RemoteSimulator(settings: s)
            self?.session.appendConsole("Ycode: unpairing \(pair.id) (the watch is shut down and erased)\n", kind: .debugger)
            let (status, out) = await Task.detached { r.runPairing(r.unpairCommand(pair.id)) }.value
            let text = out.trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty { self?.session.appendConsole(text + "\n", kind: .debugger) }
            return status == 0 ? (true, text.contains("erased") ? "Unpaired; the watch was erased" : "Unpaired")
                : (false, text.split(separator: "\n").last.map(String.init) ?? "ycode-sim unpair failed (\(status))")
        }
        p.activatePair = { [weak self] pair in
            let r = RemoteSimulator(settings: settings())
            let (status, out) = await Task.detached { r.runPairing(r.activateCommand(pair.id)) }.value
            let text = out.trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty { self?.session.appendConsole(text + "\n", kind: .debugger) }
            return status == 0 ? (true, "Active") : (false, text.split(separator: "\n").last.map(String.init) ?? "ycode-sim pair-activate failed (\(status))")
        }
        p.deleteDevice = { [weak self, weak c] row in
            guard let r = remote(row), let dir = row.deviceDirectory else { return (false, "Unknown device") }
            if RemoteDeviceSessions.shared.isRunning(r) { return (false, "Shut \(row.name) down first.") }
            self?.session.appendConsole("Ycode: deleting \(row.name) (\(r.remoteDevicePath))\n", kind: .debugger)
            let (status, out) = await Task.detached { r.erase() }.value
            guard status == 0 else { return (false, "Erase failed (status \(status)): \(out.trimmingCharacters(in: .whitespacesAndNewlines))") }
            RemoteSimulatorSettings.removeCreatedDevice(directory: dir, defaults)
            c?.reloadRemoteRows()
            return (true, "Deleted")
        }
    }
}
