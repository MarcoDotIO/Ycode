# StoreKit spec: the IDE side (Xcode's StoreKit tooling)

Part of `specs/frameworks/storekit/`. What Xcode offers for StoreKit
Testing and what Ycode's IDE must reproduce: the configuration file
(`configuration-file.md`), the file template, the configuration editor, the
scheme option that installs a configuration on Run, the Transaction Manager
and the Debug ▸ StoreKit commands, and what the command-line tools expose.

Evidence: level 1 (Apple's public documentation and Xcode Help, summarized
in our words), level 2 (scheme and configuration files as formats), level 3
(black-box runs of our own generated project with Xcode 27.1 driven through
its scripting interface and with `xcodebuild`), level 4 (Xcode's plug-in
registration data and bundle layout, names only). The GUI itself could not
be observed in this round (no screen-control access in the session); the
GUI items below are level 1 and marked for a follow-up observation pass.

## 1. Components in Xcode (level 4)

| Piece | Name | Role |
|---|---|---|
| Core plug-in | `IDEStoreKitCore.ideplugin` | file types (`com.apple.dt.storekit`, `com.apple.dt.storekitbundle`, both shown as "StoreKit Configuration"), the configuration model, the connection to the device's test store |
| Editor plug-in | `IDEStoreKitEditor.ideplugin` | the configuration editor, the template assistant, the Transaction Manager, text conversion (open as source), the exported test certificate (`StoreKitTestCertificate.cer`, the StoreKit 1 receipt signer, `formats.md` §3) |
| Template kind | "StoreKit Configuration File Template Kind" with an assistant | File ▸ New ▸ File from Template ▸ Other ▸ "StoreKit Configuration File" (`specs/ide/reference-ui-3.md`) |
| Commands (Debug ▸ StoreKit) | Manage Transactions… (opens the Transaction Manager), Approve Transaction, Decline Transaction, Refund Purchase, Resolve Issue, Request Price Increase Consent, Edit Subscription, Delete Transaction (`specs/ide/reference-ui-5.md` §2.10) | act on the selected transaction in the Transaction Manager |

Editor sections, from the names of its interface files: products list with
cells, localizations, subscription levels (group ranking), introductory /
ad-hoc (promotional) / code / win-back offers sections, key pair (the
subscription-offer signing key), EULA, policies, a transactions table, and
a "launch action option" (the scheme pop-up).

## 2. The scheme option

### 2.1 Format (level 2 + 3)

The Run action carries one optional child element:

    LaunchAction
      …
      StoreKitConfigurationFileReference [identifier]

- `identifier` is a **relative path** to the `.storekit` file.
- Base directory (observed): for a project's shared scheme
  `<dir>/<Name>.xcodeproj/xcshareddata/xcschemes/<scheme>.xcscheme`, the
  path `../../StoreProbe/YcodeProbe.storekit` named
  `<dir>/StoreProbe/YcodeProbe.storekit` and worked; `../StoreProbe/…` did
  not resolve (Xcode then removed the installed configuration, §2.2). So the base is two levels below `<dir>`, consistent
  with the project's embedded workspace `<Name>.xcodeproj/project.xcworkspace`
  as the base (open question 1: user schemes and `.xcworkspace` containers).
- Placement: after the runnable, arguments and environment children
  (our generated scheme placed it last in `LaunchAction`; Xcode accepted it).
  The order Xcode itself writes is open question 2.
- Absent element = "None" in the Run ▸ Options pop-up
  (`specs/ide/reference-ui-2.md`).

The Test action does not have the option in the editor (level 1: tests use
`SKTestSession`); whether `xcodebuild test` honors an element placed in
`TestAction` is open question 3.

### 2.2 Behavior on Run (level 3)

1. When Run launches the app on a simulator, Xcode installs the scheme's
   configuration in that device's test store for the app's bundle
   identifier — the same save-configuration request `SKTestSession` makes
   (`simulator-baseline.md` §4) — **before** launching the app. The request
   does not come from Xcode's own process: it comes from the developer-tools
   service process in the guest (launchd job
   `com.apple.instruments.deviceservice`, program
   `/System/Library/PrivateFrameworks/DVTInstrumentsFoundation.framework/DTServiceHub`,
   started on demand by Xcode through CoreSimulator). The daemon logs the
   request as made "for dev.ycode.skprobe by
   com.apple.dt.instruments.DVTInstrumentsFoundation" and accepts it because
   that caller "is entitled for StoreKit testing"; ordinary apps may only
   save configurations for themselves. Timeline of one run (light host
   load): Run at 0 s, save request at +3.5 s, the daemon's copy
   `Octane/<bundle id>/Configuration.storekit` written with `appName` set
   to the product name, the app's first log line at +14 s. Products then
   loaded in the app without any `SKTestSession`.
2. The installation persists after the run ends: a later plain `simctl`
   launch of the app still sees the products.
3. With a path that does not resolve (observed with `../StoreProbe/…`),
   Xcode sends a **delete-configuration** request for the app's bundle id
   through the same service before launch: the app's installed
   configuration is removed and the app sees an empty catalog. Expected the
   same for "None" (no element) — open question 7.
4. Xcode no longer hosts a test server itself; the device's daemon is the
   store (the daemon logs that fetching an Xcode-hosted server port is "no
   longer supported").
5. Xcode re-sends the file on **every** Run, changed or not (three Runs, three
   save requests). The save keeps the app's test-store transactions (two
   entitlements survived; see `simulator-baseline.md` §4 for an unfinished
   consumable that did not). Not yet observed: whether editing the file
   while the app runs updates the store live (level 1 says it does) (open
   question 4).
6. Under very heavy host load (load average 300–700) Runs took many minutes
   to reach the launch and several attempts were stopped before the
   installation happened; observations of "nothing installed" must wait for
   the app's own first log line.

### 2.3 Devices and destinations (level 1)

Local StoreKit Testing works on simulators and on physical devices
(through the same option); for a device Xcode installs the configuration
over its device connection. Ycode supports simulators first.

## 3. The configuration editor (level 1; GUI pass pending)

From public documentation and the interface-file names:

1. New file: the template assistant offers a local configuration or one
   **synchronized with App Store Connect** (needs a signed-in team; the
   synced file is read-only until converted). Ycode offers local only and
   preserves the sync keys of existing files.
2. Main view: a sidebar/list of products grouped as Consumables,
   Non-Consumables, Non-Renewing Subscriptions and subscription groups; a
   "+" menu adds a product of each kind or a subscription group; selecting
   an item shows its detail form: reference name, product ID, price, family
   sharing, localizations (with "+" per locale), and for subscriptions the
   duration, group level ordering (drag to rank), introductory offer,
   promotional offers, offer codes and win-back offers.
3. Editor menu items while the file is open: default storefront, default
   localization, time rate, Ask to Buy, interrupted purchases, billing retry
   on renewal, billing grace period, StoreKit errors (per-API simulated
   errors), subscription offers key, save public certificate, and (for
   synced files) sync and convert. These write the `settings` keys of
   `configuration-file.md` §6.
4. Editing writes the JSON immediately (document-based, undoable).

## 4. Transaction Manager (level 1 + 4; GUI pass pending)

Debug ▸ StoreKit ▸ Manage Transactions… opens a window that lists, per
device and app, the test store's transactions (product, date, state,
pending Ask-to-Buy, purchase issue) and lets the developer act on the
selected one with the commands of §1. These map one-to-one onto the test
store's control operations (`testing-session.md` §2: approve/decline Ask to
Buy, refund, resolve issue, request price increase consent, change
subscription, delete). The manager reads the device's store through the
same configuration service an app's `SKTestSession` uses
(`com.apple.storekit.configuration.xpc`), so it shows transactions made by
the app on that device whether or not the app is running (inference; open
question 5).

## 5. Command-line tools

| Tool | StoreKit support |
|---|---|
| Xcode Run (for comparison) | installs through the guest's developer-tools service (§2.2) |
| `xcrun simctl` | none: no subcommand installs a configuration or lists transactions (level 3, `simctl help`) |
| `xcodebuild build` | copies a `.storekit` that is a target resource into the app bundle like any resource; no other processing (level 3) |
| `xcodebuild test` | runs tests that use `SKTestSession` (level 1); our attempt to observe whether it applies the scheme's Run option hung before the tests started on a heavily loaded host (open question 3) |
| `xcrun` tools | none dedicated to StoreKit (level 3: no such tool in the developer `usr/bin`) |

## 6. What Ycode's IDE must provide

1. Read, edit and write `.storekit` files per `configuration-file.md`,
   preserving unknown keys and the sync keys; a source-text view.
2. A "StoreKit Configuration File" template (local) producing a valid empty
   configuration with default settings (USA, `en_US`, real time, all toggles
   off, no errors) and a fresh 8-hex-digit identifier.
3. The configuration editor of §3 (Ycode's own design and assets).
4. The scheme option: the Run ▸ Options pop-up listing the workspace's
   `.storekit` files, writing and reading `StoreKitConfigurationFileReference`
   with the relative path rule of §2.1.
5. On Run to a Ycode simulator: install the configuration for the app's
   bundle id in the guest's store before launch (through the guest's
   configuration service, or, with an open StoreKit, through Ycode's own
   channel), and keep it after the run.
6. A Transaction Manager with the actions of §1 and §4, and the Debug ▸
   StoreKit menu.
7. Export of the store's public certificate (Ycode's own).
8. Command line: a Ycode CLI equivalent to the missing `simctl` support
   (install configuration, list/act on transactions) so tests and CI can
   drive the store without the GUI (Ycode extension).

## 7. Open questions

1. Base directory of `identifier` for user schemes and for schemes stored
   in an `.xcworkspace`.
2. The child order Xcode writes in `LaunchAction` when the option is set in
   the editor.
3. `xcodebuild test` and the Run option / a `TestAction` reference.
4. Re-installation on each Run, live updates while running, effect on
   existing transactions.
5. Transaction Manager contents and behavior (GUI pass with screen control).
6. The template assistant's choices and the new file's exact bytes,
   including `version` (GUI pass).
7. Run with the option set to "None": a delete request as for an
   unresolved path? And whether Xcode reports an unresolved path anywhere.

## Evidence

- §1: level 4 (plug-in registration data, interface-file names, resource
  names; nothing copied) and earlier menu observations (level 3,
  `specs/ide/reference-ui-5.md`).
- §2.1–§2.2: level 2 (scheme format, launchd job and program path) and
  level 3 (Xcode 27.1 running our generated project
  `research/experiments/storekit/make_project.py` through its scripting
  interface on `ycode-test-storekit-1`; positive and negative path runs; the
  daemon's copy and the device log).
- §2.3, §3, §4: level 1 (public documentation), marked pending GUI
  observation.
- §5: level 3.
- §6: Ycode's requirements (no evidence level).
