import Dispatch
import Foundation

/// Whether the caller runs on the main actor, without trapping.
///
/// The graph runs on the main actor; state written from elsewhere is applied
/// there later. `Thread.isMainThread` is not enough: on Linux, main-actor jobs
/// are run from the main dispatch queue, which is not always drained by the
/// main thread (e.g. under Swift Testing). So the main queue is tagged and
/// the tag looked up; the main thread itself (top-level code) also counts.
package enum MainActorCheck {
    private static let key = DispatchSpecificKey<UInt8>()
    private static let installed: Bool = {
        DispatchQueue.main.setSpecific(key: key, value: 1)
        return true
    }()

    package static var isCurrent: Bool {
        _ = installed
        return Thread.isMainThread || DispatchQueue.getSpecific(key: key) == 1
    }
}
