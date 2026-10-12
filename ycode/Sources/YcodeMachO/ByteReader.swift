import Foundation

public struct MachOError: Error, CustomStringConvertible, Equatable {
    public var message: String
    public init(_ message: String) { self.message = message }
    public var description: String { message }
}

/// Bounds-checked little/big-endian reads over a byte buffer. Files are
/// memory-mapped, so multi-gigabyte shared caches cost nothing until touched.
public struct ByteReader: Sendable {
    public let data: Data

    public init(_ data: Data) { self.data = data }

    public init(contentsOf url: URL) throws {
        data = try Data(contentsOf: url, options: .alwaysMapped)
    }

    public var count: Int { data.count }

    @inline(__always)
    func check(_ offset: Int, _ size: Int) throws(MachOError) {
        guard offset >= 0, size >= 0, offset <= data.count - size else {
            throw MachOError("read of \(size) bytes at \(offset) is outside a \(data.count)-byte file")
        }
    }

    public func u8(_ o: Int) throws(MachOError) -> UInt8 {
        try check(o, 1)
        return data[data.startIndex + o]
    }

    public func u32(_ o: Int) throws(MachOError) -> UInt32 {
        try check(o, 4)
        return data.withUnsafeBytes { UInt32(littleEndian: $0.loadUnaligned(fromByteOffset: o, as: UInt32.self)) }
    }

    public func u64(_ o: Int) throws(MachOError) -> UInt64 {
        try check(o, 8)
        return data.withUnsafeBytes { UInt64(littleEndian: $0.loadUnaligned(fromByteOffset: o, as: UInt64.self)) }
    }

    public func u32BE(_ o: Int) throws(MachOError) -> UInt32 {
        try check(o, 4)
        return data.withUnsafeBytes { UInt32(bigEndian: $0.loadUnaligned(fromByteOffset: o, as: UInt32.self)) }
    }

    public func u64BE(_ o: Int) throws(MachOError) -> UInt64 {
        try check(o, 8)
        return data.withUnsafeBytes { UInt64(bigEndian: $0.loadUnaligned(fromByteOffset: o, as: UInt64.self)) }
    }

    public func bytes(_ o: Int, _ n: Int) throws(MachOError) -> [UInt8] {
        try check(o, n)
        return [UInt8](data[(data.startIndex + o)..<(data.startIndex + o + n)])
    }

    /// A NUL-padded fixed-size field (`segname[16]`), or a NUL-terminated
    /// string limited to `limit` bytes.
    public func string(_ o: Int, limit: Int) throws(MachOError) -> String {
        let n = max(0, min(limit, data.count - o))
        try check(o, n)
        return data.withUnsafeBytes { raw in
            let base = raw.baseAddress!.advanced(by: o).assumingMemoryBound(to: UInt8.self)
            var len = 0
            while len < n, base[len] != 0 { len += 1 }
            return String(decoding: UnsafeBufferPointer(start: base, count: len), as: UTF8.self)
        }
    }

    public func uuid(_ o: Int) throws(MachOError) -> UUID {
        let b = try bytes(o, 16)
        return UUID(uuid: (b[0], b[1], b[2], b[3], b[4], b[5], b[6], b[7], b[8], b[9], b[10], b[11], b[12], b[13], b[14], b[15]))
    }
}

/// `0x` followed by lowercase hex digits.
public func hex<T: BinaryInteger>(_ v: T) -> String { "0x" + String(v, radix: 16) }

/// `xxxx.yy.zz` packed version.
public struct PackedVersion: Equatable, Comparable, Sendable, CustomStringConvertible {
    public var raw: UInt32
    public init(_ raw: UInt32) { self.raw = raw }
    public var major: Int { Int(raw >> 16) }
    public var minor: Int { Int((raw >> 8) & 0xFF) }
    public var patch: Int { Int(raw & 0xFF) }
    public var description: String { patch == 0 ? "\(major).\(minor)" : "\(major).\(minor).\(patch)" }
    public static func < (a: Self, b: Self) -> Bool { a.raw < b.raw }
}

public enum Platform: UInt32, Sendable, CustomStringConvertible {
    case macOS = 1, iOS, tvOS, watchOS, bridgeOS, macCatalyst
    case iOSSimulator, tvOSSimulator, watchOSSimulator, driverKit, visionOS, visionOSSimulator

    public var description: String {
        switch self {
        case .macOS: "macOS"
        case .iOS: "iOS"
        case .tvOS: "tvOS"
        case .watchOS: "watchOS"
        case .bridgeOS: "bridgeOS"
        case .macCatalyst: "macCatalyst"
        case .iOSSimulator: "iOS Simulator"
        case .tvOSSimulator: "tvOS Simulator"
        case .watchOSSimulator: "watchOS Simulator"
        case .driverKit: "DriverKit"
        case .visionOS: "visionOS"
        case .visionOSSimulator: "visionOS Simulator"
        }
    }

    public var isSimulator: Bool { [.iOSSimulator, .tvOSSimulator, .watchOSSimulator, .visionOSSimulator].contains(self) }
}

/// Memory protection bits.
public struct Protection: OptionSet, Sendable, CustomStringConvertible {
    public let rawValue: UInt32
    public init(rawValue: UInt32) { self.rawValue = rawValue }
    public static let read = Protection(rawValue: 1)
    public static let write = Protection(rawValue: 2)
    public static let execute = Protection(rawValue: 4)
    public var description: String {
        (contains(.read) ? "r" : "-") + (contains(.write) ? "w" : "-") + (contains(.execute) ? "x" : "-")
    }
}
