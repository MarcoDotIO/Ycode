// EKObject: the base of model objects (interface.md §1).

import Foundation

public class EKObject: NSObject {
    /// YES when the object has edits that are not saved.
    public var hasChanges: Bool { false }
    /// YES until the object has been saved to a store.
    public var isNew: Bool { false }
    /// Discards unsaved edits and reloads the stored values.
    public func reset() {}
    /// Discards unsaved edits.
    public func rollback() {}
    /// Reloads stored values; NO when the object no longer exists.
    @discardableResult
    public func refresh() -> Bool { true }

    var objectAddress: String {
        "0x" + String(UInt(bitPattern: ObjectIdentifier(self).hashValue), radix: 16)
    }
}

/// Swift-only callable used by the occurrence enumeration.
public typealias EKEventSearchCallback = (EKEvent, UnsafeMutablePointer<ObjCBool>) -> Void
public typealias EKEventStoreRequestAccessCompletionHandler = (Bool, (any Error)?) -> Void
