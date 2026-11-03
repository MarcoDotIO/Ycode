import Foundation

/// The BOM container (`specs/formats/assets-car.md` §2): numbered blocks,
/// named variables and B-trees, all big-endian.
public struct BOMWriter {
    /// How a tree stores its keys (§2.4).
    public enum KeyStorage: Equatable, Sendable {
        /// Keys in their own blocks; the header says `0xFFFFFFFF`.
        case variable
        /// Keys in their own blocks, all `n` bytes; every leaf carries copies.
        case fixed(Int)
        /// The key is a 32-bit number stored in the entry itself.
        case inline
    }

    var blocks: [[UInt8]] = [[]]
    var variables: [(name: String, block: UInt32)] = []

    public init() {}

    @discardableResult
    public mutating func addBlock(_ b: [UInt8]) -> UInt32 {
        blocks.append(b)
        return UInt32(blocks.count - 1)
    }

    mutating func reserveBlock() -> UInt32 { addBlock([]) }

    mutating func setBlock(_ n: UInt32, _ b: [UInt8]) { blocks[Int(n)] = b }

    public mutating func addVariable(_ name: String, block: UInt32) {
        precondition(name.utf8.count < 256, "a variable name is at most 255 bytes")
        variables.append((name, block))
    }

    public mutating func addVariable(_ name: String, bytes: [UInt8]) { addVariable(name, block: addBlock(bytes)) }

    /// Writes a tree as `name`. `entries` must be sorted the way readers
    /// search them (§2.4); a leaf holds at most `(blockSize − 12) / 8`
    /// entries, and several leaves hang under one branch root.
    public mutating func addTree(_ name: String, entries: [(key: [UInt8], value: [UInt8])],
                                 keys: KeyStorage, blockSize: Int = 4096) {
        let headerBlock = reserveBlock()
        let capacity = max(1, (blockSize - 12) / 8)
        var leaves: [(block: UInt32, firstKey: UInt32)] = []
        let chunks = stride(from: 0, to: max(entries.count, 1), by: capacity).map { Array(entries[$0..<min($0 + capacity, entries.count)]) }
        let leafBlocks = chunks.map { _ in reserveBlock() }
        for (ci, chunk) in chunks.enumerated() {
            var pairs: [(value: UInt32, key: UInt32)] = []
            for e in chunk {
                let v = addBlock(e.value)
                let k: UInt32
                switch keys {
                case .inline:
                    k = e.key.reduce(0) { $0 << 8 | UInt32($1) }
                case .fixed(let n):
                    precondition(e.key.count == n, "fixed-length tree keys must be \(n) bytes")
                    k = addBlock(e.key)
                case .variable:
                    k = addBlock(e.key)
                }
                pairs.append((v, k))
            }
            var w = ByteWriter()
            w.u16be(1)
            w.u16be(UInt16(chunk.count))
            w.u32be(ci + 1 < chunks.count ? leafBlocks[ci + 1] : 0)
            w.u32be(ci > 0 ? leafBlocks[ci - 1] : 0)
            for p in pairs {
                w.u32be(p.value)
                w.u32be(p.key)
            }
            if case .fixed(let n) = keys {
                // The copies readers compare against (§2.4).
                w.zeros(4)
                for e in chunk { w.append(e.key) }
                let size = blockSize + chunk.count * n
                if w.count < size { w.zeros(size - w.count) }
            } else if w.count < blockSize {
                w.zeros(blockSize - w.count)
            }
            setBlock(leafBlocks[ci], w.bytes)
            leaves.append((leafBlocks[ci], pairs.first?.key ?? 0))
        }
        var root = leafBlocks[0]
        if leaves.count > 1 {
            var w = ByteWriter()
            w.u16be(0)
            w.u16be(UInt16(leaves.count))
            w.u32be(0)
            w.u32be(0)
            for l in leaves {
                w.u32be(l.block)
                w.u32be(l.firstKey)
            }
            if case .fixed(let n) = keys {
                w.zeros(4)
                for c in chunks { w.append(c.first?.key ?? [UInt8](repeating: 0, count: n)) }
            }
            if w.count < blockSize { w.zeros(blockSize - w.count) }
            root = addBlock(w.bytes)
        }
        var h = ByteWriter()
        h.tag("tree")
        h.u32be(1)
        h.u32be(root)
        h.u32be(UInt32(blockSize))
        h.u32be(UInt32(entries.count))
        switch keys {
        case .inline:
            h.u8(1)
            h.u32be(0)
        case .fixed(let n):
            h.u8(0)
            h.u32be(UInt32(n))
        case .variable:
            h.u8(0)
            h.u32be(0xFFFF_FFFF)
        }
        h.u32be(0)
        setBlock(headerBlock, h.bytes)
        addVariable(name, block: headerBlock)
    }

    /// The file: header, blocks from offset 512 on 16-byte boundaries, the
    /// variables, then the block table (at least 256 entries, 20 zero bytes
    /// after it).
    public func data() -> Data {
        var w = ByteWriter()
        w.zeros(512)
        var table: [(UInt32, UInt32)] = [(0, 0)]
        for b in blocks.dropFirst() {
            if b.isEmpty {
                table.append((0, 0))
                continue
            }
            w.align(16)
            table.append((UInt32(w.count), UInt32(b.count)))
            w.append(b)
        }
        w.align(16)
        let varsOffset = w.count
        w.u32be(UInt32(variables.count))
        for v in variables {
            w.u32be(v.block)
            let name = Array(v.name.utf8)
            w.u8(UInt8(name.count))
            w.append(name)
        }
        let varsLength = w.count - varsOffset
        w.align(16)
        let indexOffset = w.count
        let count = max(256, table.count)
        w.u32be(UInt32(count))
        for k in 0..<count {
            let e = k < table.count ? table[k] : (0, 0)
            w.u32be(e.0)
            w.u32be(e.1)
        }
        w.zeros(20)
        let indexLength = w.count - indexOffset
        var h = ByteWriter()
        h.append(Array("BOMStore".utf8))
        h.u32be(1)
        h.u32be(UInt32(table.count - 1))
        h.u32be(UInt32(indexOffset))
        h.u32be(UInt32(indexLength))
        h.u32be(UInt32(varsOffset))
        h.u32be(UInt32(varsLength))
        var bytes = w.bytes
        bytes.replaceSubrange(0..<h.count, with: h.bytes)
        return Data(bytes)
    }
}

/// Reads a BOM file: blocks, variables and trees.
public struct BOMReader {
    public struct FormatError: Error, CustomStringConvertible {
        public var message: String
        public var description: String { "BOM: \(message)" }
    }

    public struct TreeInfo: Equatable, Sendable {
        public var root: UInt32
        public var blockSize: UInt32
        public var pathCount: UInt32
        public var inlineKeys: Bool
        public var keyLength: UInt32
    }

    public let bytes: [UInt8]
    public private(set) var table: [(offset: UInt32, length: UInt32)] = []
    public private(set) var variables: [(name: String, block: UInt32)] = []
    public private(set) var usedBlockCount: UInt32 = 0

    public init(_ data: Data) throws {
        bytes = [UInt8](data)
        guard bytes.count >= 32, bytes.starts(with: Array("BOMStore".utf8)) else { throw FormatError(message: "not a BOMStore file") }
        guard bytes.u32be(at: 8) == 1 else { throw FormatError(message: "version \(bytes.u32be(at: 8))") }
        usedBlockCount = bytes.u32be(at: 12)
        let io = Int(bytes.u32be(at: 16)), vo = Int(bytes.u32be(at: 24))
        var r = ByteReader(bytes, offset: io)
        let n = Int(try r.u32be())
        guard n < 1 << 24 else { throw FormatError(message: "block table too large") }
        for _ in 0..<n { table.append((try r.u32be(), try r.u32be())) }
        var v = ByteReader(bytes, offset: vo)
        let nv = Int(try v.u32be())
        for _ in 0..<nv {
            let b = try v.u32be()
            let len = Int(try v.u8())
            variables.append((String(decoding: try v.take(len), as: UTF8.self), b))
        }
    }

    public func block(_ n: UInt32) throws -> ArraySlice<UInt8> {
        guard Int(n) < table.count else { throw FormatError(message: "block \(n) out of range") }
        let e = table[Int(n)]
        guard Int(e.offset) + Int(e.length) <= bytes.count else { throw FormatError(message: "block \(n) past the end") }
        return bytes[Int(e.offset)..<Int(e.offset) + Int(e.length)]
    }

    public func variable(_ name: String) -> UInt32? { variables.first { $0.name == name }?.block }

    public func treeInfo(_ name: String) throws -> TreeInfo {
        guard let vb = variable(name) else { throw FormatError(message: "no variable \(name)") }
        let h = Array(try block(vb))
        guard h.count >= 29, h.starts(with: Array("tree".utf8)) else { throw FormatError(message: "\(name) is not a tree") }
        return TreeInfo(root: h.u32be(at: 8), blockSize: h.u32be(at: 12), pathCount: h.u32be(at: 16),
                        inlineKeys: h[20] == 1, keyLength: h.u32be(at: 21))
    }

    /// One leaf's entries and, for fixed-length keys, the key copies it carries.
    public struct Leaf {
        public var block: UInt32
        public var forward: UInt32
        public var backward: UInt32
        public var entries: [(value: UInt32, key: UInt32)]
        public var keyCopies: [[UInt8]]
    }

    /// The leaves in order: down the first child of each branch, then along
    /// the forward links.
    public func leaves(_ name: String) throws -> [Leaf] {
        let info = try treeInfo(name)
        var node = info.root
        var guardCount = 0
        while true {
            let b = Array(try block(node))
            guard b.count >= 12 else { throw FormatError(message: "short tree node \(node)") }
            if b.u16be(at: 0) == 1 { break }
            guard b.u16be(at: 2) > 0 else { throw FormatError(message: "empty branch \(node)") }
            node = b.u32be(at: 12)
            guardCount += 1
            guard guardCount < 64 else { throw FormatError(message: "tree too deep") }
        }
        var out: [Leaf] = []
        var seen = Set<UInt32>()
        while node != 0, seen.insert(node).inserted {
            let b = Array(try block(node))
            let count = Int(b.u16be(at: 2))
            guard b.count >= 12 + count * 8 else { throw FormatError(message: "short leaf \(node)") }
            let entries = (0..<count).map { (b.u32be(at: 12 + $0 * 8), b.u32be(at: 16 + $0 * 8)) }
            var copies: [[UInt8]] = []
            if !info.inlineKeys, info.keyLength != 0xFFFF_FFFF, info.keyLength > 0 {
                let kl = Int(info.keyLength), start = 12 + count * 8 + 4
                if b.count >= start + count * kl {
                    copies = (0..<count).map { Array(b[start + $0 * kl..<start + ($0 + 1) * kl]) }
                }
            }
            out.append(Leaf(block: node, forward: b.u32be(at: 4), backward: b.u32be(at: 8), entries: entries, keyCopies: copies))
            node = b.u32be(at: 4)
        }
        return out
    }

    /// Every entry of a tree in order, keys and values as bytes (an inline
    /// key comes back as its four big-endian bytes).
    public func tree(_ name: String) throws -> [(key: [UInt8], value: [UInt8])] {
        let info = try treeInfo(name)
        var out: [(key: [UInt8], value: [UInt8])] = []
        for leaf in try leaves(name) {
            for e in leaf.entries {
                let key: [UInt8]
                if info.inlineKeys {
                    key = [UInt8(e.key >> 24), UInt8(e.key >> 16 & 0xFF), UInt8(e.key >> 8 & 0xFF), UInt8(e.key & 0xFF)]
                } else {
                    key = Array(try block(e.key))
                }
                out.append((key, Array(try block(e.value))))
            }
        }
        return out
    }
}
