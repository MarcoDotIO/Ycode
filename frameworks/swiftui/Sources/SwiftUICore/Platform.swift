// Geometry types (CGFloat, CGPoint, CGSize, CGRect) come from Foundation on
// Linux (swift-corelibs-foundation) and from CoreGraphics on Apple hosts;
// re-export them so that clients see one set of names either way.
@_exported import Foundation
#if canImport(CoreGraphics)
@_exported import CoreGraphics
#endif
