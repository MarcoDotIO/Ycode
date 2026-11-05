// From an unpacked asset (or an exported bundle the user copied, route A) to
// a runtime in Ycode's folder (`runtime-downloads.md` §5.1, §6.2 steps 3–7):
// validate the bundle, read the disk image's APFS volume, put the
// `.simruntime`'s RuntimeRoot at `<runtimes>/<token>-<version>-<build>/RuntimeRoot`
// with `profile.plist` and `runtime-Info.plist` beside it, write Ycode's
// marker (its registry) and remove the archives. Portable.

import Foundation

public struct RuntimeInstaller: Sendable {
    public var folder: String
    public var reader: any RuntimeImageReader

    public init(folder: String, reader: any RuntimeImageReader) {
        self.folder = folder
        self.reader = reader
    }

    /// A bundle as §5.1 lays it out.
    public struct Bundle: Sendable, Equatable {
        public var root: String
        public var dmg: String
        public var build: String?
        public var version: String?
    }

    /// Step 3: the folder holding `Restore/` (the unpacked tree, an
    /// `.exportedBundle`, or a folder above one), its DMG, and the build and
    /// version its plists name.
    public static func locateBundle(_ path: String, fileManager fm: FileManager = .default) throws -> Bundle {
        var queue = [(path, 0)]
        while !queue.isEmpty {
            let (dir, depth) = queue.removeFirst()
            let restore = dir + "/Restore"
            if let names = try? fm.contentsOfDirectory(atPath: restore), let dmg = names.sorted().first(where: { $0.lowercased().hasSuffix(".dmg") }) {
                var b = Bundle(root: dir, dmg: restore + "/" + dmg)
                if let m = plist(fm.contents(atPath: dir + "/ExportedMetadata.plist")), let props = m["MobileAssetProperties"] as? [String: Any] {
                    b.build = props["Build"] as? String
                    b.version = props["SimulatorVersion"] as? String
                }
                if let r = plist(fm.contents(atPath: restore + "/Restore.plist")) {
                    b.build = b.build ?? r["ProductBuildVersion"] as? String
                    b.version = b.version ?? r["ProductVersion"] as? String
                }
                if let i = plist(fm.contents(atPath: dir + "/Info.plist")), let props = i["MobileAssetProperties"] as? [String: Any] {
                    b.build = b.build ?? props["Build"] as? String
                    b.version = b.version ?? props["SimulatorVersion"] as? String
                }
                return b
            }
            guard depth < 4 else { continue }
            for n in ((try? fm.contentsOfDirectory(atPath: dir)) ?? []).sorted() where !n.hasPrefix(".") {
                var isDir: ObjCBool = false
                let p = dir + "/" + n
                if fm.fileExists(atPath: p, isDirectory: &isDir), isDir.boolValue { queue.append((p, depth + 1)) }
            }
        }
        throw RuntimeDownloadError.install("no Restore/ folder with a disk image in \((path as NSString).lastPathComponent)")
    }

    static func plist(_ d: Data?) -> [String: Any]? {
        d.flatMap { try? PropertyListSerialization.propertyList(from: $0, format: nil) as? [String: Any] }
    }

    /// The `.simruntime` bundle inside a mounted or extracted volume (§5.2).
    public static func findSimRuntime(in volume: String, fileManager fm: FileManager = .default) -> String? {
        for base in [volume + "/Library/Developer/CoreSimulator/Profiles/Runtimes", volume + "/Runtimes", volume] {
            if let n = ((try? fm.contentsOfDirectory(atPath: base)) ?? []).sorted().first(where: { $0.hasSuffix(".simruntime") }) {
                return base + "/" + n
            }
        }
        return nil
    }

    /// Steps 4–6. `expect` names the build the user chose (nil for an import
    /// of whatever the bundle is). Returns the new runtime.
    public func install(bundle: Bundle, expectBuild: String?, marker: @escaping @Sendable (SimRuntimeRecord) -> RuntimeMarker, replace: Bool = false,
                        work: String, cancel: RuntimeCancellation, log: @escaping @Sendable (String) -> Void) async throws -> SimRuntimeRecord {
        if let expectBuild, let b = bundle.build, b != expectBuild {
            throw RuntimeDownloadError.install("the bundle is build \(b), not the \(expectBuild) that was chosen")
        }
        let folder = folder
        return try await reader.withVolume(bundle.dmg, work: work, cancel: cancel, log: log) { volume in
            let fm = FileManager.default
            guard let sim = Self.findSimRuntime(in: volume) else {
                throw RuntimeDownloadError.install("no .simruntime bundle in the disk image's volume")
            }
            guard var record = RuntimeBundleReader.read(sim, owner: .ycode(folder: "")), let root = record.runtimeRoot else {
                throw RuntimeDownloadError.install("\((sim as NSString).lastPathComponent) has no readable RuntimeRoot")
            }
            if let expectBuild, record.build != expectBuild {
                throw RuntimeDownloadError.install("the runtime is build \(record.build), not \(expectBuild)")
            }
            let dest = folder + "/" + record.folderName
            if fm.fileExists(atPath: dest) {
                guard replace else { throw RuntimeDownloadError.install("\(record.title) is already in Ycode's folder (\(dest)); remove it first") }
            }
            let incoming = dest + RuntimeFolders.incomingSuffix
            try? fm.removeItem(atPath: incoming)
            try fm.createDirectory(atPath: incoming, withIntermediateDirectories: true)
            log("Placing \(record.title)'s RuntimeRoot in \(dest)")
            try await Self.moveOrCopy(root, to: incoming + "/RuntimeRoot", cancel: cancel)
            for (from, to) in [("/Contents/Resources/profile.plist", "/profile.plist"), ("/Contents/Info.plist", "/runtime-Info.plist")]
            where fm.fileExists(atPath: sim + from) {
                try? fm.copyItem(atPath: sim + from, toPath: incoming + to)
            }
            record.unpackedBytes = RuntimeBundleReader.directorySize(incoming + "/RuntimeRoot")
            try (marker(record).json + "\n").write(toFile: incoming + "/" + RuntimeFolders.marker, atomically: true, encoding: .utf8)
            if fm.fileExists(atPath: dest) { try fm.removeItem(atPath: dest) }
            try fm.moveItem(atPath: incoming, toPath: dest)
            guard let placed = RuntimeBundleReader.read(dest, owner: .ycode(folder: dest)) else {
                throw RuntimeDownloadError.install("the placed runtime could not be read back")
            }
            return placed
        }
    }

    /// A rename when source and destination share a file system (the
    /// extracted volume), else a copy that keeps modes, links and attributes.
    static func moveOrCopy(_ source: String, to dest: String, cancel: RuntimeCancellation) async throws {
        if rename(source, dest) == 0 { return }
        #if os(macOS)
        let p = SetupProcess(["/usr/bin/ditto", source, dest])
        #else
        let p = SetupProcess(["/bin/cp", "-a", source, dest])
        #endif
        let token = cancel.onCancel { p.terminate() }
        defer { cancel.remove(token) }
        let s = await p.run()
        try cancel.check()
        guard s == 0 else { throw RuntimeDownloadError.install("copying the RuntimeRoot failed: \(p.text.trimmed)") }
    }
}
