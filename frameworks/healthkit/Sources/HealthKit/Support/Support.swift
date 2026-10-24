import Foundation

// MARK: - Programming errors ("exceptions")

/// A HealthKit programming error (`errors.md` §3). Validation code throws it
/// internally (typed throws) so that tests can observe it; the public API turns it
/// into a trap with `hkRaise`, which is what an uncaught Objective-C exception does
/// to an app. On Darwin the trap is a real `NSException` with the interop name.
struct HKRaise: Error, CustomStringConvertible, Equatable, Sendable {
    var name: String
    var reason: String

    static let invalidArgument = "NSInvalidArgumentException"
    static let validationFailure = "_HKObjectValidationFailureException"
    static let generic = "NSGenericException"
    static let internalInconsistency = "NSInternalInconsistencyException"

    static func invalidArgument(_ reason: String) -> HKRaise { HKRaise(name: invalidArgument, reason: reason) }
    static func validation(_ reason: String) -> HKRaise { HKRaise(name: validationFailure, reason: reason) }

    var description: String { "\(name): \(reason)" }
}

/// Raise a HealthKit exception. Never returns.
func hkRaise(_ error: HKRaise) -> Never {
    #if canImport(ObjectiveC)
    NSException(name: NSExceptionName(rawValue: error.name), reason: error.reason, userInfo: nil).raise()
    #endif
    fatalError("*** Terminating app due to uncaught exception '\(error.name)', reason: '\(error.reason)'")
}

/// Run a throwing validation step from a public, non-throwing API.
@inline(__always)
func hkCheck<T>(_ body: () throws(HKRaise) -> T) -> T {
    do { return try body() } catch { hkRaise(error) }
}

// MARK: - Runtime errors (`HKErrorDomain`)

/// HealthKit runtime error (`errors.md` §1). Bridges to `NSError` with domain
/// `com.apple.healthkit` and the `HKErrorCode` raw value as its code.
public struct HKError: CustomNSError, LocalizedError, Hashable, Sendable {
    public enum Code: Int, Sendable, CaseIterable {
        case unknownError = 0
        case errorHealthDataUnavailable = 1
        case errorHealthDataRestricted = 2
        case errorInvalidArgument = 3
        case errorAuthorizationDenied = 4
        case errorAuthorizationNotDetermined = 5
        case errorDatabaseInaccessible = 6
        case errorUserCanceled = 7
        case errorAnotherWorkoutSessionStarted = 8
        case errorUserExitedWorkoutSession = 9
        case errorRequiredAuthorizationDenied = 10
        case errorNoData = 11
        case errorWorkoutActivityNotAllowed = 12
        case errorDataSizeExceeded = 13
        case errorBackgroundWorkoutSessionNotAllowed = 14
        case errorNotPermissibleForGuestUserMode = 15

        @available(*, deprecated, renamed: "unknownError")
        public static var noError: Code { .unknownError }
    }

    public let code: Code
    /// Ycode's own message text (the reference localizes its own).
    public let message: String

    public init(_ code: Code, message: String? = nil) {
        self.code = code
        self.message = message ?? HKError.defaultMessage(code)
    }

    public static var errorDomain: String { HKErrorDomain }
    public var errorCode: Int { code.rawValue }
    public var errorUserInfo: [String: Any] { [NSLocalizedDescriptionKey: message] }
    public var errorDescription: String? { message }

    static func defaultMessage(_ code: Code) -> String {
        switch code {
        case .errorInvalidArgument: return "Invalid argument."
        case .errorAuthorizationDenied: return "Not authorized."
        case .errorAuthorizationNotDetermined: return "Authorization not determined."
        case .errorUserCanceled: return "The user canceled the request."
        case .errorNoData: return "No data available for the specified predicate."
        case .errorHealthDataUnavailable: return "Health data is unavailable on this device."
        default: return "HealthKit error \(code.rawValue)."
        }
    }

    static let notDetermined = HKError(.errorAuthorizationNotDetermined)
    static let notAuthorized = HKError(.errorAuthorizationDenied, message: "Not authorized")
    static let noData = HKError(.errorNoData)
    static let deletionNotFound = HKError(.errorInvalidArgument, message: "Failed to find some objects for deletion.")
}

/// `catch HKError.Code.errorNoData` style matching.
public func ~= (lhs: HKError.Code, rhs: any Error) -> Bool {
    let ns = rhs as NSError
    return ns.domain == HKErrorDomain && ns.code == lhs.rawValue
}

// MARK: - Small utilities

/// A value guarded by a lock (Sendable box for shared mutable state).
final class Locked<Value>: @unchecked Sendable {
    private var value: Value
    private let lock = NSLock()
    init(_ value: Value) { self.value = value }
    func withLock<R>(_ body: (inout Value) throws -> R) rethrows -> R {
        lock.lock(); defer { lock.unlock() }
        return try body(&value)
    }
    var current: Value { withLock { $0 } }
}

/// Box that lets a non-Sendable value cross an isolation boundary when the
/// program guarantees exclusive or read-only use (immutable predicates, results).
struct UncheckedSendable<T>: @unchecked Sendable {
    let value: T
    init(_ value: T) { self.value = value }
}

extension Double {
    /// `%.16g`-style text: what HealthKit prints for molar masses (`units.md` §3).
    var g16: String { String(format: "%.16g", self) }

    /// Compact text for quantities: integral values without a fraction.
    var compactText: String {
        if self.rounded() == self, abs(self) < 1e15 { return String(Int64(self)) }
        return String(format: "%.15g", self)
    }
}

/// Seconds since 1970 (the store's time scale).
extension Date {
    var t: Double { timeIntervalSince1970 }
    init(t: Double) { self.init(timeIntervalSince1970: t) }
}
