import Foundation

/// The runtime sanitizers of a scheme action's Diagnostics (Run ▸
/// Diagnostics, `specs/ide/schemes.md` §Diagnostics). Stored as attributes
/// of the action element, `"YES"` when on and absent when off:
/// `enableAddressSanitizer`, `enableASanStackUseAfterReturn`,
/// `enableThreadSanitizer`, `enableUBSanitizer`.
public struct SchemeDiagnostics: Equatable, Sendable {
    public var addressSanitizer = false
    /// "Detect use of stack after return"; only meaningful with ASan.
    public var stackUseAfterReturn = false
    public var threadSanitizer = false
    public var undefinedBehaviorSanitizer = false

    public init(addressSanitizer: Bool = false, stackUseAfterReturn: Bool = false, threadSanitizer: Bool = false,
                undefinedBehaviorSanitizer: Bool = false) {
        self.addressSanitizer = addressSanitizer
        self.stackUseAfterReturn = stackUseAfterReturn
        self.threadSanitizer = threadSanitizer
        self.undefinedBehaviorSanitizer = undefinedBehaviorSanitizer
    }

    /// Attribute names, in the order the editor lists them.
    public static var attributes: [(key: WritableKeyPath<SchemeDiagnostics, Bool>, name: String)] {
        [
            (\.addressSanitizer, "enableAddressSanitizer"),
            (\.stackUseAfterReturn, "enableASanStackUseAfterReturn"),
            (\.threadSanitizer, "enableThreadSanitizer"),
            (\.undefinedBehaviorSanitizer, "enableUBSanitizer"),
        ]
    }

    /// Nothing is on.
    public var isEmpty: Bool { self == SchemeDiagnostics() }

    /// Turns one sanitizer on or off. The address and thread sanitizers
    /// cannot be combined (clang rejects `-fsanitize=address,thread`):
    /// turning one on turns the other off. Turning ASan off also clears
    /// its stack-use-after-return option.
    public mutating func set(_ key: WritableKeyPath<SchemeDiagnostics, Bool>, _ on: Bool) {
        self[keyPath: key] = on
        if on, key == \.addressSanitizer { threadSanitizer = false }
        if on, key == \.threadSanitizer { addressSanitizer = false; stackUseAfterReturn = false }
        if !addressSanitizer { stackUseAfterReturn = false }
    }
}

extension Scheme {
    /// The sanitizers of `action` (`"LaunchAction"`, `"TestAction"`).
    public func diagnostics(for action: String = "LaunchAction") -> SchemeDiagnostics {
        var d = SchemeDiagnostics()
        guard let node = document.child(action) else { return d }
        for a in SchemeDiagnostics.attributes { d[keyPath: a.key] = node[a.name] == "YES" }
        if !d.addressSanitizer { d.stackUseAfterReturn = false }
        return d
    }

    /// Writes the sanitizers of `action`: `"YES"` for each one on, the
    /// attribute removed for each one off.
    public mutating func setDiagnostics(_ d: SchemeDiagnostics, for action: String = "LaunchAction") {
        editAction(action) { node in
            for a in SchemeDiagnostics.attributes { node[a.name] = d[keyPath: a.key] ? "YES" : nil }
        }
    }
}
