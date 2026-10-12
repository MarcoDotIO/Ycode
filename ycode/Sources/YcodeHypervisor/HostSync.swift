// Host-side locking for the multi-vCPU VMM (stage4a-contract.md §2): a mutex
// and a condition variable over pthreads. Portable (macOS and Linux), so the
// types also exist where the KVM backend does not.

#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

/// A non-recursive pthread mutex.
public final class HostMutex: @unchecked Sendable {
    let mutex: UnsafeMutablePointer<pthread_mutex_t>

    public init() {
        mutex = .allocate(capacity: 1)
        mutex.initialize(to: pthread_mutex_t())
        pthread_mutex_init(mutex, nil)
    }

    deinit {
        pthread_mutex_destroy(mutex)
        mutex.deallocate()
    }

    public func lock() { pthread_mutex_lock(mutex) }
    public func unlock() { pthread_mutex_unlock(mutex) }

    public func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock()
        defer { unlock() }
        return try body()
    }
}

/// A condition variable used with a `HostMutex`. Deadlines use
/// CLOCK_REALTIME on Darwin and CLOCK_MONOTONIC on Linux.
public final class HostCondition: @unchecked Sendable {
    let condition: UnsafeMutablePointer<pthread_cond_t>

    public init() {
        condition = .allocate(capacity: 1)
        condition.initialize(to: pthread_cond_t())
        #if canImport(Glibc)
        var attributes = pthread_condattr_t()
        pthread_condattr_init(&attributes)
        pthread_condattr_setclock(&attributes, CLOCK_MONOTONIC)
        pthread_cond_init(condition, &attributes)
        pthread_condattr_destroy(&attributes)
        #else
        pthread_cond_init(condition, nil)
        #endif
    }

    deinit {
        pthread_cond_destroy(condition)
        condition.deallocate()
    }

    /// Waits (the caller holds `mutex`).
    public func wait(_ mutex: HostMutex) { pthread_cond_wait(condition, mutex.mutex) }

    /// Waits until signalled or `milliseconds` pass. Returns false on timeout.
    @discardableResult
    public func wait(_ mutex: HostMutex, milliseconds: UInt64) -> Bool {
        var now = timespec()
        #if canImport(Glibc)
        clock_gettime(CLOCK_MONOTONIC, &now)
        #else
        clock_gettime(CLOCK_REALTIME, &now)
        #endif
        let total = UInt64(now.tv_nsec) + (milliseconds % 1000) * 1_000_000
        var deadline = timespec()
        deadline.tv_sec = now.tv_sec + Int(milliseconds / 1000) + Int(total / 1_000_000_000)
        deadline.tv_nsec = Int(total % 1_000_000_000)
        return pthread_cond_timedwait(condition, mutex.mutex, &deadline) != ETIMEDOUT
    }

    public func signal() { pthread_cond_signal(condition) }
    public func broadcast() { pthread_cond_broadcast(condition) }
}
