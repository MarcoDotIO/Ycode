import Foundation
import Testing
import YcodeDarwinABI
@testable import YcodeDarwinKernel

/// thread_get_state, memorystatus_control, quotactl, csrctl, __persona,
/// madvise advice, setattrlist.
@Suite struct SystemControlTests {
    let s = Env.scratch + 0x1000

    @Test func threadGetStateOfTheCaller() throws {
        let env = try Env()
        var f = TrapFrame()
        f.x[20] = 0x2020
        f.elr = 0x1_0000_4444
        f.spEL0 = 0x16FD_F000
        try env.put(le32(68), at: s + 0x400)
        env.svc(0x7963_2011, [UInt64(WellKnownPort.thread), 6, s, s + 0x400], frame: &f)
        #expect(f.x[0] == 0)
        let st = try env.space.read(va: s, count: 272)
        #expect(st.readLE(UInt64.self, at: 0) == UInt64(WellKnownPort.thread))      // x0 at entry
        #expect(st.readLE(UInt64.self, at: 8 * 20) == 0x2020)
        #expect(st.readLE(UInt64.self, at: 248) == 0x16FD_F000 && st.readLE(UInt64.self, at: 256) == 0x1_0000_4444)
        #expect(try env.u32(s + 0x400) == 68)
        // Too small a count, an unknown flavor, a non-thread name.
        try env.put(le32(10), at: s + 0x400)
        #expect(env.svc(0x7963_2011, [UInt64(WellKnownPort.thread), 6, s, s + 0x400]).1.x[0] == 4)
        try env.put(le32(200), at: s + 0x400)
        #expect(env.svc(0x7963_2011, [UInt64(WellKnownPort.thread), 17, s, s + 0x400]).1.x[0] == 4)
        #expect(env.svc(0x7963_2011, [UInt64(WellKnownPort.task), 6, s, s + 0x400]).1.x[0] == 4)
        // The unified flavor carries its header.
        #expect(env.svc(0x7963_2011, [UInt64(WellKnownPort.thread), 1, s, s + 0x400]).1.x[0] == 0)
        #expect(try env.u32(s) == 6 && env.u32(s + 4) == 68 && env.u32(s + 0x400) == 70)
    }

    @Test func threadExceptionPorts() throws {
        let env = try Env()
        let thread = UInt64(WellKnownPort.thread), task = UInt64(WellKnownPort.task)
        let get: UInt64 = 0x7963_2012, set: UInt64 = 0x7963_2013
        // masks s, count s+0x100, ports s+0x200, behaviors s+0x300, flavors s+0x400
        func getAll() -> UInt64 {
            try? env.put(le32(14), at: s + 0x100)
            return env.svc(get, [thread, 0x3FFE, s, s + 0x100, s + 0x200, s + 0x300, s + 0x400]).1.x[0]
        }
        #expect(getAll() == 0)
        #expect(try env.u32(s + 0x100) == 0)                                  // nothing set
        #expect(env.svc(set, [thread, 0x6, task, 1, 6]).1.x[0] == 0)
        #expect(getAll() == 0)
        #expect(try env.u32(s + 0x100) == 2)
        #expect(try env.u32(s) == 0x6 && env.u32(s + 4) == 0x3FF8)             // grouped by port
        #expect(try env.u32(s + 0x200) != 0 && env.u32(s + 0x204) == 0)
        #expect(try env.u32(s + 0x300) == 1 && env.u32(s + 0x400) == 6)
        #expect(env.svc(set, [thread, 0x2, task, 99, 6]).1.x[0] == 4)          // bad behavior
        #expect(env.svc(set, [thread, 0x1, task, 1, 6]).1.x[0] == 4)           // bad mask
        #expect(env.svc(set, [task, 0x2, task, 1, 6]).1.x[0] == 4)             // not a thread
    }

    @Test func controlsAnsweredAsOnTheMac() throws {
        let env = try Env()
        #expect(env.svc(440, [1, 100, 0, 0, 0]).1.x[0] == 1)        // memorystatus_control: EPERM
        #expect(env.svc(440, [18, 100, 0, 0, 0]).1.x[0] == 22)      // freezer: EINVAL
        #expect(env.svc(165, [s, 0x300, 501, 0]).1.x[0] == 45)      // quotactl: ENOTSUP
        try env.put(le32(0x10), at: s)
        #expect(env.svc(483, [0, s, 4]).1.x[0] == 1)                // csr_check: EPERM
        try env.put(le32(0xFFFF), at: s)
        #expect(!env.svc(483, [1, s, 4]).1.carry)                   // active config
        #expect(try env.u32(s) == 0)
        try env.put(le32(1), at: s + 8)
        #expect(env.svc(494, [6, 0, s + 0x100, s, s + 8, 0]).1.x[0] == 3)  // PIDINFO: ESRCH
        #expect(env.svc(494, [1, 0, s + 0x100, s, s + 8, 0]).1.x[0] == 1)  // ALLOC: EPERM
        #expect(!env.svc(494, [7, 0, s + 0x100, s, s + 8, 0]).1.carry)    // FIND: none
        #expect(try env.u64(s + 8) == 0)
        #expect(!env.svc(75, [Env.scratch, 0x4000, 3]).1.carry)    // madvise WILLNEED
        #expect(env.svc(75, [Env.scratch, 0x4000, 99]).1.x[0] == 22)
        // MADV_ZERO: the range reads as zeros.
        try env.put([1, 2, 3, 4], at: s + 0x800)
        #expect(!env.svc(75, [s + 0x800, 4, 11]).1.carry)
        #expect(try env.space.read(va: s + 0x800, count: 4) == [0, 0, 0, 0])
    }

    @Test func setAttributeList() throws {
        let env = try ProcEnv()
        let k = env.rootKernel!
        let at = ProcEnv.At.out
        let file = env.root + "/f"
        try Data("x".utf8).write(to: URL(fileURLWithPath: file))
        env.putString(k, file, at: at)
        // MODTIME | FNDRINFO | ACCESSMASK
        var alist = [UInt8](repeating: 0, count: 24)
        alist.putLE(UInt16(5), at: 0)
        alist.putLE(UInt32(0x400 | 0x4000 | 0x20000), at: 4)
        env.put(k, alist, at: at + 0x200)
        var buf: [UInt8] = []
        buf.appendLE(Int64(3_000_000)); buf.appendLE(Int64(0))
        var finder = [UInt8](repeating: 0, count: 32)
        finder[0] = 0x54
        buf += finder
        buf.appendLE(UInt32(0o600))
        env.put(k, buf, at: at + 0x300)
        #expect(env.bsd(k, 221, [at, at + 0x200, at + 0x300, UInt64(buf.count), 0]) == 0)
        let attrs = try FileManager.default.attributesOfItem(atPath: file)
        #expect(Int((attrs[.modificationDate] as! Date).timeIntervalSince1970) == 3_000_000)
        #expect((attrs[.posixPermissions] as! Int) == 0o600)
        // getattrlist reads the Finder info back.
        alist.putLE(UInt32(0x4000), at: 4)
        env.put(k, alist, at: at + 0x200)
        #expect(env.bsd(k, 220, [at, at + 0x200, at + 0x400, 64, 0]) == 0)
        #expect(env.read(k, at + 0x404, 1) == [0x54])
        // A non-settable attribute: EINVAL; a volume rename: EROFS; short buffer: EINVAL.
        alist.putLE(UInt32(0x1), at: 4)
        env.put(k, alist, at: at + 0x200)
        #expect(env.bsd(k, 221, [at, at + 0x200, at + 0x300, 64, 0]) == -22)
        alist.putLE(UInt32(0), at: 4)
        alist.putLE(UInt32(0x8000_2000), at: 8)
        env.put(k, alist, at: at + 0x200)
        #expect(env.bsd(k, 221, [at, at + 0x200, at + 0x300, 64, 0]) == -30)
        alist.putLE(UInt32(0x400), at: 4)
        alist.putLE(UInt32(0), at: 8)
        env.put(k, alist, at: at + 0x200)
        #expect(env.bsd(k, 221, [at, at + 0x200, at + 0x300, 8, 0]) == -22)
    }
}
