import Foundation

/// The template chooser's and the options step's measurements, shared by
/// the macOS sheet and the Linux one (`specs/ide/parity-inventory.md`
/// P-181, P-182; beta 5).
public enum TemplateChooserMetrics {
    /// The sheet (New Project, New File).
    public static let sheetWidth = 720.0, sheetHeight = 480.0
    /// The headings are regular weight, 13 points (P-181, P-182).
    public static let headingSize = 13.0
    /// The filter field: always drawn, 202 points wide.
    public static let filterWidth = 202.0
    /// The platform tabs' label size.
    public static let platformLabelSize = 10.0
    /// The grid: five columns on a 137-point pitch (133-point tiles, 4 apart).
    public static let columns = 5
    public static let tileWidth = 133.0, tileHeight = 92.0, columnSpacing = 4.0
    public static var columnPitch: Double { tileWidth + columnSpacing }
    /// The outlined glyph's box (≈ 31.5 points of ink).
    public static let iconSide = 32.0
    /// A section header's darker band.
    public static let bandHeight = 22.0
    /// Next fades the options step in over about 190 ms (B5-MOTION's shared
    /// constant).
    public static let optionsFadeDuration = Motion.newProjectOptionsFadeIn

    // MARK: Options step (P-182)

    /// The labels' column, then the controls 8 points later.
    public static let labelColumnWidth = 170.0, labelGap = 8.0
    /// Every control in the column is 267 points wide.
    public static let fieldWidth = 267.0
    /// Rows (pop-ups) are 20 points tall on a 33-point pitch.
    public static let rowHeight = 20.0, rowPitch = 33.0
    public static var rowSpacing: Double { rowPitch - rowHeight }
    /// The pop-ups' fill in the dark appearance.
    public static let popUpFillDark: UInt32 = 0x2F2F31
    /// The options start this far below the heading.
    public static let optionsTop = 28.0
}

/// Moving the selection in a template grid with the arrow keys (P-181),
/// the same on both IDEs: Left and Right step through the templates in
/// order, across sections; Up and Down keep the column, moving into the
/// previous or next section's nearest row.
public enum TemplateGridNavigation {
    public enum Key: Sendable { case left, right, up, down }

    /// - Parameters:
    ///   - sectionCounts: the number of templates in each shown section.
    ///   - index: the selected template's index over all sections (nil:
    ///     none selected, any key selects the first).
    /// - Returns: the index to select, or nil when there are none.
    public static func index(moving key: Key, from index: Int?, sectionCounts: [Int], columns: Int) -> Int? {
        let total = sectionCounts.reduce(0, +)
        guard total > 0, columns > 0 else { return nil }
        guard let index, index >= 0, index < total else { return 0 }
        switch key {
        case .left: return max(0, index - 1)
        case .right: return min(total - 1, index + 1)
        case .up, .down:
            var ranges: [Range<Int>] = []
            var start = 0
            for c in sectionCounts where c > 0 {
                ranges.append(start..<(start + c))
                start += c
            }
            guard let s = ranges.firstIndex(where: { $0.contains(index) }) else { return index }
            let r = ranges[s], local = index - r.lowerBound, column = local % columns
            let lastRow = (r.count - 1) / columns
            if key == .down {
                if local / columns < lastRow { return min(index + columns, r.upperBound - 1) }
                guard s + 1 < ranges.count else { return index }
                let n = ranges[s + 1]
                return n.lowerBound + min(column, n.count - 1)
            }
            if local >= columns { return index - columns }
            guard s > 0 else { return index }
            let p = ranges[s - 1]
            let pLast = (p.count - 1) / columns
            return p.lowerBound + min(pLast * columns + column, p.count - 1)
        }
    }
}
