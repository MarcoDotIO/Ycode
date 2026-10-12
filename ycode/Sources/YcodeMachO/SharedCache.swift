import Foundation

/// A dyld shared cache: a main file plus its subcache files, viewed as one
/// virtual address space. See `specs/formats/macho-and-dyld-cache.md` §3.
public struct SharedCache: Sendable {
    public struct Mapping: Sendable, Equatable {
        public var address: UInt64
        public var size: UInt64
        public var fileOffset: UInt64
        public var maxProtection: Protection
        public var initialProtection: Protection
        /// Flags from the extended table, when present.
        public var flags: UInt64

        public func contains(_ a: UInt64) -> Bool { a >= address && a - address < size }

        public static func == (a: Mapping, b: Mapping) -> Bool {
            a.address == b.address && a.size == b.size && a.fileOffset == b.fileOffset && a.flags == b.flags
        }
    }

    /// One cache file (main or subcache).
    public struct File: Sendable {
        public var url: URL
        public var reader: ByteReader
        public var uuid: UUID
        public var mappings: [Mapping]
    }

    public struct Image: Sendable, Equatable {
        public var path: String
        public var address: UInt64
    }

    public let architecture: String
    public let platformRaw: UInt32
    public let isSimulator: Bool
    public let formatVersion: Int
    public let cacheType: UInt64
    public let osVersion: PackedVersion?
    public let sharedRegionStart: UInt64
    public let sharedRegionSize: UInt64
    public let files: [File]
    public let images: [Image]

    public var platform: Platform? { Platform(rawValue: platformRaw) }
    public var mainFile: File { files[0] }

    public init(contentsOf url: URL) throws {
        let main = try ByteReader(contentsOf: url)
        let header = try Header(main)
        architecture = header.architecture
        platformRaw = header.platform
        isSimulator = header.flags & (1 << 9) != 0
        formatVersion = Int(header.flags & 0xFF)
        cacheType = header.cacheType
        osVersion = header.osVersion.map(PackedVersion.init)
        sharedRegionStart = header.sharedRegionStart
        sharedRegionSize = header.sharedRegionSize

        var files = [File(url: url, reader: main, uuid: header.uuid, mappings: try header.mappings(main))]
        for (i, entry) in try header.subcaches(main).enumerated() {
            let suffix = entry.suffix ?? ".\(i + 1)"
            let subURL = URL(fileURLWithPath: url.path + suffix)
            let r = try ByteReader(contentsOf: subURL)
            let h = try Header(r)
            guard h.uuid == entry.uuid else {
                throw MachOError("subcache \(subURL.lastPathComponent) UUID does not match its main cache")
            }
            files.append(File(url: subURL, reader: r, uuid: h.uuid, mappings: try h.mappings(r)))
        }
        self.files = files

        var images: [Image] = []
        let (imagesOffset, imagesCount) = header.imageTable
        for i in 0..<imagesCount {
            let e = imagesOffset + i * 32
            let address = try main.u64(e)
            let pathOffset = Int(try main.u32(e + 24))
            images.append(Image(path: try main.string(pathOffset, limit: 1024), address: address))
        }
        self.images = images
    }

    /// The file and file offset that back a cache VM address.
    public func locate(_ address: UInt64) -> (file: File, offset: Int)? {
        for f in files {
            if let m = f.mappings.first(where: { $0.contains(address) }) {
                return (f, Int(m.fileOffset + (address - m.address)))
            }
        }
        return nil
    }

    /// Parses the Mach-O header of a cached image. Offsets inside cached
    /// images are VM-relative, so only the header and load commands are read.
    public func machO(for image: Image) throws(MachOError) -> MachOImage {
        guard let (file, offset) = locate(image.address) else {
            throw MachOError("image \(image.path) at \(hex(image.address)) is outside every mapping")
        }
        return try MachOImage(file.reader, at: offset)
    }

    public func image(path: String) -> Image? { images.first { $0.path == path } }

    // MARK: - Header

    struct Header {
        let reader: ByteReader
        let mappingOffset: Int

        init(_ r: ByteReader) throws(MachOError) {
            reader = r
            let magic = try r.string(0, limit: 16)
            guard magic.hasPrefix("dyld_v1") else { throw MachOError("not a dyld shared cache (magic \(magic.debugDescription))") }
            mappingOffset = Int(try r.u32(0x10))
            guard mappingOffset >= 0x20 else { throw MachOError("header too small") }
        }

        /// A header field exists only if it lies before the mapping table.
        func has(_ offset: Int, _ size: Int) -> Bool { offset + size <= mappingOffset }

        var architecture: String {
            ((try? reader.string(0, limit: 16)) ?? "").dropFirst("dyld_v1".count).trimmingCharacters(in: .whitespaces)
        }
        var uuid: UUID { has(0x58, 16) ? ((try? reader.uuid(0x58)) ?? UUID(uuid: (0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0))) : UUID(uuid: (0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0)) }
        var cacheType: UInt64 { has(0x68, 8) ? ((try? reader.u64(0x68)) ?? 0) : 0 }
        var platform: UInt32 { has(0xD8, 4) ? ((try? reader.u32(0xD8)) ?? 0) : 0 }
        var flags: UInt32 { has(0xDC, 4) ? ((try? reader.u32(0xDC)) ?? 0) : 0 }
        var sharedRegionStart: UInt64 { has(0xE0, 8) ? ((try? reader.u64(0xE0)) ?? 0) : 0 }
        var sharedRegionSize: UInt64 { has(0xE8, 8) ? ((try? reader.u64(0xE8)) ?? 0) : 0 }
        var osVersion: UInt32? { has(0x16C, 4) ? try? reader.u32(0x16C) : nil }

        var imageTable: (offset: Int, count: Int) {
            if has(0x1C4, 4), let off = try? reader.u32(0x1C0), let n = try? reader.u32(0x1C4), off != 0 {
                return (Int(off), Int(n))
            }
            return (Int((try? reader.u32(0x18)) ?? 0), Int((try? reader.u32(0x1C)) ?? 0))
        }

        func mappings(_ r: ByteReader) throws(MachOError) -> [Mapping] {
            if has(0x13C, 4), case let off = Int(try r.u32(0x138)), case let n = Int(try r.u32(0x13C)), off != 0, n > 0 {
                return try (0..<n).map { (i) throws(MachOError) -> Mapping in
                    let e = off + i * 56
                    return Mapping(address: try r.u64(e), size: try r.u64(e + 8), fileOffset: try r.u64(e + 16),
                                   maxProtection: Protection(rawValue: try r.u32(e + 48)),
                                   initialProtection: Protection(rawValue: try r.u32(e + 52)), flags: try r.u64(e + 40))
                }
            }
            let n = Int(try r.u32(0x14))
            return try (0..<n).map { (i) throws(MachOError) -> Mapping in
                let e = mappingOffset + i * 32
                return Mapping(address: try r.u64(e), size: try r.u64(e + 8), fileOffset: try r.u64(e + 16),
                               maxProtection: Protection(rawValue: try r.u32(e + 24)),
                               initialProtection: Protection(rawValue: try r.u32(e + 28)), flags: 0)
            }
        }

        func subcaches(_ r: ByteReader) throws(MachOError) -> [(uuid: UUID, suffix: String?)] {
            guard has(0x18C, 4) else { return [] }
            let off = Int(try r.u32(0x188)), n = Int(try r.u32(0x18C))
            guard off != 0, n > 0 else { return [] }
            let withSuffix = has(0x1C8, 4)
            return try (0..<n).map { (i) throws(MachOError) -> (uuid: UUID, suffix: String?) in
                let e = off + i * (withSuffix ? 56 : 24)
                return (try r.uuid(e), withSuffix ? try r.string(e + 24, limit: 32) : nil)
            }
        }
    }
}
