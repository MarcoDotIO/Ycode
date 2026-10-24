import Foundation

/// UTF-16 offsets of line starts, for mapping between offsets and 1-based
/// line numbers.
public struct LineIndex: Equatable, Sendable {
    public private(set) var starts: [Int] = [0]
    public private(set) var length = 0

    public init(_ text: String) {
        var offset = 0
        for unit in text.utf16 {
            offset += 1
            if unit == 10 { starts.append(offset) }
        }
        length = offset
    }

    /// Updates the index for an edit: `range` (in the old text) was
    /// replaced by `replacement`. Only the line starts inside the edit are
    /// recomputed; later ones shift.
    public mutating func applyEdit(range: NSRange, replacement: String) {
        func firstStart(after o: Int) -> Int {
            var lo = 0, hi = starts.count
            while lo < hi { let mid = (lo + hi) / 2; if starts[mid] <= o { lo = mid + 1 } else { hi = mid } }
            return lo
        }
        let lo = firstStart(after: range.location), hi = firstStart(after: NSMaxRange(range))
        var added: [Int] = []
        var k = 0
        for unit in replacement.utf16 {
            k += 1
            if unit == 10 { added.append(range.location + k) }
        }
        let delta = k - range.length
        starts.replaceSubrange(lo..<hi, with: added)
        for i in (lo + added.count)..<starts.count { starts[i] += delta }
        length += delta
    }

    public var lineCount: Int { starts.count }

    /// The 1-based line that contains `offset`.
    public func line(at offset: Int) -> Int {
        var lo = 0, hi = starts.count - 1
        while lo < hi {
            let mid = (lo + hi + 1) / 2
            if starts[mid] <= offset { lo = mid } else { hi = mid - 1 }
        }
        return lo + 1
    }

    /// The UTF-16 range of a 1-based line, without its newline.
    public func range(ofLine line: Int) -> NSRange? {
        guard line >= 1, line <= starts.count else { return nil }
        let start = starts[line - 1]
        let end = line < starts.count ? starts[line] - 1 : length
        return NSRange(location: start, length: max(0, end - start))
    }
}
