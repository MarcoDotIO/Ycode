// A recursive pthread mutex: `GuestAddressSpace` takes it in every public
// operation, so the address space stays consistent even when VMM code
// reads it from a thread that does not hold the kernel lock (diagnostics),
// and a later per-process VM lock can build on it (stage 6 §5).

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif

/// Diagnostics: names host locks by address for the trap profile's futex
/// report (`TrapProfile.nameLock`). Nil unless profiling; set before the
/// first VM is built.
public enum DebugLockNames {
    /// Called with a lock's address and name when a named lock is created.
    nonisolated(unsafe) public static var register: ((UnsafeMutableRawPointer, String) -> Void)?
}

/// A recursive pthread mutex: the thread that holds it may lock it again.
/// Every `lock()` needs a matching `unlock()` on the same thread.
public final class RecursiveMutex: @unchecked Sendable {
    private let mutex: UnsafeMutablePointer<pthread_mutex_t>

    public init() {
        mutex = .allocate(capacity: 1)
        mutex.initialize(to: pthread_mutex_t())
        var attr = pthread_mutexattr_t()
        pthread_mutexattr_init(&attr)
        pthread_mutexattr_settype(&attr, Int32(PTHREAD_MUTEX_RECURSIVE))
        pthread_mutex_init(mutex, &attr)
        pthread_mutexattr_destroy(&attr)
    }

    /// A mutex named in profiles (`DebugLockNames`).
    public convenience init(name: String) {
        self.init()
        DebugLockNames.register?(UnsafeMutableRawPointer(mutex), name)
    }

    deinit {
        pthread_mutex_destroy(mutex)
        mutex.deallocate()
    }

    public func lock() { pthread_mutex_lock(mutex) }
    public func unlock() { pthread_mutex_unlock(mutex) }

    /// Runs `body` while holding the mutex and returns its result.
    @inline(__always)
    public func withLock<T>(_ body: () throws -> T) rethrows -> T {
        pthread_mutex_lock(mutex)
        defer { pthread_mutex_unlock(mutex) }
        return try body()
    }
}
