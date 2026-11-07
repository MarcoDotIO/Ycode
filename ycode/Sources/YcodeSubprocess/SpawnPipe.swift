import Foundation
#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

/// A pipe for a child's standard input, output or error whose two
/// descriptors are close-on-exec from the moment they exist.
///
/// Foundation's `Pipe` is not, and on Linux `Process` emulates Darwin's
/// `POSIX_SPAWN_CLOEXEC_DEFAULT` by listing the descriptors open when it
/// prepares a spawn and closing those in the child. A pipe that another
/// thread creates after that list is made, and before the spawn, is
/// inherited by that unrelated child. When the inherited end is the write
/// end of a child's standard input, that child never sees end of file
/// while the unrelated child lives; two such leaks between two runs, each
/// holding the other's input open, wait for each other for ever.
///
/// `Process` takes the child's end as a `FileHandle` and duplicates it onto
/// 0, 1 or 2 in the child, which clears close-on-exec on the copy, so the
/// child gets its own end and nothing else. After `run()`, call
/// `closeChildEnd()`: unlike a `Pipe`, `Process` does not close it.
public final class SpawnPipe: @unchecked Sendable {
    public let fileHandleForReading: FileHandle
    public let fileHandleForWriting: FileHandle
    /// Which end the child uses: its standard input reads, its output and error write.
    private let childReads: Bool
    private let lock = NSLock()
    private var childEndClosed = false

    /// A pipe for the child's standard input (`childReads`) or for its output or error.
    public init(childReads: Bool) throws {
        var fds: [Int32] = [-1, -1]
        #if canImport(Glibc)
        // Atomic: no other thread's spawn can catch the descriptors without the flag.
        guard Self.pipe2(&fds, O_CLOEXEC) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        #else
        // Darwin's Foundation spawns with POSIX_SPAWN_CLOEXEC_DEFAULT, so the
        // short window before the flag is set matters only to other spawners.
        guard pipe(&fds) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        for fd in fds { _ = fcntl(fd, F_SETFD, FD_CLOEXEC) }
        #endif
        fileHandleForReading = FileHandle(fileDescriptor: fds[0], closeOnDealloc: true)
        fileHandleForWriting = FileHandle(fileDescriptor: fds[1], closeOnDealloc: true)
        self.childReads = childReads
    }

    #if canImport(Glibc)
    /// glibc's `pipe2`, which the Glibc module does not import (it is a GNU extension).
    private static let pipe2: @convention(c) (UnsafeMutablePointer<Int32>, Int32) -> Int32 = {
        guard let symbol = dlsym(nil, "pipe2") else { fatalError("glibc has no pipe2") }
        return unsafeBitCast(symbol, to: (@convention(c) (UnsafeMutablePointer<Int32>, Int32) -> Int32).self)
    }()
    #endif

    /// The end the child uses, for `Process.standardInput`/`standardOutput`/`standardError`.
    public var childEnd: FileHandle { childReads ? fileHandleForReading : fileHandleForWriting }
    /// The end this process uses.
    public var parentEnd: FileHandle { childReads ? fileHandleForWriting : fileHandleForReading }

    /// Closes this process's copy of the child's end, after the child has
    /// started (or failed to start), so that the parent's end sees end of
    /// file, or a broken pipe, when the child is gone.
    public func closeChildEnd() {
        let first = lock.withLock { () -> Bool in
            defer { childEndClosed = true }
            return !childEndClosed
        }
        if first { try? childEnd.close() }
    }

    /// True when both descriptors are still open and close-on-exec (for tests).
    public var isCloseOnExec: Bool {
        [fileHandleForReading, fileHandleForWriting].allSatisfy { fcntl($0.fileDescriptor, F_GETFD) & FD_CLOEXEC != 0 }
    }
}

extension Process {
    /// `runWithSignalsUnblocked()` for a child whose standard streams are
    /// `pipes`: afterwards, whether or not the child started, this process's
    /// copies of their child ends are closed (`SpawnPipe.closeChildEnd()`),
    /// as `Process` does for a `Pipe`.
    public func runWithSignalsUnblocked(closingChildEndsOf pipes: SpawnPipe?...) throws {
        defer { pipes.forEach { $0?.closeChildEnd() } }
        try runWithSignalsUnblocked()
    }
}
