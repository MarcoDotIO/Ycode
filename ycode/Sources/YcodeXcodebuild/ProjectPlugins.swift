import Foundation
import YcodeBuild
import YcodeProject
import YcodeSubprocess

/// Build-tool plug-ins applied to project targets: a target's
/// `PBXTargetDependency` whose `productRef` names a product `plugin:<name>`
/// (`specs/ide/build-pif.md` §Plug-ins).
///
/// Ycode hosts the plug-in itself, as SwiftPM does for package targets
/// (open-source protocol): it compiles the plug-in's sources against the
/// toolchain's `PackagePlugin` library and Ycode's own `XcodeProjectPlugin`
/// module (`XcodeProjectPluginSource`), sends the plug-in a
/// `createXcodeProjectBuildToolCommands` message describing the project and
/// the target, and turns the commands it answers with into custom tasks and
/// generated source files of the target's PIF.
public enum ProjectPlugins {
    /// Whether this host can run plug-ins for project targets: the open
    /// `PackagePlugin` runtime calls the project-plug-in entry point only on
    /// Darwin.
    public static var isSupported: Bool {
        #if os(macOS)
        true
        #else
        false
        #endif
    }

    /// One command a plug-in defined for a target.
    public struct BuildCommand: Equatable, Sendable {
        public var displayName: String?
        public var executable: String
        public var arguments: [String]
        public var environment: [String: String]
        public var workingDirectory: String?
        public var inputFiles: [String]
        public var outputFiles: [String]
    }

    /// What the plug-ins applied to one target produced.
    public struct TargetOutputs: Equatable, Sendable {
        /// The plug-ins' own PIF targets (host tools), as dependencies.
        public var pluginTargetGUIDs: [String] = []
        public var commands: [BuildCommand] = []
        /// Files written by prebuild commands, already run.
        public var prebuildOutputs: [String] = []
        public var diagnostics: [String] = []

        /// Generated files to compile (by extension).
        public var generatedSources: [String] {
            (commands.flatMap(\.outputFiles) + prebuildOutputs).filter { ProjectPlugins.isSource($0) }
        }

        /// Generated files to copy as resources.
        public var generatedResources: [String] {
            (commands.flatMap(\.outputFiles) + prebuildOutputs).filter { !ProjectPlugins.isSource($0) && !ProjectPlugins.isHeader($0) }
        }
    }

    static func isSource(_ path: String) -> Bool {
        ["swift", "c", "m", "mm", "cpp", "cc", "cxx", "s"].contains((path as NSString).pathExtension.lowercased())
    }

    static func isHeader(_ path: String) -> Bool {
        ["h", "hpp", "hh"].contains((path as NSString).pathExtension.lowercased())
    }

    /// The key of a target in `PackageGraphPIF.pluginOutputs`.
    static func key(_ project: LoadedProject, _ targetID: String) -> String { project.url.standardizedFileURL.path + "|" + targetID }

    /// Plug-ins a target applies: (product dependency id, plug-in name).
    static func applied(_ t: PBXObject, in proj: PBXProj) -> [(id: String, name: String)] {
        t.references("dependencies").compactMap { d in
            guard let ref = proj[d]?.string("productRef"), let name = proj[ref]?.string("productName"), name.hasPrefix("plugin:") else { return nil }
            return (ref, String(name.dropFirst("plugin:".count)))
        }
    }

    // MARK: Running the plug-ins of a container

    /// Runs every plug-in applied to a project target of the container.
    static func run(container: Container, graph: PackageGraphPIF, sourcePackages: URL, scratch: URL,
                    toolchain: Toolchain) throws -> [String: TargetOutputs] {
        var out: [String: TargetOutputs] = [:]
        var compiled: [String: URL] = [:]
        for p in container.projects {
            for t in p.targets {
                let plugins = applied(t, in: p.proj)
                guard !plugins.isEmpty else { continue }
                guard isSupported else {
                    throw PIFGenerator.GenerationError.unsupported("build-tool plug-ins of project targets need a Mac")
                }
                var outputs = TargetOutputs()
                for (refID, name) in plugins {
                    guard let package = pluginPackage(refID, name: name, project: p, graph: graph) else {
                        throw PIFGenerator.GenerationError.unsupported("no package provides the plug-in \(name)")
                    }
                    let plugin = try PluginDescription.load(name: name, packageDirectory: package.directory)
                    if let guid = package.pluginTargets[plugin.targetName] { outputs.pluginTargetGUIDs.append(guid) }
                    let exe: URL
                    if let e = compiled[package.directory + "|" + name] { exe = e } else {
                        exe = try toolchain.compile(plugin, into: sourcePackages.appendingPathComponent("ycode-plugins"))
                        compiled[package.directory + "|" + name] = exe
                    }
                    let work = sourcePackages.appendingPathComponent("ycode-plugins/outputs")
                        .appendingPathComponent(p.name).appendingPathComponent(t.string("name") ?? t.id).appendingPathComponent(name)
                    try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
                    // Tools are named where SwiftPM's own build would put them;
                    // `PackageGraphPIF.relocateHostTools` maps that folder to
                    // the client build's products folder.
                    var tools: [String: String] = [:]
                    for tool in plugin.toolNames { tools[tool] = scratch.path + "/out/Products/Debug/" + tool }
                    let input = WireInput.message(project: p, target: t, pluginWorkDirectory: work.path, tools: tools,
                                                  toolSearchDirectories: [toolchain.binDirectory])
                    let replies = try toolchain.runPlugin(exe, message: input, workingDirectory: package.directory)
                    for r in replies {
                        switch r {
                        case .build(let c): outputs.commands.append(c)
                        case .prebuild(let c, let dir):
                            try runPrebuild(c)
                            let files = (try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? []
                            outputs.prebuildOutputs += files.sorted().map { dir + "/" + $0 }
                        case .diagnostic(let d): outputs.diagnostics.append("\(name): \(d)")
                        }
                    }
                }
                out[key(p, t.id)] = outputs
            }
        }
        return out
    }

    /// The package that provides plug-in `name`: the product dependency's
    /// package reference, else the first package that has such a plug-in.
    static func pluginPackage(_ refID: String, name: String, project: LoadedProject, graph: PackageGraphPIF) -> PackageGraphPIF.Package? {
        if let ref = project.proj[refID]?.string("package").flatMap({ project.proj[$0] }) {
            var identity: String?
            if let rel = ref.string("relativePath") { identity = URL(fileURLWithPath: rel).lastPathComponent.lowercased() }
            if let url = ref.string("repositoryURL") { identity = PackageResolver.identity(of: url) }
            if let identity, let p = graph.package(identity: identity) { return p }
        }
        return graph.packages.first { (try? PluginDescription.load(name: name, packageDirectory: $0.directory)) != nil }
    }

    static func runPrebuild(_ c: BuildCommand) throws {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: c.executable)
        p.arguments = c.arguments
        p.environment = ProcessInfo.processInfo.environment.merging(c.environment) { $1 }
        if let d = c.workingDirectory { p.currentDirectoryURL = URL(fileURLWithPath: d) }
        p.standardInput = FileHandle.nullDevice
        try p.run()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else {
            throw PIFGenerator.GenerationError.unsupported("prebuild command \(c.displayName ?? c.executable) failed (\(p.terminationStatus))")
        }
    }

    // MARK: Plug-in descriptions

    /// A plug-in target as the package manifest declares it.
    struct PluginDescription {
        var targetName: String
        var sources: [URL]
        /// Names the plug-in may look up with `tool(named:)`: its executable
        /// target and product dependencies.
        var toolNames: [String]
        /// The package's tools version (`6.0.0`).
        var toolsVersion: String
        var packageDirectory: String

        /// From `swift package dump-package` (no resolution): the plug-in
        /// product `name` (or a plug-in target of that name), its folder
        /// (`Plugins/<target>` unless the manifest gives a path) and its
        /// dependencies.
        static func load(name: String, packageDirectory: String) throws -> PluginDescription {
            let json = try PackageResolver.dumpPackage(at: URL(fileURLWithPath: packageDirectory))
            let products = json["products"] as? [[String: Any]] ?? []
            let targets = json["targets"] as? [[String: Any]] ?? []
            let productTargets = products.first { ($0["name"] as? String) == name && ($0["type"] as? [String: Any])?.keys.contains("plugin") == true }?["targets"] as? [String]
            let targetName = productTargets?.first ?? name
            guard let t = targets.first(where: { $0["name"] as? String == targetName && $0["type"] as? String == "plugin" }) else {
                throw PIFGenerator.GenerationError.unsupported("\(packageDirectory) has no plug-in \(name)")
            }
            let dir = URL(fileURLWithPath: packageDirectory).appendingPathComponent(t["path"] as? String ?? "Plugins/\(targetName)")
            let sources = Self.swiftFiles(in: dir)
            var tools: [String] = []
            for d in t["dependencies"] as? [[String: Any]] ?? [] {
                for key in ["byName", "target", "product"] {
                    if let first = (d[key] as? [Any])?.first as? String { tools.append(first) }
                }
            }
            let version = (json["toolsVersion"] as? [String: Any])?["_version"] as? String ?? "5.9.0"
            return PluginDescription(targetName: targetName, sources: sources, toolNames: tools, toolsVersion: version,
                                     packageDirectory: packageDirectory)
        }

        static func swiftFiles(in dir: URL) -> [URL] {
            guard let e = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: nil) else { return [] }
            return e.compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" }.sorted { $0.path < $1.path }
        }
    }

    // MARK: The toolchain

    /// The compiler and plug-in library that compile and run plug-ins.
    struct Toolchain {
        /// `swiftc`.
        var swiftc: String
        /// `<toolchain>/usr/lib/swift/pm/PluginAPI`: `PackagePlugin`'s module and library.
        var pluginAPI: String
        /// The macOS SDK (nil elsewhere).
        var sdk: String?
        var binDirectory: String { URL(fileURLWithPath: swiftc).deletingLastPathComponent().path }

        /// The toolchain of `swift` (the `swift` driver PackageGraphLoader
        /// uses): on the Mac, `xcrun --find swiftc` when `swift` is the
        /// `/usr/bin` shim.
        static func locate(swift: String) throws -> Toolchain {
            var swiftc = URL(fileURLWithPath: swift).resolvingSymlinksInPath().deletingLastPathComponent().appendingPathComponent("swiftc").path
            var sdk: String?
            #if os(macOS)
            if swiftc.hasPrefix("/usr/bin/") || !FileManager.default.fileExists(atPath: swiftc) {
                if let found = try? PackageResolver.run("/usr/bin/xcrun", ["--find", "swiftc"], in: nil).trimmingCharacters(in: .whitespacesAndNewlines) {
                    swiftc = found
                }
            }
            sdk = try? PackageResolver.run("/usr/bin/xcrun", ["--sdk", "macosx", "--show-sdk-path"], in: nil).trimmingCharacters(in: .whitespacesAndNewlines)
            #endif
            let api = URL(fileURLWithPath: swiftc).deletingLastPathComponent().deletingLastPathComponent()
                .appendingPathComponent("lib/swift/pm/PluginAPI").path
            guard FileManager.default.fileExists(atPath: api) else {
                throw PIFGenerator.GenerationError.unsupported("no PackagePlugin library in \(api)")
            }
            return Toolchain(swiftc: swiftc, pluginAPI: api, sdk: sdk)
        }

        func compileCommon(_ args: [String]) throws {
            var a = args
            if let sdk { a += ["-sdk", sdk] }
            do { _ = try PackageResolver.run(swiftc, a, in: nil) } catch {
                throw PIFGenerator.GenerationError.unsupported("cannot compile a plug-in: \(error)")
            }
        }

        /// Ycode's `XcodeProjectPlugin` module and library, compiled once per
        /// source text into `<dir>/support-<hash>/`.
        func supportLibrary(in dir: URL) throws -> URL {
            let src = XcodeProjectPluginSource.text
            let out = dir.appendingPathComponent("support-" + String(MD5.hex(src + swiftc).prefix(12)))
            let lib = out.appendingPathComponent("libXcodeProjectPlugin.dylib")
            if FileManager.default.fileExists(atPath: lib.path) { return out }
            try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
            let file = out.appendingPathComponent("XcodeProjectPlugin.swift")
            try Data(src.utf8).write(to: file)
            try compileCommon(["-parse-as-library", "-emit-library", "-emit-module", "-module-name", "XcodeProjectPlugin",
                               "-swift-version", "5", "-package-description-version", "6.0.0",
                               "-I", pluginAPI, "-L", pluginAPI, "-lPackagePlugin", "-Xlinker", "-rpath", "-Xlinker", pluginAPI,
                               "-Xlinker", "-install_name", "-Xlinker", lib.path,
                               "-emit-module-path", out.appendingPathComponent("XcodeProjectPlugin.swiftmodule").path,
                               file.path, "-o", lib.path])
            return out
        }

        /// Compiles a plug-in's sources into `<dir>/<package>-<plugin>-<hash>`
        /// (the hash covers the sources, the compiler and the support module).
        func compile(_ plugin: PluginDescription, into dir: URL) throws -> URL {
            let support = try supportLibrary(in: dir)
            var hashInput = swiftc + plugin.toolsVersion + support.path
            for s in plugin.sources { hashInput += s.path + ((try? String(contentsOf: s, encoding: .utf8)) ?? "") }
            let exe = dir.appendingPathComponent(URL(fileURLWithPath: plugin.packageDirectory).lastPathComponent + "-" + plugin.targetName
                                                 + "-" + String(MD5.hex(hashInput).prefix(12)))
            if FileManager.default.isExecutableFile(atPath: exe.path) { return exe }
            let major = Int(plugin.toolsVersion.split(separator: ".").first ?? "5") ?? 5
            try compileCommon(["-parse-as-library", "-swift-version", major >= 6 ? "6" : "5",
                               "-package-description-version", plugin.toolsVersion,
                               "-I", pluginAPI, "-L", pluginAPI, "-lPackagePlugin", "-Xlinker", "-rpath", "-Xlinker", pluginAPI,
                               "-I", support.path, "-L", support.path, "-lXcodeProjectPlugin"]
                              + plugin.sources.map(\.path) + ["-o", exe.path])
            return exe
        }

        /// Runs a plug-in: sends one message (an 8-byte little-endian length,
        /// then JSON) and reads its messages until it exits.
        func runPlugin(_ exe: URL, message: Data, workingDirectory: String) throws -> [Reply] {
            MainThreadGuard.blockingCall("build-tool plug-in")
            let p = Process()
            p.executableURL = exe
            p.currentDirectoryURL = URL(fileURLWithPath: workingDirectory)
            // Ycode's XcodeProjectPlugin module writes the commands here.
            let commandsFile = FileManager.default.temporaryDirectory.appendingPathComponent("ycode-plugin-\(UUID().uuidString).json")
            defer { try? FileManager.default.removeItem(at: commandsFile) }
            p.environment = ProcessInfo.processInfo.environment.merging(["YCODE_PLUGIN_COMMANDS": commandsFile.path]) { $1 }
            let input = Pipe(), output = Pipe(), errors = Pipe()
            p.standardInput = input
            p.standardOutput = output
            p.standardError = errors
            try p.run()
            var length = UInt64(message.count).littleEndian
            input.fileHandleForWriting.write(withUnsafeBytes(of: &length) { Data($0) } + message)
            final class Box: @unchecked Sendable { var data = Data() }
            let err = Box()
            let group = DispatchGroup()
            group.enter()
            let errHandle = errors.fileHandleForReading
            // A thread, not a global queue (see Subprocess.run).
            Thread { err.data = errHandle.readDataToEndOfFile(); group.leave() }.start()
            let data = output.fileHandleForReading.readDataToEndOfFile()
            try? input.fileHandleForWriting.close()
            group.wait()
            p.waitUntilExit()
            var replies = WireOutput.replies(in: data)
            if let d = FileManager.default.contents(atPath: commandsFile.path) { replies += WireOutput.commands(inFile: d) }
            guard p.terminationStatus == 0 else {
                let diagnostics = replies.compactMap { if case .diagnostic(let d) = $0 { d } else { nil } }
                throw PIFGenerator.GenerationError.unsupported("plug-in \(exe.lastPathComponent) failed: "
                    + (diagnostics + [String(decoding: err.data, as: UTF8.self)]).joined(separator: "\n"))
            }
            return replies
        }
    }

    enum Reply {
        case build(BuildCommand)
        case prebuild(BuildCommand, outputDirectory: String)
        case diagnostic(String)
    }

    // MARK: Wire format (SwiftPM's PackagePlugin protocol, open source)

    enum WireInput {
        /// `{"createXcodeProjectBuildToolCommands": {context, rootProjectId,
        /// targetId, pluginGeneratedSources, pluginGeneratedResources}}`
        /// for one project target. Every path is its own entry with no base.
        static func message(project: LoadedProject, target: PBXObject, pluginWorkDirectory: String, tools: [String: String],
                            toolSearchDirectories: [String]) -> Data {
            var paths: [[String: Any]] = []
            var ids: [String: Int] = [:]
            func id(_ path: String) -> Int {
                if let i = ids[path] { return i }
                paths.append(["subpath": String(path.drop { $0 == "/" })])
                ids[path] = paths.count - 1
                return paths.count - 1
            }
            let proj = project.proj
            let parents = proj.parentMap()
            var xcodeTargets: [[String: Any]] = []
            var allFiles: [Int] = []
            var targetIndex = 0
            for (i, t) in proj.targets.enumerated() {
                if t.id == target.id { targetIndex = i }
                var files: [[String: Any]] = []
                for pid in t.references("buildPhases") {
                    guard let phase = proj[pid] else { continue }
                    for bf in phase.references("files") {
                        guard let ref = proj[bf]?.string("fileRef"),
                              let path = proj.resolvedPath(of: ref, projectDirectory: project.directory, parents: parents), path.hasPrefix("/") else { continue }
                        let url = URL(fileURLWithPath: path)
                        let type: String = switch phase.isa {
                        case "PBXSourcesBuildPhase": "source"
                        case "PBXHeadersBuildPhase": "header"
                        case "PBXResourcesBuildPhase": "resource"
                        default: "unknown"
                        }
                        files.append(["basePathId": id(url.deletingLastPathComponent().path), "name": url.lastPathComponent, "type": type])
                        allFiles.append(id(path))
                    }
                }
                let productType = t.string("productType") ?? ""
                let kind: [String: Any] = productType.hasPrefix("com.apple.product-type.application") ? ["application": [String: Any]()]
                    : productType == "com.apple.product-type.tool" ? ["executable": [String: Any]()]
                    : productType == "com.apple.product-type.framework" ? ["framework": [String: Any]()]
                    : productType.hasPrefix("com.apple.product-type.library") ? ["library": [String: Any]()]
                    : ["other": ["_0": productType]]
                let productName = t.string("productReference").flatMap { proj[$0]?.string("path") } ?? (t.string("name") ?? "")
                xcodeTargets.append(["displayName": t.string("name") ?? "", "product": ["name": productName, "kind": kind],
                                     "dependencies": [Any](), "inputFiles": files])
            }
            let projectEntry: [String: Any] = ["displayName": project.name, "directoryPathId": id(project.directory.path),
                                               "dependencies": [Any](), "urlIds": allFiles, "targetIds": Array(proj.targets.indices)]
            let work = id(pluginWorkDirectory)
            let search = toolSearchDirectories.map(id)
            var accessible: [String: Any] = [:]
            for (name, path) in tools { accessible[name] = ["path": id(path)] }
            let context: [String: Any] = ["paths": paths, "targets": [Any](), "products": [Any](), "packages": [Any](),
                                          "xcodeTargets": xcodeTargets, "xcodeProjects": [projectEntry],
                                          "pluginWorkDirId": work, "toolSearchDirIds": search, "accessibleTools": accessible]
            let message: [String: Any] = ["createXcodeProjectBuildToolCommands": [
                "context": context, "rootProjectId": 0, "targetId": targetIndex,
                "pluginGeneratedSources": [Int](), "pluginGeneratedResources": [Int](),
            ] as [String: Any]]
            return (try? JSONSerialization.data(withJSONObject: message, options: [.sortedKeys])) ?? Data()
        }
    }

    enum WireOutput {
        /// The plug-in's messages: each an 8-byte little-endian length and JSON.
        static func replies(in data: Data) -> [Reply] {
            var out: [Reply] = []
            var i = data.startIndex
            while data.endIndex - i >= 8 {
                var length: UInt64 = 0
                for k in 0..<8 { length |= UInt64(data[i + k]) << (8 * UInt64(k)) }
                i += 8
                guard data.endIndex - i >= Int(length) else { break }
                let payload = data[i..<(i + Int(length))]
                i += Int(length)
                guard let obj = try? JSONSerialization.jsonObject(with: payload) as? [String: Any] else { continue }
                if let r = reply(obj) { out.append(r) }
            }
            return out
        }

        /// The commands file of Ycode's XcodeProjectPlugin module: a JSON
        /// array of `{kind: build|prebuild, displayName, executable,
        /// arguments, environment, inputFiles, outputFiles,
        /// outputFilesDirectory}`.
        static func commands(inFile data: Data) -> [Reply] {
            guard let list = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return [] }
            return list.compactMap { c in
                guard let exe = c["executable"] as? String else { return nil }
                let name = (c["displayName"] as? String).flatMap { $0.isEmpty ? nil : $0 }
                var cmd = BuildCommand(displayName: name, executable: exe, arguments: c["arguments"] as? [String] ?? [],
                                       environment: c["environment"] as? [String: String] ?? [:], workingDirectory: nil,
                                       inputFiles: c["inputFiles"] as? [String] ?? [], outputFiles: c["outputFiles"] as? [String] ?? [])
                if c["kind"] as? String == "prebuild" {
                    cmd.inputFiles = []
                    return .prebuild(cmd, outputDirectory: c["outputFilesDirectory"] as? String ?? "")
                }
                return .build(cmd)
            }
        }

        static func reply(_ obj: [String: Any]) -> Reply? {
            if let b = obj["defineBuildCommand"] as? [String: Any], let c = command(b["configuration"]) {
                var cmd = c
                cmd.inputFiles = (b["inputFiles"] as? [Any] ?? []).compactMap(path)
                cmd.outputFiles = (b["outputFiles"] as? [Any] ?? []).compactMap(path)
                return .build(cmd)
            }
            if let b = obj["definePrebuildCommand"] as? [String: Any], let c = command(b["configuration"]),
               let dir = path(b["outputFilesDirectory"] as Any) {
                return .prebuild(c, outputDirectory: dir)
            }
            if let d = obj["emitDiagnostic"] as? [String: Any] {
                let location = (d["file"] as? String).map { f in (d["line"] as? Int).map { "\(f):\($0): " } ?? "\(f): " } ?? ""
                return .diagnostic("\(location)\(d["severity"] as? String ?? "error"): \(d["message"] as? String ?? "")")
            }
            return nil
        }

        static func command(_ any: Any?) -> BuildCommand? {
            guard let c = any as? [String: Any], let exe = path(c["executable"] as Any) else { return nil }
            return BuildCommand(displayName: c["displayName"] as? String, executable: exe, arguments: c["arguments"] as? [String] ?? [],
                                environment: c["environment"] as? [String: String] ?? [:],
                                workingDirectory: c["workingDirectory"].flatMap(path), inputFiles: [], outputFiles: [])
        }

        /// A `URL` as Foundation encodes it (`{"relative": "file:///…"}`) or a
        /// plain string; nil for other shapes.
        static func path(_ any: Any) -> String? {
            let text: String?
            if let s = any as? String { text = s } else if let d = any as? [String: Any] { text = d["relative"] as? String } else { text = nil }
            guard let text else { return nil }
            if text.hasPrefix("file://"), let u = URL(string: text) { return u.path }
            return text
        }
    }
}
