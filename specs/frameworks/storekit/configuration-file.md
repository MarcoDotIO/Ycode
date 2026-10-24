# StoreKit spec: the `.storekit` configuration file

Part of `specs/frameworks/storekit/`. A StoreKit configuration file describes a
local, made-up App Store catalog for one app: its in-app products,
subscription groups and offers, and the settings of the local test store
(storefront, locale, time rate, simulated failures). Xcode edits it, a scheme
names it, `SKTestSession` loads it, and the simulator's store daemon serves
products and transactions from it. Ycode's IDE must read and write it
byte-compatibly enough that Xcode opens Ycode's files and the other way
round; Ycode's simulator must accept it as its catalog.

Our probe configuration (`research/experiments/storekit/StoreProbe/YcodeProbe.storekit`,
our own data) exercises every entity listed here and loads in the reference
simulator. Statements are level 2 (the file as a format, the copy the daemon
writes back) and level 3 (what the daemon does with each key) unless marked.

## 1. File identity

| Property | Value |
|---|---|
| Extension | `.storekit` |
| Plain-file UTI | `com.apple.dt.storekit`, conforms to `com.apple.xcode.configsettings` (Xcode plug-in registration, level 4) |
| Package UTI | `com.apple.dt.storekitbundle`, conforms to `com.apple.package`; the same extension is also detected as a package (a directory named `*.storekit`). Content of the package form not observed (open question 1) |
| Display name of the type | "StoreKit Configuration" |
| Encoding | UTF-8 JSON, a single top-level object |
| Text form | Foundation-style pretty printing as seen in published configuration files: two-space indent, `"key" : value` with a space on both sides of the colon, keys sorted alphabetically, an empty array written as `[`, a blank line, `]`. Whether Xcode 27.1 still writes exactly this form is open question 2. Xcode registers a "text conversion provider" for both UTIs, so the file can also be opened as source text |
| In the target | Usually a member of the app target's resources. A file inside a folder-synchronized group is copied into the built `.app` like any resource (observed with `xcodebuild`); the app's own `SKTestSession(configurationFileNamed:)` needs it in the main bundle, the scheme path does not |

Key order is irrelevant to readers: the daemon re-serializes the file with a
different order and both forms load. Ycode writes the sorted form so that
files diff cleanly against Xcode's.

## 2. Top level

| Key | Type | Meaning |
|---|---|---|
| `identifier` | string, 8 uppercase hex digits | identifies this configuration file (our file: `5C0DE001`) |
| `version` | object `{ "major" : int, "minor" : int }` | format version. Files with `4.0` load on Xcode 27.1 / iOS 27.1. Which version Xcode 27.1 writes for a new file is open question 2 |
| `products` | array of product objects (§3) | consumables and non-consumables |
| `nonRenewingSubscriptions` | array of product objects (§3) | non-renewing subscriptions |
| `subscriptionGroups` | array of group objects (§4) | auto-renewable subscriptions, by group |
| `settings` | object (§6) | test-store settings |
| `appPolicies` | object (§7) | EULA and policy texts |
| `appName` | string | **added by the daemon** to its private copy (§8); absent from editor files we have seen |

Keys of a file synchronized with App Store Connect (level 4, names only, not
yet observed in a file): `_applicationInternalID`, `_developerTeamID`,
`_lastSynchronizedDate`. A synchronized configuration is read-only in the
editor and is refreshed from the developer's App Store Connect account; Ycode
does not support synchronization (it needs an Apple account) but must
preserve these keys when it edits such a file.

## 3. Product object (in `products` and `nonRenewingSubscriptions`)

| Key | Type | Meaning | Daemon behavior |
|---|---|---|---|
| `type` | string | `Consumable`, `NonConsumable` (in `products`), `NonRenewingSubscription` (in `nonRenewingSubscriptions`) | `Product.type` is `Consumable`, `Non-Consumable`, `Non-Renewing Subscription` |
| `productID` | string | the product identifier the app requests | `Product.id` |
| `referenceName` | string | developer-facing name (editor list) | not visible to the app |
| `internalID` | string of digits | stable numeric item identifier (our file: 9 digits) | becomes the `id` of the product's JSON representation (`formats.md` §1) |
| `displayPrice` | string, decimal with `.` | the price, in whatever the storefront's currency is | `Product.price` = this decimal, never converted: storefront USA → `$0.99`, storefront DEU with locale `de` → `0,99 €` (currency EUR, price locale `de@currency=EUR`); JWS `price` = value × 1000 as an integer (`formats.md` §2) |
| `familyShareable` | bool | Family Sharing enabled | `Product.isFamilyShareable` |
| `localizations` | array of `{ "locale", "displayName", "description" }` | per-locale texts; `locale` is a locale identifier (`en_US`, `de`) | name and description in the session locale: with locale `en_US` the `en_US` entry, with locale `de` the `de` entry. A product **without** an entry for the session locale shows its `referenceName` as display name and an empty description (the product JSON then has no `description` key); it does not fall back to `en_US` |

## 4. Subscription group object (in `subscriptionGroups`)

| Key | Type | Meaning |
|---|---|---|
| `id` | string of digits | the subscription group identifier (`Product.SubscriptionInfo.subscriptionGroupID`, JWS `subscriptionGroupIdentifier`) |
| `name` | string | developer name; used as the group display name when the group has no localization for the session locale (observed: group "Extra" without localizations → "Extra"; group "Plus" with only an `en_US` localization → "Plus" under locale `de`) |
| `localizations` | array of `{ "locale", "displayName", "description" }` | group display name per locale (`groupDisplayName` "Ycode Plus") |
| `subscriptions` | array of subscription objects (§5) | the group's products |

## 5. Auto-renewable subscription object

All keys of §3 except `type`'s value, plus:

| Key | Type | Meaning | Observed |
|---|---|---|---|
| `type` | string | `RecurringSubscription` | `Product.type` "Auto-Renewable Subscription" |
| `subscriptionGroupID` | string | id of the containing group (redundant with the nesting) | |
| `groupNumber` | int ≥ 1 | the level in the group; 1 is the highest service level | `groupLevel`; JSON `subscriptionFamilyRank` |
| `recurringSubscriptionPeriod` | ISO 8601 duration | renewal period: `P1W`, `P1M`, `P1Y` observed; the editor's choices also include 3 days? (open question 4), 1, 2, 3, 6 months | `subscriptionPeriod` (value, unit) |
| `introductoryOffer` | offer object or absent | introductory offer (§5.1) without `offerID` | `subscription.introductoryOffer`, type `IntroOffer`, `id` nil |
| `adHocOffers` | array of offer objects | promotional offers; each has an `offerID` | `promotionalOffers` (type `AdhocOffer` in JSON) |
| `codeOffers` | array of code-offer objects | offer codes (§5.2) | not listed on the product; shown in the redeem sheet (`simulator-baseline.md` §6) |
| `winbackOffers` | array | win-back offers; structure not observed (open question 5) | `winBackOffers` empty |

### 5.1 Offer object

| Key | Type | Meaning |
|---|---|---|
| `internalID` | string of digits | offer's item id |
| `offerID` | string | promotional offers only: the offer identifier the app passes when purchasing |
| `referenceName` | string | developer name (promotional and code offers) |
| `paymentMode` | string | `free` (free trial), `payAsYouGo` (discounted price per period), `payUpFront` (one discounted price for the whole offer duration) |
| `subscriptionPeriod` | ISO 8601 duration | the length of one offer period |
| `numberOfPeriods` | int ≥ 1 | how many periods the offer lasts (for `payUpFront` 1 with the full duration in `subscriptionPeriod`) |
| `displayPrice` | decimal string | the offer price (absent or `"0"` for `free`) |

Mapping to the product API (observed): `free` → payment mode `FreeTrial`
(transaction offer mode `FREE_TRIAL`); `payAsYouGo` → `PayAsYouGo`; `payUpFront`
→ `PayUpFront` (`PAY_UP_FRONT`). Offer `price` 0 for a free trial with
`displayPrice` "$0.00".

### 5.2 Code-offer object

The offer keys of §5.1 (without `offerID`; `referenceName` is the code the
redeem sheet lists and the app passes as `codeOffer(referenceName:)`), plus:

| Key | Type | Meaning |
|---|---|---|
| `eligibility` | array of strings | who may redeem: any of `new`, `existing`, `expired` |
| `isStackable` | bool | whether the code offer may stack on an introductory offer |

## 6. `settings`

Every key starts with an underscore. The values are the defaults the store
applies when the configuration is loaded (observed: a file with storefront
`DEU`, locale `de`, time rate 1004 and every toggle on gave a session with
exactly those property values, and loading the default file again gave the
defaults back). A property that was once **set through the API** is stored
as a per-app override and wins over the file from then on — even across a
configuration switch, an uninstall and a reinstall (observed for
`disableDialogs`), presumably until `resetToDefaultState()` clears it. The
editor's Editor-menu toggles edit these file keys; the overrides are kept per
app by the daemon (`simulator-baseline.md` §5).

| Key | Type | Meaning | SKTestSession property |
|---|---|---|---|
| `_storefront` | string, ISO 3166-1 alpha-3 country (`USA`) | default storefront; the daemon maps it to the numeric storefront id (`USA` → `143441`) and currency (`USD`) | `storefront` |
| `_locale` | locale identifier (`en_US`) | default locale for product texts and price formatting (`en_US@currency=USD`) | `locale` |
| `_timeRate` | int | subscription time rate as a raw `SKTestSession.TimeRate` value (`testing-session.md` §2); 0 = real time | `timeRate` |
| `_askToBuyEnabled` | bool | purchases need parental approval | `askToBuyEnabled` |
| `_billingIssuesEnabled` | bool | purchases are interrupted by a billing issue | `interruptedPurchasesEnabled` |
| `_renewalBillingIssuesEnabled` | bool | renewals fail and enter billing retry | `shouldEnterBillingRetryOnRenewal` |
| `_billingGracePeriodEnabled` | bool | billing retry starts with a grace period | `billingGracePeriodIsEnabled` |
| `_disableDialogs` | bool | purchases complete without the system purchase sheet | `disableDialogs` |
| `_failTransactionsEnabled` | bool | legacy "fail transactions" switch | `failTransactionsEnabled` (deprecated) |
| `_storeKitErrors` | array | the editor's "StoreKit Errors" table: per-API simulated errors; empty when none. Element structure not observed (open question 6) | `setSimulatedError(_:forAPI:)` |

Level-4 names that may appear in newer files (unconfirmed):
`_compatibilityTimeRate` (a time rate in the pre-15.2 "x is one day" units),
`_billingGracePeriodIsEnabled`, `_subscriptionOffersKeyPair` (the key id and
private key used to sign promotional offers locally; never copy a real key
into a test file), `_partnerReferralCodes`.

## 7. `appPolicies`

| Key | Type | Meaning |
|---|---|---|
| `eula` | string | custom license agreement text; empty means the standard one |
| `policies` | array of `{ "locale", "policyText", "policyURL" }` | privacy policy per locale |

Purpose (level 1): the subscription store views show these links.

## 8. What the daemon does with the file

1. On `SKTestSession(configurationFileNamed:)` (name without extension, looked
   up in the main bundle) or `SKTestSession(contentsOf:)`, the framework
   sends the file's data to the store daemon for the app's bundle identifier.
   The daemon writes its own copy to
   `<group.com.apple.storekit container>/Documents/Persistence/Octane/<bundle id>/Configuration.storekit`,
   re-serialized (different key order, keys preserved, `appName` added)
   (level 2 + 3).
2. From then on the configuration belongs to the app, not to the process:
   later launches **without** an `SKTestSession` still get the configured
   products and the earlier transactions (observed: relaunch with no session
   returned all 7 products and 2 entitlements). A second app with another
   bundle identifier sees nothing (0 products).
3. Uninstalling the app deletes its configuration copy and its transactions;
   the device-wide signing certificate (`simulator-baseline.md` §5) stays.
4. Unknown product identifiers are silently omitted from product requests;
   an empty request returns an empty list.

## 9. How a scheme attaches the file

The Run action of a scheme names the file; see `ide.md` §2 for the XML.
Xcode then installs the configuration for the app's bundle identifier before
launching it, in place of the `SKTestSession` call (open question 7 for the
exact mechanism).

## 10. Open questions

1. Content of the package (`.storekit` directory) form.
2. The `version` Xcode 27.1 writes for a new file, and what older/newer
   versions mean (needs an editor-created file; GUI pass).
3. (answered: `referenceName` fallback, §3)
4. The complete list of periods offered by the editor.
5. `winbackOffers` element keys.
6. `_storeKitErrors` element keys.
7. Whether Xcode transfers the file's data or a path.

## Evidence

- §1 UTIs, conformance, type names, text conversion provider: level 4
  (Xcode plug-in registration data, as metadata). Pretty-print style and
  bundle copying: level 2/3 (our file, the daemon copy, an `xcodebuild` build).
- §2–§7 keys and value forms: level 2 (our configuration file that loads in
  the reference, and the daemon's copy); mappings to API values: level 3
  (StoreProbe `products`, `sub`, `offers` phases, and `products` with our
  `YcodeProbeSettings.storekit`). Synchronized-file keys and
  §6 "unconfirmed" names: level 4 (binary metadata, names only). Purpose of
  `appPolicies`: level 1.
- §8: level 2 (file locations) and level 3 (probe launches with and without a
  session, second bundle, uninstall).
- §9: see `ide.md`.
