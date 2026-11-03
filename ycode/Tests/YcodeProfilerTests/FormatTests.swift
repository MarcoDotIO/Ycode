import Foundation
import Testing
@testable import YcodeMachO
@testable import YcodeProfiler

@Suite struct TraceCodecTests {
    @Test func roundTripKeepsEverything() throws {
        var t = Synthetic.trace()
        t.recording.notes = ["note"]
        t.recording.startDate = Date(timeIntervalSince1970: 1_800_000_000)
        t.signposts = [.init(name: "Load", subsystem: "s", category: "c", id: 0xEEEE_B0B5_B2B2_EEEE, thread: 7, begin: 1, end: 9, message: "m", flags: ["open"]),
                       .init(name: "Tick", begin: 4, end: nil, kind: .event)]
        t.hangs = [.init(thread: 7, begin: 0, end: 9_000_000)]
        t.presents = [1, 2, 3]
        t.gpu = [.init(pid: 7, process: "App", submit: 5, end: 9, gpuNs: 3)]
        // An absolute kernel address does not fit a double: written as hex.
        var b = GaugeTraceBuilder(recording: t.recording)
        b.update { $0 = t }
        let kernelFrame = b.frameID(.init(image: -1, offset: 0xFFFF_0000_0000_1234))
        b.addSample(time: 99, thread: 8, state: .kernel, stack: b.stackID(frameIDs: [kernelFrame]))
        t = b.finish()
        let data = try GaugeTraceCodec.encode(t)
        #expect(String(decoding: data, as: UTF8.self).contains("\"0xffff000000001234\""))
        let back = try GaugeTraceCodec.decode(data)
        #expect(back == t)
    }

    @Test func refusesOtherDocumentsAndNewerVersions() throws {
        #expect(throws: GaugeTraceCodec.Failure.self) { try GaugeTraceCodec.decode(Data("{\"format\":\"other\"}".utf8)) }
        let newer = Data("{\"format\":\"ycode-gauge-trace\",\"version\":99}".utf8)
        do {
            _ = try GaugeTraceCodec.decode(newer)
            Issue.record("a newer version was accepted")
        } catch let e as GaugeTraceCodec.Failure {
            #expect(e.description.contains("newer"))
        }
        #expect(throws: (any Error).self) { try GaugeTraceCodec.decode(Data([0x1F, 0x8B, 0, 0])) }
        // A sample naming a stack that does not exist.
        let bad = Data("{\"format\":\"ycode-gauge-trace\",\"version\":1,\"samples\":{\"time\":[1],\"thread\":[1],\"stack\":[5],\"state\":[\"user\"]}}".utf8)
        #expect(throws: GaugeTraceCodec.Failure.self) { try GaugeTraceCodec.decode(bad) }
    }

    @Test func minimalDocumentReads() throws {
        let t = try GaugeTraceCodec.decode(Data("{\"format\":\"ycode-gauge-trace\",\"version\":1}".utf8))
        #expect(t.samples.count == 0 && t.recording.sampleIntervalNs == 1_000_000)
    }
}

/// DWARF line programs built by hand (DWARF 4 and 5 encodings).
@Suite struct DWARFLineTests {
    static func uleb(_ v: UInt64) -> [UInt8] {
        var v = v, out: [UInt8] = []
        repeat {
            var b = UInt8(v & 0x7F)
            v >>= 7
            if v != 0 { b |= 0x80 }
            out.append(b)
        } while v != 0
        return out
    }
    static func le<T: FixedWidthInteger>(_ v: T) -> [UInt8] { withUnsafeBytes(of: v.littleEndian) { Array($0) } }
    static let standardLengths: [UInt8] = [0, 1, 1, 1, 1, 0, 0, 0, 1, 0, 0, 1]
    static func setAddress(_ a: UInt64) -> [UInt8] { [0, 9, 2] + le(a) }

    static func unit(version: UInt16, headerTail: [UInt8], program: [UInt8]) -> [UInt8] {
        var header: [UInt8] = []
        if version >= 5 { header += [8, 0] }
        let fields: [UInt8] = [4, 1, 1, UInt8(bitPattern: -5), 14, 13] + standardLengths + headerTail
        header += le(UInt32(fields.count)) + fields
        let body = le(version) + header + program
        return le(UInt32(body.count)) + body
    }

    @Test func version4() {
        let tail: [UInt8] = Array("/src".utf8) + [0, 0] + Array("a.c".utf8) + [0, 1, 0, 0, 0]
        // set_address 0x1000; advance_line 9; copy; special (+8 bytes, +1 line); advance_pc 1×4; end_sequence.
        let program = Self.setAddress(0x1000) + [3, 9, 1, 47, 2, 1, 0, 1, 1]
        let table = DWARFLineTable(debugLine: Self.unit(version: 4, headerTail: tail, program: program))
        #expect(table.lookup(0x1000)! == ("/src/a.c", 10))
        #expect(table.lookup(0x1004)! == ("/src/a.c", 10))
        #expect(table.lookup(0x1008)! == ("/src/a.c", 11))
        #expect(table.lookup(0x100B)! == ("/src/a.c", 11))
        #expect(table.lookup(0x100C) == nil)
        #expect(table.lookup(0x0FFF) == nil)
    }

    @Test func version5WithLineStrings() {
        let lineStr: [UInt8] = Array("/build".utf8) + [0] + Array("inc".utf8) + [0]
        var tail: [UInt8] = [1] + Self.uleb(1) + Self.uleb(0x1F) + Self.uleb(2) + Self.le(UInt32(0)) + Self.le(UInt32(7))
        tail += [2] + Self.uleb(1) + Self.uleb(0x08) + Self.uleb(2) + Self.uleb(0x0B) + Self.uleb(2)
        tail += Array("main.swift".utf8) + [0, 0] + Array("util.h".utf8) + [0, 1]
        // set_address 0x2000; set_file 1; advance_line 4; copy; special (+4, +1);
        // set_file 0; advance_pc 1×4; advance_line 9; copy; advance_pc 1×4; end_sequence.
        let program = Self.setAddress(0x2000) + [4, 1, 3, 4, 1, 20 + 13, 4, 0, 2, 1, 3, 9, 1, 2, 1, 0, 1, 1]
        let two = Self.unit(version: 5, headerTail: tail, program: program)
        // Two units: the same unit twice at another address checks the file numbering of the second unit.
        let table = DWARFLineTable(debugLine: two, lineStrings: lineStr)
        #expect(table.lookup(0x2000)! == ("/build/inc/util.h", 5))
        #expect(table.lookup(0x2005)!.line == 6)
        #expect(table.lookup(0x2008)! == ("/build/main.swift", 15))
        #expect(table.lookup(0x200C) == nil)
    }
}

/// A minimal ELF64 file: one PT_LOAD, .text, .symtab, .strtab, .shstrtab, a build id.
@Suite struct ELFTests {
    static func le<T: FixedWidthInteger>(_ v: T) -> [UInt8] { withUnsafeBytes(of: v.littleEndian) { Array($0) } }

    static func makeELF() -> [UInt8] {
        let shstr: [UInt8] = [0] + Array(".text\0.symtab\0.strtab\0.shstrtab\0.note.gnu.build-id\0".utf8)
        let strtab: [UInt8] = [0] + Array("hot_loop\0main\0data_object\0".utf8)
        func sym(_ name: UInt32, _ info: UInt8, _ shndx: UInt16, _ value: UInt64, _ size: UInt64) -> [UInt8] {
            le(name) + [info, 0] + le(shndx) + le(value) + le(size)
        }
        let symtab = sym(0, 0, 0, 0, 0) + sym(1, 0x12, 1, 0x401000, 0x40) + sym(10, 0x12, 1, 0x401040, 0) + sym(15, 0x11, 1, 0x402000, 8)
        let note: [UInt8] = le(UInt32(4)) + le(UInt32(4)) + le(UInt32(3)) + Array("GNU\0".utf8) + [0xDE, 0xAD, 0xBE, 0xEF]
        // Layout: header (64), phdr (56) at 64, then data from 0x100.
        var body: [UInt8] = []
        let textOff = 0x100, textSize = 0x80
        var file = [UInt8](repeating: 0, count: textOff)
        file += [UInt8](repeating: 0x90, count: textSize)
        let symOff = file.count; file += symtab
        let strOff = file.count; file += strtab
        let shstrOff = file.count; file += shstr
        let noteOff = file.count; file += note
        while file.count % 8 != 0 { file.append(0) }
        let shoff = file.count
        func sh(_ name: UInt32, _ type: UInt32, _ addr: UInt64, _ off: Int, _ size: Int, _ link: UInt32, _ ent: UInt64) -> [UInt8] {
            le(name) + le(type) + le(UInt64(0)) + le(addr) + le(UInt64(off)) + le(UInt64(size)) + le(link) + le(UInt32(0)) + le(UInt64(8)) + le(ent)
        }
        body += [UInt8](repeating: 0, count: 64)
        body += sh(1, 1, 0x401000, textOff, textSize, 0, 0)
        body += sh(7, 2, 0, symOff, symtab.count, 3, 24)
        body += sh(15, 3, 0, strOff, strtab.count, 0, 0)
        body += sh(23, 3, 0, shstrOff, shstr.count, 0, 0)
        body += sh(33, 7, 0, noteOff, note.count, 0, 0)
        file += body
        var h: [UInt8] = [0x7F, 0x45, 0x4C, 0x46, 2, 1, 1, 0] + [UInt8](repeating: 0, count: 8)
        h += le(UInt16(3)) + le(UInt16(62)) + le(UInt32(1)) + le(UInt64(0x401000)) + le(UInt64(64)) + le(UInt64(shoff))
        h += le(UInt32(0)) + le(UInt16(64)) + le(UInt16(56)) + le(UInt16(1)) + le(UInt16(64)) + le(UInt16(6)) + le(UInt16(4))
        let ph: [UInt8] = le(UInt32(1)) + le(UInt32(5)) + le(UInt64(0)) + le(UInt64(0x400000)) + le(UInt64(0x400000)) + le(UInt64(0x1000)) + le(UInt64(0x1000)) + le(UInt64(0x1000))
        file.replaceSubrange(0..<64, with: h)
        file.replaceSubrange(64..<120, with: ph)
        return file
    }

    @Test func symbolsSegmentsAndBuildID() throws {
        let elf = try ELFFile(bytes: Self.makeELF())
        #expect(elf.type == 3 && elf.machine == 62)
        #expect(elf.functions.map(\.name) == ["hot_loop", "main"])
        #expect(elf.function(containing: 0x401010)?.name == "hot_loop")
        // main has no size: up to the end (16 bytes when it is the last).
        #expect(elf.function(containing: 0x401045)?.name == "main")
        #expect(elf.function(containing: 0x402000) == nil)
        #expect(elf.buildID == "deadbeef")
        // A PIE mapped at 0x7f0000400000 from offset 0: bias = start − vaddr.
        #expect(elf.loadBias(mappingStart: 0x7F00_0040_0000, fileOffset: 0) == 0x7F00_0000_0000)
        #expect(throws: ELFFile.Failure.self) { try ELFFile(bytes: [UInt8](repeating: 0, count: 100)) }
    }

    @Test func resolvesAbsoluteFramesThroughMaps() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("gauge-elf-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let path = dir.appendingPathComponent("prog").path
        try Data(Self.makeELF()).write(to: URL(fileURLWithPath: path))
        let maps = GaugeSymbolicator.parseMaps("""
        7f0000400000-7f0000401000 r--p 00000000 08:01 1 \(path)
        7f0000401000-7f0000402000 r-xp 00001000 08:01 1 \(path)
        7fff00000000-7fff00001000 r-xp 00000000 00:00 0 [vdso]
        """)
        #expect(maps.count == 1)
        var b = GaugeTraceBuilder(recording: .init(target: "linux"))
        b.addSample(time: 0, thread: 1, state: .user, frames: [.init(image: -1, offset: 0x7F00_0040_1044), .init(image: -1, offset: 0x7F00_0040_1008)])
        b.addSample(time: 1, thread: 1, state: .user, frames: [.init(image: -1, offset: 0x1234)])
        GaugeSymbolicator.resolveELF(&b, mappings: maps, appPaths: [path], appDirectories: [])
        let t = b.finish()
        #expect(t.images.count == 1 && t.images[0].kind == .app && t.images[0].uuid == "deadbeef")
        let tree = CallTree(trace: t)
        #expect(tree.root.children.map(\.name).sorted() == ["0x1234", "main"])
        #expect(tree.root.children.first { $0.name == "main" }?.children.first?.name == "hot_loop")
    }

    @Test func agentRecordsParse() {
        func rec(_ tid: UInt32, _ time: UInt64, _ pc: UInt64, _ ras: [UInt64]) -> [UInt8] {
            Self.le(UInt32(0x3141_4759)) + Self.le(UInt16(32 + 8 * ras.count)) + Self.le(UInt16(ras.count)) + Self.le(UInt32(9)) + Self.le(tid)
                + Self.le(time) + Self.le(pc) + ras.flatMap { Self.le($0) }
        }
        let bytes = rec(10, 100, 0xAAAA, [0xBBBB, 0xCCCC]) + rec(11, 200, 0xDDDD, []) + [1, 2, 3]
        let s = LinuxRecorder.parseAgentSamples(bytes)
        #expect(s.count == 2)
        #expect(s[0].tid == 10 && s[0].time == 100 && s[0].frames == [0xAAAA, 0xBBBB, 0xCCCC])
        #expect(s[1].frames == [0xDDDD])
    }
}

/// `nlist_64` symbol tables in a synthetic Mach-O (YcodeMachO.SymbolTable).
@Suite struct MachOSymbolTests {
    static func le<T: FixedWidthInteger>(_ v: T) -> [UInt8] { withUnsafeBytes(of: v.littleEndian) { Array($0) } }
    static func name16(_ s: String) -> [UInt8] { Array(s.utf8.prefix(16)) + [UInt8](repeating: 0, count: 16 - min(16, s.utf8.count)) }

    /// __TEXT (vm 0x1_0000_0000) with __text at +0x400 (0x100 bytes),
    /// __LINKEDIT at file 0x1000 holding the symbols and strings.
    static func make(uuid: [UInt8] = Array(0..<16)) -> [UInt8] {
        let strings: [UInt8] = [0x20, 0] + Array("_main\0_compute\0_data\0ltmp0\0".utf8)
        func nlist(_ strx: UInt32, _ type: UInt8, _ sect: UInt8, _ value: UInt64) -> [UInt8] { le(strx) + [type, sect] + le(UInt16(0)) + le(value) }
        let syms = nlist(2, 0x0F, 1, 0x1_0000_0400) + nlist(8, 0x0F, 1, 0x1_0000_0440) + nlist(17, 0x0F, 2, 0x1_0000_0600)
            + nlist(23, 0x0E, 1, 0x1_0000_0480) + nlist(2, 0x24, 1, 0x1_0000_0400)
        var cmds: [UInt8] = []
        // LC_SEGMENT_64 __TEXT with __text (code) and __const (data).
        let text: [UInt8] = le(UInt32(0x19)) + le(UInt32(72 + 2 * 80)) + name16("__TEXT") + le(UInt64(0x1_0000_0000)) + le(UInt64(0x1000))
            + le(UInt64(0)) + le(UInt64(0x1000)) + le(UInt32(5)) + le(UInt32(5)) + le(UInt32(2)) + le(UInt32(0))
            + name16("__text") + name16("__TEXT") + le(UInt64(0x1_0000_0400)) + le(UInt64(0x100)) + le(UInt32(0x400)) + le(UInt32(2))
            + le(UInt32(0)) + le(UInt32(0)) + le(UInt32(0x8000_0400)) + le(UInt32(0)) + le(UInt32(0)) + le(UInt32(0))
            + name16("__const") + name16("__TEXT") + le(UInt64(0x1_0000_0600)) + le(UInt64(0x40)) + le(UInt32(0x600)) + le(UInt32(2))
            + le(UInt32(0)) + le(UInt32(0)) + le(UInt32(0)) + le(UInt32(0)) + le(UInt32(0)) + le(UInt32(0))
        let linkedit: [UInt8] = le(UInt32(0x19)) + le(UInt32(72)) + name16("__LINKEDIT") + le(UInt64(0x1_0000_1000)) + le(UInt64(0x1000))
            + le(UInt64(0x1000)) + le(UInt64(UInt64(syms.count + strings.count))) + le(UInt32(1)) + le(UInt32(1)) + le(UInt32(0)) + le(UInt32(0))
        let symtab: [UInt8] = le(UInt32(2)) + le(UInt32(24)) + le(UInt32(0x1000)) + le(UInt32(5)) + le(UInt32(0x1000 + syms.count)) + le(UInt32(strings.count))
        let uuidCmd: [UInt8] = le(UInt32(0x1B)) + le(UInt32(24)) + uuid
        cmds = text + linkedit + symtab + uuidCmd
        var file: [UInt8] = le(UInt32(0xFEED_FACF)) + le(UInt32(0x0100_000C)) + le(UInt32(0)) + le(UInt32(2)) + le(UInt32(4)) + le(UInt32(cmds.count))
            + le(UInt32(0)) + le(UInt32(0)) + cmds
        file += [UInt8](repeating: 0, count: 0x1000 - file.count)
        file += syms + strings
        return file
    }

    @Test func functionsFromNlist() throws {
        let table = try SymbolTable(file: ByteReader(Data(Self.make())))
        #expect(table.textAddress == 0x1_0000_0000)
        // _data is in a non-code section; ltmp0 is a local label; the N_STAB entry is skipped.
        #expect(table.functions.map(\.name) == ["main", "compute"])
        #expect(table.functions[0].size == 0x40)
        #expect(table.functions[1].size == 0xC0) // to the section's end
        #expect(table.function(containing: 0x1_0000_0450)?.name == "compute")
        #expect(table.function(containing: 0x1_0000_0500) == nil)
    }

    @Test func symbolicateByUUID() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("gauge-macho-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try Data(Self.make()).write(to: dir.appendingPathComponent("App"))
        var b = GaugeTraceBuilder(recording: .init(target: "ycode-simulator"))
        let uuid = UUID(uuid: (0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15)).uuidString
        let img = b.addImage(.init(id: 0, name: "App", uuid: uuid, kind: .app, base: 0x1_0450_0000, size: 0x2000))
        b.addSample(time: 0, thread: 1, state: .user, frames: [.init(image: img, offset: 0x404), .init(image: img, offset: 0x450)])
        var t = b.finish()
        let changed = GaugeSymbolicator.symbolicateMachO(&t, searching: [dir])
        #expect(changed == ["App"])
        #expect(t.images[0].symbols.map(\.name) == ["main", "compute"])
        #expect(CallTree(trace: t).root.children.first?.children.first?.name == "compute")
    }
}
