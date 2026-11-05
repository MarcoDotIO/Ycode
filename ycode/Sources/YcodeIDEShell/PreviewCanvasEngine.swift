import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif
import YcodeIDECore
import YcodePreviews
import YcodeProject

// The Linux canvas's engines (specs/ide/previews.md §Linux, "The Linux
// canvas"): `OpenViewsPreviewEngine` renders SwiftUI previews with
// OpenViews in a long-lived host; the canvas model asks an engine for one
// picture per tile and shows them.

/// One picture the canvas shows: a preview with a variant at a size.
public struct PreviewCanvasTileRequest: Equatable, Sendable {
    public var preview: Int
    public var variant: PreviewVariant
    /// Points; 0 × 0 for the view's ideal size (`.sizeThatFitsLayout`).
    public var size: CGSize
    public init(preview: Int, variant: PreviewVariant, size: CGSize) {
        self.preview = preview
        self.variant = variant
        self.size = size
    }
}

/// How the engine finds the module a file belongs to.
public struct PreviewModuleLocator: Sendable {
    public var kind: WorkspaceModel.ContainerKind
    public var directory: URL
    public var projects: [String: PBXProj]
    public init(kind: WorkspaceModel.ContainerKind, directory: URL, projects: [String: PBXProj]) {
        self.kind = kind
        self.directory = directory
        self.projects = projects
    }

    /// The module's name and Swift files; a module the payload cannot
    /// compile from sources (a package target with dependencies or
    /// resources) or no module at all gives the file alone.
    public func module(for file: URL) -> (name: String, files: [URL]) {
        let alone = (Self.moduleName(file.deletingPathExtension().lastPathComponent), [URL]())
        do throws(PreviewRenderer.Failure) {
            let m: PreviewRenderer.Module
            switch kind {
            case .package: m = try PreviewRenderer.packageModule(for: file, packageDirectory: directory)
            default:
                guard let (path, proj) = projects.first(where: { file.path.hasPrefix(URL(fileURLWithPath: $0.key).deletingLastPathComponent().path + "/") })
                    ?? projects.first.map({ ($0.key, $0.value) }) else { return alone }
                m = try PreviewRenderer.projectModule(for: file, project: proj, xcodeprojURL: URL(fileURLWithPath: path))
            }
            guard case .sources(let files) = m.kind else { return alone }
            return (Self.moduleName(m.name), files)
        } catch {
            return alone
        }
    }

    /// A Swift module name from a target or file name.
    static func moduleName(_ s: String) -> String {
        let cleaned = String(s.map { $0.isLetter || $0.isNumber || $0 == "_" ? $0 : "_" })
        guard let first = cleaned.first, !first.isNumber else { return "_" + cleaned }
        return cleaned
    }
}

/// What the canvas asks an engine for.
public struct PreviewCanvasRequest: Sendable {
    public var file: URL
    /// The focused file's text as edited (it need not be saved).
    public var text: String
    public var previews: [PreviewDeclaration]
    public var tiles: [PreviewCanvasTileRequest]
    public var locator: PreviewModuleLocator
    /// The canvas's device (`DeviceFrameSpec.typeID`) and its screen in points.
    public var deviceTypeID: String
    public var screen: CGSize
    public init(file: URL, text: String, previews: [PreviewDeclaration], tiles: [PreviewCanvasTileRequest], locator: PreviewModuleLocator,
                deviceTypeID: String = "iphone-18-pro", screen: CGSize = .zero) {
        self.file = file
        self.text = text
        self.previews = previews
        self.tiles = tiles
        self.locator = locator
        self.deviceTypeID = deviceTypeID
        self.screen = screen
    }
}

/// An engine's answer: one PNG per tile (in the request's order) and the
/// image's size in points.
public struct PreviewCanvasOutcome: Equatable, Sendable {
    public var pictures: [URL]
    public var sizes: [CGSize]
    /// The update planner's decision (`PreviewUpdatePlanner`), as text.
    public var decision: String
    public var compile: Double
    public var render: Double
    /// When pictures are of a whole device screen (the simulator), each
    /// tile's region of it in screen points, and the screen's size.
    public var crops: [CGRect]?
    public var screen: CGSize?
    public init(pictures: [URL], sizes: [CGSize], decision: String, compile: Double = 0, render: Double = 0, crops: [CGRect]? = nil, screen: CGSize? = nil) {
        self.pictures = pictures
        self.sizes = sizes
        self.decision = decision
        self.compile = compile
        self.render = render
        self.crops = crops
        self.screen = screen
    }
}

/// Renders a canvas request. Implementations serialize their work; a
/// request older than the newest one returns nil (superseded).
public protocol PreviewCanvasEngine: AnyObject, Sendable {
    func update(_ request: PreviewCanvasRequest, generation: Int, progress: @escaping @Sendable (String) -> Void) async
        -> Result<PreviewCanvasOutcome, PreviewFailure>?
    /// Ends the engine's processes (the workspace closes).
    func stop()
}

/// SwiftUI previews rendered with OpenViews: a long-lived host loads one
/// payload per edit. See `specs/ide/previews.md` §Linux.
public final class OpenViewsPreviewEngine: PreviewCanvasEngine, @unchecked Sendable {
    private let queue = DispatchQueue(label: "ycode.previews.openviews")
    private let lock = NSLock()
    private var newest = 0
    // State below is touched only on `queue`.
    private var built: PreviewOpenViewsHost.Built?
    private var host: PreviewHostProcess?
    private var hostFailed = false
    private var inputs: PreviewInputs?
    private var payload: URL?
    private var payloadGeneration = 0
    private var renderCount = 0
    /// Package modules by file: the target's name and folder, kept while
    /// `Package.swift` is unchanged (`dump-package` takes most of a second).
    private var packageModules: [String: (stamp: Date?, name: String, folder: URL?)] = [:]

    /// Where payloads and pictures go (one folder per workspace).
    public let workDirectory: URL
    /// The OpenViews package (nil: not found; every update says so).
    public let openViews: URL?
    /// The cache root the host package is built under.
    public let cacheRoot: URL

    public init(workDirectory: URL, openViews: URL?, cacheRoot: URL) {
        self.workDirectory = workDirectory
        self.openViews = openViews
        self.cacheRoot = cacheRoot
    }

    /// The cache root: `$XDG_CACHE_HOME`, else `~/.cache`.
    public static func cacheRoot(environment: [String: String] = ProcessInfo.processInfo.environment) -> URL {
        environment["XDG_CACHE_HOME"].flatMap { $0.hasPrefix("/") ? URL(fileURLWithPath: $0) : nil }
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".cache")
    }

    /// The engine for a workspace: OpenViews found from `$YCODE_OPENVIEWS`,
    /// the executable's folders or the workspace's.
    public static func standard(workspace: URL, environment: [String: String] = ProcessInfo.processInfo.environment) -> OpenViewsPreviewEngine {
        let root = cacheRoot(environment: environment)
        let exe = URL(fileURLWithPath: Bundle.main.executableURL?.path ?? CommandLine.arguments[0]).resolvingSymlinksInPath().deletingLastPathComponent()
        let ov = PreviewRenderHost.locateOpenViews(environment: environment,
                                                    starts: [exe, workspace, URL(fileURLWithPath: FileManager.default.currentDirectoryPath)])
        let tag = String(UInt64(bitPattern: Int64(PreviewInputs.hash(workspace.standardizedFileURL.path))), radix: 16)
        return OpenViewsPreviewEngine(workDirectory: root.appendingPathComponent("ycode/previews/\(workspace.lastPathComponent)-\(tag)"),
                                      openViews: ov, cacheRoot: root)
    }

    public func update(_ request: PreviewCanvasRequest, generation: Int, progress: @escaping @Sendable (String) -> Void) async
        -> Result<PreviewCanvasOutcome, PreviewFailure>? {
        lock.withLock { newest = max(newest, generation) }
        return await withCheckedContinuation { c in
            queue.async {
                let stale = self.lock.withLock { generation < self.newest }
                c.resume(returning: stale ? nil : self.run(request, progress: progress))
            }
        }
    }

    public func stop() {
        queue.async {
            self.host?.stop()
            self.host = nil
            self.inputs = nil
        }
    }

    /// The host's pid (tests).
    public var hostPID: Int32? { queue.sync { host?.isRunning == true ? host?.pid : nil } }

    private func module(for file: URL, locator: PreviewModuleLocator) -> (name: String, files: [URL]) {
        guard locator.kind == .package else { return locator.module(for: file) }
        let manifest = locator.directory.appendingPathComponent("Package.swift").path
        let stamp = (try? FileManager.default.attributesOfItem(atPath: manifest))?[.modificationDate] as? Date
        if let m = packageModules[file.path], m.stamp == stamp {
            return (m.name, m.folder.map(Self.swiftFiles(in:)) ?? [])
        }
        let m = locator.module(for: file)
        let folder = m.files.isEmpty ? nil : m.files[0].deletingLastPathComponent()
        let root = folder.flatMap { f in Self.targetFolder(of: file, package: locator.directory) ?? f }
        packageModules[file.path] = (stamp, m.name, root)
        return (m.name, root.map(Self.swiftFiles(in:)) ?? [])
    }

    /// `Sources/<Target>` of a package file.
    static func targetFolder(of file: URL, package: URL) -> URL? {
        let base = package.standardizedFileURL.path + "/"
        let p = file.standardizedFileURL.path
        guard p.hasPrefix(base) else { return nil }
        let parts = p.dropFirst(base.count).split(separator: "/")
        guard parts.count >= 3, parts[0] == "Sources" else { return nil }
        return package.standardizedFileURL.appendingPathComponent("Sources/\(parts[1])")
    }

    static func swiftFiles(in dir: URL) -> [URL] {
        guard let e = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: nil) else { return [] }
        return e.compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" }.map(\.standardizedFileURL).sorted { $0.path < $1.path }
    }

    private func run(_ request: PreviewCanvasRequest, progress: @escaping @Sendable (String) -> Void) -> Result<PreviewCanvasOutcome, PreviewFailure> {
        guard let openViews else {
            return .failure(.unsupported("Ycode could not find the open SwiftUI port (frameworks/swiftui) that renders previews on Linux. "
                + "Set YCODE_OPENVIEWS to its folder."))
        }
        let file = request.file.standardizedFileURL
        let module = module(for: file, locator: request.locator)
        let texts = [file: request.text]
        let hashes = Dictionary((module.files + [file]).map { u in
            (u.standardizedFileURL.path, PreviewInputs.hash(texts[u.standardizedFileURL] ?? (try? String(contentsOf: u, encoding: .utf8)) ?? ""))
        }, uniquingKeysWith: { a, _ in a })
        let regions = request.tiles.map { t in
            PreviewRegion(preview: t.preview, x: 0, y: 0, width: Double(t.size.width), height: Double(t.size.height), scale: 1,
                          style: t.variant.colorScheme, dynamicType: t.variant.dynamicType, orientation: t.variant.orientation)
        }
        let current = PreviewInputs(destination: "openviews|" + openViews.path, module: module.name, sourceHashes: hashes,
                                    previewsHash: PreviewInputs.hash(request.previews), layout: regions)
        let state = PreviewHostState(running: host?.isRunning == true, loads: host?.loads ?? 0, failed: hostFailed)
        var decision = PreviewUpdatePlanner.decide(previous: inputs, current: current, host: state)
        if case .relayout = decision, payload == nil { decision = .reloadPayload }
        let t0 = Date()
        // The host, built once (minutes the first time).
        if built == nil {
            do throws(PreviewFailure) {
                built = try PreviewOpenViewsHost.build(openViews: openViews, cacheRoot: cacheRoot, progress: progress)
            } catch { return .failure(error) }
        }
        guard let built else { return .failure(.host("The preview host is not built")) }
        let needsCompile: Bool
        switch decision {
        case .none, .relayout: needsCompile = false
        case .reloadPayload: needsCompile = true
        case .relaunchHost: needsCompile = payload == nil || inputs?.sourceHashes != current.sourceHashes || inputs?.previewsHash != current.previewsHash
            || inputs?.module != current.module
        case .rebuild(let why): return .failure(.unsupported(why))
        }
        if needsCompile {
            progress("Compiling the preview")
            payloadGeneration += 1
            let src = workDirectory.appendingPathComponent("src")
            let out = workDirectory.appendingPathComponent("payload-\(payloadGeneration).so")
            do {
                let sources = try PreviewPayloadGenerator.generate(moduleFiles: module.files, previewed: [PreviewedFile(url: file, previews: request.previews)],
                                                                   kit: .openViews, into: src, texts: texts)
                do throws(PreviewFailure) {
                    try PreviewOpenViewsHost.compilePayload(sources, output: out, moduleName: module.name, built: built)
                } catch {
                    inputs = nil
                    return .failure(error)
                }
            } catch {
                return .failure(.host("Could not write the preview's sources: \(error)"))
            }
            // Earlier payloads go (a loaded library stays mapped).
            if let old = payload { try? FileManager.default.removeItem(at: old) }
            payload = out
        }
        let t1 = Date()
        if case .relaunchHost = decision { host?.stop(); host = nil }
        if host == nil || host?.isRunning != true {
            progress("Starting the preview host")
            do { host = try PreviewHostProcess(executable: built.executable) } catch { return .failure(.host("The preview host did not start: \(error)")) }
            hostFailed = false
        }
        guard let host, let payload else { return .failure(.host("The preview host is not running")) }
        progress("Rendering")
        renderCount += 1
        let dir = workDirectory.appendingPathComponent("Rendered-\(renderCount)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let items = request.tiles.enumerated().map { i, t in
            PreviewOpenViewsHost.Request.Item(index: t.preview, width: Double(t.size.width), height: Double(t.size.height),
                                              dark: t.variant.colorScheme == "dark", dynamicType: t.variant.dynamicType,
                                              file: dir.appendingPathComponent("\(i)@2x.png").path)
        }
        let report = host.send(PreviewOpenViewsHost.Request(generation: renderCount, payload: payload.path, items: items), newPayload: needsCompile)
        switch report {
        case .ready?: break
        case .error(_, let m)?:
            hostFailed = true
            inputs = nil
            return .failure(.host(m))
        default:
            hostFailed = true
            inputs = nil
            self.host = nil
            return .failure(.host("The preview host ended or did not answer in \(Int(PreviewHostProcess.requestTimeout)) s"))
        }
        inputs = current
        // Earlier pictures go, but the one before stays: the canvas may still show it.
        for name in (try? FileManager.default.contentsOfDirectory(atPath: workDirectory.path)) ?? []
        where name.hasPrefix("Rendered-") && Int(name.dropFirst("Rendered-".count)).map({ $0 < renderCount - 1 }) == true {
            try? FileManager.default.removeItem(at: workDirectory.appendingPathComponent(name))
        }
        let pictures = items.map { URL(fileURLWithPath: $0.file) }
        let sizes = pictures.map { Self.pointSize(png: $0, scale: PreviewOpenViewsHost.scale) }
        return .success(PreviewCanvasOutcome(pictures: pictures, sizes: sizes, decision: Self.describe(decision),
                                             compile: t1.timeIntervalSince(t0), render: Date().timeIntervalSince(t1)))
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

    /// A PNG's size in points (its IHDR's pixels over `scale`).
    public static func pointSize(png: URL, scale: Double) -> CGSize {
        guard let h = FileHandle(forReadingAtPath: png.path) else { return .zero }
        defer { try? h.close() }
        let d = h.readData(ofLength: 24)
        guard d.count == 24, d.starts(with: [0x89, 0x50, 0x4e, 0x47]) else { return .zero }
        let b = [UInt8](d)
        let w = Int(b[16]) << 24 | Int(b[17]) << 16 | Int(b[18]) << 8 | Int(b[19])
        let ht = Int(b[20]) << 24 | Int(b[21]) << 16 | Int(b[22]) << 8 | Int(b[23])
        return CGSize(width: Double(w) / scale, height: Double(ht) / scale)
    }
}
