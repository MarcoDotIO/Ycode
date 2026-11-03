import Foundation

/// The functions of a Mach-O image from its `LC_SYMTAB` (`nlist_64`
/// entries; `specs/ide/profiler.md` §4.2): defined section symbols in
/// executable sections, sorted by address, each ending where the next
/// begins (or at its section's end).
public struct SymbolTable: Sendable {
    public struct Function: Sendable, Equatable {
        /// Link-time VM address.
        public var address: UInt64
        public var size: UInt64
        public var name: String
        public init(address: UInt64, size: UInt64, name: String) {
            self.address = address
            self.size = size
            self.name = name
        }
    }

    public let functions: [Function]
    /// The image's `__TEXT` VM address (link-time; the mach header's address).
    public let textAddress: UInt64

    public init(functions: [Function], textAddress: UInt64) {
        self.functions = functions
        self.textAddress = textAddress
    }

    /// The function containing a link-time VM address.
    public func function(containing address: UInt64) -> Function? {
        var low = 0, high = functions.count
        while low < high {
            let mid = (low + high) / 2
            if functions[mid].address <= address { low = mid + 1 } else { high = mid }
        }
        guard low > 0 else { return nil }
        let f = functions[low - 1]
        return address < f.address &+ f.size ? f : nil
    }

    // MARK: Reading

    static let nStab: UInt8 = 0xE0, nType: UInt8 = 0x0E, nSect: UInt8 = 0x0E
    /// S_ATTR_PURE_INSTRUCTIONS | S_ATTR_SOME_INSTRUCTIONS.
    static let instructionAttributes: UInt32 = 0x8000_0000 | 0x0000_0400

    /// The symbol table of a Mach-O file (thin, or the slice at `offset`).
    public init(file reader: ByteReader, at offset: Int = 0) throws(MachOError) {
        let image = try MachOImage(reader, at: offset)
        try self.init(image: image) { (linkeditOffset: UInt64, _: Int) throws(MachOError) -> (ByteReader, Int) in
            (reader, offset + Int(linkeditOffset))
        }
    }

    /// The symbol table of an image inside a shared cache: its `__LINKEDIT`
    /// offsets are turned into VM addresses
    /// (`linkedit.vmaddr + offset − linkedit.fileoff`) and located in the
    /// cache's files.
    public init(cache: SharedCache, image: SharedCache.Image) throws(MachOError) {
        let macho = try cache.machO(for: image)
        guard let linkedit = macho.segment(named: "__LINKEDIT") else { throw MachOError("\(image.path): no __LINKEDIT") }
        try self.init(image: macho) { (linkeditOffset: UInt64, _: Int) throws(MachOError) -> (ByteReader, Int) in
            let address = linkedit.vmAddress &+ linkeditOffset &- linkedit.fileOffset
            guard let (file, off) = cache.locate(address) else {
                throw MachOError("\(image.path): symbol table at \(hex(address)) is outside the cache's mappings")
            }
            return (file.reader, off)
        }
    }

    /// `locate(offset, byteCount)` gives the reader and position of a
    /// `__LINKEDIT` file offset.
    init(image: MachOImage, locate: (UInt64, Int) throws(MachOError) -> (ByteReader, Int)) throws(MachOError) {
        textAddress = image.segment(named: "__TEXT")?.vmAddress ?? 0
        guard let st = image.symtab, st.symbolCount > 0 else {
            functions = []
            return
        }
        // Executable sections, numbered from 1 in load-command order.
        var sections: [(start: UInt64, end: UInt64, code: Bool)] = []
        for seg in image.segments {
            for s in seg.sections {
                let code = s.flags & Self.instructionAttributes != 0 || (s.segment == "__TEXT" && s.name == "__text")
                sections.append((s.address, s.address &+ s.size, code))
            }
        }
        let (symReader, symPos) = try locate(UInt64(st.symbolOffset), Int(st.symbolCount) * 16)
        let (strReader, strPos) = try locate(UInt64(st.stringOffset), Int(st.stringSize))
        try symReader.check(symPos, Int(st.symbolCount) * 16)
        var raw: [(UInt64, String)] = []
        raw.reserveCapacity(Int(st.symbolCount))
        for i in 0..<Int(st.symbolCount) {
            let e = symPos + i * 16
            let type = try symReader.u8(e + 4)
            guard type & Self.nStab == 0, type & Self.nType == Self.nSect else { continue }
            let sect = Int(try symReader.u8(e + 5))
            guard sect >= 1, sect <= sections.count, sections[sect - 1].code else { continue }
            let strx = Int(try symReader.u32(e))
            guard strx > 0, strx < Int(st.stringSize) else { continue }
            let value = try symReader.u64(e + 8)
            var name = try strReader.string(strPos + strx, limit: Int(st.stringSize) - strx)
            if name.hasPrefix("_") { name.removeFirst() }
            guard !name.isEmpty, !name.hasPrefix("ltmp"), !name.hasPrefix("l_"), !name.hasPrefix("Ltmp") else { continue }
            raw.append((value, name))
        }
        raw.sort { $0.0 != $1.0 ? $0.0 < $1.0 : $0.1 < $1.1 }
        var out: [Function] = []
        out.reserveCapacity(raw.count)
        for (i, (address, name)) in raw.enumerated() {
            if let last = out.last, last.address == address { continue } // aliases: keep the first name
            var next = i + 1
            while next < raw.count, raw[next].0 == address { next += 1 }
            let sectionEnd = sections.first { $0.start <= address && address < $0.end }?.end ?? address &+ 4
            let end = next < raw.count ? min(raw[next].0, sectionEnd) : sectionEnd
            out.append(Function(address: address, size: end &- address, name: name))
        }
        functions = out
    }
}
