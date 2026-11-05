import AppKit
import YcodeBuild
import YcodeDeviceModel
import YcodeDeviceUI
import YcodeIDECore

/// Times of one live preview update, in seconds from its start (a save,
/// a resume, a layout change). See `specs/ide/previews.md` §Measurements.
public struct LivePreviewTiming: Equatable, Sendable {
    public var kind: String
    /// Generating the payload's sources.
    public var generate: Double = 0
    /// Compiling the payload.
    public var compile: Double = 0
    /// Building the host (first preview only) and starting the device.
    public var start: Double = 0
    /// Sending the payload and the plan.
    public var upload: Double = 0
    /// From the upload's end to the host's `ready`.
    public var load: Double = 0
    /// From the start to the host's `ready`.
    public var ready: Double = 0
    /// From the start to the first new picture on the canvas after `ready`.
    public var pixels: Double?

    public var summary: String {
        String(format: "%@: generate %.2f, compile %.2f, start %.2f, upload %.2f, load %.2f, ready %.2f, pixels %@ s", kind, generate, compile, start,
               upload, load, ready, pixels.map { String(format: "%.2f", $0) } ?? "–")
    }
}

/// A window's live-preview state (one per workspace window).
@MainActor
final class LivePreviewState {
    var session: RemotePreviewSession?
    var inputs: PreviewInputs?
    var sources: PreviewPayloadGenerator.Sources?
    var task: Task<Void, Never>?
    /// The pinned preview: its file and name (`previews.md` §Pinning).
    var pinned: (url: URL, name: String)?
    /// Timings of the updates, newest last (tests and the report).
    var timings: [LivePreviewTiming] = []
    var pendingPixels: (start: Date, index: Int)?
    var observer: PixelsObserver?
    var issues: [PreviewIssue] = []
}

/// Notes the first picture after a `ready` (the "new pixels" time).
@MainActor
final class PixelsObserver: DeviceLiveSessionObserver {
    let onImage: () -> Void
    init(onImage: @escaping () -> Void) { self.onImage = onImage }
    func session(_ s: DeviceLiveSession, changed: DeviceSessionChange) { if changed == .image { onImage() } }
}

extension WorkspaceWindowController {
    /// The platform the focused file's previews run on: the product's
    /// (a project's first target), or for a package the run destination's
    /// (a Ycode simulator → iOS), else the Mac. A package file whose
    /// previews need UIKit runs on iOS (issue #84).
    public var previewPlatform: PreviewPlatform {
        if session.model.kind == .package {
            if session.destination?.isYcodeRemoteSimulator == true { return .iOS }
            if editor.fileURL?.pathExtension == "swift", PreviewDiscovery.needsUIKit(text: editor.text) { return .iOS }
            return .macOS
        }
        return productPlatform.platform.flatMap(PreviewPlatform.init(destinationPlatform:)) ?? .macOS
    }

    /// The Ycode simulator a live preview runs on: the canvas's device
    /// choice, else the run destination when it is a Ycode simulator, else
    /// the first one of the settings for the platform (phones first).
    func previewSimulator(platform: PreviewPlatform) -> RemoteSimulator? {
        let settings = RemoteSimulatorSettings.load(Preferences.shared.defaults)
        guard settings.isConfigured else { return nil }
        let all = Self.previewSimulators(settings)
        if let chosen = canvas?.devices.chosen, let r = all.first(where: { Self.previewDeviceTitle($0) == chosen }) { return r }
        if let d = session.destination, d.isYcodeRemoteSimulator { return RemoteSimulator(settings: settings, destination: d) }
        return all.first(where: { $0.target?.deviceType.id.hasPrefix("iphone") == true && $0.target?.deviceType.id != "iphone-duo" })
            ?? all.first
    }

    /// The devices a preview can run on (Ycode decision, `previews.md`
    /// §Live canvas): every run destination, plus every other device type
    /// a runtime boots (previews look at sizes the run destinations leave
    /// out, e.g. the iPhone 18 Pro on a runtime whose run destination is
    /// the iPhone Duo). Such a type's device directory follows the run
    /// destinations' naming (`<device name>-<type>-<runtime version>`).
    static func previewSimulators(_ settings: RemoteSimulatorSettings) -> [RemoteSimulator] {
        var out = RemoteSimulator.all(settings)
        let have = Set(out.compactMap { $0.target.map { "\($0.runtimeRoot)|\($0.deviceType.id)" } })
        for root in settings.allRuntimeRoots where settings.runtimePlatform(forRoot: root) != "watchOS" {
            let version = settings.runtimeVersion(forRoot: root)
            for type in YcodeSimulatorDeviceType.all where type.runs(onRuntimeVersion: version) && !have.contains("\(root)|\(type.id)") {
                let dir = "\(settings.deviceName)-\(type.id)-\(RemoteSimulatorTarget.runtimeTag(root: root, version: version))"
                out.append(RemoteSimulator(settings: settings, target: RemoteSimulatorTarget(runtimeRoot: root, runtimeVersion: version, deviceType: type,
                                                                                          deviceDirectoryName: dir, isPrimary: false)))
            }
        }
        return out
    }

    /// The device menu's title for a Ycode simulator ("iPhone 18 Pro (Ycode) 27.0").
    static func previewDeviceTitle(_ r: RemoteSimulator) -> String {
        [r.target?.name ?? RemoteSimulator.deviceName, r.runtimeVersion].compactMap { $0 }.joined(separator: " ")
    }

    /// The device's screen in points (its frame data; the hello's when live).
    static func screenPoints(_ r: RemoteSimulator) -> CGSize {
        let spec = r.target.flatMap { DeviceFrameSpec.named(typeID: $0.deviceType.id) } ?? .iPhone18Pro
        return spec.panels[0].uprightPointSize
    }

    /// The tiles a live canvas asks for (Ycode design, `previews.md` §Canvas
    /// layout): Grid → every preview; Variants → the selected preview in
    /// each variant; otherwise the selected preview, after a pinned one.
    static func liveTiles(previews: [PreviewDeclaration], titles: [String], selected: Int, grid: Bool, variants: PreviewVariantKind?,
                          base: PreviewVariant, pinned: Int?, screen: CGSize) -> [PreviewTile] {
        guard !previews.isEmpty else { return [] }
        func tile(_ i: Int, _ v: PreviewVariant, suffix: String = "") -> PreviewTile {
            let p = previews[i]
            let fits = p.layout == .sizeThatFits
            var variant = v
            if variant.orientation == nil, p.orientation != .portrait { variant.orientation = p.orientation.rawValue }
            let label = suffix.isEmpty ? "" : " — " + suffix
            return PreviewTile(preview: i, variant: variant, size: PreviewScreenLayout.tileSize(p, screen: screen, variant: variant), fits: fits,
                               title: (i < titles.count ? titles[i] : p.name) + label)
        }
        let sel = min(max(selected, 0), previews.count - 1)
        if grid { return previews.indices.map { tile($0, base) } }
        if let kind = variants { return kind.variants(base: base).map { tile(sel, $0, suffix: $0.label) } }
        var out: [PreviewTile] = []
        if let p = pinned, p != sel, p < previews.count { out.append(tile(p, base, suffix: "Pinned")) }
        out.append(tile(sel, base))
        return out
    }

    /// Discovers the focused file's previews and brings the live canvas up to
    /// date the cheapest way (`PreviewUpdatePlanner`). See `previews.md`
    /// §Fast updates.
    @discardableResult
    func refreshLivePreviews(platform: PreviewPlatform, reason: String = "refresh") -> Task<Void, Never>? {
        guard let c = canvas, let url = editor.fileURL else { return nil }
        let start = Date()
        try? editor.save()
        let text = editor.text
        let previews = PreviewDiscovery.previews(in: text)
        let titles = previews.map(\.tabTitle)
        c.setNames(previews.map(\.name))
        c.tabTitles = titles
        guard !previews.isEmpty else { c.setState(.empty("No Previews")); return nil }
        guard !c.isPaused else { return nil }
        guard let sim = previewSimulator(platform: platform) else {
            c.setState(.needsSimulator(Self.needsSimulatorMessage(platform: platform, uikit: PreviewDiscovery.needsUIKit(text: text, previews: previews))))
            return nil
        }
        let live = livePreview
        c.devices.automatic = Self.previewDeviceTitle(sim)
        c.devices.connected = Self.previewSimulators(sim.settings).map(Self.previewDeviceTitle)
        // Another device than the running session's: start over on it.
        if let s = live.session, s.remote.remoteDevicePath != sim.previewDevice.remoteDevicePath {
            live.session = nil
            live.inputs = nil
        }
        let session = live.session ?? RemotePreviewSessions.shared.session(for: sim, platform: platform)
        live.session = session
        c.attach(session.link?.session)
        // Pinned preview (same module): exported first.
        var previewed = [PreviewedFile(url: url, previews: previews)]
        var pinnedIndex: Int?
        var allTitles = titles
        var allPreviews = previews
        if let pin = live.pinned, pin.url.standardizedFileURL != url.standardizedFileURL,
           let pinText = try? String(contentsOf: pin.url, encoding: .utf8),
           let p = PreviewDiscovery.previews(in: pinText).first(where: { $0.name == pin.name }) {
            previewed.append(PreviewedFile(url: pin.url, previews: [p]))
            pinnedIndex = previews.count
            allTitles.append(p.tabTitle)
            allPreviews.append(p)
        } else if let pin = live.pinned, pin.url.standardizedFileURL == url.standardizedFileURL {
            pinnedIndex = previews.firstIndex { $0.name == pin.name }
        }
        c.pinnedTitle = live.pinned?.name
        let previewedFiles = previewed, exported = allPreviews
        let screen = session.link?.session.hello.map { CGSize(width: $0.pointWidth, height: $0.pointHeight) } ?? Self.screenPoints(sim)
        c.liveScreen = screen
        let tiles = Self.liveTiles(previews: allPreviews, titles: allTitles, selected: c.selectedIndex, grid: c.layout == .grid,
                                   variants: c.variantKind, base: c.baseVariant, pinned: pinnedIndex, screen: screen)
        let regions = PreviewScreenLayout.regions(tiles, screen: screen)
        let liveTiles = zip(tiles, regions).map { PreviewLiveTile(title: $0.0.title, preview: $0.0.preview, region: $0.1) }
        let kind = self.session.model.kind, packageDirectory = self.session.model.url, projects = self.session.model.projects
        let work = previewWorkDirectory
        live.task?.cancel()
        c.setUpdating(true)
        let activity = beginPreviewActivity()
        let task = Task { [weak self, weak c] in
            defer { self?.endPreviewActivity(activity) }
            // The module, its sources and the decision.
            let resolved = await Task.detached { () -> Result<PreviewRenderer.Module, PreviewRenderer.Failure> in
                do throws(PreviewRenderer.Failure) {
                    switch kind {
                    case .package: return .success(try PreviewRenderer.packageModule(for: url, packageDirectory: packageDirectory))
                    default:
                        guard let (path, proj) = projects.first(where: { url.path.hasPrefix(URL(fileURLWithPath: $0.key).deletingLastPathComponent().path + "/") })
                            ?? projects.first.map({ ($0.key, $0.value) }) else { throw PreviewRenderer.Failure.unsupportedTarget("no project") }
                        return .success(try PreviewRenderer.projectModule(for: url, project: proj, xcodeprojURL: URL(fileURLWithPath: path)))
                    }
                } catch { return .failure(error) }
            }.value
            guard !Task.isCancelled, let self, let c, self.canvas === c else { return }
            let module: PreviewRenderer.Module
            switch resolved {
            case .success(let m): module = m
            case .failure(let e):
                c.setUpdating(false)
                c.setState(.failed(e.description))
                return
            }
            let linked: Bool = if case .linked = module.kind { true } else { false }
            let files = module.sources
            let hashes = Dictionary(files.map { ($0.path, PreviewInputs.hash((try? String(contentsOf: $0, encoding: .utf8)) ?? "")) }, uniquingKeysWith: { a, _ in a })
            let inputs = PreviewInputs(destination: session.remote.remoteDevicePath + "|" + platform.rawValue, module: module.name, linked: linked,
                                       sourceHashes: hashes, previewsHash: PreviewInputs.hash(exported), layout: regions)
            var decision = PreviewUpdatePlanner.decide(previous: live.inputs, current: inputs, host: session.host)
            if case .relayout = decision, live.sources == nil { decision = .reloadPayload }
            if !session.isRunning, case .relaunchHost = decision {} else if !session.isRunning { decision = .relaunchHost(reason: "the host is not running") }
            var timing = LivePreviewTiming(kind: "\(reason) (\(Self.describe(decision)))")
            switch decision {
            case .none:
                c.setUpdating(false)
                c.setState(.live(liveTiles))
                return
            case .rebuild(let why):
                c.setUpdating(false)
                c.setState(.failed("This preview cannot run on the simulator yet: \(why)."))
                return
            case .relaunchHost, .reloadPayload, .relayout:
                break
            }
            var payload: URL?
            if decision != .relayout {
                let dir = work.appendingPathComponent("Live/\(platform.rawValue)/\(module.name)")
                let g = (session.generation + 1)
                let out = dir.appendingPathComponent("payload-\(g).dylib")
                let compiler = PreviewCompiler(platform: platform, deploymentTarget: session.deploymentTarget, moduleName: module.name,
                                               moduleCache: work.appendingPathComponent("ModuleCache"))
                let t0 = Date()
                let result = await Task.detached { () -> Result<PreviewPayloadGenerator.Sources, PreviewFailure> in
                    let sources: PreviewPayloadGenerator.Sources
                    do { sources = try PreviewPayloadGenerator.generate(moduleFiles: files, previewed: previewedFiles, platform: platform, into: dir.appendingPathComponent("src")) } catch {
                        return .failure(.host("Could not write the preview's sources: \(error)"))
                    }
                    do throws(PreviewFailure) { try compiler.compilePayload(sources, output: out) } catch { return .failure(error) }
                    return .success(sources)
                }.value
                timing.compile = Date().timeIntervalSince(t0)
                guard !Task.isCancelled, self.canvas === c else { return }
                switch result {
                case .success(let s): live.sources = s
                case .failure(let f):
                    c.setUpdating(false)
                    live.issues = f.issues
                    if case .live = c.state {
                        c.setBanner(title: f.issues.isEmpty ? "Preview failed" : "Compiling the preview failed", issues: f.issues, message: f.description)
                    } else {
                        c.setState(.failed(f.description))
                    }
                    return
                }
                payload = out
            }
            if !session.isRunning {
                let t0 = Date()
                if case .live = c.state {} else { c.setState(.building) }
                let target = session.deploymentTarget
                let built = await Task.detached { () -> Result<URL, PreviewFailure> in
                    do throws(PreviewFailure) {
                        return .success(try PreviewHost.build(platform: platform, deploymentTarget: target, workDirectory: work))
                    } catch { return .failure(error) }
                }.value
                guard case .success(let host) = built else {
                    c.setUpdating(false)
                    if case .failure(let e) = built { c.setState(.failed("The preview host could not be built: \(e.description)")) }
                    return
                }
                session.onChange = { [weak self, weak c] in
                    guard let c, let self, self.canvas === c else { return }
                    if case .starting(let text) = session.phase { c.setStartingText(text) }
                    if case .failed(let m) = session.phase { c.setState(.failed(m)) }
                }
                let ok = await session.start(hostApp: host)
                timing.start = Date().timeIntervalSince(t0)
                guard ok, self.canvas === c else {
                    c.setUpdating(false)
                    if case .failed(let m) = session.phase { c.setState(.failed(m)) } else { c.setState(.failed("The preview device did not start")) }
                    return
                }
                c.attach(session.link?.session)
                if let h = session.link?.session.hello { c.liveScreen = CGSize(width: h.pointWidth, height: h.pointHeight) }
            }
            do throws(PreviewFailure) {
                let d = try await session.deliver(payload: payload, regions: regions)
                timing.upload = d.upload
                timing.load = d.load
                timing.ready = Date().timeIntervalSince(start)
                live.inputs = inputs
                live.issues = []
                c.clearBanner()
                c.setUpdating(false)
                c.setState(.live(liveTiles))
                // The first picture after ready is the update's "new pixels".
                live.timings.append(timing)
                self.watchPixels(start: start, index: live.timings.count - 1)
            } catch {
                c.setUpdating(false)
                live.inputs = nil
                c.setBanner(title: "The preview host failed", issues: [], message: error.description)
                if case .live = c.state {} else { c.setState(.failed(error.description)) }
            }
        }
        live.task = task
        return task
    }

    /// What the canvas says when previews need a Ycode simulator and none is set up.
    static func needsSimulatorMessage(platform: PreviewPlatform, uikit: Bool) -> String {
        let what = uikit ? "UIKit previews" : "Previews for \(platform.rawValue)"
        return "\(what) run on a Ycode Simulator. Set one up in Settings ▸ Simulators (a simulator host and a runtime), then choose Check Again."
    }

    static func describe(_ d: PreviewUpdate) -> String {
        switch d {
        case .none: "none"
        case .relayout: "relayout"
        case .reloadPayload: "reload payload"
        case .relaunchHost(let r): "relaunch host: \(r)"
        case .rebuild(let r): "rebuild: \(r)"
        }
    }

    private func watchPixels(start: Date, index: Int) {
        let live = livePreview
        guard let s = live.session?.link?.session else { return }
        if let o = live.observer { s.removeObserver(o) }
        let o = PixelsObserver { [weak self] in
            guard let self else { return }
            let live = self.livePreview
            guard index < live.timings.count, live.timings[index].pixels == nil else { return }
            live.timings[index].pixels = Date().timeIntervalSince(start)
            let line = "previews: " + live.timings[index].summary
            if let path = ProcessInfo.processInfo.environment["YCODE_PREVIEW_TIMING_LOG"],
               let h = FileHandle(forWritingAtPath: path) ?? { FileManager.default.createFile(atPath: path, contents: nil); return FileHandle(forWritingAtPath: path) }() {
                h.seekToEndOfFile()
                h.write(Data((line + "\n").utf8))
                h.closeFile()
            }
        }
        live.observer = o
        s.addObserver(o)
    }

    /// Timings of this window's live preview updates (newest last).
    public var livePreviewTimings: [LivePreviewTiming] { livePreview.timings }

    /// Pins the canvas's selected preview, or unpins (`previews.md` §Pinning).
    func togglePin() {
        let live = livePreview
        if live.pinned != nil {
            live.pinned = nil
        } else if let url = editor.fileURL, let c = canvas, c.selectedIndex < c.names.count {
            live.pinned = (url, c.names[c.selectedIndex])
        }
        canvas?.pinnedTitle = live.pinned?.name
        refreshPreviews()
    }

    /// Opens an issue's file at its line.
    func openPreviewIssue(_ issue: PreviewIssue) {
        guard let f = issue.file else { return }
        open(path: f.path, line: issue.line)
    }

    /// Selectable mode: reveals a preview's `#Preview` line.
    func revealPreview(_ index: Int) {
        guard let url = editor.fileURL else { return }
        let previews = PreviewDiscovery.previews(in: editor.text)
        guard index < previews.count else { return }
        open(path: url.path, line: previews[index].line)
    }
}

extension PreviewCanvasController {
    /// The status while the preview device starts ("Booting the preview device").
    public func setStartingText(_ text: String) {
        guard isViewLoaded else { return }
        statusLabel.stringValue = text
    }
}
