import Foundation
import Synchronization

// EnvironmentValues: keyed storage. Round R2 adds a revision number for
// change tracking in the view graph: every mutation takes a new, globally
// unique revision, so two values with the same revision are identical, and a
// node whose environment kept its revision has nothing to re-check. Per-key
// change detection compares the values a body actually read
// (09-open-design.md §3.2).

private let environmentRevisionCounter = Atomic<UInt64>(0)

/// A key for a value stored in `EnvironmentValues`.
public protocol EnvironmentKey {
    associatedtype Value
    static var defaultValue: Value { get }
}

/// A collection of environment values, keyed by `EnvironmentKey` types.
public struct EnvironmentValues: CustomStringConvertible {
    private var storage: [ObjectIdentifier: Any] = [:]
    /// Changes on every mutation (0 for an untouched value).
    package private(set) var revision: UInt64 = 0

    public init() {}

    public subscript<K: EnvironmentKey>(key: K.Type) -> K.Value {
        get {
            // (Not `as? K.Value ?? default`: for an optional `Value` a missing
            // entry would cast to `.some(nil)`.)
            guard let v = storage[ObjectIdentifier(key)] else { return K.defaultValue }
            return v as! K.Value
        }
        set {
            storage[ObjectIdentifier(key)] = newValue
            revision = environmentRevisionCounter.add(1, ordering: .relaxed).newValue
        }
    }

    public var description: String { "EnvironmentValues(\(storage.count) values set)" }
}

/// Light or dark appearance.
public enum ColorScheme: CaseIterable, Sendable, Equatable, Hashable {
    case light
    case dark
}

/// Standard or increased contrast.
public enum ColorSchemeContrast: CaseIterable, Sendable, Equatable, Hashable {
    case standard
    case increased
}

/// Dynamic Type content sizes, smallest to largest (07-text-images-color.md §1.1).
public enum DynamicTypeSize: Hashable, Comparable, CaseIterable, Sendable {
    case xSmall, small, medium, large, xLarge, xxLarge, xxxLarge
    case accessibility1, accessibility2, accessibility3, accessibility4, accessibility5

    public var isAccessibilitySize: Bool { self >= .accessibility1 }
}

private enum ColorSchemeKey: EnvironmentKey { static let defaultValue = ColorScheme.light }
private enum ColorSchemeContrastKey: EnvironmentKey { static let defaultValue = ColorSchemeContrast.standard }
private enum LayoutDirectionKey: EnvironmentKey { static let defaultValue = LayoutDirection.leftToRight }
// The reference device renders at scale 3 (04-layout.md §9).
private enum DisplayScaleKey: EnvironmentKey { static let defaultValue: CGFloat = 3 }
private enum DynamicTypeSizeKey: EnvironmentKey { static let defaultValue = DynamicTypeSize.large }

extension EnvironmentValues {
    public var colorScheme: ColorScheme {
        get { self[ColorSchemeKey.self] }
        set { self[ColorSchemeKey.self] = newValue }
    }

    public var colorSchemeContrast: ColorSchemeContrast {
        get { self[ColorSchemeContrastKey.self] }
        set { self[ColorSchemeContrastKey.self] = newValue }
    }

    public var layoutDirection: LayoutDirection {
        get { self[LayoutDirectionKey.self] }
        set { self[LayoutDirectionKey.self] = newValue }
    }

    /// Device pixels per point.
    public var displayScale: CGFloat {
        get { self[DisplayScaleKey.self] }
        set { self[DisplayScaleKey.self] = newValue }
    }

    /// The size of one device pixel in points (1 / displayScale).
    public var pixelLength: CGFloat { 1 / displayScale }

    public var dynamicTypeSize: DynamicTypeSize {
        get { self[DynamicTypeSizeKey.self] }
        set { self[DynamicTypeSizeKey.self] = newValue }
    }
}
