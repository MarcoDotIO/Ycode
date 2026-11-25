import AppKit
import YcodeIDECore

/// The bottom-bar filter's behaviour (P-037, `NavigatorFilterModel`):
/// rows filter `settleDelay` after the last key; matched text is bold and
/// the rest dimmed; "No Filter Results" when nothing is left (and the
/// inspector reads "No Selection"); the options glyph turns the accent
/// colour while text is present; its menu holds the recent filters and
/// Clear Recents and opens upward from the glyph.
@MainActor
final class NavigatorFilterState {
    var recents = NavigatorFilterRecents()
    /// The pending refilter after a key.
    var settle: Timer?
    /// The filter text whose rows are shown, per navigator.
    var applied: [Int: String] = [:]
}

extension NavigatorAreaController {
    /// P-024: no header row holds the navigator wide; each gives way (its
    /// controls truncate) so the area compresses to ≈ 135 points, where
    /// the selector bar's tabs stop.
    func letHeadersCompress() {
        for v in view.subviews {
            if let stack = v as? NSStackView, stack.orientation == .horizontal {
                stack.setClippingResistancePriority(.init(200), for: .horizontal)
                for a in stack.arrangedSubviews { a.setContentCompressionResistancePriority(.init(200), for: .horizontal) }
            }
            if let c = v as? NSControl { c.setContentCompressionResistancePriority(.init(200), for: .horizontal) }
        }
        // The Test header narrows its pop-up rather than clipping it: above
        // the pop-up's 194-point width (240), below the navigator's hold.
        testHeader.setClippingResistancePriority(.init(245), for: .horizontal)
    }

    /// Called once from `loadView`.
    func configureFilterBehaviour() {
        filter.sendsSearchStringImmediately = true
        filter.sendsWholeSearchString = false
        filter.action = #selector(filterTyped)
        filter.delegate = filterDelegate
        filterDelegate.onEndEditing = { [weak self] in self?.noteRecentFilter() }
        (filterOptions as? NavigatorOptionsButton)?.opensUpward = true
    }

    /// A key in the field: the rows follow after a short pause (the last
    /// key wins), or at once when the field was cleared.
    @objc func filterTyped() {
        filterState.settle?.invalidate()
        updateFilterGlyph()
        // The typed filter is the field's accessibility value (P-037).
        filter.setAccessibilityValue(filter.stringValue)
        guard !filter.stringValue.isEmpty else { applyFilterNow(); return }
        let t = Timer(timeInterval: NavigatorFilterModel.settleDelay, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.applyFilterNow() }
        }
        RunLoop.main.add(t, forMode: .common)
        filterState.settle = t
    }

    /// Applies the field's text to the selected navigator now (tests call
    /// it instead of waiting for the pause).
    public func applyFilterNow() {
        filterState.settle?.invalidate()
        filterState.settle = nil
        filterState.applied[selectedIndex] = filter.stringValue
        filter.setAccessibilityValue(filter.stringValue)
        filterChanged()
        updateFilterGlyph()
        onShownViewChange?()
    }

    /// Whether a refilter is waiting for the pause after a key (tests).
    public var filterIsSettling: Bool { filterState.settle != nil }

    /// The field ended editing (Return, or the focus left): its text is a
    /// recent filter of this navigator.
    func noteRecentFilter() {
        filterState.recents.note(filter.stringValue, navigator: selectedIndex)
        rebuildFilterOptionsMenu()
    }

    /// The selected navigator's recent filters, newest first (tests).
    public var recentFilters: [String] { filterState.recents.recents(selectedIndex) }

    /// The options glyph: the accent colour while the field has text.
    func updateFilterGlyph() {
        let active = NavigatorFilterModel.isActive(filter.stringValue)
        filterOptions.contentTintColor = active ? .controlAccentColor : NavigatorBarColors.optionsGlyph
        filterOptions.needsDisplay = true
    }

    /// Whether the options glyph shows an active filter (tests).
    public var filterGlyphIsActive: Bool { filterOptions.contentTintColor == .controlAccentColor }

    /// The filter left no row of a navigator that had some: the
    /// navigator shows "No Filter Results" and the inspector "No Selection".
    public var filterLeavesNoRows: Bool {
        guard isViewLoaded, NavigatorFilterModel.isActive(filter.stringValue), shownRoots.isEmpty else { return false }
        return selectedIndex == 0 ? !unfilteredProjectRows.isEmpty : !roots[selectedIndex].isEmpty
    }

    /// The inspector's empty placeholder reads "No Selection" (the
    /// Repositories view, or a filter that left no row) rather than
    /// "Not Applicable".
    public var inspectorPlaceholderIsNoSelection: Bool { showsRepositoriesView || filterLeavesNoRows }

    /// The filter options of every navigator but Issues: the recent
    /// filters, Clear Recents.
    func addRecentFilterItems(to menu: NSMenu) {
        for entry in NavigatorFilterModel.menu(recents: filterState.recents.recents(selectedIndex)) {
            switch entry {
            case .recent(let text):
                let item = NSMenuItem(title: text, action: #selector(recentFilterChosen(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = text
                menu.addItem(item)
            case .separator:
                menu.addItem(.separator())
            case .clearRecents(let enabled):
                let item = NSMenuItem(title: NavigatorFilterModel.clearRecents, action: enabled ? #selector(clearRecentFilters(_:)) : nil,
                                      keyEquivalent: "")
                item.target = self
                item.isEnabled = enabled
                menu.addItem(item)
            }
        }
    }

    @objc func recentFilterChosen(_ item: NSMenuItem) {
        guard let text = item.representedObject as? String else { return }
        filter.stringValue = text
        applyFilterNow()
    }

    @objc func clearRecentFilters(_ sender: Any?) {
        filterState.recents.clear(selectedIndex)
        rebuildFilterOptionsMenu()
    }

    /// A row's title with the filter's match in bold and the rest dimmed
    /// (a group kept for the rows under it is dimmed throughout); nil when
    /// no filter is applied.
    func emphasizedTitle(_ title: String, size: CGFloat) -> NSAttributedString? {
        let query = filterState.applied[selectedIndex] ?? ""
        guard NavigatorFilterModel.isActive(query) else { return nil }
        let dim = NavigatorCellView.rowLabelColor.withAlphaComponent(NavigatorFilterModel.unmatchedOpacity)
        let plain: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: size), .foregroundColor: dim]
        guard let e = NavigatorFilterModel.emphasis(title, query: query) else { return NSAttributedString(string: title, attributes: plain) }
        let bold: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: size, weight: .bold),
                                                   .foregroundColor: NavigatorCellView.rowLabelColor]
        let s = NSMutableAttributedString(string: e.before, attributes: plain)
        s.append(NSAttributedString(string: e.match, attributes: bold))
        s.append(NSAttributedString(string: e.after, attributes: plain))
        return s
    }
}

/// Notes the end of an edit in the filter field.
@MainActor
final class NavigatorFilterDelegate: NSObject, NSSearchFieldDelegate {
    var onEndEditing: (() -> Void)?
    func controlTextDidEndEditing(_ obj: Notification) { onEndEditing?() }
}
