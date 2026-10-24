// `Product.PurchaseOption` (testing-session.md §4 "Purchase options").
import Foundation
import StoreKitEngine

extension Product {
    /// An option of `purchase(options:)`.
    public struct PurchaseOption: Hashable, Sendable, CustomDebugStringConvertible {
        @_spi(Ycode) public enum Kind: Hashable, Sendable {
            case appAccountToken(UUID)
            case quantity(Int)
            case custom(String, String)
            case signedPromotionalOffer(offerID: String, keyID: String, nonce: UUID, signature: Data, timestamp: Int)
            case simulatesAskToBuyInSandbox(Bool)
            // StoreKitTest options (testing-session.md §4).
            case unsignedPromotionalOffer(String)
            case codeOffer(String)
            case purchaseDate(Date, BackdatedRenewalBehavior)
        }

        @_spi(Ycode) public let kind: Kind

        @_spi(Ycode) public init(kind: Kind) { self.kind = kind }

        public static func appAccountToken(_ token: UUID) -> PurchaseOption { .init(kind: .appAccountToken(token)) }
        public static func quantity(_ quantity: Int) -> PurchaseOption { .init(kind: .quantity(quantity)) }
        public static func custom(key: String, value: String) -> PurchaseOption { .init(kind: .custom(key, value)) }
        public static func custom(key: String, value: Double) -> PurchaseOption { .init(kind: .custom(key, String(value))) }
        public static func custom(key: String, value: Bool) -> PurchaseOption { .init(kind: .custom(key, String(value))) }
        public static func custom(key: String, value: Data) -> PurchaseOption { .init(kind: .custom(key, value.base64EncodedString())) }
        public static func custom(key: String, value: UUID) -> PurchaseOption { .init(kind: .custom(key, value.uuidString)) }
        public static func simulatesAskToBuyInSandbox(_ value: Bool) -> PurchaseOption { .init(kind: .simulatesAskToBuyInSandbox(value)) }

        public static func promotionalOffer(offerID: String, keyID: String, nonce: UUID, signature: Data, timestamp: Int) -> PurchaseOption {
            .init(kind: .signedPromotionalOffer(offerID: offerID, keyID: keyID, nonce: nonce, signature: signature, timestamp: timestamp))
        }

        public static func promotionalOffer(offerID: String, signature: SubscriptionOffer.Signature) -> PurchaseOption {
            promotionalOffer(offerID: offerID, keyID: signature.keyID, nonce: signature.nonce, signature: signature.signature,
                             timestamp: signature.timestamp)
        }

        public var debugDescription: String { "\(kind)" }

        /// The engine's options for a set of purchase options.
        static func engineOptions(_ options: Set<PurchaseOption>) -> PurchaseOptions {
            var o = PurchaseOptions()
            for option in options {
                switch option.kind {
                case .appAccountToken(let t): o.appAccountToken = t
                case .quantity(let q): o.quantity = q
                case .custom(let k, let v): o.custom[k] = v
                case .signedPromotionalOffer(let id, let key, let nonce, let sig, let ts):
                    o.signedPromotionalOffer = SignedPromotionalOffer(offerID: id, keyID: key, nonce: nonce, signature: sig, timestamp: Int64(ts))
                case .simulatesAskToBuyInSandbox: break  // sandbox only
                case .unsignedPromotionalOffer(let id): o.promotionalOfferID = id
                case .codeOffer(let code): o.codeOfferReferenceName = code
                case .purchaseDate(let date, let behavior):
                    o.purchaseDate = date
                    o.renewalBehavior = behavior
                }
            }
            return o
        }
    }
}
