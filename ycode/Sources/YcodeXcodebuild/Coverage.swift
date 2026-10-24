import Foundation

/// Code coverage of a test run, gathered with the toolchain's open-source
/// `llvm-cov` from the merged profile, and its two result-bundle forms: the
/// coverage report and the coverage archive.
/// See `specs/xcodebuild/coverage.md`.
public struct CoverageData: Sendable {
    public struct Function: Sendable, Equatable {
        public var name: String
        public var lineNumber: Int
        public var executionCount: Int
        public var executableLines: Int
        public var coveredLines: Int
    }
    /// One source line: executable or not, its count, and the column
    /// ranges whose count differs from the line's (column, length with 0 =
    /// to the end of the line, count).
    public struct Line: Sendable, Equatable {
        public var executable: Bool
        public var count: Int
        public var subranges: [Subrange]
    }
    public struct Subrange: Sendable, Equatable {
        public var column: Int
        public var length: Int
        public var count: Int
    }
    public struct File: Sendable {
        public var path: String
        public var functions: [Function]
        public var lines: [Line]
        public var executableLines: Int { functions.reduce(0) { $0 + $1.executableLines } }
        public var coveredLines: Int { functions.reduce(0) { $0 + $1.coveredLines } }
    }
    public struct Target: Sendable {
        public var name: String
        public var buildableIdentifier: String
        public var productPath: String
        public var files: [File]
        public var executableLines: Int { files.reduce(0) { $0 + $1.executableLines } }
        public var coveredLines: Int { files.reduce(0) { $0 + $1.coveredLines } }
    }
    public var targets: [Target]
    public var executableLines: Int { targets.reduce(0) { $0 + $1.executableLines } }
    public var coveredLines: Int { targets.reduce(0) { $0 + $1.coveredLines } }
    public var fraction: Double { executableLines == 0 ? 0 : Double(coveredLines) / Double(executableLines) }
}

/// A target whose code coverage is reported.
struct CoverageTarget {
    var name: String
    var blueprintIdentifier: String
    /// The binary with the target's code (nil for static libraries, whose
    /// code is in the binaries that link them).
    var binary: String?
    var productPath: String
    /// Source files of the target (absolute) and folders whose files it
    /// builds (synchronized groups).
    var sources: Set<String>
    var folders: [String]
    /// Reported even when it owns no covered file (package library products).
    var listedWithoutFiles = false

    func owns(_ path: String) -> Bool {
        // `/private/tmp/x` and `/tmp/x` name the same file on macOS.
        let p = PathText.withoutPrivatePrefix(path)
        return sources.contains(path) || sources.contains(p) || folders.contains {
            let f = PathText.withoutPrivatePrefix($0)
            return p.hasPrefix(f.hasSuffix("/") ? f : f + "/")
        }
    }
}

enum Coverage {
    // MARK: Gathering

    /// The scheme's targets as coverage sees them: test bundles first, then
    /// the other targets in scheme order.
    static func targets(plan: Plan, context ctx: XcodebuildContext) -> [CoverageTarget] {
        if let package = plan.package { return packageTargets(package, plan: plan, context: ctx) }
        // The scheme's targets and every other target of its projects (the
        // test bundles' dependencies are reported too).
        var all = plan.targets
        for p in plan.container.projects {
            for t in p.targets where ProjectPIF.targetKind(t) != nil && !all.contains(where: { $0.target.id == t.id && $0.project.url == p.url }) {
                all.append(SettingsTarget(project: p, target: t))
            }
        }
        guard let settings = try? ShowBuildSettings.provider(ctx).settings(container: plan.container, targets: all,
                                                                          parameters: plan.parameters(action: .build)) else { return [] }
        var out: [CoverageTarget] = []
        for (t, s) in zip(all, settings) {
            let dir = s["TARGET_BUILD_DIR"] ?? s["BUILT_PRODUCTS_DIR"] ?? ""
            let product = s["FULL_PRODUCT_NAME"] ?? t.name
            let exe = s["EXECUTABLE_PATH"] ?? ""
            let isStatic = (t.target.string("productType") ?? "").hasSuffix(".library.static")
            let binary = isStatic || exe.isEmpty ? nil : dir + "/" + exe
            let proj = t.project.proj
            let parents = proj.parentMap()
            var sources = Set<String>()
            for pid in t.target.references("buildPhases") where proj[pid]?.isa == "PBXSourcesBuildPhase" {
                for bf in proj[pid]?.references("files") ?? [] {
                    guard let ref = proj[bf]?.string("fileRef"),
                          let path = proj.resolvedPath(of: ref, projectDirectory: t.project.directory, parents: parents) else { continue }
                    sources.insert(path)
                }
            }
            let folders = t.target.references("fileSystemSynchronizedGroups").compactMap {
                proj.resolvedPath(of: $0, projectDirectory: t.project.directory, parents: parents)
            }
            out.append(CoverageTarget(name: product, blueprintIdentifier: t.target.id, binary: binary,
                                      productPath: binary ?? dir + "/" + product, sources: sources, folders: folders))
        }
        let tests = all.map { Container.isTestBundle($0.target) }
        return zip(out, tests).filter { $0.1 }.map(\.0) + zip(out, tests).filter { !$0.1 }.map(\.0)
    }

    /// A package scheme's coverage targets: its library products, each with
    /// its package framework and no files, then the test targets with their
    /// bundles' executables and the files in their folders.
    static func packageTargets(_ package: Plan.PackageBuild, plan: Plan, context ctx: XcodebuildContext) -> [CoverageTarget] {
        let tests = (try? TestActions.packageTargets(package, plan: plan, context: ctx)) ?? []
        let products = tests.first?.productsDirectory ?? plan.arena.map { $0.buildProductsPath + "/" + plan.configuration } ?? ""
        var out: [CoverageTarget] = package.coverageLibraries.map { lib in
            CoverageTarget(name: lib.name, blueprintIdentifier: "PACKAGE-PRODUCT:" + lib.name, binary: nil,
                           productPath: products + "/PackageFrameworks/" + lib.framework + ".framework/" + lib.framework,
                           sources: [], folders: [], listedWithoutFiles: true)
        }
        for t in package.targets where t.isTest {
            guard let bundle = tests.first(where: { $0.moduleName == t.name }) else { continue }
            out.append(CoverageTarget(name: t.name, blueprintIdentifier: "PACKAGE-TARGET:" + t.name, binary: bundle.executablePath,
                                      productPath: bundle.executablePath, sources: [], folders: [t.path]))
        }
        return out
    }

    /// `<ProfileData>/<device id>/Coverage.profdata`.
    static func profilePath(profileDirectory: String) -> String {
        profileDirectory + "/" + (Destinations.macProvisioningUDID() ?? "local") + "/Coverage.profdata"
    }

    static func toolchainTool(_ name: String, developerDirectory dev: String) -> String? {
        let p = dev + "/Toolchains/XcodeDefault.xctoolchain/usr/bin/" + name
        return FileManager.default.isExecutableFile(atPath: p) ? p : nil
    }

    /// The coverage of `targets` from the merged profile, or nil when there
    /// is nothing to report.
    static func collect(profile: String, targets: [CoverageTarget], developerDirectory dev: String) -> CoverageData? {
        guard FileManager.default.fileExists(atPath: profile), let llvmCov = toolchainTool("llvm-cov", developerDirectory: dev) else { return nil }
        let binaries = targets.compactMap(\.binary).filter { FileManager.default.fileExists(atPath: $0) }.uniqued()
        guard let first = binaries.first else { return nil }
        var objects = [first]
        for b in binaries.dropFirst() { objects += ["-object", b] }
        let env = ProcessInfo.processInfo.environment
        let export = TestActions.run(llvmCov, ["export", "-instr-profile", profile] + objects, environment: env)
        guard export.status == 0, let root = try? JSONSerialization.jsonObject(with: Data(export.output.utf8)) as? [String: Any],
              let data = (root["data"] as? [[String: Any]])?.first else { return nil }
        let files = data["files"] as? [[String: Any]] ?? []
        let functions = data["functions"] as? [[String: Any]] ?? []
        let paths = files.compactMap { $0["filename"] as? String }
        guard !paths.isEmpty else { return nil }
        // Per-function line counts, from llvm-cov's own function report.
        let report = TestActions.run(llvmCov, ["report", "-show-functions", "-instr-profile", profile] + objects + paths, environment: env)
        let rows = parseFunctionReport(report.output)
        // Start line and entry count of each function, by file and name.
        var starts: [String: (line: Int, count: Int)] = [:]
        for f in functions {
            guard let name = f["name"] as? String, let file = (f["filenames"] as? [String])?.first,
                  let region = (f["regions"] as? [[Any]])?.first, let line = region.first as? Int else { continue }
            let key = file + "\u{0}" + name
            if starts[key] == nil { starts[key] = (line, f["count"] as? Int ?? 0) }
        }
        let demangled = demangle(rows.values.flatMap { $0.map(\.name) }, developerDirectory: dev)
        var byPath: [String: CoverageData.File] = [:]
        for f in files {
            guard let path = f["filename"] as? String else { continue }
            let segments = (f["segments"] as? [[Any]] ?? []).compactMap(Segment.init)
            let fns: [CoverageData.Function] = (rows[path] ?? []).map { r in
                let s = starts[path + "\u{0}" + r.name]
                return CoverageData.Function(name: demangled[r.name] ?? r.name, lineNumber: s?.line ?? 0, executionCount: s?.count ?? 0,
                                             executableLines: r.lines, coveredLines: r.lines - r.missed)
            }.sorted { $0.lineNumber < $1.lineNumber }
            byPath[path] = CoverageData.File(path: path, functions: fns, lines: lineCoverage(segments))
        }
        var out: [CoverageData.Target] = []
        for t in targets {
            let owned = paths.filter { t.owns($0) }.compactMap { byPath[$0] }
            guard !owned.isEmpty || t.listedWithoutFiles else { continue }
            out.append(.init(name: t.name, buildableIdentifier: t.blueprintIdentifier + ":primary", productPath: t.productPath, files: owned))
        }
        return out.isEmpty ? nil : CoverageData(targets: out)
    }

    struct ReportRow { var name: String; var lines: Int; var missed: Int }

    /// `llvm-cov report -show-functions` text: per `File '<path>':` block,
    /// rows of name and counters; the `Lines` and following `Miss` columns.
    static func parseFunctionReport(_ text: String) -> [String: [ReportRow]] {
        var out: [String: [ReportRow]] = [:]
        var file: String?
        var linesColumn: Int?
        var numeric = 0
        for raw in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(raw)
            if line.hasPrefix("File '"), line.hasSuffix("':") {
                file = String(line.dropFirst(6).dropLast(2))
                continue
            }
            let tokens = line.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
            if tokens.first == "Name", let i = tokens.firstIndex(of: "Lines") {
                linesColumn = tokens.count - i   // position from the end
                numeric = tokens.count - 1
                continue
            }
            guard let f = file, let c = linesColumn, tokens.count > numeric, !line.hasPrefix("-"), tokens.first != "TOTAL",
                  let lines = Int(tokens[tokens.count - c]), let missed = Int(tokens[tokens.count - c + 1]) else { continue }
            out[f, default: []].append(ReportRow(name: tokens[0..<(tokens.count - numeric)].joined(separator: " "), lines: lines, missed: missed))
        }
        return out
    }

    /// Swift symbol names in the simplified form (`static Calc.add(_:_:)`),
    /// through the toolchain's open-source `swift-demangle`; others as is.
    static func demangle(_ names: [String], developerDirectory dev: String) -> [String: String] {
        let swiftNames = names.filter { $0.hasPrefix("$s") || $0.hasPrefix("_$s") }.uniqued()
        guard !swiftNames.isEmpty, let tool = toolchainTool("swift-demangle", developerDirectory: dev) else { return [:] }
        let input = FileManager.default.temporaryDirectory.appendingPathComponent("ycodebuild-symbols-\(UUID().uuidString).txt")
        defer { try? FileManager.default.removeItem(at: input) }
        guard (try? swiftNames.joined(separator: "\n").write(to: input, atomically: true, encoding: .utf8)) != nil else { return [:] }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: tool)
        p.arguments = ["--simplified"]
        let out = Pipe()
        p.standardOutput = out
        p.standardInput = try? FileHandle(forReadingFrom: input)
        p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return [:] }
        let text = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        p.waitUntilExit()
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        var map: [String: String] = [:]
        for (n, d) in zip(swiftNames, lines) where !d.isEmpty { map[n] = d }
        return map
    }

    // MARK: Lines

    /// One llvm-cov export segment: line, column, count, has-count,
    /// region entry, gap region.
    struct Segment {
        var line: Int, column: Int, count: Int, hasCount: Bool, isRegionEntry: Bool, isGap: Bool
        init?(_ a: [Any]) {
            guard a.count >= 5, let l = a[0] as? Int, let c = a[1] as? Int else { return nil }
            line = l; column = c
            count = a[2] as? Int ?? Int((a[2] as? Double) ?? 0)
            hasCount = a[3] as? Bool ?? false
            isRegionEntry = a[4] as? Bool ?? false
            isGap = a.count > 5 ? (a[5] as? Bool ?? false) : false
        }
        init(line: Int, column: Int, count: Int, hasCount: Bool, isRegionEntry: Bool, isGap: Bool) {
            (self.line, self.column, self.count, self.hasCount, self.isRegionEntry, self.isGap) = (line, column, count, hasCount, isRegionEntry, isGap)
        }
    }

    /// Per-line coverage from a file's segments, lines 1 through the last
    /// executable one. Whether a line is executable and its count follow
    /// LLVM's line-coverage rules (open-source `LineCoverageStats`); the
    /// subranges are the column ranges between the segments on the line
    /// whose count differs from the line's.
    static func lineCoverage(_ segments: [Segment]) -> [CoverageData.Line] {
        guard let lastLine = segments.map(\.line).max() else { return [] }
        var lines: [CoverageData.Line] = []
        var wrapped: Segment?
        var index = 0
        for n in 1...lastLine {
            var onLine: [Segment] = []
            while index < segments.count, segments[index].line == n { onLine.append(segments[index]); index += 1 }
            func isStart(_ s: Segment) -> Bool { !s.isGap && s.hasCount && s.isRegionEntry }
            let starts = onLine.filter(isStart)
            let skipped = onLine.first.map { !$0.hasCount && $0.isRegionEntry } ?? false
            let mapped = !skipped && ((wrapped?.hasCount ?? false) || !starts.isEmpty)
            var count = 0
            if mapped {
                if let w = wrapped, w.hasCount { count = w.count }
                for st in starts { count = max(count, st.count) }
            }
            var subranges: [CoverageData.Subrange] = []
            if mapped {
                // Ranges: [1, first) with the wrapped count, then between segments.
                var bounds: [(column: Int, count: Int?)] = [(1, (wrapped?.hasCount ?? false) ? wrapped!.count : nil)]
                for s in onLine { bounds.append((s.column, s.hasCount ? s.count : nil)) }
                for (i, b) in bounds.enumerated() {
                    let end = i + 1 < bounds.count ? bounds[i + 1].column : nil
                    if let e = end, e <= b.column { continue }
                    guard let c = b.count, c != count else { continue }
                    let length = end.map { $0 - b.column } ?? 0
                    if let last = subranges.last, last.count == c, last.length > 0, last.column + last.length == b.column {
                        subranges[subranges.count - 1].length = length == 0 ? 0 : last.length + length
                    } else {
                        subranges.append(.init(column: b.column, length: length, count: c))
                    }
                }
            }
            lines.append(.init(executable: mapped, count: count, subranges: subranges))
            if let l = onLine.last { wrapped = l }
        }
        while let l = lines.last, !l.executable { lines.removeLast() }
        return lines
    }

    // MARK: Result-bundle forms

    /// The coverage archive's files: `Coverage`, `Index`, `Metadata.plist`.
    static func archiveFiles(_ c: CoverageData) -> [(name: String, bytes: [UInt8])] {
        var coverage: [UInt8] = []
        var offsets: [String: Int] = [:]
        func u32(_ v: Int) -> [UInt8] { (0..<4).map { UInt8(truncatingIfNeeded: UInt32(truncatingIfNeeded: v) >> (8 * UInt32($0))) } }
        func u64(_ v: Int) -> [UInt8] { (0..<8).map { UInt8(truncatingIfNeeded: UInt64(v) >> (8 * UInt64($0))) } }
        for t in c.targets {
            for f in t.files where offsets[f.path] == nil {
                offsets[f.path] = coverage.count
                // Runs of lines with the same executability and count.
                var runs: [(count: Int, executable: Bool, length: Int)] = []
                for l in f.lines {
                    if let last = runs.last, last.executable == l.executable, last.count == l.count, last.length < 0x8000 {
                        runs[runs.count - 1].length += 1
                    } else {
                        runs.append((l.count, l.executable, 1))
                    }
                }
                coverage += u32(runs.count)
                for r in runs {
                    coverage += u32(r.executable ? r.count : 0)
                    coverage += u32((r.executable ? 0x8000_0000 : 0) | ((r.length - 1) << 16))
                }
                let subs = f.lines.enumerated().flatMap { n, l in l.subranges.map { (n + 1, $0) } }
                coverage += u32(subs.count)
                for (line, s) in subs { coverage += u32(line) + u32(s.column) + u32(s.length) + u32(s.count) + u32(0) }
            }
        }
        let paths = offsets.keys.sorted()
        var index = u32(paths.count)
        var names: [UInt8] = []
        let tableEnd = 4 + 16 * paths.count
        var entries: [UInt8] = []
        for p in paths {
            entries += u64(tableEnd + names.count) + u64(offsets[p]!)
            let bytes = Array(p.utf8)
            names += [UInt8(bytes.count & 0xFF), UInt8((bytes.count >> 8) & 0xFF)] + bytes
        }
        index += entries + names
        let metadata = (try? PropertyListSerialization.data(fromPropertyList: ["formatVersion": 1], format: .xml, options: 0)).map { [UInt8]($0) } ?? []
        return [("Coverage", coverage), ("Index", index), ("Metadata.plist", metadata)]
    }

    /// The coverage report: a keyed archive of the report, target and file
    /// objects (class names and keys from the format;
    /// `specs/xcodebuild/coverage.md` §3), written by hand so that every
    /// platform gives the same bytes. `name` is the report's identifier.
    static func reportArchive(_ c: CoverageData, name: String = UUID().uuidString) -> [UInt8]? {
        let container = "XCTHCoverageDataContainer"
        func counts(_ covered: Int, _ executable: Int) -> [(String, BPlist)] {
            [("coveredLines", .int(covered)), ("executableLines", .int(executable))]
        }
        func file(_ f: CoverageData.File, _ a: inout KeyedArchive) -> BPlist {
            a.object(["XCTHCodeCoverageFile", container, "NSObject"]) { a in
                [("name", a.string(URL(fileURLWithPath: f.path).lastPathComponent))]
                    + counts(f.coveredLines, f.executableLines)
                    + [("documentLocation", a.string(f.path)),
                       ("functions", a.mutableData([UInt8](functionTable(f.functions))))]
            }
        }
        func target(_ t: CoverageData.Target, _ a: inout KeyedArchive) -> BPlist {
            a.object(["XCTHCodeCoverageTarget", container, "NSObject"]) { a in
                [("name", a.string(t.name))] + counts(t.coveredLines, t.executableLines)
                    + [("buildableIdentifier", a.string(t.buildableIdentifier)),
                       ("productPath", a.string(t.productPath)),
                       ("sourceFiles", a.array(mutable: true) { a in t.files.map { file($0, &a) } })]
            }
        }
        var archive = KeyedArchive()
        let root = archive.object(["XCTHCodeCoverage", container, "NSObject"]) { a in
            [("name", a.string(name))] + counts(c.coveredLines, c.executableLines)
                + [("buildableCoverageObjects", a.array(mutable: false) { a in c.targets.map { target($0, &a) } }),
                   ("creationErrors", a.array(mutable: true) { _ in [] })]
        }
        return archive.encoded(root: root)
    }

    /// The per-file function table: count, then per function six 32-bit
    /// little-endian fields (covered lines, executable lines, line number,
    /// executable lines, execution count, 0), then the names, each ending
    /// with a NUL byte.
    static func functionTable(_ fns: [CoverageData.Function]) -> Data {
        func u32(_ v: Int) -> [UInt8] { (0..<4).map { UInt8(truncatingIfNeeded: UInt32(truncatingIfNeeded: v) >> (8 * UInt32($0))) } }
        var b = u32(fns.count)
        for f in fns {
            b += u32(f.coveredLines) + u32(f.executableLines) + u32(f.lineNumber) + u32(f.executableLines) + u32(f.executionCount) + u32(0)
        }
        for f in fns { b += Array(f.name.utf8) + [0] }
        return Data(b)
    }
}

// MARK: - Summary for the IDE

extension Coverage {
    /// The environment variable that asks ycodebuild to write a coverage
    /// summary for Ycode's test report (Coverage page) to the named path.
    /// Ycode's own JSON, not an Apple format: `{"targets": [{"name",
    /// "coveredLines", "executableLines", "files": [{"path",
    /// "coveredLines", "executableLines"}]}]}`.
    public static let summaryVariable = "YCODE_COVERAGE_SUMMARY"

    static func summaryJSON(_ c: CoverageData) -> Data {
        let targets: [[String: Any]] = c.targets.map { t in
            ["name": t.name, "coveredLines": t.coveredLines, "executableLines": t.executableLines,
             "files": t.files.map { ["path": $0.path, "coveredLines": $0.coveredLines, "executableLines": $0.executableLines] as [String: Any] }]
        }
        return (try? JSONSerialization.data(withJSONObject: ["targets": targets], options: [.sortedKeys])) ?? Data()
    }
}
