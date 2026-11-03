# Code signing and entitlements

Ycode: `YcodeSigning` (Foundation only), compiled into the `ycode-swb`
helper through the symbolic link `ycode/Tools/ycode-swb/Sources/YcodeSigning`;
`YcodeBuild.SwiftBuildEngine` (IDE builds and `ycode build --engine
swift-build`); `YcodeXcodebuild` (`ycodebuild`, `-exportArchive`). Tests:
`YcodeSigningTests` (synthetic identities and profiles only),
`YcodeIDECoreTests/SigningBuildTests`.

This is a Ycode design built from open-source swift-build and Apple's
public documentation. Where Xcode's exact behaviour is not recorded in
`specs/`, the rule is marked **Ycode decision** and, where it matters, an
open question for the dirty room.

## 1. Who decides what

swift-build (open source) plans the signing tasks itself: it reads
`CODE_SIGN_ENTITLEMENTS` (and `CODE_SIGN_ENTITLEMENTS_CONTENTS`), expands
the build settings in it except `$(AppIdentifierPrefix)`, writes the
`.xcent` files, signs nested code when it is copied (`CodeSignOnCopy`) and
the product last, embeds a profile, strips
`com.apple.security.get-task-allow` from deployment builds and adds the
App Sandbox and Hardened Runtime entitlements set through build settings
(`ENABLE_APP_SANDBOX`, `ENABLE_FILE_ACCESS_*`, …). For every target it asks
its client one question: given the target's provisioning source data
(`CODE_SIGN_IDENTITY`, `CODE_SIGN_STYLE`, `DEVELOPMENT_TEAM`, bundle
identifier, `PROVISIONING_PROFILE_SPECIFIER`, `PROVISIONING_PROFILE`,
whether a profile is required, the SDK, the product type's entitlements,
the project's expanded entitlements, whether the product takes
entitlements), which identity, profile and entitlements? Ycode answers it
in `ProvisioningResolver.resolve`, with these outputs:

| Output | Use by swift-build |
|---|---|
| identity hash (`-` ad hoc, else a certificate's SHA-1) and name | `codesign --sign`; the name appears in the log (`Signing Identity:`) |
| profile name, UUID, path | `EXPANDED_PROVISIONING_PROFILE`; the profile is copied into the product (`embedded.mobileprovision`, `embedded.provisionprofile`) |
| signed entitlements | the `.xcent` file passed to `codesign --entitlements` |
| simulated entitlements | `<product>-Simulated.xcent`, linked into `__TEXT,__entitlements` (simulator SDKs) |
| `$(AppIdentifierPrefix)`, `$(TeamIdentifierPrefix)` | expanded in the entitlements and available as settings |
| errors, warnings | reported as build issues; an error stops signing |

## 2. Identities

`CODE_SIGN_IDENTITY` values: empty (not signed), `-` (Sign to Run Locally,
ad hoc), a SHA-1 hash (40 hex digits), a certificate's full common name, or
a kind. Kinds select certificates whose common name starts with the kind
and `:`. These are families (the older names select the same certificates):
`Apple Development` / `iPhone Developer` / `Mac Developer`;
`Apple Distribution` / `iPhone Distribution` / `3rd Party Mac Developer
Application` / `Mac App Distribution`. Other kinds (`Developer ID
Application`, …) match only themselves.

Identities come from `security find-identity -v -p codesigning` (hash and
name) and the certificates from `security find-certificate -a -Z -p`
(public parts only). The certificate's subject organizational unit (OID
2.5.4.11) is the team, its validity end the expiry. Ycode never creates,
imports or exports an identity, and prints only names and hashes. With a
team, only that team's identities are candidates; expired ones never are;
the latest-expiring candidate is used unless a profile narrows the choice.

The keychain is read only when a target asks for an identity other than
`-`, at most once per build. On Linux there is no keychain: identity
signing reports the missing certificate.

## 3. Provisioning profiles

Folders: `~/Library/Developer/Xcode/UserData/Provisioning Profiles`
(Xcode 16 and later) and `~/Library/MobileDevice/Provisioning Profiles`
(older); `YCODE_PROVISIONING_PROFILES` (folders separated by `:`)
replaces both (tests). Files `*.mobileprovision` and `*.provisionprofile`;
the CMS envelope is opened with `security cms -D -i`; a file that is
already a property list is read as it is (synthetic test profiles).

Keys read (TN3125): `UUID`, `Name`, `TeamIdentifier`, `TeamName`,
`AppIDName`, `ApplicationIdentifierPrefix`, `Platform`, `CreationDate`,
`ExpirationDate`, `Entitlements`, `ProvisionedDevices`,
`ProvisionsAllDevices`, `DeveloperCertificates` (compared by SHA-1 with
the identities), `IsXcodeManaged`. Kind: `get-task-allow` (or
`com.apple.security.get-task-allow`) true → development; else all
devices → enterprise; else listed devices → ad hoc; else distribution.

A profile can sign a request when (in this order; the first failure is the
message): it has not expired; it belongs to `DEVELOPMENT_TEAM`; its
`Platform` includes the SDK's (`OSX` for macOS and Mac Catalyst, `iOS`,
`xrOS`/`visionOS`, `tvOS`, `watchOS`/`iOS`); its application identifier
`<prefix>.<pattern>` covers the bundle identifier (`*` matches any run of
characters); it lists a candidate identity's certificate; a debuggable
device build has a development profile; and it allows every restricted
entitlement the project asks for (§4.3).

- **Manual** style (or any style with a specifier): the profile named by
  `PROVISIONING_PROFILE` (UUID) or `PROVISIONING_PROFILE_SPECIFIER`
  (name or UUID, optionally `<team>/` first). It must pass the checks.
- **Automatic** style: among the installed profiles that pass, an explicit
  app ID before a wildcard, then the kind that fits (development for
  debuggable builds, distribution otherwise), then the latest expiry,
  then the UUID.
- A profile is **needed** when the SDK requires one (device SDKs:
  swift-build's `PROVISIONING_PROFILE_REQUIRED`) or a restricted
  entitlement is requested. On the Mac an identity without restricted
  entitlements signs without a profile (manual style) or with a matching
  one if installed (automatic).

**Never created.** Ycode does not register devices, create App IDs or
download profiles. Automatic signing that would need Apple's developer
services reports the missing profile (§7) — remaining work (SIGN-2: an
Accounts pane with an App Store Connect API key, public REST API).

## 4. Entitlements

### 4.1 Composition

`base` = the product type's entitlements, overlaid with the project's
(swift-build already merged the file and `CODE_SIGN_ENTITLEMENTS_CONTENTS`
and expanded their settings). Products that take no entitlements
(`supportsEntitlements` false: frameworks, libraries, test bundles) get
none, except product types swift-build signs only with entitlements:
UI test bundles (`com.apple.product-type.bundle.ui-testing`, the
`productTypeIdentifier` of the source data; swift-build sets
`ENTITLEMENTS_REQUIRED` for them and stops with "Entitlements are required
for product type …" when the answer has none). They are composed like an
executable's, from the table below (`SigningRequest.takesEntitlements`). "Debuggable" is true for builds and false for archives
(`ycode-swb` request `debuggable`).

| Case | Signed (code signature) | Simulated (`__TEXT,__entitlements`) |
|---|---|---|
| Simulator SDK (swift-build always sends `-`) | `get-task-allow` true when debuggable, nothing else | `application-identifier` = `$(AppIdentifierPrefix)<bundle id>`, `keychain-access-groups` = [the same], `com.apple.developer.team-identifier` when a team is set, then `base` (the project wins) |
| `-` on the Mac or a device | `base` + the debugging entitlement (`com.apple.security.get-task-allow` on the Mac, `get-task-allow` elsewhere) when debuggable | none |
| identity, no profile (Mac) | `base` + the debugging entitlement when debuggable | none |
| identity and profile | `base`, overlaid with: the application identifier (`com.apple.application-identifier` on the Mac, `application-identifier` elsewhere) = prefix + bundle id; `com.apple.developer.team-identifier`; the debugging entitlement when debuggable (on devices only if the profile allows it); on devices, `keychain-access-groups` = [prefix + bundle id] when the project sets none and the profile allows it | none |

`$(AppIdentifierPrefix)` = the profile's application-identifier prefix (or
the team) plus `.`; empty without a team. `$(TeamIdentifierPrefix)` = the
team plus `.`.

Evidence and decisions: the simulator split (signature only
`get-task-allow`, the rest in the section) follows swift-build's own
reference answer (`swbuild`'s and the test suite's provisioning
delegates) and its rule that simulator signatures carry only
`get-task-allow`; the section is what the simulator honours
(`specs/simulator/app-install-launch.md` §4.5, `host-libraries.md`). The
derived `keychain-access-groups` in the simulator section is a **Ycode
decision**: without it a keychain call fails with -34018
(`specs/simulator/snapshot.md` w9). OPEN QUESTION (dirty room): the exact
keys Xcode 27.1 writes into `<product>-Simulated.xcent` with and without
a team, and into a development `.xcent` on the Mac and on devices.

### 4.2 Restricted entitlements

Restricted (need a profile): on the Mac everything except
`com.apple.security.*` (App Sandbox and Hardened Runtime entitlements,
`com.apple.security.application-groups`); on devices everything except
`get-task-allow`; in simulators nothing. The identifiers Ycode derives
(application identifier, team identifier, debugging) are checked
separately.

### 4.3 Allowed values

A profile value allows a request when: Boolean true allows true and false,
false only false; a string is a pattern for a string or for every element
of an array; an array allows a string or array whose every element
matches one of its patterns; other types must be equal.

## 5. Re-signing finished code (`-exportArchive`)

`signingCertificate` other than `-` (method `mac-application`): the
identity is looked up as in §2 (team: `teamID` of the options); every
nested item is signed before its container with `codesign --force --sign
<hash> --preserve-metadata=identifier,entitlements,flags --timestamp=none`.

Order (`NestedCode.signingOrder`, TN2206 and "Placing content in a
bundle"): in a bundle's contents folder (`Contents`, `Versions/<Current>`
for frameworks, else the bundle) the folders `Frameworks`,
`SharedFrameworks`, `PlugIns`, `Extensions`, `XPCServices`,
`Library/LoginItems`, `Library/SystemExtensions`, `Library/QuickLook`,
`Library/Spotlight`, `Helpers`, `MacOS`, `Watch`, `AppClips`, in that
order; in each, entries by name. A nested bundle (`.app`, `.appex`,
`.framework`, `.xpc`, `.bundle`, `.systemextension`, `.qlgenerator`,
`.mdimporter`, `.plugin`) is visited depth-first and signed after its own
nested code; `.dylib` files and other Mach-O files are signed as they
are, except the bundle's own `CFBundleExecutable`; the bundle is last.

## 6. Build paths

- **IDE and `ycode build --engine swift-build`**: `SwiftBuildEngine` runs
  `ycode-swb build` (found through `YCODE_SWB`, next to `swbuild`, or on
  PATH) with the same PIF, the request `swbuild build` would make
  (`targetNames`, no implicit dependencies, hidden script environment,
  `cleanBuildFolder` for clean) and the build locations of `swbuild
  --derivedDataPath` (`arenaInfo`: `<dd>/Products`,
  `<dd>/Intermediates.noindex`). Only `SDK_STAT_CACHE_ENABLE=NO` is
  overridden: the project's signing settings apply. Without the helper
  the engine still uses `swbuild` with the old overrides (identity `-`,
  `ENTITLEMENTS_DESTINATION` empty: no entitlements) and says so in the
  build log.
- **`ycodebuild`**: `ycode-swb build` as before (`build-actions.md` §4);
  the delegate is now the same resolver, so identities, profiles and the
  simulator section apply there too. Sign to Run Locally builds are
  unchanged.
- **Automatic style on the Mac without a team** signs to run locally
  (**Ycode decision**, matching what the Signing & Capabilities editor
  shows for team None); on device SDKs it is the "requires a development
  team" error.

## 7. Diagnostics

Ycode's wording (**Ycode decision**, modelled on the messages developers
know; the reference's exact texts are an open question):

| Situation | Message |
|---|---|
| identity, no team (devices; manual Mac with a profile) | `Signing for "<target>" requires a development team. Select a development team in the Signing & Capabilities editor.` |
| no matching identity | `No signing certificate "<identity>" found: No "<identity>" signing certificate matching team ID "<team>" with a private key was found in the keychain. Ycode does not create certificates; add one to the keychain, or sign to run locally.` |
| manual profile not installed | `No profile for team '<team>' matching '<specifier>' found: Ycode found no installed provisioning profile matching '<specifier>'. Install the profile, or choose another one in the Signing & Capabilities editor.` |
| manual style, profile needed, none named | `"<target>" requires a provisioning profile. Select a provisioning profile in the Signing & Capabilities editor.` |
| automatic, no usable profile | `No profiles for '<bundle id>' were found: Ycode found no installed provisioning profile for team '<team>' matching '<bundle id>'[ with the entitlements the target needs]. Ycode does not create or download profiles (automatic provisioning through Apple's developer services is not supported); install a matching profile, or sign to run locally.` |
| profile expired / other team / other platform / app ID / certificate / kind | `Provisioning profile "<name>" expired on <ISO 8601 date>.` · `… belongs to team <ids>, not to the development team <team>.` · `… is for <platforms>, not for <platform>.` · `… has app ID "<id>", which does not match the bundle ID "<bundle id>".` · `… doesn't include a signing certificate "<identity>" from the keychain.` · `… is a <kind> profile; debugging needs a development profile.` |
| entitlement not allowed | `Provisioning profile "<name>" doesn't include the <key> entitlement.` · `Provisioning profile "<name>" doesn't match the entitlements file's value for the <key> entitlement.` |
| ad hoc Mac build with restricted entitlements (warning) | `"<target>" is signed to run locally, but "<key>"[, …] needs a provisioning profile; macOS may refuse to launch it. Select a development team to sign with a profile.` |

## 8. Linux (design)

`codesign` and the keychain do not exist on Linux. The plan:

- **rcodesign** (apple-codesign, MPL-2.0) as an external program found on
  PATH, never linked or vendored. `rcodesign sign <path>` without key
  material signs ad hoc; `--entitlements-xml-file <plist>` signs
  entitlements in. `CodesignCommand.rcodesignAdHoc` builds that command
  line (tested); nothing runs it yet, because swift-build on Linux does not
  build Apple-platform products in Ycode today (simulator apps are built on
  the Mac, then installed on the Linux host's simulator, which reads the
  `__TEXT,__entitlements` section and needs no real signature).
- Identity signing on Linux needs the certificate and private key as
  files (`--p12-file` with a password from a file, or `--pem-file`). Ycode
  will take them from a user-chosen location, never copy them, and pass
  them only to rcodesign. Profiles are the same files (§3), opened with
  rcodesign's or Ycode's own CMS reader (the content is a signed property
  list; reading it needs no verification).
- Notarization: the public Notary REST API (or `rcodesign
  notary-submit`) with an App Store Connect API key.

Remaining: running rcodesign from swift-build's signing tasks on Linux,
identity signing with key files, notarization.

## 9. Remaining

Automatic provisioning (device registration, App ID and profile creation,
certificate requests) through Apple's developer services; an Accounts pane
(SIGN-2); notarization and stapling; distribution methods other than
`mac-application` (`development`, `ad-hoc`, `app-store-connect`,
`developer-id`, `enterprise`) and `.pkg` export; Linux signing (§8);
installing on physical devices.

## Evidence

- Provisioning question and answer, the planning of signing tasks,
  `.xcent` files, the entitlements section, settings expansion,
  `$(AppIdentifierPrefix)` handling, simulators always ad hoc, deployment
  builds without `com.apple.security.get-task-allow`, App Sandbox settings:
  open-source swift-build, Apache-2.0 (`SWBProvisioningTaskInputs.swift`,
  `PlanningOperation.swift`, `Provisioning.swift`, `ProductPackaging.swift`,
  `Settings.swift` signing settings, `ProcessProductEntitlementsTaskAction.swift`,
  `SWBServiceConsoleBuildCommand.swift` and `TestBuildOperationDelegate.swift`
  reference delegates, `CoreBuildSystem.xcspec`, `DarwinProductTypes.xcspec`;
  UI test bundles requiring entitlements: `ProductTypes.swift`
  `addXCTRunnerSettings`, `SigningSupport.swift`) (level 1).
- Profiles as a CMS-signed property list, their keys, entitlements as an
  allow list with wildcards, restricted and unrestricted entitlements,
  application-identifier keys per platform: Apple TN3125 "Inside Code
  Signing: Provisioning Profiles", TN3126/TN3127 (code signing and
  requirements), "Entitlements" and "App Sandbox" developer documentation
  (level 1).
- Profile folders: Xcode 16 release notes (the UserData location) and
  TN3125 (the MobileDevice location) (level 1).
- Nested code order, bundle folders: TN2206 "macOS Code Signing In Depth"
  and "Placing content in a bundle" (level 1); `codesign(1)` manual page
  for the flags (level 1).
- Certificate fields: RFC 5280 §4.1 and ITU-T X.690 (DER) (level 1);
  SHA-1: FIPS 180-4 (level 1). `security(1)` manual page for
  `find-identity`, `find-certificate`, `cms` (level 1).
- rcodesign command line: apple-codesign documentation and its CLI source
  (MPL-2.0, read only) (level 1).
- Simulator entitlements in `__TEXT,__entitlements`, signature
  entitlements refused by the Mac simulator host:
  `specs/simulator/app-install-launch.md` §4.5 (level 3, from the spec).
- Ycode runs (level 3, Ycode only): a template macOS app with App Sandbox,
  Outgoing Connections and an app group named with
  `$(PRODUCT_BUNDLE_IDENTIFIER)`, built through the IDE engine, signed ad
  hoc with all of them expanded and `com.apple.security.get-task-allow`
  (`SigningBuildTests`); `Samples/SigningSamples` `SandboxedMac` built
  with `ycode build --engine swift-build` ran inside the App Sandbox
  with its app-group container; with a development identity of the Mac's
  keychain and `DEVELOPMENT_TEAM` the same app was signed by the team
  (no profile needed), passed `codesign --verify --strict` and launched;
  with `keychain-access-groups` added, the automatic-profile error of §7
  was reported (no matching profile was installed).
- Ycode's simulator (level 3, Ycode only): `KeychainGroups`, built for
  `platform=iOS Simulator`, has only `get-task-allow` in its ad hoc
  signature and `application-identifier`, the app group and the keychain
  group in `__TEXT,__entitlements`; on an iPhone 18 Pro device (iOS 27.0
  runtime) on the arm64 Linux host it printed `keychain add=0 read=0
  group=org.ycode.samples.signing.shared appGroupContainer=yes` (one cold
  boot, `ide-remote/signing/runs/kg1`).
- Diagnostics wording and the rules marked **Ycode decision**: Ycode
  design (no level).
