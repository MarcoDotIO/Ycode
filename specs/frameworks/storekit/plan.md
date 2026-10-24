# StoreKit spec: implementation rounds and conformance tests

Part of `specs/frameworks/storekit/`. This plan is Ycode's own. Each round is
sized for one agent. Clean-room agents read only `specs/`, public
documentation and permissively licensed open source. They must not open the
reference tools (the Xcode copy, Ghidra, the IPSW), `research/dirty/` or
Ghidra projects, and they must not run, boot or observe Apple's Xcode or
Apple's Simulator (simctl devices included) themselves; booting Ycode's own
simulator is fine. Questions about Apple behavior the specs lack go back to
a dirty-side agent.

## 1. Targets

1. **Simulator parity**: StoreKit apps in a Ycode guest running Apple's
   runtime behave as in `simulator-baseline.md` (design §2).
2. **IDE parity**: Ycode's IDE edits `.storekit` files and installs them on
   Run like Xcode (design §3, `ide.md` §6).
3. **Open StoreKit** (opt-in): Ycode's own engine and frameworks with the
   same observable behavior (design §4).

## 2. Rounds

| Round | Owner | Scope | Done when |
|---|---|---|---|
| R0 | KIT-STOREKIT (this) | specification and probes | this directory reviewed and merged |
| R1 | simulator track | **Guest services**: dependencies G1–G12 of `design.md` §2 (daemon and UI service jobs, the `group.com.apple.storekit` container, registration events, peer bundle-id identity, clock while suspended, fast network failure); build StoreProbe with Ycode's toolchain or reuse the reference build; run phases `env`, `products`, `buy`, `relaunch`, `sub`, `refund`, `ask`, `fail`, `offers`, `sk1` with an `SKTestSession` | checklist rows E1–K1 of `simulator-baseline.md` §8 match (ids relative, dates relative, signatures verify) |
| R2 | clean room (IDE) | **Configuration file model**: parser/writer per `configuration-file.md`, unknown-key preservation, sorted pretty printing, validation (ids unique, group levels, periods, offers), the template | C-FILE passes; Xcode-written sample files (provided as test corpus paths) round-trip byte-exactly |
| R3 | clean room (IDE) + simulator track | **Scheme option and install-on-Run**: Run ▸ Options pop-up, `StoreKitConfigurationFileReference` read/write with the path rule of `ide.md` §2.1, and installation into the guest before launch via the injected-session route of `design.md` §3 I1 | C-SCHEME passes; StoreProbe launched by Ycode's Run with `-session 0` gets the 7 products (row U4 analogue) |
| R4 | clean room (IDE) | **Configuration editor** (`ide.md` §3) with Ycode's own UI | C-EDITOR: every key of `configuration-file.md` editable; files open in Xcode (checked by a dirty-side agent) |
| R5 | clean room (IDE) + simulator track | **Transaction Manager and Debug ▸ StoreKit** (`ide.md` §4): list, refund, delete, approve/decline, resolve, expire/renew, price-increase request; Ycode CLI equivalents | C-TXMGR passes against the guest's store |
| R6 | simulator track | **System sheets**: purchase confirmation, alerts, refund, redeem, manage subscriptions render and accept taps in the guest (Apple's `StoreKitUISceneService`) | rows G1–G4 match; screenshots show "[Environment: Xcode]" |
| R7 | clean room | **Open store engine**: catalog, per-app store, id counter, purchase rules of `testing-session.md` §4, subscription scheduler §3, offers §5, Ask to Buy §6, refunds §7, issues §8, simulated errors §9, persistence | C-ENGINE passes on Linux with the golden values below |
| R8 | clean room | **Signing and formats**: per-device P-256 identity, JWS builders and verifier, product JSON, app transaction, StoreKit 1 receipt (CMS) | C-FORMATS passes; JWS verify with OpenSSL |
| R9 | clean room | **Open client frameworks**: StoreKit 2 API, StoreKit 1 API, StoreKitTest API over the engine; Ycode's own sheets | C-API: StoreProbe built against Ycode's frameworks prints the same report as against Apple's (normalized) |
| R10 | simulator track + clean room | **Drop-in switch** in the guest (opt-in), with Apple's stack as the default | the whole suite passes with both stacks |

## 3. Golden values (measured on the reference, level 3)

### 3.1 Catalog (`YcodeProbe.storekit`, storefront USA, locale `en_US`)

| Product | Type | Name | Price / display | Family | Subscription |
|---|---|---|---|---|---|
| `dev.ycode.skprobe.coins100` | Consumable | 100 Probe Coins | 0.99 / $0.99 | no | — |
| `dev.ycode.skprobe.pro` | Non-Consumable | Probe Pro | 4.99 / $4.99 | yes | — |
| `dev.ycode.skprobe.season` | Non-Renewing Subscription | Probe Season Pass | 2.99 / $2.99 | no | — |
| `dev.ycode.skprobe.plus.monthly` | Auto-Renewable | Plus Monthly | 3.99 / $3.99 | no | group 200000001 "Ycode Plus", level 1, 1 month; intro free 1 week ×1; promo `plus.promo3` pay-as-you-go 1.99 × 3 months |
| `dev.ycode.skprobe.plus.yearly` | Auto-Renewable | Plus Yearly | 29.99 / $29.99 | no | same group, level 1, 1 year, no offers |
| `dev.ycode.skprobe.plus.lite` | Auto-Renewable | Plus Lite | 1.99 / $1.99 | no | same group, level 2, 1 month; intro pay-as-you-go 0.99 × 2 months |
| `dev.ycode.skprobe.extra.weekly` | Auto-Renewable | Extra Weekly | 0.49 / $0.49 | yes | group 200000002 "Extra" (no localization), level 1, 1 week; intro pay-up-front 0.99 for 1 month |

Product JSON ids: 100000001, 100000002, 100000004, 100000011, 100000012,
100000013, 100000021. Price locale `en_US@currency=USD`. StoreKit 1 period
units: week 1, month 2, year 3; intro payment modes pay-as-you-go 0,
pay-up-front 1, free 2.

### 3.2 Behavior

| Test | Expected |
|---|---|
| no configuration | 0 products; AppTransaction `systemError(noAccount)` |
| first purchase ids | 0, 1, 2… per app; never reused |
| buy coins (unfinished) then coins ×3 | returns the unfinished transaction again (same id, quantity 1) |
| buy pro twice | same transaction |
| price fields | JWS `price` 990 / 4990 / 2990 / 3990; trial 0; pay-up-front intro 990 |
| monthly at rate 1004 | expires +10000 ms; renewals at +10 s each with reason RENEWAL, price 3990, purchase date = previous expiry |
| monthly at real time from 2026-10-19 | expires +604800 s (trial week) |
| one month at real time across the DST end | +2682000 s; within September +2592000 s |
| crossgrade / downgrade in group | current transaction returned; `autoRenewProductId` updated |
| auto-renew off then expiry | status 2, `expirationIntent` 1 |
| billing retry on renewal | status 2, `expirationIntent` 2 (retry window under 1004 shorter than 40 s) |
| refund | revocation reason 0; status 5; entitlement removed |
| Ask to Buy | `.pending`; state 4; approve → state 1 |
| simulated purchase errors | alert + `StoreKitError.unknown` (code 2) |
| simulated invalid signature | `.unverified(invalidSignature)`; signature fails OpenSSL verification |
| JWS header | ES256, kid `Apple_Xcode_Key`, one self-signed P-256 certificate "StoreKit Testing in Xcode", one-year validity |
| `deviceVerification` | base64(SHA-384(lowercase(nonce) + lowercase(vendor id))) |
| locale `de`, storefront DEU | coins "100 Testmuenzen", `0,99 €`; products without a `de` entry show their reference name and no description; group "Plus" |
| grace period (rate 1003) | state 4, `gracePeriodExpiresDate` = failed renewal + 30 s |
| Xcode Run | one save-configuration request per Run from the developer-tools service; unresolved path → delete request |
| StoreKit 1 restore | new transactions in state 3 for pro and the active subscription |
| receipt | CMS signed by the fixed "StoreKit" certificate; attributes 0, 1, 2, 3, 4, 5, 8, 12, 17×n, 21 |

## 4. Conformance tests

| Test | Content | Reference |
|---|---|---|
| C-BASE | StoreProbe phases in the order of `simulator-baseline.md` §8 | rows E1–G4 |
| C-FILE | parse and re-write `YcodeProbe.storekit`, `YcodeProbeSettings.storekit` and corpus files; every key of `configuration-file.md`; unknown keys kept | `configuration-file.md` |
| C-SCHEME | read/write the element; path resolution for shared schemes (and, once answered, user schemes and workspaces); install-on-Run | `ide.md` §2 |
| C-EDITOR | editor operations produce the expected JSON | `configuration-file.md` |
| C-TXMGR | each Transaction Manager action has the effect of the matching test-session call | `testing-session.md` §2 |
| C-ENGINE | §3.2 on Linux with a simulated clock | `testing-session.md` |
| C-FORMATS | payload keys and value forms; verification | `formats.md` |
| C-API | StoreProbe against Ycode's frameworks | §3 |

## 5. Open questions (for the next dirty-side round)

1. GUI pass in Xcode with screen control: template assistant, new file
   bytes and `version`, editor sections and Editor menu, scheme pop-up and
   the XML it writes, Transaction Manager (`ide.md` §7).
2. Purchase confirmation sheet and manage-subscriptions sheet content
   (`simulator-baseline.md` §9).
3. Billing retry state 3 and the retry window length (grace state 4 is
   measured); price increase testing; win-back offers; `_storeKitErrors`
   element structure.
4. `xcodebuild test` and StoreKit configurations.
5. The same baseline on the iOS 27.0 runtime.
6. The anomalies listed in `research/notes/storekit-observations-2026-10-20.md`.

## Evidence

Golden values: level 3 (StoreProbe on iOS 27.1, 2026-10-19/20). Rounds and
tests: Ycode's plan (no evidence level).
