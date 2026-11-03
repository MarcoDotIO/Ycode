#if canImport(CoreServices)
import CoreServices
#elseif canImport(Glibc)
import Glibc
#endif
import Foundation

/// Watches a folder tree and reports changed paths on the main queue,
/// coalesced over `latency` seconds: FSEvents on macOS, inotify on Linux.
/// The window uses it to refresh source-control state after changes made
/// outside Ycode (a terminal `git add`, an editor in another app).
@MainActor
package final class FileSystemWatcher {
    private let handler: @MainActor ([String]) -> Void

    package init(handler: @escaping @MainActor ([String]) -> Void) { self.handler = handler }

    isolated deinit { stop() }

    /// Whether a change under `path` can alter what git reports: not git's
    /// object store or lock files, not build output.
    nonisolated package static func affectsSourceControl(_ path: String) -> Bool {
        let parts = path.split(separator: "/")
        if parts.contains(where: { [".build", ".build-ide", "DerivedData", ".swiftpm"].contains($0) }) { return false }
        if let g = parts.firstIndex(of: ".git") {
            let inside = parts[(g + 1)...]
            if inside.first == "objects" || inside.first == "logs" { return false }
            if inside.last?.hasSuffix(".lock") == true { return false }
        }
        return true
    }

    #if canImport(CoreServices)
    private var stream: FSEventStreamRef?

    /// Starts watching `path` (and everything under it).
    package func start(path: String, latency: TimeInterval = 0.3) {
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

    package func stop() {
        guard let s = stream else { return }
        FSEventStreamStop(s)
        FSEventStreamInvalidate(s)
        FSEventStreamRelease(s)
        stream = nil
    }
    #elseif canImport(Glibc)
    // inotify watches one directory, not a tree: every directory under the
    // root gets a watch, and a directory created or moved in later gets one
    // when its event arrives.
    private var source: DispatchSourceRead?
    private var directories: [Int32: String] = [:]
    private var fd: Int32 = -1
    private var pending: [String] = []
    private var flushScheduled = false
    private var latency: TimeInterval = 0.3
    private static let mask = UInt32(IN_MODIFY | IN_ATTRIB | IN_CLOSE_WRITE | IN_CREATE | IN_DELETE | IN_DELETE_SELF
                                     | IN_MOVED_FROM | IN_MOVED_TO | IN_MOVE_SELF)

    /// Starts watching `path` (and everything under it).
    package func start(path: String, latency: TimeInterval = 0.3) {
        stop()
        let fd = inotify_init1(Int32(IN_CLOEXEC | IN_NONBLOCK))
        guard fd >= 0 else { return }
        self.fd = fd
        self.latency = latency
        watchTree(path)
        let s = DispatchSource.makeReadSource(fileDescriptor: fd, queue: .main)
        s.setEventHandler { [weak self] in MainActor.assumeIsolated { self?.drain() } }
        s.setCancelHandler { close(fd) }
        s.resume()
        source = s
    }

    package func stop() {
        guard let s = source else { return }
        s.cancel()
        source = nil
        fd = -1
        directories = [:]
        pending = []
    }

    private func watch(_ directory: String) {
        let wd = inotify_add_watch(fd, directory, Self.mask)
        if wd >= 0 { directories[wd] = directory }
    }

    /// Watches `root` and every directory under it (symbolic links are not
    /// followed).
    private func watchTree(_ root: String) {
        watch(root)
        guard let e = FileManager.default.enumerator(at: URL(fileURLWithPath: root), includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        else { return }
        for case let u as URL in e {
            let v = try? u.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            if v?.isDirectory == true && v?.isSymbolicLink != true { watch(u.path) }
        }
    }

    /// Reads every queued event, then delivers the paths after `latency`.
    private func drain() {
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        let header = MemoryLayout<inotify_event>.size
        while true {
            let n = buffer.withUnsafeMutableBytes { read(fd, $0.baseAddress, $0.count) }
            guard n > 0 else { break }
            var offset = 0
            while offset + header <= n {
                let (wd, mask, length) = buffer.withUnsafeBytes { raw -> (Int32, UInt32, Int) in
                    let e = raw.loadUnaligned(fromByteOffset: offset, as: inotify_event.self)
                    return (e.wd, e.mask, Int(e.len))
                }
                let name = String(decoding: buffer[(offset + header)..<min(n, offset + header + length)].prefix { $0 != 0 }, as: UTF8.self)
                offset += header + length
                if mask & UInt32(IN_IGNORED) != 0 {
                    directories[wd] = nil
                    continue
                }
                guard let directory = directories[wd] else { continue }
                let path = name.isEmpty ? directory : directory + "/" + name
                pending.append(path)
                if mask & UInt32(IN_ISDIR) != 0, mask & UInt32(IN_CREATE | IN_MOVED_TO) != 0 { watchTree(path) }
            }
        }
        guard !pending.isEmpty, !flushScheduled else { return }
        flushScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + latency) { [weak self] in
            MainActor.assumeIsolated { self?.flush() }
        }
    }

    private func flush() {
        flushScheduled = false
        guard source != nil, !pending.isEmpty else { return }
        let paths = pending
        pending = []
        handler(paths)
    }
    #else
    /// No file-system events on this platform: nothing is reported.
    package func start(path: String, latency: TimeInterval = 0.3) {}
    package func stop() {}
    #endif
}
