import Foundation

/// The workspace text search: files searched in parallel, results
/// delivered in file order as each one finishes, binaries and very large
/// files skipped, unsaved editor text searched instead of the file on
/// disk, cancellable. See `specs/ide/navigators.md` §Find navigator,
/// "Ycode implementation".
public enum FindEngine {
    public struct Request: Sendable {
        public var query: FindQuery
        public var files: [FindCandidate]
        /// Unsaved editor text by path; searched instead of the file.
        public var buffers: [String: String]
        /// Stop after this many matches (the file that reaches it is kept whole).
        public var limit: Int
        /// Files larger than this are skipped.
        public var maxFileSize: Int
        /// Worker threads (at most the active processors).
        public var concurrency: Int

        public init(query: FindQuery, files: [FindCandidate], buffers: [String: String] = [:], limit: Int = 1000,
                    maxFileSize: Int = 16 << 20, concurrency: Int = min(8, ProcessInfo.processInfo.activeProcessorCount)) {
            self.query = query
            self.files = files
            self.buffers = buffers
            self.limit = limit
            self.maxFileSize = maxFileSize
            self.concurrency = max(1, concurrency)
        }

        public init(query: FindQuery, paths: [String], buffers: [String: String] = [:], limit: Int = 1000) {
            self.init(query: query, files: paths.map { FindCandidate($0) }, buffers: buffers, limit: limit)
        }
    }

    public struct Summary: Equatable, Sendable {
        public var files: [WorkspaceSearch.FileResult] = []
        public var matchCount = 0
        /// Files read and searched (buffers included).
        public var searchedFiles = 0
        /// Files skipped as binary (a NUL byte in the first 8 KB, a known
        /// binary extension, or text that is not UTF-8 or UTF-16).
        public var skippedBinary = 0
        public var skippedLarge = 0
        /// The search stopped at the match limit.
        public var truncated = false
        public var cancelled = false
        public var elapsed: TimeInterval = 0
        public init() {}
    }

    public enum Event: Sendable {
        case file(WorkspaceSearch.FileResult)
        case finished(Summary)
    }

    /// Stops a running search; checked between files.
    public final class Cancellation: @unchecked Sendable {
        private let lock = NSLock()
        private var flag = false
        public init() {}
        public func cancel() { lock.withLock { flag = true } }
        public var isCancelled: Bool { lock.withLock { flag } }
    }

    /// Extensions never read (images, archives, objects, media, fonts).
    public static let binaryExtensions: Set<String> = [
        "png", "jpg", "jpeg", "gif", "tif", "tiff", "bmp", "heic", "ico", "icns", "webp", "psd", "pdf", "car",
        "zip", "gz", "tgz", "xz", "bz2", "7z", "rar", "tar", "dmg", "pkg", "ipa", "aar", "jar",
        "a", "o", "so", "dylib", "tbd", "dll", "exe", "bin", "class", "pyc", "wasm", "metallib", "air", "nib",
        "mp3", "mp4", "m4a", "m4v", "mov", "wav", "aiff", "caf", "aac", "flac", "ogg",
        "ttf", "otf", "woff", "woff2", "sqlite", "db", "realm", "mlmodel", "mlmodelc", "usdz", "reality",
    ]

    /// Searches synchronously (the work runs on `concurrency` threads).
    /// `onFile` gets each file with matches, in request order, before the
    /// call returns.
    public static func search(_ r: Request, cancellation: Cancellation = Cancellation(),
                              onFile: (@Sendable (WorkspaceSearch.FileResult) -> Void)? = nil) -> Summary {
        let start = Date()
        var summary = Summary()
        guard let matcher = r.query.matcher(), !r.files.isEmpty else {
            summary.elapsed = Date().timeIntervalSince(start)
            return summary
        }
        let state = SearchState(paths: r.files.map(\.path))
        let workers = min(r.concurrency, r.files.count)
        DispatchQueue.concurrentPerform(iterations: workers) { _ in
            while !cancellation.isCancelled {
                guard let i = state.claim() else { return }
                let outcome = searchFile(r.files[i].path, request: r, matcher: matcher)
                state.finish(i, outcome) { result in
                    // In order, under the state's lock.
                    guard !state.summary.truncated else { return }
                    state.summary.files.append(result)
                    state.summary.matchCount += result.matches.count
                    onFile?(result)
                    if state.summary.matchCount >= r.limit {
                        state.summary.truncated = true
                        cancellation.cancel()
                    }
                }
            }
        }
        summary = state.summary
        summary.cancelled = cancellation.isCancelled && !summary.truncated
        summary.elapsed = Date().timeIntervalSince(start)
        return summary
    }

    /// Searches on a background thread; events arrive as files finish.
    /// Ending the stream (or cancelling its task) stops the search.
    public static func stream(_ r: Request) -> AsyncStream<Event> {
        let cancellation = Cancellation()
        return AsyncStream { continuation in
            continuation.onTermination = { _ in cancellation.cancel() }
            DispatchQueue.global(qos: .userInitiated).async {
                let summary = search(r, cancellation: cancellation) { continuation.yield(.file($0)) }
                continuation.yield(.finished(summary))
                continuation.finish()
            }
        }
    }

    // MARK: One file

    enum Outcome { case matches([WorkspaceSearch.Match]), none, binary, large }

    static func searchFile(_ path: String, request r: Request, matcher: FindMatcher) -> Outcome {
        if let text = r.buffers[path] {
            let m = matcher.matches(in: text)
            return m.isEmpty ? .none : .matches(m)
        }
        if binaryExtensions.contains((path as NSString).pathExtension.lowercased()) { return .binary }
        guard let data = FileManager.default.contents(atPath: path) else { return .none }
        if data.count > r.maxFileSize { return .large }
        guard let text = decode(data, matcher: matcher) else { return data.isEmpty ? .none : .binary }
        if text.isEmpty { return .none }
        let m = matcher.matches(in: text)
        return m.isEmpty ? .none : .matches(m)
    }

    /// The file's text: UTF-16 with a byte-order mark, else UTF-8 without
    /// NUL bytes in the first 8 KB. Returns "" (nothing to search) when
    /// the byte pre-check rules the file out, nil for a binary file.
    static func decode(_ data: Data, matcher: FindMatcher) -> String? {
        if data.count >= 2, (data[0] == 0xFF && data[1] == 0xFE) || (data[0] == 0xFE && data[1] == 0xFF) {
            return String(data: data, encoding: .utf16)
        }
        let isText: Bool = data.withUnsafeBytes { raw in
            let n = min(raw.count, 8000)
            for i in 0..<n where raw[i] == 0 { return false }
            return true
        }
        guard isText else { return nil }
        guard data.withUnsafeBytes({ matcher.mayMatch($0) }) else { return "" }
        return String(data: data, encoding: .utf8)
    }

    /// Shared between the workers: the next file to claim, finished
    /// outcomes waiting for their turn, and the summary built in order.
    final class SearchState: @unchecked Sendable {
        private let lock = NSLock()
        private var next = 0
        private var cursor = 0
        private var pending: [Int: Outcome] = [:]
        private let count: Int
        private let paths: [String]
        var summary = Summary()

        init(paths: [String]) {
            self.paths = paths
            count = paths.count
        }

        func claim() -> Int? {
            lock.withLock {
                guard next < count else { return nil }
                defer { next += 1 }
                return next
            }
        }

        /// Records an outcome and delivers every outcome now in order.
        func finish(_ i: Int, _ outcome: Outcome, deliver: (WorkspaceSearch.FileResult) -> Void) {
            lock.lock()
            defer { lock.unlock() }
            pending[i] = outcome
            while let o = pending.removeValue(forKey: cursor) {
                switch o {
                case .matches(let m):
                    summary.searchedFiles += 1
                    deliver(WorkspaceSearch.FileResult(path: pathFor(cursor), matches: m))
                case .none: summary.searchedFiles += 1
                case .binary: summary.skippedBinary += 1
                case .large: summary.skippedLarge += 1
                }
                cursor += 1
            }
        }

        private func pathFor(_ i: Int) -> String { paths[i] }
    }
}
