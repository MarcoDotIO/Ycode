// An ordered map of disjoint half-open intervals, for the address space's
// mappings and the physical backings' allocators. Every operation is
// O(log n) expected (n = intervals), plus O(k) for the k intervals an
// operation returns: a treap (randomized balanced search tree) keyed by the
// interval start, each node also holding its subtree's first start, last
// end, and largest gap between consecutive intervals, so the first free
// range of a given size is found without a scan.

/// An element of an `IntervalMap`: [start, end), end > start.
public protocol IntervalMapElement {
    var start: UInt64 { get }
    var end: UInt64 { get }
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
    private var freeNodes: [Int32] = []
    private var root: Int32 = -1
    private var seed: UInt64 = 0x9E37_79B9_7F4A_7C15
    public private(set) var count = 0

    public init() {}

    public var isEmpty: Bool { count == 0 }

    @inline(__always) private func element(_ t: Int32) -> Element { elementTable[Int(t)]! }

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
        let t = floorNode(x)
        return t == Self.none ? nil : element(t)
    }

    /// The interval with the smallest start >= `x`.
    public func ceiling(_ x: UInt64) -> Element? {
        let t = ceilingNode(x)
        return t == Self.none ? nil : element(t)
    }

    /// The interval that contains `x`.
    public func element(containing x: UInt64) -> Element? {
        let t = floorNode(x)
        guard t != Self.none, x < nodes[Int(t)].end else { return nil }
        return element(t)
    }

    /// The intervals that intersect [lo, hi), ascending.
    public func overlapping(_ lo: UInt64, _ hi: UInt64) -> [Element] {
        var out: [Element] = []
        guard lo < hi else { return out }
        collect(root, lo, hi, &out)
        return out
    }

    /// True when some interval intersects [lo, hi).
    public func intersects(_ lo: UInt64, _ hi: UInt64) -> Bool {
        guard lo < hi else { return false }
        let f = floorNode(lo)
        if f != Self.none, nodes[Int(f)].end > lo { return true }
        let c = ceilingNode(lo)
        return c != Self.none && nodes[Int(c)].start < hi
    }

    /// True when the intervals cover all of [lo, hi) without a hole.
    public func covers(_ lo: UInt64, _ hi: UInt64) -> Bool {
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
        var out: [Element] = []
        out.reserveCapacity(count)
        inorder(root, &out)
        return out
    }

    /// The end of the last interval (0 when empty).
    public var lastEnd: UInt64 { root == Self.none ? 0 : nodes[Int(root)].last }

    /// The lowest p >= `from` with [p, p + size) free of every interval
    /// (size > 0). The result may be anywhere above the last interval: the
    /// caller checks its own limit. Nil only when p + size would overflow.
    public func firstGap(from x: UInt64, size: UInt64) -> UInt64? {
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
        precondition(element.end > element.start, "IntervalMap: empty interval")
        let n = makeNode(element)
        let (l, r) = split(root, element.start)
        root = merge(merge(l, n), r)
        count += 1
    }

    /// Removes and returns (ascending) every interval that intersects [lo, hi).
    @discardableResult
    public func extract(_ lo: UInt64, _ hi: UInt64) -> [Element] {
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
        nodes.removeAll()
        elementTable.removeAll()
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
            elementTable[Int(i)] = e
            return i
        }
        nodes.append(node)
        elementTable.append(e)
        return Int32(nodes.count - 1)
    }

    private func release(_ i: Int32) {
        count -= 1
        elementTable[Int(i)] = nil
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
    public let base: UInt64
    public let size: UInt64
    private let allocated = IntervalMap<PlainInterval>()
    /// Bytes allocated.
    public private(set) var bytesInUse: UInt64 = 0

    public init(base: UInt64, size: UInt64) {
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
