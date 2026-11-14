import Foundation
import YcodeIDECore
import YcodePreviews
import YcodeSimLink

/// UIKit view and view-controller previews in the Linux IDE (issue #84;
/// `specs/ide/previews.md` §Linux, "UIKit previews"): they need UIKit, so
/// they run in Ycode's iOS simulator on a paired simulator host. Each update
/// compiles the module and the previews into a payload for the simulator
/// (with the user's SDK copy, `PreviewIOSToolchain`), puts it with the plan
/// in a preview host app (`PreviewHost.bundledPlanSource`), uploads that over
/// Ycode's link, launches it on the host's preview device, and takes one
/// picture of the device's screen with the headless viewer. The canvas cuts
/// each tile's region out of that picture.
public final class SimulatorPreviewEngine: PreviewCanvasEngine, @unchecked Sendable {
    private let queue = DispatchQueue(label: "ycode.previews.simulator")
    private let lock = NSLock()
    private var newest = 0
    private var generation = 0
    private var hostExecutable: (version: String, url: URL)?

    /// The paired host (`ycode sim remote pair`) the previews run on.
    public let hostName: String
    public let workDirectory: URL
    /// The SDK copy, or why there is none.
    public let toolchain: Result<PreviewIOSToolchain, PreviewFailure>
    /// How long the device may take to show the app (a first boot takes minutes).
    public var startTimeout: TimeInterval = 900

    public init(hostName: String, workDirectory: URL, toolchain: Result<PreviewIOSToolchain, PreviewFailure>) {
        self.hostName = hostName
        self.workDirectory = workDirectory
        self.toolchain = toolchain
    }

    /// The paired simulator hosts' names (`$YCODE_SIM_LINK_HOME`'s trusted hosts).
    public static func pairedHosts(store: LinkStore = LinkStore()) -> [String] {
        store.peers().filter { $0.role == "host" }.map(\.name)
    }

    /// The engine for a workspace when a simulator host is paired
    /// (`YCODE_PREVIEW_SIM_HOST` picks one of several), else nil: the
    /// canvas then says that UIKit previews need one.
    public static func standard(workspace: URL, environment: [String: String] = ProcessInfo.processInfo.environment) -> PreviewCanvasEngine? {
        let hosts = pairedHosts()
        guard let name = environment["YCODE_PREVIEW_SIM_HOST"].flatMap({ hosts.contains($0) ? $0 : nil }) ?? hosts.first else { return nil }
        let root = OpenViewsPreviewEngine.cacheRoot(environment: environment)
        let tag = String(UInt64(bitPattern: Int64(PreviewInputs.hash(workspace.standardizedFileURL.path))), radix: 16)
        return SimulatorPreviewEngine(hostName: name, workDirectory: root.appendingPathComponent("ycode/previews-ios/\(workspace.lastPathComponent)-\(tag)"),
                                      toolchain: PreviewIOSToolchain.locate(environment: environment))
    }

    /// The preview device for a device type on the host ("ycode-previews-iphone-18-pro").
    public static func previewDevice(typeID: String) -> String { "ycode-previews-" + typeID }

    /// The tiles' regions on the device's screen (`PreviewScreenLayout`):
    /// a fitting preview gets the screen and lays itself out at its size.
    public static func regions(_ tiles: [PreviewCanvasTileRequest], screen: CGSize) -> [PreviewRegion] {
        let t = tiles.map { t in
            PreviewTile(preview: t.preview, variant: t.variant, size: t.size == .zero ? screen : t.size, fits: t.size == .zero)
        }
        return PreviewScreenLayout.regions(t, screen: screen)
    }

    /// The headless viewer's script: past the boot logo, the home screen
    /// gives way to the app (the launcher opens it once the home screen has
    /// settled), then the app's first steady picture.
    public static func shotScript(png: String, timeout: TimeInterval) -> String {
        """
        wait-live \(Int(timeout))
        wait-home \(Int(timeout))
        wait-change 20 \(Int(timeout))
        sleep 1500
        wait-quiet 1500 120
        server-shot \(png)
        quit

        """
    }

    public func update(_ request: PreviewCanvasRequest, generation g: Int, progress: @escaping @Sendable (String) -> Void) async
        -> Result<PreviewCanvasOutcome, PreviewFailure>? {
        lock.withLock { newest = max(newest, g) }
        return await withCheckedContinuation { c in
            queue.async {
                let stale = self.lock.withLock { g < self.newest }
                c.resume(returning: stale ? nil : self.run(request, progress: progress))
            }
        }
    }

    public func stop() {}

    private func run(_ request: PreviewCanvasRequest, progress: @escaping @Sendable (String) -> Void) -> Result<PreviewCanvasOutcome, PreviewFailure> {
        let tc: PreviewIOSToolchain
        switch toolchain {
        case .success(let t): tc = t
        case .failure(let f): return .failure(f)
        }
        let t0 = Date()
        let fm = FileManager.default
        let cache = PreviewModuleCache.prepare(workDirectory.appendingPathComponent("ModuleCache"))
        let crashed: ((status: Int32, output: String)) -> Bool = { $0.status != 0 && PreviewModuleCache.looksLikeCompilerCrash($0.output) }
        // The host's executable, once per SDK and host source.
        let version = "\(tc.sdkVersion)-v\(PreviewHost.sourceVersion)"
        if hostExecutable?.version != version {
            progress("Building the preview host")
            let dir = workDirectory.appendingPathComponent("host-\(version)")
            let src = dir.appendingPathComponent("main.swift"), exe = dir.appendingPathComponent(PreviewHost.executableName)
            if !fm.isExecutableFile(atPath: exe.path) {
                do { try PreviewPayloadGenerator.write(PreviewHost.bundledPlanSource, to: src) } catch { return .failure(.host("\(error)")) }
                let r = PreviewModuleCache.retryingAfterCrash(cache, {
                    PreviewChild.runSwiftc(tc.arguments(sources: [src], output: exe, moduleName: PreviewHost.executableName, library: false, moduleCache: cache))
                }, crashed: crashed)
                guard r.status == 0 else { return .failure(.host("The preview host did not build: \(r.output.suffix(600))")) }
            }
            hostExecutable = (version, exe)
        }
        guard let hostExe = hostExecutable?.url else { return .failure(.host("no preview host")) }
        // The payload.
        progress("Compiling the preview")
        let file = request.file.standardizedFileURL
        let module = request.locator.module(for: file)
        let sources: PreviewPayloadGenerator.Sources
        do {
            sources = try PreviewPayloadGenerator.generate(moduleFiles: module.files, previewed: [PreviewedFile(url: file, previews: request.previews)],
                                                           kit: .uiKit, into: workDirectory.appendingPathComponent("src"), texts: [file: request.text])
        } catch { return .failure(.host("Could not write the preview's sources: \(error)")) }
        generation += 1
        let app = workDirectory.appendingPathComponent("app/\(PreviewHost.appName)")
        try? fm.removeItem(at: app)
        let previewsDir = app.appendingPathComponent("Previews")
        let payload = previewsDir.appendingPathComponent("payload.dylib")
        do { try fm.createDirectory(at: previewsDir, withIntermediateDirectories: true) } catch { return .failure(.host("\(error)")) }
        let compiled = PreviewModuleCache.retryingAfterCrash(cache, {
            PreviewChild.runSwiftc(tc.arguments(sources: sources.files, output: payload, moduleName: module.name, library: true, moduleCache: cache))
        }, crashed: crashed)
        guard compiled.status == 0, fm.fileExists(atPath: payload.path) else {
            return .failure(.compile(PreviewCompiler.issues(from: compiled.output, lineMaps: sources.lineMaps)))
        }
        // The app: the host, its Info.plist and icon, the payload and the plan.
        let regions = Self.regions(request.tiles, screen: request.screen)
        do {
            try fm.copyItem(at: hostExe, to: app.appendingPathComponent(PreviewHost.executableName))
            try PreviewHost.infoPlist(platform: .iOS, deploymentTarget: tc.sdkVersion).write(to: app.appendingPathComponent("Info.plist"), atomically: true, encoding: .utf8)
            try PreviewHost.iconPNG(size: 120).write(to: app.appendingPathComponent("AppIcon60x60@2x.png"))
            try PreviewHost.iconPNG(size: 180).write(to: app.appendingPathComponent("AppIcon60x60@3x.png"))
            try PreviewPlan(generation: generation, payload: "payload.dylib", regions: regions).json().write(to: previewsDir.appendingPathComponent("plan.json"))
        } catch { return .failure(.host("Could not make the preview app: \(error)")) }
        let t1 = Date()
        // Upload, launch on the preview device, one picture.
        progress("Launching the preview on \(hostName)")
        let device = Self.previewDevice(typeID: request.deviceTypeID)
        do {
            let client = try LinkClient()
            let host = try client.host(named: hostName)
            let c = try client.control(host)
            defer { c.close() }
            let devices = try c.request(LinkRequest(op: "devices"))
            if devices.devices?.contains(where: { $0.name == device }) != true {
                let made = try c.request(LinkRequest(op: "create", device: device, deviceType: request.deviceTypeID))
                guard made.ok else { return .failure(.host("The simulator host could not create \(device): \(made.error ?? "")")) }
            }
            let up = try c.upload(app)
            guard up.ok else { return .failure(.host("Uploading the preview failed: \(up.error ?? "")")) }
            let r = try c.request(LinkRequest(op: "run", device: device, app: app.lastPathComponent, bundleID: PreviewHost.bundleIdentifier))
            guard r.ok else { return .failure(.host("The simulator host did not launch the preview: \(r.error ?? "")")) }
            // Until its display is up; a device that ends says why (its log's last lines).
            progress("Booting the preview device")
            let deadline = Date().addingTimeInterval(startTimeout)
            var state = "booting"
            while Date() < deadline {
                state = try c.request(LinkRequest(op: "devices")).devices?.first { $0.name == device }?.state ?? "shutdown"
                if state != "booting" { break }
                Thread.sleep(forTimeInterval: 2)
            }
            guard state == "running" else {
                let tail = (try? c.request(LinkRequest(op: "log", device: device, lines: 3)).log) ?? []
                return .failure(.host("The preview device \(state == "booting" ? "did not start in \(Int(startTimeout)) s" : "stopped")"
                    + (tail.isEmpty ? "" : ": " + tail.joined(separator: " "))))
            }
        } catch {
            return .failure(.host("The simulator host \(hostName) did not answer on Ycode's link: \(error)"))
        }
        progress("Waiting for the preview device")
        let shot = workDirectory.appendingPathComponent("Shot-\(generation).png")
        let script = workDirectory.appendingPathComponent("shot.script")
        try? Self.shotScript(png: shot.path, timeout: startTimeout).write(to: script, atomically: true, encoding: .utf8)
        let viewer = PreviewChild.run([SimRemoteCLI.viewerPath()] + SimRemoteCLI.viewerArguments(host: hostName, device: device,
                                                                                                extra: ["--headless", "--script", script.path]),
                                      timeout: startTimeout * 2 + 180)
        guard fm.fileExists(atPath: shot.path) else {
            return .failure(.host("No picture of the preview device: " + (viewer.output.split(separator: "\n").suffix(2).joined(separator: " "))))
        }
        for name in (try? fm.contentsOfDirectory(atPath: workDirectory.path)) ?? [] where name.hasPrefix("Shot-") && name != shot.lastPathComponent {
            if Int(name.dropFirst(5).dropLast(4)).map({ $0 < generation - 1 }) == true { try? fm.removeItem(at: workDirectory.appendingPathComponent(name)) }
        }
        let crops = regions.map { CGRect(x: $0.x, y: $0.y, width: $0.width, height: $0.height) }
        return .success(PreviewCanvasOutcome(pictures: regions.map { _ in shot }, sizes: regions.map { CGSize(width: $0.width / $0.scale, height: $0.height / $0.scale) },
                                             decision: "relaunch host: the payload travels in the app", compile: t1.timeIntervalSince(t0),
                                             render: Date().timeIntervalSince(t1), crops: crops, screen: request.screen))
    }
}

extension PreviewChild {
    /// The toolchain's `swiftc` (on the PATH).
    static func runSwiftc(_ arguments: [String]) -> (status: Int32, output: String) { run(["swiftc"] + arguments, timeout: 600) }
}
