// Signed promotional offers: the signature a developer's server makes for
// `promotionalOffer(offerID:keyID:nonce:signature:timestamp:)`, as publicly
// documented (level 1): ECDSA P-256 with SHA-256 over the UTF-8 text
// `bundleID ⁣ keyID ⁣ productID ⁣ offerID ⁣ appAccountToken ⁣ nonce ⁣ timestamp`
// joined with U+2063, with the token and nonce in lower case (the token
// empty when absent); DER signature.
//
// The configuration's own key (`_subscriptionOffersKeyPair`) has an
// unobserved format (testing-session.md §12 q5), so Ycode takes the public
// keys from its caller.
import Crypto
import Foundation
import StoreKitEngine

public enum PromotionalOfferSignature {
    public static func message(_ offer: SignedPromotionalOffer, context: PromotionalOfferContext) -> Data {
        let parts = [
            context.bundleID, offer.keyID, context.productID, offer.offerID,
            context.appAccountToken?.uuidString.lowercased() ?? "", offer.nonce.uuidString.lowercased(), String(offer.timestamp),
        ]
        return Data(parts.joined(separator: "\u{2063}").utf8)
    }

    /// Signs an offer (what the developer's server does; for tests and local tools).
    public static func sign(
        offerID: String, keyID: String, nonce: UUID, timestamp: Int64, context: PromotionalOfferContext, key: P256.Signing.PrivateKey
    ) throws -> SignedPromotionalOffer {
        var offer = SignedPromotionalOffer(offerID: offerID, keyID: keyID, nonce: nonce, signature: Data(), timestamp: timestamp)
        offer.signature = try key.signature(for: message(offer, context: context)).derRepresentation
        return offer
    }

    /// A verifier for `StoreDevice.promotionalOfferVerifier` accepting offers signed by one of `keys` (key id → public key).
    public static func verifier(keys: [String: P256.Signing.PublicKey]) -> PromotionalOfferVerifier {
        let keyData = keys.mapValues { $0.derRepresentation }
        return { offer, context in
            guard let der = keyData[offer.keyID], let key = try? P256.Signing.PublicKey(derRepresentation: der),
                  let sig = try? P256.Signing.ECDSASignature(derRepresentation: offer.signature) else { return false }
            return key.isValidSignature(sig, for: message(offer, context: context))
        }
    }
}
