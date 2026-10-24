// HomeKit errors (errors.md §1–§3).
//
// Public failures are `HMError` values (domain `HMErrorDomain`); the
// undocumented code 2040 of errors.md §2 is a plain NSError in the same domain
// because it has no `HMError.Code` case. Descriptions are Ycode's own wording.

import Foundation

public typealias HMErrorCode = HMError.Code

/// A HomeKit error: domain `HMErrorDomain`, one of the public codes.
public struct HMError: Error, CustomNSError, Hashable, Sendable, CustomStringConvertible {
    /// `HMErrorCode` (errors.md §1).
    public enum Code: Int, Sendable, CaseIterable, Codable {
        case unexpectedError = -1
        case alreadyExists = 1
        case notFound = 2
        case invalidParameter = 3
        case accessoryNotReachable = 4
        case readOnlyCharacteristic = 5
        case writeOnlyCharacteristic = 6
        case notificationNotSupported = 7
        case operationTimedOut = 8
        case accessoryPoweredOff = 9
        case accessDenied = 10
        case objectAssociatedToAnotherHome = 11
        case objectNotAssociatedToAnyHome = 12
        case objectAlreadyAssociatedToHome = 13
        case accessoryIsBusy = 14
        case operationInProgress = 15
        case accessoryOutOfResources = 16
        case insufficientPrivileges = 17
        case accessoryPairingFailed = 18
        case invalidDataFormatSpecified = 19
        case nilParameter = 20
        case unconfiguredParameter = 21
        case invalidClass = 22
        case operationCancelled = 23
        case roomForHomeCannotBeInZone = 24
        case noActionsInActionSet = 25
        case noRegisteredActionSets = 26
        case missingParameter = 27
        case fireDateInPast = 28
        case roomForHomeCannotBeUpdated = 29
        case actionInAnotherActionSet = 30
        case objectWithSimilarNameExistsInHome = 31
        case homeWithSimilarNameExists = 32
        case renameWithSimilarName = 33
        case cannotRemoveNonBridgeAccessory = 34
        case nameContainsProhibitedCharacters = 35
        case nameDoesNotStartWithValidCharacters = 36
        case userIDNotEmailAddress = 37
        case userDeclinedAddingUser = 38
        case userDeclinedRemovingUser = 39
        case userDeclinedInvite = 40
        case userManagementFailed = 41
        case recurrenceTooSmall = 42
        case invalidValueType = 43
        case valueLowerThanMinimum = 44
        case valueHigherThanMaximum = 45
        case stringLongerThanMaximum = 46
        case homeAccessNotAuthorized = 47
        case operationNotSupported = 48
        case maximumObjectLimitReached = 49
        case accessorySentInvalidResponse = 50
        case stringShorterThanMinimum = 51
        case genericError = 52
        case securityFailure = 53
        case communicationFailure = 54
        case messageAuthenticationFailed = 55
        case invalidMessageSize = 56
        case accessoryDiscoveryFailed = 57
        case clientRequestError = 58
        case accessoryResponseError = 59
        case nameDoesNotEndWithValidCharacters = 60
        case accessoryIsBlocked = 61
        case invalidAssociatedServiceType = 62
        case actionSetExecutionFailed = 63
        case actionSetExecutionPartialSuccess = 64
        case actionSetExecutionInProgress = 65
        case accessoryOutOfCompliance = 66
        case dataResetFailure = 67
        case notificationAlreadyEnabled = 68
        case recurrenceMustBeOnSpecifiedBoundaries = 69
        case dateMustBeOnSpecifiedBoundaries = 70
        case cannotActivateTriggerTooFarInFuture = 71
        case recurrenceTooLarge = 72
        case readWritePartialSuccess = 73
        case readWriteFailure = 74
        case notSignedIntoiCloud = 75
        case keychainSyncNotEnabled = 76
        case cloudDataSyncInProgress = 77
        case networkUnavailable = 78
        case addAccessoryFailed = 79
        case missingEntitlement = 80
        case cannotUnblockNonBridgeAccessory = 81
        case deviceLocked = 82
        case cannotRemoveBuiltinActionSet = 83
        case locationForHomeDisabled = 84
        case notAuthorizedForLocationServices = 85
        case referToUserManual = 86
        case invalidOrMissingAuthorizationData = 87
        case bridgedAccessoryNotReachable = 88
        case notAuthorizedForMicrophoneAccess = 89
        case incompatibleNetwork = 90
        case noHomeHub = 91
        case noCompatibleHomeHub = 92
        case incompatibleAccessory = 93
        case objectWithSimilarNameExists = 95
        case ownershipFailure = 96
        case maximumAccessoriesOfTypeInHome = 97
        case wiFiCredentialGenerationFailed = 98
        case enterpriseNetworkNotSupported = 99
        case timedOutWaitingForAccessory = 100
        case accessoryCommunicationFailure = 101
        case failedToJoinNetwork = 102
        case accessoryIsSuspended = 103
        case partialCommunicationFailure = 104
        case homeUpgradeRequired = 105

        /// Deprecated alias of `noCompatibleHomeHub` (errors.md §1).
        @available(iOS, deprecated: 11.0)
        public static var incompatibleHomeHub: Code { .noCompatibleHomeHub }
    }

    public let code: Code
    public let userInfo: [String: String]

    public init(_ code: Code, userInfo: [String: String]? = nil) {
        self.code = code
        self.userInfo = userInfo ?? [NSLocalizedDescriptionKey: HMError.describe(code)]
    }

    public init(_ code: Code, description: String) {
        self.init(code, userInfo: [NSLocalizedDescriptionKey: description])
    }

    public static var errorDomain: String { HMErrorDomain }
    public var errorCode: Int { code.rawValue }
    public var errorUserInfo: [String: Any] { userInfo }
    public var localizedDescription: String { userInfo[NSLocalizedDescriptionKey] ?? HMError.describe(code) }
    public var description: String { "HMError(\(code.rawValue) \(code))" }

    /// Ycode's description text for a code (own wording, errors.md §2 last paragraph).
    public static func describe(_ code: Code) -> String {
        switch code {
        case .homeAccessNotAuthorized: return "Access to home data is not authorized for this app."
        case .operationCancelled: return "The operation was cancelled."
        default:
            // Split the case name into words: "valueLowerThanMinimum" -> "Value lower than minimum."
            var words = ""
            for ch in String(describing: code) {
                if ch.isUppercase, !words.isEmpty { words.append(" ") }
                words.append(ch)
            }
            return words.prefix(1).uppercased() + words.dropFirst().lowercased()
                .replacingOccurrences(of: "icloud", with: "iCloud")
                .replacingOccurrences(of: "i d ", with: "ID ") + "."
        }
    }
}

extension HMError {
    /// The private "no account" code returned by `addHome` without an iCloud
    /// account (errors.md §2; not a public `HMErrorCode`).
    public static let ycodeNoAccountCode = 2040

    /// The 2040 error exactly as errors.md §2 describes it: domain
    /// `HMErrorDomain`, userInfo holding only a localized description.
    public static func ycodeNoAccountError() -> NSError {
        NSError(domain: HMErrorDomain, code: ycodeNoAccountCode,
                userInfo: [NSLocalizedDescriptionKey: "The operation could not be completed (unknown error code 2040)."])
    }

    /// Errors 23 of the setup flow carry an empty userInfo (errors.md §2).
    static let cancelledWithoutInfo = HMError(.operationCancelled, userInfo: [:])
}

extension HMError {
    // `catch HMError.notFound` style matching (static members of type `Code`).
    public static var unexpectedError: Code { .unexpectedError }
    public static var alreadyExists: Code { .alreadyExists }
    public static var notFound: Code { .notFound }
    public static var invalidParameter: Code { .invalidParameter }
    public static var accessoryNotReachable: Code { .accessoryNotReachable }
    public static var readOnlyCharacteristic: Code { .readOnlyCharacteristic }
    public static var writeOnlyCharacteristic: Code { .writeOnlyCharacteristic }
    public static var notificationNotSupported: Code { .notificationNotSupported }
    public static var operationTimedOut: Code { .operationTimedOut }
    public static var accessoryPoweredOff: Code { .accessoryPoweredOff }
    public static var accessDenied: Code { .accessDenied }
    public static var objectAssociatedToAnotherHome: Code { .objectAssociatedToAnotherHome }
    public static var objectNotAssociatedToAnyHome: Code { .objectNotAssociatedToAnyHome }
    public static var objectAlreadyAssociatedToHome: Code { .objectAlreadyAssociatedToHome }
    public static var accessoryIsBusy: Code { .accessoryIsBusy }
    public static var operationInProgress: Code { .operationInProgress }
    public static var accessoryOutOfResources: Code { .accessoryOutOfResources }
    public static var insufficientPrivileges: Code { .insufficientPrivileges }
    public static var accessoryPairingFailed: Code { .accessoryPairingFailed }
    public static var invalidDataFormatSpecified: Code { .invalidDataFormatSpecified }
    public static var nilParameter: Code { .nilParameter }
    public static var unconfiguredParameter: Code { .unconfiguredParameter }
    public static var invalidClass: Code { .invalidClass }
    public static var operationCancelled: Code { .operationCancelled }
    public static var roomForHomeCannotBeInZone: Code { .roomForHomeCannotBeInZone }
    public static var noActionsInActionSet: Code { .noActionsInActionSet }
    public static var noRegisteredActionSets: Code { .noRegisteredActionSets }
    public static var missingParameter: Code { .missingParameter }
    public static var fireDateInPast: Code { .fireDateInPast }
    public static var roomForHomeCannotBeUpdated: Code { .roomForHomeCannotBeUpdated }
    public static var actionInAnotherActionSet: Code { .actionInAnotherActionSet }
    public static var objectWithSimilarNameExistsInHome: Code { .objectWithSimilarNameExistsInHome }
    public static var homeWithSimilarNameExists: Code { .homeWithSimilarNameExists }
    public static var renameWithSimilarName: Code { .renameWithSimilarName }
    public static var cannotRemoveNonBridgeAccessory: Code { .cannotRemoveNonBridgeAccessory }
    public static var nameContainsProhibitedCharacters: Code { .nameContainsProhibitedCharacters }
    public static var nameDoesNotStartWithValidCharacters: Code { .nameDoesNotStartWithValidCharacters }
    public static var userIDNotEmailAddress: Code { .userIDNotEmailAddress }
    public static var userDeclinedAddingUser: Code { .userDeclinedAddingUser }
    public static var userDeclinedRemovingUser: Code { .userDeclinedRemovingUser }
    public static var userDeclinedInvite: Code { .userDeclinedInvite }
    public static var userManagementFailed: Code { .userManagementFailed }
    public static var recurrenceTooSmall: Code { .recurrenceTooSmall }
    public static var invalidValueType: Code { .invalidValueType }
    public static var valueLowerThanMinimum: Code { .valueLowerThanMinimum }
    public static var valueHigherThanMaximum: Code { .valueHigherThanMaximum }
    public static var stringLongerThanMaximum: Code { .stringLongerThanMaximum }
    public static var homeAccessNotAuthorized: Code { .homeAccessNotAuthorized }
    public static var operationNotSupported: Code { .operationNotSupported }
    public static var maximumObjectLimitReached: Code { .maximumObjectLimitReached }
    public static var accessorySentInvalidResponse: Code { .accessorySentInvalidResponse }
    public static var stringShorterThanMinimum: Code { .stringShorterThanMinimum }
    public static var genericError: Code { .genericError }
    public static var securityFailure: Code { .securityFailure }
    public static var communicationFailure: Code { .communicationFailure }
    public static var messageAuthenticationFailed: Code { .messageAuthenticationFailed }
    public static var invalidMessageSize: Code { .invalidMessageSize }
    public static var accessoryDiscoveryFailed: Code { .accessoryDiscoveryFailed }
    public static var clientRequestError: Code { .clientRequestError }
    public static var accessoryResponseError: Code { .accessoryResponseError }
    public static var nameDoesNotEndWithValidCharacters: Code { .nameDoesNotEndWithValidCharacters }
    public static var accessoryIsBlocked: Code { .accessoryIsBlocked }
    public static var invalidAssociatedServiceType: Code { .invalidAssociatedServiceType }
    public static var actionSetExecutionFailed: Code { .actionSetExecutionFailed }
    public static var actionSetExecutionPartialSuccess: Code { .actionSetExecutionPartialSuccess }
    public static var actionSetExecutionInProgress: Code { .actionSetExecutionInProgress }
    public static var accessoryOutOfCompliance: Code { .accessoryOutOfCompliance }
    public static var dataResetFailure: Code { .dataResetFailure }
    public static var notificationAlreadyEnabled: Code { .notificationAlreadyEnabled }
    public static var recurrenceMustBeOnSpecifiedBoundaries: Code { .recurrenceMustBeOnSpecifiedBoundaries }
    public static var dateMustBeOnSpecifiedBoundaries: Code { .dateMustBeOnSpecifiedBoundaries }
    public static var cannotActivateTriggerTooFarInFuture: Code { .cannotActivateTriggerTooFarInFuture }
    public static var recurrenceTooLarge: Code { .recurrenceTooLarge }
    public static var readWritePartialSuccess: Code { .readWritePartialSuccess }
    public static var readWriteFailure: Code { .readWriteFailure }
    public static var notSignedIntoiCloud: Code { .notSignedIntoiCloud }
    public static var keychainSyncNotEnabled: Code { .keychainSyncNotEnabled }
    public static var cloudDataSyncInProgress: Code { .cloudDataSyncInProgress }
    public static var networkUnavailable: Code { .networkUnavailable }
    public static var addAccessoryFailed: Code { .addAccessoryFailed }
    public static var missingEntitlement: Code { .missingEntitlement }
    public static var cannotUnblockNonBridgeAccessory: Code { .cannotUnblockNonBridgeAccessory }
    public static var deviceLocked: Code { .deviceLocked }
    public static var cannotRemoveBuiltinActionSet: Code { .cannotRemoveBuiltinActionSet }
    public static var locationForHomeDisabled: Code { .locationForHomeDisabled }
    public static var notAuthorizedForLocationServices: Code { .notAuthorizedForLocationServices }
    public static var referToUserManual: Code { .referToUserManual }
    public static var invalidOrMissingAuthorizationData: Code { .invalidOrMissingAuthorizationData }
    public static var bridgedAccessoryNotReachable: Code { .bridgedAccessoryNotReachable }
    public static var notAuthorizedForMicrophoneAccess: Code { .notAuthorizedForMicrophoneAccess }
    public static var incompatibleNetwork: Code { .incompatibleNetwork }
    public static var noHomeHub: Code { .noHomeHub }
    public static var noCompatibleHomeHub: Code { .noCompatibleHomeHub }
    public static var incompatibleAccessory: Code { .incompatibleAccessory }
    public static var objectWithSimilarNameExists: Code { .objectWithSimilarNameExists }
    public static var ownershipFailure: Code { .ownershipFailure }
    public static var maximumAccessoriesOfTypeInHome: Code { .maximumAccessoriesOfTypeInHome }
    public static var wiFiCredentialGenerationFailed: Code { .wiFiCredentialGenerationFailed }
    public static var enterpriseNetworkNotSupported: Code { .enterpriseNetworkNotSupported }
    public static var timedOutWaitingForAccessory: Code { .timedOutWaitingForAccessory }
    public static var accessoryCommunicationFailure: Code { .accessoryCommunicationFailure }
    public static var failedToJoinNetwork: Code { .failedToJoinNetwork }
    public static var accessoryIsSuspended: Code { .accessoryIsSuspended }
    public static var partialCommunicationFailure: Code { .partialCommunicationFailure }
    public static var homeUpgradeRequired: Code { .homeUpgradeRequired }
}

extension HMError.Code {
    /// `catch HMError.notFound` style matching.
    public static func ~= (code: HMError.Code, error: Error) -> Bool {
        (error as? HMError)?.code == code
    }
}

// MARK: - Wire form

/// An error as it crosses the store boundary (Codable for a future daemon).
public struct YcodeHomeStoreError: Error, Codable, Hashable, Sendable {
    public var domain: String
    public var code: Int
    public var userInfo: [String: String]

    public init(_ code: HMError.Code, userInfo: [String: String]? = nil) {
        let e = HMError(code, userInfo: userInfo)
        self.domain = HMErrorDomain
        self.code = code.rawValue
        self.userInfo = e.userInfo
    }

    public init(domain: String, code: Int, userInfo: [String: String]) {
        self.domain = domain
        self.code = code
        self.userInfo = userInfo
    }

    static let noAccount = YcodeHomeStoreError(
        domain: HMErrorDomain, code: HMError.ycodeNoAccountCode,
        userInfo: HMError.ycodeNoAccountError().userInfo.compactMapValues { $0 as? String })

    /// The error an app sees: `HMError` for public codes, `NSError` otherwise.
    public var publicError: Error {
        if domain == HMErrorDomain, let c = HMError.Code(rawValue: code) {
            return HMError(c, userInfo: userInfo)
        }
        return NSError(domain: domain, code: code, userInfo: userInfo)
    }
}

// MARK: - Accessory protocol status (errors.md §3, accessory-protocols.md §2.3)

/// HAP status codes, the error vocabulary of `YcodeAccessoryEndpoint`.
public enum YcodeHAPStatus: Int, Codable, Sendable, CaseIterable {
    case success = 0
    case insufficientPrivileges = -70401
    case unableToCommunicate = -70402
    case resourceBusy = -70403
    case writeToReadOnly = -70404
    case readFromWriteOnly = -70405
    case notificationNotSupported = -70406
    case outOfResources = -70407
    case operationTimedOut = -70408
    case resourceDoesNotExist = -70409
    case invalidValue = -70410
    case insufficientAuthorization = -70411

    /// The `HMErrorCode` an app sees for this status (errors.md §3, Ycode's proposal).
    public var errorCode: HMError.Code? {
        switch self {
        case .success: return nil
        case .insufficientPrivileges: return .insufficientPrivileges
        case .unableToCommunicate: return .communicationFailure
        case .resourceBusy: return .accessoryIsBusy
        case .writeToReadOnly: return .readOnlyCharacteristic
        case .readFromWriteOnly: return .writeOnlyCharacteristic
        case .notificationNotSupported: return .notificationNotSupported
        case .outOfResources: return .accessoryOutOfResources
        case .operationTimedOut: return .operationTimedOut
        case .resourceDoesNotExist: return .notFound
        case .invalidValue: return .invalidParameter
        case .insufficientAuthorization: return .invalidOrMissingAuthorizationData
        }
    }
}

/// Why an accessory operation failed: a HAP status, or the connection is gone
/// (mapped to 4 `AccessoryNotReachable`, errors.md §3 last row).
public enum YcodeAccessoryFailure: Error, Codable, Hashable, Sendable {
    case status(YcodeHAPStatus)
    case unreachable

    public var errorCode: HMError.Code {
        switch self {
        case .status(let s): return s.errorCode ?? .unexpectedError
        case .unreachable: return .accessoryNotReachable
        }
    }
}
