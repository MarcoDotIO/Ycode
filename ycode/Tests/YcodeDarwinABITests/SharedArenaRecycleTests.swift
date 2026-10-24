import Testing
@testable import YcodeDarwinABI

/// Freed runs of the shared object arena are reused without a host mapping
/// change (frame-profile.md §5.2): the next object of the same size gets the
/// same run, zero-filled; a file view's run is never pooled.
@Suite struct SharedArenaRecycleTests {
    @Test func aFreedRunIsReusedZeroFilled() throws {
        guard let arena = SharedObjectArena.shared, SharedObjectArena.recycleLimit > 0 else { return }
        // A size no other test uses (tests run in parallel).
        let size: UInt64 = 0x5C000
        var first: SharedMemoryObject? = try SharedMemoryObject(size: size)
        let offset = try #require(first?.arenaOffset)
        first?.write(offset: 0, bytes: [1, 2, 3])
        first?.write(offset: size - 2, bytes: [4, 5])
        first = nil
        let second = try SharedMemoryObject(size: size)
        #expect(second.arenaOffset == offset)
        #expect(second.read(offset: 0, count: 3) == [0, 0, 0])
        #expect(second.read(offset: size - 2, count: 2) == [0, 0])
        #expect(arena.recycleSummary.contains("reused"))
    }

    @Test func runsAboveTheLimitAreNotPooled() throws {
        guard let arena = SharedObjectArena.shared else { return }
        let size = SharedObjectArena.recycleMaxRun + 0x4000
        #expect(!arena.recycle(0, size))
        #expect(arena.takeRecycled(size) == nil)
    }
}
