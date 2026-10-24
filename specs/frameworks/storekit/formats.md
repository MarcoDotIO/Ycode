# StoreKit spec: wire and file formats the app sees

Part of `specs/frameworks/storekit/`. These are the data formats an app (and
its server) receives from StoreKit in the local test store: the product's
JSON representation, signed transactions and renewal information (JWS),
the signed app transaction, and the StoreKit 1 receipt. Values are from the
reference simulator (level 3, StoreProbe) unless marked. Field names are
interop facts; many also appear in Apple's public App Store Server
documentation (level 1).

## 1. Product JSON representation (`Product.jsonRepresentation`)

The product is the App Store's catalog resource. For a configuration-file
product the daemon synthesizes:

| Path | Value |
|---|---|
| `id` | the product's `internalID` from the configuration (string) |
| `type` | `"in-apps"` |
| `attributes.kind` | `Consumable`, `Non-Consumable`, `Non-Renewing Subscription`, `Auto-Renewable Subscription` |
| `attributes.offerName` | the product identifier |
| `attributes.name` | localized display name |
| `attributes.description.standard` | localized description |
| `attributes.icuLocale` | e.g. `en_US@currency=USD` |
| `attributes.isFamilyShareable` | 0 or 1 (number) |
| `attributes.offers[0]` | the purchase offer: `currencyCode`, `priceFormatted` (`$0.99`), `priceString` (`0.99`); for subscriptions also `type` `"buy"`, `billingPeriod` and `recurringSubscriptionPeriod` (ISO 8601, both the subscription period), `billingPlanType` `BILLED_UPFRONT`, and `discounts` |
| `…discounts[]` | one per introductory and promotional offer: `type` (`IntroOffer` or `AdhocOffer`), `modeType` (`FreeTrial`, `PayAsYouGo`, `PayUpFront`), `numOfPeriods`, `recurringSubscriptionPeriod` (the offer period), `priceFormatted`, `priceString` (`0.00` for a free trial), `billingPlanType`, and `offerId` for promotional offers |
| `attributes.subscriptionFamilyId` | group id |
| `attributes.subscriptionFamilyName` | group display name |
| `attributes.subscriptionFamilyRank` | the level (`groupNumber`) |

Key order in `jsonRepresentation` is the daemon's (sorted in the debug
description). Code offers and win-back offers are not part of it.

## 2. Signed transactions (JWS)

Every `VerificationResult` carries a compact JWS (`jwsRepresentation`):
`base64url(header).base64url(payload).base64url(signature)`.

### 2.1 Header and signature

| Field | Value |
|---|---|
| `alg` | `ES256` (ECDSA P-256 with SHA-256; the signature is the 64-byte raw r‖s form) |
| `kid` | `Apple_Xcode_Key` |
| `typ` | `JWT` |
| `x5c` | an array with **one** certificate (DER, base64): self-signed, subject and issuer `CN=StoreKit Testing in Xcode, O=StoreKit Testing in Xcode`, P-256 key, ECDSA-SHA256 signature, valid one year from the moment it was created; basic-constraints (critical), subject-alternative-name and key-usage (critical) extensions |

The certificate and its key are generated **per simulator device** the first
time StoreKit Testing is used there and are kept in the store's group
container (`simulator-baseline.md` §5): all apps on that device share it; a
new device gets a new one. A signature verifies against the leaf
certificate's public key with any standard verifier (checked with
`research/experiments/storekit/jws_check.py`, our own script using OpenSSL).
`VerificationResult` reports such a transaction as verified in the
simulator; the chain does not lead to Apple's root, so a server that checks
the chain must special-case the Xcode environment (level 1: Apple documents
that Xcode-signed transactions do not chain to its root).

Ycode can therefore generate its own key pair and certificate with the same
subject and serve fully verifiable transactions; no Apple key material is
needed.

### 2.2 Transaction payload (`Transaction`)

Keys observed (all numeric dates are milliseconds since 1970 as integers):

| Key | Type | Value in the local store |
|---|---|---|
| `transactionId` | string | decimal counter value (`testing-session.md` §10) |
| `originalTransactionId` | string | the original purchase's id |
| `webOrderLineItemId` | string | equals `transactionId` |
| `bundleId` | string | app bundle identifier |
| `productId` | string | product identifier |
| `subscriptionGroupIdentifier` | string | subscriptions only |
| `purchaseDate`, `originalPurchaseDate` | int ms | |
| `expiresDate` | int ms | subscriptions only |
| `signedDate` | int ms | time of signing (a re-delivered transaction has a new one) |
| `quantity` | int | |
| `type` | string | `Consumable`, `Non-Consumable`, `Non-Renewing Subscription`, `Auto-Renewable Subscription` |
| `inAppOwnershipType` | string | `PURCHASED` (`FAMILY_SHARED` exists, level 1) |
| `transactionReason` | string | `PURCHASE` or `RENEWAL` |
| `environment` | string | `Xcode` |
| `storefront`, `storefrontId` | string | `USA`, `143441` |
| `currency` | string | `USD` |
| `price` | int | price × 1000 (0.99 → 990; a free trial 0) |
| `appTransactionId` | string | `"0"` |
| `appAccountToken` | string | lower-case UUID, only when the purchase passed one |
| `offerType` | int | 1 introductory, 2 promotional, 3 offer code, 4 win-back (level 1 for 2 and 4); only when an offer applied |
| `offerDiscountType` | string | `FREE_TRIAL`, `PAY_AS_YOU_GO`, `PAY_UP_FRONT` |
| `offerPeriod` | ISO 8601 | the offer's duration (one period for a trial, the whole duration for pay-up-front: `P1M`) |
| `offerIdentifier` | string | promotional offer id or offer-code reference name (level 1; observed in renewal info) |
| `billingPlanType` | string | `BILLED_UPFRONT` (subscriptions) |
| `storeType` | string | `CONSUMER` |
| `deviceVerification` | string | base64 of 48 bytes (a SHA-384 digest) |
| `deviceVerificationNonce` | string | lower-case UUID, new per signing |
| `revocationDate`, `revocationReason` | int ms, int | after a refund: the refund time, reason 0 |
| `revocationType` | string | `REFUND_FULL` after a test-session refund |
| `revocationPercentage` | int | 100000 (100 %, in thousandths of a percent) after a full refund |
| `isUpgraded` | bool | when a higher level replaced it (level 1; observed through the API) |

`deviceVerification` = base64 of SHA-384 over the UTF-8 bytes of the
**nonce string in lower case followed by the vendor identifier
(`identifierForVendor`, `AppStore.deviceVerificationID`) string in lower
case**, both in the 8-4-4-4-12 hyphenated form (level 3: recomputed in the
app for an app transaction; the other five concatenations we tried did not
match). Several JWS signed in one batch (for example two refunded
transactions read together) share one nonce, `deviceVerification` and
`signedDate`.

### 2.3 Renewal info payload (`Product.SubscriptionInfo.RenewalInfo`)

| Key | Value |
|---|---|
| `originalTransactionId`, `productId` | the subscription |
| `autoRenewProductId` | product of the next period (changes on crossgrade or downgrade) |
| `autoRenewStatus` | 1 on, 0 off |
| `renewalDate` | int ms, the current expiration |
| `renewalPrice` | int, milli-units; 0 when a code offer applies to the next period |
| `renewalBillingPlanType` | `BILLED_UPFRONT` (absent once auto-renew is off) |
| `recentSubscriptionStartDate` | int ms, start of the current uninterrupted run |
| `isInBillingRetryPeriod` | bool |
| `gracePeriodExpiresDate` | int ms, while in a billing grace period |
| `expirationIntent` | 1 customer cancelled, 2 billing error (3 price increase declined, 4 product unavailable, 5 other: level 1) |
| `offerType`, `offerIdentifier`, `offerDiscountType`, `offerPeriod` | a pending offer for the next period |
| `eligibleWinBackOfferIds` | array (empty) |
| `currency`, `environment`, `appTransactionId`, `signedDate`, `deviceVerification`, `deviceVerificationNonce` | as in §2.2 |

### 2.4 App transaction payload (`AppTransaction`)

| Key | Value |
|---|---|
| `receiptType` | `Xcode` |
| `bundleId` | app bundle identifier |
| `applicationVersion`, `originalApplicationVersion` | the app's `CFBundleVersion` (`12`) |
| `originalPlatform` | `iOS` |
| `originalPurchaseDate` | 0 |
| `receiptCreationDate`, `requestDate` | int ms, now |
| `appTransactionId` | `"0"` |
| `deviceVerification`, `deviceVerificationNonce` | as in §2.2 |

Without an installed configuration `AppTransaction.shared` fails with
`systemError(noAccount)` (`errors.md`).

## 3. StoreKit 1 receipt (`Bundle.appStoreReceiptURL`)

Path: `<app data container>/StoreKit/receipt`. It is created when the app
uses the StoreKit 1 payment queue or a receipt refresh request in the local
store (absent after StoreKit 2-only purchases).

Container: a PKCS#7 / CMS `SignedData` (DER) with the payload embedded,
signed by a fixed self-signed certificate (`CN=StoreKit, O=StoreKit,
OU=StoreKit, C=US`, valid 2020-04-01 to 2040-03-27). This is the same
certificate that Xcode's StoreKit editor exports as its public test
certificate (identical SHA-256 fingerprint), so a developer can validate the
receipt locally. Unlike the JWS key it is fixed, not generated per device
(inference: the runtime's test-store support framework carries a signing
identity file; level 2, name only). Ycode's own store signs with its own certificate and its
IDE exports that one.

Payload: the documented receipt ASN.1 (level 1): a SET of SEQUENCE
{ type INTEGER, version INTEGER, value OCTET STRING } where each value is DER
inside the octet string. Attributes present (version 1 each):

| Type | Content in the local store |
|---|---|
| 0 | UTF8String `Xcode` (receipt type) |
| 1 | INTEGER 0 |
| 2 | UTF8String bundle id |
| 3 | UTF8String app version (`12`) |
| 4 | 8 opaque bytes |
| 5 | 20 bytes (SHA-1 hash) |
| 8 | IA5String, empty |
| 12 | IA5String creation date, RFC 3339 `YYYY-MM-DDTHH:MM:SSZ` |
| 17 | one per in-app purchase in the receipt (below) |
| 21 | IA5String expiration date `4001-01-01T00:00:00Z` |

In-app purchase entry (a SET of the same SEQUENCE form): 1701 quantity
(INTEGER), 1702 product id (UTF8String), 1703 transaction id (UTF8String),
1704 purchase date (IA5String), 1708 expiration date (subscriptions), 1719
"in introductory offer period" (INTEGER 1). Finished consumables are not
listed; the observed receipt listed the non-consumable and the subscription
bought through the payment queue.

## Open questions

1. Partial refunds (`revocationType` other than full) in the local store.
2. Receipt attributes 4, 5 and 8 meaning in the Xcode environment and
   whether 19 (original application version) is ever present.

## Evidence

- §1, §2.1–§2.4 observed values, refund fields and the
  `deviceVerification` recomputation: level 3 (decoded payloads and headers from
  StoreProbe; our verifier). Meanings of offer types 2/4, expiration intents
  3–5, the upgrade key: level 1
  (public App Store Server and StoreKit documentation, in our words).
- §3: level 2 (the receipt file as a format: CMS structure, certificate
  fingerprint compared with the certificate in Xcode's editor bundle as a
  file) and level 1 (attribute numbering of the documented receipt format).
