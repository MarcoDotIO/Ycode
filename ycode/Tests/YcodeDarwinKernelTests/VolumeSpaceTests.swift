import Foundation
import Testing
import YcodeDarwinABI
@testable import YcodeDarwinKernel

/// Volume sizes and free space (visionos.md §10.26.2): every path of one guest
/// volume, "/" and its read-only parts included, reports the host file
/// system's real sizes, taken from the volume's writable prefix (the device
/// directory). Before, getattrlist on "/" reported 0 bytes free, and Photos
/// refused to open its library ("insufficient free space 0").
@Suite(.serialized) struct VolumeSpaceTests {
    typealias At = ProcEnv.At
    typealias Prefix = DarwinFileSystem.Prefix

    /// Device mode in small: a read-only runtime root that is a volume of its
    /// own, and a writable device directory and a read-only `/System` that
    /// are part of "/"'s volume.
    static func devicePrefixes(_ root: String) -> [Prefix] {
        for d in ["rr/System", "dev/data/Media"] {
            try? FileManager.default.createDirectory(atPath: root + "/" + d, withIntermediateDirectories: true)
        }
        return [Prefix(guestPath: "/rr", hostPath: root + "/rr", writable: false, device: 0x0100_0011),
                Prefix(guestPath: "/dev1", hostPath: root + "/dev", writable: true, device: 0x0100_0010, mountPoint: "/"),
                Prefix(guestPath: "/System", hostPath: root + "/rr/System", writable: false, device: 0x0100_0010,
                       mountPoint: "/")]
    }

    let env: ProcEnv
    var k: DarwinKernel { env.rootKernel }
    init() throws { env = try ProcEnv(prefixes: Self.devicePrefixes) }

    /// The host's sizes for `path` in 4096-byte blocks (total, available).
    func host(_ path: String) -> (UInt64, UInt64) {
        var vfs = statvfs()
        #expect(statvfs(path, &vfs) == 0)
        let unit = UInt64(vfs.f_frsize)
        return (UInt64(vfs.f_blocks) * unit / 4096, UInt64(vfs.f_bavail) * unit / 4096)
    }

    /// getattrlist ATTR_VOL_INFO | SIZE | SPACEFREE | SPACEAVAIL | SPACEUSED (bytes).
    func volumeSizes(_ path: String) -> [Int64]? {
        var alist = [UInt8](repeating: 0, count: 24)
        alist.putLE(UInt16(5), at: 0)
        alist.putLE(UInt32(0x8080_001C), at: 8)
        env.put(k, alist, at: At.out + 0x800)
        env.putString(k, path, at: At.out + 0x900)
        guard env.bsd(k, 220, [At.out + 0x900, At.out + 0x800, At.out + 0xC00, 256, 0]) == 0 else { return nil }
        let reply = env.read(k, At.out + 0xC00, 64)
        #expect(reply.readLE(UInt32.self, at: 0) == 36)
        return (0..<4).map { reply.readLE(Int64.self, at: 4 + 8 * $0) }
    }

    /// statfs64: (f_blocks, f_bavail) in 4096-byte blocks.
    func statfs(_ path: String) -> (UInt64, UInt64)? {
        env.putString(k, path, at: At.out + 0x900)
        guard env.bsd(k, 345, [At.out + 0x900, At.out + 0x1000]) == 0 else { return nil }
        let b = env.read(k, At.out + 0x1000, 32)
        #expect(b.readLE(UInt32.self, at: 0) == 4096)
        return (b.readLE(UInt64.self, at: 8), b.readLE(UInt64.self, at: 24))
    }

    @Test func theWritablePrefixGivesTheRootVolumesSizes() {
        let prefixes = Self.devicePrefixes(env.root)
        #expect(DarwinKernel.volumeSpaceHostPath(mountPoint: "/", prefixes: prefixes) == env.root + "/dev")
        #expect(DarwinKernel.volumeSpaceHostPath(mountPoint: "/rr", prefixes: prefixes) == env.root + "/rr")
        #expect(DarwinKernel.volumeSpaceHostPath(mountPoint: "/elsewhere", prefixes: prefixes) == nil)
        // Without a writable prefix: the one mounted there.
        let readOnly = prefixes.filter { !$0.writable }
        #expect(DarwinKernel.volumeSpaceHostPath(mountPoint: "/", prefixes: readOnly) == env.root + "/rr/System")
    }

    @Test func everyPathOfTheRootVolumeReportsTheHostsFreeSpace() throws {
        let (total, avail) = host(env.root + "/dev")
        #expect(avail > 0)
        for path in ["/", "/dev1/data/Media", "/System"] {
            let v = try #require(volumeSizes(path), "\(path)")
            #expect(v[0] == Int64(total) * 4096, "SIZE \(path)")
            // The host's free space moves a little between the calls.
            #expect(abs(v[2] - Int64(avail) * 4096) < 64 << 20, "SPACEAVAIL \(path)")
            #expect(v[1] == v[2] && v[3] == v[0] - v[2], "SPACEFREE, SPACEUSED \(path)")
            let s = try #require(statfs(path), "statfs \(path)")
            #expect(s.0 == total && abs(Int64(s.1) - Int64(avail)) < 16 << 10, "statfs \(path)")
        }
    }

    @Test func theRuntimeVolumeReportsItsOwnHostFileSystem() throws {
        let (total, _) = host(env.root + "/rr")
        let v = try #require(volumeSizes("/rr/System"))
        #expect(v[0] == Int64(total) * 4096 && v[2] > 0)
    }
}
