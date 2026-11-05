import Foundation
import Observation
import YcodeDeviceModel
import YcodeIDECore
import YcodePreviews

/// The Linux IDE's preview canvas (`specs/ide/previews.md` §Canvas and
/// §Linux, "The Linux canvas"): the canvas beside or below the source
/// editor, a tab per preview, the selected preview in a device frame (or
/// every preview in Grid, or its variants), live updates as the file is
/// edited, errors in place, and the "needs a simulator host" state for
/// UIKit previews when no simulator host is set up. The toolkit-free half;
/// `ycode-ide/PreviewCanvasView.swift` draws it.
@MainActor
@Observable
public final class PreviewCanvasShellModel {
    /// Where the canvas goes: Editor ▸ Layout (Automatic: beside the
    /// editor, below it when the editor area is narrower than 760 points).
    public enum LayoutChoice: Int, Sendable { case automatic, right, bottom }

    public enum State: Equatable, Sendable {
        /// Nothing to show ("No Previews").
        case empty(String)
        /// The first picture is on its way: a spinner and what happens.
        case starting(String)
        /// Tiles with pictures.
        case rendered
        /// No picture yet and the update failed: the error card.
        case failed(title: String, message: String, issues: [PreviewIssue])
        /// UIKit previews without a simulator host: what to set up.
        case needsSimulator(title: String, message: String)
    }

    /// One shown picture.
    public struct Tile: Equatable, Identifiable, Sendable {
        public var id: Int
        public var preview: Int
        public var title: String
        /// The variant's label in Variants ("Dark"), else "".
        public var caption: String
        public var variant: PreviewVariant
        /// The size the preview is laid out at, in points (0 × 0: its ideal size).
        public var requested: CGSize
        /// The picture and its size in points (nil: not rendered yet).
        public var image: URL?
        public var size: CGSize
        /// Drawn in the device's frame (a preview without a layout trait).
        public var isDevice: Bool
        /// A picture of the whole device screen: the tile's region of it
        /// (screen points) and the screen's size (UIKit previews).
        public var crop: CGRect?
        public var screen: CGSize?
    }

    /// A failed update over the last picture (`previews.md` §Live canvas: Errors).
    public struct Banner: Equatable, Sendable {
        public var title: String
        public var issues: [PreviewIssue]
        public var message: String?
    }

    /// One update's times in seconds, from the edit (or the action) to new pixels.
    public struct Timing: Equatable, Sendable {
        public var reason: String
        public var decision: String
        public var compile: Double
        public var render: Double
        public var total: Double
        public var summary: String {
            String(format: "%@ (%@): compile %.2f, render %.2f, total %.2f s", reason, decision, compile, render, total)
        }
    }

    // MARK: Configuration (set by the workspace)

    /// The engine for SwiftUI previews (OpenViews on Linux); made on first use.
    @ObservationIgnored public var makeEngine: () -> PreviewCanvasEngine? = { nil }
    /// The engine for UIKit previews on a simulator host, when one is set up.
    @ObservationIgnored public var makeSimulatorEngine: () -> PreviewCanvasEngine? = { nil }
    /// The module's location (the workspace's container).
    @ObservationIgnored public var locator: () -> PreviewModuleLocator? = { nil }
    /// Opens a file at a line (an issue's link, Selectable's reveal).
    @ObservationIgnored public var reveal: (String, Int) -> Void = { _, _ in }
    /// The wait after an edit before the update (a live canvas: 0.15 s).
    @ObservationIgnored public var refreshDelay: TimeInterval = 0.15

    // MARK: State

    /// Canvas mode (Editor ▸ Canvas, the Canvas toolbar segment): on in a
    /// new window; while on, a file that declares previews shows the canvas.
    public private(set) var isModeOn = true
    public var layoutChoice: LayoutChoice = .automatic
    /// The focused Swift file that declares previews (nil: no canvas).
    public private(set) var path: String?
    public private(set) var previews: [PreviewDeclaration] = []
    /// Until resumed the canvas shows the "Canvas paused" capsule and
    /// builds nothing (`reference-ui-4.md` §10.2).
    public private(set) var isPaused = true
    public private(set) var state: State = .empty("No Previews")
    public private(set) var tiles: [Tile] = []
    public private(set) var selectedIndex = 0
    public private(set) var isGrid = false
    /// Live (the default) or Selectable.
    public private(set) var mode: PreviewCanvasMode = .live
    /// The Variants button's choice (nil: off).
    public private(set) var variantKind: PreviewVariantKind?
    /// Zoom factor; nil fits every tile.
    public private(set) var zoom: CGFloat?
    public private(set) var settings = PreviewCanvasSettings()
    /// The device previews are laid out on (nil: Automatic).
    public private(set) var deviceTypeID: String?
    /// An update is in flight: tabs show a spinner, the last picture stays.
    public private(set) var isUpdating = false
    /// What the update in flight is doing ("Compiling the preview").
    public private(set) var progressText = ""
    public private(set) var banner: Banner?
    /// Times of the updates, newest last.
    public private(set) var timings: [Timing] = []
    /// The UIKit path is chosen for this file (it imports UIKit or a
    /// preview returns a UIKit view or view controller).
    public private(set) var usesSimulator = false

    @ObservationIgnored private var text = ""
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var debounce: Task<Void, Never>?
    @ObservationIgnored private var updateTask: Task<Void, Never>?
    @ObservationIgnored private var engine: PreviewCanvasEngine?
    @ObservationIgnored private var simulatorEngine: PreviewCanvasEngine?
    @ObservationIgnored private var editStart: Date?

    public static let zoomSteps: [CGFloat] = [0.25, 0.5, 0.75, 1, 1.5, 2]
    /// The devices a preview can be laid out on (phones, then iPads).
    public static let devices: [DeviceFrameSpec] = [.iPhone18Pro, .iPhoneDuo, .iPadA16, .iPadPro13M5]
    public static let automaticDevice = DeviceFrameSpec.iPhone18Pro

    public init() {}

    /// The canvas is drawn: canvas mode is on and the focused file has previews.
    public var isShown: Bool { isModeOn && path != nil }

    /// The update in flight (tests await it).
    public var pendingUpdate: Task<Void, Never>? { updateTask }
    /// The debounced update waiting after an edit (tests await it).
    public var pendingDebounce: Task<Void, Never>? { debounce }

    public var device: DeviceFrameSpec { Self.devices.first { $0.typeID == deviceTypeID } ?? Self.automaticDevice }
    /// The device's screen in points, upright.
    public var screen: CGSize { device.panels[0].uprightPointSize }
    /// The bottom-left pop-up's title.
    public var deviceTitle: String { deviceTypeID == nil ? "Automatic – \(Self.automaticDevice.name)" : device.name }
    /// Header titles: `#Preview("name")`, else the view type at the start of the body.
    public var tabTitles: [String] { previews.map(\.tabTitle) }
    /// The zoom pop-up's title ("Fit" or "<n>%").
    public var zoomTitle: String { zoom.map { "\(Int(($0 * 100).rounded()))%" } ?? "Fit" }
    /// The status at the header's end.
    public var statusText: String {
        if isPaused { return "" }
        switch state {
        case .starting(let t): return t
        case .failed: return "Build failed"
        case .needsSimulator: return "Needs a simulator host"
        case .empty(let m): return m
        case .rendered: return isUpdating ? "Updating…" : grid ? "\(previews.count) preview\(previews.count == 1 ? "" : "s")" : ""
        }
    }
    private var grid: Bool { isGrid }

    /// Where the canvas goes for an editor area `width` points wide.
    public func placement(forWidth width: CGFloat) -> CanvasPlacement {
        switch layoutChoice {
        case .automatic: CanvasPlacement.placement(forWidth: width)
        case .right: .beside
        case .bottom: .below
        }
    }

    // MARK: The focused file

    /// The editor shows `path` with `text` (nil: no Swift file): the canvas
    /// follows it, shown when the file declares previews.
    public func focus(path newPath: String?, text newText: String?) {
        let has = newPath.map { CanvasAutoShow.hasPreviews(fileName: ($0 as NSString).lastPathComponent, text: newText ?? "") } ?? false
        let changed = newPath != path
        let same = !changed && text == (newText ?? "")
        text = newText ?? ""
        if !has {
            if path != nil { path = nil; previews = []; tiles = []; banner = nil; state = .empty("No Previews") }
            return
        }
        path = newPath
        let list = PreviewDiscovery.previews(in: text)
        previews = list
        if changed {
            selectedIndex = 0
            tiles = []
            banner = nil
            state = .empty("")
        }
        if selectedIndex >= list.count { selectedIndex = 0 }
        usesSimulator = Self.needsSimulator(text: text, previews: list)
        if !isPaused, !same { update(reason: changed ? "open" : "refresh") }
    }

    /// The focused file was edited: discover its previews again, and after
    /// `refreshDelay` without another edit, update the pictures.
    public func edited(path p: String, text newText: String) {
        guard p == path || CanvasAutoShow.hasPreviews(fileName: (p as NSString).lastPathComponent, text: newText) else { return }
        if p != path { focus(path: p, text: newText); return }
        text = newText
        let list = PreviewDiscovery.previews(in: newText)
        if list.isEmpty { focus(path: p, text: newText); return }
        previews = list
        if selectedIndex >= list.count { selectedIndex = 0 }
        usesSimulator = Self.needsSimulator(text: newText, previews: list)
        guard !isPaused, isModeOn else { return }
        if editStart == nil { editStart = Date() }
        debounce?.cancel()
        let delay = refreshDelay
        debounce = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1e9))
            guard !Task.isCancelled, let self else { return }
            self.update(reason: "edit")
        }
    }

    /// Whether a file's previews need Ycode's simulator: it imports UIKit,
    /// or a preview's body makes a UIKit view or view controller.
    public static func needsSimulator(text: String, previews: [PreviewDeclaration]) -> Bool {
        PreviewDiscovery.needsUIKit(text: text, previews: previews)
    }

    // MARK: Commands

    /// Editor ▸ Canvas and the toolbar's Canvas segment.
    public func toggleMode() {
        isModeOn.toggle()
        if isModeOn, !isPaused, path != nil { update(reason: "canvas") }
    }

    /// The paused capsule's resume button: the first build.
    public func resume() {
        guard isPaused else { return }
        isPaused = false
        update(reason: "resume")
    }

    /// A header tab: selects that preview (and leaves the grid).
    public func select(_ index: Int) {
        guard previews.indices.contains(index) else { return }
        selectedIndex = index
        isGrid = false
        relayout()
    }

    /// The mode buttons: Live and Selectable are exclusive; Grid toggles;
    /// Variants cycles Color Scheme → Orientation → Dynamic Type → off.
    public func setMode(_ m: PreviewCanvasMode) {
        switch m {
        case .live, .selectable: mode = m
        case .grid:
            isGrid.toggle()
            if isGrid { variantKind = nil }
            relayout()
        case .variants:
            let all = PreviewVariantKind.allCases
            setVariants(variantKind.flatMap { all.firstIndex(of: $0) }.map { $0 + 1 < all.count ? all[$0 + 1] : nil } ?? all.first)
        }
    }

    /// The Variants menu's choice (nil: off).
    public func setVariants(_ kind: PreviewVariantKind?) {
        variantKind = kind
        if kind != nil { isGrid = false }
        relayout()
    }

    public func setZoom(_ z: CGFloat?) { zoom = z }

    /// A canvas settings switch; Color Scheme, Orientation and Dynamic Type
    /// change the pictures' traits.
    public func setSetting(_ name: String, _ on: Bool) {
        if on { settings.on.insert(name) } else { settings.on.remove(name) }
        if ["Color Scheme", "Orientation", "Dynamic Type"].contains(name) { relayout() }
    }

    /// The device pop-up (nil: Automatic).
    public func chooseDevice(_ typeID: String?) {
        deviceTypeID = typeID
        relayout()
    }

    /// Editor ▸ Layout.
    public func setLayout(_ choice: LayoutChoice) { layoutChoice = choice }

    /// A click on a tile: it becomes the selected preview; in Selectable
    /// mode its `#Preview` line is revealed in the editor.
    public func tileClicked(_ tile: Tile) {
        if selectedIndex != tile.preview, isGrid { selectedIndex = tile.preview }
        if mode == .selectable, let path, previews.indices.contains(tile.preview) { reveal(path, previews[tile.preview].line) }
    }

    /// A banner's issue: its file at its line.
    public func open(_ issue: PreviewIssue) {
        guard let f = issue.file else { return }
        reveal(f.path, issue.line)
    }

    /// The workspace closes.
    public func stop() {
        debounce?.cancel()
        updateTask?.cancel()
        engine?.stop()
        simulatorEngine?.stop()
    }

    // MARK: Updating

    /// The base variant from the canvas settings.
    public var baseVariant: PreviewVariant {
        PreviewVariant(colorScheme: settings.on.contains("Color Scheme") ? "dark" : "light",
                       dynamicType: settings.on.contains("Dynamic Type") ? "accessibility1" : nil,
                       orientation: settings.on.contains("Orientation") ? .landscapeLeft : nil)
    }

    /// The tiles the canvas asks for: Grid → every preview; Variants → the
    /// selected preview in each variant; otherwise the selected preview.
    public func plannedTiles() -> [Tile] {
        guard !previews.isEmpty else { return [] }
        let base = baseVariant
        func tile(_ id: Int, _ i: Int, _ v: PreviewVariant, caption: String) -> Tile {
            let p = previews[i]
            var variant = v
            if variant.orientation == nil, p.orientation != .portrait { variant.orientation = p.orientation.rawValue }
            let size: CGSize = p.layout == .sizeThatFits ? .zero : PreviewScreenLayout.tileSize(p, screen: screen, variant: variant)
            return Tile(id: id, preview: i, title: tabTitles[i], caption: caption, variant: variant, requested: size, image: nil,
                        size: size, isDevice: p.layout == .device, crop: nil, screen: nil)
        }
        let sel = min(max(selectedIndex, 0), previews.count - 1)
        if isGrid { return previews.indices.map { tile($0, $0, base, caption: "") } }
        if let kind = variantKind {
            return kind.variants(base: base).enumerated().map { tile($0.offset, sel, $0.element, caption: $0.element.label) }
        }
        return [tile(0, sel, base, caption: "")]
    }

    /// The layout changed (selection, grid, variants, settings, device): new
    /// pictures for the loaded payload, no compile (the update planner's
    /// relayout).
    private func relayout() {
        guard !isPaused, isShown else { return }
        update(reason: "layout")
    }

    /// Brings the pictures up to date (the engine's planner decides how).
    public func update(reason: String) {
        guard isShown, !isPaused, let path else { return }
        debounce?.cancel()
        let start = reason == "edit" ? (editStart ?? Date()) : Date()
        editStart = nil
        let planned = plannedTiles()
        guard !planned.isEmpty else { state = .empty("No Previews"); return }
        // UIKit previews need a simulator host.
        let eng: PreviewCanvasEngine
        if usesSimulator {
            if simulatorEngine == nil { simulatorEngine = makeSimulatorEngine() }
            guard let s = simulatorEngine else {
                tiles = []
                banner = nil
                state = .needsSimulator(title: Self.needsSimulatorTitle, message: Self.needsSimulatorMessage)
                return
            }
            eng = s
        } else {
            if engine == nil { engine = makeEngine() }
            guard let e = engine else { state = .failed(title: "Previews are not available", message: "No preview engine.", issues: []); return }
            eng = e
        }
        guard let locator = locator() else { return }
        generation += 1
        let g = generation
        // Keep the last pictures while the new ones are made.
        if case .rendered = state {
            if tiles.map(\.preview) != planned.map(\.preview) || tiles.map(\.variant) != planned.map(\.variant) {
                tiles = zip(planned, planned.indices).map { t, i in
                    var t = t
                    if let old = tiles.first(where: { $0.preview == t.preview && $0.variant == t.variant }) ?? (i < tiles.count && tiles[i].preview == t.preview ? tiles[i] : nil) {
                        (t.image, t.size, t.crop, t.screen) = (old.image, old.size, old.crop, old.screen)
                    }
                    return t
                }
            }
        } else {
            state = .starting(usesSimulator ? "Starting the preview device" : "Preparing the preview")
        }
        isUpdating = true
        let request = PreviewCanvasRequest(file: URL(fileURLWithPath: path), text: text, previews: previews,
                                           tiles: planned.map { PreviewCanvasTileRequest(preview: $0.preview, variant: $0.variant, size: $0.requested) },
                                           locator: locator, deviceTypeID: device.typeID, screen: screen)
        let progress: @Sendable (String) -> Void = { [weak self] text in
            Task { @MainActor in if self?.generation == g { self?.noteProgress(text) } }
        }
        updateTask = Task { [weak self] in
            let result = await eng.update(request, generation: g, progress: progress)
            guard let self, g == self.generation, let result else { return }
            self.finish(result, planned: planned, reason: reason, start: start)
        }
    }

    private func noteProgress(_ text: String) {
        progressText = text
        if case .starting = state { state = .starting(text) }
    }

    private func finish(_ result: Result<PreviewCanvasOutcome, PreviewFailure>, planned: [Tile], reason: String, start: Date) {
        isUpdating = false
        progressText = ""
        switch result {
        case .success(let o):
            tiles = planned.enumerated().map { i, t in
                var t = t
                if i < o.pictures.count { t.image = o.pictures[i]; t.size = o.sizes[i] }
                if let c = o.crops, i < c.count { t.crop = c[i]; t.screen = o.screen }
                return t
            }
            banner = nil
            state = .rendered
            let timing = Timing(reason: reason, decision: o.decision, compile: o.compile, render: o.render, total: Date().timeIntervalSince(start))
            timings.append(timing)
            if timings.count > 100 { timings.removeFirst(timings.count - 100) }
        case .failure(.unsupported(let why)) where usesSimulator:
            // The simulator path's setup (the SDK copy, a linker): a card, not an error.
            tiles = []
            banner = nil
            state = .needsSimulator(title: "UIKit Previews Need Setup", message: why)
        case .failure(let f):
            let title = f.issues.isEmpty ? (Self.isHostFailure(f) ? "The preview host failed" : "Preview failed") : "Compiling the preview failed"
            if case .rendered = state, tiles.contains(where: { $0.image != nil }) {
                banner = Banner(title: title, issues: Array(f.issues.prefix(3)), message: f.issues.isEmpty ? f.description : nil)
            } else {
                tiles = []
                state = .failed(title: f.issues.isEmpty ? "Preview build failed" : "Compiling the preview failed", message: f.description,
                                issues: Array(f.issues.prefix(3)))
            }
        }
    }

    private static func isHostFailure(_ f: PreviewFailure) -> Bool { if case .host = f { return true }; return false }

    public static let needsSimulatorTitle = "Needs a Simulator Host"
    public static let needsSimulatorMessage = "UIKit previews run in Ycode's iOS simulator, on an arm64 Linux simulator host. "
        + "Pair one with ycode sim remote pair (Window ▸ Downloads checks it), then choose Check Again. SwiftUI previews render here without one."

    // MARK: Layout of the tiles

    /// Space around the tiles and between them, and the caption's height.
    public static let gap: CGFloat = 24
    public static let captionHeight: CGFloat = 18

    /// The zoom that fits every tile in `area` (at most 1, at least 0.1),
    /// with one row per `columns` tiles.
    public func fitZoom(area: CGSize) -> CGFloat { Self.arrange(tiles, area: area, zoom: nil).zoom }

    /// The tiles' frames (picture only; the caption sits above), the
    /// content's size and the zoom used.
    public func frames(area: CGSize) -> (frames: [CGRect], size: CGSize, zoom: CGFloat) { Self.arrange(tiles, area: area, zoom: zoom) }

    /// Arranges tiles in rows: the column count that gives the largest
    /// fitting zoom (Fit), or the most columns that fit at a set zoom.
    public static func arrange(_ tiles: [Tile], area: CGSize, zoom: CGFloat?) -> (frames: [CGRect], size: CGSize, zoom: CGFloat) {
        guard !tiles.isEmpty else { return ([], .zero, zoom ?? 1) }
        let sizes = tiles.map { $0.size.width > 0 && $0.size.height > 0 ? $0.size : CGSize(width: 200, height: 120) }
        let n = tiles.count
        func layout(cols: Int, z: CGFloat) -> ([CGRect], CGSize) {
            var frames: [CGRect] = []
            var y = gap, width: CGFloat = 0
            var i = 0
            while i < n {
                let row = Array(i..<min(i + cols, n))
                let h = row.map { sizes[$0].height * z }.max() ?? 0
                var x = gap
                for k in row {
                    let s = CGSize(width: sizes[k].width * z, height: sizes[k].height * z)
                    frames.append(CGRect(x: x, y: y + captionHeight, width: s.width, height: s.height))
                    x += s.width + gap
                }
                width = max(width, x)
                y += captionHeight + h + gap
                i += cols
            }
            return (frames, CGSize(width: width, height: y))
        }
        if let z = zoom {
            var cols = n
            while cols > 1, layout(cols: cols, z: z).1.width > area.width { cols -= 1 }
            let (f, s) = layout(cols: cols, z: z)
            return (f, s, z)
        }
        var best = (cols: 1, zoom: CGFloat(0.1))
        for cols in 1...n {
            let (_, s1) = layout(cols: cols, z: 1)
            let w = s1.width - gap * CGFloat(min(cols, n) + 1), h = s1.height - (gap + captionHeight) * CGFloat((n + cols - 1) / cols) - gap
            let zw = (area.width - gap * CGFloat(min(cols, n) + 1)) / max(w, 1)
            let zh = (area.height - (gap + captionHeight) * CGFloat((n + cols - 1) / cols) - gap) / max(h, 1)
            let z = max(0.1, min(1, zw, zh))
            if z >= best.zoom - 1e-9 { best = (cols, z) }
        }
        let (f, s) = layout(cols: best.cols, z: best.zoom)
        return (f, s, best.zoom)
    }
}
