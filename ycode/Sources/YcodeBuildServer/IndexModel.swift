import Foundation
import YcodeWorkspace
import YcodeXcodebuild

/// The build server's view of one container: its targets and each target's
/// settings for the build context, reloaded when the project changes.
public final class IndexModel: @unchecked Sendable {
    public let containerURL: URL
    public let context: BuildContext
    public let settingsSource: IndexSettingsSource
    private let lock = NSLock()
    private var _graph: BuildGraph
    private var settings: [String: [String: String]]
    private var headerDirectories: [Int: [String]]
    private var fingerprint: [String: String]
    private var _packages: PackageProducts?
    /// Problems found while loading (settings that could not be resolved).
    public private(set) var diagnostics: [String] = []

    public init(containerURL: URL, context: BuildContext, settingsSource: IndexSettingsSource = ResolverSettingsSource()) throws {
        self.containerURL = containerURL.standardizedFileURL
        self.context = context
        self.settingsSource = settingsSource
        let loaded = try Self.load(containerURL, context: context, source: settingsSource)
        _graph = loaded.graph
        settings = loaded.settings
        headerDirectories = loaded.headers
        fingerprint = loaded.fingerprint
        _packages = loaded.packages
        diagnostics = loaded.diagnostics
    }

    public var graph: BuildGraph { lock.withLock { _graph } }

    /// The package products targets use (nil: none), from the build's PIF.
    public var packages: PackageProducts? { lock.withLock { _packages } }

    /// The compile context of a target, nil when the target is unknown.
    public func compileContext(_ targetID: String) -> TargetCompileContext? {
        lock.withLock {
            guard let t = _graph.target(id: targetID), let s = settings[targetID] else { return nil }
            return TargetCompileContext(target: t, settings: s, projectDirectory: _graph.project(of: t).directory.path,
                                        projectHeaderDirectories: headerDirectories[t.projectIndex] ?? [],
                                        isLinuxHost: context.isLinuxHost, hostArchitecture: context.hostArchitecture)
        }
    }

    /// Compiler arguments for a file in a target (the first target that
    /// contains the file when `targetID` is nil).
    public func arguments(for file: String, targetID: String?, language: SourceLanguage? = nil) -> (arguments: [String], workingDirectory: String)? {
        let path = URL(fileURLWithPath: file).standardizedFileURL.path
        let id = targetID ?? graph.targets(containing: path).first?.id
        guard let id, let ctx = compileContext(id) else { return nil }
        let isHeader = SourceLanguage.isHeader(path)
        guard isHeader || ctx.target.sources.contains(where: { $0.path == path }) else { return nil }
        let lang = SourceLanguage(path: path) ?? language ?? .objectiveC
        return (CompilerArguments.arguments(for: path, language: lang, in: ctx), ctx.projectDirectory)
    }

    /// Reloads when a watched file changed; returns the identifiers of the
    /// targets that were added, removed or changed (empty: nothing changed).
    @discardableResult
    public func reloadIfChanged(force: Bool = false) -> [String] {
        let current = lock.withLock { (fingerprint, _graph) }
        let now = Self.fingerprint(current.1)
        guard force || now != current.0 else { return [] }
        guard let loaded = try? Self.load(containerURL, context: context, source: settingsSource) else {
            lock.withLock { fingerprint = now }
            return []
        }
        return lock.withLock {
            var changed: [String] = []
            let old = Dictionary(uniqueKeysWithValues: _graph.targets.map { ($0.id, $0) })
            let new = Dictionary(uniqueKeysWithValues: loaded.graph.targets.map { ($0.id, $0) })
            for id in Set(old.keys).union(new.keys).sorted() {
                guard let o = old[id], let n = new[id] else { changed.append(id); continue }
                if o.sources != n.sources || o.headers != n.headers || o.dependencies != n.dependencies || settings[id] != loaded.settings[id] {
                    changed.append(id)
                }
            }
            _graph = loaded.graph
            settings = loaded.settings
            headerDirectories = loaded.headers
            fingerprint = loaded.fingerprint
            _packages = loaded.packages
            diagnostics = loaded.diagnostics
            return changed
        }
    }

    // MARK: Loading

    struct Loaded {
        var graph: BuildGraph
        var settings: [String: [String: String]]
        var headers: [Int: [String]]
        var fingerprint: [String: String]
        var diagnostics: [String]
        var packages: PackageProducts?
    }

    static func load(_ url: URL, context: BuildContext, source: IndexSettingsSource) throws -> Loaded {
        let container = try Container.open(url)
        let graph = BuildGraph.load(container)
        var diagnostics: [String] = []
        var settings: [String: [String: String]] = [:]
        do {
            settings = try source.settings(for: graph.targets, in: graph, context: context)
        } catch {
            diagnostics.append("settings: \(error)")
            // One target's failure should not lose the others.
            for t in graph.targets {
                if let s = try? source.settings(for: [t], in: graph, context: context)[t.id] { settings[t.id] = s }
            }
        }
        // Package products: their imparted search paths and flags.
        var packages: PackageProducts?
        do { packages = try PackageProducts.load(graph) } catch { diagnostics.append("package products: \(error)") }
        if let packages {
            for t in graph.targets { if let s = settings[t.id] { settings[t.id] = packages.merged(s, targetID: t.id) } }
        }
        var headers: [Int: [String]] = [:]
        for (i, p) in container.projects.enumerated() {
            var dirs: [String] = []
            for t in graph.targets where t.projectIndex == i { dirs += t.headers.map { ($0.path as NSString).deletingLastPathComponent } }
            let parents = p.proj.parentMap()
            for o in p.proj.objects.values where o.isa == "PBXFileReference" && SourceLanguage.isHeader(o.string("path") ?? "") {
                if let path = p.proj.resolvedPath(of: o.id, projectDirectory: p.directory, parents: parents), path.hasPrefix("/") {
                    dirs.append((URL(fileURLWithPath: path).standardizedFileURL.path as NSString).deletingLastPathComponent)
                }
            }
            headers[i] = dirs.uniqued().sorted()
        }
        return Loaded(graph: graph, settings: settings, headers: headers, fingerprint: fingerprint(graph), diagnostics: diagnostics, packages: packages)
    }

    /// Modification time and size of every watched path.
    static func fingerprint(_ graph: BuildGraph) -> [String: String] {
        var out: [String: String] = [:]
        for p in graph.watchedPaths() {
            let a = try? FileManager.default.attributesOfItem(atPath: p)
            let m = (a?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? -1
            let s = (a?[.size] as? NSNumber)?.intValue ?? -1
            out[p] = "\(m):\(s)"
        }
        return out
    }

    // MARK: Context from a scheme

    /// The configuration a scheme runs with (nil when the scheme is unknown).
    public static func configuration(ofScheme name: String, in containerURL: URL) -> String? {
        guard let c = try? Container.open(containerURL), let s = c.schemes().first(where: { $0.name == name }) else { return nil }
        return s.configuration(for: "LaunchAction")
    }
}
