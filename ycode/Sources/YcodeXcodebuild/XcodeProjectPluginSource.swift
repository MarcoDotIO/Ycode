/// The source of Ycode's `XcodeProjectPlugin` module, compiled next to the
/// plug-ins Ycode runs for project targets (`ProjectPlugins`).
///
/// Plug-ins written for project targets import a module of that name (an
/// interoperability identifier) and conform to `XcodeBuildToolPlugin`. The
/// open-source `PackagePlugin` runtime decodes the host's
/// `createXcodeProjectBuildToolCommands` message into an invocation record
/// and calls the C entry point
/// `call_XcodeProjectPlugin_build_command_creation_entry_point`, which this
/// module provides. The record's type is not in the toolchain's public
/// `PackagePlugin` interface, so the module reads the record by reflection
/// (its stored properties, as the open-source runtime declares them), wraps
/// it in the public types (as Apple's public documentation names them),
/// calls the plug-in, and writes the commands as JSON to the file named by
/// `YCODE_PLUGIN_COMMANDS`, which Ycode reads after the plug-in exits. See
/// `specs/ide/build-pif.md` §Plug-ins.
enum XcodeProjectPluginSource {
    static let text = #"""
    // Ycode's XcodeProjectPlugin module (generated; see Ycode's
    // specs/ide/build-pif.md). Built against the toolchain's PackagePlugin.
    import Foundation
    import PackagePlugin

    /// A plug-in that creates build commands for a target of a project.
    public protocol XcodeBuildToolPlugin {
        func createBuildCommands(context: XcodePluginContext, target: XcodeTarget) throws -> [Command]
    }

    /// A plug-in that performs a command on a project.
    public protocol XcodeCommandPlugin {
        func performCommand(context: XcodePluginContext, arguments: [String]) throws
    }

    /// What a project plug-in is given.
    public struct XcodePluginContext {
        public let xcodeProject: XcodeProject
        public let pluginWorkDirectoryURL: URL
        public var pluginWorkDirectory: Path { Path(pluginWorkDirectoryURL.path) }
        let accessibleTools: [String: (path: URL, triples: [String]?)]
        let toolSearchDirectoryURLs: [URL]

        /// A tool the plug-in depends on, or one found in the tool search
        /// directories.
        public func tool(named name: String) throws -> PluginContext.Tool {
            if let t = accessibleTools[name] { return try makeTool(name: name, url: t.path) }
            for dir in toolSearchDirectoryURLs {
                let url = dir.appendingPathComponent(name)
                if FileManager.default.isExecutableFile(atPath: url.path) { return try makeTool(name: name, url: url) }
            }
            throw XcodeProjectPluginError.toolNotFound(name)
        }
    }

    /// `PluginContext.Tool`'s stored properties in the open-source runtime's
    /// order. Its initializer is not public, so a tool is made from this
    /// layout and checked before it is used.
    struct ToolLayout {
        var name: String
        var url: URL
        var path: Path
    }

    func makeTool(name: String, url: URL) throws -> PluginContext.Tool {
        let layout = ToolLayout(name: name, url: url, path: Path(url.path))
        guard MemoryLayout<ToolLayout>.size == MemoryLayout<PluginContext.Tool>.size else { throw XcodeProjectPluginError.toolLayout }
        let tool = withUnsafeBytes(of: layout) { $0.load(as: PluginContext.Tool.self) }
        guard tool.name == name, tool.url == url else { throw XcodeProjectPluginError.toolLayout }
        return tool
    }

    /// A project.
    public struct XcodeProject {
        public let id: String
        public let displayName: String
        public let directoryURL: URL
        public var directory: Path { Path(directoryURL.path) }
        public let filePaths: PathList
        public let targets: [XcodeTarget]
    }

    /// A target of a project.
    public struct XcodeTarget {
        public let id: String
        public let displayName: String
        public let product: XcodeProduct?
        public let inputFiles: FileList
        public let pluginGeneratedSources: [URL]
        public let pluginGeneratedResources: [URL]
    }

    /// The product of a target.
    public struct XcodeProduct {
        public let id: String
        public let name: String
        public let kind: Kind

        public enum Kind {
            case application
            case executable
            case framework
            case library
            case other(String)
        }
    }

    public enum XcodeProjectPluginError: Error, CustomStringConvertible {
        case toolNotFound(String)
        case notABuildToolPlugin
        case noTarget
        case noHost
        case toolLayout
        case record(String)

        public var description: String {
            switch self {
            case .toolNotFound(let n): "no tool named \(n)"
            case .notABuildToolPlugin: "the plug-in does not conform to XcodeBuildToolPlugin"
            case .noTarget: "the request names no target"
            case .noHost: "YCODE_PLUGIN_COMMANDS is not set: the plug-in host is not Ycode"
            case .toolLayout: "this PackagePlugin library's tool type is not the one Ycode knows"
            case .record(let s): "unexpected invocation record: \(s)"
            }
        }
    }

    // MARK: Reading the runtime's invocation record (by reflection)

    func field(_ value: Any, _ name: String) -> Any? {
        Mirror(reflecting: value).children.first { $0.label == name }?.value
    }

    /// A stored property the module cannot do without.
    func require<T>(_ value: Any, _ name: String, as _: T.Type = T.self) throws -> T {
        guard let v = field(value, name) as? T else {
            let labels = Mirror(reflecting: value).children.compactMap(\.label)
            throw XcodeProjectPluginError.record("\(name) (\(T.self)) not among \(labels) of \(type(of: value))")
        }
        return v
    }

    /// The wrapped value of an optional, nil for `.none`.
    func unwrap(_ value: Any?) -> Any? {
        guard let value else { return nil }
        let m = Mirror(reflecting: value)
        guard m.displayStyle == .optional else { return value }
        return m.children.first?.value
    }

    func xcodeTarget(_ t: Any) throws -> XcodeTarget {
        var product: XcodeProduct?
        if let p = unwrap(field(t, "product")) {
            let name = field(p, "name") as? String ?? ""
            let k = field(p, "kind") as Any
            let kind: XcodeProduct.Kind
            switch String(describing: k) {
            case "application": kind = .application
            case "executable": kind = .executable
            case "framework": kind = .framework
            case "library": kind = .library
            default: kind = .other(Mirror(reflecting: k).children.first?.value as? String ?? String(describing: k))
            }
            product = XcodeProduct(id: name, name: name, kind: kind)
        }
        return XcodeTarget(id: field(t, "id") as? String ?? "", displayName: field(t, "displayName") as? String ?? "", product: product,
                           inputFiles: try require(t, "inputFiles"),
                           pluginGeneratedSources: field(t, "pluginGeneratedSources") as? [URL] ?? [],
                           pluginGeneratedResources: field(t, "pluginGeneratedResources") as? [URL] ?? [])
    }

    func context(_ record: AnyObject) throws -> XcodePluginContext {
        guard let p = field(record, "xcodeProject") else {
            throw XcodeProjectPluginError.record("no xcodeProject in \(Mirror(reflecting: record).children.compactMap(\.label))")
        }
        let project = XcodeProject(id: field(p, "id") as? String ?? "", displayName: field(p, "displayName") as? String ?? "",
                                   directoryURL: field(p, "directoryPathURL") as? URL ?? URL(fileURLWithPath: "/"),
                                   filePaths: try require(p, "filePaths"),
                                   targets: try (field(p, "targets") as? [Any] ?? []).map(xcodeTarget))
        return XcodePluginContext(xcodeProject: project,
                                  pluginWorkDirectoryURL: field(record, "pluginWorkDirectoryURL") as? URL ?? URL(fileURLWithPath: "/tmp"),
                                  accessibleTools: field(record, "accessibleToolsByURL") as? [String: (path: URL, triples: [String]?)] ?? [:],
                                  toolSearchDirectoryURLs: field(record, "toolSearchDirectoryURLs") as? [URL] ?? [])
    }

    /// Writes the commands for the host (`YCODE_PLUGIN_COMMANDS`).
    func deliver(_ commands: [Command]) throws {
        guard let path = ProcessInfo.processInfo.environment["YCODE_PLUGIN_COMMANDS"] else {
            throw XcodeProjectPluginError.noHost
        }
        let list: [[String: Any]] = commands.map { c in
            switch c {
            case let .buildCommand(displayName, executable, arguments, environment, inputFiles, outputFiles):
                return ["kind": "build", "displayName": displayName ?? "", "executable": executable.path, "arguments": arguments,
                        "environment": environment, "inputFiles": inputFiles.map(\.path), "outputFiles": outputFiles.map(\.path)]
            case let .prebuildCommand(displayName, executable, arguments, environment, outputFilesDirectory):
                return ["kind": "prebuild", "displayName": displayName ?? "", "executable": executable.path, "arguments": arguments,
                        "environment": environment, "outputFilesDirectory": outputFilesDirectory.path]
            @unknown default:
                return [:]
            }
        }
        try JSONSerialization.data(withJSONObject: list).write(to: URL(fileURLWithPath: path))
    }

    /// Called by the PackagePlugin runtime for a build-tool request.
    @_cdecl("call_XcodeProjectPlugin_build_command_creation_entry_point")
    public func callXcodeProjectPluginBuildCommandCreation(_ pointer: UnsafeRawPointer) -> (any Error)? {
        let record = Unmanaged<AnyObject>.fromOpaque(pointer).takeUnretainedValue()
        guard let plugin = field(record, "plugin") as? XcodeBuildToolPlugin else { return XcodeProjectPluginError.notABuildToolPlugin }
        guard let target = unwrap(field(record, "xcodeTarget")) else { return XcodeProjectPluginError.noTarget }
        do {
            try deliver(try plugin.createBuildCommands(context: try context(record), target: try xcodeTarget(target)))
            return nil
        } catch {
            return error
        }
    }

    /// Called by the PackagePlugin runtime for a command request.
    @_cdecl("call_XcodeProjectPlugin_custom_command_entry_point")
    public func callXcodeProjectPluginCustomCommand(_ pointer: UnsafeRawPointer) -> (any Error)? {
        let record = Unmanaged<AnyObject>.fromOpaque(pointer).takeUnretainedValue()
        guard let plugin = field(record, "plugin") as? XcodeCommandPlugin else { return XcodeProjectPluginError.notABuildToolPlugin }
        do {
            try plugin.performCommand(context: try context(record), arguments: field(record, "arguments") as? [String] ?? [])
            return nil
        } catch {
            return error
        }
    }
    """#
}
