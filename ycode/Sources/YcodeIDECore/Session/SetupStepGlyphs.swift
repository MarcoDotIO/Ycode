/// Each setup step's glyph in the paged assistant (`liquid-glass-ycode.md`
/// §11): a system symbol name, used as an interop identifier. On macOS the
/// system draws it; on Linux Ycode's own symbol set has the runtime steps'
/// names. None depicts an Apple product.
extension RuntimeSetupStep {
    public var glyph: String {
        switch self {
        case .target: "arrow.triangle.branch"
        case .host: "cpu"
        case .prepare: "gearshape.2"
        case .runtimes: "square.stack.3d.up"
        case .download: "square.and.arrow.down"
        case .add: "plus.circle"
        case .finish: "checkmark.circle"
        }
    }
}

extension HeadsetSetupStep {
    public var glyph: String {
        switch self {
        case .viewerHost: "server.rack"
        case .workstation: "shippingbox"
        case .headset: "eyeglasses"
        case .tracking: "hand.raised"
        case .connect: "link"
        }
    }
}
