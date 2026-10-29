// An ordered map of disjoint half-open intervals, for the address space's
// mappings and the physical backings' allocators. Every operation is
// O(log n) expected (n = intervals), plus O(k) for the k intervals an
// operation returns: a treap (randomized balanced search tree) keyed by the
// interval start, each node also holding its subtree's first start, last
// end, and largest gap between consecutive intervals, so the first free
// range of a given size is found without a scan.

#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif
import Synchronization

/// Diagnostics: catches two threads changing one map at once (the map has
/// no lock of its own; its owner's lock must serialize every change). With
/// `YCODE_DEBUG_RW_GUARD=1` it also catches a reader overlapping a writer:
/// readers count themselves in, writers own the map, and whichever side
/// arrives second traps, printing its own call chain and the one the other
/// side recorded when it entered (`DebugAccessGuard.captureFrames`).
final class ConcurrentUseGuard: @unchecked Sendable {
    private let holder = Atomic<UInt>(0)
    private let readers = Atomic<Int>(0)
    private let readSeq = Atomic<UInt>(0)
    /// Recorded entries: slot 0 is the writer, 1...readerSlots readers. Each
    /// is [thread, active, what (StaticString address), frames...].
    private static let readerSlots = 8
    private static let words = 3 + DebugAccessGuard.frameCount
    private let record: UnsafeMutablePointer<UInt>?
    init() {
        if DebugAccessGuard.enabled {
            let n = (1 + Self.readerSlots) * Self.words
            record = .allocate(capacity: n)
            record!.initialize(repeating: 0, count: n)
        } else {
            record = nil
        }
    }
    deinit { record?.deallocate() }
    @inline(__always) private static var me: UInt {
        #if canImport(Darwin)
        UInt(bitPattern: pthread_self())
        #else
        UInt(pthread_self())
        #endif
    }
    private func note(_ slot: Int, _ what: StaticString) {
        guard let record else { return }
        let r = record + slot * Self.words
        r[0] = Self.me
        r[2] = UInt(bitPattern: what.utf8Start)
        for i in 0..<DebugAccessGuard.frameCount { r[3 + i] = 0 }
        if DebugAccessGuard.mode != 2, let capture = DebugAccessGuard.captureFrames { _ = capture(r + 3, Int32(DebugAccessGuard.frameCount)) }
        r[1] = 1
    }
    func enter(_ what: StaticString) {
        let (exchanged, other) = holder.compareExchange(expected: 0, desired: Self.me, ordering: .sequentiallyConsistent)
        if !exchanged {
            if record != nil { trap(what, "writer meets writer", otherSlots: [0]) }
            preconditionFailure("\(what): concurrent use (thread 0x\(String(other, radix: 16)) is inside, this thread 0x\(String(Self.me, radix: 16)))")
        }
        guard record != nil else { return }
        if DebugAccessGuard.mode == 3 { note(0, what); return }
        note(0, what)
        if readers.load(ordering: .sequentiallyConsistent) > 0 {
            trap(what, "writer meets reader(s)", otherSlots: Array(1...Self.readerSlots))
        }
    }
    func leave() {
        if let record { record[1] = 0 }
        holder.store(0, ordering: .sequentiallyConsistent)
    }
    /// A lookup starts (no-op unless `YCODE_DEBUG_RW_GUARD=1`). Returns the
    /// token for `endRead`.
    @inline(__always) func beginRead(_ what: StaticString) -> Int {
        guard record != nil else { return -1 }
        return beginReadChecked(what)
    }
    @inline(never) private func beginReadChecked(_ what: StaticString) -> Int {
        if DebugAccessGuard.mode == 3 { note(1, what); return -1 }
        let w = holder.load(ordering: .sequentiallyConsistent)
        if w == Self.me { return -1 }  // a read inside this thread's own change
        readers.add(1, ordering: .sequentiallyConsistent)
        let slot = 1 + Int(readSeq.add(1, ordering: .relaxed).oldValue % UInt(Self.readerSlots))
        note(slot, what)
        let w2 = holder.load(ordering: .sequentiallyConsistent)
        if w2 != 0 && w2 != Self.me { trap(what, "reader meets writer", otherSlots: [0]) }
        return slot
    }
    @inline(__always) func endRead(_ token: Int) {
        guard token > 0, let record else { return }
        let r = record + token * Self.words
        if r[0] == Self.me { r[1] = 0 }
        readers.subtract(1, ordering: .sequentiallyConsistent)
    }
    @inline(never) private func trap(_ what: StaticString, _ kind: String, otherSlots: [Int]) -> Never {
        func hx(_ v: UInt) -> String { "0x" + String(v, radix: 16) }
        func say(_ text: String) { var t = text + "\n"; _ = t.withUTF8 { write(2, $0.baseAddress, $0.count) } }
        var mine = [UInt](repeating: 0, count: DebugAccessGuard.frameCount)
        if let capture = DebugAccessGuard.captureFrames { _ = mine.withUnsafeMutableBufferPointer { capture($0.baseAddress, Int32($0.count)) } }
        say("RWGUARD: \(kind): this thread \(hx(Self.me)) in \(what), readers \(readers.load(ordering: .relaxed)), writer \(hx(holder.load(ordering: .relaxed))), map guard \(hx(UInt(bitPattern: ObjectIdentifier(self).hashValue)))")
        say("RWGUARD:   this side frames: " + mine.filter { $0 != 0 }.map(hx).joined(separator: " "))
        if let record {
            for slot in otherSlots {
                let r = record + slot * Self.words
                guard r[1] != 0, r[0] != Self.me else { continue }
                let name = r[2] == 0 ? "?" : String(cString: UnsafePointer<CChar>(bitPattern: r[2])!)
                let frames = (0..<DebugAccessGuard.frameCount).map { r[3 + $0] }.filter { $0 != 0 }
                say("RWGUARD:   other side (\(slot == 0 ? "writer" : "reader")) thread \(hx(r[0])) in \(name): " + frames.map(hx).joined(separator: " "))
            }
        }
        DebugAccessGuard.printCodeMappings(say)
        preconditionFailure("IntervalMap: \(kind) in \(what)")
    }
}

/// Diagnostics: the reader/writer check of `ConcurrentUseGuard`.
public enum DebugAccessGuard {
    /// `YCODE_DEBUG_RW_GUARD=1` (full check), `=2` (the check without call
    /// chains), `=3` (no check: only the call-chain walk on every lookup).
    public static let mode = getenv("YCODE_DEBUG_RW_GUARD").flatMap { Int(String(cString: $0)) } ?? 0
    /// True when `YCODE_DEBUG_RW_GUARD` is set to a nonzero mode.
    public static var enabled: Bool { mode != 0 }
    static let frameCount = 16
    /// Fills up to `count` return addresses of the calling thread (the VMM
    /// installs a frame-pointer walk); returns how many.
    nonisolated(unsafe) public static var captureFrames: (@convention(c) (UnsafeMutablePointer<UInt>?, Int32) -> Int32)?
    static func printCodeMappings(_ say: (String) -> Void) {
        let fd = open("/proc/self/maps", O_RDONLY)
        guard fd >= 0 else { return }
        defer { close(fd) }
        var bytes: [UInt8] = []
        var buffer = [UInt8](repeating: 0, count: 65536)
        while true {
            let n = buffer.withUnsafeMutableBytes { read(fd, $0.baseAddress, $0.count) }
            if n <= 0 { break }
            bytes += buffer[0..<n]
        }
        for line in String(decoding: bytes, as: UTF8.self).split(separator: "\n") where line.contains("r-xp")
            && (line.contains("ycode-simd") || line.contains("libswift") || line.contains("libc.so") || line.contains("libdispatch")) {
            say("RWGUARD:   map " + line)
        }
    }
}

/// An element of an `IntervalMap`: [start, end), end > start.
public protocol IntervalMapElement {
    /// The first address in the interval.
    var start: UInt64 { get }
    /// The address one past the last; greater than `start`.
    var end: UInt64 { get }
}

/// Diagnostics: a hardware write watchpoint on one element of one map
/// (`IntervalMap(hardwareWatch:)`), so a write from outside the map raises
/// SIGTRAP in the writing thread. The VMM installs `arm`/`disarm`.
public enum DebugHardwareWatch {
    /// Arms watchpoint `slot` on the 8 bytes at `address`; returns > 0 on
    /// success. Nil: hardware watches are off.
    nonisolated(unsafe) public static var arm: ((_ slot: Int, _ address: UInt64) -> Int32)?
    /// Disarms watchpoint `slot`.
    nonisolated(unsafe) public static var disarm: ((_ slot: Int) -> Void)?
    static let lock = NSLockLike()
    static let slots = 4
    /// The watched elements by slot; `next` is the slot reused next.
    nonisolated(unsafe) static var targets: [(map: ObjectIdentifier, index: Int)?] = Array(repeating: nil, count: 4)
    nonisolated(unsafe) static var next = 0
}

/// Diagnostics storage for `IntervalMap(watch:)`: element slots in their own
/// mmap'd pages, read-only except during the map's own writes.
final class WatchedSlots<Element> {
    private let slots: UnsafeMutablePointer<Element?>
    private let capacity = 1 << 16
    private let bytes: Int
    private(set) var count = 0
    var base: UInt { UInt(bitPattern: slots) }

    init() {
        bytes = (MemoryLayout<Element?>.stride * capacity + 0xFFFF) & ~0xFFFF
        let p = mmap(nil, bytes, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANONYMOUS, -1, 0)!
        slots = p.bindMemory(to: Element?.self, capacity: capacity)
        slots.initialize(repeating: nil, count: capacity)
        mprotect(p, bytes, PROT_READ)
    }

    private func writable(_ i: Int, _ on: Bool) {
        let page = UInt(sysconf(Int32(_SC_PAGESIZE)))
        let a = UInt(bitPattern: slots + i) & ~(page - 1)
        let b = (UInt(bitPattern: slots + i) + UInt(MemoryLayout<Element?>.stride) + page - 1) & ~(page - 1)
        mprotect(UnsafeMutableRawPointer(bitPattern: a), Int(b - a), on ? PROT_READ | PROT_WRITE : PROT_READ)
    }

    func get(_ i: Int) -> Element? {
        precondition(i >= 0 && i < count, "WatchedSlots: index \(i) of \(count)")
        return slots[i]
    }

    func set(_ i: Int, _ e: Element?) {
        precondition(i >= 0 && i < count)
        writable(i, true)
        slots[i] = e
        writable(i, false)
    }

    func append(_ e: Element) {
        precondition(count < capacity, "WatchedSlots: full")
        writable(count, true)
        slots[count] = e
        writable(count, false)
        count += 1
    }

    func removeAll() {
        mprotect(UnsafeMutableRawPointer(slots), bytes, PROT_READ | PROT_WRITE)
        for i in 0..<count { slots[i] = nil }
        mprotect(UnsafeMutableRawPointer(slots), bytes, PROT_READ)
        count = 0
    }
}

/// A bare interval (allocators).
public struct PlainInterval: IntervalMapElement, Equatable, Sendable {
    public var start: UInt64
    public var end: UInt64
    public init(start: UInt64, end: UInt64) {
        self.start = start
        self.end = end
    }
}

/// Disjoint intervals, ordered by start. Callers keep them disjoint: an
/// insert must not overlap what is there. The tree works on plain node
/// records; elements live in a side table and are copied only when returned.
public final class IntervalMap<Element: IntervalMapElement> {
    private struct Node {
        var start: UInt64
        var end: UInt64
        var left: Int32
        var right: Int32
        var priority: UInt32
        /// Subtree aggregates: first start, last end, largest inner gap.
        var first: UInt64
        var last: UInt64
        var gap: UInt64
    }

    private static var none: Int32 { -1 }
    private var nodes: [Node] = []
    private var elementTable: [Element?] = []
    /// Diagnostics (`watch`): the elements live in their own pages, kept
    /// read-only except while this map writes them, so a stray write from
    /// anywhere else faults at the writer.
    private var watched: WatchedSlots<Element>?
    private var freeNodes: [Int32] = []
    private var root: Int32 = -1
    private var seed: UInt64 = 0x9E37_79B9_7F4A_7C15
    /// The number of intervals in the map.
    public private(set) var count = 0
    private let useGuard = ConcurrentUseGuard()

    /// An empty map without diagnostics.
    public init() {}

    /// `watch`: see `watched` (diagnostics; trivial element types only).
    public init(watch: Bool, hardwareWatch: Bool = false) {
        if watch { watched = WatchedSlots<Element>() }
        self.hardwareWatch = hardwareWatch && DebugHardwareWatch.arm != nil
    }
    private var hardwareWatch = false

    deinit {
        if hardwareWatch { hwRelease(nil) }
    }

    /// Before this map writes element `i` (nil: all, or a buffer move): drop
    /// the watches on it.
    private func hwRelease(_ i: Int?) {
        DebugHardwareWatch.lock.withLock {
            for s in 0..<DebugHardwareWatch.slots {
                guard let t = DebugHardwareWatch.targets[s], t.map == ObjectIdentifier(self), i == nil || i == t.index else { continue }
                DebugHardwareWatch.disarm?(s)
                DebugHardwareWatch.targets[s] = nil
            }
        }
    }

    /// After this map wrote element `i`: watch it (the oldest watch makes room).
    private func hwClaim(_ i: Int) {
        DebugHardwareWatch.lock.withLock {
            guard i < elementTable.count, elementTable[i] != nil else { return }
            let s = DebugHardwareWatch.next
            DebugHardwareWatch.next = (s + 1) % DebugHardwareWatch.slots
            let address = elementTable.withUnsafeBufferPointer { UInt64(UInt(bitPattern: $0.baseAddress! + i)) + 8 }
            if let n = DebugHardwareWatch.arm?(s, address), n > 0 {
                DebugHardwareWatch.targets[s] = (ObjectIdentifier(self), i)
            } else {
                DebugHardwareWatch.targets[s] = nil
            }
        }
    }

    private func slot(_ i: Int) -> Element? { watched?.get(i) ?? (watched == nil ? elementTable[i] : nil) }

    // swiftlint:disable:next empty_count - this is isEmpty
    public var isEmpty: Bool { count == 0 }

    @inline(__always) private func element(_ t: Int32) -> Element { slot(Int(t))! }

    // MARK: Queries

    private func floorNode(_ x: UInt64) -> Int32 {
        var t = root, best: Int32 = Self.none
        while t != Self.none {
            if nodes[Int(t)].start <= x { best = t; t = nodes[Int(t)].right } else { t = nodes[Int(t)].left }
        }
        return best
    }

    private func ceilingNode(_ x: UInt64) -> Int32 {
        var t = root, best: Int32 = Self.none
        while t != Self.none {
            if nodes[Int(t)].start >= x { best = t; t = nodes[Int(t)].left } else { t = nodes[Int(t)].right }
        }
        return best
    }

    /// The interval with the greatest start <= `x`.
    public func floor(_ x: UInt64) -> Element? {
        let readToken = useGuard.beginRead("IntervalMap.floor")
        defer { useGuard.endRead(readToken) }
        let t = floorNode(x)
        return t == Self.none ? nil : element(t)
    }

    /// The interval with the smallest start >= `x`.
    public func ceiling(_ x: UInt64) -> Element? {
        let readToken = useGuard.beginRead("IntervalMap.ceiling")
        defer { useGuard.endRead(readToken) }
        let t = ceilingNode(x)
        return t == Self.none ? nil : element(t)
    }

    /// The interval that contains `x`.
    public func element(containing x: UInt64) -> Element? {
        let readToken = useGuard.beginRead("IntervalMap.element(containing:)")
        defer { useGuard.endRead(readToken) }
        let t = floorNode(x)
        guard t != Self.none, x < nodes[Int(t)].end else { return nil }
        return element(t)
    }

    /// The intervals that intersect [lo, hi), ascending.
    public func overlapping(_ lo: UInt64, _ hi: UInt64) -> [Element] {
        let readToken = useGuard.beginRead("IntervalMap.overlapping")
        defer { useGuard.endRead(readToken) }
        var out: [Element] = []
        guard lo < hi else { return out }
        collect(root, lo, hi, &out)
        return out
    }

    /// True when some interval intersects [lo, hi).
    public func intersects(_ lo: UInt64, _ hi: UInt64) -> Bool {
        let readToken = useGuard.beginRead("IntervalMap.intersects")
        defer { useGuard.endRead(readToken) }
        guard lo < hi else { return false }
        let f = floorNode(lo)
        if f != Self.none, nodes[Int(f)].end > lo { return true }
        let c = ceilingNode(lo)
        return c != Self.none && nodes[Int(c)].start < hi
    }

    /// True when the intervals cover all of [lo, hi) without a hole.
    public func covers(_ lo: UInt64, _ hi: UInt64) -> Bool {
        let readToken = useGuard.beginRead("IntervalMap.covers")
        defer { useGuard.endRead(readToken) }
        guard lo < hi else { return true }
        var cursor = lo
        var t = floorNode(lo)
        if t == Self.none || nodes[Int(t)].end <= lo { return false }
        // Walk successors while they continue the run.
        while true {
            cursor = nodes[Int(t)].end
            if cursor >= hi { return true }
            t = ceilingNode(cursor)
            if t == Self.none || nodes[Int(t)].start != cursor { return false }
        }
    }

    /// Every interval, ascending.
    public var elements: [Element] {
        let readToken = useGuard.beginRead("IntervalMap.elements")
        defer { useGuard.endRead(readToken) }
        var out: [Element] = []
        out.reserveCapacity(count)
        inorder(root, &out)
        return out
    }

    /// The end of the last interval (0 when empty).
    public var lastEnd: UInt64 {
        let readToken = useGuard.beginRead("IntervalMap.lastEnd")
        defer { useGuard.endRead(readToken) }
        return root == Self.none ? 0 : nodes[Int(root)].last
    }

    /// The lowest p >= `from` with [p, p + size) free of every interval
    /// (size > 0). The result may be anywhere above the last interval: the
    /// caller checks its own limit. Nil only when p + size would overflow.
    public func firstGap(from x: UInt64, size: UInt64) -> UInt64? {
        let readToken = useGuard.beginRead("IntervalMap.firstGap")
        defer { useGuard.endRead(readToken) }
        var candidate = x
        let f = floorNode(x)
        if f != Self.none, nodes[Int(f)].end > x { candidate = nodes[Int(f)].end }
        let c = ceilingNode(candidate)
        guard c != Self.none else { return fits(candidate, size) }
        let cStart = nodes[Int(c)].start
        if cStart - candidate >= size { return candidate }
        // The first gap after an interval starting at or above cStart.
        var prevEnd: UInt64 = 0
        var havePrev = false
        if let p = search(root, cStart, size, &prevEnd, &havePrev) { return p }
        return fits(lastEnd, size)
    }

    private func fits(_ p: UInt64, _ size: UInt64) -> UInt64? { p <= UInt64.max - size ? p : nil }

    // MARK: Changes

    /// Inserts `element`, which must not overlap any interval.
    public func insert(_ element: Element) {
        useGuard.enter("IntervalMap.insert")
        defer { useGuard.leave() }
        precondition(element.end > element.start, "IntervalMap: empty interval")
        // Disjointness (O(log n)): an overlap would corrupt the subtree
        // aggregates and trap later, far from the culprit.
        if intersects(element.start, element.end) {
            let f = floor(element.start), c = ceiling(element.start)
            preconditionFailure("IntervalMap: insert of [0x\(String(element.start, radix: 16)), 0x\(String(element.end, radix: 16))) "
                + "overlaps " + [f, c].compactMap { $0 }.map { "[0x\(String($0.start, radix: 16)), 0x\(String($0.end, radix: 16)))" }
                    .joined(separator: " / "))
        }
        let n = makeNode(element)
        let (l, r) = split(root, element.start)
        root = merge(merge(l, n), r)
        count += 1
    }

    /// Removes and returns (ascending) every interval that intersects [lo, hi).
    @discardableResult
    public func extract(_ lo: UInt64, _ hi: UInt64) -> [Element] {
        useGuard.enter("IntervalMap.extract")
        defer { useGuard.leave() }
        guard lo < hi, root != Self.none else { return [] }
        var (a, b) = split(root, lo)
        var out: [Element] = []
        // The last interval below `lo` may reach into the range.
        if a != Self.none, nodes[Int(a)].last > lo {
            let (rest, lastNode) = splitLast(a)
            a = rest
            out.append(element(lastNode))
            release(lastNode)
        }
        let (m, c) = split(b, hi)
        b = c
        drain(m, &out)
        root = merge(a, b)
        return out
    }

    /// Removes every interval.
    public func removeAll() {
        useGuard.enter("IntervalMap.removeAll")
        defer { useGuard.leave() }
        nodes.removeAll()
        if hardwareWatch { hwRelease(nil) }
        elementTable.removeAll()
        watched?.removeAll()
        freeNodes.removeAll()
        root = Self.none
        count = 0
    }

    // MARK: Treap internals

    private func makeNode(_ e: Element) -> Int32 {
        seed ^= seed << 13
        seed ^= seed >> 7
        seed ^= seed << 17
        let node = Node(start: e.start, end: e.end, left: Self.none, right: Self.none,
                        priority: UInt32(truncatingIfNeeded: seed >> 16), first: e.start, last: e.end, gap: 0)
        if let i = freeNodes.popLast() {
            nodes[Int(i)] = node
            if hardwareWatch { hwRelease(Int(i)) }
            if let watched { watched.set(Int(i), e) } else { elementTable[Int(i)] = e }
            if hardwareWatch { hwClaim(Int(i)) }
            return i
        }
        nodes.append(node)
        // An append may move the buffer: the watch goes with the old one.
        if hardwareWatch && elementTable.count == elementTable.capacity { hwRelease(nil) }
        if let watched { watched.append(e) } else { elementTable.append(e) }
        if hardwareWatch { hwClaim(elementTable.count - 1) }
        return Int32(nodes.count - 1)
    }

    private func release(_ i: Int32) {
        count -= 1
        if hardwareWatch { hwRelease(Int(i)) }
        if let watched { watched.set(Int(i), nil) } else { elementTable[Int(i)] = nil }
        freeNodes.append(i)
    }

    private func update(_ t: Int32) {
        let i = Int(t)
        let l = nodes[i].left, r = nodes[i].right
        let start = nodes[i].start, end = nodes[i].end
        var first = start, last = end, gap: UInt64 = 0
        if l != Self.none {
            let li = Int(l)
            first = nodes[li].first
            gap = max(nodes[li].gap, start - nodes[li].last)
        }
        if r != Self.none {
            let ri = Int(r)
            last = nodes[ri].last
            gap = max(gap, nodes[ri].gap, nodes[ri].first - end)
        }
        nodes[i].first = first
        nodes[i].last = last
        nodes[i].gap = gap
    }

    /// (starts < key, starts >= key)
    private func split(_ t: Int32, _ key: UInt64) -> (Int32, Int32) {
        guard t != Self.none else { return (Self.none, Self.none) }
        if nodes[Int(t)].start < key {
            let (l, r) = split(nodes[Int(t)].right, key)
            nodes[Int(t)].right = l
            update(t)
            return (t, r)
        } else {
            let (l, r) = split(nodes[Int(t)].left, key)
            nodes[Int(t)].left = r
            update(t)
            return (l, t)
        }
    }

    /// (everything but the last node, the last node)
    private func splitLast(_ t: Int32) -> (Int32, Int32) {
        if nodes[Int(t)].right == Self.none {
            let l = nodes[Int(t)].left
            nodes[Int(t)].left = Self.none
            update(t)
            return (l, t)
        }
        let (rest, last) = splitLast(nodes[Int(t)].right)
        nodes[Int(t)].right = rest
        update(t)
        return (t, last)
    }

    private func merge(_ a: Int32, _ b: Int32) -> Int32 {
        if a == Self.none { return b }
        if b == Self.none { return a }
        if nodes[Int(a)].priority > nodes[Int(b)].priority {
            let m = merge(nodes[Int(a)].right, b)
            nodes[Int(a)].right = m
            update(a)
            return a
        } else {
            let m = merge(a, nodes[Int(b)].left)
            nodes[Int(b)].left = m
            update(b)
            return b
        }
    }

    private func drain(_ t: Int32, _ out: inout [Element]) {
        guard t != Self.none else { return }
        drain(nodes[Int(t)].left, &out)
        out.append(element(t))
        drain(nodes[Int(t)].right, &out)
        release(t)
    }

    private func inorder(_ t: Int32, _ out: inout [Element]) {
        guard t != Self.none else { return }
        inorder(nodes[Int(t)].left, &out)
        out.append(element(t))
        inorder(nodes[Int(t)].right, &out)
    }

    private func collect(_ t: Int32, _ lo: UInt64, _ hi: UInt64, _ out: inout [Element]) {
        guard t != Self.none else { return }
        let i = Int(t)
        if nodes[i].last <= lo || nodes[i].first >= hi { return }
        collect(nodes[i].left, lo, hi, &out)
        if nodes[i].start < hi && nodes[i].end > lo { out.append(element(t)) }
        collect(nodes[i].right, lo, hi, &out)
    }

    /// The first gap of at least `size` after an interval whose start is
    /// >= key, in order; `prevEnd` carries the end of the interval before.
    private func search(_ t: Int32, _ key: UInt64, _ size: UInt64, _ prevEnd: inout UInt64, _ havePrev: inout Bool) -> UInt64? {
        guard t != Self.none else { return nil }
        let i = Int(t)
        if nodes[i].start < key { return search(nodes[i].right, key, size, &prevEnd, &havePrev) }
        if let p = search(nodes[i].left, key, size, &prevEnd, &havePrev) { return p }
        if havePrev, nodes[i].start - prevEnd >= size { return prevEnd }
        prevEnd = nodes[i].end
        havePrev = true
        return searchAll(nodes[i].right, size, &prevEnd, &havePrev)
    }

    /// As `search` for a subtree that lies entirely in the searched part.
    private func searchAll(_ t: Int32, _ size: UInt64, _ prevEnd: inout UInt64, _ havePrev: inout Bool) -> UInt64? {
        guard t != Self.none else { return nil }
        let i = Int(t)
        let entry = havePrev ? nodes[i].first - prevEnd : 0
        if entry < size && nodes[i].gap < size {
            prevEnd = nodes[i].last
            havePrev = true
            return nil
        }
        if let p = searchAll(nodes[i].left, size, &prevEnd, &havePrev) { return p }
        if havePrev, nodes[i].start - prevEnd >= size { return prevEnd }
        prevEnd = nodes[i].end
        havePrev = true
        return searchAll(nodes[i].right, size, &prevEnd, &havePrev)
    }
}

/// A first-fit allocator of 16 KiB-aligned ranges inside [base, base+size)
/// (the backings' anonymous pools): O(log n) per call.
public final class RangeAllocator {
    /// The first address of the pool.
    public let base: UInt64
    /// The pool's length in bytes.
    public let size: UInt64
    private let allocated: IntervalMap<PlainInterval>
    /// Diagnostics: `YCODE_DEBUG_WATCH_MAPS=1` (see `IntervalMap(watch:)`).
    static let watchMaps = getenv("YCODE_DEBUG_WATCH_MAPS").map { String(cString: $0) == "1" } ?? false

    /// Bytes allocated.
    public private(set) var bytesInUse: UInt64 = 0

    /// `hardwareWatch`: see `IntervalMap(hardwareWatch:)` (diagnostics).
    public init(base: UInt64, size: UInt64, hardwareWatch: Bool = false) {
        allocated = IntervalMap<PlainInterval>(watch: RangeAllocator.watchMaps, hardwareWatch: hardwareWatch)
        self.base = base
        self.size = size
    }

    /// The lowest free run of `size` bytes, now allocated; nil if none.
    public func allocate(_ length: UInt64) -> UInt64? {
        guard length > 0, let start = allocated.firstGap(from: base, size: length), start >= base,
              start - base <= size, length <= size - (start - base) else { return nil }
        allocated.insert(PlainInterval(start: start, end: start + length))
        bytesInUse += length
        return start
    }

    /// True when all of [start, start+length) is allocated.
    public func isAllocated(_ start: UInt64, _ length: UInt64) -> Bool {
        length > 0 && start <= UInt64.max - length && allocated.covers(start, start + length)
    }

    /// Records [start, start+length), which must be free, as allocated.
    public func mark(_ start: UInt64, _ length: UInt64) {
        guard length > 0 else { return }
        allocated.insert(PlainInterval(start: start, end: start + length))
        bytesInUse += length
    }

    /// Frees everything; returns what was allocated (ascending).
    public func takeAll() -> [Range<UInt64>] {
        let all = allocated.elements.map { $0.start..<$0.end }
        allocated.removeAll()
        bytesInUse = 0
        return all
    }

    /// Frees the allocated parts of [start, start+length); returns the
    /// freed parts (ascending).
    @discardableResult
    public func free(_ start: UInt64, _ length: UInt64) -> [Range<UInt64>] {
        guard length > 0, start <= UInt64.max - length else { return [] }
        let end = start + length
        var freed: [Range<UInt64>] = []
        for r in allocated.extract(start, end) {
            if r.start < start { allocated.insert(PlainInterval(start: r.start, end: start)) }
            if r.end > end { allocated.insert(PlainInterval(start: end, end: r.end)) }
            let lo = max(r.start, start), hi = min(r.end, end)
            freed.append(lo..<hi)
            bytesInUse -= hi - lo
        }
        return freed
    }
}
