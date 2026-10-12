import Foundation

/// Computes the full set of images an executable needs under a simulator
/// runtime, following the lookup order in `specs/simulator/loader.md` §1:
/// the shared cache first, then files under the runtime root, with `@rpath`,
/// `@loader_path`, and `@executable_path` expanded.
public struct DependencyClosure {
    public enum Source: Equatable, Sendable, CustomStringConvertible {
        case sharedCache(address: UInt64)
        case file(String)
        public var description: String {
            switch self {
            case .sharedCache(let a): "cache@\(hex(a))"
            case .file(let p): "file \(p)"
            }
        }
    }

    public struct Node: Sendable {
        public var installPath: String
        public var source: Source
        public var image: MachOImage
        /// Paths this image loads (resolved install paths), in load-command order.
        public var dependencies: [String]
    }

    public struct Missing: Sendable, Equatable {
        public var path: String
        public var requiredBy: String
        public var kind: MachOImage.DylibReference.Kind
        /// Weak references may be absent at run time.
        public var isFatal: Bool { kind != .weak }
    }

    public let root: String
    public let cache: SharedCache?
    public private(set) var nodes: [String: Node] = [:]
    /// Breadth-first load order starting from the executable.
    public private(set) var order: [String] = []
    public private(set) var missing: [Missing] = []

    public init(root: String, cache: SharedCache?) {
        self.root = root
        self.cache = cache
    }

    /// Resolves everything `executablePath` (a host path) depends on.
    public mutating func resolve(executable executablePath: String) throws {
        let exe = try MachOFile(contentsOf: URL(fileURLWithPath: executablePath)).image()
        let exeDir = (executablePath as NSString).deletingLastPathComponent
        let mainKey = "<main>"
        var queue: [(key: String, image: MachOImage, loaderDir: String, rpaths: [String])] = []
        nodes[mainKey] = Node(installPath: executablePath, source: .file(executablePath), image: exe, dependencies: [])
        order.append(mainKey)
        queue.append((mainKey, exe, exeDir, expandRpaths(exe.rpaths, loaderDir: exeDir, exeDir: exeDir)))

        var head = 0
        while head < queue.count {
            let (key, image, loaderDir, rpaths) = queue[head]
            head += 1
            var deps: [String] = []
            for ref in image.dylibs {
                guard let (resolvedPath, source, loaded) = locate(ref.path, loaderDir: loaderDir, exeDir: exeDir, rpaths: rpaths) else {
                    missing.append(Missing(path: ref.path, requiredBy: nodes[key]?.installPath ?? key, kind: ref.kind))
                    continue
                }
                deps.append(resolvedPath)
                if nodes[resolvedPath] == nil {
                    nodes[resolvedPath] = Node(installPath: resolvedPath, source: source, image: loaded, dependencies: [])
                    order.append(resolvedPath)
                    let dir = (resolvedPath as NSString).deletingLastPathComponent
                    queue.append((resolvedPath, loaded, dir, rpaths + expandRpaths(loaded.rpaths, loaderDir: dir, exeDir: exeDir)))
                }
            }
            nodes[key]?.dependencies = deps
        }
    }

    /// `@loader_path`/`@executable_path` substitution in LC_RPATH entries.
    private func expandRpaths(_ rpaths: [String], loaderDir: String, exeDir: String) -> [String] {
        rpaths.map {
            $0.replacingOccurrences(of: "@loader_path", with: loaderDir)
                .replacingOccurrences(of: "@executable_path", with: exeDir)
        }
    }

    /// Candidate install paths for a load-command path, in search order.
    func candidates(_ path: String, loaderDir: String, exeDir: String, rpaths: [String]) -> [String] {
        if path.hasPrefix("@rpath/") {
            let rest = String(path.dropFirst("@rpath/".count))
            return rpaths.map { ($0 as NSString).appendingPathComponent(rest) }
        }
        if path.hasPrefix("@loader_path/") {
            return [(loaderDir as NSString).appendingPathComponent(String(path.dropFirst("@loader_path/".count)))]
        }
        if path.hasPrefix("@executable_path/") {
            return [(exeDir as NSString).appendingPathComponent(String(path.dropFirst("@executable_path/".count)))]
        }
        return [path]
    }

    private func locate(_ path: String, loaderDir: String, exeDir: String, rpaths: [String])
        -> (String, Source, MachOImage)? {
        for candidate in candidates(path, loaderDir: loaderDir, exeDir: exeDir, rpaths: rpaths) {
            // Absolute guest paths live in the cache or under the runtime root.
            // Paths already inside the root (from @loader_path on a root file)
            // are used as they are.
            let guestPath = candidate.hasPrefix(root) ? String(candidate.dropFirst(root.count)) : candidate
            if let cache, let entry = cache.image(path: guestPath), let image = try? cache.machO(for: entry) {
                return (guestPath, .sharedCache(address: entry.address), image)
            }
            let hostPath = candidate.hasPrefix(root) ? candidate : root + candidate
            if FileManager.default.fileExists(atPath: hostPath),
               let image = try? MachOFile(contentsOf: URL(fileURLWithPath: hostPath)).image() {
                return (guestPath, .file(hostPath), image)
            }
        }
        return nil
    }
}
