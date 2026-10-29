import YcodeDarwinABI

// POSIX named semaphores (stage 6): sem_open (268), sem_close (269),
// sem_unlink (270), sem_wait (271), sem_trywait (272), sem_post (273).
// Rules from xnu bsd/kern/posix_sem.c (level 1):
// - names are at most 31 bytes (PSEMNAMLEN; ENAMETOOLONG), one system-wide
//   namespace (here: the device's `DarwinSystem`);
// - sem_open: without O_CREAT a missing name is ENOENT; O_CREAT|O_EXCL on an
//   existing one EEXIST; plain O_CREAT on an existing one opens it; a new
//   one needs 0 ≤ value ≤ SEM_VALUE_MAX (32767, EINVAL); the result is the
//   new descriptor number, which is the `sem_t *` value; Ycode marks it
//   close-on-exec as shm_open does;
// - sem_close, sem_wait, sem_trywait, sem_post take that descriptor number;
//   anything that is not a semaphore descriptor is EBADF;
// - sem_wait blocks while the count is 0 (an interrupted wait is EINTR);
//   sem_trywait then fails with EAGAIN;
// - sem_unlink removes the name (ENOENT if absent); open descriptors keep
//   the semaphore.

/// A named semaphore.
final class PosixSemaphore {
    let name: String
    let mode: UInt16
    var count: Int32
    let waiters = WaitQueue()
    init(name: String, mode: UInt16, count: Int32) {
        self.name = name
        self.mode = mode
        self.count = count
    }
}

/// The open file description's object of a semaphore descriptor.
final class PosixSemDescriptor: DarwinDescriptorObject {
    let semaphore: PosixSemaphore
    init(_ semaphore: PosixSemaphore) { self.semaphore = semaphore }
    var fileType: UInt16 { 0 }
    func lastReferenceClosed() {}
}

enum PosixSemBSD {
    static let open = 268, close = 269, unlink = 270, wait = 271, trywait = 272, post = 273
    static let all: Set<Int> = [open, close, unlink, wait, trywait, post]
    static let maxName = 31
    static let valueMax: UInt32 = 32767
}

extension DarwinSystem {
    var posixSemaphores: [String: PosixSemaphore] {
        get { posixSemaphoreStorage }
        set { posixSemaphoreStorage = newValue }
    }
}

extension DarwinKernel {
    private func semaphore(_ fd: Int32) throws -> PosixSemaphore {
        guard let o = try? fileSystem.object(for: fd), let s = o as? PosixSemDescriptor else { throw fail(Code.EBADF) }
        return s.semaphore
    }

    func posixSemCall(_ n: Int, _ a: [UInt64], _ call: inout CallText, _ mem: any KernelGuestMemory) throws -> BSDResult {
        func int(_ i: Int) -> Int32 { Int32(truncatingIfNeeded: a[i]) }
        switch n {
        case PosixSemBSD.open, PosixSemBSD.unlink:
            let name = try readString(a[0], length: 1024, mem)
            guard name.utf8.count <= PosixSemBSD.maxName else { throw fail(Code.ENAMETOOLONG) }
            if n == PosixSemBSD.unlink {
                call.set("sem_unlink(\"\(name)\")")
                guard system.posixSemaphores.removeValue(forKey: name) != nil else { throw fail(Code.ENOENT) }
                return .value(0)
            }
            let oflag = int(1)
            let mode = UInt16(truncatingIfNeeded: a[2]) & 0o7777
            call.set("sem_open(\"\(name)\", oflag=\(hx(UInt32(bitPattern: oflag))), mode=0o\(String(mode, radix: 8)), value=\(UInt32(truncatingIfNeeded: a[3])))")
            let sem: PosixSemaphore
            if let existing = system.posixSemaphores[name] {
                if oflag & DarwinOpen.O_CREAT != 0 && oflag & DarwinOpen.O_EXCL != 0 { throw fail(Code.EEXIST) }
                sem = existing
            } else {
                guard oflag & DarwinOpen.O_CREAT != 0 else { throw fail(Code.ENOENT) }
                let value = UInt32(truncatingIfNeeded: a[3])
                guard value <= PosixSemBSD.valueMax else { throw fail(Code.EINVAL) }
                sem = PosixSemaphore(name: name, mode: mode, count: Int32(value))
                system.posixSemaphores[name] = sem
            }
            let fd = try fileSystem.installObject(PosixSemDescriptor(sem), statusFlags: DarwinOpen.O_RDWR, closeOnExec: true)
            call += " [fd \(fd)]"
            return .value(UInt64(UInt32(bitPattern: fd)))

        case PosixSemBSD.close:
            call.set("sem_close(\(int(0)))")
            _ = try semaphore(int(0))
            try fileSystem.close(int(0))
            return .value(0)

        case PosixSemBSD.post:
            call.set("sem_post(\(int(0)))")
            let sem = try semaphore(int(0))
            sem.count += 1
            _ = sem.waiters.wake(count: 1)
            return .value(0)

        default:  // sem_wait, sem_trywait
            let wait = n == PosixSemBSD.wait
            call.set("\(wait ? "sem_wait" : "sem_trywait")(\(int(0)))")
            let sem = try semaphore(int(0))
            // swiftlint:disable:next empty_count - the semaphore value, not a collection
            while sem.count <= 0 {
                guard wait else { throw fail(Code.EAGAIN) }
                if sem.waiters.wait(on: lock, deadline: nil) == .interrupted { throw fail(Code.EINTR) }
            }
            sem.count -= 1
            call += " [count \(sem.count)]"
            return .value(0)
        }
    }
}
