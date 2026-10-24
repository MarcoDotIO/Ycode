import CoreServices
import Foundation

/// Watches a folder tree with FSEvents and reports changed paths on the
/// main queue, coalesced over `latency` seconds. The window uses it to
/// refresh source-control state after changes made outside Ycode (a
/// terminal `git add`, an editor in another app).
@MainActor
final class FileSystemWatcher {
    private var stream: FSEventStreamRef?
    private let handler: @MainActor ([String]) -> Void

    init(handler: @escaping @MainActor ([String]) -> Void) { self.handler = handler }

    /// Starts watching `path` (and everything under it).
    func start(path: String, latency: TimeInterval = 0.3) {
        stop()
        var context = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(), retain: nil, release: nil, copyDescription: nil)
        let callback: FSEventStreamCallback = { _, info, count, paths, _, _ in
            guard let info else { return }
            let watcher = Unmanaged<FileSystemWatcher>.fromOpaque(info).takeUnretainedValue()
            let array = unsafeBitCast(paths, to: NSArray.self)
            let list = (0..<count).compactMap { array[$0] as? String }
            MainActor.assumeIsolated { watcher.handler(list) }
        }
        // File-level events: the filter below needs the changed file, not its folder.
        let flags = FSEventStreamCreateFlags(kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagWatchRoot | kFSEventStreamCreateFlagFileEvents)
        guard let s = FSEventStreamCreate(nil, callback, &context, [path] as CFArray,
                                          FSEventStreamEventId(kFSEventStreamEventIdSinceNow), latency, flags) else { return }
        FSEventStreamSetDispatchQueue(s, DispatchQueue.main)
        FSEventStreamStart(s)
        stream = s
    }

    func stop() {
        guard let s = stream else { return }
        FSEventStreamStop(s)
        FSEventStreamInvalidate(s)
        FSEventStreamRelease(s)
        stream = nil
    }

    isolated deinit { stop() }

    /// Whether a change under `path` can alter what git reports: not git's
    /// object store or lock files, not build output.
    nonisolated static func affectsSourceControl(_ path: String) -> Bool {
        let parts = path.split(separator: "/")
        if parts.contains(where: { [".build", ".build-ide", "DerivedData", ".swiftpm"].contains($0) }) { return false }
        if let g = parts.firstIndex(of: ".git") {
            let inside = parts[(g + 1)...]
            if inside.first == "objects" || inside.first == "logs" { return false }
            if inside.last?.hasSuffix(".lock") == true { return false }
        }
        return true
    }
}
