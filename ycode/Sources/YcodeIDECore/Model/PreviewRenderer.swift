import Foundation
import YcodeBuild
import YcodePreviews
import YcodeProject
import YcodeSubprocess

/// Builds and runs a preview host for a file and returns PNGs. See
/// `specs/ide/previews.md` §The preview host.
public struct PreviewRenderer: Sendable {
    public struct Rendered: Equatable, Sendable {
        public var name: String
        public var png: URL
        public var scheme: ColorScheme = .light
        public init(name: String, png: URL, scheme: ColorScheme = .light) {
            self.name = name
            self.png = png
            self.scheme = scheme
        }
    }

    public enum Failure: Error, Equatable, CustomStringConvertible {
        case unsupportedTarget(String)
        case build(firstDiagnostic: String, log: String)
        case run(String)
        public var description: String {
            switch self {
            case .unsupportedTarget(let m): "Unsupported target kind: \(m)"
            case .build(let d, _): d
            case .run(let m): m
            }
        }
    }

    public enum ColorScheme: String, Sendable, CaseIterable { case light, dark }

    /// Where hosts are generated (one folder per module, kept warm).
    public var workDirectory: URL

    public init(workDirectory: URL) { self.workDirectory = workDirectory }

    /// `~/Library/Developer/Ycode/DerivedData/Previews`.
    public static var defaultWorkDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Developer/Ycode/DerivedData/Previews")
    }

    /// The module a file belongs to and how the host reaches it.
    public struct Module: Equatable, Sendable {
        public enum Kind: Equatable, Sendable {
            /// The module's sources are compiled into the host.
            case sources([URL])
            /// The host depends on the user's package and imports the
            /// target `@testable` (targets with dependencies or resources).
            case linked(packageDirectory: URL, packageName: String, product: String)
        }
        public var name: String
        public var kind: Kind
        public var sources: [URL] { if case .sources(let s) = kind { return s }; return [] }
    }

    // MARK: Module resolution

    /// A package target holding the file (`Sources/<Target>/…`). Targets
    /// without dependencies or resources are compiled from source; others
    /// are linked through a library product that contains them.
    public static func packageModule(for file: URL, packageDirectory: URL) throws(Failure) -> Module {
        let rel = file.standardizedFileURL.path.replacingOccurrences(of: packageDirectory.standardizedFileURL.path + "/", with: "")
        let parts = rel.split(separator: "/")
        guard parts.count >= 3, parts[0] == "Sources" else { throw .unsupportedTarget("\(file.lastPathComponent) is not in a Sources/<Target> folder") }
        let target = String(parts[1])
        let (status, json) = run("/usr/bin/env", ["swift", "package", "--package-path", packageDirectory.path, "dump-package"], cwd: packageDirectory)
        guard status == 0, let start = json.firstIndex(of: "{"),
              let obj = try? JSONSerialization.jsonObject(with: Data(json[start...].utf8)) as? [String: Any] else {
            throw .unsupportedTarget("the package manifest could not be read")
        }
        let t = (obj["targets"] as? [[String: Any]])?.first { $0["name"] as? String == target }
        if t?["type"] as? String == "executable" { throw .unsupportedTarget("\(target) is an executable target") }
        let hasDeps = !((t?["dependencies"] as? [Any]) ?? []).isEmpty
        let hasResources = !((t?["resources"] as? [Any]) ?? []).isEmpty
        if !hasDeps && !hasResources {
            return Module(name: target, kind: .sources(swiftFiles(in: packageDirectory.appendingPathComponent("Sources/\(target)"))))
        }
        let products = obj["products"] as? [[String: Any]] ?? []
        guard let product = products.first(where: { p in
            (p["type"] as? [String: Any])?["library"] != nil && ((p["targets"] as? [String]) ?? []).contains(target)
        })?["name"] as? String else {
            throw .unsupportedTarget("\(target) has dependencies or resources and no library product contains it")
        }
        return Module(name: target, kind: .linked(packageDirectory: packageDirectory.standardizedFileURL,
                                                 packageName: obj["name"] as? String ?? packageDirectory.lastPathComponent, product: product))
    }

    /// A project target containing the file: its sources phase files, or
    /// the Swift files of its synchronized folders.
    public static func projectModule(for file: URL, project: PBXProj, xcodeprojURL: URL) throws(Failure) -> Module {
        let dir = project.projectDirectory(xcodeprojURL: xcodeprojURL)
        let parents = project.parentMap()
        let path = file.standardizedFileURL.path
        for t in project.targets {
            let type = t.string("productType") ?? ""
            guard type.hasSuffix(".application") || type.hasSuffix(".framework") || type.hasSuffix(".library.static") || type.hasSuffix(".library.dynamic") else { continue }
            var files: [URL] = []
            for phase in project.buildPhases(ofTarget: t.id) where phase.isa == "PBXSourcesBuildPhase" {
                for bf in phase.references("files") {
                    if let ref = project.fileReference(ofBuildFile: bf), let p = project.resolvedPath(of: ref.id, projectDirectory: dir, parents: parents),
                       p.hasSuffix(".swift") { files.append(URL(fileURLWithPath: p)) }
                }
            }
            for g in t.references("fileSystemSynchronizedGroups") {
                if let p = project.resolvedPath(of: g, projectDirectory: dir, parents: parents) { files += swiftFiles(in: URL(fileURLWithPath: p)) }
            }
            if files.contains(where: { $0.standardizedFileURL.path == path }) {
                return Module(name: (t.string("productName") ?? t.string("name") ?? "App").replacingOccurrences(of: " ", with: "_"), kind: .sources(files))
            }
        }
        throw .unsupportedTarget("no application or framework target compiles \(file.lastPathComponent)")
    }

    static func swiftFiles(in dir: URL) -> [URL] {
        guard let e = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: nil) else { return [] }
        return e.compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" }.sorted { $0.path < $1.path }
    }

    // MARK: Generated code

    /// Splits a `#Preview` body into `@Previewable` declarations (which
    /// become stored properties of the preview's wrapper view) and the
    /// remaining view content.
    static func splitPreviewable(_ body: String) -> (properties: [String], content: String) {
        var props: [String] = [], rest: [Substring] = []
        for line in body.split(separator: "\n", omittingEmptySubsequences: false) {
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.hasPrefix("@Previewable ") { props.append(String(t.dropFirst("@Previewable ".count))) } else { rest.append(line) }
        }
        return (props, rest.joined(separator: "\n"))
    }

    /// One wrapper view per preview: `@Previewable` lines become stored
    /// properties and the rest is the `body`; providers render `previews`.
    static func previewTypes(_ previews: [PreviewDeclaration]) -> String {
        var out = ""
        for (i, p) in previews.enumerated() {
            switch p.kind {
            case .macro(let body):
                let (props, content) = splitPreviewable(body)
                out += "struct __YcodePreview\(i): View {\n" + props.map { "    \($0)\n" }.joined() + "    var body: some View {\(content)}\n}\n"
            case .provider(let type):
                out += "struct __YcodePreview\(i): View {\n    var body: some View { \(type).previews }\n}\n"
            }
        }
        return out
    }

    /// The entry point: renders each preview in an `NSHostingView` inside a
    /// borderless window never ordered on screen, in the color scheme given
    /// as the second argument, to `<out>/<index>-<scheme>.png`.
    static func entryPoint(_ previews: [PreviewDeclaration], imports: String) -> String {
        var out = """
        // Generated by Ycode. Renders previews offscreen to PNG files.
        import AppKit
        import SwiftUI
        \(imports)

        @MainActor func __ycodeRender<V: View>(_ view: V, size: CGSize?, dark: Bool, to path: String) -> Bool {
            let host = NSHostingView(rootView: view.environment(\\.colorScheme, dark ? .dark : .light))
            host.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            var s = size ?? host.fittingSize
            if s.width < 1 || s.height < 1 || s.width > 4000 || s.height > 4000 { s = CGSize(width: 320, height: 240) }
            let window = NSWindow(contentRect: CGRect(origin: .zero, size: s), styleMask: [.borderless], backing: .buffered, defer: true)
            window.appearance = host.appearance
            window.contentView = host
            host.frame = CGRect(origin: .zero, size: s)
            host.layoutSubtreeIfNeeded()
            guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return false }
            host.cacheDisplay(in: host.bounds, to: rep)
            guard let png = rep.representation(using: .png, properties: [:]) else { return false }
            return (try? png.write(to: URL(fileURLWithPath: path))) != nil
        }

        @main struct YcodePreviewHostMain {
            @MainActor static func main() {
                let app = NSApplication.shared
                app.setActivationPolicy(.prohibited)
                let args = CommandLine.arguments
                let out = args.count > 1 ? args[1] : "."
                let schemes = args.count > 2 ? args[2].split(separator: ",").map(String.init) : ["light"]
                for scheme in schemes {

        """
        for (i, p) in previews.enumerated() {
            let size = p.fixedSize.map { "CGSize(width: \($0.width), height: \($0.height))" } ?? "nil"
            out += "            print(__ycodeRender(__YcodePreview\(i)(), size: \(size), dark: scheme == \"dark\", to: out + \"/\(i)-\\(scheme).png\") ? \"rendered \(i)\" : \"failed \(i)\")\n"
        }
        out += "        }\n    }\n}\n"
        return out
    }

    // MARK: Host package (kept warm)

    /// Writes `text` only when it differs, so unchanged files keep their
    /// dates and incremental builds skip them.
    static func write(_ text: String, to url: URL) throws -> Bool {
        if (try? String(contentsOf: url, encoding: .utf8)) == text { return false }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
        return true
    }

    /// Writes (or updates) the host package for a module and file. Files
    /// that did not change are left alone; stale ones are removed.
    public func generateHost(module: Module, file: URL, previews: [PreviewDeclaration]) throws -> URL {
        let fm = FileManager.default
        let host = workDirectory.appendingPathComponent(module.name)
        let src = host.appendingPathComponent("Sources/YcodePreviewHost")
        var wanted: Set<String> = ["YcodePreviewEntry.swift"]
        switch module.kind {
        case .sources(let files):
            _ = try Self.write("""
            // swift-tools-version: 5.9
            // Generated by Ycode for previews. Do not edit.
            import PackageDescription
            let package = Package(name: "YcodePreviewHost", platforms: [.macOS(.v14)],
                                  targets: [.executableTarget(name: "YcodePreviewHost", path: "Sources/YcodePreviewHost")])

            """, to: host.appendingPathComponent("Package.swift"))
            for (i, s) in files.enumerated() {
                guard var text = try? String(contentsOf: s, encoding: .utf8), !text.contains("@main") else { continue }
                text = PreviewDiscovery.blankingPreviews(text)
                // The previewed file carries the wrapper views, so they can
                // use its fileprivate declarations.
                if s.standardizedFileURL.path == file.standardizedFileURL.path { text += "\n// Ycode previews\nimport SwiftUI\n" + Self.previewTypes(previews) }
                let name = "\(i)_\(s.lastPathComponent)"
                wanted.insert(name)
                _ = try Self.write(text, to: src.appendingPathComponent(name))
            }
            _ = try Self.write(Self.entryPoint(previews, imports: ""), to: src.appendingPathComponent("YcodePreviewEntry.swift"))
        case .linked(let dir, let packageName, let product):
            _ = try Self.write("""
            // swift-tools-version: 5.9
            // Generated by Ycode for previews. Do not edit.
            import PackageDescription
            let package = Package(name: "YcodePreviewHost", platforms: [.macOS(.v14)],
                                  dependencies: [.package(name: "\(packageName)", path: "\(dir.path)")],
                                  targets: [.executableTarget(name: "YcodePreviewHost",
                                                              dependencies: [.product(name: "\(product)", package: "\(packageName)")],
                                                              path: "Sources/YcodePreviewHost")])

            """, to: host.appendingPathComponent("Package.swift"))
            // The previewed file's own imports, then the module itself.
            let fileImports = ((try? String(contentsOf: file, encoding: .utf8)) ?? "").split(separator: "\n")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { $0.hasPrefix("import ") && $0 != "import SwiftUI" && $0 != "import AppKit" }
            let imports = (fileImports + ["@testable import \(module.name)"]).joined(separator: "\n")
            _ = try Self.write(Self.entryPoint(previews, imports: imports + "\n\n" + Self.previewTypes(previews)),
                               to: src.appendingPathComponent("YcodePreviewEntry.swift"))
        }
        for name in (try? fm.contentsOfDirectory(atPath: src.path)) ?? [] where !wanted.contains(name) {
            try? fm.removeItem(at: src.appendingPathComponent(name))
        }
        return host
    }

    /// Timings of the last render, in seconds.
    public struct Timing: Equatable, Sendable {
        public var build: Double
        public var run: Double
        public var total: Double { build + run }
    }

    /// Builds the host (swift-build engine when given, else `swift build`),
    /// runs it, and returns the PNGs in preview order for each scheme.
    public func render(module: Module, file: URL, previews: [PreviewDeclaration], schemes: [ColorScheme] = [.light],
                       swiftBuild: String? = nil, timing: ((Timing) -> Void)? = nil) throws(Failure) -> [Rendered] {
        guard !previews.isEmpty else { return [] }
        let t0 = Date()
        let host: URL
        do { host = try generateHost(module: module, file: file, previews: previews) } catch { throw .run("\(error)") }
        let linked: Bool = if case .linked = module.kind { true } else { false }
        let exe = try build(host: host, swiftBuild: swiftBuild, testable: linked)
        let t1 = Date()
        let out = host.appendingPathComponent("Rendered")
        try? FileManager.default.removeItem(at: out)
        try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let (status, text) = Self.run(exe, [out.path, schemes.map(\.rawValue).joined(separator: ",")], cwd: host,
                                      timeout: MacPreviewHostProcess.requestTimeout)
        timing?(Timing(build: t1.timeIntervalSince(t0), run: Date().timeIntervalSince(t1)))
        guard status == 0 else { throw .run("The preview host exited with status \(status): \(text.suffix(400))") }
        return schemes.flatMap { scheme in
            previews.enumerated().compactMap { i, p in
                let png = out.appendingPathComponent("\(i)-\(scheme.rawValue).png")
                return FileManager.default.fileExists(atPath: png.path) ? Rendered(name: p.name, png: png, scheme: scheme) : nil
            }
        }
    }

    public enum Container: Sendable { case package, project }

    /// Which builder the canvas uses: SwiftPM for package previews (first
    /// build and refreshes; faster incremental rebuilds), the swift-build
    /// engine (when installed) for project targets. Returns the `swbuild`
    /// path to pass to `render`, or nil for SwiftPM.
    public static func engine(for container: Container, swiftBuild: String?) -> String? {
        container == .project ? swiftBuild : nil
    }

    /// The swift-build path builds into `<host>/.ycode-build`; SwiftPM into `<host>/.build`.
    func build(host: URL, swiftBuild: String?, testable: Bool) throws(Failure) -> String {
        if let tool = swiftBuild {
            let engine = SwiftBuildEngine(swbuild: tool)
            var request = BuildRequest(container: .package(host.path), scheme: "YcodePreviewHost", action: .build)
            if testable { request.settings = [("ENABLE_TESTABILITY", "YES")] }
            let result = engine.start(request).runBlocking { _ in }
            if result.status == .succeeded, let exe = engine.executablePath(for: request), FileManager.default.isExecutableFile(atPath: exe) {
                return exe
            }
            if let first = result.issues.first(where: { $0.severity == .error && $0.location != nil }) {
                throw .build(firstDiagnostic: Self.describe(first), log: "")
            }
            // Otherwise fall back to SwiftPM.
        }
        var args = ["swift", "build", "--package-path", host.path, "--product", "YcodePreviewHost"]
        if testable { args += ["-Xswiftc", "-enable-testing"] }
        let (status, log) = Self.run("/usr/bin/env", args, cwd: host)
        guard status == 0 else {
            let errors = DiagnosticParser.parse(log).filter { $0.severity == .error }
            let first = errors.first { $0.location != nil } ?? errors.first
            throw .build(firstDiagnostic: first.map(Self.describe) ?? (log.split(separator: "\n").last.map(String.init) ?? "Build failed"), log: log)
        }
        let (_, bin) = Self.run("/usr/bin/env", ["swift", "build", "--package-path", host.path, "--show-bin-path"], cwd: host)
        return bin.trimmingCharacters(in: .whitespacesAndNewlines) + "/YcodePreviewHost"
    }

    /// `File.swift:3: message` — host copies (`<n>_<File>.swift`) map back
    /// to the user's file names.
    static func describe(_ d: Diagnostic) -> String {
        guard let l = d.location else { return d.message }
        var name = URL(fileURLWithPath: l.file).lastPathComponent
        if let us = name.firstIndex(of: "_"), name[..<us].allSatisfy(\.isNumber) { name = String(name[name.index(after: us)...]) }
        return "\(name):\(l.line): \(d.message)"
    }

    /// How long one preview child (a SwiftPM build, a run of the built host)
    /// may take before it is stopped: no wait on a preview child is unbounded.
    nonisolated(unsafe) public static var childTimeout: TimeInterval = 600

    /// Runs a child to completion, at most `timeout` (default `childTimeout`).
    /// A child that takes longer gets SIGINT (SwiftPM cancels its jobs), then
    /// SIGTERM, then SIGKILL, and the result is status -1 with a last line
    /// saying so.
    static func run(_ exe: String, _ args: [String], cwd: URL, timeout: TimeInterval? = nil) -> (Int32, String) {
        let name = URL(fileURLWithPath: exe).lastPathComponent
        MainThreadGuard.blockingCall("\(name) \(args.prefix(2).joined(separator: " "))")
        let p = Process()
        p.executableURL = URL(fileURLWithPath: exe)
        p.arguments = args
        p.currentDirectoryURL = cwd
        p.standardInput = FileHandle.nullDevice
        guard let pipe = try? SpawnPipe(childReads: false) else { return (127, "could not run \(exe)") }
        p.standardOutput = pipe.childEnd
        p.standardError = pipe.childEnd
        guard (try? p.runWithSignalsUnblocked(closingChildEndsOf: pipe)) != nil else { return (127, "could not run \(exe)") }
        final class Box: @unchecked Sendable {
            let lock = NSLock()
            var data = Data()
            var text: String { lock.lock(); defer { lock.unlock() }; return String(decoding: data, as: UTF8.self) }
        }
        let box = Box(), done = DispatchSemaphore(value: 0)
        let reader = pipe.fileHandleForReading
        Thread.detachNewThread {
            let d = reader.readDataToEndOfFile()
            box.lock.lock(); box.data = d; box.lock.unlock()
            done.signal()
        }
        let limit = timeout ?? childTimeout
        func exited(within seconds: TimeInterval) -> Bool {
            let deadline = Date().addingTimeInterval(seconds)
            while p.isRunning && Date() < deadline { usleep(20_000) }
            return !p.isRunning
        }
        guard exited(within: limit) else {
            // As Control-C: SwiftPM and the jobs it started.
            for sig in [SIGINT, SIGTERM, SIGKILL] where p.isRunning {
                ChildSignals.send(sig, to: p.processIdentifier)
                if exited(within: 2) { break }
            }
            // A grandchild may still hold the output open: take what came.
            _ = done.wait(timeout: .now() + 2)
            return (-1, box.text + "\n\(name) did not finish in \(Int(limit)) s and was stopped")
        }
        // Normally the output ends with the child; a grandchild that keeps
        // it open does not hold the caller for long.
        _ = done.wait(timeout: .now() + 10)
        return (p.terminationStatus, box.text)
    }
}

// MARK: Payloads on the Mac (specs/ide/previews.md §The macOS host)

/// A running Mac preview host (`PreviewMacHost`): one per work directory,
/// kept between refreshes; requests are one JSON line each.
final class MacPreviewHostProcess: @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var hosts: [String: MacPreviewHostProcess] = [:]
    let process = Process()
    private let input: SpawnPipe, output: SpawnPipe
    private let ioLock = NSLock()
    private var buffer = Data()
    private var inputClosed = false
    private(set) var loads = 0
    /// How long a request may take before the host is considered hung and
    /// is killed (a first render compiles nothing; 120 s is generous).
    nonisolated(unsafe) static var requestTimeout: TimeInterval = 120

    init(executable: URL) throws {
        input = try SpawnPipe(childReads: true)
        output = try SpawnPipe(childReads: false)
        process.executableURL = executable
        process.standardInput = input.childEnd
        process.standardOutput = output.childEnd
        process.standardError = FileHandle.nullDevice
        // A write to a host that died fails with EPIPE instead of a SIGPIPE
        // that would end Ycode (or the test process). The Mac host runs only
        // on macOS.
        #if canImport(Darwin)
        _ = fcntl(input.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
        #endif
        try process.runWithSignalsUnblocked(closingChildEndsOf: input, output)
    }

    var pid: pid_t { process.processIdentifier }

    private static let exitHook: Void = { atexit { MacPreviewHostProcess.terminateAll() } }()

    /// Ends one host without ever waiting unboundedly: its standard input is
    /// closed (the host exits at end of input), then SIGTERM, then SIGKILL,
    /// each after a short grace.
    func stop(grace: TimeInterval = 2) {
        ioLock.lock()
        if !inputClosed { inputClosed = true; try? input.fileHandleForWriting.close() }
        ioLock.unlock()
        func wait(_ seconds: TimeInterval) -> Bool {
            let deadline = Date().addingTimeInterval(seconds)
            while process.isRunning && Date() < deadline { usleep(20_000) }
            return !process.isRunning
        }
        guard process.isRunning else { return }
        if wait(grace) { return }
        kill(pid, SIGTERM)
        if wait(grace) { return }
        kill(pid, SIGKILL)
        _ = wait(grace)
    }

    /// Ends every Mac preview host (Ycode exits; tests). The registry lock
    /// is not held while hosts end.
    static func terminateAll() {
        lock.lock()
        let all = Array(hosts.values)
        hosts = [:]
        lock.unlock()
        for h in all { h.stop() }
    }

    /// The pids of the hosts this process runs (tests).
    static var runningPIDs: [pid_t] {
        lock.lock(); defer { lock.unlock() }
        return hosts.values.filter(\.process.isRunning).map(\.pid)
    }

    /// The host for a work directory, started (or restarted) when needed.
    static func shared(executable: URL, key: String) throws -> MacPreviewHostProcess {
        _ = exitHook
        lock.lock()
        if let h = hosts[key], h.process.isRunning, h.loads < PreviewUpdatePlanner.maximumLoads { lock.unlock(); return h }
        let old = hosts.removeValue(forKey: key)
        lock.unlock()
        old?.stop()
        let h = try MacPreviewHostProcess(executable: executable)
        lock.lock()
        hosts[key] = h
        lock.unlock()
        return h
    }

    /// The next line of output, waiting at most until `deadline`; nil at end
    /// of output or at the deadline.
    private func readLine(deadline: Date) -> String? {
        let fd = output.fileHandleForReading.fileDescriptor
        while true {
            if let nl = buffer.firstIndex(of: 0x0A) {
                let line = String(decoding: buffer[buffer.startIndex..<nl], as: UTF8.self)
                buffer.removeSubrange(buffer.startIndex...nl)
                return line
            }
            let left = deadline.timeIntervalSinceNow
            guard left > 0 else { return nil }
            var p = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            let r = poll(&p, 1, Int32(min(left, 1) * 1000))
            if r < 0 && errno != EINTR { return nil }
            if r <= 0 { continue }
            var chunk = [UInt8](repeating: 0, count: 4096)
            let n = read(fd, &chunk, chunk.count)
            if n <= 0 { return nil }
            buffer.append(contentsOf: chunk[0..<n])
        }
    }

    /// Sends a request and waits for its answer, at most `requestTimeout`
    /// (nil: the host ended, or hung and was killed).
    func send(_ r: PreviewMacHost.Request, newPayload: Bool) -> PreviewHost.Report? {
        MainThreadGuard.blockingCall("preview host request")
        ioLock.lock()
        guard !inputClosed, process.isRunning else { ioLock.unlock(); return nil }
        if newPayload { loads += 1 }
        let line = Data(r.line().utf8)
        let ok = line.withUnsafeBytes { b in write(input.fileHandleForWriting.fileDescriptor, b.baseAddress, b.count) == b.count }
        ioLock.unlock()
        guard ok else { stop(); return nil }
        let deadline = Date().addingTimeInterval(Self.requestTimeout)
        while let line = readLine(deadline: deadline) {
            guard let report = PreviewHost.parseReport(line) else { continue }
            switch report {
            case .started: continue
            case .ready(let g, _), .error(let g, _): if g == r.generation || g == 0 { return report }
            }
        }
        // End of output or no answer in time: the host is gone or hung.
        stop(grace: 0.5)
        return nil
    }
}

extension PreviewRenderer {
    /// Ends the Mac preview hosts (they otherwise live until Ycode exits).
    public static func stopMacHosts() { MacPreviewHostProcess.terminateAll() }

    /// The pids of the Mac preview hosts this process runs.
    public static var macHostPIDs: [pid_t] { MacPreviewHostProcess.runningPIDs }

    nonisolated(unsafe) private static var generation = 0
    nonisolated(unsafe) private static var sdkVersion: String?
    private static let generationLock = NSLock()

    /// The Mac SDK's version (`xcrun --sdk macosx --show-sdk-version`), read once.
    static func macSDKVersion() -> String {
        generationLock.lock(); defer { generationLock.unlock() }
        if let v = sdkVersion { return v }
        let v = (try? Subprocess.run("/usr/bin/xcrun", ["--sdk", "macosx", "--show-sdk-version"]))?.stdoutText
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? "15.0"
        sdkVersion = v.isEmpty ? "15.0" : v
        return sdkVersion!
    }

    /// Renders through a payload loaded into the long-lived Mac host: one
    /// compile of the module, no SwiftPM build, no new process. Linked
    /// modules (package targets with dependencies or resources) use
    /// `render` (the SwiftPM host).
    public func renderWithPayload(module: Module, file: URL, previews: [PreviewDeclaration], schemes: [ColorScheme] = [.light],
                                  timing: ((Timing) -> Void)? = nil) throws(Failure) -> [Rendered] {
        guard case .sources(let files) = module.kind else {
            return try render(module: module, file: file, previews: previews, schemes: schemes, timing: timing)
        }
        guard !previews.isEmpty else { return [] }
        let t0 = Date()
        let target = PreviewMacHost.deploymentTarget(sdkVersion: Self.macSDKVersion())
        let dir = workDirectory.appendingPathComponent("Live/macOS/\(module.name)")
        Self.generationLock.lock()
        Self.generation += 1
        let g = Self.generation
        Self.generationLock.unlock()
        let sources: PreviewPayloadGenerator.Sources
        do {
            sources = try PreviewPayloadGenerator.generate(moduleFiles: files, previewed: [PreviewedFile(url: file, previews: previews)],
                                                           platform: .macOS, into: dir.appendingPathComponent("src"))
        } catch { throw .run("Could not write the preview's sources: \(error)") }
        let payload = dir.appendingPathComponent("payload-\(g).dylib")
        let compiler = PreviewCompiler(platform: .macOS, deploymentTarget: target, moduleName: module.name,
                                       moduleCache: workDirectory.appendingPathComponent("ModuleCache"))
        do throws(PreviewFailure) { try compiler.compilePayload(sources, output: payload) } catch {
            throw .build(firstDiagnostic: error.issues.first?.description ?? error.description, log: error.description)
        }
        let exe: URL
        do throws(PreviewFailure) { exe = try PreviewMacHost.build(deploymentTarget: target, workDirectory: workDirectory) } catch {
            throw .run("The preview host could not be built: \(error.description)")
        }
        let t1 = Date()
        let out = dir.appendingPathComponent("Rendered-\(g)")
        try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let items = previews.enumerated().map { i, p in
            PreviewMacHost.Request.Item(index: i, width: Double(p.fixedSize?.width ?? 0), height: Double(p.fixedSize?.height ?? 0))
        }
        let request = PreviewMacHost.Request(generation: g, payload: payload.path, output: out.path, schemes: schemes.map(\.rawValue), items: items)
        let host: MacPreviewHostProcess
        do { host = try MacPreviewHostProcess.shared(executable: exe, key: workDirectory.path) } catch { throw .run("The preview host did not start: \(error)") }
        switch host.send(request, newPayload: true) {
        case .ready?: break
        case .error(_, let m)?: throw .run(m)
        default: throw .run("The preview host ended or did not answer in \(Int(MacPreviewHostProcess.requestTimeout)) s")
        }
        timing?(Timing(build: t1.timeIntervalSince(t0), run: Date().timeIntervalSince(t1)))
        // Older renders and payloads of this module go (the host keeps the images it loaded).
        for name in (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        where (name.hasPrefix("Rendered-") && name != out.lastPathComponent) || (name.hasPrefix("payload-") && name != payload.lastPathComponent) {
            try? FileManager.default.removeItem(at: dir.appendingPathComponent(name))
        }
        return schemes.flatMap { scheme in
            previews.enumerated().compactMap { i, p in
                let png = out.appendingPathComponent("\(i)-\(scheme.rawValue).png")
                return FileManager.default.fileExists(atPath: png.path) ? Rendered(name: p.name, png: png, scheme: scheme) : nil
            }
        }
    }
}
