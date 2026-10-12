// Builders for synthetic Metal host messages, written from the layouts of
// metal-sim-protocol.md (no captured bytes).

import Foundation
@testable import YcodeMetalHost
import YcodeXPC

/// Host memory standing in for guest pages behind memory entries.
final class FakeMemory: MetalGuestMemoryResolver, @unchecked Sendable {
    final class Block {
        let pointer: UnsafeMutableRawPointer
        let length: Int
        init(length: Int) {
            self.length = length
            pointer = UnsafeMutableRawPointer.allocate(byteCount: max(length, 1), alignment: 16384)
            pointer.initializeMemory(as: UInt8.self, repeating: 0, count: max(length, 1))
        }
        deinit { pointer.deallocate() }
    }

    private let lock = NSLock()
    private var blocks: [UInt32: Block] = [:]
    private var next: UInt32 = 0x9000

    /// A new memory entry name over `length` bytes (optionally filled).
    func entry(length: Int, bytes: [UInt8] = []) -> (UInt32, Block) {
        lock.withLock {
            let b = Block(length: length)
            if !bytes.isEmpty { bytes.withUnsafeBytes { b.pointer.copyMemory(from: $0.baseAddress!, byteCount: min(bytes.count, length)) } }
            next += 1
            blocks[next] = b
            return (next, b)
        }
    }

    func region(forMemoryEntry name: UInt32) -> GuestSharedRegion? {
        lock.withLock {
            guard let b = blocks[name] else { return nil }
            return GuestSharedRegion(pointer: b.pointer, length: b.length, objectID: UInt64(name), owner: b)
        }
    }
}

final class FakeSurfaces: IOSurfaceResolver, @unchecked Sendable {
    var known: [UInt32: IOSurfaceBacking] = [:]
    func backing(forSurfacePort port: UInt32, plane: Int) -> IOSurfaceBacking? { known[port] }
}

final class FakeTransport: MetalHostTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var _events: [(port: UInt32, event: XPCDict)] = []
    private var _dropped: [UInt32] = []
    var events: [(port: UInt32, event: XPCDict)] { lock.withLock { _events } }
    var dropped: [UInt32] { lock.withLock { _dropped } }
    func sendEvent(_ event: XPCDict, to port: UInt32) -> Bool { lock.withLock { _events.append((port, event)) }; return true }
    func dropRight(_ name: UInt32) { lock.withLock { _dropped.append(name) } }

    /// (messageType, commandBufferRef, status) of each event.
    var summary: [[UInt64]] {
        events.map { [$0.event["messageType"]?.uint64Value ?? 0, $0.event["commandBufferRef"]?.uint64Value ?? 0,
                      $0.event["status"]?.uint64Value ?? 0] }
    }
}

enum Build {
    static func record(_ op: UInt32, _ fill: (inout MetalByteWriter) -> Void = { _ in }) -> [UInt8] {
        var w = MetalByteWriter()
        fill(&w)
        return MetalByteWriter.record(op, w.bytes)
    }

    /// A segment: header (used, kind, continues-previous, continues-in-next, 0), records, padding to `size`.
    static func segment(kind: UInt8, continuesPrevious: Bool = false, continuesInNext: Bool = false, _ records: [[UInt8]],
                        size: Int = 4096) -> [UInt8] {
        let body = records.flatMap { $0 }
        var w = MetalByteWriter()
        w.u32(UInt32(8 + body.count))
        w.u8(kind); w.u8(continuesPrevious ? 1 : 0); w.u8(continuesInNext ? 1 : 0); w.u8(0)
        w.append(body)
        w.pad(to: max(size, w.bytes.count))
        return w.bytes
    }

    /// Texture descriptor words 0–8.
    static func textureWords(type: UInt32 = 2, flags: UInt32 = 0, gpuOptimized: Bool = true, usage: UInt32, format: UInt32,
                             width: UInt32, height: UInt32, depth: UInt32 = 1, levels: UInt16 = 1, samples: UInt16 = 1,
                             arrayLength: UInt16 = 1, options: UInt16 = 0) -> [UInt8] {
        var w = MetalByteWriter()
        w.u32(0)
        w.u32(type | flags << 4 | (gpuOptimized ? 0x40 : 0) | usage << 8 | format << 16)
        w.u32(width); w.u32(height); w.u32(depth)
        w.u16(levels); w.u16(samples); w.u16(arrayLength); w.u16(options)
        w.u64(0)
        return w.bytes
    }

    /// A 584-byte render pass descriptor body with color attachments
    /// (index, texture ref, load, store, clear color) and an optional depth texture.
    static func renderPass(colors: [(Int, UInt32, UInt16, UInt16, [Double])], depth: UInt32 = 0, width: UInt64, height: UInt64)
        -> [UInt8] {
        var b = [UInt8](repeating: 0, count: 584)
        func put32(_ at: Int, _ v: UInt32) { for i in 0..<4 { b[at + i] = UInt8(truncatingIfNeeded: v >> (8 * UInt32(i))) } }
        func put16(_ at: Int, _ v: UInt16) { b[at] = UInt8(v & 0xFF); b[at + 1] = UInt8(v >> 8) }
        func put64(_ at: Int, _ v: UInt64) { put32(at, UInt32(truncatingIfNeeded: v)); put32(at + 4, UInt32(truncatingIfNeeded: v >> 32)) }
        put32(0, depth)
        put16(20, 2); put16(22, 0)
        put64(28, 1.0.bitPattern)
        put16(60, 2)
        for n in 0..<8 { put16(76 + 60 * n + 20, 0); put16(76 + 60 * n + 22, 1); put64(76 + 60 * n + 28 + 24, 1.0.bitPattern) }
        for (n, t, load, store, clear) in colors {
            let base = 76 + 60 * n
            put32(base, t)
            put16(base + 20, load); put16(base + 22, store)
            for (i, c) in clear.enumerated() { put64(base + 28 + 8 * i, c.bitPattern) }
        }
        put64(568, width)
        put64(576, height)
        return b
    }

    /// A message dictionary with a `command` record.
    static func message(_ type: UInt64, _ command: [UInt8]? = nil, _ extra: [(String, XPCObject)] = []) -> XPCDict {
        var d: XPCDict = ["messageType": .uint64(type)]
        if let command { d["command"] = .data(command) }
        for (k, v) in extra { d[k] = v }
        return d
    }

    static func u32(_ b: [UInt8], _ i: Int) -> UInt32 {
        var v: UInt32 = 0
        for k in 0..<4 { v |= UInt32(b[4 * i + k]) << (8 * UInt32(k)) }
        return v
    }

    static func u64(_ b: [UInt8], _ i: Int) -> UInt64 { UInt64(u32(b, 2 * i)) | UInt64(u32(b, 2 * i + 1)) << 32 }
}
