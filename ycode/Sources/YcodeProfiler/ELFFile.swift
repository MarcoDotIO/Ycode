import Foundation

/// The parts of a 64-bit little-endian ELF file a profiler needs
/// (`specs/ide/profiler.md` §3.2): loadable segments, function symbols
/// (`.symtab`, else `.dynsym`), the GNU build id, and the DWARF line
/// sections.
public struct ELFFile: Sendable {
    public struct Segment: Sendable, Equatable {
        public var offset: UInt64
        public var vaddr: UInt64
        public var fileSize: UInt64
        public var memorySize: UInt64
        public var executable: Bool
    }

    public struct Section: Sendable, Equatable {
        public var name: String
        public var type: UInt32
        public var flags: UInt64
        public var address: UInt64
        public var offset: UInt64
        public var size: UInt64
        public var link: UInt32
        public var entrySize: UInt64
    }

    public struct Failure: Error, CustomStringConvertible {
        public var description: String
    }

    public let type: UInt16
    public let machine: UInt16
    public let segments: [Segment]
    public let sections: [Section]
    /// Function symbols (STT_FUNC with a value), sorted by address; sizes
    /// from the symbol, else up to the next symbol.
    public let functions: [(address: UInt64, size: UInt64, name: String)]
    /// The GNU build id as hex, when present.
    public let buildID: String?
    let bytes: [UInt8]

    public init(contentsOf url: URL) throws {
        try self.init(bytes: [UInt8](Data(contentsOf: url, options: .alwaysMapped)))
    }

    public init(bytes: [UInt8]) throws {
        self.bytes = bytes
        guard bytes.count >= 64, bytes[0] == 0x7F, bytes[1] == 0x45, bytes[2] == 0x4C, bytes[3] == 0x46 else {
            throw Failure(description: "not an ELF file")
        }
        guard bytes[4] == 2, bytes[5] == 1 else { throw Failure(description: "only 64-bit little-endian ELF files are read") }
        var c = ByteCursor(bytes, at: 16)
        type = try c.u16()
        machine = try c.u16()
        _ = try c.u32()
        _ = try c.u64() // entry
        let phoff = Int(try c.u64())
        let shoff = Int(try c.u64())
        _ = try c.u32()
        _ = try c.u16()
        let phentsize = Int(try c.u16()), phnum = Int(try c.u16())
        let shentsize = Int(try c.u16()), shnum = Int(try c.u16()), shstrndx = Int(try c.u16())

        var segs: [Segment] = []
        for i in 0..<phnum {
            var p = ByteCursor(bytes, at: phoff + i * phentsize)
            let ptype = try p.u32(), pflags = try p.u32()
            let off = try p.u64(), vaddr = try p.u64()
            _ = try p.u64()
            let filesz = try p.u64(), memsz = try p.u64()
            if ptype == 1 { segs.append(Segment(offset: off, vaddr: vaddr, fileSize: filesz, memorySize: memsz, executable: pflags & 1 != 0)) }
        }
        segments = segs

        var raw: [(nameOffset: Int, Section)] = []
        if shoff > 0 {
            for i in 0..<shnum {
                var s = ByteCursor(bytes, at: shoff + i * shentsize)
                let name = Int(try s.u32()), stype = try s.u32(), flags = try s.u64(), addr = try s.u64()
                let off = try s.u64(), size = try s.u64(), link = try s.u32()
                _ = try s.u32()
                _ = try s.u64()
                let entsize = try s.u64()
                raw.append((name, Section(name: "", type: stype, flags: flags, address: addr, offset: off, size: size, link: link, entrySize: entsize)))
            }
        }
        var secs = raw.map(\.1)
        if shstrndx < secs.count {
            let strtab = secs[shstrndx]
            for i in secs.indices {
                secs[i].name = ByteCursor.cString(in: bytes, at: Int(strtab.offset) + raw[i].nameOffset) ?? ""
            }
        }
        sections = secs

        // Functions: .symtab (type 2) when present, else .dynsym (11).
        var fns: [(UInt64, UInt64, String)] = []
        if let symtab = secs.first(where: { $0.type == 2 }) ?? secs.first(where: { $0.type == 11 }), Int(symtab.link) < secs.count {
            let strs = secs[Int(symtab.link)]
            let n = symtab.entrySize > 0 ? Int(symtab.size / symtab.entrySize) : 0
            for i in 0..<n {
                var s = ByteCursor(bytes, at: Int(symtab.offset) + i * Int(symtab.entrySize))
                let nameOff = Int(try s.u32()), info = try s.u8()
                _ = try s.u8()
                let shndx = try s.u16(), value = try s.u64(), size = try s.u64()
                guard info & 0xF == 2, shndx != 0, value != 0,
                      let name = ByteCursor.cString(in: bytes, at: Int(strs.offset) + nameOff), !name.isEmpty else { continue }
                fns.append((value, size, name))
            }
        }
        fns.sort { $0.0 != $1.0 ? $0.0 < $1.0 : ($0.1 != $1.1 ? $0.1 > $1.1 : $0.2 < $1.2) }
        var out: [(address: UInt64, size: UInt64, name: String)] = []
        for (i, f) in fns.enumerated() {
            if let last = out.last, last.address == f.0 { continue }
            var size = f.1
            if size == 0 {
                var j = i + 1
                while j < fns.count, fns[j].0 == f.0 { j += 1 }
                size = j < fns.count ? fns[j].0 - f.0 : 16
            }
            out.append((f.0, size, f.2))
        }
        functions = out

        var bid: String?
        if let note = secs.first(where: { $0.name == ".note.gnu.build-id" }) {
            var n = ByteCursor(bytes, at: Int(note.offset))
            if let namesz = try? n.u32(), let descsz = try? n.u32(), (try? n.u32()) != nil {
                let descStart = n.pos + Int((namesz + 3) & ~3)
                if descStart + Int(descsz) <= bytes.count {
                    bid = bytes[descStart..<(descStart + Int(descsz))].map { String(format: "%02x", $0) }.joined()
                }
            }
        }
        buildID = bid
    }

    /// A section's bytes (empty when absent or compressed).
    public func sectionBytes(_ name: String) -> [UInt8] {
        guard let s = sections.first(where: { $0.name == name }), s.type != 8, s.flags & 0x800 == 0,
              Int(s.offset) + Int(s.size) <= bytes.count else { return [] }
        return Array(bytes[Int(s.offset)..<(Int(s.offset) + Int(s.size))])
    }

    /// The function containing a link-time address.
    public func function(containing address: UInt64) -> (address: UInt64, size: UInt64, name: String)? {
        var low = 0, high = functions.count
        while low < high {
            let mid = (low + high) / 2
            if functions[mid].address <= address { low = mid + 1 } else { high = mid }
        }
        guard low > 0 else { return nil }
        let f = functions[low - 1]
        return address < f.address &+ f.size ? f : nil
    }

    /// The load bias of a mapping: runtime address − link-time address, for
    /// a mapping of this file at `start` from file offset `fileOffset`.
    public func loadBias(mappingStart start: UInt64, fileOffset: UInt64) -> UInt64 {
        if type == 2 { return 0 } // ET_EXEC: fixed addresses
        let seg = segments.first { fileOffset >= ($0.offset & ~0xFFF) && fileOffset < $0.offset + max($0.fileSize, 1) } ?? segments.first
        guard let s = seg else { return start &- fileOffset }
        // runtime(start) corresponds to vaddr s.vaddr + (fileOffset − s.offset).
        return start &- (s.vaddr &+ fileOffset &- s.offset)
    }

    /// DWARF lines of the file (empty table when it has none).
    public func lineTable() -> DWARFLineTable {
        let line = sectionBytes(".debug_line")
        guard !line.isEmpty else { return DWARFLineTable() }
        return DWARFLineTable(debugLine: line, lineStrings: sectionBytes(".debug_line_str"), strings: sectionBytes(".debug_str"))
    }
}
