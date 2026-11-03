import Foundation

/// What the canvas has to do after something changed. See
/// `specs/ide/previews.md` §Fast updates.
public enum PreviewUpdate: Equatable, Sendable {
    /// Nothing that the shown pixels depend on changed.
    case none
    /// Only the canvas layout changed (another preview selected, a variant,
    /// orientation, color scheme, zoom of tiles): write a new plan for the
    /// payload already loaded. No compile.
    case relayout
    /// Swift sources of the module changed: compile a new payload and let
    /// the running host load it. No app build, no relaunch.
    case reloadPayload
    /// The host must be (re)started: it is not running, it crashed, it
    /// cannot load more images, the device or the platform changed, or the
    /// host itself is out of date. The payload is compiled first if needed.
    case relaunchHost(reason: String)
    /// The incremental path cannot apply the change: build the preview the
    /// slow way (the Mac's SwiftPM host for linked package targets, a
    /// relaunch with a new host bundle for resources).
    case rebuild(reason: String)
}

/// A snapshot of what a preview depends on.
public struct PreviewInputs: Equatable, Sendable {
    /// The platform, deployment target and device the previews run on.
    public var destination: String
    /// The module's name and how it is reached (`sources` or `linked`).
    public var module: String
    public var linked: Bool
    /// The module's Swift files and a hash of each one's text (blanked of
    /// previews, so editing a preview body changes it too).
    public var sourceHashes: [String: Int]
    /// Hashes of the module's other files (assets, resources, plists).
    public var resourceHashes: [String: Int]
    /// The previews the payload exports (names, kinds and bodies).
    public var previewsHash: Int
    /// The canvas layout the plan was made for.
    public var layout: [PreviewRegion]

    public init(destination: String, module: String, linked: Bool = false, sourceHashes: [String: Int],
                resourceHashes: [String: Int] = [:], previewsHash: Int, layout: [PreviewRegion]) {
        self.destination = destination
        self.module = module
        self.linked = linked
        self.sourceHashes = sourceHashes
        self.resourceHashes = resourceHashes
        self.previewsHash = previewsHash
        self.layout = layout
    }

    /// A stable hash of a text (FNV-1a, 64 bit; Swift's `hashValue` is
    /// seeded per process).
    public static func hash(_ text: String) -> Int {
        var h: UInt64 = 0xcbf2_9ce4_8422_2325
        for b in text.utf8 { h = (h ^ UInt64(b)) &* 0x100_0000_01b3 }
        return Int(truncatingIfNeeded: h)
    }

    /// The previews' identity for a payload: names, kinds, bodies, traits.
    public static func hash(_ previews: [PreviewDeclaration]) -> Int {
        hash(previews.map { p -> String in
            let k: String = switch p.kind { case .macro(let b): "m:" + b; case .provider(let t): "p:" + t }
            return "\(p.name)|\(k)|\(p.traits.joined(separator: ","))|\(p.fixedSize.map { "\($0.width)x\($0.height)" } ?? "")"
        }.joined(separator: "\u{1}"))
    }
}

/// The host's state as the canvas knows it.
public struct PreviewHostState: Equatable, Sendable {
    public var running: Bool
    /// Payload images the host has loaded; a host is restarted after
    /// `PreviewUpdatePlanner.maximumLoads` so the old images do not pile up.
    public var loads: Int
    /// The host exited or reported an error loading the last payload.
    public var failed: Bool
    public init(running: Bool, loads: Int = 0, failed: Bool = false) {
        self.running = running
        self.loads = loads
        self.failed = failed
    }
}

/// Decides how to bring the canvas up to date (Ycode design, `previews.md`
/// §Fast updates): the cheapest step that is still correct.
public enum PreviewUpdatePlanner {
    /// Every payload stays loaded in the host (an image cannot be unloaded
    /// safely while SwiftUI may hold its types); after this many the host is
    /// restarted.
    public static let maximumLoads = 40

    public static func decide(previous: PreviewInputs?, current: PreviewInputs, host: PreviewHostState) -> PreviewUpdate {
        if current.linked {
            return .rebuild(reason: "the target is linked from its package, so its sources cannot be compiled into a payload")
        }
        guard let previous else {
            return host.running ? .reloadPayload : .relaunchHost(reason: "first preview")
        }
        if previous.destination != current.destination { return .relaunchHost(reason: "the preview device changed") }
        if previous.module != current.module { return host.running ? .reloadPayload : .relaunchHost(reason: "the host is not running") }
        if previous.resourceHashes != current.resourceHashes {
            return .rebuild(reason: "resources changed; the host bundle is rebuilt with them")
        }
        let sourcesChanged = previous.sourceHashes != current.sourceHashes || previous.previewsHash != current.previewsHash
        if !host.running || host.failed {
            return .relaunchHost(reason: host.failed ? "the host failed" : "the host is not running")
        }
        if sourcesChanged {
            return host.loads >= maximumLoads ? .relaunchHost(reason: "the host has loaded \(host.loads) payloads") : .reloadPayload
        }
        if previous.layout != current.layout { return .relayout }
        return .none
    }
}
