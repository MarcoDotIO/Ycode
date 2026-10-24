import Foundation
import Testing
import YcodeDarwinKernel
@testable import YcodeHostServices
import YcodeXPC

/// The IOSurface host service's methods (iosurface-remote.md §3–§5), called
/// directly; the Mach side is exercised in device runs.
@Suite struct IOSurfaceServiceTests {
    func service() throws -> IOSurfaceHostService {
        try IOSurfaceHostService(host: DarwinSystem().hostTask, log: { _ in })
    }

    func props(_ pairs: [(String, OSValue)]) -> XPCObject { .data(OSSerialize.encode(.dictionary(pairs.map { ($0.0, $0.1) }))) }

    func u32(_ d: [UInt8], _ i: Int) -> UInt32 { d.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 4 * i, as: UInt32.self) } }

    func reply(_ r: [(String, XPCObject)]) -> XPCDict { XPCDict(r.map { XPCDict.Entry(key: $0.0, value: $0.1) }) }

    @Test func layoutRules() throws {
        func layout(_ w: UInt64, _ h: UInt64, _ bpe: UInt64) -> IOSurfaceHostService.Layout? {
            IOSurfaceHostService.layout(.dictionary([("IOSurfaceWidth", .number(w, bits: 64)), ("IOSurfaceHeight", .number(h, bits: 64)),
                                                     ("IOSurfaceBytesPerElement", .number(bpe, bits: 64))]))
        }
        #expect(layout(1398, 2034, 4)?.bytesPerRow == 5632 && layout(1398, 2034, 4)?.allocationSize == 11_468_800)
        #expect(layout(64, 32, 4)?.bytesPerRow == 256 && layout(64, 32, 4)?.allocationSize == 16384)
        #expect(layout(146, 1, 8)?.bytesPerRow == 1280 && layout(100, 100, 4)?.allocationSize == 65536)
        #expect(layout(0, 10, 4) == nil)
    }

    /// CPU access waits for pending GPU writes (the Metal back end's
    /// `waitForSurfaceWrites`): guest locks without kIOSurfaceLockAvoidSync,
    /// and host reads (display server, screenshots); never under the lock.
    @Test func cpuAccessWaitsForGPUWrites() throws {
        let s = try service()
        let conn: UInt32 = 0x1235
        s.addTestConnection(conn)
        final class Calls: @unchecked Sendable { let lock = NSLock(); var ids: [UInt32] = [] }
        let calls = Calls()
        s.gpuWriteWait = { [unowned s] id in
            _ = s.lockState(id: id)  // the service's lock is free here
            calls.lock.withLock { calls.ids.append(id) }
        }
        let p = props([("IOSurfaceWidth", .number(64, bits: 64)), ("IOSurfaceHeight", .number(32, bits: 64)),
                       ("IOSurfaceBytesPerElement", .number(4, bits: 64))])
        let r = reply(s.perform(["Method": .uint64(2), "PropertiesDictionary": p], connection: conn).0)
        guard case let .data(state)? = r["SurfaceState"] else { Issue.record("no state"); return }
        let id = u32(state, 1), sid: XPCObject = .uint64(UInt64(id))
        _ = s.perform(["Method": .uint64(4), "SurfaceID": sid, "Options": .uint64(0)], connection: conn)  // waits
        _ = s.perform(["Method": .uint64(4), "SurfaceID": sid, "Options": .uint64(1)], connection: conn)  // read-only: waits
        _ = s.perform(["Method": .uint64(4), "SurfaceID": sid, "Options": .uint64(2)], connection: conn)  // avoid sync: no wait
        _ = s.perform(["Method": .uint64(5), "SurfaceID": sid], connection: conn)                          // unlock: no wait
        #expect(calls.lock.withLock { calls.ids } == [id, id])
        _ = s.surface(id: id)
        _ = s.snapshot(surfaceID: id)
        #expect(calls.lock.withLock { calls.ids } == [id, id, id, id])
    }

    @Test func createLookUpLockValuesPorts() throws {
        let s = try service()
        let conn: UInt32 = 0x1234
        s.addTestConnection(conn)
        var r = reply(s.perform(["Method": .uint64(0)], connection: conn).0)
        #expect(r["ErrorCode"]?.uint64Value == 0 && r["ProtocolVersion"]?.uint64Value == 1)
        let p = props([("IOSurfaceWidth", .number(1398, bits: 64)), ("IOSurfaceHeight", .number(2034, bits: 64)),
                       ("IOSurfaceBytesPerElement", .number(4, bits: 64)), ("IOSurfacePixelFormat", .number(0x4247_5241, bits: 32)),
                       ("IOSurfaceName", .string("QuartzCore"))])
        r = reply(s.perform(["Method": .uint64(2), "PropertiesDictionary": p], connection: conn).0)
        #expect(r["ErrorCode"]?.uint64Value == 0)
        guard case let .sharedMemory(size, _)? = r["MemoryObject"], case let .data(state)? = r["SurfaceState"] else {
            Issue.record("no memory object or state")
            return
        }
        #expect(size == 11_468_800 && state.count == 72)
        let id = u32(state, 1)
        #expect(u32(state, 3) == 1398 && u32(state, 5) == 5632 && u32(state, 7) == 0x4247_5241 && u32(state, 13) == 0)
        // Look-up by ID; unknown ID; no key at all.
        r = reply(s.perform(["Method": .uint64(2), "LookupID": .uint64(UInt64(id))], connection: conn).0)
        #expect(r["ErrorCode"]?.uint64Value == 0)
        r = reply(s.perform(["Method": .uint64(2), "LookupID": .uint64(999)], connection: conn).0)
        #expect(r["ErrorCode"]?.uint64Value == 0xFFFF_FFFF_E000_02F0)
        r = reply(s.perform(["Method": .uint64(2)], connection: conn).0)
        #expect(r["ErrorCode"]?.uint64Value == 0xFFFF_FFFF_E000_02C2)
        // Lock (write) bumps the seed; read-only does not; unlock beyond the count fails.
        let sid: XPCObject = .uint64(UInt64(id))
        r = reply(s.perform(["Method": .uint64(4), "SurfaceID": sid, "Options": .uint64(0)], connection: conn).0)
        if case let .data(st)? = r["SurfaceState"] { #expect(u32(st, 13) == 1) }
        _ = s.perform(["Method": .uint64(4), "SurfaceID": sid, "Options": .uint64(1)], connection: conn)
        _ = s.perform(["Method": .uint64(5), "SurfaceID": sid], connection: conn)
        _ = s.perform(["Method": .uint64(5), "SurfaceID": sid], connection: conn)
        r = reply(s.perform(["Method": .uint64(5), "SurfaceID": sid], connection: conn).0)
        #expect(r["ErrorCode"]?.uint64Value == 0xFFFF_FFFF_E000_02C2)
        // Values: set the name, read all (three service-added values).
        let v = OSSerialize.encode(.dictionary([("key", .string("IOSurfaceName")), ("value", .string("LCD"))]))
        _ = s.perform(["Method": .uint64(9), "SurfaceID": sid, "PropertiesDictionary": .data(v)], connection: conn)
        r = reply(s.perform(["Method": .uint64(10), "SurfaceID": sid], connection: conn).0)
        if case let .data(blob)? = r["PropertiesDictionary"] {
            let all = try OSSerialize.decode(blob)
            #expect(all["IOSurfaceName"]?.stringValue == "LCD" && all["CreationProperties"] != nil
                    && all["HorizontalDisparityAdjustment"]?.numberValue == 0)
        } else { Issue.record("no values") }
        #expect(s.surfaceSummary.first?.name == "LCD")
        // Attachments: defaults, then what was set.
        _ = s.perform(["Method": .uint64(20), "SurfaceID": sid, "TransferFunctionIndex": .uint64(13)], connection: conn)
        r = reply(s.perform(["Method": .uint64(21), "SurfaceID": sid], connection: conn).0)
        #expect(r["TransferFunctionIndex"]?.uint64Value == 13 && r["ChromaSubsampling"]?.uint64Value == 0x80)
        // A Mach port, then look-up by it; in use while it exists.
        let (r14, after) = s.perform(["Method": .uint64(14), "SurfaceID": sid], connection: conn)
        after?()
        guard case let .sendRight(port)? = reply(r14)["MachPort"] else { Issue.record("no port"); return }
        r = reply(s.perform(["Method": .uint64(2), "MachPort": .sendRight(XPCPort(name: port.name, disposition: 17))], connection: conn).0)
        #expect(r["ErrorCode"]?.uint64Value == 0)
        r = reply(s.perform(["Method": .uint64(17), "SurfaceID": sid], connection: conn).0)
        #expect(r["IsInUse"]?.boolValue == true)
        // Snapshot for the host; unknown method.
        #expect(s.snapshot(surfaceID: id)?.bytesPerRow == 5632)
        r = reply(s.perform(["Method": .uint64(99), "SurfaceID": sid], connection: conn).0)
        #expect(r["ErrorCode"]?.uint64Value == 0xFFFF_FFFF_E000_02C7)
    }
}
