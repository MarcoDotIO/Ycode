import AppKit

/// The navigator's floating glass bars and the outline scrolling beneath
/// them (`specs/ide/liquid-glass.md` §2.3, §3.1), macOS 26 and later.
extension NavigatorAreaController {
    /// The "+" circle's size and the room between the filter field and its
    /// capsule's ends.
    static let plusSize = NSSize(width: 31, height: GlassBars.height)
    static let filterInset: CGFloat = 4
    /// The selected icon's recessed pill.
    static let selectorPillSize = NSSize(width: 30, height: 24)

    /// Places the capsules around their controls: the selector bar
    /// (278 × 30 at a 290-point width, 6 from each side), the "+" circle
    /// (31 × 30, 6 from the leading edge) and the filter capsule (6 after
    /// the "+", 6 from the trailing edge, 7 above the window's bottom).
    func installGlassBars(_ root: NSView) {
        let field = filter
        NSLayoutConstraint.activate([
            selectorGlass.topAnchor.constraint(equalTo: root.safeAreaLayoutGuide.topAnchor, constant: GlassBars.topOffset),
            selectorGlass.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 6),
            selectorGlass.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -6),
            selectorGlass.heightAnchor.constraint(equalToConstant: GlassBars.height),
            plusGlass.centerXAnchor.constraint(equalTo: addBreakpointButton.centerXAnchor),
            plusGlass.centerYAnchor.constraint(equalTo: field.centerYAnchor),
            plusGlass.widthAnchor.constraint(equalToConstant: Self.plusSize.width),
            plusGlass.heightAnchor.constraint(equalToConstant: Self.plusSize.height),
            filterGlass.leadingAnchor.constraint(equalTo: field.leadingAnchor, constant: -Self.filterInset),
            filterGlass.trailingAnchor.constraint(equalTo: field.trailingAnchor, constant: Self.filterInset),
            filterGlass.centerYAnchor.constraint(equalTo: field.centerYAnchor),
            filterGlass.heightAnchor.constraint(equalToConstant: GlassBars.height),
        ])
        // The field sits on the capsule: no bezel or background of its own.
        field.isBezeled = false
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        // Without its bezel the text starts nearer the edge: keep it after
        // the options pull-down.
        (field as? NavigatorFilterField)?.leadingInset += 2
        underBarsScroll = [
            scrollView.topAnchor.constraint(equalTo: root.topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: root.bottomAnchor),
        ]
    }

    /// The outline runs under the bars to the window's top and bottom
    /// edges, its first row where the clipped layout put it; with header
    /// rows shown (Find, Source Control, Tests, Reports) it is clipped
    /// below them as before.
    func setOutlineUnderBars(_ under: Bool) {
        guard GlassBars.enabled, !underBarsScroll.isEmpty else { return }
        if under {
            NSLayoutConstraint.deactivate(clippedScrollConstraints)
            NSLayoutConstraint.activate(underBarsScroll)
        } else {
            NSLayoutConstraint.deactivate(underBarsScroll)
            NSLayoutConstraint.activate(clippedScrollConstraints)
            setOutlineInsets(NSEdgeInsets())
        }
        scrollClipView.clipsToBounds = !under
    }

    /// After layout: the content insets that keep the first row and the
    /// last one where the clipped layout put them, and the pill under the
    /// selected icon.
    func updateGlassLayout() {
        guard GlassBars.enabled, isViewLoaded else { return }
        selectorPill.follow(selectorButtons.first { $0.state == .on }, size: Self.selectorPillSize)
        guard underBarsScroll.first?.isActive == true else { return }
        let root = view
        let clip = scrollClipView.frame
        let top = root.bounds.maxY - clip.maxY + Self.firstRowGap - Self.selectorToContent - Self.sourceListTopPadding
        // The last row clears the bottom bar's capsules.
        let bottom = max(clip.minY, filterGlass.frame.maxY + 2)
        setOutlineInsets(NSEdgeInsets(top: top, left: 0, bottom: bottom, right: 0))
    }

    private func setOutlineInsets(_ insets: NSEdgeInsets) {
        let scroll = scrollView
        let old = scroll.contentInsets
        guard abs(old.top - insets.top) > 0.25 || abs(old.bottom - insets.bottom) > 0.25 else { return }
        let atTop = scroll.contentView.bounds.minY <= -old.top + 0.5
        scroll.contentInsets = insets
        scroll.scrollerInsets = insets
        if atTop {
            scroll.contentView.scroll(to: NSPoint(x: scroll.contentView.bounds.minX, y: -insets.top))
            scroll.reflectScrolledClipView(scroll.contentView)
        }
    }
}
