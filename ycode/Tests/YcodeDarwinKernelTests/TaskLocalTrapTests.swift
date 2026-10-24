import Foundation
import Testing
import YcodeDarwinABI
@testable import YcodeDarwinKernel

/// Task-local traps (`handleTaskLocal`, boot-profile.md §3.6): the same
/// answers as the locked path, without the kernel lock.
@Suite(.serialized) struct TaskLocalTrapTests {
    /// Runs `body` with the switch on, then restores it.
    private func withSwitch(_ body: () throws -> Void) rethrows {
        let saved = DarwinKernel.taskLocalTrapsEnabled
        DarwinKernel.taskLocalTrapsEnabled = true
        defer { DarwinKernel.taskLocalTrapsEnabled = saved }
        try body()
    }

    private func fast(_ env: Env, _ x16: UInt64, _ args: [UInt64]) -> (DarwinKernel.Outcome?, TrapFrame) {
        var f = TrapFrame()
        f.kind = TrapFrame.Kind.svc.rawValue
        f.x[16] = x16
        for (i, v) in args.enumerated() { f.x[i] = v }
        let o = env.kernel.handleTaskLocal(&f, context: env.kernel.mainThread, memory: env.space)
        return (o, f)
    }

    @Test func statMatchesTheLockedPath() throws {
        try withSwitch {
            let env = try Env()
            env.kernel.tracing = false
            _ = env.svc(20)  // getpid: binds the main thread to the image
            let path = try env.makeFile("file.txt", [1, 2, 3, 4, 5])
            let pathVA = Env.scratch + 0x100, locked = Env.scratch + 0x1000, unlocked = Env.scratch + 0x2000
            try env.putString(path, at: pathVA)

            let (lo, lf) = env.svc(338, [pathVA, locked])
            #expect(lo == .resume && !lf.carry)
            let (o, f) = fast(env, 338, [pathVA, unlocked])
            #expect(o == .resume && !f.carry && f.x[0] == 0)
            #expect(try env.space.read(va: unlocked, count: 144) == env.space.read(va: locked, count: 144))

            // A missing path: the same errno (ENOENT) with carry.
            try env.putString(env.root + "/missing", at: pathVA)
            let (_, lf2) = env.svc(340, [pathVA, locked])
            let (o2, f2) = fast(env, 340, [pathVA, unlocked])
            #expect(o2 == .resume && f2.carry && lf2.carry && f2.x[0] == lf2.x[0] && f2.x[0] == 2)
        }
    }

    /// Cache-only image files (app-launch.md §3.5): a guest `stat` sees
    /// them on both paths; the loader's helper stub (a PC in the host page)
    /// does not.
    @Test func cacheImageFilesAreHiddenFromTheLoaderHelper() throws {
        try withSwitch {
            let env = try Env()
            env.kernel.tracing = false
            _ = env.svc(20)
            try FileManager.default.createDirectory(atPath: env.root + "/Lib.framework", withIntermediateDirectories: true)
            env.kernel.fileSystem.cacheImageFiles = CacheImageFiles(runtimeRoot: env.root,
                                                                    imagePaths: { ["/Lib.framework/Lib"] })
            let pathVA = Env.scratch + 0x100, buf = Env.scratch + 0x1000
            try env.putString(env.root + "/Lib.framework/Lib", at: pathVA)
            for loader in [false, true] {
                var lf = TrapFrame()
                if loader { lf.elr = VMLayout.hostPageVA + 0x120 }
                _ = env.svc(338, [pathVA, buf], frame: &lf)
                var tf = TrapFrame()
                tf.kind = TrapFrame.Kind.svc.rawValue
                tf.x[16] = 338; tf.x[0] = pathVA; tf.x[1] = buf
                if loader { tf.elr = VMLayout.hostPageVA + 0x120 }
                #expect(env.kernel.handleTaskLocal(&tf, context: env.kernel.mainThread, memory: env.space) == .resume)
                #expect(lf.carry == loader && tf.carry == loader)
                if loader { #expect(lf.x[0] == 2 && tf.x[0] == 2) }
            }
            // A PC just past the stub code is an ordinary caller.
            #expect(!DarwinKernel.isLoaderHelper(pc: VMLayout.hostPageVA + VMLayout.hostPageCodeSize))
            #expect(DarwinKernel.isLoaderHelper(pc: VMLayout.hostPageVA))
        }
    }

    @Test func vmCallsMatchTheLockedPath() throws {
        try withSwitch {
            let env = try Env()
            env.kernel.tracing = false
            _ = env.svc(20)
            let slot = Env.scratch + 0x100
            try env.put(leBytes(0), at: slot)
            // vm_allocate anywhere.
            let (o, f) = fast(env, UInt64(bitPattern: -10), [0x103, slot, 0x6000, 1])
            #expect(o == .resume && f.x[0] == 0)
            let va = try env.u64(slot)
            #expect(va >= 0x3_2000_0000 && va & 0x3FFF == 0)
            #expect(env.space.region(containing: va)?.size == 0x8000)
            // A fixed address goes to the locked path.
            let (fixed, _) = fast(env, UInt64(bitPattern: -10), [0x103, slot, 0x4000, 0])
            #expect(fixed == nil)
            // vm_protect (current protection), and set_maximum to the locked path.
            let (po, pf) = fast(env, UInt64(bitPattern: -14), [0x103, va, 0x4000, 0, 0x11])
            #expect(po == .resume && pf.x[0] == 0 && env.space.region(containing: va)?.protection == .read)
            #expect(fast(env, UInt64(bitPattern: -14), [0x103, va, 0x4000, 1, 0x7]).0 == nil)
            // vm_protect of an unmapped range: KERN_INVALID_ADDRESS, as locked.
            let (_, bad) = fast(env, UInt64(bitPattern: -14), [0x103, 0x7_0000_0000, 0x4000, 0, 0x3])
            #expect(bad.x[0] == 1)
            // vm_deallocate.
            let (d, df) = fast(env, UInt64(bitPattern: -12), [0x103, va, 0x8000])
            #expect(d == .resume && df.x[0] == 0 && env.space.region(containing: va) == nil)
            // A bad address pointer: KERN_INVALID_ADDRESS.
            #expect(fast(env, UInt64(bitPattern: -10), [0x103, 0x8, 0x4000, 1]).1.x[0] == 1)
            // Tracing and other traps: the locked path.
            #expect(fast(env, 20, []).0 == nil)
            env.kernel.tracing = true
            #expect(fast(env, 338, [slot, slot]).0 == nil)
        }
    }

    @Test func madviseMatchesTheLockedPath() throws {
        try withSwitch {
            let saved = DarwinKernel.taskLocalMadviseEnabled
            DarwinKernel.taskLocalMadviseEnabled = true
            defer { DarwinKernel.taskLocalMadviseEnabled = saved }
            let env = try Env()
            env.kernel.tracing = false
            _ = env.svc(20)
            let va = Env.scratch + 0x4000
            // Hints (MADV_FREE = 5, MADV_DONTNEED = 4): 0, no change.
            try env.put([1, 2, 3, 4], at: va)
            for advice: UInt64 in [0, 4, 5, 9] {
                let (lo, lf) = env.svc(75, [va, 0x4000, advice])
                let (o, f) = fast(env, 75, [va, 0x4000, advice])
                #expect(lo == .resume && o == .resume)
                #expect(f.carry == lf.carry && f.x[0] == lf.x[0] && f.x[1] == lf.x[1] && !f.carry && f.x[0] == 0)
            }
            #expect(try env.space.read(va: va, count: 4) == [1, 2, 3, 4])
            // MADV_ZERO (11): the range reads as zeros.
            let (zo, zf) = fast(env, 75, [va, 0x10, 11])
            #expect(zo == .resume && !zf.carry && zf.x[0] == 0)
            #expect(try env.space.read(va: va, count: 4) == [0, 0, 0, 0])
            // Bad advice and an overflowing range: EINVAL with carry, as locked.
            for args: [UInt64] in [[va, 0x4000, 12], [UInt64.max - 0xF, 0x100, 11]] {
                let (_, lf) = env.svc(75, args)
                let (o, f) = fast(env, 75, args)
                #expect(o == .resume && f.carry && lf.carry && f.x[0] == lf.x[0] && f.x[0] == 22)
            }
            // MADV_ZERO of unmapped memory: ENOMEM, as locked.
            let (_, lf) = env.svc(75, [0x7_0000_0000, 0x4000, 11])
            let (_, f) = fast(env, 75, [0x7_0000_0000, 0x4000, 11])
            #expect(f.carry && lf.carry && f.x[0] == lf.x[0] && f.x[0] == 12)
            // The switch off: the locked path.
            DarwinKernel.taskLocalMadviseEnabled = false
            #expect(fast(env, 75, [va, 0x4000, 5]).0 == nil)
            #expect(!DarwinKernel.isTaskLocalTrap(75))
        }
    }

    @Test func offWithoutTheSwitchOrForAnotherImagesThread() throws {
        let env = try Env()
        env.kernel.tracing = false
        let saved = DarwinKernel.taskLocalTrapsEnabled
        defer { DarwinKernel.taskLocalTrapsEnabled = saved }
        DarwinKernel.taskLocalTrapsEnabled = false
        #expect(fast(env, UInt64(bitPattern: -12), [0x103, Env.scratch, 0x4000]).0 == nil)
        DarwinKernel.taskLocalTrapsEnabled = true
        // A thread bound to another image is never served here.
        let other = try Env()
        var f = TrapFrame()
        f.kind = TrapFrame.Kind.svc.rawValue
        f.x[16] = UInt64(bitPattern: -12)
        #expect(env.kernel.handleTaskLocal(&f, context: other.kernel.mainThread, memory: env.space) == nil)
    }
}
