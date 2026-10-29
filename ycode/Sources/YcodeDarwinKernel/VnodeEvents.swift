import Foundation
import Synchronization
import YcodeDarwinABI

// EVFILT_VNODE (`specs/simulator/threads-and-events.md` §3.10): a knote on
// a descriptor of a file or directory watches that object. The VFS and the
// host's own writes post `NOTE_*` to it through `VnodeNotes`
// (YcodeDarwinABI/VnodeNotes.swift), keyed by the host object, whichever
// process (or the host) made the change. As xnu's filt_vnode: the notes the
// knote asks for (`fflags`) accumulate until delivery; a knote with
// EV_CLEAR forgets them when delivered, one without keeps firing with them;
// NOTE_REVOKE ends the knote with EV_EOF | EV_ONESHOT.

/// One EVFILT_VNODE registration with `VnodeNotes`: the knote and the
/// kernel whose kqueue holds it (both weak, as `ProcessWatch`).
final class VnodeKnoteWatch: VnodeWatcher, @unchecked Sendable {
    weak var knote: Knote?
    weak var kernel: DarwinKernel?
    let key: HostFileKey
    /// The knote's interest mask (`fflags`), readable without its image's
    /// event lock: a post that asks for none of it (most of a boot's posts:
    /// writes to databases watched for deletes and renames) takes no lock.
    let interest: Atomic<UInt32>

    init(knote: Knote, kernel: DarwinKernel, key: HostFileKey, interest: UInt32) {
        self.knote = knote
        self.kernel = kernel
        self.key = key
        self.interest = Atomic(interest)
    }

    func vnodeNotesPosted(_ notes: UInt32) {
        guard notes & (interest.load(ordering: .relaxed) | VnodeNote.revoke) != 0, let kernel, let knote else { return }
        kernel.vnodeNotesPosted(knote, notes)
    }
}

extension DarwinKernel {
    /// Attaches a vnode watch to the object open as descriptor `c.ident`
    /// (xnu filt_vnattach). A descriptor that is not a host file or
    /// directory (the console, a pipe, a socket, a device) is registered
    /// but never fires, as before.
    func attachVnode(_ kn: Knote, _ c: KEventRecord) -> Int32? {
        guard c.ident <= UInt64(Int32.max) else { return Errno.EBADF }
        let fd = Int32(c.ident)
        let open: DarwinOpenFile
        do {
            _ = try fileSystem.closeOnExec(fd)  // EBADF for a closed descriptor
            open = try fileSystem.openFile(for: fd)
        } catch {
            return errno(of: error, default: Errno.EBADF)
        }
        kn.data = 0
        kn.vnodeFired = 0
        guard let file = open.guestFile, let key = file.hostKey else {
            trace("note: EVFILT_VNODE on descriptor \(fd), which is no file or directory: it never fires")
            return nil
        }
        let watch = VnodeKnoteWatch(knote: kn, kernel: self, key: key, interest: c.fflags)
        kn.vnodeWatch = watch
        VnodeNotes.add(watch, key: key)
        if Self.debugVnode {
            FileHandle.standardError.write(Data(("ycode-vnode: pid \(pid) (\(processRecord?.comm ?? "?")) watches \(file.guestPath) "
                + "fflags \(hx(UInt64(c.fflags))) flags \(hx(UInt64(c.flags))); \(VnodeNotes.count) watched\n").utf8))
        }
        return nil
    }

    /// Diagnostics (`YCODE_DEBUG_VNODE=1`): one line per EVFILT_VNODE
    /// registration and per delivered vnode event.
    static let debugVnode = getenv("YCODE_DEBUG_VNODE").map { String(cString: $0) == "1" } ?? false

    /// Ends a knote's registration (its drop, the image's end).
    func detachVnode(_ kn: Knote) {
        guard let watch = kn.vnodeWatch else { return }
        kn.vnodeWatch = nil
        VnodeNotes.remove(watch, key: watch.key)
    }

    /// After a restore (snapshot.md §12.5): the knote watches the object
    /// its descriptor names in the restored table (a restored device's
    /// files are new host objects). Notes pending at the save are not kept.
    func reattachVnodeAfterRestore(_ kn: Knote) {
        guard kn.filter == EVFilter.vnode, !kn.dropped, kn.vnodeWatch == nil, kn.ident <= UInt64(Int32.max),
              let open = try? fileSystem.openFile(for: Int32(kn.ident)), let key = open.guestFile?.hostKey else { return }
        let watch = VnodeKnoteWatch(knote: kn, kernel: self, key: key, interest: kn.fflags)
        kn.vnodeWatch = watch
        VnodeNotes.add(watch, key: key)
    }

    /// `VnodeNotes` posted `notes` to the object `kn` watches: taken under
    /// this image's event lock (L0 without the lock split). The poster
    /// holds no lock, or L0 only; anything else defers the work until its
    /// locks allow it (`KernelLock.deferIfFast`).
    func vnodeNotesPosted(_ kn: Knote, _ notes: UInt32) {
        guard !isTerminating else { return }
        let work: () -> Void = { [weak self, weak kn] in
            guard let self, let kn else { return }
            self.withEvents { self.vnodeNotesPostedLocked(kn, notes) }
        }
        if let events = eventLock {
            lock.deferIfFast(.fineLock(events), tag: "vnode note", work)
        } else {
            lock.withLock(work)
        }
    }

    /// xnu filt_vnode_common: the notes the knote asks for accumulate;
    /// NOTE_REVOKE ends it (EV_EOF | EV_ONESHOT, NOTE_REVOKE reported when
    /// asked for).
    func vnodeNotesPostedLocked(_ kn: Knote, _ notes: UInt32) {
        guard !kn.dropped else { return }
        if notes & VnodeNote.revoke != 0 {
            kn.vnodeRevoked = true
            kn.flags |= EV.eof | EV.oneshot
            kn.vnodeFired |= kn.fflags & VnodeNote.revoke
        } else {
            let wanted = kn.fflags & notes
            guard wanted != 0 else { return }
            kn.vnodeFired |= wanted
        }
        kn.note("vnode notes \(hx(UInt64(notes))) -> fired \(hx(UInt64(kn.vnodeFired)))")
        kn.active = true
        activated(kn)
    }

    /// The delivered event of a vnode knote: the accumulated notes in
    /// `fflags`, `data` 0; with EV_CLEAR the notes start over.
    func deliverVnode(_ kn: Knote, into e: inout KEventRecord) {
        e.fflags = kn.vnodeFired
        e.data = 0
        if Self.debugVnode {
            FileHandle.standardError.write(Data(("ycode-vnode: pid \(pid) (\(processRecord?.comm ?? "?")) gets fd \(kn.ident) "
                + "notes \(hx(UInt64(kn.vnodeFired)))\n").utf8))
        }
        if kn.flags & EV.clear != 0 { kn.vnodeFired = 0 }
    }
}
