import Testing
@testable import YcodeDarwinABI

/// Guest memory as one flat range of bytes at `base`.
private struct FakeMemory: GuestMemoryAccess {
    var base: UInt64
    var bytes: [UInt8]

    func read(va: UInt64, count: Int) throws -> [UInt8] {
        guard va >= base, va - base + UInt64(count) <= UInt64(bytes.count) else {
            throw GuestMemoryError.unmapped(va: va)
        }
        let o = Int(va - base)
        return Array(bytes[o..<(o + count)])
    }

    func write(va: UInt64, bytes: [UInt8]) throws { throw GuestMemoryError.accessDenied(va: va) }
}

private final class Capture {
    var out = ""
    var err = ""
    var log: [String] = []
}

private let hello = Array("hello from EL0 (Darwin ABI on KVM)\n".utf8)
private let memory = FakeMemory(base: 0x1_0000_4000, bytes: hello + [UInt8](repeating: 0, count: 64))

private func dispatcher(_ c: Capture, clock: @escaping () -> UInt64 = MachTimebase.now) -> DarwinTrapDispatcher {
    DarwinTrapDispatcher(pid: 100, stdout: { c.out += $0 }, stderr: { c.err += $0 }, log: { c.log.append($0) },
                         machAbsoluteTime: clock)
}

/// An SVC frame with `x16` = `number` and the given arguments.
private func svc(_ number: Int64, _ args: UInt64..., spsr: UInt64 = 0) -> TrapFrame {
    var x = [UInt64](repeating: 0xCAFE, count: 31)
    for (i, a) in args.enumerated() { x[i] = a }
    x[16] = UInt64(bitPattern: number)
    return TrapFrame(x: x, spEL0: 0x1_6FFF_FF00, elr: 0x1_0000_0024, spsr: spsr, esr: 0x5600_0080, kind: 1)
}

@Suite struct DispatcherTests {
    @Test func exitStatus() {
        let c = Capture()
        var d = dispatcher(c)
        var f = svc(1, 0)
        #expect(d.handle(&f, memory: memory) == .exit(status: 0))
        f = svc(1, 3)
        #expect(d.handle(&f, memory: memory) == .exit(status: 3))
        f = svc(1, 0x1FF)
        #expect(d.handle(&f, memory: memory) == .exit(status: 255))
        f = svc(1, UInt64(bitPattern: -1))
        #expect(d.handle(&f, memory: memory) == .exit(status: 255))
        #expect(c.log.first == "trap bsd 1 exit -> exit 0")
    }

    @Test func writeStdoutAndStderr() {
        let c = Capture()
        var d = dispatcher(c)
        var f = svc(4, 1, 0x1_0000_4000, UInt64(hello.count), spsr: AArch64.SPSR.c | 0x3C0)
        #expect(d.handle(&f, memory: memory) == .resume)
        #expect(c.out == "hello from EL0 (Darwin ABI on KVM)\n")
        #expect(f.x[0] == UInt64(hello.count))
        #expect(!f.carry)
        #expect(f.spsr == 0x3C0)
        #expect(f.elr == 0x1_0000_0024)
        #expect(c.log == ["trap bsd 4 write -> 35"])

        f = svc(4, 2, 0x1_0000_4006, 4)
        #expect(d.handle(&f, memory: memory) == .resume)
        #expect(c.err == "from")
        #expect(f.x[0] == 4 && !f.carry)
        #expect(c.out == "hello from EL0 (Darwin ABI on KVM)\n")
    }

    @Test(arguments: [UInt64(0), 3, 100, UInt64(bitPattern: -1)])
    func writeOtherFdIsEBADF(fd: UInt64) {
        let c = Capture()
        var d = dispatcher(c)
        var f = svc(4, fd, 0x1_0000_4000, 5)
        #expect(d.handle(&f, memory: memory) == .resume)
        #expect(f.x[0] == 9)
        #expect(f.carry)
        #expect(c.out.isEmpty && c.err.isEmpty)
        #expect(c.log == ["trap bsd 4 write -> error 9 (EBADF)"])
    }

    @Test func writeEdgeCases() {
        let c = Capture()
        var d = dispatcher(c)
        // Zero length: success, nothing read.
        var f = svc(4, 1, 0xDEAD_0000, 0)
        #expect(d.handle(&f, memory: memory) == .resume)
        #expect(f.x[0] == 0 && !f.carry)
        // Unreadable buffer: EFAULT.
        f = svc(4, 1, 0xDEAD_0000, 4)
        #expect(d.handle(&f, memory: memory) == .resume)
        #expect(f.x[0] == 14 && f.carry)
        // Absurd length: EINVAL.
        f = svc(4, 1, 0x1_0000_4000, 1 << 40)
        #expect(d.handle(&f, memory: memory) == .resume)
        #expect(f.x[0] == 22 && f.carry)
        #expect(c.out.isEmpty)
    }

    @Test func getpid() {
        let c = Capture()
        var d = dispatcher(c)
        var f = svc(20, spsr: AArch64.SPSR.c)
        #expect(d.handle(&f, memory: memory) == .resume)
        #expect(f.x[0] == 100)
        #expect(!f.carry)
        #expect(c.log == ["trap bsd 20 getpid -> 100"])
        d.pid = 4242
        f = svc(20)
        _ = d.handle(&f, memory: memory)
        #expect(f.x[0] == 4242)
    }

    @Test func unknownPositiveIsENOSYS() {
        let c = Capture()
        var d = dispatcher(c)
        for n: Int64 in [9999, 2, 669, 0, 0x7FFF_FFFF] {
            var f = svc(n, 7)
            #expect(d.handle(&f, memory: memory) == .resume)
            #expect(f.x[0] == 78)
            #expect(f.carry)
            #expect(f.x[1] == 0xCAFE)
        }
        #expect(c.log.first == "trap bsd 9999 unimplemented -> error 78 (ENOSYS)")
    }

    @Test func machTime() {
        let c = Capture()
        var d = dispatcher(c)
        var a = svc(-3, spsr: AArch64.SPSR.c)
        var b = svc(-3)
        #expect(d.handle(&a, memory: memory) == .resume)
        #expect(d.handle(&b, memory: memory) == .resume)
        #expect(a.x[0] != 0)
        #expect(b.x[0] >= a.x[0])
        // No carry semantics: the flag is left as it was.
        #expect(a.carry)
        #expect(!b.carry)
        var cont = svc(-4)
        #expect(d.handle(&cont, memory: memory) == .resume)
        #expect(cont.x[0] >= b.x[0])
        #expect(c.log[0].hasPrefix("trap mach -3 mach_absolute_time -> "))
        #expect(c.log[2].hasPrefix("trap mach -4 mach_continuous_time -> "))
    }

    @Test func machTimeUsesInjectedClock() {
        let c = Capture()
        var d = dispatcher(c, clock: { 24_000_000 })
        var f = svc(-4)
        _ = d.handle(&f, memory: memory)
        #expect(f.x[0] == 24_000_000)
        #expect(c.log == ["trap mach -4 mach_continuous_time -> 24000000"])
    }

    @Test func timebase() {
        #expect(MachTimebase.ticks(fromNanoseconds: 1_000_000_000) == 24_000_000)
        #expect(MachTimebase.ticks(fromNanoseconds: 125) == 3)
        #expect(MachTimebase.ticks(fromNanoseconds: 124) == 2)
        #expect(MachTimebase.nanoseconds(fromTicks: 24_000_000) == 1_000_000_000)
        #expect(MachTimebase.nanoseconds(fromTicks: 3) == 125)
        // No overflow near the top of the range.
        #expect(MachTimebase.ticks(fromNanoseconds: UInt64.max) == UInt64.max / 125 * 3 + (UInt64.max % 125) * 3 / 125)
        let t0 = MachTimebase.now()
        let t1 = MachTimebase.now()
        #expect(t0 > 0 && t1 >= t0)
    }

    @Test(arguments: [Int64(-1), -26, -31, -100, -0x7FFF_FFFF, Int64(Int32.min)])
    func unknownNegative(n: Int64) {
        let c = Capture()
        var d = dispatcher(c)
        for carry in [false, true] {
            var f = svc(n, 55, spsr: carry ? AArch64.SPSR.c : 0)
            #expect(d.handle(&f, memory: memory) == .resume)
            #expect(f.x[0] == 0x1)
            #expect(f.carry == carry)
        }
    }

    @Test func trapNumberClassification() {
        #expect(DarwinTrapNumber(x16: 20) == .bsd(20))
        #expect(DarwinTrapNumber(x16: UInt64(bitPattern: -3)) == .mach(-3))
        // Only the low 32 bits count.
        #expect(DarwinTrapNumber(x16: 0xFFFF_FFFD) == .mach(-3))
        #expect(DarwinTrapNumber(x16: 0x1_0000_0014) == .bsd(20))
        #expect(DarwinTrapNumber(x16: 0x8000_0000) == .platform)
        let c = Capture()
        var d = dispatcher(c)
        var f = svc(0x8000_0000)
        _ = d.handle(&f, memory: memory)
        #expect(f.x[0] == 1)
        // x16 = 0xFFFF_FFFD with garbage in the high half is still mach_absolute_time.
        f = svc(Int64(bitPattern: 0xABCD_0000_FFFF_FFFD))
        _ = d.handle(&f, memory: memory)
        #expect(f.x[0] > 1)
    }

    @Test(arguments: [UInt64(2), 3, 4, 0, 9])
    func nonSVCKindsAreFatal(kind: UInt64) throws {
        let c = Capture()
        var d = dispatcher(c)
        var f = TrapFrame(elr: 0x1_0000_0010, esr: 0x9200_0047, far: 0x1234_5678, kind: kind)
        let before = f
        let outcome = d.handle(&f, memory: memory)
        guard case let .fatal(message) = outcome else {
            Issue.record("expected .fatal, got \(outcome)")
            return
        }
        #expect(message.contains("EC=0x24"))
        #expect(message.contains("data abort from a lower EL"))
        #expect(message.contains("IL=1"))
        #expect(message.contains("ISS=0x47"))
        #expect(message.contains("FAR=0x0000000012345678"))
        #expect(message.contains("ELR=0x0000000100000010"))
        #expect(message.contains("x16="))
        #expect(f == before)
        #expect(c.log.count == 1)
    }

    @Test func fatalKindNames() {
        let c = Capture()
        var d = dispatcher(c)
        var f = TrapFrame(esr: UInt64(0x3C) << 26 | 1 << 25, kind: 4)
        guard case let .fatal(m) = d.handle(&f, memory: memory) else { Issue.record("not fatal"); return }
        #expect(m.hasPrefix("synchronous exception at EL1: EC=0x3c (BRK (AArch64))"))
    }

    /// Runs the §7 self-test sequence against the dispatcher, with the guest
    /// memory reached through real page tables.
    @Test func selfTestSequence() throws {
        var tables = PageTableBuilder()
        for r in VMLayout.el1Regions { try tables.mapIdentity(r) }
        var ram = [UInt8](repeating: 0, count: 0x4000 * 8)
        let data = hello
        ram.replaceSubrange(0x4000..<(0x4000 + data.count), with: data)
        var pool: UInt64 = VMLayout.el0PoolGPA
        for r in VMLayout.selfTestRegions(imageSize: 0x4000 + UInt64(data.count)) {
            try tables.map(va: r.va, pa: pool, size: r.size, attributes: r.attributes)
            pool += r.size
        }
        let ramCopy = ram
        let mem = TranslatingGuestMemory(
            pageTables: tables,
            readPhysical: { pa, n in
                let o = Int(pa - VMLayout.el0PoolGPA)
                return Array(ramCopy[o..<(o + n)])
            },
            writePhysical: { _, _ in })

        let c = Capture()
        var d = dispatcher(c)
        var f = svc(20)
        #expect(d.handle(&f, memory: mem) == .resume && f.x[0] == 100 && !f.carry)
        f = svc(9999)
        #expect(d.handle(&f, memory: mem) == .resume && f.x[0] == 78 && f.carry)
        f = svc(4, 1, VMLayout.selfTestDataVA, UInt64(data.count))
        #expect(d.handle(&f, memory: mem) == .resume && f.x[0] == UInt64(data.count) && !f.carry)
        #expect(c.out == "hello from EL0 (Darwin ABI on KVM)\n")
        // EL1-only memory is not a valid user buffer.
        f = svc(4, 1, VMLayout.bootInfoGPA, 8)
        #expect(d.handle(&f, memory: mem) == .resume && f.x[0] == 14 && f.carry)
        f = svc(1, 0)
        #expect(d.handle(&f, memory: mem) == .exit(status: 0))
    }
}
