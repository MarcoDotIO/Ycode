import Foundation

/// A parsed 64-bit Mach-O image. See `specs/formats/macho-and-dyld-cache.md` §2.
public struct MachOImage: Sendable {
    public enum FileType: UInt32, Sendable {
        case object = 1, executable = 2, dylib = 6, dylinker = 7, bundle = 8, dsym = 0xB, kextBundle = 0xC
    }

    public struct Section: Sendable, Equatable {
        public var name: String
        public var segment: String
        public var address: UInt64
        public var size: UInt64
        public var fileOffset: UInt32
        public var flags: UInt32
    }

    public struct Segment: Sendable, Equatable {
        public var name: String
        public var vmAddress: UInt64
        public var vmSize: UInt64
        public var fileOffset: UInt64
        public var fileSize: UInt64
        public var maxProtection: Protection
        public var initialProtection: Protection
        public var sections: [Section]

        public static func == (a: Segment, b: Segment) -> Bool {
            a.name == b.name && a.vmAddress == b.vmAddress && a.vmSize == b.vmSize && a.fileOffset == b.fileOffset
                && a.fileSize == b.fileSize && a.sections == b.sections
                && a.maxProtection.rawValue == b.maxProtection.rawValue && a.initialProtection.rawValue == b.initialProtection.rawValue
        }
    }

    public struct DylibReference: Sendable, Equatable {
        public enum Kind: String, Sendable { case normal, weak, reexport, upward, lazy }
        public var path: String
        public var kind: Kind
        public var currentVersion: PackedVersion
        public var compatibilityVersion: PackedVersion
    }

    public struct BuildVersion: Sendable, Equatable {
        public var platformRaw: UInt32
        public var minOS: PackedVersion
        public var sdk: PackedVersion
        public var platform: Platform? { Platform(rawValue: platformRaw) }
    }

    /// A `__LINKEDIT` blob referenced by a load command (code signature, fixups, …).
    public struct LinkEditData: Sendable, Equatable {
        public var offset: UInt32
        public var size: UInt32
    }

    public var cpuType: UInt32
    public var cpuSubtype: UInt32
    public var fileTypeRaw: UInt32
    public var flags: UInt32
    public var segments: [Segment] = []
    public var dylibs: [DylibReference] = []
    public var installName: String?
    public var dylinker: String?
    public var uuid: UUID?
    public var buildVersion: BuildVersion?
    /// Entry point offset from the start of `__TEXT` (LC_MAIN).
    public var entryOffset: UInt64?
    public var rpaths: [String] = []
    public var codeSignature: LinkEditData?
    public var chainedFixups: LinkEditData?
    public var exportsTrie: LinkEditData?
    /// Nonzero `cryptid` in LC_ENCRYPTION_INFO_64. Ycode never decrypts.
    public var isEncrypted = false
    /// Load commands Ycode does not interpret, by command number.
    public var otherCommands: [UInt32] = []

    public var fileType: FileType? { FileType(rawValue: fileTypeRaw) }
    public var isArm64: Bool { cpuType == MachO.cpuTypeARM64 }

    /// Parses the image whose header starts at `offset` in `reader`.
    public init(_ reader: ByteReader, at offset: Int = 0) throws(MachOError) {
        let magic = try reader.u32(offset)
        guard magic == MachO.magic64 else {
            throw MachOError("not a 64-bit Mach-O (magic \(hex(magic)))")
        }
        cpuType = try reader.u32(offset + 4)
        cpuSubtype = try reader.u32(offset + 8)
        fileTypeRaw = try reader.u32(offset + 12)
        let ncmds = Int(try reader.u32(offset + 16))
        let sizeofcmds = Int(try reader.u32(offset + 20))
        flags = try reader.u32(offset + 24)

        var p = offset + 32
        let end = p + sizeofcmds
        try reader.check(p, sizeofcmds)
        for _ in 0..<ncmds {
            guard p + 8 <= end else { throw MachOError("load commands overrun sizeofcmds") }
            let cmd = try reader.u32(p)
            let size = Int(try reader.u32(p + 4))
            guard size >= 8, p + size <= end else { throw MachOError("bad cmdsize \(size) for command \(hex(cmd))") }
            try parseCommand(cmd, at: p, size: size, reader)
            p += size
        }
    }

    private mutating func parseCommand(_ cmd: UInt32, at p: Int, size: Int, _ r: ByteReader) throws(MachOError) {
        func lcString(_ field: Int) throws(MachOError) -> String {
            let off = Int(try r.u32(p + field))
            guard off < size else { throw MachOError("string offset outside its load command") }
            return try r.string(p + off, limit: size - off)
        }
        func linkEdit() throws(MachOError) -> LinkEditData {
            LinkEditData(offset: try r.u32(p + 8), size: try r.u32(p + 12))
        }
        switch cmd {
        case MachO.lcSegment64:
            let nsects = Int(try r.u32(p + 64))
            guard 72 + nsects * 80 <= size else { throw MachOError("segment sections overrun cmdsize") }
            var sections: [Section] = []
            for i in 0..<nsects {
                let s = p + 72 + i * 80
                sections.append(Section(
                    name: try r.string(s, limit: 16), segment: try r.string(s + 16, limit: 16),
                    address: try r.u64(s + 32), size: try r.u64(s + 40),
                    fileOffset: try r.u32(s + 48), flags: try r.u32(s + 64)))
            }
            segments.append(Segment(
                name: try r.string(p + 8, limit: 16),
                vmAddress: try r.u64(p + 24), vmSize: try r.u64(p + 32),
                fileOffset: try r.u64(p + 40), fileSize: try r.u64(p + 48),
                maxProtection: Protection(rawValue: try r.u32(p + 56)),
                initialProtection: Protection(rawValue: try r.u32(p + 60)),
                sections: sections))
        case MachO.lcLoadDylib, MachO.lcLoadWeakDylib, MachO.lcReexportDylib, MachO.lcLoadUpwardDylib, MachO.lcLazyLoadDylib:
            let kind: DylibReference.Kind = switch cmd {
            case MachO.lcLoadWeakDylib: .weak
            case MachO.lcReexportDylib: .reexport
            case MachO.lcLoadUpwardDylib: .upward
            case MachO.lcLazyLoadDylib: .lazy
            default: .normal
            }
            dylibs.append(DylibReference(
                path: try lcString(8), kind: kind,
                currentVersion: PackedVersion(try r.u32(p + 16)),
                compatibilityVersion: PackedVersion(try r.u32(p + 20))))
        case MachO.lcIDDylib:
            installName = try lcString(8)
        case MachO.lcLoadDylinker:
            dylinker = try lcString(8)
        case MachO.lcUUID:
            uuid = try r.uuid(p + 8)
        case MachO.lcBuildVersion:
            buildVersion = BuildVersion(platformRaw: try r.u32(p + 8), minOS: PackedVersion(try r.u32(p + 12)), sdk: PackedVersion(try r.u32(p + 16)))
        case MachO.lcMain:
            entryOffset = try r.u64(p + 8)
        case MachO.lcRpath:
            rpaths.append(try lcString(8))
        case MachO.lcCodeSignature:
            codeSignature = try linkEdit()
        case MachO.lcDyldChainedFixups:
            chainedFixups = try linkEdit()
        case MachO.lcDyldExportsTrie:
            exportsTrie = try linkEdit()
        case MachO.lcEncryptionInfo64:
            isEncrypted = try r.u32(p + 16) != 0
        default:
            otherCommands.append(cmd)
        }
    }

    public func segment(named name: String) -> Segment? { segments.first { $0.name == name } }
}

/// Constants from `specs/formats/macho-and-dyld-cache.md`.
public enum MachO {
    public static let magic64: UInt32 = 0xFEEDFACF
    public static let fatMagic: UInt32 = 0xCAFEBABE
    public static let fatMagic64: UInt32 = 0xCAFEBABF
    public static let cpuTypeARM64: UInt32 = 0x0100000C
    public static let cpuTypeX86_64: UInt32 = 0x01000007

    /// Architecture name from CPU type and subtype. The low 24 bits of the
    /// subtype select the variant; the high byte holds capability flags.
    public static func architectureName(cpuType: UInt32, cpuSubtype: UInt32) -> String {
        let sub = cpuSubtype & 0x00FF_FFFF
        switch cpuType {
        case cpuTypeARM64:
            switch sub {
            case 0: return "arm64"
            case 1: return "arm64v8"
            case 2: return "arm64e"
            // Newer variants (Apple's lipo prints e.g. "arm64e.x1" for 12)
            // have no published name mapping; show the raw subtype.
            default: return "arm64.subtype\(sub)"
            }
        case cpuTypeX86_64:
            return sub == 8 ? "x86_64h" : "x86_64"
        default:
            return hex(cpuType)
        }
    }

    static let lcSymtab: UInt32 = 0x02
    static let lcDysymtab: UInt32 = 0x0B
    static let lcLoadDylib: UInt32 = 0x0C
    static let lcIDDylib: UInt32 = 0x0D
    static let lcLoadDylinker: UInt32 = 0x0E
    static let lcSegment64: UInt32 = 0x19
    static let lcUUID: UInt32 = 0x1B
    static let lcCodeSignature: UInt32 = 0x1D
    static let lcLazyLoadDylib: UInt32 = 0x20
    static let lcEncryptionInfo64: UInt32 = 0x2C
    static let lcBuildVersion: UInt32 = 0x32
    static let lcLoadWeakDylib: UInt32 = 0x8000_0018
    static let lcRpath: UInt32 = 0x8000_001C
    static let lcReexportDylib: UInt32 = 0x8000_001F
    static let lcLoadUpwardDylib: UInt32 = 0x8000_0023
    static let lcMain: UInt32 = 0x8000_0028
    static let lcDyldExportsTrie: UInt32 = 0x8000_0033
    static let lcDyldChainedFixups: UInt32 = 0x8000_0034
}

/// A file that is either a thin Mach-O or a universal (fat) container.
public struct MachOFile: Sendable {
    public struct Slice: Sendable {
        public var cpuType: UInt32
        public var cpuSubtype: UInt32
        public var offset: Int
        public var size: Int

        /// `arm64`, `arm64e`, `arm64e.x<N>`, `x86_64`, or the raw CPU type.
        public var name: String { MachO.architectureName(cpuType: cpuType, cpuSubtype: cpuSubtype) }
    }

    public let reader: ByteReader
    public let slices: [Slice]

    public init(contentsOf url: URL) throws {
        try self.init(ByteReader(contentsOf: url))
    }

    public init(_ reader: ByteReader) throws(MachOError) {
        self.reader = reader
        let be = try reader.u32BE(0)
        if be == MachO.fatMagic || be == MachO.fatMagic64 {
            let wide = be == MachO.fatMagic64
            let n = Int(try reader.u32BE(4))
            guard n < 64 else { throw MachOError("implausible slice count \(n)") }
            var out: [Slice] = []
            for i in 0..<n {
                let e = 8 + i * (wide ? 32 : 20)
                let cpu = try reader.u32BE(e)
                let sub = try reader.u32BE(e + 4)
                let off = wide ? Int(try reader.u64BE(e + 8)) : Int(try reader.u32BE(e + 8))
                let size = wide ? Int(try reader.u64BE(e + 16)) : Int(try reader.u32BE(e + 12))
                try reader.check(off, size)
                out.append(Slice(cpuType: cpu, cpuSubtype: sub, offset: off, size: size))
            }
            slices = out
        } else {
            let image = try MachOImage(reader)
            slices = [Slice(cpuType: image.cpuType, cpuSubtype: image.cpuSubtype, offset: 0, size: reader.count)]
        }
    }

    /// The slice named `architecture` (`arm64`, `arm64e`, `x86_64`, …).
    public func image(architecture: String) throws(MachOError) -> MachOImage {
        guard let s = slices.first(where: { $0.name == architecture }) else {
            throw MachOError("no \(architecture) slice (have \(slices.map(\.name).joined(separator: ", ")))")
        }
        return try MachOImage(reader, at: s.offset)
    }

    /// The first slice of a CPU type. For arm64 the plain `arm64` slice is
    /// preferred over arm64e variants.
    public func image(cpuType: UInt32 = MachO.cpuTypeARM64) throws(MachOError) -> MachOImage {
        let candidates = slices.filter { $0.cpuType == cpuType }
        guard let s = candidates.first(where: { $0.cpuSubtype & 0x00FF_FFFF == 0 }) ?? candidates.first else {
            throw MachOError("no slice for CPU type \(hex(cpuType))")
        }
        return try MachOImage(reader, at: s.offset)
    }
}
