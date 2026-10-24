// CNErrorDomain errors and the two Contacts exceptions
// (specs/frameworks/contacts/errors.md). Codes and user-info keys are the
// contract; the English messages are Ycode's own wording.

import Foundation

public struct CNError: Error, @unchecked Sendable {
    public enum Code: Int, Sendable {
        case communicationError = 1
        case dataAccessError = 2
        case authorizationDenied = 100
        case noAccessableWritableContainers = 101
        case unauthorizedKeys = 102
        case featureDisabledByUser = 103
        case featureNotAvailable = 104
        case recordDoesNotExist = 200
        case insertedRecordAlreadyExists = 201
        case containmentCycle = 202
        case containmentScope = 203
        case parentRecordDoesNotExist = 204
        case recordIdentifierInvalid = 205
        case recordNotWritable = 206
        case parentContainerNotWritable = 207
        case validationMultipleErrors = 300
        case validationTypeMismatch = 301
        case validationConfigurationError = 302
        case predicateInvalid = 400
        case policyViolation = 500
        case clientIdentifierInvalid = 600
        case clientIdentifierDoesNotExist = 601
        case clientIdentifierCollision = 602
        case changeHistoryExpired = 603
        case changeHistoryInvalidAnchor = 604
        case changeHistoryInvalidFetchRequest = 605
        case vCardMalformed = 700
        case vCardSummarizationError = 701
    }

    public let code: Code
    /// The full user-info dictionary (CNInvalidRecords, CNInvalidRecordIdentifiers,
    /// CNKeyPaths, NSLocalizedDescription, NSLocalizedFailureReason).
    public let userInfo: [String: Any]

    public init(_ code: Code, userInfo: [String: Any] = [:]) {
        self.code = code
        var info = userInfo
        if info[NSLocalizedDescriptionKey] == nil { info[NSLocalizedDescriptionKey] = CNError.message(for: code) }
        if info[NSLocalizedFailureReasonErrorKey] == nil { info[NSLocalizedFailureReasonErrorKey] = CNError.reason(for: code) }
        self.userInfo = info
    }

    public static var errorDomain: String { CNErrorDomain }

    // Swift overlay accessors (README.md "Framework layout facts").
    public var affectedRecords: [AnyObject]? { userInfo[CNErrorUserInfoAffectedRecordsKey] as? [AnyObject] }
    public var affectedRecordIdentifiers: [String]? { userInfo[CNErrorUserInfoAffectedRecordIdentifiersKey] as? [String] }
    public var keyPaths: [String]? { userInfo[CNErrorUserInfoKeyPathsKey] as? [String] }

    public static var authorizationDenied: Code { .authorizationDenied }
    public static var unauthorizedKeys: Code { .unauthorizedKeys }
    public static var recordDoesNotExist: Code { .recordDoesNotExist }
    public static var insertedRecordAlreadyExists: Code { .insertedRecordAlreadyExists }
    public static var predicateInvalid: Code { .predicateInvalid }
    public static var vCardMalformed: Code { .vCardMalformed }

    /// Ycode's short description for a code.
    static func message(for code: Code) -> String {
        switch code {
        case .communicationError: return "Could not reach the contacts service"
        case .dataAccessError: return "Could not read or write the contacts database"
        case .authorizationDenied: return "Access to contacts is not allowed"
        case .noAccessableWritableContainers: return "No writable contacts account"
        case .unauthorizedKeys: return "Keys Not Allowed"
        case .featureDisabledByUser: return "Feature Turned Off"
        case .featureNotAvailable: return "Feature Not Available"
        case .recordDoesNotExist: return "Record Not Found"
        case .insertedRecordAlreadyExists: return "Record Already Saved"
        case .containmentCycle: return "Group Cycle"
        case .containmentScope: return "Wrong Account"
        case .parentRecordDoesNotExist: return "Parent Record Not Found"
        case .recordIdentifierInvalid: return "Bad Record Identifier"
        case .recordNotWritable: return "Record Is Read-Only"
        case .parentContainerNotWritable: return "Account Is Read-Only"
        case .validationMultipleErrors: return "Several Validation Errors"
        case .validationTypeMismatch: return "Value Of The Wrong Type"
        case .validationConfigurationError: return "Validation Setup Error"
        case .predicateInvalid: return "Predicate Not Supported"
        case .policyViolation: return "Policy Violation"
        case .clientIdentifierInvalid: return "Bad Client Identifier"
        case .clientIdentifierDoesNotExist: return "Client Identifier Not Found"
        case .clientIdentifierCollision: return "Client Identifier In Use"
        case .changeHistoryExpired: return "Change History Expired"
        case .changeHistoryInvalidAnchor: return "Bad Change History Token"
        case .changeHistoryInvalidFetchRequest: return "Bad Change History Request"
        case .vCardMalformed: return "vCard Data Not Readable"
        case .vCardSummarizationError: return "vCard Data Not Writable"
        }
    }

    static func reason(for code: Code) -> String {
        switch code {
        case .recordDoesNotExist: return "The record you tried to read or change is not in the contacts database."
        case .insertedRecordAlreadyExists: return "The record you tried to add is already in the contacts database."
        case .unauthorizedKeys: return "This app is not allowed to fetch some of the requested keys."
        case .authorizationDenied: return "The user has not given this app access to contacts."
        default: return message(for: code) + "."
        }
    }
}

/// Pattern matching in `catch CNError.recordDoesNotExist { … }`.
public func ~= (code: CNError.Code, error: any Error) -> Bool {
    guard let error = error as? CNError else { return false }
    return error.code == code
}

extension CNError: CustomNSError {
    public var errorCode: Int { code.rawValue }
    public var errorUserInfo: [String: Any] { userInfo }
}

extension CNError: LocalizedError {
    public var errorDescription: String? { userInfo[NSLocalizedDescriptionKey] as? String }
    public var failureReason: String? { userInfo[NSLocalizedFailureReasonErrorKey] as? String }
}

// MARK: - Exceptions

/// Not a declared constant (errors.md §3 names the exception by its string).
let propertyInvalidTypeExceptionName = "CNPropertyInvalidTypeException"

/// An Objective-C style exception of the framework (errors.md §3).
///
/// Swift cannot raise Objective-C exceptions portably. By default a raise
/// stops the process (`fatalError`) with "<name>: <reason>". Inside
/// `CNException.catching { … }` a raise is recorded instead, the offending
/// call returns an empty value without side effects, and `catching`
/// throws the first recorded exception.
public struct CNException: Error, Equatable, CustomStringConvertible, Sendable {
    public let name: String
    public let reason: String

    public init(name: String, reason: String) {
        self.name = name
        self.reason = reason
    }

    public var description: String { "\(name): \(reason)" }

    static let notFetchedReason = "A property was not requested when contact was fetched."

    static func notFetched() -> CNException {
        CNException(name: CNContactPropertyNotFetchedExceptionName, reason: notFetchedReason)
    }

    private static let captureKey = "org.ycode.contacts.exception-capture"

    private final class Capture {
        var depth = 0
        var first: CNException?
    }

    /// Runs `body`; throws the first exception it raised.
    @discardableResult
    public static func catching<T>(_ body: () throws -> T) throws -> T {
        let dict = Thread.current.threadDictionary
        let cap = (dict[captureKey] as? Capture) ?? Capture()
        dict[captureKey] = cap
        cap.depth += 1
        let saved = cap.first
        cap.first = nil
        defer {
            cap.depth -= 1
            if cap.depth == 0 { dict.removeObject(forKey: captureKey) }
        }
        let result = try body()
        let raised = cap.first
        cap.first = saved
        if let raised { throw raised }
        return result
    }

    /// Raises `self`: records it inside `catching`, otherwise stops the process.
    func raise() {
        if let cap = Thread.current.threadDictionary[CNException.captureKey] as? Capture, cap.depth > 0 {
            if cap.first == nil { cap.first = self }
            return
        }
        fatalError(description)
    }
}
