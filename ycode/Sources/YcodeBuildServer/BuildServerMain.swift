import Foundation
import YcodeDebug
import YcodeWorkspace
import YcodeXcodebuild

/// The command line of the build server (`ycode-bsp`, `ycode bsp`):
///
///     ycode-bsp [serve] <container> [options]      BSP over stdin/stdout (what sourcekit-lsp starts)
///     ycode-bsp config <container> [options] [--output DIR]
///                                                  writes DIR/.bsp/ycode.json (default: the container's folder)
///     ycode-bsp targets <container> [options]      lists targets, sources and dependencies
///     ycode-bsp args <container> <file> [--target NAME] [options]
///                                                  prints a file's compiler arguments, one per line
///     ycode-bsp prepare <container> <target name>… [options]
///                                                  emits the modules the targets need
///     ycode-bsp sample <dir> [ios|portable]       writes the sample project (Kit, App, AppTests)
///
/// Options: `--scheme S`, `--configuration C`, `--destination D`,
/// `--derived-data DIR` (the derived-data root), `--settings resolver|swift-build`,
/// `--log FILE`. See `specs/ide/language.md` §Build server.
public enum BuildServerMain {
    public struct Options {
        public var command = "serve"
        public var container: String?
        public var positional: [String] = []
        public var scheme: String?
        public var configuration: String?
        public var destination: String?
        public var derivedDataRoot: String?
        public var settings: String?
        public var output: String?
        public var target: String?
        public var log: String?
    }

    public static let usage = """
    usage: ycode-bsp [serve|config|targets|args|prepare] <path.xcodeproj|.xcworkspace> [arguments]
           ycode-bsp sample <dir> [ios|portable]
                     [--scheme S] [--configuration C] [--destination D] [--derived-data DIR]
                     [--settings resolver|swift-build] [--log FILE] [--output DIR] [--target NAME]

    """

    public static func parse(_ args: [String]) -> Options? {
        var o = Options()
        var it = args.makeIterator()
        var first = true
        while let a = it.next() {
            switch a {
            case "--scheme": o.scheme = it.next()
            case "--configuration": o.configuration = it.next()
            case "--destination": o.destination = it.next()
            case "--derived-data": o.derivedDataRoot = it.next()
            case "--settings": o.settings = it.next()
            case "--output": o.output = it.next()
            case "--target": o.target = it.next()
            case "--log": o.log = it.next()
            default:
                if a.hasPrefix("--") { return nil }
                if first, ["serve", "config", "targets", "args", "prepare", "sample"].contains(a) { o.command = a } else if o.container == nil {
                    o.container = a
                } else {
                    o.positional.append(a)
                }
            }
            first = false
        }
        return o.container == nil ? nil : o
    }

    /// Runs a command; returns the exit status (`serve` returns when the
    /// client exits or closes the channel).
    public static func run(_ args: [String]) -> Int32 {
        guard let o = parse(args), let path = o.container else {
            FileHandle.standardError.write(Data(usage.utf8))
            return 2
        }
        let url = URL(fileURLWithPath: path.hasPrefix("/") ? path : FileManager.default.currentDirectoryPath + "/" + path).standardizedFileURL
        if o.command == "config" { return writeConfig(url, o) }
        if o.command == "sample" {
            do {
                print(try SampleProject.write(o.positional.first == "portable" ? .portable : .iOS, in: url).path)
                return 0
            } catch {
                FileHandle.standardError.write(Data("ycode-bsp sample: \(error)\n".utf8))
                return 1
            }
        }
        let logHandle = o.log.flatMap { p -> FileHandle? in
            FileManager.default.createFile(atPath: p, contents: nil)
            return FileHandle(forWritingAtPath: p)
        }
        let log: @Sendable (String) -> Void = { line in
            let text = Data((ISO8601DateFormatter().string(from: Date()) + " " + line + "\n").utf8)
            if let logHandle { logHandle.write(text) } else { FileHandle.standardError.write(text) }
        }
        let model: IndexModel
        do { model = try makeModel(url, o) } catch {
            log("ycode-bsp: \(error)")
            FileHandle.standardError.write(Data("ycode-bsp: \(error)\n".utf8))
            return 1
        }
        for d in model.diagnostics { log("ycode-bsp: \(d)") }
        switch o.command {
        case "targets": return listTargets(model)
        case "args": return printArguments(model, o)
        case "prepare": return prepare(model, o, log: log)
        default: return serve(model, log: log)
        }
    }

    public static func makeModel(_ url: URL, _ o: Options) throws -> IndexModel {
        let env = ProcessInfo.processInfo.environment
        var root = o.derivedDataRoot ?? env["YCODE_DERIVED_DATA"] ?? BuildContext.defaultDerivedDataRoot()
        if !root.hasPrefix("/") { root = FileManager.default.currentDirectoryPath + "/" + root }
        root = URL(fileURLWithPath: root).standardizedFileURL.path
        var configuration = o.configuration
        if configuration == nil, let s = o.scheme { configuration = IndexModel.configuration(ofScheme: s, in: url) }
        let context = BuildContext(configuration: configuration, destination: o.destination,
                                   derivedDataFolder: BuildContext.derivedDataFolder(for: url, root: root),
                                   developerDirectory: BuildContext.currentIsLinux ? nil : Workspace.activeDeveloperDirectory())
        let source: IndexSettingsSource
        let helper = SwiftBuildSettingsProvider.locate(environment: env, executableDirectory: Bundle.main.executableURL?.deletingLastPathComponent().path)
        switch o.settings {
        case "swift-build":
            guard let helper else { throw MainError(description: "--settings swift-build: the ycode-swb helper was not found (YCODE_SWB)") }
            source = SwiftBuildSettingsSource(helper: helper)
        default:
            source = ResolverSettingsSource()
        }
        return try IndexModel(containerURL: url, context: context, settingsSource: source)
    }

    struct MainError: Error, CustomStringConvertible { var description: String }

    // MARK: Commands

    static func serve(_ model: IndexModel, log: @escaping @Sendable (String) -> Void) -> Int32 {
        let out = FileHandle.standardOutput
        let outLock = NSLock()
        let server = BuildServer(model: model, send: { data in outLock.withLock { out.write(data) } }, log: log)
        let done = DispatchSemaphore(value: 0)
        server.onExit = { done.signal() }
        server.startWatching()
        log("ycode-bsp: serving \(model.containerURL.path) (\(model.graph.targets.count) targets)")
        Thread {
            let input = FileHandle.standardInput
            while true {
                let data = input.availableData
                if data.isEmpty { break }
                server.receive(data)
            }
            done.signal()
        }.start()
        done.wait()
        log("ycode-bsp: exiting")
        return 0
    }

    static func listTargets(_ model: IndexModel) -> Int32 {
        let graph = model.graph
        for t in graph.targets {
            let deps = t.dependencies.compactMap { graph.target(id: $0)?.name }
            print("\(t.name) [\(t.productType)] languages: \(t.languages.map(\.rawValue).joined(separator: ", "))"
                + (deps.isEmpty ? "" : " depends on: \(deps.joined(separator: ", "))")
                + (t.packageProducts.isEmpty ? "" : " packages: \(t.packageProducts.joined(separator: ", "))"))
            for s in t.sources { print("  \(s.language.rawValue) \(s.path)") }
            for h in t.headers { print("  header (\(h.visibility.rawValue)) \(h.path)") }
        }
        return 0
    }

    static func printArguments(_ model: IndexModel, _ o: Options) -> Int32 {
        guard let file = o.positional.first else {
            FileHandle.standardError.write(Data("ycode-bsp args: name a file\n".utf8))
            return 2
        }
        let path = URL(fileURLWithPath: file.hasPrefix("/") ? file : FileManager.default.currentDirectoryPath + "/" + file).standardizedFileURL.path
        let targetID = o.target.flatMap { name in model.graph.targets.first { $0.name == name }?.id }
        guard let r = model.arguments(for: path, targetID: targetID) else {
            FileHandle.standardError.write(Data("ycode-bsp args: \(path) is not in any target\n".utf8))
            return 1
        }
        print(r.arguments.joined(separator: "\n"))
        return 0
    }

    static func prepare(_ model: IndexModel, _ o: Options, log: @escaping @Sendable (String) -> Void) -> Int32 {
        let ids = o.positional.compactMap { name in model.graph.targets.first { $0.name == name }?.id }
        let steps = ModulePreparer(model: model, log: log).prepare(ids)
        var failed = false
        for s in steps {
            let name = model.graph.target(id: s.target)?.name ?? s.target
            if s.packages {
                print("\(name) package products: \(s.succeeded ? "built" : "failed")")
            } else {
                print("\(name): \(s.ran ? (s.succeeded ? "emitted" : "failed") : (s.succeeded ? "up to date" : "skipped"))")
            }
            if !s.succeeded { failed = true; print(s.output) }
        }
        return failed ? 1 : 0
    }

    static func writeConfig(_ url: URL, _ o: Options) -> Int32 {
        let exe = Bundle.main.executableURL?.resolvingSymlinksInPath().path ?? CommandLine.arguments[0]
        // `ycode bsp config` names `ycode bsp serve`.
        var argv = URL(fileURLWithPath: exe).lastPathComponent == "ycode" ? [exe, "bsp", "serve", url.path] : [exe, "serve", url.path]
        if let s = o.scheme { argv += ["--scheme", s] }
        if let c = o.configuration { argv += ["--configuration", c] }
        if let d = o.destination { argv += ["--destination", d] }
        if let r = o.derivedDataRoot {
            argv += ["--derived-data", r.hasPrefix("/") ? r : FileManager.default.currentDirectoryPath + "/" + r]
        }
        let dir = URL(fileURLWithPath: o.output ?? url.deletingLastPathComponent().path)
        do {
            let file = try BuildServerConfigFile.write(argv: argv, into: dir)
            print(file.path)
            return 0
        } catch {
            FileHandle.standardError.write(Data("ycode-bsp config: \(error)\n".utf8))
            return 1
        }
    }
}

/// The BSP connection file (`.bsp/ycode.json`) sourcekit-lsp finds in a
/// workspace folder.
public enum BuildServerConfigFile {
    public static func json(argv: [String]) -> JSON {
        [
            "name": "Ycode",
            "version": .string(BuildServer.version),
            "bspVersion": .string(BuildServer.bspVersion),
            "languages": .array(SourceLanguage.allCases.map { .string($0.rawValue) }),
            "argv": .array(argv.map(JSON.string)),
        ]
    }

    @discardableResult
    public static func write(argv: [String], into directory: URL) throws -> URL {
        let dir = directory.appendingPathComponent(".bsp")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent("ycode.json")
        try json(argv: argv).encoded().write(to: file, options: .atomic)
        return file
    }
}
