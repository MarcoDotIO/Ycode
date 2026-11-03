import Foundation

// The images of a Darwin process as LLDB's `jGetLoadedDynamicLibrariesInfos`
// packet reports them (`specs/simulator/debug-stub.md` §4.3). Each image's
// Mach-O header and load commands are read from the process's memory; the
// field names and the JSON shape follow LLDB's `lldbgdbremote.md` and the
// reader of the reply in LLDB's open-source `DynamicLoaderDarwin.cpp`
// (Apache-2.0 with LLVM exception). Mach-O structures: the public
// `mach-o/loader.h` layouts.

/// One loaded Mach-O image.
public struct GDBRemoteImageInfo: Equatable, Sendable {
    public struct Segment: Equatable, Sendable {
        public var name: String
        public var vmaddr: UInt64
        public var vmsize: UInt64
        public var fileoff: UInt64
        public var filesize: UInt64
        public var maxprot: UInt32
        public init(name: String, vmaddr: UInt64, vmsize: UInt64, fileoff: UInt64, filesize: UInt64, maxprot: UInt32) {
            self.name = name
            self.vmaddr = vmaddr
            self.vmsize = vmsize
            self.fileoff = fileoff
            self.filesize = filesize
            self.maxprot = maxprot
        }
    }

    public var loadAddress: UInt64
    public var path: String
    public var uuid: [UInt8]?
    public var magic: UInt32
    public var cputype: UInt32
    public var cpusubtype: UInt32
    public var filetype: UInt32
    public var flags: UInt32
    /// The header and its load commands (`sizeof_mh_and_loadcmds`).
    public var headerAndCommandsSize: UInt32
    public var segments: [Segment]
    /// The platform of `LC_BUILD_VERSION` (or an `LC_VERSION_MIN_*`) as LLDB
    /// names it (`iossimulator`, `ios`, `macosx`, ...), and its minimum OS.
    public var minimumOSName: String?
    public var minimumOSVersion: String?

    public init(loadAddress: UInt64, path: String, uuid: [UInt8]?, magic: UInt32, cputype: UInt32, cpusubtype: UInt32,
                filetype: UInt32, flags: UInt32, headerAndCommandsSize: UInt32, segments: [Segment],
                minimumOSName: String? = nil, minimumOSVersion: String? = nil) {
        self.loadAddress = loadAddress
        self.path = path
        self.uuid = uuid
        self.magic = magic
        self.cputype = cputype
        self.cpusubtype = cpusubtype
        self.filetype = filetype
        self.flags = flags
        self.headerAndCommandsSize = headerAndCommandsSize
        self.segments = segments
        self.minimumOSName = minimumOSName
        self.minimumOSVersion = minimumOSVersion
    }
}

/// How much `jGetLoadedDynamicLibrariesInfos` reports per image.
public enum GDBRemoteImageDetail: Equatable, Sendable {
    case addressOnly, addressName, addressNameUUID, full
}

public enum GDBRemoteMachO {
    public static let magic64: UInt32 = 0xFEED_FACF
    static let segment64: UInt32 = 0x19
    static let uuidCommand: UInt32 = 0x1B
    static let buildVersion: UInt32 = 0x32
    /// LC_VERSION_MIN_* → the platform they stand for.
    static let versionMin: [UInt32: UInt32] = [0x24: 1, 0x25: 2, 0x2F: 3, 0x30: 4]
    /// MH_DYLINKER.
    public static let fileTypeDylinker: UInt32 = 7
    /// Load commands larger than this are not read.
    static let maxCommandBytes = 1 << 20

    /// LLDB's name for a `PLATFORM_*` number (public `mach-o/loader.h`;
    /// the names LLDB's reply reader takes).
    public static func platformName(_ platform: UInt32) -> String? {
        switch platform {
        case 1: "macosx"
        case 2: "ios"
        case 3: "tvos"
        case 4: "watchos"
        case 5: "bridgeos"
        case 6: "maccatalyst"
        case 7: "iossimulator"
        case 8: "tvossimulator"
        case 9: "watchossimulator"
        case 10: "driverkit"
        case 11: "xros"
        case 12: "xrsimulator"
        default: nil
        }
    }

    /// `xxxx.yy.zz` nibbles → "x.y" or "x.y.z".
    public static func versionString(_ v: UInt32) -> String {
        let major = v >> 16, minor = (v >> 8) & 0xFF, patch = v & 0xFF
        return patch == 0 ? "\(major).\(minor)" : "\(major).\(minor).\(patch)"
    }

    /// The image whose 64-bit Mach-O header is at `address`, read with
    /// `read` (fewer bytes than asked: unreadable). nil when no valid
    /// header is there.
    public static func image(at address: UInt64, path: String, read: (UInt64, Int) -> [UInt8]) -> GDBRemoteImageInfo? {
        let header = read(address, 32)
        guard header.count == 32, u32(header, 0) == magic64 else { return nil }
        let ncmds = Int(u32(header, 16)), sizeofcmds = Int(u32(header, 20))
        guard sizeofcmds <= maxCommandBytes else { return nil }
        let commands = read(address + 32, sizeofcmds)
        guard commands.count == sizeofcmds else { return nil }
        var info = GDBRemoteImageInfo(loadAddress: address, path: path, uuid: nil, magic: magic64, cputype: u32(header, 4),
                                      cpusubtype: u32(header, 8) & 0x00FF_FFFF, filetype: u32(header, 12),
                                      flags: u32(header, 24), headerAndCommandsSize: UInt32(32 + sizeofcmds), segments: [])
        var offset = 0
        for _ in 0..<ncmds {
            guard offset + 8 <= commands.count else { break }
            let cmd = u32(commands, offset), size = Int(u32(commands, offset + 4))
            guard size >= 8, offset + size <= commands.count else { break }
            switch cmd {
            case segment64 where size >= 72:
                let nameBytes = commands[(offset + 8)..<(offset + 24)].prefix { $0 != 0 }
                info.segments.append(.init(name: String(decoding: nameBytes, as: UTF8.self), vmaddr: u64(commands, offset + 24),
                                           vmsize: u64(commands, offset + 32), fileoff: u64(commands, offset + 40),
                                           filesize: u64(commands, offset + 48), maxprot: u32(commands, offset + 56)))
            case uuidCommand where size >= 24:
                info.uuid = Array(commands[(offset + 8)..<(offset + 24)])
            case buildVersion where size >= 24:
                if let name = platformName(u32(commands, offset + 8)) {
                    info.minimumOSName = name
                    info.minimumOSVersion = versionString(u32(commands, offset + 12))
                }
            default:
                if let platform = versionMin[cmd], size >= 16, info.minimumOSName == nil, let name = platformName(platform) {
                    info.minimumOSName = name
                    info.minimumOSVersion = versionString(u32(commands, offset + 8))
                }
            }
            offset += size
        }
        return info
    }

    public static func u32(_ b: [UInt8], _ o: Int) -> UInt32 {
        UInt32(b[o]) | UInt32(b[o + 1]) << 8 | UInt32(b[o + 2]) << 16 | UInt32(b[o + 3]) << 24
    }

    public static func u64(_ b: [UInt8], _ o: Int) -> UInt64 {
        UInt64(u32(b, o)) | UInt64(u32(b, o + 4)) << 32
    }
}

/// `jGetLoadedDynamicLibrariesInfos:<json>`: what the client asks for.
public struct GDBRemoteImageRequest: Equatable, Sendable {
    /// Every image (`fetch_all_solibs`), or the images at these addresses
    /// (`solib_addresses`), or `count` images of the `dyld_image_info` array
    /// at `listAddress` (the OS X 10.11 form).
    public enum Selection: Equatable, Sendable {
        case all
        case addresses([UInt64])
        case list(address: UInt64, count: Int)
    }
    public var selection: Selection
    public var detail: GDBRemoteImageDetail

    /// Parses the packet's arguments (the text after the colon). nil: not
    /// a request (an empty argument is the client's support probe).
    public static func parse(_ text: String) -> GDBRemoteImageRequest? {
        guard let data = text.data(using: .utf8),
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
        var detail = GDBRemoteImageDetail.full
        if let reportCommands = object["report_load_commands"] as? Bool, !reportCommands { detail = .addressOnly }
        switch object["information-level"] as? String {
        case "address-only"?: detail = .addressOnly
        case "address-name"?: detail = .addressName
        case "address-name-uuid"?: detail = .addressNameUUID
        case "full"?: detail = .full
        default: break
        }
        if let all = object["fetch_all_solibs"] as? Bool, all { return GDBRemoteImageRequest(selection: .all, detail: detail) }
        if let addresses = object["solib_addresses"] as? [Any] {
            return GDBRemoteImageRequest(selection: .addresses(addresses.compactMap(Self.number)), detail: detail)
        }
        if let list = object["image_list_address"].flatMap(Self.number), let count = object["image_count"].flatMap(Self.number) {
            return GDBRemoteImageRequest(selection: .list(address: list, count: Int(min(count, 1 << 16))), detail: detail)
        }
        return nil
    }

    static func number(_ v: Any) -> UInt64? {
        if let n = v as? NSNumber { return n.uint64Value }
        if let i = v as? Int { return UInt64(bitPattern: Int64(i)) }
        return nil
    }
}

extension GDBRemoteImageInfo {
    /// The image's entry of the reply, at `detail`.
    public func json(_ detail: GDBRemoteImageDetail) -> String {
        var fields = ["\"load_address\":\(loadAddress)"]
        if detail == .addressOnly { return "{" + fields.joined(separator: ",") + "}" }
        fields.append("\"pathname\":\(GDBRemoteServer.jsonString(path))")
        if detail == .addressName { return "{" + fields.joined(separator: ",") + "}" }
        fields.append("\"uuid\":\"\(uuid.map(GDBRemoteServer.uuidString) ?? "")\"")
        if detail == .addressNameUUID { return "{" + fields.joined(separator: ",") + "}" }
        fields.append("\"mod_date\":0")
        if let minimumOSName, let minimumOSVersion {
            fields.append("\"min_version_os_name\":\"\(minimumOSName)\"")
            fields.append("\"min_version_os_sdk\":\"\(minimumOSVersion)\"")
        }
        fields.append("\"mach_header\":{\"magic\":\(magic),\"cputype\":\(cputype),\"cpusubtype\":\(cpusubtype),"
            + "\"filetype\":\(filetype),\"flags\":\(flags),\"sizeof_mh_and_loadcmds\":\(headerAndCommandsSize)}")
        let segs = segments.map {
            "{\"name\":\(GDBRemoteServer.jsonString($0.name)),\"vmaddr\":\($0.vmaddr),\"vmsize\":\($0.vmsize),"
                + "\"fileoff\":\($0.fileoff),\"filesize\":\($0.filesize),\"maxprot\":\($0.maxprot)}"
        }
        fields.append("\"segments\":[" + segs.joined(separator: ",") + "]")
        return "{" + fields.joined(separator: ",") + "}"
    }

    /// The whole reply: `{"images":[…]}`.
    public static func reply(_ images: [GDBRemoteImageInfo], _ detail: GDBRemoteImageDetail) -> String {
        "{\"images\":[" + images.map { $0.json(detail) }.joined(separator: ",") + "]}"
    }
}

/// libdyld's process states (`jGetDyldProcessState`), with the names LLDB
/// compares (`DynamicLoaderMacOS::IsFullyInitialized`).
public enum GDBRemoteDyldState: Int, Sendable, CaseIterable {
    case notStarted = 0x00
    case dyldInitialized = 0x10
    case terminatedBeforeInits = 0x20
    case libSystemInitialized = 0x30
    case runningInitializers = 0x40
    case programRunning = 0x50
    case dyldTerminated = 0x60

    public var name: String {
        switch self {
        case .notStarted: "dyld_process_state_not_started"
        case .dyldInitialized: "dyld_process_state_dyld_initialized"
        case .terminatedBeforeInits: "dyld_process_state_terminated_before_inits"
        case .libSystemInitialized: "dyld_process_state_libSystem_initialized"
        case .runningInitializers: "dyld_process_state_running_initializers"
        case .programRunning: "dyld_process_state_program_running"
        case .dyldTerminated: "dyld_process_state_dyld_terminated"
        }
    }

    public var reply: String { "{\"process_state_value\":\(rawValue),\"process_state string\":\"\(name)\"}" }
}
