/// A USDZ package: an uncompressed ZIP archive whose first entry is the
/// root layer and whose entry data start on 64-byte boundaries (OpenUSD's
/// USDZ specification). Only stored (method 0) entries are read or written;
/// archives larger than 4 GiB (ZIP64) are not supported.
public struct USDZArchive: Sendable, Equatable {
    public struct Entry: Sendable, Equatable {
        public var name: String
        public var data: [UInt8]

        public init(name: String, data: [UInt8]) {
            self.name = name
            self.data = data
        }
    }

    public var entries: [Entry]

    public init(entries: [Entry] = []) { self.entries = entries }

    static let layerExtensions: Set<String> = ["usda", "usdc", "usd"]

    /// The root layer: the first entry, which must be a USD layer.
    public var rootLayer: Entry? {
        guard let first = entries.first, USDZArchive.layerExtensions.contains(first.name.fileExtension) else { return nil }
        return first
    }

    public func entry(named name: String) -> Entry? { entries.first { $0.name == name } }

    // MARK: Reading

    public static func read(_ bytes: [UInt8]) throws -> USDZArchive {
        var c = ByteCursor(bytes)
        // End of central directory: search backwards for its signature.
        var eocd = -1
        var i = bytes.count - 22
        while i >= max(0, bytes.count - 22 - 0xFFFF) {
            if bytes[i] == 0x50, bytes[i + 1] == 0x4B, bytes[i + 2] == 0x05, bytes[i + 3] == 0x06 {
                eocd = i
                break
            }
            i -= 1
        }
        guard eocd >= 0 else { throw USDError("usdz: no ZIP end-of-central-directory record") }
        c.pos = eocd + 10
        let count = Int(try c.uint(2))
        _ = try c.u32() // directory size
        let directoryOffset = Int(try c.u32())
        guard directoryOffset != 0xFFFF_FFFF else { throw USDError("usdz: ZIP64 archives are not supported") }
        c.pos = directoryOffset
        var entries: [Entry] = []
        for _ in 0..<count {
            guard try c.u32() == 0x0201_4B50 else { throw USDError("usdz: bad central directory entry") }
            c.pos += 6 // versions, flags
            let method = try c.uint(2)
            c.pos += 4 // time, date
            let crc = try c.u32()
            let compressedSize = Int(try c.u32())
            let size = Int(try c.u32())
            let nameLength = Int(try c.uint(2))
            let extraLength = Int(try c.uint(2))
            let commentLength = Int(try c.uint(2))
            c.pos += 8 // disk, attributes
            let localOffset = Int(try c.u32())
            let name = String(decoding: try c.slice(nameLength), as: UTF8.self)
            c.pos += extraLength + commentLength
            guard method == 0, compressedSize == size else {
                throw USDError("usdz: entry \(name) is compressed; USDZ entries must be stored")
            }
            var local = ByteCursor(bytes, at: localOffset)
            guard try local.u32() == 0x0403_4B50 else { throw USDError("usdz: bad local header for \(name)") }
            local.pos = localOffset + 26
            let localNameLength = Int(try local.uint(2))
            let localExtraLength = Int(try local.uint(2))
            local.pos += localNameLength + localExtraLength
            let data = Array(try local.slice(size))
            guard CRC32.checksum(data) == crc else { throw USDError("usdz: CRC mismatch in \(name)") }
            entries.append(Entry(name: name, data: data))
        }
        return USDZArchive(entries: entries)
    }

    // MARK: Writing

    /// Writes the archive with each entry's data aligned to 64 bytes.
    public func write() -> [UInt8] {
        var out: [UInt8] = []
        var central: [UInt8] = []
        func put16(_ v: Int, _ buffer: inout [UInt8]) {
            buffer.append(UInt8(v & 0xFF))
            buffer.append(UInt8((v >> 8) & 0xFF))
        }
        func put32(_ v: UInt32, _ buffer: inout [UInt8]) {
            for k in 0..<4 { buffer.append(UInt8(truncatingIfNeeded: v >> (8 * UInt32(k)))) }
        }
        // 1980-01-01 00:00 in DOS format keeps output reproducible.
        let dosTime = 0
        let dosDate = (0 << 9) | (1 << 5) | 1
        for entry in entries {
            let name = Array(entry.name.utf8)
            let crc = CRC32.checksum(entry.data)
            let headerOffset = out.count
            let headerSize = 30 + name.count
            var extra: [UInt8] = []
            let unaligned = (headerOffset + headerSize) % 64
            if unaligned != 0 {
                var padding = 64 - unaligned
                if padding < 4 { padding += 64 }
                // Extra field: id 0x1986 (the padding id used by usdzip), then zeros.
                put16(0x1986, &extra)
                put16(padding - 4, &extra)
                extra += [UInt8](repeating: 0, count: padding - 4)
            }
            put32(0x0403_4B50, &out)
            put16(20, &out)
            put16(0, &out)
            put16(0, &out)
            put16(dosTime, &out)
            put16(dosDate, &out)
            put32(crc, &out)
            put32(UInt32(entry.data.count), &out)
            put32(UInt32(entry.data.count), &out)
            put16(name.count, &out)
            put16(extra.count, &out)
            out += name
            out += extra
            out += entry.data

            put32(0x0201_4B50, &central)
            put16(20, &central)
            put16(20, &central)
            put16(0, &central)
            put16(0, &central)
            put16(dosTime, &central)
            put16(dosDate, &central)
            put32(crc, &central)
            put32(UInt32(entry.data.count), &central)
            put32(UInt32(entry.data.count), &central)
            put16(name.count, &central)
            put16(0, &central)
            put16(0, &central)
            put16(0, &central)
            put16(0, &central)
            put32(0, &central)
            put32(UInt32(headerOffset), &central)
            central += name
        }
        let directoryOffset = out.count
        out += central
        put32(0x0605_4B50, &out)
        put16(0, &out)
        put16(0, &out)
        put16(entries.count, &out)
        put16(entries.count, &out)
        put32(UInt32(central.count), &out)
        put32(UInt32(directoryOffset), &out)
        put16(0, &out)
        return out
    }

    /// Offsets of each entry's data in a written archive (for checks).
    public static func dataOffsets(_ bytes: [UInt8]) throws -> [String: Int] {
        var result: [String: Int] = [:]
        var c = ByteCursor(bytes)
        while c.pos + 30 <= bytes.count, try c.u32() == 0x0403_4B50 {
            let start = c.pos - 4
            c.pos = start + 18
            let size = Int(try c.u32())
            c.pos += 4
            let nameLength = Int(try c.uint(2))
            let extraLength = Int(try c.uint(2))
            let name = String(decoding: try c.slice(nameLength), as: UTF8.self)
            c.pos += extraLength
            result[name] = c.pos
            c.pos += size
        }
        return result
    }
}

/// CRC-32 (IEEE 802.3, as ZIP uses).
public enum CRC32 {
    static let table: [UInt32] = (0..<256).map { n in
        var c = UInt32(n)
        for _ in 0..<8 { c = c & 1 != 0 ? 0xEDB8_8320 ^ (c >> 1) : c >> 1 }
        return c
    }

    public static func checksum(_ data: [UInt8]) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        for b in data { crc = table[Int((crc ^ UInt32(b)) & 0xFF)] ^ (crc >> 8) }
        return crc ^ 0xFFFF_FFFF
    }
}

extension String {
    /// The lowercase extension after the last `.` of the last path component.
    var fileExtension: String {
        let last = split(separator: "/").last.map(String.init) ?? self
        guard let dot = last.lastIndex(of: ".") else { return "" }
        return String(last[last.index(after: dot)...]).lowercased()
    }
}
