// Route B end to end (`runtime-downloads.md` §6.1, §6.2): index, selection,
// asset query, resumable download with size and SHA-256 checks, decryption
// and unpacking, the disk image, Ycode's runtime folder, and the clean-up.
// Always started by an explicit choice (a command, or a confirmed sheet).
// The command line and both wizards drive it and show its events.

import Foundation

/// Where route B is, for progress lines and the wizard.
public enum RuntimeDownloadPhase: Sendable, Equatable {
    case index
    case selected(RuntimeIndexEntry)
    case querying
    case downloading(done: Int64, total: Int64)
    case verifying(done: Int64, total: Int64)
    case decrypting(done: Int64, total: Int64?)
    case readingImage
    case installing
    case finished(SimRuntimeRecord)
    /// `--stop-after`: the step's output is at this path.
    case stopped(String)

    public var title: String {
        switch self {
        case .index: "Reading Apple's runtime index…"
        case .selected(let e): "Chose \(e.title), \(RuntimeSize.format(e.fileSize))."
        case .querying: "Asking Apple's asset service where it is…"
        case .downloading(let d, let t): "Downloading: \(RuntimeSize.format(d)) of \(RuntimeSize.format(t))"
        case .verifying(let d, let t): "Checking the SHA-256: \(RuntimeSize.format(d)) of \(RuntimeSize.format(t))"
        case .decrypting(let d, let t): "Decrypting and unpacking: \(RuntimeSize.format(d))" + (t.map { " of \(RuntimeSize.format($0))" } ?? "")
        case .readingImage: "Reading the disk image…"
        case .installing: "Putting the runtime in Ycode's folder…"
        case .finished(let r): "\(r.title) is ready."
        case .stopped(let p): "Stopped as asked; the result is at \(p)."
        }
    }

    /// 0…1 for a bar, nil when indeterminate.
    public var fraction: Double? {
        switch self {
        case .downloading(let d, let t), .verifying(let d, let t): t > 0 ? Double(d) / Double(t) : nil
        case .decrypting(let d, let t?): t > 0 ? min(1, Double(d) / Double(t)) : nil
        case .finished: 1
        default: nil
        }
    }
}

/// What route B fetches.
public enum RuntimeDownloadTarget: Sendable, Equatable {
    case runtime(RuntimeRequest)
    /// The Metal Toolchain (§6.3): fetched like a runtime, never installed.
    case metalToolchain(build: String?)
}

/// Where to stop (the Mac's test of route B ends after decryption).
public enum RuntimeDownloadStop: String, Sendable, CaseIterable {
    /// After the asset service answered (nothing downloaded).
    case queried
    case downloaded, expanded, installed
}

public final class RuntimeDirectDownload: @unchecked Sendable {
    public var folder: String
    public var transport: any RuntimeTransport
    public var expander: any RuntimeArchiveExpander
    public var reader: (any RuntimeImageReader)?
    public var host: RuntimeHostDescription
    public var selectionHost: RuntimeSelectionHost
    public let cancellation = RuntimeCancellation()
    /// Keep the archive and the unpacked tree (§6.2 step 7's `--keep`).
    public var keep = false
    public var stop: RuntimeDownloadStop = .installed
    /// Where the unpacked tree goes when stopping after expansion (default: the work folder).
    public var expandTo: String?
    public var replace = false
    /// The asset query (tests answer for the asset service).
    public var query: @Sendable (_ assetType: String, _ build: String) async throws -> RuntimeAssetRecord
    /// Free bytes where a path is (tests answer for the volume, whose free space other work changes).
    public var freeSpace: @Sendable (String) -> Int64? = { RuntimeDirectDownload.freeBytes($0) }

    public init(folder: String, transport: any RuntimeTransport = CurlTransport(), expander: (any RuntimeArchiveExpander)? = nil,
                reader: (any RuntimeImageReader)? = RuntimeImageReaders.standard(), host: RuntimeHostDescription = .current(),
                selectionHost: RuntimeSelectionHost = .current) {
        self.folder = folder
        self.transport = transport
        self.expander = expander ?? RuntimeExpanders.standard(folder: folder)
        self.reader = reader
        self.host = host
        self.selectionHost = selectionHost
        let h = host, t = transport, f = folder
        query = { type, build in
            try await RuntimeAssetQuery.run(assetType: type, build: build, host: h, transport: t, trust: RuntimeTrust(folder: f))
        }
    }

    public func cancel() { cancellation.cancel() }

    var partial: String { folder + "/.partial" }

    /// The index (cached for its refresh interval).
    public func index(force: Bool = false) async throws -> RuntimeIndex {
        try await RuntimeIndexCache(folder: folder).load(transport: transport, force: force)
    }

    /// What will be fetched: the index entry (or component) and its asset type.
    public func resolve(_ target: RuntimeDownloadTarget, index: RuntimeIndex) throws -> (entry: RuntimeIndexEntry?, assetType: String, build: String, size: Int64, name: String) {
        switch target {
        case .runtime(let r):
            let e = try RuntimeSelection.select(index, r, host: selectionHost)
            return (e, r.platform.assetType, e.build, e.fileSize, e.title)
        case .metalToolchain(let build):
            guard let c = index.metalToolchain(build: build), let type = c.mobileAssetType else {
                throw RuntimeDownloadError.noRuntime("Apple's index lists no Metal Toolchain\(build.map { " \($0)" } ?? "").")
            }
            return (nil, type, c.build, c.fileSize, c.name)
        }
    }

    /// Free bytes where `path` is (or its nearest existing parent).
    public static func freeBytes(_ path: String) -> Int64? {
        var p = path
        while !FileManager.default.fileExists(atPath: p), p != "/" { p = (p as NSString).deletingLastPathComponent }
        guard let a = try? FileManager.default.attributesOfFileSystem(forPath: p) else { return nil }
        return (a[.systemFreeSize] as? NSNumber)?.int64Value
    }

    /// Runs route B. `event` gets every phase and log line (scrubbed).
    @discardableResult
    public func run(_ target: RuntimeDownloadTarget, event: @escaping @Sendable (RuntimeDownloadPhase) -> Void,
                    log: @escaping @Sendable (String) -> Void = { _ in }) async throws -> SimRuntimeRecord? {
        let cancel = cancellation
        let say: @Sendable (String) -> Void = { log(RuntimeSecrets.scrub($0)) }
        event(.index)
        let index = try await self.index()
        let chosen = try resolve(target, index: index)
        if let e = chosen.entry { event(.selected(e)) }
        say("Selected \(chosen.name), build \(chosen.build), \(RuntimeSize.format(chosen.size)).")
        // Room for the archive, the unpacked tree and the RuntimeRoot.
        let need = stop == .queried ? 0 : stop == .downloaded ? chosen.size : chosen.size * 4
        if let free = freeSpace(folder), free < need {
            throw RuntimeDownloadError.notEnoughSpace("\(RuntimeSize.format(free)) free in \(folder); \(chosen.name) needs about \(RuntimeSize.format(need)). Free some space and try again.")
        }
        try cancel.check()
        event(.querying)
        say("Asking \(RuntimeAssetQuery.url.host ?? "") for \(chosen.assetType) \(chosen.build) as: \(host.summary).")
        let asset = try await query(chosen.assetType, chosen.build)
        defer { if let k = asset.key { RuntimeSecrets.forget(k) } }
        say("The asset: \(RuntimeSize.format(asset.downloadSize)) from \(asset.url.host ?? ""), SHA-256 \(asset.sha256Hex.prefix(16))…, \(asset.key == nil ? "not encrypted" : "encrypted (key received, not shown)").")
        if stop == .queried { event(.stopped("the asset service's answer (nothing was downloaded)")); return nil }
        let tag = chosen.build.replacingOccurrences(of: "/", with: "_")
        let archive = partial + "/\(tag).aar"
        try await RuntimeDownloader(transport: transport).fetch(asset, to: archive, cancel: cancel) { e in
            switch e {
            case .downloading(let d, let t): event(.downloading(done: d, total: t))
            case .verifying(let d, let t): event(.verifying(done: d, total: t))
            case .resuming(let from): say("Resuming at \(RuntimeSize.format(from)).")
            }
        }
        say("Downloaded and verified \(archive).")
        if stop == .downloaded { event(.stopped(archive)); return nil }
        let expanded = expandTo ?? partial + "/\(tag).expanded"
        try? FileManager.default.removeItem(atPath: expanded)
        event(.decrypting(done: 0, total: asset.unarchivedSize))
        say("Decrypting with \(expander.title).")
        let stats = try await expander.expand(archive, key: asset.key, into: expanded, cancel: cancel) { n in
            event(.decrypting(done: n, total: asset.unarchivedSize))
        }
        say("Unpacked \(stats.files) files (\(RuntimeSize.format(stats.bytes))) into \(expanded); \(stats.verified) checked against the archive's SHA-256.")
        if stop == .expanded || chosen.entry == nil {
            if !keep { try? FileManager.default.removeItem(atPath: archive) }
            event(.stopped(expanded))
            return nil
        }
        guard let reader else { throw RuntimeDownloadError.tool(SevenZipImageReader.installHint) }
        let bundle = try RuntimeInstaller.locateBundle(expanded)
        event(.readingImage)
        let entry = chosen.entry!
        let sha = asset.sha256Hex, urlHost = asset.url.host
        let record = try await RuntimeInstaller(folder: folder, reader: reader).install(
            bundle: bundle, expectBuild: entry.build,
            marker: { r in
                var m = RuntimeMarker(r, source: "Apple (route B, \(urlHost ?? "Apple's CDN"))")
                m.route = "download"
                m.architectures = entry.architectures
                m.indexIdentifier = entry.identifier
                m.downloadHost = urlHost
                m.sha256 = sha
                return m
            }, replace: replace, work: partial + "/\(tag).work", cancel: cancel, log: say)
        event(.installing)
        if !keep {
            for p in [archive, expanded, partial + "/\(tag).work"] { try? FileManager.default.removeItem(atPath: p) }
        } else {
            try? FileManager.default.removeItem(atPath: partial + "/\(tag).work")
        }
        event(.finished(record))
        return record
    }

    /// Route A from step 3: an exported bundle (or a folder holding one).
    public func importBundle(_ path: String, log: @escaping @Sendable (String) -> Void = { _ in }) async throws -> SimRuntimeRecord {
        guard let reader else { throw RuntimeDownloadError.tool(SevenZipImageReader.installHint) }
        var bundle: RuntimeInstaller.Bundle
        if path.lowercased().hasSuffix(".dmg") {
            bundle = RuntimeInstaller.Bundle(root: (path as NSString).deletingLastPathComponent, dmg: path)
        } else {
            bundle = try RuntimeInstaller.locateBundle(path)
        }
        let work = partial + "/import-\(UUID().uuidString.prefix(8)).work"
        defer { try? FileManager.default.removeItem(atPath: work) }
        let name = (path as NSString).lastPathComponent
        return try await RuntimeInstaller(folder: folder, reader: reader).install(
            bundle: bundle, expectBuild: nil,
            marker: { r in
                var m = RuntimeMarker(r, source: "imported: \(name)")
                m.route = "import"
                return m
            }, replace: replace, work: work, cancel: cancellation, log: log)
    }
}
