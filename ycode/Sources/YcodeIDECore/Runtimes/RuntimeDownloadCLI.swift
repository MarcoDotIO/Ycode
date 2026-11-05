// `ycode runtime …` (`runtime-downloads.md` §6): Ycode's runtime registry
// and the three routes from a terminal. `download` (route B) and `xcodebuild`
// (route C) say what they will do and ask before they start (or take --yes).

import Foundation

public enum RuntimeDownloadCLI {
    public static let usage = """
        usage: ycode runtime list [--json]
               ycode runtime available [<platform>] [--all]
               ycode runtime download <platform> [--build B | --version V] [--sdk-build B] [--keep] [--replace] [--yes]
               ycode runtime download metal-toolchain [--build B] [--keep] [--yes]
               ycode runtime import <exportedBundle or .dmg> [--replace]
               ycode runtime xcodebuild <platform> [--export DIR] [--build-version V] [--yes]   (a Mac with Xcode)
          list        the runtimes in Ycode's folder ($YCODE_RUNTIMES_DIR, $YCODE_DATA/runtimes, or the default)
          available   the arm64 runtimes Apple's index offers for a platform, newest first
          download    route B: Ycode fetches the runtime from Apple for you, checks its size and SHA-256, decrypts it
                      with the key Apple's asset service returns, and puts its RuntimeRoot in Ycode's folder.
                      --stop-after queried|downloaded|expanded [--to DIR] stops early (the Metal Toolchain always stops
                      after unpacking: it is macOS software, listed for information)
          import      route A: an exported bundle (xcodebuild -downloadPlatform P -exportPath DIR on a Mac) or its disk image
          xcodebuild  route C: runs xcodebuild -downloadPlatform on this Mac, with -exportPath to save a copy
        platforms: iOS, watchOS, tvOS, visionOS
        """

    public static func main(_ arguments: [String], out: @escaping @Sendable (String) -> Void = { print($0) },
                            ask: @escaping @Sendable (String) -> Bool = RuntimeDownloadCLI.askOnTerminal,
                            folder: String = RuntimeFolders.local(), transport: (any RuntimeTransport)? = nil) async -> Int32 {
        var a = arguments
        guard let cmd = a.first else { out(usage); return 64 }
        a.removeFirst()
        var opts: [String: String] = [:]
        var flags: Set<String> = []
        var positional: [String] = []
        var i = 0
        let valued: Set<String> = ["--build", "--version", "--sdk-build", "--stop-after", "--to", "--export", "--build-version"]
        while i < a.count {
            let x = a[i]
            if valued.contains(x) {
                guard i + 1 < a.count else { out("\(x) needs a value"); return 64 }
                opts[x] = a[i + 1]
                i += 2
            } else if x.hasPrefix("--") { flags.insert(x); i += 1 } else { positional.append(x); i += 1 }
        }
        let tr = transport ?? CurlTransport()
        switch cmd {
        case "list":
            let list = RuntimeBundleReader.ycodeRuntimes(in: folder)
            if flags.contains("--json") {
                let rows: [[String: Any]] = list.map { r in
                    var d: [String: Any] = ["platform": r.platform.rawValue, "version": r.version, "build": r.build, "state": r.state,
                                            "architectures": r.architectures, "runtimeRoot": r.runtimeRoot ?? ""]
                    if let id = r.identifier { d["identifier"] = id }
                    if let b = r.unpackedBytes { d["sizeBytes"] = b }
                    if case .ycode(let f) = r.owner, let m = FileManager.default.contents(atPath: f + "/" + RuntimeFolders.marker),
                       let marker = try? JSONSerialization.jsonObject(with: m) { d["marker"] = marker }
                    return d
                }
                let data = (try? JSONSerialization.data(withJSONObject: rows, options: [.prettyPrinted, .sortedKeys])) ?? Data()
                out(String(decoding: data, as: UTF8.self))
            } else {
                out("Ycode's runtimes in \(folder):")
                if list.isEmpty { out("  (none)") }
                for r in list { out("  \(r.title)  \(r.sizeText)  \(r.architectures.joined(separator: ","))  \(r.runtimeRoot ?? "")") }
            }
            return 0
        case "available":
            let d = RuntimeDirectDownload(folder: folder, transport: tr, reader: nil)
            do {
                let index = try await d.index(force: flags.contains("--refresh"))
                let platforms = positional.first.map { SimPlatform(name: $0).map { [$0] } ?? [] } ?? SimPlatform.allCases
                guard !platforms.isEmpty else { out("unknown platform \(positional[0])"); return 64 }
                for p in platforms {
                    var list = RuntimeSelection.candidates(index, platform: p, host: d.selectionHost)
                    if !flags.contains("--all") { list = Array(list.prefix(8)) }
                    out("\(p.title):")
                    if list.isEmpty { out("  (none Ycode can fetch)") }
                    for e in list { out("  \(e.title)  \(RuntimeSize.format(e.fileSize))") }
                }
                if let m = index.metalToolchain() { out("Metal Toolchain (information): \(m.name), \(RuntimeSize.format(m.fileSize))") }
                return 0
            } catch {
                out("error: \(RuntimeSecrets.scrub(String(describing: error)))")
                return 1
            }
        case "download":
            guard let what = positional.first else { out(usage); return 64 }
            let target: RuntimeDownloadTarget
            if what.lowercased().replacingOccurrences(of: "-", with: "") == "metaltoolchain" {
                target = .metalToolchain(build: opts["--build"])
            } else {
                guard let p = SimPlatform(name: what) else { out("unknown platform \(what)"); return 64 }
                if opts["--build"] != nil && opts["--version"] != nil { out("--build and --version cannot be used together"); return 64 }
                target = .runtime(RuntimeRequest(platform: p, build: opts["--build"], version: opts["--version"], sdkBuild: opts["--sdk-build"]))
            }
            let d = RuntimeDirectDownload(folder: folder, transport: tr)
            d.keep = flags.contains("--keep")
            d.replace = flags.contains("--replace")
            if let s = opts["--stop-after"] {
                guard let stop = RuntimeDownloadStop(rawValue: s), stop != .installed else { out("--stop-after takes queried, downloaded or expanded"); return 64 }
                d.stop = stop
            }
            if case .metalToolchain = target, d.stop == .installed { d.stop = .expanded }
            d.expandTo = opts["--to"]
            if d.stop == .installed, d.reader == nil { out("error: \(SevenZipImageReader.installHint)"); return 1 }
            do {
                let index = try await d.index()
                let chosen = try d.resolve(target, index: index)
                out("Ycode will download \(chosen.name) (\(RuntimeSize.format(chosen.size))) from Apple for you:")
                out("  1. ask \(RuntimeAssetQuery.url.host ?? "") for it, describing this computer as: \(d.host.summary)")
                out("  2. download it into \(folder)/.partial (resumable) and check its size and SHA-256")
                out("  3. decrypt it with the key Apple returns, using \(d.expander.title)")
                if d.stop == .installed { out("  4. read its disk image with \(d.reader?.title ?? "?") and put its RuntimeRoot in \(folder)") }
                out("Nothing is shared or kept for anyone else; the archive is removed afterwards\(d.keep ? " (unless --keep, as given)" : "").")
                guard flags.contains("--yes") || ask("Continue? [y/N] ") else { out("Nothing was downloaded."); return 1 }
                let started = Date()
                // ⌃C cancels: curl and the decryptor stop, the partial file stays for a resume.
                let sigint = interruptHandler { out("Cancelling…"); d.cancel() }
                defer { sigint.cancel() }
                let printer = PhasePrinter(out: out)
                let record = try await d.run(target, event: { printer.show($0) }, log: { out("  " + $0) })
                printer.finish()
                out(String(format: "Done in %.0f s.", Date().timeIntervalSince(started)))
                if let record { out("\(record.title): \(record.runtimeRoot ?? "")") }
                return 0
            } catch let e as RuntimeDownloadError {
                out("error: \(RuntimeSecrets.scrub(e.description))")
                if case .refused = e { out("Other routes: on a Mac, ycode runtime xcodebuild \(positional[0]) --export DIR, then ycode runtime import DIR here.") }
                return e == .cancelled ? 130 : 1
            } catch {
                out("error: \(RuntimeSecrets.scrub(String(describing: error)))")
                return 1
            }
        case "import":
            guard let path = positional.first else { out(usage); return 64 }
            guard FileManager.default.fileExists(atPath: path) else { out("File not found at \(path)"); return 2 }
            let d = RuntimeDirectDownload(folder: folder, transport: tr)
            d.replace = flags.contains("--replace")
            do {
                let r = try await d.importBundle(path) { out("  " + $0) }
                out("\(r.title): \(r.runtimeRoot ?? "")")
                return 0
            } catch {
                out("error: \(RuntimeSecrets.scrub(String(describing: error)))")
                return 1
            }
        case "xcodebuild":
            guard let name = positional.first, let p = SimPlatform(name: name) else { out(usage); return 64 }
            let dl = XcodebuildDownload(platform: p, exportPath: opts["--export"], buildVersion: opts["--build-version"])
            let tool = XcodebuildDownload.tool()
            guard FileManager.default.isExecutableFile(atPath: tool) else { out("xcodebuild was not found: install Xcode, or use ycode runtime download."); return 1 }
            out("Ycode will run Apple's tool to download the runtime:\n  \(dl.shownCommand)")
            guard flags.contains("--yes") || ask("Continue? [y/N] ") else { out("Nothing was run."); return 1 }
            let run = XcodebuildDownloadRun(dl, tool: tool)
            let sigint = interruptHandler { run.cancel() }
            defer { sigint.cancel() }
            let outcome = await run.run(output: { s in FileHandle.standardOutput.write(Data(s.utf8)) }, progress: { _ in })
            switch outcome {
            case .finished: out("Done."); return 0
            case .cancelled: out("Cancelled."); return 130
            case .failed(let s, let tail): out("xcodebuild failed (status \(s)):\n\(tail)"); return 1
            }
        default:
            out(usage)
            return 64
        }
    }

    /// Handles SIGINT in place of the default (which would leave the child running).
    static func interruptHandler(_ h: @escaping @Sendable () -> Void) -> DispatchSourceSignal {
        signal(SIGINT, SIG_IGN)
        let s = DispatchSource.makeSignalSource(signal: SIGINT, queue: .global())
        s.setEventHandler(handler: h)
        s.setCancelHandler { signal(SIGINT, SIG_DFL) }
        s.resume()
        return s
    }

    public static let askOnTerminal: @Sendable (String) -> Bool = { prompt in
        FileHandle.standardOutput.write(Data(prompt.utf8))
        guard let line = readLine() else { return false }
        return ["y", "yes"].contains(line.trimmed.lowercased())
    }

    /// Progress lines, at most one per percent (or per phase).
    final class PhasePrinter: @unchecked Sendable {
        let out: @Sendable (String) -> Void
        let lock = NSLock()
        var lastKey = ""
        var lastPercent = -1
        let started = Date()
        init(out: @escaping @Sendable (String) -> Void) { self.out = out }

        func show(_ p: RuntimeDownloadPhase) {
            let key: String = switch p {
            case .downloading: "d"
            case .verifying: "v"
            case .decrypting: "x"
            default: p.title
            }
            let pct = p.fraction.map { Int($0 * 100) } ?? -1
            let line: String? = lock.withLock {
                if key == lastKey && (pct < 0 || pct / 5 == lastPercent / 5) { return nil }
                lastKey = key
                lastPercent = pct
                let elapsed = Int(Date().timeIntervalSince(started))
                return "[\(elapsed)s] \(p.title)" + (pct >= 0 && p.fraction != 1 ? " (\(pct)%)" : "")
            }
            if let line { out(line) }
        }

        func finish() {}
    }
}
