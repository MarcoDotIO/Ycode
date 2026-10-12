import Testing
@testable import YcodeDarwinKernel

@Suite struct ProcessImageTests {
    @Test func argumentBlockLayout() {
        let top: UInt64 = 0x1_6FE0_0000
        let apple = ["executable_path=/a/hello", "stack_guard=0x1", "th_port=0x203"]
        let block = KernelArgumentBlock(userStack: top, argv: ["/a/hello"], envp: ["HOME=/tmp", "X=1"],
                                        apple: apple, machHeader: 0x1_0000_0000)
        // Strings: "executable_path=/a/hello\0" (25) → 32; "/a/hello\0HOME=/tmp\0X=1\0" (23) → 24;
        // "stack_guard=0x1\0th_port=0x203\0" (30) → 32. Total 88.
        #expect(block.stringAreaAddress == top - 88)
        // Pointers: argv 2 + envp 3 + apple 4 = 9 words, + argc + mach_header.
        #expect(block.stackPointer == top - 88 - 9 * 8 - 16)
        #expect(block.bytes.count == Int(top - block.stackPointer))
        #expect(block.stackPointer % 8 == 0)

        let b = block.bytes
        let sp = block.stackPointer
        func word(_ address: UInt64) -> UInt64 { u64(b, Int(address - sp)) }
        func str(_ address: UInt64) -> String {
            String(decoding: b[Int(address - sp)...].prefix { $0 != 0 }, as: UTF8.self)
        }
        #expect(word(sp) == 0x1_0000_0000)  // mach_header slot
        #expect(word(sp + 8) == 1)  // argc
        #expect(block.argvAddress == sp + 16)
        #expect(str(word(block.argvAddress)) == "/a/hello")
        #expect(word(block.argvAddress + 8) == 0)
        #expect(block.envpAddress == sp + 32)
        #expect(str(word(block.envpAddress)) == "HOME=/tmp" && str(word(block.envpAddress + 8)) == "X=1")
        #expect(word(block.envpAddress + 16) == 0)
        #expect(block.appleAddress == sp + 56)
        #expect(word(block.appleAddress) == block.stringAreaAddress)  // apple[0] = first string
        #expect(str(word(block.appleAddress)) == "executable_path=/a/hello")
        #expect(str(word(block.appleAddress + 8)) == "stack_guard=0x1")
        #expect(str(word(block.appleAddress + 16)) == "th_port=0x203")
        #expect(word(block.appleAddress + 24) == 0)
        #expect(block.appleAddress + 32 == block.stringAreaAddress)
        // Padding: the argv string starts 8-aligned after the path; envp ends padded; last byte NUL.
        #expect(word(block.argvAddress) == block.stringAreaAddress + 32)
        #expect(word(block.appleAddress + 8) == block.stringAreaAddress + 56)
        #expect(b[b.count - 1] == 0 && b[b.count - 2] == 0)
        #expect(b[Int(block.stringAreaAddress - sp) + 25..<Int(block.stringAreaAddress - sp) + 32].allSatisfy { $0 == 0 })
    }

    @Test func appleStrings() {
        var rng = CountingRNG(state: 0)
        let a = AppleStrings(executablePath: "/x/hello", using: &rng)
        #expect(a.stackGuard == 0x1111_1111_1111_0011)
        #expect(a.strings == [
            "executable_path=/x/hello",
            "stack_guard=0x1111111111110011",
            "malloc_entropy=0x2222222222222222,0x3333333333333333",
            "ptr_munge=0x4444444444444444",
            "main_stack=0x16fe00000,0x800000,0x16f600000,0x800000",
            "th_port=0x203",
            "security_config=0x0",
        ])
        #expect(a.ptrMunge != 0)
        // A zero random value never becomes a zero munge token.
        var zero = CountingRNG(state: 0xBBBB_BBBB_BBBB_BBBC)  // the 4th value is 0
        let z = AppleStrings(executablePath: "/x", using: &zero)
        #expect(z.ptrMunge != 0 && z.strings[3] == "ptr_munge=0x" + String(z.ptrMunge, radix: 16))
        var small = CountingRNG(state: 0xFFFF_FFFF_FFFF_EEEE)  // first value: 0x1111111111110fff → guard has leading zeros
        let b = AppleStrings(executablePath: "p", using: &small)
        #expect(b.strings[1] == "stack_guard=0x" + String(repeating: "0", count: 16 - String(b.stackGuard, radix: 16).count)
            + String(b.stackGuard, radix: 16))
        #expect(b.strings[1].count == "stack_guard=0x".count + 16)
        #expect(b.stackGuard & 0xFF00 == 0)

        let env = SimulatorEnvironment.make(runtimeRoot: "/R")
        #expect(env.first == "DYLD_ROOT_PATH=/R")
        #expect(env.contains("DYLD_SHARED_CACHE_DIR=/R/System/Library/Caches/com.apple.dyld"))
        #expect(env.contains("PATH=/R/usr/bin:/R/bin") && env.contains("TMPDIR=/tmp/") && env.count == 8)
    }

    @Test func commpage() {
        let c = CommpageBuilder()
        let p = c.rwPage()
        #expect(p.count == 16384)
        #expect(String(decoding: p[0..<15], as: UTF8.self) == "commpage 64-bit" && p[15] == 0)
        let caps: UInt64 = 0x80 | 0x400 | 0x1000 | 0x2000 | 0x8000 | (1 << 16) | 0x20
        #expect(u64(p, 0x010) == caps)
        #expect(u16(p, 0x01E) == 3)
        #expect(u32(p, 0x020) == UInt32(caps))
        #expect(p[0x022] == 1)  // NCPUS, byte 2 of 0x020
        #expect(p[0x024] == 14 && p[0x025] == 14 && p[0x037] == 14)
        #expect(u16(p, 0x026) == 64)
        #expect(p[0x02F] == 1 && p[0x034] == 1 && p[0x035] == 1 && p[0x036] == 1)
        #expect(u64(p, 0x038) == 1 << 30)
        #expect(u32(p, 0x080) == 0 && u32(p, 0x084) == 0 && u64(p, 0x088) == 0)
        #expect(p[0x090] == 1 && p[0x091] == 0)
        #expect(u64(p, 0x098) == 0 && u64(p, 0x0A8) == 0 && u64(p, 0x0C0) == 0 && p[0x0C8] == 0)
        #expect((0..<5).allSatisfy { u64(p, 0x120 + 8 * $0) == 0 })  // gettimeofday tick = 0
        #expect(u64(p, 0x148) == 0xFFFF_FFFF_FFFF_FFFC)
        #expect(u64(p, 0x160) == 0)
        let ro = c.roPage()
        #expect(ro.count == 16384 && ro[0x024] == 14 && ro[0x025] == 14 && ro[0x037] == 14 && u32(ro, 0x084) == 0)
        #expect(ro.enumerated().allSatisfy { [0x24, 0x25, 0x37].contains($0.offset) || $0.element == 0 })
    }

    @Test func allImageInfos() {
        let i = DyldAllImageInfos.initial(infoArray: 0x3_1000_8300, notification: 0x3_1000_0400, simMH: 0x3_0000_0000)
        let b = i.encoded()
        #expect(b.count == 368)
        #expect(u32(b, 0) == 17 && u32(b, 4) == 1)
        #expect(u64(b, 8) == 0x3_1000_8300)
        #expect(u64(b, 16) == 0x3_1000_0400)
        #expect(b[24] == 0 && b[25] == 0)
        #expect(u64(b, 32) == 0x3_0000_0000)
        #expect(u64(b, 88) == 0 && u64(b, 96) == 0)
        #expect(u64(b, 112) == 1)
        #expect(u64(b, 152) == 0)
        let set: Set<Int> = [0, 4, 8, 16, 32, 112]
        for o in stride(from: 0, to: 368, by: 4) where !set.contains(o) && !set.contains(o - 4) {
            #expect(u32(b, o) == 0, "offset \(o)")
        }

        let s = DyldImageInfoStorage(base: 0x3_1000_8300, images: [
            .init(loadAddress: 0x1_0000_0000, path: "/a/hello", uuid: Array(1...16)),
        ])
        #expect(s.infoArrayAddress == 0x3_1000_8300 && s.infoArrayCount == 1)
        #expect(s.uuidArrayAddress == 0x3_1000_8318 && s.uuidArrayCount == 1)
        #expect(u64(s.bytes, 0) == 0x1_0000_0000)
        #expect(u64(s.bytes, 8) == 0x3_1000_8330)  // path after the two 24-byte arrays
        #expect(u64(s.bytes, 16) == 0)
        #expect(u64(s.bytes, 24) == 0x1_0000_0000 && Array(s.bytes[32..<48]) == Array(1...16))
        #expect(String(decoding: s.bytes[48...].prefix { $0 != 0 }, as: UTF8.self) == "/a/hello")
        #expect(s.bytes.count % 8 == 0 && s.bytes.count <= Int(HostPageLayout.imageInfoStorageSize))
    }

    @Test func launchBlock() {
        let args = KernelArgumentBlock(userStack: Stage3Layout.userStack, argv: ["/h"], envp: [],
                                       apple: ["executable_path=/h"], machHeader: 0x1_0000_0000)
        let l = LaunchBlock(prepareEntry: 0x3_0000_1234, arguments: args, mainMH: 0x1_0000_0000,
                            simMH: 0x3_0000_0000, simSlide: 0x3_0000_0000)
        let b = l.encoded()
        #expect(b.count == 96)
        let expected: [UInt64] = [0x3_0000_1234, 1, args.argvAddress, args.envpAddress, args.appleAddress,
                                  0x1_0000_0000, 0x3_0000_0000, 0x3_0000_0000, 0x3_1000_4000, 0x3_1000_8008,
                                  args.stackPointer, 0]
        for (i, w) in expected.enumerated() { #expect(u64(b, 8 * i) == w, "word \(i)") }
        #expect(HostPageLayout.launchBlock == 0x3_1000_8040 && HostPageLayout.allImageInfos == 0x3_1000_8100)
    }

    @Test func trapNames() {
        #expect(TrapNames.bsd.count == 558 && TrapNames.mach.count == 128)
        #expect(TrapNames.bsd(197).name == "mmap" && TrapNames.bsd(197).argumentNames.count == 6)
        #expect(TrapNames.bsd(9999).name == "nosys")
        #expect(TrapNames.mach(-31).name == "mach_msg_trap")
        #expect(TrapNames.mach(-3).name == "mach_absolute_time")
        #expect(TrapNames.mach(-200).name == "kern_invalid")
    }
}
