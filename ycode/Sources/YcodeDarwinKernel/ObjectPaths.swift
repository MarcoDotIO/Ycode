import Foundation
import YcodeDarwinABI

// Paths from object ids: fsgetpath(2) (427), fsgetpath_ext (217) and
// openbyid_np (479) (the fsgetpath(2) manual page, sys/fsgetpath.h; level 1).
//
// Ycode's volumes report VOL_CAP_FMT_PATH_FROM_ID, as the Mac's APFS volumes
// do (level 3: ATTR_VOL_CAPABILITIES of the simulator runtime's volume and of
// the device's data volume). LaunchServices depends on it: its file nodes
// give a file identifier only on volumes that can turn the identifier back
// into a path, and without the executable's identifier lsd reads no Mach-O
// information for an app, so it registers every app as an incomplete
// placeholder (platform 0, no SDK, no extension point; level 3: on the Mac,
// clearing that one capability bit in lsd's getattrlist replies with our own
// interposer reproduces the 162 "Placeholder detected" registrations; see
// specs/simulator/home-screen.md §3.3).
//
// The object id is the file's inode number on its volume (ATTR_CMN_FILEID,
// st_ino), and 2 names the volume's root directory, as on APFS. Ycode keeps
// an index of (volume device, object id) → guest path, filled whenever
// getattrlist reports an object, and falls back to walking the volume's
// directories (each volume at most once every 30 s).
final class ObjectPathIndex: @unchecked Sendable {
    struct Key: Hashable { let dev: UInt32; let ino: UInt64 }
    private let lock = NSLock()
    private var paths: [Key: String] = [:]
    private var lastWalk: [UInt32: Date] = [:]
    static let limit = 1 << 20

    func note(dev: UInt32, ino: UInt64, path: String) {
        lock.lock(); defer { lock.unlock() }
        if paths.count >= Self.limit { paths.removeAll(keepingCapacity: true) }
        paths[Key(dev: dev, ino: ino)] = path
    }

    func lookup(dev: UInt32, ino: UInt64) -> String? {
        lock.lock(); defer { lock.unlock() }
        return paths[Key(dev: dev, ino: ino)]
    }

    /// True when the volume may be walked now (and records the walk).
    func mayWalk(_ dev: UInt32) -> Bool {
        lock.lock(); defer { lock.unlock() }
        if let last = lastWalk[dev], Date().timeIntervalSince(last) < 30 { return false }
        lastWalk[dev] = Date()
        return true
    }
}

extension DarwinKernel {
    /// Records the object getattrlist reported (and the volume roots, id 2).
    func noteObjectPath(dev: UInt32, ino: UInt64, path: String) {
        system.objectPaths.note(dev: dev, ino: ino, path: path)
    }

    /// The guest path of object `objid` on the volume whose fsid.val[0] is `dev`.
    func pathForObject(dev: UInt32, objid: UInt64) throws -> String {
        let fs = fileSystem
        // The volume's directory prefixes (guest path, host path) and its mount point.
        var roots: [(guest: String, host: String)] = []
        var mountPoint: String?
        for prefix in fs.prefixes {
            guard let st = try? fs.stat(prefix.guestPath, followSymlinks: true), st.dev == dev, st.isDirectory else { continue }
            roots.append((prefix.guestPath, prefix.hostPath))
            if mountPoint == nil || prefix.volumeMountPoint.count < mountPoint!.count { mountPoint = prefix.volumeMountPoint }
        }
        if let root = try? fs.stat("/", followSymlinks: true), root.dev == dev, mountPoint == nil { mountPoint = "/" }
        guard let mount = mountPoint else { throw Failure(errno: Errno.EINVAL) }  // no such volume
        if objid == 2 { return mount }
        if let path = system.objectPaths.lookup(dev: dev, ino: objid),
           let st = try? fs.stat(path, followSymlinks: false), st.ino == objid, st.dev == dev {
            return path
        }
        for root in roots where (try? fs.stat(root.guest, followSymlinks: false).ino) == objid { return root.guest }
        guard system.objectPaths.mayWalk(dev) else { throw Failure(errno: Errno.ENOENT) }
        // Walk the volume's directories on the host (d_ino is st_ino on the
        // host file systems Ycode runs on), noting every entry.
        let index = system.objectPaths
        var found: String?
        let fm = FileManager.default
        for root in roots {
            guard let walker = fm.enumerator(atPath: root.host) else { continue }
            let hostBase = root.host.hasSuffix("/") ? String(root.host.dropLast()) : root.host
            let guestBase = root.guest == "/" ? "" : root.guest
            while let rel = walker.nextObject() as? String {
                var st = stat()
                guard lstat(hostBase + "/" + rel, &st) == 0 else { continue }
                let guest = guestBase + "/" + rel
                index.note(dev: dev, ino: UInt64(st.st_ino), path: guest)
                if UInt64(st.st_ino) == objid { found = guest; break }
            }
            if found != nil { break }
        }
        guard let path = found else { throw Failure(errno: Errno.ENOENT) }
        return path
    }

    /// fsgetpath(buf, bufsize, fsid, objid) and fsgetpath_ext(…, options):
    /// the path's length including its NUL, ENOSPC when it does not fit.
    func fsGetPathCall(_ n: Int, _ a: [UInt64], _ call: inout String, _ mem: any KernelGuestMemory) throws -> UInt64 {
        let fsid = try mem.read(va: a[2], count: 8)
        let dev = fsid.readLE(UInt32.self, at: 0)
        call = "\(n == 427 ? "fsgetpath" : "fsgetpath_ext")(buf=\(hx(a[0])), size=\(a[1]), fsid=\(hx(UInt64(dev))), objid=\(a[3])"
            + (n == 427 ? ")" : ", options=\(hx(a[4])))")
        let path = try lock.unlocked { try pathForObject(dev: dev, objid: a[3]) }
        let bytes = Array(path.utf8) + [0]
        call += " [\(path)]"
        guard UInt64(bytes.count) <= a[1] else { throw Failure(errno: 28) }  // ENOSPC
        try mem.write(va: a[0], bytes: bytes)
        return UInt64(bytes.count)
    }

    /// openbyid_np(fsid, objid, oflags): opens the object's path.
    func openByIDCall(_ a: [UInt64], _ call: inout String, _ mem: any KernelGuestMemory) throws -> UInt64 {
        let fsid = try mem.read(va: a[0], count: 8)
        let dev = fsid.readLE(UInt32.self, at: 0)
        let flags = Int32(truncatingIfNeeded: a[2])
        call = "openbyid_np(fsid=\(hx(UInt64(dev))), objid=\(a[1]), oflags=\(hx(UInt64(UInt32(bitPattern: flags)))))"
        let path = try lock.unlocked { try pathForObject(dev: dev, objid: a[1]) }
        call += " [\(path)]"
        let fd = try openUnlocked(path, flags: flags, mode: 0)
        return UInt64(UInt32(bitPattern: fd))
    }
}
