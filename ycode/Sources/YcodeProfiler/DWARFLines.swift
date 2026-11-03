import Foundation

/// A little-endian cursor over bytes (ELF and DWARF reading).
struct ByteCursor {
    let bytes: [UInt8]
    var pos: Int

    init(_ bytes: [UInt8], at pos: Int = 0) {
        self.bytes = bytes
        self.pos = pos
    }

    struct Overrun: Error {}

    var atEnd: Bool { pos >= bytes.count }

    mutating func u8() throws -> UInt8 {
        guard pos < bytes.count else { throw Overrun() }
        defer { pos += 1 }
        return bytes[pos]
    }

    mutating func fixed(_ n: Int) throws -> UInt64 {
        guard n >= 0, n <= 8, pos + n <= bytes.count else { throw Overrun() }
        var v: UInt64 = 0
        for i in 0..<n { v |= UInt64(bytes[pos + i]) << (8 * UInt64(i)) }
        pos += n
        return v
    }

    mutating func u16() throws -> UInt16 { UInt16(try fixed(2)) }
    mutating func u32() throws -> UInt32 { UInt32(try fixed(4)) }
    mutating func u64() throws -> UInt64 { try fixed(8) }

    mutating func uleb() throws -> UInt64 {
        var result: UInt64 = 0, shift: UInt64 = 0
        while true {
            let b = try u8()
            if shift < 64 { result |= UInt64(b & 0x7F) << shift }
            shift += 7
            if b & 0x80 == 0 { return result }
        }
    }

    mutating func sleb() throws -> Int64 {
        var result: Int64 = 0, shift: Int64 = 0
        var b: UInt8
        repeat {
            b = try u8()
            if shift < 64 { result |= Int64(b & 0x7F) << shift }
            shift += 7
        } while b & 0x80 != 0
        if shift < 64 && b & 0x40 != 0 { result |= -(Int64(1) << shift) }
        return result
    }

    mutating func cString() throws -> String {
        guard let end = bytes[pos...].firstIndex(of: 0) else { throw Overrun() }
        defer { pos = end + 1 }
        return String(decoding: bytes[pos..<end], as: UTF8.self)
    }

    mutating func skip(_ n: Int) throws {
        guard n >= 0, pos + n <= bytes.count else { throw Overrun() }
        pos += n
    }

    static func cString(in bytes: [UInt8], at offset: Int) -> String? {
        guard offset >= 0, offset < bytes.count, let end = bytes[offset...].firstIndex(of: 0) else { return nil }
        return String(decoding: bytes[offset..<end], as: UTF8.self)
    }
}

/// Address → (file, line) from DWARF line programs (`.debug_line`, DWARF
/// 2–5; `specs/ide/profiler.md` §4.3).
public struct DWARFLineTable: Sendable {
    public struct Row: Sendable, Equatable {
        public var address: UInt64
        public var file: Int
        public var line: Int
        /// The first address after a sequence (no line of its own).
        public var endSequence: Bool
    }

    /// Every unit's file paths, in one list.
    public private(set) var files: [String] = []
    /// Sorted by address.
    public private(set) var rows: [Row] = []

    public init() {}

    /// Parses `.debug_line`; `lineStrings` is `.debug_line_str`, `strings`
    /// `.debug_str` (DWARF 5 path forms). A unit that cannot be read ends
    /// the parse (units read before it are kept).
    public init(debugLine: [UInt8], lineStrings: [UInt8] = [], strings: [UInt8] = []) {
        var c = ByteCursor(debugLine)
        var all: [Row] = []
        while !c.atEnd {
            let unitStart = c.pos
            guard let (unitEnd, next) = try? Self.parseUnit(&c, lineStrings: lineStrings, strings: strings, files: &files, rows: &all),
                  next > unitStart else { break }
            _ = unitEnd
            c.pos = next
        }
        // By address; at one address non-end rows before end rows, and in
        // program order (the later row wins a lookup).
        rows = all.enumerated().sorted { a, b in
            if a.element.address != b.element.address { return a.element.address < b.element.address }
            if a.element.endSequence != b.element.endSequence { return !a.element.endSequence }
            return a.offset < b.offset
        }.map(\.element)
    }

    /// The line of an address: the row with the largest address ≤ it, unless
    /// that row ends a sequence.
    public func lookup(_ address: UInt64) -> (file: String, line: Int)? {
        var low = 0, high = rows.count
        while low < high {
            let mid = (low + high) / 2
            if rows[mid].address <= address { low = mid + 1 } else { high = mid }
        }
        // Among rows at the same address prefer a non-end row.
        var i = low - 1
        while i > 0, rows[i].endSequence, rows[i - 1].address == rows[i].address { i -= 1 }
        guard i >= 0, !rows[i].endSequence, rows[i].line > 0, files.indices.contains(rows[i].file) else { return nil }
        return (files[rows[i].file], rows[i].line)
    }

    static let formString: UInt64 = 0x08, formLineStrp: UInt64 = 0x1F, formStrp: UInt64 = 0x0E, formUdata: UInt64 = 0x0F
    static let formData1: UInt64 = 0x0B, formData2: UInt64 = 0x05, formData4: UInt64 = 0x06, formData8: UInt64 = 0x07
    static let formData16: UInt64 = 0x1E, formBlock: UInt64 = 0x09, formSdata: UInt64 = 0x0D

    /// Returns (end of header, next unit offset).
    static func parseUnit(_ c: inout ByteCursor, lineStrings: [UInt8], strings: [UInt8],
                          files: inout [String], rows: inout [Row]) throws -> (Int, Int) {
        var length = UInt64(try c.u32())
        var offsetSize = 4
        if length == 0xFFFF_FFFF {
            length = try c.u64()
            offsetSize = 8
        }
        let end = c.pos + Int(length)
        guard end <= c.bytes.count, length > 0 else { throw ByteCursor.Overrun() }
        let version = Int(try c.u16())
        guard (2...5).contains(version) else { return (end, end) }
        var addressSize = 8
        if version >= 5 {
            addressSize = Int(try c.u8())
            _ = try c.u8() // segment selector size
        }
        let headerLength = Int(try c.fixed(offsetSize))
        let programStart = c.pos + headerLength
        let minInst = UInt64(try c.u8())
        let maxOps = version >= 4 ? Int(try c.u8()) : 1
        _ = maxOps
        let defaultIsStmt = try c.u8() != 0
        _ = defaultIsStmt
        let lineBase = Int(Int8(bitPattern: try c.u8()))
        let lineRange = Int(try c.u8())
        let opcodeBase = Int(try c.u8())
        guard lineRange > 0, opcodeBase >= 1 else { return (end, end) }
        var standardLengths: [Int] = [0]
        for _ in 1..<opcodeBase { standardLengths.append(Int(try c.u8())) }

        // Directories and files; `fileBase` maps the unit's file numbers to `files`.
        var dirs: [String] = []
        var unitFiles: [String] = []
        func join(_ dir: String, _ name: String) -> String {
            if name.hasPrefix("/") || dir.isEmpty { return name }
            return dir.hasSuffix("/") ? dir + name : dir + "/" + name
        }
        if version >= 5 {
            func readEntries() throws -> [[UInt64: Any]] {
                let formatCount = Int(try c.u8())
                var formats: [(UInt64, UInt64)] = []
                for _ in 0..<formatCount { formats.append((try c.uleb(), try c.uleb())) }
                let count = Int(try c.uleb())
                var out: [[UInt64: Any]] = []
                for _ in 0..<count {
                    var entry: [UInt64: Any] = [:]
                    for (content, form) in formats {
                        switch form {
                        case formString: entry[content] = try c.cString()
                        case formLineStrp: entry[content] = ByteCursor.cString(in: lineStrings, at: Int(try c.fixed(offsetSize))) ?? ""
                        case formStrp: entry[content] = ByteCursor.cString(in: strings, at: Int(try c.fixed(offsetSize))) ?? ""
                        case formUdata: entry[content] = try c.uleb()
                        case formSdata: entry[content] = try c.sleb()
                        case formData1: entry[content] = try c.fixed(1)
                        case formData2: entry[content] = try c.fixed(2)
                        case formData4: entry[content] = try c.fixed(4)
                        case formData8: entry[content] = try c.fixed(8)
                        case formData16: try c.skip(16)
                        case formBlock: try c.skip(Int(try c.uleb()))
                        default: throw ByteCursor.Overrun()
                        }
                    }
                    out.append(entry)
                }
                return out
            }
            dirs = try readEntries().map { $0[1] as? String ?? "" }
            // Directories other than 0 are relative to the compilation directory (entry 0).
            if let base = dirs.first, !base.isEmpty {
                for i in dirs.indices.dropFirst() where !dirs[i].hasPrefix("/") { dirs[i] = join(base, dirs[i]) }
            }
            for f in try readEntries() {
                let name = f[1] as? String ?? ""
                let d = Int((f[2] as? UInt64) ?? 0)
                unitFiles.append(join(dirs.indices.contains(d) ? dirs[d] : "", name))
            }
        } else {
            dirs = [""]
            while true {
                let d = try c.cString()
                if d.isEmpty { break }
                dirs.append(d)
            }
            unitFiles = [""] // file numbers start at 1
            while true {
                let name = try c.cString()
                if name.isEmpty { break }
                let d = Int(try c.uleb())
                _ = try c.uleb()
                _ = try c.uleb()
                unitFiles.append(join(dirs.indices.contains(d) ? dirs[d] : "", name))
            }
        }
        let fileBase = files.count
        files += unitFiles

        c.pos = programStart
        var address: UInt64 = 0, file = version >= 5 ? 0 : 1, line = 1
        func emit(_ endSequence: Bool) {
            rows.append(Row(address: address, file: fileBase + max(0, min(file, unitFiles.count - 1)), line: line, endSequence: endSequence))
        }
        while c.pos < end {
            let op = Int(try c.u8())
            if op >= opcodeBase {
                let adjusted = op - opcodeBase
                address &+= minInst * UInt64(adjusted / lineRange)
                line += lineBase + adjusted % lineRange
                emit(false)
                continue
            }
            switch op {
            case 0:
                let len = Int(try c.uleb())
                let start = c.pos
                guard len > 0 else { continue }
                let sub = try c.u8()
                switch sub {
                case 1:
                    emit(true)
                    address = 0
                    file = version >= 5 ? 0 : 1
                    line = 1
                case 2: address = try c.fixed(len > 1 ? min(8, len - 1) : addressSize)
                case 3:
                    // DW_LNE_define_file (DWARF 2–4).
                    let name = try c.cString()
                    let d = Int(try c.uleb())
                    unitFiles.append(join(dirs.indices.contains(d) ? dirs[d] : "", name))
                    files.append(unitFiles.last ?? "")
                default: break
                }
                c.pos = start + len
            case 1: emit(false)
            case 2: address &+= minInst * (try c.uleb())
            case 3: line += Int(try c.sleb())
            case 4: file = Int(try c.uleb())
            case 5: _ = try c.uleb()
            case 6, 7, 10, 11: break
            case 8: address &+= minInst * UInt64((255 - opcodeBase) / lineRange)
            case 9: address &+= UInt64(try c.u16())
            case 12: _ = try c.uleb()
            default:
                for _ in 0..<(op < standardLengths.count ? standardLengths[op] : 0) { _ = try c.uleb() }
            }
        }
        return (programStart, end)
    }
}
