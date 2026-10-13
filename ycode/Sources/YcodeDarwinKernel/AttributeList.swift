import Foundation
import YcodeDarwinABI

// getattrlist(2), fgetattrlist(2) and getattrlistat(2). The request and
// reply formats are the public ones (`sys/attr.h`, the getattrlist(2)
// manual page): a `struct attrlist` of five attribute groups selects the
// attributes; the reply starts with a u32 total length, then the fixed-size
// attributes in bit order, each 4-byte aligned, and variable-length data
// (names, paths) after them, reached through `attrreference_t` (i32 offset
// from the reference itself, u32 length including the NUL). Group order is
// common, volume, directory or file, then the extended common group
// (`forkattr` with FSOPT_ATTR_CMN_EXTENDED).

extension DarwinKernel {
    enum AttrList {
        static let bitmapCount: UInt16 = 5
        // options
        static let noFollow: UInt64 = 0x1
        static let reportFullSize: UInt64 = 0x4
        static let packInvalAttrs: UInt64 = 0x8
        static let cmnExtended: UInt64 = 0x20
        static let noFollowAny: UInt64 = 0x800
        // valid masks
        static let volValid: UInt32 = 0xF0FF_FFFF
        static let dirValid: UInt32 = 0x0000_003F
        static let fileValid: UInt32 = 0x0000_37FF
        static let cmnExtValid: UInt32 = 0x0000_1FFC
        static let volInfo: UInt32 = 0x8000_0000
        static let returnedAttrs: UInt32 = 0x8000_0000
        static let cmnError: UInt32 = 0x2000_0000
        // fsobj_type_t (sys/vnode.h enum vtype)
        static let vreg: UInt32 = 1, vdir: UInt32 = 2, vblk: UInt32 = 3, vchr: UInt32 = 4, vlnk: UInt32 = 5,
                    vsock: UInt32 = 6, vfifo: UInt32 = 7
        /// The APFS signature ('H+' style word; any stable value works).
        static let volumeSignature: UInt32 = 0x4244
        /// VOL_CAP_FMT_*: persistent object ids, symbolic links, hard links,
        /// sparse files, case sensitive, case preserving, fast statfs,
        /// 2 TB file size, 64-bit object ids.
        static let formatCaps: UInt32 = 0x1 | 0x2 | 0x4 | 0x40 | 0x100 | 0x200 | 0x400 | 0x800 | 0x20000
        /// VOL_CAP_INT_*: attrlist, advisory locks, flock, extended attributes.
        static let interfaceCaps: UInt32 = 0x2 | 0x100 | 0x200 | 0x4000
        static let formatValid: UInt32 = 0x07FF_FFFF
        static let interfaceValid: UInt32 = 0x01FF_7FFF
    }

    /// The reply under construction.
    private struct AttrPacker {
        var fixed: [UInt8] = []
        var variable: [(fixedOffset: Int, data: [UInt8])] = []

        mutating func align() { while fixed.count % 4 != 0 { fixed.append(0) } }
        mutating func u32(_ v: UInt32) { align(); fixed.appendLE(v) }
        mutating func i32(_ v: Int32) { align(); fixed.appendLE(v) }
        mutating func u64(_ v: UInt64) { align(); fixed.appendLE(v) }
        mutating func i64(_ v: Int64) { align(); fixed.appendLE(v) }
        mutating func zeros(_ n: Int) { align(); fixed += [UInt8](repeating: 0, count: n) }
        mutating func time(_ t: DarwinTimespec) { i64(t.sec); i64(t.nsec) }
        mutating func reference(_ string: String?) {
            align()
            let data: [UInt8] = string.map { Array($0.utf8) + [0] } ?? []
            variable.append((fixed.count, data))
            fixed += [UInt8](repeating: 0, count: 8)
        }

        /// The full reply: length word, fixed part, variable part.
        func encoded() -> [UInt8] {
            var tail: [UInt8] = []
            var out = [0, 0, 0, 0] + fixed
            let base = 4 + fixed.count
            for item in variable {
                let referenceAt = 4 + item.fixedOffset
                let dataAt = base + tail.count
                out.putLE(Int32(dataAt - referenceAt), at: referenceAt)
                out.putLE(UInt32(item.data.count), at: referenceAt + 4)
                tail += item.data
                while tail.count % 4 != 0 { tail.append(0) }
            }
            out += tail
            out.putLE(UInt32(out.count), at: 0)
            return out
        }
    }

    /// One file-system object as getattrlist reports it.
    private struct AttrObject {
        var path: String       // canonical guest path
        var stat: DarwinStat
        var parentID: UInt64
        var mountPoint: String
        var writable: Bool
    }

    /// getattrlist (220), fgetattrlist (228), getattrlistat (476).
    func attributeListCall(_ n: Int, _ a: [UInt64], _ call: inout String,
                           _ mem: any KernelGuestMemory) throws -> UInt64 {
        let fs = fileSystem
        // Arguments: [fd,] path?, alist, buffer, size, options.
        let request: (alist: UInt64, buffer: UInt64, size: UInt64, options: UInt64)
        let object: (path: String, follow: Bool)
        switch n {
        case 228:
            let fd = Int32(truncatingIfNeeded: a[0])
            request = (a[1], a[2], a[3], a[4])
            object = (try fs.path(for: fd), true)
            call = "fgetattrlist(fd=\(fd) [\(object.path)], "
        case 476:
            let fd = Int32(truncatingIfNeeded: a[0])
            request = (a[2], a[3], a[4], a[5])
            object = (try resolveAtPath(fd, a[1], mem), request.options & AttrList.noFollow == 0)
            call = "getattrlistat(\(fd), \"\(object.path)\", "
        default:
            request = (a[1], a[2], a[3], a[4])
            object = (try readPath(a[0], mem), request.options & AttrList.noFollow == 0)
            call = "getattrlist(\"\(object.path)\", "
        }
        let raw = try mem.read(va: request.alist, count: 24)
        let groups = (0..<5).map { raw.readLE(UInt32.self, at: 4 + 4 * $0) }
        let (requestedCommon, volume, dir, file, fork) = (groups[0], groups[1], groups[2], groups[3], groups[4])
        call += "attrs=[\(groups.map { hx(UInt64($0)) }.joined(separator: ","))], size=\(request.size), "
            + "options=\(hx(request.options)))"
        // ATTR_CMN_ERROR belongs to getattrlistbulk: getattrlist accepts the
        // bit but neither packs the field nor lists it in the returned set
        // (level 3: our probe `lsd-seed/gadump.c` on the Mac's simulator;
        // Foundation's directory listing reads the reply that way).
        let common = requestedCommon & ~AttrList.cmnError
        let options = request.options
        let extended = options & AttrList.cmnExtended != 0
        guard raw.readLE(UInt16.self, at: 0) == AttrList.bitmapCount,
              volume & ~AttrList.volValid == 0, dir & ~AttrList.dirValid == 0, file & ~AttrList.fileValid == 0,
              extended ? fork & ~AttrList.cmnExtValid == 0 : fork == 0
        else { throw Failure(errno: Errno.EINVAL) }
        if volume != 0 {
            // ATTR_VOL_INFO is documented as required, but the Mac's kernel
            // answers volume attributes without it, on any directory of the
            // volume (level 3: our probe `getattrlist-volume/ga.c` on the
            // simulator; installd asks for ATTR_VOL_UUID alone).
            guard dir == 0, file == 0 else { throw Failure(errno: Errno.EINVAL) }
        }

        let info = try attrObject(object.path, follow: object.follow)
        let isDir = info.stat.isDirectory
        var packer = AttrPacker()
        let wantsReturned = common & AttrList.returnedAttrs != 0
        if wantsReturned { packer.zeros(20) }
        let packInvalid = options & AttrList.packInvalAttrs != 0

        // Returned set: everything requested, minus what is skipped.
        var returned = (common: common, volume: volume, dir: dir, file: file, fork: fork)
        if volume == 0 {
            if isDir { returned.file = 0 } else { returned.dir = 0 }
        }

        packCommon(common, info, &packer)
        if volume != 0 { packVolume(volume, info, &packer) }
        if volume == 0 {
            if isDir || packInvalid { packDirectory(dir, info, valid: isDir, &packer) }
            if !isDir || packInvalid { packFile(file, info, valid: !isDir, &packer) }
        }
        if extended { packCommonExtended(fork, info, &packer) }

        var reply = packer.encoded()
        if wantsReturned {
            reply.putLE(returned.common, at: 4)
            reply.putLE(returned.volume, at: 8)
            reply.putLE(returned.dir, at: 12)
            reply.putLE(returned.file, at: 16)
            reply.putLE(returned.fork, at: 20)
        }
        let full = reply.count
        let count = min(full, Int(min(request.size, 1 << 20)))
        guard count >= 4 else { throw Failure(errno: Errno.ERANGE) }
        var out = Array(reply[0..<count])
        out.putLE(UInt32(options & AttrList.reportFullSize != 0 ? full : count), at: 0)
        try mem.write(va: request.buffer, bytes: out)
        call += " [\(info.path)\(full > count ? ", truncated from \(full)" : "")]"
        return 0
    }

    private func attrObject(_ path: String, follow: Bool) throws -> AttrObject {
        let fs = fileSystem
        let st = try fs.stat(path, followSymlinks: follow)
        let canonical: String
        if !follow && st.isSymbolicLink {
            let normalized = fs.normalize(path, cwd: "/")
            let slash = normalized.lastIndex(of: "/")!
            let parent = slash == normalized.startIndex ? "/" : String(normalized[..<slash])
            let parentReal = try fs.realpath(parent)
            let name = String(normalized[normalized.index(after: slash)...])
            canonical = parentReal == "/" ? "/" + name : parentReal + "/" + name
        } else {
            canonical = try fs.realpath(path)
        }
        var parentID = st.ino
        if canonical != "/" {
            let slash = canonical.lastIndex(of: "/")!
            let parent = slash == canonical.startIndex ? "/" : String(canonical[..<slash])
            parentID = (try? fs.stat(parent, followSymlinks: true).ino) ?? 2
        }
        let prefix = fs.prefixes
            .filter { canonical == $0.guestPath || canonical.hasPrefix($0.guestPath == "/" ? "/" : $0.guestPath + "/") }
            .max { $0.guestPath.count < $1.guestPath.count }
        return AttrObject(path: canonical, stat: st, parentID: parentID,
                          mountPoint: prefix?.guestPath ?? "/", writable: prefix?.writable ?? false)
    }

    private static func objectType(_ st: DarwinStat) -> UInt32 {
        switch st.fileType {
        case DarwinStat.S_IFREG: return AttrList.vreg
        case DarwinStat.S_IFDIR: return AttrList.vdir
        case DarwinStat.S_IFBLK: return AttrList.vblk
        case DarwinStat.S_IFCHR: return AttrList.vchr
        case DarwinStat.S_IFLNK: return AttrList.vlnk
        case DarwinStat.S_IFSOCK: return AttrList.vsock
        case DarwinStat.S_IFIFO: return AttrList.vfifo
        default: return 0
        }
    }

    private static func lastComponent(_ path: String) -> String {
        path == "/" ? "/" : String(path[path.index(after: path.lastIndex(of: "/")!)...])
    }

    private func packCommon(_ bits: UInt32, _ o: AttrObject, _ p: inout AttrPacker) {
        let st = o.stat
        // ATTR_CMN_ERROR comes right after ATTR_CMN_RETURNED_ATTRS, before
        // every other attribute (the getattrlistbulk(2) manual page; level 1).
        if bits & 0x2000_0000 != 0 { p.u32(0) }
        for bit in 0..<31 where bits & (1 << UInt32(bit)) != 0 && bit != 29 {
            switch UInt32(1) << UInt32(bit) {
            case 0x1: p.reference(Self.lastComponent(o.path))                // NAME
            case 0x2: p.u32(st.dev)                                        // DEVID
            case 0x4: p.u32(st.dev); p.u32(0x1A)                           // FSID
            case 0x8: p.u32(Self.objectType(st))                           // OBJTYPE
            case 0x10: p.u32(0)                                            // OBJTAG (VT_NON)
            case 0x20, 0x40: p.u32(UInt32(truncatingIfNeeded: st.ino)); p.u32(0)  // OBJID, OBJPERMANENTID
            case 0x80: p.u32(UInt32(truncatingIfNeeded: o.parentID)); p.u32(0)   // PAROBJID
            case 0x100: p.u32(0)                                           // SCRIPT
            case 0x200: p.time(st.birthtime)                               // CRTIME
            case 0x400: p.time(st.mtime)                                   // MODTIME
            case 0x800: p.time(st.ctime)                                   // CHGTIME
            case 0x1000: p.time(st.atime)                                  // ACCTIME
            case 0x2000: p.time(.init())                                   // BKUPTIME
            case 0x4000:                                                   // FNDRINFO (setattrlist keeps it)
                let info = (try? fileSystem.getExtendedAttribute(.path(o.path, followSymlinks: false),
                                                                 name: Self.finderInfoName)) ?? []
                if info.count == 32 { p.align(); p.fixed += info } else { p.zeros(32) }
            case 0x8000: p.u32(st.uid)                                     // OWNERID
            case 0x10000: p.u32(st.gid)                                    // GRPID
            case 0x20000: p.u32(UInt32(st.mode))                           // ACCESSMASK
            case 0x40000: p.u32(st.flags)                                  // FLAGS
            case 0x80000, 0x100000: p.u32(0)                               // GEN_COUNT, DOCUMENT_ID
            case 0x200000:                                                 // USERACCESS (R/W/X_OK)
                var access = UInt32(st.mode >> 6) & 7
                if !o.writable { access &= ~2 }
                p.u32(access)
            case 0x400000: p.reference(nil)                                // EXTENDED_SECURITY (none)
            case 0x800000, 0x1000000: p.zeros(16)                          // UUID, GRPUUID
            case 0x2000000: p.u64(st.ino)                                  // FILEID
            case 0x4000000: p.u64(o.parentID)                              // PARENTID
            case 0x8000000: p.reference(o.path)                            // FULLPATH
            case 0x10000000: p.time(.init())                               // ADDEDTIME
            case 0x40000000: p.u32(0)                                      // DATA_PROTECT_FLAGS
            default: break
            }
        }
    }

    /// A stable, nonzero UUID per volume device (the Mac reports a real
    /// UUID; installd compares volumes by it). Version-4 layout bits.
    static func volumeUUID(device: UInt32) -> [UInt8] {
        var h: UInt64 = 0xCBF2_9CE4_8422_2325, bytes: [UInt8] = []
        for round in 0..<2 {
            for b in le32(device) + [UInt8(round)] { h = (h ^ UInt64(b)) &* 0x0000_0100_0000_01B3 }
            bytes += le64(h)
        }
        bytes[6] = (bytes[6] & 0x0F) | 0x40
        bytes[8] = (bytes[8] & 0x3F) | 0x80
        return bytes
    }

    private func packVolume(_ bits: UInt32, _ o: AttrObject, _ p: inout AttrPacker) {
        let blockSize: Int64 = 4096
        let total: Int64 = 1 << 36
        let free: Int64 = o.writable ? 1 << 35 : 0
        for bit in 0..<31 where bits & (1 << UInt32(bit)) != 0 {
            switch UInt32(1) << UInt32(bit) {
            case 0x1: p.u32(0x1A)                                          // FSTYPE
            case 0x2: p.u32(AttrList.volumeSignature)                      // SIGNATURE
            case 0x4: p.i64(total)                                         // SIZE
            case 0x8, 0x10: p.i64(free)                                    // SPACEFREE, SPACEAVAIL
            case 0x20, 0x40: p.i64(blockSize)                              // MINALLOCATION, ALLOCATIONCLUMP
            case 0x80: p.u32(UInt32(blockSize))                            // IOBLOCKSIZE
            case 0x100, 0x200, 0x400: p.u32(0)                             // OBJCOUNT, FILECOUNT, DIRCOUNT
            case 0x800: p.u32(UInt32.max)                                  // MAXOBJCOUNT
            case 0x1000: p.reference(o.mountPoint)                         // MOUNTPOINT
            case 0x2000: p.reference(Self.lastComponent(o.mountPoint))     // NAME
            case 0x4000: p.u32((o.writable ? 0 : 0x1) | 0x1000)            // MOUNTFLAGS (MNT_RDONLY, MNT_LOCAL)
            case 0x8000: p.reference("ycode-vfs")                          // MOUNTEDDEVICE
            case 0x10000: p.u64(0)                                         // ENCODINGSUSED
            case 0x20000:                                                  // CAPABILITIES
                p.u32(AttrList.formatCaps); p.u32(AttrList.interfaceCaps); p.u32(0); p.u32(0)
                p.u32(AttrList.formatValid); p.u32(AttrList.interfaceValid); p.u32(0); p.u32(0)
            case 0x40000: p.align(); p.fixed += Self.volumeUUID(device: o.stat.dev)  // UUID
            case 0x80000: p.u32(0)                                         // MOUNTEXTFLAGS
            case 0x100000: p.reference("apfs")                             // FSTYPENAME
            case 0x200000: p.u32(0)                                        // FSSUBTYPE
            case 0x400000: p.u32(0)                                        // OWNER
            case 0x800000: p.i64(total - free)                             // SPACEUSED
            case 0x10000000, 0x20000000: p.i64(0)                          // QUOTA_SIZE, RESERVED_SIZE
            case 0x40000000:                                               // ATTRIBUTES (valid, native)
                for _ in 0..<2 {
                    p.u32(0xFFFF_FFFF); p.u32(AttrList.volValid); p.u32(AttrList.dirValid)
                    p.u32(AttrList.fileValid); p.u32(AttrList.cmnExtValid)
                }
            default: break
            }
        }
    }

    private func packDirectory(_ bits: UInt32, _ o: AttrObject, valid: Bool, _ p: inout AttrPacker) {
        let st = o.stat
        for bit in 0..<6 where bits & (1 << UInt32(bit)) != 0 {
            switch UInt32(1) << UInt32(bit) {
            case 0x1: p.u32(valid ? UInt32(st.nlink) : 0)                 // LINKCOUNT
            case 0x2:                                                      // ENTRYCOUNT (without . and ..)
                p.u32(valid ? UInt32(max(0, Int(st.nlink) - 2)) : 0)
            case 0x4: p.u32(valid && o.path == o.mountPoint ? 1 : 0)       // MOUNTSTATUS (DIR_MNTSTATUS_MNTPOINT)
            case 0x8: p.i64(valid ? st.blocks * 512 : 0)                   // ALLOCSIZE
            case 0x10: p.u32(valid ? UInt32(bitPattern: st.blksize) : 0)   // IOBLOCKSIZE
            case 0x20: p.i64(valid ? st.size : 0)                          // DATALENGTH
            default: break
            }
        }
    }

    private func packFile(_ bits: UInt32, _ o: AttrObject, valid: Bool, _ p: inout AttrPacker) {
        let st = o.stat
        for bit in 0..<14 where bits & (1 << UInt32(bit)) != 0 {
            let v = valid
            switch UInt32(1) << UInt32(bit) {
            case 0x1: p.u32(v ? UInt32(st.nlink) : 0)                      // LINKCOUNT
            case 0x2, 0x200: p.i64(v ? st.size : 0)                        // TOTALSIZE, DATALENGTH
            case 0x4, 0x400: p.i64(v ? st.blocks * 512 : 0)               // ALLOCSIZE, DATAALLOCSIZE
            case 0x8, 0x10: p.u32(v ? UInt32(bitPattern: st.blksize) : 0) // IOBLOCKSIZE, CLUMPSIZE
            case 0x20: p.u32(v ? st.rdev : 0)                              // DEVTYPE
            case 0x40, 0x80: p.u32(0)                                      // FILETYPE, FORKCOUNT
            case 0x100: p.reference(nil)                                   // FORKLIST
            case 0x800: p.zeros(64)                                        // DATAEXTENTS (8 × u32 pairs)
            case 0x1000, 0x2000: p.i64(0)                                  // RSRCLENGTH, RSRCALLOCSIZE
            default: break
            }
        }
    }

    private func packCommonExtended(_ bits: UInt32, _ o: AttrObject, _ p: inout AttrPacker) {
        let st = o.stat
        for bit in 2..<13 where bits & (1 << UInt32(bit)) != 0 {
            switch UInt32(1) << UInt32(bit) {
            case 0x4:                                                      // RELPATH (to the mount point)
                let rel = o.path == o.mountPoint ? "" : String(o.path.dropFirst(o.mountPoint == "/" ? 1 : o.mountPoint.count + 1))
                p.reference(rel)
            case 0x8: p.i64(0)                                             // PRIVATESIZE
            case 0x10: p.u64(st.ino)                                       // LINKID
            case 0x20: p.reference(o.path)                                 // NOFIRMLINKPATH
            case 0x40: p.u32(st.dev)                                       // REALDEVID
            case 0x80: p.u32(st.dev); p.u32(0x1A)                          // REALFSID
            case 0x100, 0x200, 0x400, 0x800: p.u64(0)                      // CLONEID, EXT_FLAGS, RECURSIVE_GENCOUNT, ATTRIBUTION_TAG
            case 0x1000: p.u32(1)                                          // CLONE_REFCNT
            default: break
            }
        }
    }
}

// MARK: - setattrlist

// setattrlist(2), fsetattrlist(2), setattrlistat(2) (`sys/attr.h`, the
// setattrlist(2) manual page; level 1): the buffer holds the attributes in
// bit order, packed as getattrlist packs them but without the length word.
// Settable: ATTR_CMN_SETMASK (0x51C7FF00) and ATTR_FILE_SETMASK (0x20);
// ATTR_VOL_INFO|ATTR_VOL_NAME (volume renames) are refused (EROFS: Ycode's
// volumes have fixed names); anything else is EINVAL. Applied: MODTIME and
// ACCTIME (host times), FNDRINFO (kept as the `com.apple.FinderInfo`
// extended attribute, as Darwin file systems without native Finder info
// do), OWNERID/GRPID (chown rules), ACCESSMASK (chmod), DATA_PROTECT_FLAGS
// (the protection class). SCRIPT, CRTIME, CHGTIME, BKUPTIME, FLAGS,
// EXTENDED_SECURITY, UUID, GRPUUID and ADDEDTIME are accepted and not kept.
extension DarwinKernel {
    static let finderInfoName = "com.apple.FinderInfo"

    func setAttributeListCall(_ n: Int, _ a: [UInt64], _ call: inout String, _ mem: any KernelGuestMemory) throws -> UInt64 {
        let fs = fileSystem
        let request: (alist: UInt64, buffer: UInt64, size: UInt64, options: UInt64)
        let target: DarwinFileSystem.XattrTarget
        let path: String
        switch n {
        case 229:
            let fd = Int32(truncatingIfNeeded: a[0])
            request = (a[1], a[2], a[3], a[4])
            path = try fs.path(for: fd)
            target = .descriptor(fd)
            call = "fsetattrlist(fd=\(fd) [\(path)], "
        case 524:
            let fd = Int32(truncatingIfNeeded: a[0])
            request = (a[2], a[3], a[4], a[5])
            path = try resolveAtPath(fd, a[1], mem)
            target = .path(path, followSymlinks: request.options & AttrList.noFollow == 0)
            call = "setattrlistat(\(fd), \"\(path)\", "
        default:
            request = (a[1], a[2], a[3], a[4])
            path = try readPath(a[0], mem)
            target = .path(path, followSymlinks: request.options & AttrList.noFollow == 0)
            call = "setattrlist(\"\(path)\", "
        }
        let raw = try mem.read(va: request.alist, count: 24)
        let groups = (0..<5).map { raw.readLE(UInt32.self, at: 4 + 4 * $0) }
        call += "attrs=[\(groups.map { hx(UInt64($0)) }.joined(separator: ","))], size=\(request.size), "
            + "options=\(hx(request.options)))"
        guard raw.readLE(UInt16.self, at: 0) == AttrList.bitmapCount else { throw Failure(errno: Errno.EINVAL) }
        let (common, volume, dir, file, fork) = (groups[0], groups[1], groups[2], groups[3], groups[4])
        if volume != 0 {
            guard volume & ~0x8000_2000 == 0 else { throw Failure(errno: Errno.EINVAL) }
            throw Failure(errno: 30)  // EROFS
        }
        guard common & ~0x51C7_FF00 == 0, dir == 0, file & ~0x20 == 0, fork == 0 else {
            throw Failure(errno: Errno.EINVAL)
        }
        let follow: Bool
        if case let .path(_, f) = target { follow = f } else { follow = true }
        let st: DarwinStat
        switch target {
        case .descriptor(let fd): st = try fs.fstat(fd)
        case .path: st = try fs.stat(path, followSymlinks: follow)
        }
        let size = Int(min(request.size, 1 << 16))
        let buffer = size == 0 ? [] : try mem.read(va: request.buffer, count: size)
        var at = 0
        func take(_ count: Int) throws -> ArraySlice<UInt8> {
            at = (at + 3) & ~3
            guard at + count <= buffer.count else { throw Failure(errno: Errno.EINVAL) }
            defer { at += count }
            return buffer[at..<(at + count)]
        }
        func time() throws -> DarwinTimespec {
            let b = Array(try take(16))
            return DarwinTimespec(sec: b.readLE(Int64.self, at: 0), nsec: b.readLE(Int64.self, at: 8))
        }
        func u32() throws -> UInt32 { Array(try take(4)).readLE(UInt32.self, at: 0) }
        var modification: DarwinTimespec?, access: DarwinTimespec?
        var finderInfo: [UInt8]?, owner: UInt32?, group: UInt32?, mode: UInt32?, protection: UInt32?
        for bit in 8..<31 where common & (1 << UInt32(bit)) != 0 {
            switch UInt32(1) << UInt32(bit) {
            case 0x100: _ = try u32()                                    // SCRIPT
            case 0x200, 0x800, 0x2000, 0x10000000: _ = try time()        // CRTIME, CHGTIME, BKUPTIME, ADDEDTIME
            case 0x400: modification = try time()
            case 0x1000: access = try time()
            case 0x4000: finderInfo = Array(try take(32))
            case 0x8000: owner = try u32()
            case 0x10000: group = try u32()
            case 0x20000: mode = try u32()
            case 0x40000: _ = try u32()                                  // FLAGS (not kept)
            case 0x400000: _ = try take(8)                               // EXTENDED_SECURITY reference
            case 0x800000, 0x1000000: _ = try take(16)                   // UUID, GRPUUID
            case 0x40000000: protection = try u32()                      // DATA_PROTECT_FLAGS
            default: throw Failure(errno: Errno.EINVAL)
            }
        }
        if file & 0x20 != 0 { _ = try u32() }                            // FILE_DEVTYPE
        // Apply in the order the checks can fail.
        if owner != nil || group != nil {
            switch target {
            case .descriptor(let fd): try fs.fchown(fd, uid: owner ?? UInt32.max, gid: group ?? UInt32.max)
            case .path: try fs.chown(path, uid: owner ?? UInt32.max, gid: group ?? UInt32.max, followSymlinks: follow)
            }
        }
        if let mode {
            switch target {
            case .descriptor(let fd): try fs.fchmod(fd, mode: UInt16(truncatingIfNeeded: mode))
            case .path: try fs.chmod(path, mode: UInt16(truncatingIfNeeded: mode), followSymlinks: follow)
            }
        }
        if modification != nil || access != nil {
            let m = modification ?? st.mtime, ac = access ?? st.atime
            switch target {
            case .descriptor(let fd): try fs.setTimes(fd, access: ac, modification: m)
            case .path: try fs.setTimes(path, access: ac, modification: m, followSymlinks: follow)
            }
        }
        if let finderInfo {
            if finderInfo.allSatisfy({ $0 == 0 }) {
                try? fs.removeExtendedAttribute(target, name: Self.finderInfoName)
            } else {
                try fs.setExtendedAttribute(target, name: Self.finderInfoName, value: finderInfo, create: false, replace: false)
            }
        }
        if let protection, case .descriptor(let fd) = target, let f = try? fs.file(for: fd) {
            try setProtectionClass(f, Int32(bitPattern: protection))
        }
        return 0
    }
}

// MARK: - getattrlistbulk

// getattrlistbulk(dirfd, alist, buffer, size, options) (the getattrlistbulk(2)
// manual page, sys/attr.h; level 1): the attributes of the next entries of
// an open directory, one record per entry, packed as getattrlist packs one
// object (u32 length, attribute_set_t of the returned attributes, fixed
// attributes, variable data), each record a multiple of 8 bytes. "." and
// ".." are not returned; entries are not followed (a symbolic link reports
// itself). ATTR_CMN_RETURNED_ATTRS is required; volume attributes are
// EINVAL; `forkattr` holds the extended common attributes. The read
// position is the descriptor's directory position (shared with
// getdirentries64). Returns the number of records, 0 at the end.
extension DarwinKernel {
    func attributeListBulkCall(_ a: [UInt64], _ call: inout String, _ mem: any KernelGuestMemory) throws -> UInt64 {
        let fd = Int32(truncatingIfNeeded: a[0])
        let options = a[4]
        call = "getattrlistbulk(dirfd=\(fd), alist=\(hx(a[1])), buffer=\(hx(a[2])), size=\(a[3]), options=\(hx(options)))"
        let raw = try mem.read(va: a[1], count: 24)
        let groups = (0..<5).map { raw.readLE(UInt32.self, at: 4 + 4 * $0) }
        let (common, volume, dir, file, fork) = (groups[0], groups[1], groups[2], groups[3], groups[4])
        guard raw.readLE(UInt16.self, at: 0) == AttrList.bitmapCount, common & AttrList.returnedAttrs != 0, volume == 0,
              dir & ~AttrList.dirValid == 0, file & ~AttrList.fileValid == 0, fork & ~AttrList.cmnExtValid == 0
        else { throw Failure(errno: Errno.EINVAL) }
        let handle = try fileSystem.file(for: fd)
        guard handle.isDirectory else { throw Failure(errno: Errno.ENOTDIR) }
        if extended.directoryCursors[fd].map({ $0.file !== handle }) ?? true {
            extended.directoryCursors[fd] = .init(file: handle, entries: try listDirectory(fd: fd, file: handle))
        }
        var cursor = extended.directoryCursors[fd]!
        let base = handle.guestPath
        let capacity = Int(min(a[3], 1 << 20))
        let packInvalid = options & AttrList.packInvalAttrs != 0
        var out: [UInt8] = []
        var count = 0
        while cursor.next < cursor.entries.count {
            let e = cursor.entries[cursor.next]
            if e.name == "." || e.name == ".." { cursor.next += 1; continue }
            let path = base == "/" ? "/" + e.name : base + "/" + e.name
            guard let info = try? attrObject(path, follow: false) else { cursor.next += 1; continue }
            let isDir = info.stat.isDirectory
            var packer = AttrPacker()
            packer.zeros(20)
            packCommon(common, info, &packer)
            if isDir || packInvalid { packDirectory(dir, info, valid: isDir, &packer) }
            if !isDir || packInvalid { packFile(file, info, valid: !isDir, &packer) }
            packCommonExtended(fork, info, &packer)
            var record = packer.encoded()
            record.putLE(common, at: 4)
            record.putLE(UInt32(0), at: 8)
            record.putLE(isDir ? dir : 0, at: 12)
            record.putLE(isDir ? 0 : file, at: 16)
            record.putLE(fork, at: 20)
            while record.count % 8 != 0 { record.append(0) }
            record.putLE(UInt32(record.count), at: 0)
            if out.count + record.count > capacity { break }
            out += record
            count += 1
            cursor.next += 1
        }
        if count == 0 && cursor.next < cursor.entries.count { throw Failure(errno: Errno.ERANGE) }
        extended.directoryCursors[fd] = cursor
        if !out.isEmpty { try mem.write(va: a[2], bytes: out) }
        call += " [\(count) entries]"
        return UInt64(count)
    }
}
