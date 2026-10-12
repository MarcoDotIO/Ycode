import Foundation
import Testing
@testable import YcodeMachO

/// Builds small Mach-O images byte by byte, following
/// specs/formats/macho-and-dyld-cache.md, so the parser is tested without any
/// Apple binary.
private struct Builder {
    var bytes: [UInt8] = []

    mutating func u32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { bytes += $0 } }
    mutating func u64(_ v: UInt64) { withUnsafeBytes(of: v.littleEndian) { bytes += $0 } }
    mutating func u32BE(_ v: UInt32) { withUnsafeBytes(of: v.bigEndian) { bytes += $0 } }
    mutating func name16(_ s: String) {
        var b = Array(s.utf8.prefix(16))
        b += Array(repeating: 0, count: 16 - b.count)
        bytes += b
    }

    /// A load command with a trailing string, padded to 8 bytes.
    static func stringCommand(_ cmd: UInt32, fixed: [UInt32], string: String) -> [UInt8] {
        var b = Builder()
        let header = 8 + 4 + fixed.count * 4
        var s = Array(string.utf8) + [0]
        while (header + s.count) % 8 != 0 { s.append(0) }
        b.u32(cmd)
        b.u32(UInt32(header + s.count))
        b.u32(UInt32(header))  // string offset
        for f in fixed { b.u32(f) }
        b.bytes += s
        return b.bytes
    }

    static func image(fileType: UInt32 = 2, commands: [[UInt8]], cpu: UInt32 = MachO.cpuTypeARM64) -> [UInt8] {
        var b = Builder()
        b.u32(MachO.magic64); b.u32(cpu); b.u32(0); b.u32(fileType)
        b.u32(UInt32(commands.count)); b.u32(UInt32(commands.reduce(0) { $0 + $1.count })); b.u32(0x0020_0085); b.u32(0)
        for c in commands { b.bytes += c }
        return b.bytes
    }

    static func segment(_ name: String, vm: UInt64, size: UInt64, prot: UInt32, sections: [String] = []) -> [UInt8] {
        var b = Builder()
        b.u32(0x19); b.u32(UInt32(72 + sections.count * 80))
        b.name16(name); b.u64(vm); b.u64(size); b.u64(0); b.u64(size); b.u32(prot); b.u32(prot)
        b.u32(UInt32(sections.count)); b.u32(0)
        for (i, s) in sections.enumerated() {
            b.name16(s); b.name16(name); b.u64(vm + UInt64(i) * 16); b.u64(16); b.u32(0); b.u32(2)
            b.u32(0); b.u32(0); b.u32(0x8000_0400); b.u32(0); b.u32(0); b.u32(0)
        }
        return b.bytes
    }
}

@Suite struct MachOImageTests {
    private func sampleExecutable() -> [UInt8] {
        var build = Builder(); build.u32(0x32); build.u32(24); build.u32(7); build.u32(0x001B_0100); build.u32(0x001B_0100); build.u32(0)
        var uuid = Builder(); uuid.u32(0x1B); uuid.u32(24); uuid.bytes += Array(0..<16)
        var main = Builder(); main.u32(0x8000_0028); main.u32(24); main.u64(0x4000); main.u64(0)
        var sig = Builder(); sig.u32(0x1D); sig.u32(16); sig.u32(0x8000); sig.u32(0x200)
        return Builder.image(commands: [
            Builder.segment("__PAGEZERO", vm: 0, size: 0x1_0000_0000, prot: 0),
            Builder.segment("__TEXT", vm: 0x1_0000_0000, size: 0x8000, prot: 5, sections: ["__text", "__stubs"]),
            Builder.stringCommand(0x0E, fixed: [], string: "/usr/lib/dyld"),
            Builder.stringCommand(0x0C, fixed: [2, 0x0547_0000, 0x0001_0000], string: "/usr/lib/libSystem.B.dylib"),
            Builder.stringCommand(0x8000_0018, fixed: [2, 0x0001_0203, 0x0001_0000], string: "/usr/lib/libweak.dylib"),
            Builder.stringCommand(0x8000_001C, fixed: [], string: "@executable_path/Frameworks"),
            build.bytes, uuid.bytes, main.bytes, sig.bytes,
        ])
    }

    @Test func parsesExecutable() throws {
        let image = try MachOImage(ByteReader(Data(sampleExecutable())))
        #expect(image.isArm64)
        #expect(image.fileType == .executable)
        #expect(image.segments.map(\.name) == ["__PAGEZERO", "__TEXT"])
        #expect(image.segment(named: "__TEXT")?.sections.map(\.name) == ["__text", "__stubs"])
        #expect(image.segment(named: "__TEXT")?.initialProtection.description == "r-x")
        #expect(image.dylinker == "/usr/lib/dyld")
        #expect(image.dylibs.map(\.path) == ["/usr/lib/libSystem.B.dylib", "/usr/lib/libweak.dylib"])
        #expect(image.dylibs.map(\.kind) == [.normal, .weak])
        #expect(image.dylibs[0].currentVersion.description == "1351.0")
        #expect(image.dylibs[1].currentVersion.description == "1.2.3")
        #expect(image.rpaths == ["@executable_path/Frameworks"])
        #expect(image.buildVersion?.platform == .iOSSimulator)
        #expect(image.buildVersion?.minOS.description == "27.1")
        #expect(image.uuid?.uuidString == "00010203-0405-0607-0809-0A0B0C0D0E0F")
        #expect(image.entryOffset == 0x4000)
        #expect(image.codeSignature == .init(offset: 0x8000, size: 0x200))
        #expect(!image.isEncrypted)
    }

    @Test func detectsEncryptedImages() throws {
        var enc = Builder(); enc.u32(0x2C); enc.u32(24); enc.u32(0x4000); enc.u32(0x1000); enc.u32(1); enc.u32(0)
        #expect(try MachOImage(ByteReader(Data(Builder.image(commands: [enc.bytes])))).isEncrypted)
    }

    @Test func universalFilesExposeSlices() throws {
        let arm = Builder.image(commands: [])
        let x86 = Builder.image(commands: [], cpu: MachO.cpuTypeX86_64)
        var fat = Builder()
        fat.u32BE(MachO.fatMagic); fat.u32BE(2)
        let first = 4096, second = 8192
        for (cpu, off, len) in [(MachO.cpuTypeX86_64, first, x86.count), (MachO.cpuTypeARM64, second, arm.count)] {
            fat.u32BE(cpu); fat.u32BE(0); fat.u32BE(UInt32(off)); fat.u32BE(UInt32(len)); fat.u32BE(12)
        }
        fat.bytes += Array(repeating: 0, count: first - fat.bytes.count) + x86
        fat.bytes += Array(repeating: 0, count: second - fat.bytes.count) + arm
        let file = try MachOFile(ByteReader(Data(fat.bytes)))
        #expect(file.slices.map(\.cpuType) == [MachO.cpuTypeX86_64, MachO.cpuTypeARM64])
        #expect(try file.image().isArm64)
        #expect(try file.image(cpuType: MachO.cpuTypeX86_64).cpuType == MachO.cpuTypeX86_64)
        #expect(file.slices.map(\.name) == ["x86_64", "arm64"])
        #expect(try file.image(architecture: "arm64").isArm64)
        #expect(throws: MachOError.self) { try file.image(architecture: "arm64e") }
    }

    @Test(arguments: [
        (MachO.cpuTypeARM64, UInt32(0), "arm64"), (MachO.cpuTypeARM64, UInt32(2), "arm64e"),
        (MachO.cpuTypeARM64, UInt32(0x8000_0002), "arm64e"), (MachO.cpuTypeARM64, UInt32(0x8000_000C), "arm64.subtype12"),
        (MachO.cpuTypeX86_64, UInt32(3), "x86_64"), (MachO.cpuTypeX86_64, UInt32(8), "x86_64h"),
    ])
    func architectureNames(_ cpu: UInt32, _ sub: UInt32, _ name: String) {
        #expect(MachO.architectureName(cpuType: cpu, cpuSubtype: sub) == name)
    }

    @Test(arguments: [
        [UInt8](repeating: 0, count: 64),                         // bad magic
        Array(Builder.image(commands: []).prefix(20)),            // truncated header
    ])
    func rejectsMalformed(_ bytes: [UInt8]) {
        #expect(throws: MachOError.self) { try MachOImage(ByteReader(Data(bytes))) }
    }

    @Test func rejectsCommandOverrunningItsSize() {
        var bad = Builder.image(commands: [Builder.segment("__TEXT", vm: 0, size: 0x1000, prot: 5)])
        bad[32 + 4] = 0xF0  // cmdsize larger than sizeofcmds
        #expect(throws: MachOError.self) { try MachOImage(ByteReader(Data(bad))) }
    }

    @Test func versionsAndProtections() {
        #expect(PackedVersion(0x001B_0100).description == "27.1")
        #expect(PackedVersion(0x0001_0203) > PackedVersion(0x0001_0200))
        #expect(Protection(rawValue: 3).description == "rw-")
        #expect(Platform.iOSSimulator.isSimulator && !Platform.iOS.isSimulator)
    }
}

/// Runs against a real simulator runtime when one is available: the
/// installed iOS 27.1 runtime on macOS, or `YCODE_SIM_RUNTIME_ROOT` (for
/// example a copy on the Linux simulator host). Skipped otherwise.
@Suite struct SimulatorRuntimeTests {
    static let root: String? = {
        if let env = ProcessInfo.processInfo.environment["YCODE_SIM_RUNTIME_ROOT"] { return env }
        let mac = "/Library/Developer/CoreSimulator/Volumes/iOS_24A94401/Library/Developer/CoreSimulator/Profiles/Runtimes/iOS 27.1.simruntime/Contents/Resources/RuntimeRoot"
        return FileManager.default.fileExists(atPath: mac) ? mac : nil
    }()

    @Test(.enabled(if: root != nil, "no simulator runtime available"))
    func launchdSimIsASimulatorExecutable() throws {
        let image = try MachOFile(contentsOf: URL(fileURLWithPath: Self.root! + "/sbin/launchd_sim")).image()
        #expect(image.fileType == .executable)
        #expect(image.buildVersion?.platform == .iOSSimulator)
        #expect(image.dylibs.contains { $0.path == "/usr/lib/libSystem.B.dylib" })
        #expect(image.entryOffset != nil)
    }

    @Test(.enabled(if: root != nil, "no simulator runtime available"))
    func sharedCacheResolvesImagesAcrossSubcaches() throws {
        let cache = try SharedCache(contentsOf: URL(fileURLWithPath: Self.root! + "/System/Library/Caches/com.apple.dyld/dyld_sim_shared_cache_arm64"))
        #expect(cache.isSimulator)
        #expect(cache.platform == .iOSSimulator)
        #expect(cache.images.count > 1000)
        #expect(cache.files.count >= 2)
        let names = ["/usr/lib/libobjc.A.dylib", "/usr/lib/system/libdyld.dylib", "/System/Library/Frameworks/Foundation.framework/Foundation",
                     "/System/Library/PrivateFrameworks/UIKitCore.framework/UIKitCore"]
        for name in names {
            let img = try #require(cache.image(path: name), "\(name)")
            let macho = try cache.machO(for: img)
            #expect(macho.installName == name)
            #expect(macho.buildVersion?.platform == .iOSSimulator)
        }
        // Every image header must lie inside some mapping.
        #expect(cache.images.allSatisfy { cache.locate($0.address) != nil })
    }
}

@Suite struct DependencyClosureTests {
    @Test(.enabled(if: SimulatorRuntimeTests.root != nil, "no simulator runtime available"))
    func launchdSimClosureIsCompleteFromTheCache() throws {
        let root = SimulatorRuntimeTests.root!
        let cache = try SharedCache(contentsOf: URL(fileURLWithPath: root + "/System/Library/Caches/com.apple.dyld/dyld_sim_shared_cache_arm64"))
        var closure = DependencyClosure(root: root, cache: cache)
        try closure.resolve(executable: root + "/sbin/launchd_sim")
        #expect(closure.order.count > 40)
        #expect(closure.missing.filter(\.isFatal).isEmpty)
        #expect(closure.nodes["/usr/lib/system/libsystem_kernel.dylib"] != nil)
        #expect(closure.nodes["/usr/lib/libobjc.A.dylib"] != nil)
    }

    @Test func expandsRunpathPrefixes() {
        let c = DependencyClosure(root: "/R", cache: nil)
        #expect(c.candidates("@rpath/A.framework/A", loaderDir: "/L", exeDir: "/E", rpaths: ["/x", "/y"]) == ["/x/A.framework/A", "/y/A.framework/A"])
        #expect(c.candidates("@loader_path/../B.dylib", loaderDir: "/L/sub", exeDir: "/E", rpaths: []) == ["/L/sub/../B.dylib"])
        #expect(c.candidates("@executable_path/Frameworks/C", loaderDir: "/L", exeDir: "/E", rpaths: []) == ["/E/Frameworks/C"])
        #expect(c.candidates("/usr/lib/libz.dylib", loaderDir: "/L", exeDir: "/E", rpaths: []) == ["/usr/lib/libz.dylib"])
    }
}
