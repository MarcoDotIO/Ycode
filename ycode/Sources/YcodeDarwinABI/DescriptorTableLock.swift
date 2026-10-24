// The descriptor-table lock of a process (`specs/simulator/bsd-locking.md`
// §3): a leaf mutex that guards one `DarwinFileSystem`'s descriptor table,
// so that BSD descriptor traps can run without the kernel lock L0.
//
// It is a leaf: the thread that holds it takes no other lock (no kernel
// lock, no address-space lock, no other table) and never waits for
// anything else. Callbacks that the table makes (the close hook, the
// release of a closed description) run after it is released.
//
// With `YCODE_LOCK_ORDER_CHECK=1` each thread counts the leaf locks it
// holds (`LeafLockCheck`); the kernel's lock-order check stops the process
// when a kernel lock is taken while a leaf lock is held.

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif

/// Debug bookkeeping of leaf locks held by the calling thread.
public enum LeafLockCheck {
    /// `YCODE_LOCK_ORDER_CHECK=1` (tests set it through the kernel's switch).
    nonisolated(unsafe) public static var enabled = getenv("YCODE_LOCK_ORDER_CHECK").map { String(cString: $0) == "1" } ?? false

    private static let key: pthread_key_t = {
        var key = pthread_key_t()
        pthread_key_create(&key, nil)
        return key
    }()

    /// Leaf locks the calling thread holds (0 unless `enabled`).
    public static var depth: Int {
        guard enabled else { return 0 }
        return Int(bitPattern: pthread_getspecific(key))
    }

    @inline(__always) static func entered() {
        guard enabled else { return }
        pthread_setspecific(key, UnsafeRawPointer(bitPattern: Int(bitPattern: pthread_getspecific(key)) + 1))
    }

    @inline(__always) static func left() {
        guard enabled else { return }
        pthread_setspecific(key, UnsafeRawPointer(bitPattern: Int(bitPattern: pthread_getspecific(key)) - 1))
    }
}

/// A recursive leaf mutex (the descriptor table's). Re-entrant so that a
/// table operation may call another (dup2 → install).
public final class DescriptorTableLock: @unchecked Sendable {
    private let mutex: UnsafeMutablePointer<pthread_mutex_t>

    public init(name: String = "descriptor table") {
        mutex = .allocate(capacity: 1)
        mutex.initialize(to: pthread_mutex_t())
        var attr = pthread_mutexattr_t()
        pthread_mutexattr_init(&attr)
        pthread_mutexattr_settype(&attr, Int32(PTHREAD_MUTEX_RECURSIVE))
        pthread_mutex_init(mutex, &attr)
        pthread_mutexattr_destroy(&attr)
        DebugLockNames.register?(UnsafeMutableRawPointer(mutex), name)
    }

    deinit {
        pthread_mutex_destroy(mutex)
        mutex.deallocate()
    }

    @inline(__always)
    public func withLock<T>(_ body: () throws -> T) rethrows -> T {
        pthread_mutex_lock(mutex)
        LeafLockCheck.entered()
        defer {
            LeafLockCheck.left()
            pthread_mutex_unlock(mutex)
        }
        return try body()
    }
}
