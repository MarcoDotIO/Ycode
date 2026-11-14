import Foundation
import YcodeProject
#if canImport(IOKit)
import IOKit.ps
#endif

/// The scheme capsule's icons (`workspace-window.md` W7; council round 8,
/// row 199), shared by both IDEs: the scheme shows its app target's icon,
/// the picture its asset catalog's app icon set holds (else a plain app
/// tile of Ycode's own design, `SchemeAppTile`); the run destination for
/// this computer shows a laptop on a laptop and a desktop computer
/// otherwise.
public enum SchemeCapsuleIcons {
    /// The app icon's picture for `scheme` in `model`: the scheme's target
    /// (the target of that name, else the project's first application),
    /// its `ASSETCATALOG_COMPILER_APPICON_NAME` (default "AppIcon"), and
    /// that set's largest picture for any appearance in an asset catalog
    /// in the project's folder. Nil: none (draw the plain tile).
    public static func appIconURL(scheme: String?, model: WorkspaceModel) -> URL? {
        for (path, proj) in model.projects.sorted(by: { $0.key < $1.key }) {
            let targets = proj.targets
            let app = "com.apple.product-type.application"
            guard let target = targets.first(where: { $0.string("name") == scheme })
                ?? targets.first(where: { $0.string("productType") == app }) else { continue }
            let configs = proj.buildConfigurations(listID: target.string("buildConfigurationList"))
            let names = configs.compactMap { $0["buildSettings"]?.dictionary?["ASSETCATALOG_COMPILER_APPICON_NAME"]?.string }
            let setName = names.first ?? "AppIcon"
            let folder = URL(fileURLWithPath: path).deletingLastPathComponent()
            if let url = iconPicture(named: setName, under: folder) { return url }
        }
        return nil
    }

    /// The largest picture of the app icon set `name` in the first asset
    /// catalog under `folder` that has it (build output skipped).
    public static func iconPicture(named name: String, under folder: URL) -> URL? {
        let key = folder.path + "|" + name
        if let hit = cache.withLock({ $0[key] }) { return hit }
        let found = findPicture(named: name, under: folder)
        cache.withLock { $0[key] = found }
        return found
    }

    /// Found pictures by folder and set name (the walk runs once per window
    /// and set; `forget` clears it, as when a catalog changes).
    private static let cache = LockedBox<[String: URL?]>([:])

    public static func forget() { cache.withLock { $0 = [:] } }

    static func findPicture(named name: String, under folder: URL) -> URL? {
        let fm = FileManager.default
        let skip: Set<String> = [".build", "build", "DerivedData", ".git", "node_modules", "Pods"]
        guard let walker = fm.enumerator(at: folder, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]) else { return nil }
        var catalogs: [URL] = []
        for case let u as URL in walker {
            if skip.contains(u.lastPathComponent) || walker.level > 6 { walker.skipDescendants(); continue }
            if u.pathExtension == "xcassets" { catalogs.append(u); walker.skipDescendants() }
        }
        for catalog in catalogs.sorted(by: { $0.path < $1.path }) {
            let set = catalog.appendingPathComponent("\(name).appiconset")
            if let picture = largestPicture(in: set) { return picture }
        }
        return nil
    }

    /// The set's largest picture for any appearance (pixels: size × scale;
    /// a single-size 1024 entry counts as 1024).
    static func largestPicture(in set: URL) -> URL? {
        guard let data = try? Data(contentsOf: set.appendingPathComponent("Contents.json")),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let images = root["images"] as? [[String: Any]] else { return nil }
        var best: (pixels: Double, url: URL)?
        for e in images {
            guard let file = e["filename"] as? String, e["appearances"] == nil else { continue }
            let url = set.appendingPathComponent(file)
            guard FileManager.default.fileExists(atPath: url.path) else { continue }
            let size = (e["size"] as? String).flatMap { Double($0.split(separator: "x").first ?? "") } ?? 1024
            let scale = (e["scale"] as? String).flatMap { Double($0.dropLast()) } ?? 1
            if best == nil || size * scale > best!.pixels { best = (size * scale, url) }
        }
        return best?.url
    }

    /// The host computer's form (the run destination for this computer).
    public enum HostForm: Equatable, Sendable {
        case laptop, desktop

        /// The destination's glyph: a laptop or a desktop computer.
        public var symbol: String { self == .laptop ? "laptopcomputer" : "desktopcomputer" }
    }

    /// A model identifier's form: a laptop has an internal battery (Apple
    /// silicon laptops name themselves "Mac15,10" and the like) or, on
    /// older models, a model name beginning with "MacBook"; others are
    /// desktops.
    public static func hostForm(modelIdentifier: String, hasInternalBattery: Bool) -> HostForm {
        modelIdentifier.hasPrefix("MacBook") || hasInternalBattery ? .laptop : .desktop
    }

    /// This computer's form: on macOS by an internal battery among its
    /// power sources or its model identifier (`hw.model`); on Linux by a system battery
    /// (`/sys/class/power_supply/BAT*`) or a portable chassis type.
    public static let currentHostForm: HostForm = {
        #if os(macOS)
        var size = 0
        sysctlbyname("hw.model", nil, &size, nil, 0)
        var bytes = [CChar](repeating: 0, count: max(size, 1))
        sysctlbyname("hw.model", &bytes, &size, nil, 0)
        let model = String(decoding: bytes.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
        return hostForm(modelIdentifier: model, hasInternalBattery: hasInternalBattery())
        #else
        let fm = FileManager.default
        let supplies = (try? fm.contentsOfDirectory(atPath: "/sys/class/power_supply")) ?? []
        let battery = supplies.contains { $0.hasPrefix("BAT") }
        // SMBIOS chassis types 8–10 and 14 are portables (laptop, notebook, sub-notebook).
        let chassis = (try? String(contentsOfFile: "/sys/class/dmi/id/chassis_type", encoding: .utf8))
            .flatMap { Int($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
        return battery || [8, 9, 10, 14].contains(chassis ?? 0) ? .laptop : .desktop
        #endif
    }()

    #if canImport(IOKit)
    /// Whether the power sources include an internal battery.
    static func hasInternalBattery() -> Bool {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] else { return false }
        return list.contains { ps in
            guard let d = IOPSGetPowerSourceDescription(info, ps)?.takeUnretainedValue() as? [String: Any] else { return false }
            return d[kIOPSTypeKey] as? String == kIOPSInternalBatteryType
        }
    }
    #endif

    /// The tint of this computer's destination glyph (0xRRGGBB, light and
    /// dark): the system blue on a laptop (row 199), the label colour on a
    /// desktop (nil).
    public static func hostGlyphTint(_ form: HostForm, dark: Bool) -> UInt32? {
        form == .laptop ? (dark ? 0x0091FF : 0x0088FF) : nil
    }
}

/// A value behind a lock.
final class LockedBox<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: T
    init(_ v: T) { value = v }
    func withLock<R>(_ f: (inout T) -> R) -> R {
        lock.lock()
        defer { lock.unlock() }
        return f(&value)
    }
}

/// The plain app tile Ycode draws for a scheme whose target has no app
/// icon (Ycode's own design, not the reference's): a rounded square in a
/// soft grey gradient with a thin rim and three small rounded bars, in the
/// 16-point glyph slot. Both IDEs draw these shapes.
public enum SchemeAppTile {
    public static let side = 15.0
    /// The tile's corner (a continuous-looking 22.5 % of the side).
    public static let corner = 3.4
    /// Top and bottom of the gradient (0xRRGGBB) and the rim, light and dark.
    public static func gradient(dark: Bool) -> (top: UInt32, bottom: UInt32, rim: UInt32) {
        dark ? (0x8E8E93, 0x5E5E63, 0x48484D) : (0xF2F2F7, 0xC7C7CC, 0xAEAEB2)
    }
    /// The three bars inside (x, y, width, height in the tile's points,
    /// from its top left), white at 85 %.
    public static let bars: [(x: Double, y: Double, w: Double, h: Double)] = [(4, 4.5, 7, 1.6), (4, 7.2, 5, 1.6), (4, 9.9, 6, 1.6)]
}
