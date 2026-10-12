import Foundation
import Testing
import YcodeDarwinABI
@testable import YcodeDarwinKernel

/// Sandbox extensions on __mac_syscall("Sandbox", 5/6/7) (sandbox-extensions.md).
@Suite struct SandboxExtensionTests {
    @Test func issueConsumeRelease() throws {
        let env = try ProcEnv()
        let k = env.rootKernel!
        let at = ProcEnv.At.out
        let file = env.root + "/f"
        try Data("x".utf8).write(to: URL(fileURLWithPath: file))
        env.putString(k, "Sandbox", at: at)
        env.putString(k, "com.apple.app-sandbox.read", at: at + 0x20)
        env.putString(k, file, at: at + 0x100)
        // issue: {class, 0, path, flags, out}
        var arg: [UInt8] = []
        for w in [at + 0x20, 0, at + 0x100, 0, at + 0x400] { arg.appendLE(UInt64(w)) }
        env.put(k, arg, at: at + 0x300)
        #expect(env.bsd(k, 381, [at, 5, at + 0x300]) == 0)
        let raw = env.read(k, at + 0x400, 1024)
        let token = String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self)
        let fields = token.split(separator: ";", omittingEmptySubsequences: false)
        #expect(fields.count == 12 && fields[0].count == 64)
        #expect(fields[5] == "000000000000001a" && fields[6] == "com.apple.app-sandbox.read" && fields[7] == "01")
        #expect(fields[11].hasSuffix("/f"))
        // consume: {token, length, &handle}; the handle is 0.
        env.put(k, le64(0x55), at: at + 0x380)
        arg = []
        for w in [at + 0x400, UInt64(token.utf8.count + 1), at + 0x380] { arg.appendLE(UInt64(w)) }
        env.put(k, arg, at: at + 0x340)
        #expect(env.bsd(k, 381, [at, 6, at + 0x340]) == 0)
        #expect(env.read(k, at + 0x380, 8) == le64(0))
        env.putString(k, "not-a-token", at: at + 0x400)
        #expect(env.bsd(k, 381, [at, 6, at + 0x340]) == -22)
        // release: always 0. Other Sandbox calls: no policy.
        env.put(k, le64(999_999), at: at + 0x340)
        #expect(env.bsd(k, 381, [at, 7, at + 0x340]) == 0)
        #expect(env.bsd(k, 381, [at, 99, at + 0x340]) == -103)
    }

    /// chmod_extended / fchmod_extended and ffsctl (copyfile's calls).
    @Test func extendedModesAndFsctl() throws {
        let env = try ProcEnv()
        let k = env.rootKernel!
        let at = ProcEnv.At.out
        let file = env.root + "/g"
        try Data("x".utf8).write(to: URL(fileURLWithPath: file))
        env.putString(k, file, at: at)
        let none = UInt64(0xFFFF_FFFF - 100)
        #expect(env.bsd(k, 282, [at, none, none, 0o600, 0]) == 0)
        #expect((try FileManager.default.attributesOfItem(atPath: file)[.posixPermissions] as! Int) == 0o600)
        let fd = UInt64(env.bsd(k, 5, [at, 2, 0]))
        #expect(env.bsd(k, 283, [fd, none, none, 0o640, 1]) == 0)
        #expect((try FileManager.default.attributesOfItem(atPath: file)[.posixPermissions] as! Int) == 0o640)
        #expect(env.bsd(k, 283, [fd, none, none, UInt64(UInt32.max), 0]) == 0)   // mode -1: unchanged
        #expect((try FileManager.default.attributesOfItem(atPath: file)[.posixPermissions] as! Int) == 0o640)
        #expect(env.bsd(k, 245, [fd, 0x4004_4A0F, 0, 0]) == -25)               // ffsctl: ENOTTY
        #expect(env.bsd(k, 245, [999, 0x4004_4A0F, 0, 0]) == -9)               // bad fd
    }

    /// getattrlistbulk: one record per entry, names and object types.
    @Test func attributeListBulk() throws {
        let env = try ProcEnv()
        let k = env.rootKernel!
        let at = ProcEnv.At.out
        let dir = env.root + "/bulk"
        try FileManager.default.createDirectory(atPath: dir + "/sub", withIntermediateDirectories: true)
        try Data("abc".utf8).write(to: URL(fileURLWithPath: dir + "/a"))
        env.putString(k, dir, at: at)
        let fd = UInt64(env.bsd(k, 5, [at, 0x100000, 0]))  // O_RDONLY | O_DIRECTORY
        var alist = [UInt8](repeating: 0, count: 24)
        alist.putLE(UInt16(5), at: 0)
        alist.putLE(UInt32(0x8000_0000 | 0x1 | 0x8), at: 4)  // RETURNED_ATTRS | NAME | OBJTYPE
        env.put(k, alist, at: at + 0x100)
        #expect(env.bsd(k, 461, [fd, at + 0x100, at + 0x1000, 0x2000, 0]) == 2)
        let buf = env.read(k, at + 0x1000, 0x400)
        var found: [String: UInt32] = [:]
        var o = 0
        for _ in 0..<2 {
            let length = Int(buf.readLE(UInt32.self, at: o))
            #expect(length % 8 == 0 && buf.readLE(UInt32.self, at: o + 4) == 0x8000_0009)
            let refAt = o + 24
            let nameAt = refAt + Int(buf.readLE(Int32.self, at: refAt))
            let name = String(decoding: buf[nameAt...].prefix { $0 != 0 }, as: UTF8.self)
            found[name] = buf.readLE(UInt32.self, at: o + 32)
            o += length
        }
        #expect(found == ["a": 1, "sub": 2])
        #expect(env.bsd(k, 461, [fd, at + 0x100, at + 0x1000, 0x2000, 0]) == 0)  // the end
        // ATTR_CMN_ERROR comes first after the returned set (0), then NAME.
        let sub = UInt64(env.bsd(k, 5, [at, 0x100000, 0]))
        alist.putLE(UInt32(0x8000_0000 | 0x2000_0000 | 0x1 | 0x8), at: 4)
        env.put(k, alist, at: at + 0x100)
        #expect(env.bsd(k, 461, [sub, at + 0x100, at + 0x1000, 0x2000, 0]) == 2)
        let b2 = env.read(k, at + 0x1000, 64)
        #expect(b2.readLE(UInt32.self, at: 24) == 0 && b2.readLE(Int32.self, at: 28) > 0)
        alist.putLE(UInt32(0x1), at: 4)                                           // no RETURNED_ATTRS
        env.put(k, alist, at: at + 0x100)
        #expect(env.bsd(k, 461, [fd, at + 0x100, at + 0x1000, 0x2000, 0]) == -22)
    }
}
