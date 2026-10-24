import Foundation
import Testing
import YcodeDarwinABI
@testable import YcodeDarwinKernel

/// The start-up object seed (`boot-profile.md` §7) and the CPU-time calls
/// (getrusage 117, thread_selfusage 482).
@Suite struct StartObjectsTests {
    private let s = Env.scratch

    @Test func seededCacheFileResolvesWithoutAWalk() throws {
        let env = try Env(device: 0x0100_0042)
        let dir = env.root + "/System/Library/Caches/com.apple.dyld"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let path = try env.makeFile("System/Library/Caches/com.apple.dyld/dyld_sim_shared_cache_arm64", [1])
        var st = stat()
        _ = lstat(path, &st)
        try env.space.write(va: s, bytes: Array(leBytes(0x0100_0042).prefix(4)) + [UInt8](repeating: 0, count: 4))
        // The volume's walk is used up: without the seed the id is unknown.
        _ = env.kernel.system.objectPaths.mayWalk(0x0100_0042)
        #expect(env.svc(427, [s + 0x100, 1024, s, UInt64(st.st_ino)]).1.x[0] == 2)  // ENOENT
        let fs = DarwinFileSystem(prefixes: [.init(guestPath: env.root, hostPath: env.root, writable: false, device: 0x0100_0042)],
                                  console: { _, _ in })
        #expect(env.kernel.system.prewarmObjectPaths(fileSystem: fs) == 1)
        let (_, r) = env.svc(427, [s + 0x100, 1024, s, UInt64(st.st_ino)])
        #expect(!r.carry)
        #expect(Int(r.x[0]) == path.utf8.count + 1)
        #expect(String(decoding: try env.space.read(va: s + 0x100, count: path.utf8.count), as: UTF8.self) == path)
    }

    @Test func getrusageReportsProcessCPU() throws {
        let env = try Env()
        env.kernel.processCPUTimes = { (2_500_000_000, 750_000_000) }
        let (_, r) = env.svc(117, [0, s])
        #expect(!r.carry && r.x[0] == 0)
        let b = try env.space.read(va: s, count: 144)
        #expect(b.readLE(Int64.self, at: 0) == 2 && b.readLE(Int32.self, at: 8) == 500_000)
        #expect(b.readLE(Int64.self, at: 16) == 0 && b.readLE(Int32.self, at: 24) == 750_000)
        #expect(b[32...].allSatisfy { $0 == 0 })
        let (_, children) = env.svc(117, [UInt64(bitPattern: -1), s])
        let zeroed = try env.space.read(va: s, count: 144)
        #expect(!children.carry && zeroed.allSatisfy { $0 == 0 })
        #expect(env.svc(117, [5, s]).1.carry)  // EINVAL
    }

    @Test func threadSelfusageCountsTheCallingThread() throws {
        let env = try Env(frequency: 24_000_000)
        var spin: UInt64 = 0
        let end = Date().addingTimeInterval(0.02)
        while Date() < end { spin &+= 1 }
        let (_, r) = env.svc(482)
        #expect(!r.carry)
        // At least 10 ms of this thread's CPU, in 24 MHz ticks, and no
        // more than the thread's total.
        #expect(r.x[0] >= 240_000, "\(r.x[0]) \(spin)")
        #expect(r.x[0] <= DarwinKernel.hostThreadCPUNanoseconds() * 24 / 1000 + 1)
    }
}
