# StoreKit spec: errors

Part of `specs/frameworks/storekit/`. Error types an app sees from StoreKit,
with the values observed in the reference simulator's local store. Names
and raw values are interop facts from the public SDK (level 4); meanings are
in our words; "observed" rows are level 3 (StoreProbe).

## 1. StoreKit 2: `StoreKitError` (bridged domain `StoreKit.StoreKitError`)

| Case | Bridged code | Meaning | Observed in the simulator |
|---|---|---|---|
| `unknown` | 2 | unclassified failure | every failed `purchase()` in the local store (simulated purchase errors, interrupted purchase, invalid promotional signature), failed off-device purchase |
| `userCancelled` | — | the user cancelled | (a cancelled sheet normally yields `Product.PurchaseResult.userCancelled`, not an error) |
| `networkError(URLError)` | — | network failure | — (simulated network errors are converted, below) |
| `systemError(Error)` | 1 | a system or service error; the payload is an internal error value | `AppTransaction.shared` with no configuration (payload `noAccount`); simulated errors for load products, app transaction, sync (payload `unknown`) |
| `notAvailableInStorefront` | — | product not sold in the storefront | — |
| `notEntitled` | — | the app is not entitled to the API | — |
| `unsupported` | — | the API is unsupported here | — |
| `invalidPresentationContext` | — | the scene or view controller cannot present | — |

The bridged codes 1 and 2 are those reported by `NSError.code` on the
thrown value; the others were not observed (open question 1).

## 2. StoreKit 2 nested errors

| Type | Cases | Notes |
|---|---|---|
| `Product.PurchaseError` | `invalidQuantity`, `productUnavailable`, `purchaseNotAllowed`, `ineligibleForOffer`, `invalidOfferIdentifier`, `invalidOfferPrice`, `invalidOfferSignature`, `missingOfferParameters`, `paymentMethodBindingConfigurationRequired` | in the local store the four simulated ones surfaced as an alert then `StoreKitError.unknown`, not as these cases (`testing-session.md` §9) |
| `VerificationResult.VerificationError` | `revokedCertificate`, `invalidCertificateChain`, `invalidDeviceVerification`, `invalidEncoding`, `invalidSignature`, `missingRequiredProperties` | carried by `.unverified(value, error)`; observed `invalidSignature` |
| `Transaction.RefundRequestError` | `duplicateRequest`, `failed` | refund sheet failures |
| `Transaction.RefundRequestStatus` | `success`, `userCancelled` | observed `success` |
| `Product.PurchaseResult` | `success(VerificationResult<Transaction>)`, `userCancelled`, `pending` | `pending` with Ask to Buy |

Related value sets (public SDK):

| Type | Values |
|---|---|
| `Product.SubscriptionInfo.RenewalState` | raw 1 `subscribed`, 2 `expired`, 3 `inBillingRetryPeriod`, 4 `inGracePeriod`, 5 `revoked` |
| `RenewalInfo.ExpirationReason` | `autoRenewDisabled` (1), `billingError` (2), `didNotConsentToPriceIncrease` (3), `productUnavailable` (4), `unknown` (5) — raw values as in the JWS `expirationIntent` |
| `Transaction.RevocationReason` | `other` (0, observed), `developerIssue` (1) |

## 3. StoreKitTest: `SKTestErrorDomain` (`SKTestError.Code`)

| Code | Name | Meaning |
|---|---|---|
| 0 | `serviceUnavailable` | the test service cannot be reached |
| 1 | `invalidProductIdentifier` | no such product in the configuration |
| 2 | `invalidProductType` | the operation does not fit the product type |
| 3 | `invalidURL` | bad configuration URL |
| 4 | `fileNotFound` | configuration file missing |
| 5 | `noSubscriptionFound` | no subscription for the product |
| 6 | `noTransactionFound` | no transaction with the id |
| 7 | `invalidAction` | the action does not apply in the current state |

Observed instead (all failing test-session control calls in our runs):
domain `SKServiceErrorDomain`, code 2, underlying `SKInternalErrorDomain`
code 17, user-info `client-environment-type` = `Xcode`. An open StoreKit
should return the documented `SKTestErrorDomain` codes **and** keep the
observed form available for parity checks; parity tests compare the
observed form (open question 2).

## 4. StoreKit 1: `SKErrorDomain` (`SKError.Code`)

| Code | Name |
|---|---|
| 0 | `unknown` |
| 1 | `clientInvalid` |
| 2 | `paymentCancelled` |
| 3 | `paymentInvalid` |
| 4 | `paymentNotAllowed` |
| 5 | `storeProductNotAvailable` |
| 6 | `cloudServicePermissionDenied` |
| 7 | `cloudServiceNetworkConnectionFailed` |
| 8 | `cloudServiceRevoked` |
| 9 | `privacyAcknowledgementRequired` |
| 10 | `unauthorizedRequestData` |
| 11 | `invalidOfferIdentifier` |
| 12 | `invalidSignature` |
| 13 | `missingOfferParams` |
| 14 | `invalidOfferPrice` |
| 15 | `overlayCancelled` |
| 16 | `overlayInvalidConfiguration` |
| 17 | `overlayTimeout` |
| 18 | `ineligibleForOffer` |
| 19 | `unsupportedPlatform` |
| 20 | `overlayPresentedInBackgroundScene` |
| 21 | `paymentMethodBindingConfigurationRequired` (new in 26.5) |

No StoreKit 1 error occurred in our runs (open question 3: map the
simulated purchase errors onto SK1).

## 5. Open questions

1. Bridged `NSError` codes of the other `StoreKitError` cases (throw each via
   a simulated `generic(...)` error on an API that does not convert it).
2. Whether any test-session call returns `SKTestErrorDomain` codes.
3. StoreKit 1 transaction errors under simulated purchase failures.

## Evidence

Names, cases and raw values: level 4 (public SDK headers and Swift
interface, as metadata). Bridged codes and observed mappings: level 3.
