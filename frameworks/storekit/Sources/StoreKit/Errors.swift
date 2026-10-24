// StoreKit 2 errors and verification results (errors.md §1–§2; formats.md §2).
import Foundation
import StoreKitConfiguration
import StoreKitEngine
import StoreKitSigning

/// A `URLError.Code` from its raw value (the initializer is failable on some platforms).
@_spi(Ycode) public func urlErrorCode(_ raw: Int) -> URLError.Code {
    let code: URLError.Code? = URLError.Code(rawValue: raw)
    return code ?? .unknown
}

/// `StoreKitError` (errors.md §1). The payload cases come first so that the
/// bridged `NSError` codes match the observed ones: `systemError` 1, `unknown` 2.
public enum StoreKitError: Error, Sendable {
    case networkError(URLError)
    case systemError(any Error & Sendable)
    case unknown
    case userCancelled
    case notAvailableInStorefront
    case notEntitled
    case unsupported
    case invalidPresentationContext

    init(_ kind: StoreKitErrorKind) {
        switch kind {
        case .unknown: self = .unknown
        case .userCancelled: self = .userCancelled
        case .networkError(let code): self = .networkError(URLError(urlErrorCode(code)))
        case .systemError(.noAccount): self = .systemError(YcodeStoreSystemError.noAccount)
        case .systemError(.unknown): self = .systemError(YcodeStoreSystemError.unknown)
        case .notAvailableInStorefront: self = .notAvailableInStorefront
        case .notEntitled: self = .notEntitled
        case .unsupported: self = .unsupported
        }
    }

    /// The kind without its payload, for comparisons.
    public var ycodeKind: String {
        switch self {
        case .networkError: return "networkError"
        case .systemError: return "systemError"
        case .unknown: return "unknown"
        case .userCancelled: return "userCancelled"
        case .notAvailableInStorefront: return "notAvailableInStorefront"
        case .notEntitled: return "notEntitled"
        case .unsupported: return "unsupported"
        case .invalidPresentationContext: return "invalidPresentationContext"
        }
    }
}

extension StoreKitError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .unknown: return "An unknown error occurred."
        case .userCancelled: return "The user cancelled."
        case .networkError(let e): return "A network error occurred (\(e.code.rawValue))."
        case .systemError(let e): return "A system error occurred (\(e))."
        case .notAvailableInStorefront: return "The product is not available in this storefront."
        case .notEntitled: return "The app is not entitled to use this API."
        case .unsupported: return "This is not supported here."
        case .invalidPresentationContext: return "The presentation context is not valid."
        }
    }
}

/// Wraps a signed value with the outcome of its verification.
public enum VerificationResult<SignedType: Sendable>: Sendable {
    case unverified(SignedType, VerificationResult<SignedType>.VerificationError)
    case verified(SignedType)

    /// `VerificationResult.VerificationError` (errors.md §2).
    public enum VerificationError: Error, Hashable, Sendable {
        case revokedCertificate
        case invalidCertificateChain
        case invalidDeviceVerification
        case invalidEncoding
        case invalidSignature
        case missingRequiredProperties

        init?(_ reason: VerificationFailureReason) {
            switch reason {
            case .revokedCertificate: self = .revokedCertificate
            case .invalidCertificateChain: self = .invalidCertificateChain
            case .invalidDeviceVerification: self = .invalidDeviceVerification
            case .invalidEncoding: self = .invalidEncoding
            case .invalidSignature: self = .invalidSignature
            case .missingRequiredProperties: self = .missingRequiredProperties
            }
        }
    }

    /// The value, or the verification error.
    public var payloadValue: SignedType {
        get throws {
            switch self {
            case .verified(let v): return v
            case .unverified(_, let e): throw e
            }
        }
    }

    /// The value whether or not it verified.
    public var unsafePayloadValue: SignedType {
        switch self {
        case .verified(let v), .unverified(let v, _): return v
        }
    }
}

/// A value that carries its compact JWS (Ycode's link between a signed
/// value and its `VerificationResult`).
public protocol YcodeSignedValue: Sendable {
    var ycodeJWS: String { get }
}

extension VerificationResult where SignedType: YcodeSignedValue {
    /// The compact JWS.
    public var jwsRepresentation: String { unsafePayloadValue.ycodeJWS }

    private var parts: [Substring] { jwsRepresentation.split(separator: ".", omittingEmptySubsequences: false) }

    public var headerData: Data { Base64URL.decode(parts[0]) ?? Data() }
    public var payloadData: Data { parts.count > 1 ? Base64URL.decode(parts[1]) ?? Data() : Data() }
    public var signatureData: Data { parts.count > 2 ? Base64URL.decode(parts[2]) ?? Data() : Data() }
    /// The data the signature covers.
    public var signedData: Data { Data(parts.prefix(2).joined(separator: ".").utf8) }

    private var payloadJSON: JSONValue? { try? JSONParser.parse(payloadData) }

    public var signedDate: Date {
        let ms = payloadJSON?["signedDate"]?.numberValue?.intValue ?? payloadJSON?["receiptCreationDate"]?.numberValue?.intValue ?? 0
        return Date(storeMilliseconds: StoreMilliseconds(ms))
    }

    public var deviceVerification: Data {
        payloadJSON?["deviceVerification"]?.stringValue.flatMap { Data(base64Encoded: $0) } ?? Data()
    }

    public var deviceVerificationNonce: UUID {
        payloadJSON?["deviceVerificationNonce"]?.stringValue.flatMap(UUID.init(uuidString:)) ?? UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0))
    }
}

extension VerificationResult: Equatable where SignedType: Equatable {}
extension VerificationResult: Hashable where SignedType: Hashable {}

extension VerificationResult: CustomDebugStringConvertible {
    public var debugDescription: String {
        switch self {
        case .verified(let v): return "verified(\(v))"
        case .unverified(let v, let e): return "unverified(\(v), \(e))"
        }
    }
}
