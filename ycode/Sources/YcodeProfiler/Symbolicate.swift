import Foundation
import YcodeSubprocess
import YcodeMachO

/// Adding images, symbols and source lines to a trace
/// (`specs/ide/profiler.md` §3.2, §4.2, §4.3, §7 `symbolicate`).
public enum GaugeSymbolicator {
    // MARK: Linux mappings

    /// One executable mapping of `/proc/<pid>/maps`.
    public struct Mapping: Sendable, Equatable, Hashable {
        public var start: UInt64
        public var end: UInt64
        public var offset: UInt64
        public var path: String
        public init(start: UInt64, end: UInt64, offset: UInt64, path: String) {
            self.start = start
            self.end = end
            self.offset = offset
            self.path = path
        }
    }

    /// Executable, file-backed mappings of a `/proc/<pid>/maps` text.
    public static func parseMaps(_ text: String) -> [Mapping] {
        text.split(separator: "\n").compactMap { line in
            let f = line.split(separator: " ", maxSplits: 5, omittingEmptySubsequences: true)
            guard f.count >= 6, f[1].contains("x") else { return nil }
            let path = f[5].trimmingCharacters(in: .whitespaces)
            guard path.hasPrefix("/") else { return nil }
            let r = f[0].split(separator: "-")
            guard r.count == 2, let s = UInt64(r[0], radix: 16), let e = UInt64(r[1], radix: 16),
                  let o = UInt64(f[2], radix: 16) else { return nil }
            return Mapping(start: s, end: e, offset: o, path: path)
        }
    }

    /// Places every absolute frame in an ELF image of `mappings`, adds the
    /// images (kind `app` for `appPaths` and files under `appDirectories`,
    /// else `system`) with the symbols and lines of the offsets used.
    public static func resolveELF(_ b: inout GaugeTraceBuilder, mappings: [Mapping], appPaths: Set<String>, appDirectories: [String]) {
        let t = b.trace
        var byPath: [String: (elf: ELFFile?, bias: UInt64, low: UInt64, high: UInt64)] = [:]
        var placed: [Int: (path: String, vaddr: UInt64)] = [:]
        let sorted = mappings.sorted { $0.start < $1.start }
        for (fid, f) in t.frames.enumerated() where f.image < 0 {
            var low = 0, high = sorted.count
            while low < high {
                let mid = (low + high) / 2
                if sorted[mid].start <= f.offset { low = mid + 1 } else { high = mid }
            }
            guard low > 0, f.offset < sorted[low - 1].end else { continue }
            let m = sorted[low - 1]
            if byPath[m.path] == nil {
                let elf = try? ELFFile(contentsOf: URL(fileURLWithPath: m.path))
                let bias = elf?.loadBias(mappingStart: m.start, fileOffset: m.offset) ?? (m.start &- m.offset)
                byPath[m.path] = (elf, bias, m.start, m.end)
            }
            guard var e = byPath[m.path] else { continue }
            e.low = min(e.low, m.start)
            e.high = max(e.high, m.end)
            byPath[m.path] = e
            placed[fid] = (m.path, f.offset &- e.bias)
        }
        var imageIDs: [String: Int] = [:]
        var uses: [String: Set<UInt64>] = [:]
        for (_, p) in placed { uses[p.path, default: []].insert(p.vaddr) }
        for path in byPath.keys.sorted() where uses[path] != nil {
            guard let e = byPath[path] else { continue }
            let isApp = appPaths.contains(path) || appDirectories.contains { path.hasPrefix($0.hasSuffix("/") ? $0 : $0 + "/") }
            var image = GaugeTrace.Image(id: 0, name: (path as NSString).lastPathComponent, path: path, uuid: e.elf?.buildID,
                                         kind: isApp ? .app : .system, base: e.bias, size: e.high &- e.low)
            if let elf = e.elf {
                let offsets = uses[path] ?? []
                var symbols: [UInt64: GaugeTrace.Symbol] = [:]
                for o in offsets {
                    for q in [o, o &- 1] {
                        if let fn = elf.function(containing: q) {
                            symbols[fn.address] = GaugeTrace.Symbol(start: fn.address, end: fn.address &+ fn.size, name: fn.name)
                        }
                    }
                }
                image.symbols = symbols.values.sorted { $0.start < $1.start }
                addLines(&image, offsets: offsets) { elf.lineTable() }
            }
            imageIDs[path] = b.addImage(image)
        }
        b.resolveAbsoluteFrames { _ in nil }
        b.update { tr in
            for (fid, p) in placed {
                if let id = imageIDs[p.path] { tr.frames[fid] = GaugeTrace.Frame(image: id, offset: p.vaddr) }
            }
        }
        b.resolveAbsoluteFrames { _ in nil } // rebuild the frame index
    }

    /// Adds line entries for `offsets` and `offset − 1` from a lazily built table.
    static func addLines(_ image: inout GaugeTrace.Image, offsets: Set<UInt64>, addressBase: UInt64 = 0,
                         table: () -> DWARFLineTable) {
        let lt = table()
        guard !lt.rows.isEmpty else { return }
        var fileIndex: [String: Int] = Dictionary(uniqueKeysWithValues: image.files.enumerated().map { ($1, $0) })
        var entries: [UInt64: GaugeTrace.LineEntry] = Dictionary(image.lines.map { ($0.offset, $0) }, uniquingKeysWith: { a, _ in a })
        for o in offsets {
            for q in [o, o &- 1] {
                guard let (file, line) = lt.lookup(addressBase &+ q) else { continue }
                let fi: Int
                if let i = fileIndex[file] { fi = i } else {
                    fi = image.files.count
                    image.files.append(file)
                    fileIndex[file] = fi
                }
                entries[q] = GaugeTrace.LineEntry(offset: q, file: fi, line: line)
            }
        }
        image.lines = entries.values.sorted { $0.offset < $1.offset }
    }

    // MARK: Mach-O images and dSYMs

    /// The slices of a (possibly fat) Mach-O file: (offset, image).
    public static func machOSlices(_ reader: ByteReader) -> [(offset: Int, image: MachOImage)] {
        guard let magic = try? reader.u32BE(0) else { return [] }
        if magic == MachO.fatMagic || magic == MachO.fatMagic64 {
            let n = Int((try? reader.u32BE(4)) ?? 0)
            var out: [(Int, MachOImage)] = []
            for i in 0..<min(n, 32) {
                let off: Int
                if magic == MachO.fatMagic { off = Int((try? reader.u32BE(8 + i * 20 + 8)) ?? 0) } else { off = Int((try? reader.u64BE(8 + i * 32 + 8)) ?? 0) }
                if let img = try? MachOImage(reader, at: off) { out.append((off, img)) }
            }
            return out
        }
        return (try? MachOImage(reader, at: 0)).map { [(0, $0)] } ?? []
    }

    /// Mach-O files under `roots` (files, `.dSYM` bundles, app bundles,
    /// directories searched two levels deep) by UUID.
    public static func machOFiles(in roots: [URL]) -> [String: URL] {
        var out: [String: URL] = [:]
        func consider(_ url: URL) {
            guard let r = try? ByteReader(contentsOf: url) else { return }
            for (_, img) in machOSlices(r) {
                if let u = img.uuid?.uuidString, out[u] == nil || img.fileType == .dsym || img.segment(named: "__DWARF") != nil { out[u] = url }
            }
        }
        let fm = FileManager.default
        for root in roots {
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: root.path, isDirectory: &isDir) else { continue }
            if !isDir.boolValue { consider(root); continue }
            guard let e = fm.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey], options: []) else { continue }
            var visited = 0
            for case let u as URL in e {
                visited += 1
                if visited > 20000 { break }
                if (try? u.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile != true { continue }
                if u.pathExtension.isEmpty || u.pathExtension == "dylib" || u.path.contains(".dSYM/Contents/Resources/DWARF/") { consider(u) }
            }
        }
        return out
    }

    /// Re-symbolicates Mach-O images of a trace from local files matched by
    /// UUID (dSYMs preferred: their symbol tables have local symbols, and
    /// their DWARF gives lines). Returns the names of images that changed.
    @discardableResult
    public static func symbolicateMachO(_ t: inout GaugeTrace, searching roots: [URL]) -> [String] {
        let files = machOFiles(in: roots)
        var changed: [String] = []
        var usedOffsets: [Int: Set<UInt64>] = [:]
        for f in t.frames where f.image >= 0 { usedOffsets[f.image, default: []].insert(f.offset) }
        for idx in t.images.indices {
            guard let uuid = t.images[idx].uuid?.uppercased(), let url = files[uuid],
                  let reader = try? ByteReader(contentsOf: url),
                  let slice = machOSlices(reader).first(where: { $0.image.uuid?.uuidString == uuid }) else { continue }
            let offsets = usedOffsets[t.images[idx].id] ?? []
            if apply(&t.images[idx], reader: reader, slice: slice, offsets: offsets) { changed.append(t.images[idx].name) }
        }
        return changed
    }

    /// Symbols and lines from one Mach-O slice (a binary or a dSYM).
    static func apply(_ image: inout GaugeTrace.Image, reader: ByteReader, slice: (offset: Int, image: MachOImage), offsets: Set<UInt64>) -> Bool {
        guard let table = try? SymbolTable(file: reader, at: slice.offset) else { return false }
        let text = table.textAddress
        var symbols: [UInt64: GaugeTrace.Symbol] = Dictionary(image.symbols.map { ($0.start, $0) }, uniquingKeysWith: { a, _ in a })
        var covered: [GaugeTrace.Symbol] = []
        for o in offsets {
            for q in [o, o &- 1] {
                guard let fn = table.function(containing: text &+ q) else { continue }
                let s = GaugeTrace.Symbol(start: fn.address &- text, end: fn.address &- text &+ fn.size, name: fn.name)
                covered.append(s)
            }
        }
        guard !covered.isEmpty else { return false }
        // The new symbols replace the old ones they overlap.
        for s in covered {
            for (k, old) in symbols where old.start < s.end && s.start < old.end { symbols.removeValue(forKey: k) }
        }
        for s in covered { symbols[s.start] = s }
        image.symbols = symbols.values.sorted { $0.start < $1.start }
        if let dwarf = slice.image.segment(named: "__DWARF") {
            func section(_ name: String) -> [UInt8] {
                guard let s = dwarf.sections.first(where: { $0.name == name }) else { return [] }
                return (try? reader.bytes(slice.offset + Int(s.fileOffset), Int(s.size))) ?? []
            }
            let line = section("__debug_line")
            if !line.isEmpty {
                addLines(&image, offsets: offsets, addressBase: text) {
                    DWARFLineTable(debugLine: line, lineStrings: section("__debug_line_str"), strings: section("__debug_str"))
                }
            }
        }
        return true
    }

    // MARK: Swift names

    /// Demangles Swift names with `swift-demangle --simplified` and C++
    /// names (`_Z…`, block invocations `__Z…_block_invoke`) with `c++filt`
    /// or `llvm-cxxfilt`, when the tools are found (PATH, then `xcrun
    /// --find`). Returns how many names changed.
    @discardableResult
    public static func demangle(_ t: inout GaugeTrace, tool: String? = nil) -> Int {
        var swift: Set<String> = [], cxx: Set<String> = []
        for img in t.images {
            for s in img.symbols {
                if isSwiftMangled(s.name) { swift.insert(s.name) } else if s.name.hasPrefix("_Z") || s.name.hasPrefix("__Z") || s.name.hasPrefix("___Z") { cxx.insert(s.name) }
            }
        }
        var map: [String: String] = [:]
        if !swift.isEmpty, let exe = tool ?? findTool(["swift-demangle"]) {
            map.merge(runFilter(exe, ["--simplified"], swift.sorted()), uniquingKeysWith: { a, _ in a })
        }
        if !cxx.isEmpty, let exe = findTool(["llvm-cxxfilt", "c++filt"]) {
            // A block invocation keeps its extra underscore ("___Z…_block_invoke").
            let list = cxx.sorted()
            let fed = list.map { $0.hasPrefix("__Z") && !$0.hasPrefix("___Z") ? "_" + $0 : $0 }
            let out = runFilter(exe, [], fed)
            for (orig, f) in zip(list, fed) { if let d = out[f] { map[orig] = d } }
        }
        var n = 0
        for i in t.images.indices {
            for j in t.images[i].symbols.indices {
                if let d = map[t.images[i].symbols[j].name] { t.images[i].symbols[j].name = d; n += 1 }
            }
        }
        return n
    }

    /// Runs a line filter over names: name → output line (unchanged lines left out).
    static func runFilter(_ exe: String, _ args: [String], _ list: [String]) -> [String: String] {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: exe)
        p.arguments = args
        guard let input = try? SpawnPipe(childReads: true), let output = try? SpawnPipe(childReads: false) else { return [:] }
        p.standardInput = input.childEnd
        p.standardOutput = output.childEnd
        p.standardError = FileHandle.nullDevice
        guard (try? p.runWithSignalsUnblocked(closingChildEndsOf: input, output)) != nil else { return [:] }
        let data = Data(list.joined(separator: "\n").appending("\n").utf8)
        DispatchQueue.global().async {
            input.fileHandleForWriting.write(data)
            try? input.fileHandleForWriting.close()
        }
        let out = output.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        let lines = String(decoding: out, as: UTF8.self).split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        guard lines.count >= list.count else { return [:] }
        var map: [String: String] = [:]
        for (i, m) in list.enumerated() where !lines[i].isEmpty && lines[i] != m { map[m] = lines[i] }
        return map
    }

    static func isSwiftMangled(_ s: String) -> Bool {
        s.hasPrefix("$s") || s.hasPrefix("$S") || s.hasPrefix("$e") || s.hasPrefix("_$s") || s.hasPrefix("_T0") || s.hasPrefix("$sS")
    }

    static func findTool(_ names: [String]) -> String? {
        let env = ProcessInfo.processInfo.environment
        for name in names {
            for dir in (env["PATH"] ?? "/usr/bin:/bin").split(separator: ":") {
                let p = "\(dir)/\(name)"
                if FileManager.default.isExecutableFile(atPath: p) { return p }
            }
        }
        #if os(macOS)
        for name in names {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
            p.arguments = ["--find", name]
            guard let out = try? SpawnPipe(childReads: false) else { continue }
            p.standardOutput = out.childEnd
            p.standardError = FileHandle.nullDevice
            guard (try? p.runWithSignalsUnblocked(closingChildEndsOf: out)) != nil else { continue }
            let d = out.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()
            let path = String(decoding: d, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            if p.terminationStatus == 0 && !path.isEmpty { return path }
        }
        #endif
        return nil
    }

}
