import Foundation
import Synchronization
import Testing
import YcodeDarwinABI
@testable import YcodeDarwinKernel

// EVFILT_VNODE (`specs/simulator/threads-and-events.md` §3.10): the notes
// each file-system change posts, directories, accumulation until delivery,
// EV_CLEAR / EV_ONESHOT, other processes' and the host's changes, and the
// registry's state when nothing is watched.

private enum Sys {
    static let write: UInt64 = 4, open: UInt64 = 5, close: UInt64 = 6, unlink: UInt64 = 10, chmod: UInt64 = 15
    static let fchmod: UInt64 = 124, rename: UInt64 = 128, flock: UInt64 = 131, mkdir: UInt64 = 136, rmdir: UInt64 = 137
    static let pwrite: UInt64 = 154, truncate: UInt64 = 200, ftruncate: UInt64 = 201, setxattr: UInt64 = 236
    static let kqueue: UInt64 = 362, kevent: UInt64 = 363, utimes: UInt64 = 138
}

private enum Open {
    static let rdonly: UInt64 = 0, wronly: UInt64 = 1, rdwr: UInt64 = 2, creat: UInt64 = 0x200, evtonly: UInt64 = 0x8000
    static let directory: UInt64 = 0x10_0000
}

private let allNotes: UInt32 = VnodeNote.delete | VnodeNote.write | VnodeNote.extend | VnodeNote.attrib | VnodeNote.link
    | VnodeNote.rename | VnodeNote.revoke | VnodeNote.funlock

/// A test image with path and kevent helpers.
private struct V {
    let e: DEnv
    static let pathA = DEnv.scratch + 0x100, pathB = DEnv.scratch + 0x400
    static let changes = DEnv.scratch + 0x800, events = DEnv.scratch + 0xC00, timeout = DEnv.scratch + 0x1800

    init(_ e: DEnv) { self.e = e }

    func path(_ name: String) -> String { e.writable + "/" + name }

    @discardableResult
    func call(_ n: UInt64, _ a: String, _ rest: [UInt64] = []) -> DEnv.Result {
        e.putString(a, at: Self.pathA)
        return e.call(n, [Self.pathA] + rest)
    }

    @discardableResult
    func call2(_ n: UInt64, _ a: String, _ b: String) -> DEnv.Result {
        e.putString(a, at: Self.pathA)
        e.putString(b, at: Self.pathB)
        return e.call(n, [Self.pathA, Self.pathB])
    }

    func open(_ name: String, _ flags: UInt64) -> Int32 {
        let r = call(Sys.open, path(name), [flags, 0o644])
        precondition(!r.carry, "open \(name) failed: \(r.errno ?? 0)")
        return r.fd
    }

    func kqueue() -> Int32 { e.call(Sys.kqueue).fd }

    /// One change (struct kevent); the errno of a failed change, or nil.
    @discardableResult
    func change(_ kq: Int32, ident: Int32, flags: UInt16, fflags: UInt32, filter: Int16 = EVFilter.vnode) -> Int32? {
        let c = KEventRecord(ident: UInt64(UInt32(bitPattern: ident)), filter: filter, flags: flags, fflags: fflags, udata: 0xAB)
        e.put(c.encoded(.legacy), at: Self.changes)
        let r = e.call(Sys.kevent, [UInt64(kq), Self.changes, 1, 0, 0, 0])
        return r.errno
    }

    /// Polls `kq` (zero timeout): the events delivered.
    func poll(_ kq: Int32, max: Int = 8) -> [KEventRecord] {
        e.put([UInt8](repeating: 0, count: 16), at: Self.timeout)
        let r = e.call(Sys.kevent, [UInt64(kq), 0, 0, Self.events, UInt64(max), Self.timeout])
        guard let n = r.value else { return [] }
        let bytes = e.get(Self.events, Int(n) * 32)
        return (0..<Int(n)).map { KEventRecord(decoding: bytes, at: $0 * 32, format: .legacy) }
    }

    /// The notes of the one event for `fd` now (0: none).
    func notes(_ kq: Int32, _ fd: Int32) -> UInt32 {
        poll(kq).filter { $0.ident == UInt64(UInt32(bitPattern: fd)) && $0.filter == EVFilter.vnode }.reduce(0) { $0 | $1.fflags }
    }

    func write(_ fd: Int32, _ text: String) { precondition(!e.write(fd, text).carry) }
}

@Suite(.serialized) struct VnodeEventsTests {
    @Test func fileNotes() throws {
        let v = V(try DEnv())
        let fd = v.open("f", Open.rdwr | Open.creat)
        let kq = v.kqueue()
        #expect(v.change(kq, ident: fd, flags: EV.add | EV.clear, fflags: allNotes) == nil)
        #expect(v.notes(kq, fd) == 0)

        v.write(fd, "hello")
        #expect(v.notes(kq, fd) == VnodeNote.write | VnodeNote.extend)
        // A write inside the file does not extend it.
        v.e.put(Array("J".utf8), at: DEnv.scratch + 0x1000)
        #expect(v.e.call(Sys.pwrite, [UInt64(fd), DEnv.scratch + 0x1000, 1, 0]).value == 1)
        #expect(v.notes(kq, fd) == VnodeNote.write)

        #expect(v.e.call(Sys.fchmod, [UInt64(fd), 0o600]).value == 0)
        #expect(v.notes(kq, fd) == VnodeNote.attrib)
        #expect(v.call(Sys.chmod, v.path("f"), [0o644]).value == 0)
        #expect(v.notes(kq, fd) == VnodeNote.attrib)
        #expect(v.call(Sys.utimes, v.path("f"), [0]).value == 0)
        #expect(v.notes(kq, fd) == VnodeNote.attrib)
        v.e.putString("user.test", at: DEnv.scratch + 0x1100)
        #expect(v.call(Sys.setxattr, v.path("f"), [DEnv.scratch + 0x1100, DEnv.scratch + 0x1000, 1, 0, 0]).value == 0)
        #expect(v.notes(kq, fd) == VnodeNote.attrib)

        // Size changes: NOTE_ATTRIB, with NOTE_EXTEND when the file grows.
        #expect(v.e.call(Sys.ftruncate, [UInt64(fd), 100]).value == 0)
        #expect(v.notes(kq, fd) == VnodeNote.attrib | VnodeNote.extend)
        #expect(v.call(Sys.truncate, v.path("f"), [10]).value == 0)
        #expect(v.notes(kq, fd) == VnodeNote.attrib)

        #expect(v.call2(Sys.rename, v.path("f"), v.path("g")).value == 0)
        #expect(v.notes(kq, fd) == VnodeNote.rename)
        // The knote follows the object, not the name.
        v.write(fd, "more")
        #expect(v.notes(kq, fd) & VnodeNote.write != 0)
        #expect(v.call(Sys.unlink, v.path("g")).value == 0)
        #expect(v.notes(kq, fd) == VnodeNote.delete | VnodeNote.link)
        #expect(v.notes(kq, fd) == 0)
    }

    @Test func directoryNotes() throws {
        let v = V(try DEnv())
        #expect(v.call(Sys.mkdir, v.path("d"), [0o755]).value == 0)
        #expect(v.call(Sys.mkdir, v.path("other"), [0o755]).value == 0)
        let dfd = v.open("d", Open.evtonly | Open.directory)
        let ofd = v.open("other", Open.evtonly | Open.directory)
        let kq = v.kqueue()
        #expect(v.change(kq, ident: dfd, flags: EV.add | EV.clear, fflags: allNotes) == nil)
        #expect(v.change(kq, ident: ofd, flags: EV.add | EV.clear, fflags: allNotes) == nil)

        // An entry added or removed: NOTE_WRITE.
        let f = v.open("d/file", Open.wronly | Open.creat)
        #expect(v.notes(kq, dfd) == VnodeNote.write)
        v.write(f, "x")  // the file's contents are not the directory's
        #expect(v.notes(kq, dfd) == 0)
        #expect(v.call2(Sys.rename, v.path("d/file"), v.path("d/file2")).value == 0)
        #expect(v.notes(kq, dfd) == VnodeNote.write)
        #expect(v.call(Sys.unlink, v.path("d/file2")).value == 0)
        #expect(v.notes(kq, dfd) == VnodeNote.write)

        // A subdirectory changes the link count: NOTE_LINK too.
        #expect(v.call(Sys.mkdir, v.path("d/sub"), [0o755]).value == 0)
        #expect(v.notes(kq, dfd) == VnodeNote.write | VnodeNote.link)
        #expect(v.call2(Sys.rename, v.path("d/sub"), v.path("other/sub")).value == 0)
        let moved = v.poll(kq)
        #expect(moved.first { $0.ident == UInt64(dfd) }?.fflags == VnodeNote.write | VnodeNote.link)
        #expect(moved.first { $0.ident == UInt64(ofd) }?.fflags == VnodeNote.write | VnodeNote.link)
        #expect(v.call(Sys.rmdir, v.path("other/sub")).value == 0)
        #expect(v.notes(kq, ofd) == VnodeNote.write | VnodeNote.link)

        // The directory itself goes.
        #expect(v.call(Sys.rmdir, v.path("d")).value == 0)
        #expect(v.notes(kq, dfd) == VnodeNote.delete | VnodeNote.link)
    }

    @Test func notesAccumulateAndFollowTheInterestMask() throws {
        let v = V(try DEnv())
        let fd = v.open("f", Open.rdwr | Open.creat)
        let kq = v.kqueue()
        #expect(v.change(kq, ident: fd, flags: EV.add | EV.clear, fflags: VnodeNote.write | VnodeNote.attrib) == nil)
        v.write(fd, "a")
        #expect(v.e.call(Sys.fchmod, [UInt64(fd), 0o600]).value == 0)
        v.write(fd, "b")
        let events = v.poll(kq)
        #expect(events.count == 1)
        #expect(events.first?.fflags == VnodeNote.write | VnodeNote.attrib)  // NOTE_EXTEND not asked for
        #expect(events.first?.data == 0)
        #expect(events.first?.udata == 0xAB)
        // Notes not asked for do not activate the knote.
        #expect(v.call(Sys.unlink, v.path("f")).value == 0)
        #expect(v.poll(kq).isEmpty)
        // A new interest mask (EV_ADD again) applies from then on.
        #expect(v.change(kq, ident: fd, flags: EV.add | EV.clear, fflags: VnodeNote.extend) == nil)
        v.write(fd, "c")
        #expect(v.notes(kq, fd) == VnodeNote.extend)
    }

    @Test func clearOneshotAndLevelBehaviour() throws {
        let v = V(try DEnv())
        let a = v.open("a", Open.rdwr | Open.creat), b = v.open("b", Open.rdwr | Open.creat)
        let kq = v.kqueue()
        // Without EV_CLEAR the notes stay and the knote fires at every scan (xnu).
        #expect(v.change(kq, ident: a, flags: EV.add, fflags: VnodeNote.write) == nil)
        // EV_ONESHOT: one delivery, then the knote is gone.
        #expect(v.change(kq, ident: b, flags: EV.add | EV.oneshot, fflags: VnodeNote.write) == nil)
        v.write(a, "x")
        v.write(b, "x")
        #expect(v.notes(kq, a) == VnodeNote.write)
        #expect(v.notes(kq, a) == VnodeNote.write)
        let once = v.poll(kq).filter { $0.ident == UInt64(b) }
        #expect(once.isEmpty)  // b was delivered with a in the first poll
        #expect(v.change(kq, ident: b, flags: EV.delete, fflags: 0) == 2)  // ENOENT: dropped
        v.write(b, "y")
        #expect(v.notes(kq, b) == 0)
        // EV_DISPATCH: disabled after delivery; notes made meanwhile wait for EV_ENABLE.
        #expect(v.change(kq, ident: a, flags: EV.add | EV.clear | EV.dispatch, fflags: VnodeNote.write | VnodeNote.attrib) == nil)
        #expect(v.notes(kq, a) == VnodeNote.write)  // the notes kept from before, now disabled
        v.write(a, "z")
        #expect(v.e.call(Sys.fchmod, [UInt64(a), 0o600]).value == 0)
        #expect(v.notes(kq, a) == 0)
        #expect(v.change(kq, ident: a, flags: EV.enable, fflags: VnodeNote.write | VnodeNote.attrib) == nil)
        #expect(v.notes(kq, a) == VnodeNote.write | VnodeNote.attrib)
        #expect(v.notes(kq, a) == 0)
    }

    @Test func anotherProcessAndTheHostPost() throws {
        let parent = try DEnv()
        let child = try DEnv(parent: parent, pid: 101)
        let p = V(parent), c = V(child)
        #expect(p.call(Sys.mkdir, p.path("audio"), [0o755]).value == 0)
        let file = p.path("audio/settings.plist")
        try Data("old".utf8).write(to: URL(fileURLWithPath: file))
        let dfd = p.open("audio", Open.evtonly | Open.directory)
        let ffd = p.open("audio/settings.plist", Open.evtonly)
        let kq = p.kqueue()
        #expect(p.change(kq, ident: dfd, flags: EV.add | EV.clear, fflags: allNotes) == nil)
        #expect(p.change(kq, ident: ffd, flags: EV.add | EV.clear, fflags: allNotes) == nil)

        // The child process writes the file.
        let cfd = c.open("audio/settings.plist", Open.wronly)
        c.write(cfd, "new contents")
        #expect(p.notes(kq, ffd) == VnodeNote.write | VnodeNote.extend)

        // The host replaces it (temporary file and rename) through the hook,
        // which also feeds the file-event service (pid 0: the host).
        let fed = Mutex<[FileChange]>([])
        fileChangeFeedLock.lock()
        defer { fileChangeFeedLock.unlock() }
        FileChangeFeed.install { c in fed.withLock { $0.append(c) } }
        FileChangeFeed.setListening(true)
        try HostDataWrites.replace(hostPath: file, guestPath: "/guest/settings.plist", data: Array("host".utf8))
        FileChangeFeed.install(nil)
        // (Other suites running at the same time feed their own changes: only ours count.)
        let changes = fed.withLock { $0 }.filter { $0.path.hasPrefix("/guest/") }
        #expect(changes.count == 4 && changes.allSatisfy { $0.pid == 0 })
        #expect(changes.last == FileChange(kind: .renamed, item: .file, path: "/guest/settings.plist", pid: 0))
        #expect(changes.first?.kind == .created && changes.first?.path.hasPrefix("/guest/.settings.plist.ycode-") == true)
        let events = p.poll(kq)
        #expect(events.first { $0.ident == UInt64(dfd) }?.fflags == VnodeNote.write)
        #expect(events.first { $0.ident == UInt64(ffd) }?.fflags == VnodeNote.delete)
        #expect(try String(contentsOfFile: file, encoding: .utf8) == "host")
        // Missing directories are made (the parent sees a new subdirectory).
        try HostDataWrites.replace(hostPath: p.path("audio/new/x.plist"), guestPath: p.path("audio/new/x.plist"),
                                   data: [1])
        #expect(p.notes(kq, dfd) == VnodeNote.write | VnodeNote.link)
        HostDataWrites.remove(hostPath: p.path("audio/new/x.plist"), guestPath: p.path("audio/new/x.plist"))
        #expect(p.notes(kq, dfd) == 0)  // another directory's entry
    }

    @Test func revokeEndsTheKnoteAndFlockUnlockPosts() throws {
        let v = V(try DEnv())
        let fd = v.open("f", Open.rdwr | Open.creat)
        let kq = v.kqueue()
        #expect(v.change(kq, ident: fd, flags: EV.add | EV.clear, fflags: VnodeNote.revoke | VnodeNote.funlock) == nil)
        #expect(v.e.call(Sys.flock, [UInt64(fd), 2]).value == 0)  // LOCK_EX
        #expect(v.notes(kq, fd) == 0)
        #expect(v.e.call(Sys.flock, [UInt64(fd), 8]).value == 0)  // LOCK_UN
        #expect(v.notes(kq, fd) == VnodeNote.funlock)
        #expect(v.e.call(Sys.flock, [UInt64(fd), 8]).value == 0)  // nothing held: no note
        #expect(v.notes(kq, fd) == 0)

        let key = try #require(HostFileKey(path: v.path("f")))
        VnodeNotes.post(key, VnodeNote.revoke)
        let events = v.poll(kq)
        #expect(events.count == 1)
        #expect(events.first?.fflags == VnodeNote.revoke)
        #expect(events.first.map { $0.flags & (EV.eof | EV.oneshot) } == EV.eof | EV.oneshot)
        #expect(v.change(kq, ident: fd, flags: EV.delete, fflags: 0) == 2)
        #expect(!VnodeNotes.isWatched(key))
    }

    @Test func registrationsEndWithTheirKnotes() throws {
        let v = V(try DEnv())
        let fd = v.open("f", Open.rdwr | Open.creat)
        let key = try #require(HostFileKey(path: v.path("f")))
        let kq = v.kqueue()
        #expect(!VnodeNotes.isWatched(key))
        #expect(v.change(kq, ident: fd, flags: EV.add | EV.clear, fflags: VnodeNote.write) == nil)
        #expect(VnodeNotes.isWatched(key))
        #expect(v.change(kq, ident: fd, flags: EV.delete, fflags: 0) == nil)
        #expect(!VnodeNotes.isWatched(key))
        // Closing the descriptor drops its knotes; closing the kqueue drops the rest.
        #expect(v.change(kq, ident: fd, flags: EV.add, fflags: VnodeNote.write) == nil)
        let fd2 = v.open("f", Open.rdonly)
        #expect(v.change(kq, ident: fd2, flags: EV.add, fflags: VnodeNote.write) == nil)
        #expect(v.e.call(Sys.close, [UInt64(fd)]).value == 0)
        #expect(VnodeNotes.isWatched(key))
        #expect(v.e.call(Sys.close, [UInt64(kq)]).value == 0)
        #expect(!VnodeNotes.isWatched(key))
        // Not a file: registered, never fires, nothing watched.
        let (r, _) = v.e.pipe()
        let kq2 = v.kqueue()
        let before = VnodeNotes.count
        #expect(v.change(kq2, ident: r, flags: EV.add, fflags: allNotes) == nil)
        #expect(VnodeNotes.count <= before)
        #expect(v.change(kq2, ident: 99, flags: EV.add, fflags: allNotes) == 9)  // EBADF
    }

    /// A write on the BSD fast path (no kernel lock) and a post from a host
    /// thread reach a knote of a system with the lock split
    /// (`YCODE_IPC_LOCKS_TESTS=1`) as on the locked path.
    @Test func fastPathAndHostThreadPosts() throws {
        let env = try ProcEnv()
        let k = env.rootKernel!
        k.tracing = false
        let pathVA = ProcEnv.scratch + 0x9000, buf = ProcEnv.scratch + 0xA000, ev = ProcEnv.scratch + 0xB000
        let path = env.root + "/watched.bin"
        try Data([1, 2, 3]).write(to: URL(fileURLWithPath: path))
        env.putString(k, path, at: pathVA)
        func trap(_ n: UInt64, _ args: [UInt64], fast: Bool = false) -> (TrapFrame, Bool) {
            var f = TrapFrame()
            f.kind = TrapFrame.Kind.svc.rawValue
            f.x[16] = n
            for (i, v) in args.enumerated() { f.x[i] = v }
            if fast {
                let ran = k.handleBSDFast(&f, context: k.mainThread, memory: env.space(k)) != nil
                return (f, ran)
            }
            _ = k.handle(&f, context: k.mainThread, memory: env.space(k))
            return (f, true)
        }
        let fd = trap(Sys.open, [pathVA, Open.rdwr, 0]).0.x[0]
        let kq = trap(Sys.kqueue, []).0.x[0]
        let c = KEventRecord(ident: fd, filter: EVFilter.vnode, flags: EV.add | EV.clear, fflags: allNotes)
        env.put(k, c.encoded(.legacy), at: buf)
        #expect(!trap(Sys.kevent, [kq, buf, 1, 0, 0, 0]).0.carry)
        func poll() -> UInt32 {
            env.put(k, [UInt8](repeating: 0, count: 16), at: buf + 0x100)
            let (f, _) = trap(Sys.kevent, [kq, 0, 0, ev, 4, buf + 0x100])
            let n = Int(f.x[0])
            let bytes = env.read(k, ev, max(1, n) * 32)
            return (0..<n).reduce(0) { $0 | KEventRecord(decoding: bytes, at: $1 * 32, format: .legacy).fflags }
        }
        env.put(k, [9, 9, 9, 9, 9], at: buf + 0x200)
        let (wf, ranFast) = trap(Sys.write, [fd, buf + 0x200, 5], fast: true)
        #expect(ranFast && !wf.carry && wf.x[0] == 5)
        #expect(poll() == VnodeNote.write | VnodeNote.extend)
        let host = HostThread<Bool> {
            VnodeNotes.post(HostFileKey(path: path), VnodeNote.attrib)
            return true
        }
        #expect(host.wait() == true)
        #expect(poll() == VnodeNote.attrib)
    }

    @Test func nothingWatchedMeansNoWork() {
        // With no registration the VFS hooks skip every system call: the
        // capture of a path operation is nil and posts go nowhere.
        if !VnodeNotes.isActive {
            #expect(VnodeNotes.capture("/tmp/anything") == nil)
        }
        #expect(VnodeNotes.writeNotes(offset: 0, count: 0, sizeBefore: 0) == 0)
        #expect(VnodeNotes.writeNotes(offset: 4, count: 4, sizeBefore: 8) == VnodeNote.write)
        #expect(VnodeNotes.writeNotes(offset: 4, count: 5, sizeBefore: 8) == VnodeNote.write | VnodeNote.extend)
        #expect(VnodeNotes.sizeNotes(from: 8, to: 0) == VnodeNote.attrib)
        #expect(VnodeNotes.sizeNotes(from: 0, to: 8) == VnodeNote.attrib | VnodeNote.extend)
        VnodeNotes.post(HostFileKey(dev: 0xFFFF_FFFF, ino: 1), VnodeNote.write)  // no watcher: nothing happens
    }
}
