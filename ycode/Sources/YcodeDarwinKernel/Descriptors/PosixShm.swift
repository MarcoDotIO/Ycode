import YcodeDarwinABI
#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

// POSIX shared memory: shm_open (266), shm_unlink (267), ftruncate (201)
// on a shm descriptor, fstat, and mmap(MAP_SHARED) of it. Rules from xnu
// bsd/kern/posix_shm.c (level 1):
// - names are 1…31 bytes (PSHMNAMLEN): longer is ENAMETOOLONG, empty EINVAL;
//   one system-wide namespace (here: the device's `DarwinSystem`);
// - shm_open: the access mode must allow read or write (EINVAL); an absent
//   name without O_CREAT is ENOENT; O_CREAT|O_EXCL on an existing one EEXIST;
//   O_TRUNC once the size is set EINVAL; the descriptor is close-on-exec;
// - the size is set once, by the first ftruncate (a later one is EINVAL),
//   rounded up to pages; fstat reports the mode bits (no type), owner, size;
// - mmap needs MAP_SHARED (EINVAL), a set size, and a range inside it
//   (EINVAL); PROT_WRITE through a read-only descriptor is EPERM;
// - read/write on the descriptor are ENXIO (no file operations);
// - shm_unlink removes the name; the memory lives while descriptors or
//   mappings refer to it.
// notifyd keeps its notification slots in such a segment; its clients map it
// read-only.

/// A named segment.
final class PosixShmSegment {
    let name: String
    let mode: UInt16
    let uid: UInt32
    let gid: UInt32
    /// Set by the one ftruncate.
    var object: SharedMemoryObject?
    var length: UInt64 = 0
    var sized = false

    init(name: String, mode: UInt16, uid: UInt32, gid: UInt32) {
        self.name = name
        self.mode = mode
        self.uid = uid
        self.gid = gid
    }
}

/// The open file description's object of a shm descriptor.
final class PosixShmDescriptor: DarwinDescriptorObject {
    let segment: PosixShmSegment
    init(_ segment: PosixShmSegment) { self.segment = segment }
    var fileType: UInt16 { 0 }
    func lastReferenceClosed() {}
    func descriptorStat() -> DarwinStat {
        DarwinStat(mode: segment.mode, nlink: 1, uid: segment.uid, gid: segment.gid, size: Int64(segment.length))
    }
}

enum PosixShmBSD {
    static let ftruncate = 201, shmOpen = 266, shmUnlink = 267
    /// PSHMNAMLEN.
    static let maxName = 31
}

extension DarwinKernel {
    /// The name argument: at most 31 bytes before the NUL.
    private func shmName(_ va: UInt64, _ mem: any KernelGuestMemory) throws -> String {
        var bytes: [UInt8] = []
        var cursor = va
        while bytes.count <= PosixShmBSD.maxName {
            let page = VMLayout.pageSize
            let n = min(Int(page - (cursor & (page - 1))), PosixShmBSD.maxName + 1 - bytes.count)
            let chunk = try mem.read(va: cursor, count: n)
            if let nul = chunk.firstIndex(of: 0) {
                bytes += chunk[..<nul]
                guard !bytes.isEmpty else { throw fail(Code.EINVAL) }
                return String(decoding: bytes, as: UTF8.self)
            }
            bytes += chunk
            cursor += UInt64(n)
        }
        throw fail(Code.ENAMETOOLONG)
    }

    /// shm_open, shm_unlink, ftruncate. nil = not mine.
    func posixShmCall(_ n: Int, _ a: [UInt64], _ call: inout CallText, _ mem: any KernelGuestMemory) throws -> BSDResult? {
        func int(_ i: Int) -> Int32 { Int32(truncatingIfNeeded: a[i]) }
        switch n {
        case PosixShmBSD.shmOpen:
            let oflag = int(1)
            let mode = UInt16(truncatingIfNeeded: a[2]) & 0o7777
            call.set("shm_open(\(hx(a[0])), oflag=\(hx(UInt64(UInt32(bitPattern: oflag)))), mode=0o\(String(mode, radix: 8)))")
            let name = try shmName(a[0], mem)
            call.set("shm_open(\"\(name)\", oflag=\(hx(UInt64(UInt32(bitPattern: oflag)))), mode=0o\(String(mode, radix: 8)))")
            // FFLAGS(oflag) = oflag + 1: neither FREAD nor FWRITE is EINVAL.
            guard ((oflag & DarwinOpen.O_ACCMODE) + 1) & 3 != 0 else { throw fail(Code.EINVAL) }
            let segment: PosixShmSegment
            if let existing = system.posixShmSegments[name] {
                if oflag & DarwinOpen.O_CREAT != 0 && oflag & DarwinOpen.O_EXCL != 0 { throw fail(Code.EEXIST) }
                if oflag & DarwinOpen.O_TRUNC != 0 && existing.sized { throw fail(Code.EINVAL) }
                segment = existing
            } else {
                guard oflag & DarwinOpen.O_CREAT != 0 else { throw fail(Code.ENOENT) }
                segment = PosixShmSegment(name: name, mode: mode, uid: DarwinFileSystem.guestUID, gid: DarwinFileSystem.guestGID)
                system.posixShmSegments[name] = segment
            }
            let fd = try fileSystem.installObject(PosixShmDescriptor(segment), statusFlags: oflag & DarwinOpen.O_ACCMODE,
                                                  closeOnExec: true)
            call += " [fd \(fd)]"
            return .value(UInt64(UInt32(bitPattern: fd)))

        case PosixShmBSD.shmUnlink:
            call.set("shm_unlink(\(hx(a[0])))")
            let name: String
            do { name = try shmName(a[0], mem) } catch let e as DarwinErrnoError where e.errno == Code.ENAMETOOLONG {
                throw fail(Code.EINVAL)
            }
            call.set("shm_unlink(\"\(name)\")")
            guard system.posixShmSegments.removeValue(forKey: name) != nil else { throw fail(Code.ENOENT) }
            return .value(0)

        case PosixShmBSD.ftruncate:
            let fd = int(0)
            let length = Int64(bitPattern: a[1])
            call.set("ftruncate(fd=\(fd), length=\(hx(a[1])))")
            let file = try fileSystem.openFile(for: fd)
            if let shm = file.object as? PosixShmDescriptor {
                let segment = shm.segment
                guard !segment.sized, length >= 0 else { throw fail(Code.EINVAL) }
                let size = (UInt64(length) + VMLayout.pageSize - 1) & ~(VMLayout.pageSize - 1)
                if size > 0 {
                    guard let object = try? SharedMemoryObject(size: size) else { throw fail(Code.ENOMEM) }
                    segment.object = object
                }
                segment.length = size
                segment.sized = true
                call += " [shm \"\(segment.name)\" size \(hx(size))]"
                return .value(0)
            }
            guard let guestFile = file.guestFile else { throw fail(Code.EINVAL) }
            guard file.isWritable else { throw fail(Code.EINVAL) }
            guard length >= 0 else { throw fail(Code.EINVAL) }
            // The host file is kept alive by `guestFile`; the host call runs
            // without the kernel lock (stage6-contract.md §5.2).
            let watch = guestFile.vnodeWriteWatch()
            let hostError = Self.lockedFileIO ? hostFtruncate(guestFile.hostFD, length)
                : lock.unlocked { hostFtruncate(guestFile.hostFD, length) }
            guard hostError == 0 else { throw fail(DarwinErrnoCode.fromHost(hostError)) }
            // Shared views of the file follow its new size (service-fidelity.md §10).
            SharedFileViews.sizeMayHaveChanged(hostFD: guestFile.hostFD)
            WriteGenerations.noteWrite(dev: guestFile.stat.dev, ino: guestFile.stat.ino)
            FileChangeFeed.note(.modified, .file, guestFile.guestPath, pid: pid)
            if let watch { VnodeNotes.post(watch.key, VnodeNotes.sizeNotes(from: watch.size, to: length)) }
            return .value(0)

        default:
            return nil
        }
    }

    /// mmap of a shm descriptor (called by `mmap` for object descriptors).
    func mapPosixShm(_ shm: PosixShmDescriptor, file: DarwinOpenFile, flags: Int32, prot: VMProtection, offset: UInt64,
                     size: UInt64, at: UInt64?, hint: UInt64?, _ mem: any KernelGuestMemory) throws -> UInt64 {
        guard flags & MapFlag.shared != 0 else { throw fail(Code.EINVAL) }
        if !file.isWritable && prot.contains(.write) { throw fail(Code.EPERM) }
        let segment = shm.segment
        guard segment.sized, let object = segment.object else { throw fail(Code.EINVAL) }
        guard size <= segment.length, offset <= segment.length - size else { throw fail(Code.EINVAL) }
        return try mem.mapShared(object, offset: offset, at: at, size: size, protection: prot, hint: hint)
    }
}

/// Host ftruncate: 0 or the host errno.
private func hostFtruncate(_ fd: Int32, _ length: Int64) -> Int32 {
    #if canImport(Glibc)
    return Glibc.ftruncate(fd, __off_t(length)) == 0 ? 0 : Glibc.errno
    #else
    return Darwin.ftruncate(fd, length) == 0 ? 0 : Darwin.errno
    #endif
}
