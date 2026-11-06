import Foundation

/// How much of the content behind each bar shows, blurred, keeping its
/// shape (`specs/ide/liquid-glass.md` §8.3, §9.1, §9.2; checklist rows 68
/// and 69). A share is the part of the content's darkness that reaches the
/// screen: over white, a pixel the content darkens by `d` shows `share · d`.
public enum BarBlur {
    /// The blur's standard deviation, points.
    public static let sigma = 6.0
    /// The toolbar band above the toolbar's shapes.
    public static let toolbarBandShare = 0.18
    /// The jump bar.
    public static let jumpBarShare = 0.085
    /// The editor's bottom bar.
    public static let bottomBarShare = 0.12
    /// The navigator's selector capsule: rows under it show as smudges
    /// (a row's text darkens the #E8E8E9 fill to about #DFDFE0, 5–9 levels).
    public static let selectorShare = 0.2
    /// The capsule's own darkening over white rows (#F0F0F1 to #E8E8E9).
    public static let selectorFill = 0.033

    /// What a pixel of `content` (0 black … 1 white) shows through a bar
    /// of `share` over a white background.
    public static func shown(content: Double, share: Double) -> Double { 1 - share * (1 - content) }
}

/// A normalised Gaussian kernel (radius ⌈3σ⌉).
public enum GaussianKernel {
    public static func weights(sigma: Double) -> [Double] {
        guard sigma > 0 else { return [1] }
        let r = Int((3 * sigma).rounded(.up))
        let raw = (-r...r).map { exp(-Double($0 * $0) / (2 * sigma * sigma)) }
        let sum = raw.reduce(0, +)
        return raw.map { $0 / sum }
    }

    /// `values` blurred (edges extended): the 1-D reference the bitmap
    /// blur follows.
    public static func blur(_ values: [Double], sigma: Double) -> [Double] {
        let k = weights(sigma: sigma), r = k.count / 2
        guard !values.isEmpty else { return [] }
        return values.indices.map { i in
            k.indices.reduce(0) { acc, j in acc + k[j] * values[min(values.count - 1, max(0, i + j - r))] }
        }
    }
}
