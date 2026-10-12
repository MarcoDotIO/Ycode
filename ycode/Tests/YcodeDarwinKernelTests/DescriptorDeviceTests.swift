import Foundation
import Testing
import YcodeDarwinABI
@testable import YcodeDarwinKernel

// Stage 4c device nodes and guest links through the traps.

@Suite(.serialized) struct DescriptorDeviceTests {
    @Test func devicesThroughTheTraps() throws {
        let e = try DEnv()
        let path = DEnv.scratch + 0x100
        e.putString("/dev/null", at: path)
        let null = e.call(5, [path, 0x0100_0002, 0])  // O_RDWR | O_CLOEXEC
        #expect(null.value != nil)
        #expect(e.call(92, [null.x0, 1, 0]).value == 1)  // FD_CLOEXEC
        #expect(e.read(null.fd).0.value == 0)
        #expect(e.write(null.fd, "gone").value == 4)
        // F_GETPATH and fstat.
        #expect(e.call(92, [null.x0, 50, DEnv.scratch + 0x800]).value == 0)
        #expect(e.string(DEnv.scratch + 0x800) == "/dev/null")
        #expect(e.call(339, [null.x0, DEnv.scratch + 0x4000]).value == 0)
        let st = try #require(DarwinStat(decodingStat64: e.get(DEnv.scratch + 0x4000, 144)))
        #expect(st.fileType == DarwinStat.S_IFCHR && st.rdev == 0x0300_0002)
        // /dev/zero through readv (the file system's path).
        e.putString("/dev/zero", at: path)
        let zero = e.call(5, [path, 0, 0])
        e.put([UInt8](repeating: 0xAA, count: 8), at: DEnv.scratch + 0x2000)
        e.put(leBytes(DEnv.scratch + 0x2000) + leBytes(8), at: DEnv.scratch + 0x900)
        #expect(e.call(120, [zero.x0, DEnv.scratch + 0x900, 1]).value == 8)
        #expect(e.get(DEnv.scratch + 0x2000, 8) == [UInt8](repeating: 0, count: 8))
        // /dev/urandom.
        e.putString("/dev/urandom", at: path)
        let r = e.call(5, [path, 0, 0])
        #expect(e.call(3, [r.x0, DEnv.scratch + 0x3000, 32]).value == 32)
        // /dev/tty: ENXIO; FIONREAD on a device.
        e.putString("/dev/tty", at: path)
        #expect(e.call(5, [path, 2, 0]).errno == 6)
        #expect(e.call(54, [zero.x0, 0x4004_667F, DEnv.scratch + 0x100]).value == 0)
        // /dev/console by path writes to the console.
        e.putString("/dev/console", at: path)
        let c = e.call(5, [path, 1, 0])
        #expect(e.write(c.fd, "to console").value == 10)
        #expect(e.sink.text(1) == "to console")
    }

    @Test func devListsTheDeviceNodes() throws {
        let e = try DEnv()
        e.putString("/dev", at: DEnv.scratch + 0x100)
        let d = e.call(5, [DEnv.scratch + 0x100, 0x10_0000, 0])  // O_DIRECTORY
        #expect(d.value != nil)
        let buf = DEnv.scratch + 0x10000
        let n = try #require(e.call(344, [d.x0, buf, 0x8000, DEnv.scratch + 0x200]).value)
        var names: [String] = []
        var types: [UInt8] = []
        var off = 0
        let bytes = e.get(buf, Int(n))
        while off + 21 <= bytes.count {
            let reclen = Int(u16(bytes, off + 16)), namlen = Int(u16(bytes, off + 18))
            types.append(bytes[off + 20])
            names.append(String(decoding: bytes[(off + 21)..<(off + 21 + namlen)], as: UTF8.self))
            off += reclen
        }
        let devices = names.filter { $0 != "." && $0 != ".." }
        #expect(Set(devices) == ["null", "zero", "random", "urandom", "console", "tty"])
        #expect(types.count == names.count)
    }

    @Test func readlinkAndGuestLinks() throws {
        let e = try DEnv()
        try FileManager.default.createDirectory(atPath: e.writable + "/private-tmp", withIntermediateDirectories: true)
        // (Not "/tmp": the test directory itself lives under the host's /tmp on Linux.)
        e.kernel.fileSystem.guestSymlinks = ["/ylink": e.writable + "/private-tmp"]
        e.putString("/ylink", at: DEnv.scratch + 0x100)
        let r = e.call(58, [DEnv.scratch + 0x100, DEnv.scratch + 0x800, 256])
        #expect(r.value == UInt64((e.writable + "/private-tmp").utf8.count))
        #expect(String(decoding: e.get(DEnv.scratch + 0x800, Int(r.x0)), as: UTF8.self) == e.writable + "/private-tmp")
        // Truncated to the buffer, no NUL.
        #expect(e.call(58, [DEnv.scratch + 0x100, DEnv.scratch + 0x800, 3]).value == 3)
        // readlinkat with AT_FDCWD; not a link: EINVAL.
        #expect(e.call(473, [UInt64(bitPattern: -2), DEnv.scratch + 0x100, DEnv.scratch + 0x800, 256]).value != nil)
        e.putString(e.writable, at: DEnv.scratch + 0x100)
        #expect(e.call(58, [DEnv.scratch + 0x100, DEnv.scratch + 0x800, 256]).errno == 22)
        // lstat says link; open through the link lands in the target.
        e.putString("/ylink/f", at: DEnv.scratch + 0x100)
        #expect(e.call(5, [DEnv.scratch + 0x100, 0x0201, 0o644]).value != nil)
        #expect(FileManager.default.fileExists(atPath: e.writable + "/private-tmp/f"))
        e.putString("/ylink", at: DEnv.scratch + 0x100)
        #expect(e.call(340, [DEnv.scratch + 0x100, DEnv.scratch + 0x4000]).value == 0)
        #expect(try #require(DarwinStat(decodingStat64: e.get(DEnv.scratch + 0x4000, 144))).isSymbolicLink)
    }
}

extension DescriptorDeviceTests {
    @Test func mkdirRmdirTraps() throws {
        let e = try DEnv()
        let p = DEnv.scratch + 0x100
        e.putString(e.writable + "/state", at: p)
        #expect(e.call(136, [p, 0o777]).value == 0)
        #expect(e.call(136, [p, 0o777]).errno == 17)  // EEXIST
        e.putString(e.writable + "/state", at: p)
        #expect(e.call(338, [p, DEnv.scratch + 0x4000]).value == 0)
        let st = try #require(DarwinStat(decodingStat64: e.get(DEnv.scratch + 0x4000, 144)))
        #expect(st.isDirectory && st.mode & 0o777 == 0o755)  // the default umask 022
        // mkdirat relative to a directory fd, unlinkat with AT_REMOVEDIR, rmdir.
        let dir = e.call(5, [p, 0x10_0000, 0])
        e.putString("sub", at: p)
        #expect(e.call(475, [dir.x0, p, 0o700]).value == 0)
        #expect(FileManager.default.fileExists(atPath: e.writable + "/state/sub"))
        e.putString(e.writable + "/state", at: p)
        #expect(e.call(137, [p]).errno == 66)  // ENOTEMPTY
        e.putString("sub", at: p)
        #expect(e.call(472, [dir.x0, p, 0x80]).value == 0)
        e.putString(e.writable + "/state", at: p)
        #expect(e.call(137, [p]).value == 0)
        #expect(e.call(137, [p]).errno == 2)
        e.putString("/dev/x", at: p)
        #expect(e.call(136, [p, 0o755]).errno == 30)  // EROFS
        e.putString(e.root, at: p)
        #expect(e.call(137, [p]).errno == 16)  // EBUSY: a prefix root
    }
}

extension DEnv {
    func string(_ va: UInt64) -> String {
        String(decoding: get(va, 256).prefix { $0 != 0 }, as: UTF8.self)
    }
}
