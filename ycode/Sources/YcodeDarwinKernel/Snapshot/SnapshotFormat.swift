// The snapshot file format (specs/simulator/snapshot.md §6): a manifest of
// versioned records whose payloads are tagged fields, and sparse page files.
// Portable (macOS and Linux) so the format is unit-tested everywhere.

import Foundation

/// A failure to read or write a snapshot.
public struct SnapshotError: Error, CustomStringConvertible, Sendable {
    public var message: String
    public init(_ message: String) { self.message = message }
    public var description: String { message }
}

// MARK: - Fields

/// One record payload being written: a sequence of (tag u16, type u8, value).
public struct SnapshotFields: Sendable {
    public enum FieldType: UInt8, Sendable {
        case u64 = 1, i64 = 2, bytes = 3, string = 4, u64List = 5, reference = 6, nested = 7, nestedList = 8
    }

    public private(set) var bytes: [UInt8] = []

    public init() {}

    private mutating func head(_ tag: UInt16, _ type: FieldType) {
        bytes.append(UInt8(tag & 0xFF))
        bytes.append(UInt8(tag >> 8))
        bytes.append(type.rawValue)
    }

    private mutating func raw64(_ v: UInt64) { for i in 0..<8 { bytes.append(UInt8(truncatingIfNeeded: v >> (8 * UInt64(i)))) } }
    private mutating func raw32(_ v: UInt32) { for i in 0..<4 { bytes.append(UInt8(truncatingIfNeeded: v >> (8 * UInt32(i)))) } }

    public mutating func u64(_ tag: UInt16, _ v: UInt64) { head(tag, .u64); raw64(v) }
    public mutating func i64(_ tag: UInt16, _ v: Int64) { head(tag, .i64); raw64(UInt64(bitPattern: v)) }
    public mutating func bool(_ tag: UInt16, _ v: Bool) { u64(tag, v ? 1 : 0) }
    public mutating func bytes(_ tag: UInt16, _ v: [UInt8]) {
        head(tag, .bytes)
        raw32(UInt32(v.count))
        bytes.append(contentsOf: v)
    }
    public mutating func string(_ tag: UInt16, _ v: String) {
        head(tag, .string)
        let utf8 = Array(v.utf8)
        raw32(UInt32(utf8.count))
        bytes.append(contentsOf: utf8)
    }
    public mutating func u64s(_ tag: UInt16, _ v: [UInt64]) {
        head(tag, .u64List)
        raw32(UInt32(v.count))
        for x in v { raw64(x) }
    }
    /// A reference to another record (0 = none).
    public mutating func ref(_ tag: UInt16, _ id: UInt64) { head(tag, .reference); raw64(id) }
    public mutating func nested(_ tag: UInt16, _ v: SnapshotFields) {
        head(tag, .nested)
        raw32(UInt32(v.bytes.count))
        bytes.append(contentsOf: v.bytes)
    }
    public mutating func list(_ tag: UInt16, _ v: [SnapshotFields]) {
        head(tag, .nestedList)
        raw32(UInt32(v.count))
        for f in v {
            raw32(UInt32(f.bytes.count))
            bytes.append(contentsOf: f.bytes)
        }
    }
}

/// A decoded payload. Unknown tags are kept but ignored by callers; a
/// repeated tag keeps its last value.
public struct SnapshotFieldReader: Sendable {
    public enum Value: Sendable {
        case u64(UInt64), i64(Int64), bytes([UInt8]), string(String), u64s([UInt64]), ref(UInt64)
        case nested(SnapshotFieldReader), list([SnapshotFieldReader])
    }

    public private(set) var values: [UInt16: Value] = [:]

    public init(_ bytes: [UInt8]) throws {
        try self.init(bytes[...])
    }

    init(_ bytes: ArraySlice<UInt8>) throws {
        var r = ByteCursor(bytes)
        while !r.atEnd {
            let tag = try r.u16()
            guard let type = SnapshotFields.FieldType(rawValue: try r.u8()) else {
                throw SnapshotError("snapshot field \(tag): unknown type")
            }
            switch type {
            case .u64: values[tag] = .u64(try r.u64())
            case .i64: values[tag] = .i64(Int64(bitPattern: try r.u64()))
            case .bytes: values[tag] = .bytes(Array(try r.take(Int(try r.u32()))))
            case .string: values[tag] = .string(String(decoding: try r.take(Int(try r.u32())), as: UTF8.self))
            case .u64List:
                let n = Int(try r.u32())
                var list: [UInt64] = []
                list.reserveCapacity(n)
                for _ in 0..<n { list.append(try r.u64()) }
                values[tag] = .u64s(list)
            case .reference: values[tag] = .ref(try r.u64())
            case .nested: values[tag] = .nested(try SnapshotFieldReader(try r.take(Int(try r.u32()))))
            case .nestedList:
                let n = Int(try r.u32())
                var list: [SnapshotFieldReader] = []
                for _ in 0..<n { list.append(try SnapshotFieldReader(try r.take(Int(try r.u32())))) }
                values[tag] = .list(list)
            }
        }
    }

    public func has(_ tag: UInt16) -> Bool { values[tag] != nil }

    public func u64(_ tag: UInt16, default d: UInt64 = 0) -> UInt64 {
        switch values[tag] {
        case let .u64(v)?, let .ref(v)?: return v
        case let .i64(v)?: return UInt64(bitPattern: v)
        default: return d
        }
    }
    public func optionalU64(_ tag: UInt16) -> UInt64? { has(tag) ? u64(tag) : nil }
    public func i64(_ tag: UInt16, default d: Int64 = 0) -> Int64 {
        switch values[tag] {
        case let .i64(v)?: return v
        case let .u64(v)?: return Int64(bitPattern: v)
        default: return d
        }
    }
    public func u32(_ tag: UInt16, default d: UInt32 = 0) -> UInt32 { has(tag) ? UInt32(truncatingIfNeeded: u64(tag)) : d }
    public func i32(_ tag: UInt16, default d: Int32 = 0) -> Int32 { has(tag) ? Int32(truncatingIfNeeded: i64(tag)) : d }
    public func bool(_ tag: UInt16, default d: Bool = false) -> Bool { has(tag) ? u64(tag) != 0 : d }
    public func bytes(_ tag: UInt16) -> [UInt8] {
        if case let .bytes(v)? = values[tag] { return v }
        return []
    }
    public func string(_ tag: UInt16) -> String? {
        if case let .string(v)? = values[tag] { return v }
        return nil
    }
    public func u64s(_ tag: UInt16) -> [UInt64] {
        if case let .u64s(v)? = values[tag] { return v }
        return []
    }
    public func ref(_ tag: UInt16) -> UInt64 { u64(tag) }
    public func nested(_ tag: UInt16) -> SnapshotFieldReader? {
        if case let .nested(v)? = values[tag] { return v }
        return nil
    }
    public func list(_ tag: UInt16) -> [SnapshotFieldReader] {
        if case let .list(v)? = values[tag] { return v }
        return []
    }
}

/// Little-endian reads over a byte slice.
struct ByteCursor {
    let bytes: ArraySlice<UInt8>
    var position: Int

    init(_ bytes: ArraySlice<UInt8>) {
        self.bytes = bytes
        position = bytes.startIndex
    }

    var atEnd: Bool { position >= bytes.endIndex }

    mutating func take(_ n: Int) throws -> ArraySlice<UInt8> {
        guard n >= 0, bytes.endIndex - position >= n else { throw SnapshotError("snapshot: truncated data") }
        defer { position += n }
        return bytes[position..<position + n]
    }
    mutating func u8() throws -> UInt8 { try take(1).first! }
    mutating func u16() throws -> UInt16 {
        let b = try take(2)
        return UInt16(b[b.startIndex]) | UInt16(b[b.startIndex + 1]) << 8
    }
    mutating func u32() throws -> UInt32 {
        let b = try take(4)
        var v: UInt32 = 0
        for (i, x) in b.enumerated() { v |= UInt32(x) << (8 * UInt32(i)) }
        return v
    }
    mutating func u64() throws -> UInt64 {
        let b = try take(8)
        var v: UInt64 = 0
        for (i, x) in b.enumerated() { v |= UInt64(x) << (8 * UInt64(i)) }
        return v
    }
}

// MARK: - Records and the manifest

/// Record kinds (§6.1). Bit 15 marks a kind a reader may skip.
public enum SnapshotRecordKind: UInt16, Sendable, CaseIterable {
    case system = 1, process = 2, image = 3, thread = 4, region = 5, sharedMemory = 6
    case machSpace = 10, port = 11, portSet = 12, semaphore = 14, ulock = 15
    case openFile = 20, hostFile = 21, pipe = 22, kqueue = 23, workqueue = 25, unixSocket = 26, posixShm = 27, posixSem = 28
    /// An IP socket (networking-ycode.md §6).
    case inetSocket = 29
    case clock = 30
    /// A host service's own state (§2.6, §9): optional, a reader that does
    /// not know the service skips it.
    case hostService = 0x801F
    case census = 0x8020
}

public struct SnapshotRecord: Sendable {
    public var kind: UInt16
    public var version: UInt16
    public var id: UInt64
    public var payload: [UInt8]

    public init(kind: SnapshotRecordKind, version: UInt16 = 1, id: UInt64, fields: SnapshotFields) {
        self.kind = kind.rawValue
        self.version = version
        self.id = id
        payload = fields.bytes
    }

    public init(kind: UInt16, version: UInt16, id: UInt64, payload: [UInt8]) {
        self.kind = kind
        self.version = version
        self.id = id
        self.payload = payload
    }

    /// The record's kind, or nil when this build does not know it.
    public var knownKind: SnapshotRecordKind? { SnapshotRecordKind(rawValue: kind) }
    /// Parses the payload's fields; throws `SnapshotError` if the payload is malformed.
    public func fields() throws -> SnapshotFieldReader { try SnapshotFieldReader(payload) }
}

/// The manifest file (`manifest.ysnap`).
public enum SnapshotManifest {
    /// The 8-byte magic that starts the file (`snapshot.md` §6.1).
    public static let magic: [UInt8] = Array("YCSNAP".utf8) + [0, 1]
    /// The only format version this build writes and reads.
    public static let formatVersion: UInt32 = 1
    /// The manifest's file name inside a snapshot directory.
    public static let fileName = "manifest.ysnap"

    /// The manifest bytes for `records`: the header (creation time in seconds since
    /// 1970) followed by every record in order.
    public static func encode(_ records: [SnapshotRecord], createdAt: UInt64 = UInt64(Date().timeIntervalSince1970)) -> [UInt8] {
        var out = magic
        func u16(_ v: UInt16) { out.append(UInt8(v & 0xFF)); out.append(UInt8(v >> 8)) }
        func u32(_ v: UInt32) { for i in 0..<4 { out.append(UInt8(truncatingIfNeeded: v >> (8 * UInt32(i)))) } }
        func u64(_ v: UInt64) { for i in 0..<8 { out.append(UInt8(truncatingIfNeeded: v >> (8 * UInt64(i)))) } }
        u32(formatVersion)
        u32(0)
        u64(createdAt)
        u64(UInt64(records.count))
        for r in records {
            u16(r.kind)
            u16(r.version)
            u32(0)
            u64(r.id)
            u64(UInt64(r.payload.count))
            out.append(contentsOf: r.payload)
        }
        return out
    }

    /// Parses a manifest. Throws `SnapshotError` for a wrong magic, another format
    /// version, a truncated record, or trailing bytes.
    public static func decode(_ bytes: [UInt8]) throws -> (createdAt: UInt64, records: [SnapshotRecord]) {
        var r = ByteCursor(bytes[...])
        guard Array(try r.take(8)) == magic else { throw SnapshotError("not a Ycode snapshot manifest") }
        let version = try r.u32()
        guard version == formatVersion else { throw SnapshotError("snapshot format version \(version), this build reads \(formatVersion)") }
        _ = try r.u32()
        let created = try r.u64()
        let count = try r.u64()
        var records: [SnapshotRecord] = []
        records.reserveCapacity(Int(min(count, 1 << 20)))
        for _ in 0..<count {
            let kind = try r.u16()
            let rv = try r.u16()
            _ = try r.u32()
            let id = try r.u64()
            let length = try r.u64()
            guard length <= UInt64(Int.max) else { throw SnapshotError("snapshot record too large") }
            records.append(SnapshotRecord(kind: kind, version: rv, id: id, payload: Array(try r.take(Int(length)))))
        }
        guard r.atEnd else { throw SnapshotError("snapshot manifest has trailing bytes") }
        return (created, records)
    }
}

// MARK: - Page files

/// A sparse page file (§6.2): extents of 16 KiB pages.
public enum SnapshotPageFile {
    /// The 8-byte magic that starts a page file (§6.2).
    public static let magic: [UInt8] = Array("YCPAGES1".utf8)
    /// The page size of every extent, in bytes.
    public static let pageSize = 16384

    /// A run of `pageCount` pages starting at guest address `address`, stored
    /// contiguously in the file.
    public struct Extent: Equatable, Sendable {
        public var address: UInt64
        public var pageCount: UInt32
        public init(address: UInt64, pageCount: UInt32) {
            self.address = address
            self.pageCount = pageCount
        }
    }

    /// The header and extent table for `extents`; the pages follow at the
    /// returned data offset (16 KiB-aligned).
    public static func header(for extents: [Extent]) -> (bytes: [UInt8], dataOffset: UInt64) {
        var out = magic
        func u32(_ v: UInt32) { for i in 0..<4 { out.append(UInt8(truncatingIfNeeded: v >> (8 * UInt32(i)))) } }
        func u64(_ v: UInt64) { for i in 0..<8 { out.append(UInt8(truncatingIfNeeded: v >> (8 * UInt64(i)))) } }
        let tableEnd = UInt64(32 + 16 * extents.count)
        let dataOffset = (tableEnd + UInt64(pageSize) - 1) / UInt64(pageSize) * UInt64(pageSize)
        u32(UInt32(pageSize))
        u32(0)
        u64(UInt64(extents.count))
        u64(dataOffset)
        for e in extents {
            u64(e.address)
            u32(e.pageCount)
            u32(0)
        }
        out += [UInt8](repeating: 0, count: Int(dataOffset) - out.count)
        return (out, dataOffset)
    }

    /// Parses a header: the extents and the data offset.
    public static func parseHeader(_ bytes: [UInt8]) throws -> (extents: [Extent], dataOffset: UInt64) {
        var r = ByteCursor(bytes[...])
        guard Array(try r.take(8)) == magic else { throw SnapshotError("not a Ycode page file") }
        guard try r.u32() == UInt32(pageSize) else { throw SnapshotError("page file: unexpected page size") }
        _ = try r.u32()
        let count = try r.u64()
        let dataOffset = try r.u64()
        var extents: [Extent] = []
        for _ in 0..<count {
            let address = try r.u64()
            let pages = try r.u32()
            _ = try r.u32()
            extents.append(Extent(address: address, pageCount: pages))
        }
        return (extents, dataOffset)
    }

    /// Merges a sorted list of page addresses into extents.
    public static func extents(of pages: [UInt64]) -> [Extent] {
        var out: [Extent] = []
        for page in pages {
            if var last = out.last, last.address + UInt64(last.pageCount) * UInt64(pageSize) == page {
                last.pageCount += 1
                out[out.count - 1] = last
            } else {
                out.append(Extent(address: page, pageCount: 1))
            }
        }
        return out
    }
}
