// Enumerations and option sets of the model (object-model.md §2, §3, §9).

import Foundation

/// object-model.md §2: Determined (1), Restricted (2), Authorized (4).
public struct HMHomeManagerAuthorizationStatus: OptionSet, Hashable, Sendable {
    public let rawValue: UInt
    public init(rawValue: UInt) { self.rawValue = rawValue }
    public static let determined = HMHomeManagerAuthorizationStatus(rawValue: 1)
    public static let restricted = HMHomeManagerAuthorizationStatus(rawValue: 2)
    public static let authorized = HMHomeManagerAuthorizationStatus(rawValue: 4)
}

/// object-model.md §3 (iOS 11).
public enum HMHomeHubState: Int, Sendable, Codable {
    case notAvailable = 0
    case connected = 1
    case disconnected = 2
}

/// object-model.md §9.
public enum HMEventTriggerActivationState: Int, Sendable, Codable {
    case disabled = 0
    case disabledNoHomeHub = 1
    case disabledNoCompatibleHomeHub = 2
    case disabledNoLocationServicesAuthorization = 3
    case enabled = 4
}

/// object-model.md §9: every entry 1, every exit 2, first entry 3 (at home),
/// last exit 4 (not at home).
public enum HMPresenceEventType: Int, Sendable, Codable {
    case everyEntry = 1
    case everyExit = 2
    case firstEntry = 3
    case lastExit = 4
    public static var atHome: HMPresenceEventType { .firstEntry }
    public static var notAtHome: HMPresenceEventType { .lastExit }
}

/// object-model.md §9: current user 1, home users 2, custom users 3.
public enum HMPresenceEventUserType: Int, Sendable, Codable {
    case currentUser = 1
    case homeUsers = 2
    case customUsers = 3
}

/// Delivery on the main queue (object-model.md §12).
@inline(__always)
func onMain(_ body: @escaping () -> Void) {
    DispatchQueue.main.async(execute: body)
}

/// The link from model objects to their store session.
final class YcodeConnection: @unchecked Sendable {
    let store: YcodeHomeStore
    var sessionID = UUID()
    weak var manager: HMHomeManager?

    init(store: YcodeHomeStore) { self.store = store }

    /// Sends a request; the completion runs on the main queue.
    func request(_ r: YcodeHomeRequest, _ done: @escaping (Result<YcodeHomeResponse, Error>) -> Void) {
        store.perform(r, session: sessionID) { result in
            onMain {
                switch result {
                case .success(let v): done(.success(v))
                case .failure(let e): done(.failure(e.publicError))
                }
            }
        }
    }

    /// A request whose completion only reports an error.
    func simple(_ r: YcodeHomeRequest, _ completion: @escaping (Error?) -> Void) {
        request(r) { result in
            if case .failure(let e) = result { completion(e) } else { completion(nil) }
        }
    }
}

/// Completion with an error on the main queue, without I/O.
func fail(_ completion: @escaping (Error?) -> Void, _ code: HMError.Code) {
    onMain { completion(HMError(code)) }
}

/// Bridges a completion-handler call to `async throws`.
func asyncCall(_ body: (@escaping (Error?) -> Void) -> Void) async throws {
    try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
        body { error in
            if let error { c.resume(throwing: error) } else { c.resume() }
        }
    }
}

func asyncCall<T>(_ body: (@escaping (T?, Error?) -> Void) -> Void) async throws -> T {
    try await withCheckedThrowingContinuation { (c: CheckedContinuation<T, Error>) in
        body { value, error in
            if let error { c.resume(throwing: error) } else if let value { c.resume(returning: value) } else {
                c.resume(throwing: HMError(.unexpectedError))
            }
        }
    }
}
