import AppKit
import YcodeBuild
import YcodeIDECore

/// Runs on Ycode's remote simulators with a watch part (`specs/simulator/device-pairing.md`
/// P-9, §11.4, §13; `specs/ide/run.md` §Watch apps):
/// - a phone row: the iOS app on the phone; when the phone has an active
///   paired watch and the app embeds a watch app, that app is installed
///   directly on the watch too (not opened);
/// - a watch row (a watchOS scheme): the watch app built for the watchOS
///   simulator, installed and opened on the watch;
/// - a phone-with-watch row (a watchOS scheme): the companion iOS app is
///   built (its build builds the watch app), installed and launched on the
///   phone, then the watch app installed and opened on the phone's active
///   watch. Without an active paired watch the run fails with the
///   reference's texts (§11.4).
extension WorkspaceWindowController {
    /// The product of a build for a remote destination: an iOS app
    /// (`-iphonesimulator`) or a watch app (`-watchsimulator`).
    static func remoteProductPath(fromExecutablePath exe: String, watch: Bool) -> String {
        let path = simulatorAppPath(fromExecutablePath: exe)
        guard watch else { return path }
        return path.replacingOccurrences(of: "-iphonesimulator/", with: "-watchsimulator/")
    }

    /// The ssh program of remote runs when it is not `/usr/bin/ssh` (tests: a local stand-in).
    static var remoteSSHOverride: String?

    /// Builds (when asked) and runs on a Ycode remote destination.
    func runOnYcodeRemote(_ d: Destination, building: Bool) async {
        var settings = RemoteSimulatorSettings.load(Preferences.shared.defaults)
        if let ssh = Self.remoteSSHOverride { settings.ssh = ssh }
        let store = RemotePairsStore.shared
        let engine = session.engine
        if d.isYcodePairedDestination {
            let probe = RemoteSimulator(settings: settings, destination: d)
            await store.refresh(probe)
            guard let (phoneT, watchT) = settings.pairedTargets(for: d, pairs: store.current()) else {
                reportNoPairedWatch()
                return
            }
            let phone = RemoteSimulator(settings: settings, target: phoneT), watch = RemoteSimulator(settings: settings, target: watchT)
            let watchScheme = session.scheme ?? ""
            // The companion iOS app's scheme; a watch app without one runs on the watch alone.
            guard let companion = session.model.companionScheme(watchScheme: watchScheme) else {
                session.appendConsole("Ycode: no iOS app embeds \(watchScheme); running it on \(watch.destination.name) alone\n", kind: .debugger)
                await runWatchOnly(watch: watch, destination: watchT.destination, building: building)
                return
            }
            let iOSDestination = phone.destination
            var request = session.model.buildRequest(scheme: companion, destination: iOSDestination, action: .build)
            if building {
                let (result, r) = await session.build(scheme: companion, destination: iOSDestination)
                request = r
                guard result.status == .succeeded else { return }
            }
            guard let exe = await Task.detached(operation: { engine.executablePath(for: request) }).value else { return }
            let app = URL(fileURLWithPath: Self.remoteProductPath(fromExecutablePath: exe, watch: false))
            guard FileManager.default.fileExists(atPath: app.path) else { session.reportMissingProduct(app.path); return }
            guard let watchApp = RemoteSimulator.embeddedWatchApp(in: app) else {
                session.appendConsole("Ycode: \(app.lastPathComponent) has no watch app in Watch/\n")
                return
            }
            await session.runOnPairedRemoteSimulators(phone: phone, watch: watch,
                                                      plan: RemoteWatchRunPlan(iOSApp: app, watchApp: watchApp, launchWatchApp: true))
            return
        }
        let remote = RemoteSimulator(settings: settings, destination: d)
        if remote.isWatch {
            await runWatchOnly(watch: remote, destination: d, building: building)
            return
        }
        let request = session.model.buildRequest(scheme: session.scheme, destination: d, action: .build)
        if building {
            let result = await session.build(.build)
            guard result.status == .succeeded else { return }
        }
        guard let exe = await Task.detached(operation: { engine.executablePath(for: request) }).value else { return }
        let app = URL(fileURLWithPath: Self.remoteProductPath(fromExecutablePath: exe, watch: false))
        guard building || FileManager.default.fileExists(atPath: app.path) else { session.reportMissingProduct(app.path); return }
        // A phone with an active paired watch gets the embedded watch app on the watch (P-9).
        if let watchApp = RemoteSimulator.embeddedWatchApp(in: app), let phoneT = remote.target,
           let watchT = settings.pairedWatch(of: phoneT, pairs: store.current()) {
            await session.runOnPairedRemoteSimulators(phone: remote, watch: RemoteSimulator(settings: settings, target: watchT),
                                                      plan: RemoteWatchRunPlan(iOSApp: app, watchApp: watchApp, launchWatchApp: false))
            return
        }
        await session.runOnRemoteSimulator(app: app, remote: remote)
    }

    /// A watch app's run on a watch alone.
    private func runWatchOnly(watch: RemoteSimulator, destination: Destination, building: Bool) async {
        let request = session.model.buildRequest(scheme: session.scheme, destination: destination, action: .build)
        if building {
            let (result, _) = await session.build(scheme: session.scheme ?? session.model.displayName, destination: destination)
            guard result.status == .succeeded else { return }
        }
        let engine = session.engine
        guard let exe = await Task.detached(operation: { engine.executablePath(for: request) }).value else { return }
        let app = URL(fileURLWithPath: Self.remoteProductPath(fromExecutablePath: exe, watch: true))
        guard FileManager.default.fileExists(atPath: app.path) else { session.reportMissingProduct(app.path); return }
        await session.runOnRemoteWatch(app: app, watch: watch)
    }

    /// §11.4: the run of a watch app on a phone without an active paired
    /// watch: the reference's two texts, in the console and a sheet.
    func reportNoPairedWatch() {
        session.failRemoteRun("\(RemoteWatchRunError.noPairedWatch) \(RemoteWatchRunError.selectPairedPhone)")
        lastRunAlert = (RemoteWatchRunError.noPairedWatch, RemoteWatchRunError.selectPairedPhone)
        guard let window, window.isVisible, !Self.isTestProcess else { return }
        let alert = NSAlert()
        alert.messageText = RemoteWatchRunError.noPairedWatch
        alert.informativeText = RemoteWatchRunError.selectPairedPhone
        alert.beginSheetModal(for: window)
    }
}

extension WorkspaceWindowController {
    /// Reads the host's pairs once (the phone-with-watch destinations come
    /// from them) and relists the destinations of every workspace window
    /// whenever they change.
    func refreshRemotePairs() {
        Self.observePairChanges()
        let settings = RemoteSimulatorSettings.load(Preferences.shared.defaults)
        guard settings.isConfigured, !Self.isTestProcess else { return }
        let remote = RemoteSimulator(settings: settings)
        Task { await RemotePairsStore.shared.refresh(remote) }
    }

    private static var pairObserver: NSObjectProtocol?

    static func observePairChanges() {
        guard pairObserver == nil else { return }
        pairObserver = NotificationCenter.default.addObserver(forName: RemotePairsStore.didChange, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated {
                for w in NSApp?.windows ?? [] {
                    if let wc = w.windowController as? WorkspaceWindowController { wc.setDestinationGroups(wc.session.model.destinationGroups) }
                }
            }
        }
    }
}

/// The last run alert's texts (tests read them; `isTestProcess` shows none).
@MainActor private var lastRunAlerts: [ObjectIdentifier: (String, String)] = [:]

extension WorkspaceWindowController {
    var lastRunAlert: (String, String)? {
        get { lastRunAlerts[ObjectIdentifier(self)] }
        set { lastRunAlerts[ObjectIdentifier(self)] = newValue }
    }
}
