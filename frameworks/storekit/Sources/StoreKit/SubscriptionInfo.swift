// `Product.SubscriptionInfo`, its status and renewal info (testing-session.md
// §3.2, §5; formats.md §2.3).
import Foundation
import StoreKitConfiguration
import StoreKitEngine
import StoreKitSigning

extension Product {
    /// The subscription part of an auto-renewable product.
    public struct SubscriptionInfo: Hashable, Sendable {
        public let introductoryOffer: SubscriptionOffer?
        public let promotionalOffers: [SubscriptionOffer]
        public let winBackOffers: [SubscriptionOffer]
        public let subscriptionGroupID: String
        public let subscriptionPeriod: SubscriptionPeriod
        /// The level in the group; 1 is the highest.
        public let groupLevel: Int
        /// The group's display name in the session locale (falls back to the group name).
        public let groupDisplayName: String

        /// Whether the customer may still get the introductory offer of this group.
        public var isEligibleForIntroOffer: Bool {
            get async { await SubscriptionInfo.isEligibleForIntroOffer(for: subscriptionGroupID) }
        }

        /// True until the customer has had a subscription in the group; an unknown group answers true.
        public static func isEligibleForIntroOffer(for groupID: String) async -> Bool {
            YcodeStoreKit.shared.store.isEligibleForIntroOffer(groupID: groupID)
        }

        /// The statuses of this subscription's group.
        public var status: [Status] { get async throws { try await SubscriptionInfo.status(for: subscriptionGroupID) } }

        /// One status per subscription of the group (a simulated status error answers an empty list).
        public static func status(for groupID: String) async throws -> [Status] {
            let rt = YcodeStoreKit.shared
            return Status.make(rt.store.subscriptionStatuses(groupID: groupID), runtime: rt)
        }

        /// The status of the subscription containing a transaction.
        public static func status(transactionID: UInt64) async throws -> Status? {
            let rt = YcodeStoreKit.shared
            guard let s = rt.store.subscriptionStatus(forTransaction: transactionID) else { return nil }
            return Status.make([s], runtime: rt).first
        }

        /// `Product.SubscriptionInfo.RenewalState` (raw values of testing-session.md §3.2).
        public struct RenewalState: RawRepresentable, Hashable, Sendable {
            public let rawValue: Int
            public init(rawValue: Int) { self.rawValue = rawValue }
            public static let subscribed = RenewalState(rawValue: 1)
            public static let expired = RenewalState(rawValue: 2)
            public static let inBillingRetryPeriod = RenewalState(rawValue: 3)
            public static let inGracePeriod = RenewalState(rawValue: 4)
            public static let revoked = RenewalState(rawValue: 5)

            public var localizedDescription: String {
                switch rawValue {
                case 1: return "subscribed"
                case 2: return "expired"
                case 3: return "inBillingRetryPeriod"
                case 4: return "inGracePeriod"
                case 5: return "revoked"
                default: return "unknown"
                }
            }
        }

        /// One subscription's status.
        public struct Status: Hashable, Sendable {
            public let state: RenewalState
            public let transaction: VerificationResult<Transaction>
            public let renewalInfo: VerificationResult<RenewalInfo>

            static func make(_ snapshots: [SubscriptionStatusSnapshot], runtime rt: YcodeStoreKit) -> [Status] {
                let nonce = UUID()
                let simulated = rt.store.simulatedError(for: .verification)
                let now = rt.now
                guard let transactions = try? rt.signer.sign(snapshots.map(\.transaction), at: now, nonce: nonce, simulated: simulated)
                else { return [] }
                return zip(snapshots, transactions).compactMap { s, t in
                    guard let info = try? rt.signer.sign(s.renewal, at: now, nonce: nonce, simulated: simulated) else { return nil }
                    return Status(
                        state: RenewalState(rawValue: s.state.rawValue),
                        transaction: rt.verify(t, simulated: simulated, make: Transaction.init(jws:payload:)),
                        renewalInfo: rt.verify(info, simulated: simulated, make: RenewalInfo.init(jws:payload:)))
                }
            }
        }

        /// Signed renewal information (formats.md §2.3).
        public struct RenewalInfo: Hashable, Sendable, YcodeSignedValue {
            let jws: String
            let payload: JSONValue

            public var ycodeJWS: String { jws }

            init(jws: String, payload: JSONValue) {
                self.jws = jws
                self.payload = payload
            }

            private func string(_ k: String) -> String? { payload[k]?.stringValue }
            private func int(_ k: String) -> Int? { payload[k]?.numberValue?.intValue }
            private func date(_ k: String) -> Date? { int(k).map { Date(storeMilliseconds: StoreMilliseconds($0)) } }

            public var jsonRepresentation: Data { (try? JWS.decode(jws).payloadData) ?? Data() }
            public var originalTransactionID: UInt64 { string("originalTransactionId").flatMap(UInt64.init) ?? 0 }
            public var currentProductID: String { string("productId") ?? "" }
            public var willAutoRenew: Bool { int("autoRenewStatus") == 1 }
            /// The product of the next period.
            public var autoRenewPreference: String? { string("autoRenewProductId") }
            public var expirationReason: ExpirationReason? { int("expirationIntent").map(ExpirationReason.init(rawValue:)) }
            public var isInBillingRetry: Bool { payload["isInBillingRetryPeriod"]?.boolValue ?? false }
            public var gracePeriodExpirationDate: Date? { date("gracePeriodExpiresDate") }
            public var offerID: String? { string("offerIdentifier") }
            public var offerType: Transaction.OfferType? { int("offerType").map(Transaction.OfferType.init(rawValue:)) }
            public var offerPaymentModeStringRepresentation: String? { string("offerDiscountType") }
            public var offerPeriodStringRepresentation: String? { string("offerPeriod") }
            public var environment: AppStore.Environment { AppStore.Environment(rawValue: string("environment") ?? "") }
            public var environmentStringRepresentation: String { string("environment") ?? "" }
            public var recentSubscriptionStartDate: Date { date("recentSubscriptionStartDate") ?? .distantPast }
            public var renewalDate: Date? { date("renewalDate") }
            /// `renewalPrice` / 1000.
            public var renewalPrice: Decimal? { int("renewalPrice").map { Decimal($0) / 1000 } }
            public var currencyCode: String? { string("currency") }
            public var eligibleWinBackOfferIDs: [String] { payload["eligibleWinBackOfferIds"]?.arrayValue?.compactMap(\.stringValue) ?? [] }
            public var appTransactionID: String { string("appTransactionId") ?? "" }
            public var deviceVerification: Data { string("deviceVerification").flatMap { Data(base64Encoded: $0) } ?? Data() }
            public var deviceVerificationNonce: UUID { string("deviceVerificationNonce").flatMap(UUID.init(uuidString:)) ?? UUID() }
            public var signedDate: Date { date("signedDate") ?? .distantPast }
            public var priceIncreaseStatus: PriceIncreaseStatus { .noIncreasePending }

            public static func == (a: RenewalInfo, b: RenewalInfo) -> Bool { a.jws == b.jws }
            public func hash(into h: inout Hasher) { h.combine(jws) }

            /// `RenewalInfo.ExpirationReason` (raw values as the JWS `expirationIntent`).
            public struct ExpirationReason: RawRepresentable, Hashable, Sendable {
                public let rawValue: Int
                public init(rawValue: Int) { self.rawValue = rawValue }
                public static let autoRenewDisabled = ExpirationReason(rawValue: 1)
                public static let billingError = ExpirationReason(rawValue: 2)
                public static let didNotConsentToPriceIncrease = ExpirationReason(rawValue: 3)
                public static let productUnavailable = ExpirationReason(rawValue: 4)
                public static let unknown = ExpirationReason(rawValue: 5)
            }

            public enum PriceIncreaseStatus: Hashable, Sendable {
                case noIncreasePending, pending, agreed
            }
        }
    }
}
