# HomeKit spec: plan in rounds and conformance tests

Part of `specs/frameworks/homekit/`. Rounds are sized for one agent each.
Track S = parity of Ycode's iOS simulator (Apple's runtime HomeKit stack);
Track O = the open, Linux-buildable implementation (`open-design.md`,
Ycode-original). Implementation agents (anything writing `ycode/` or a
future open-frameworks package) read only `specs/`, public documentation and
Apache-2.0 sources; they must not open the reference tools, Ghidra,
`research/dirty/` or the IPSW.

## 1. Rounds

| Round | Track | Goal | Done when |
|---|---|---|---|
| R0 | — | This specification. | Merged. |
| R1 | S | HomeKit baseline in Ycode's simulator: homed/homeeventsd run (lean-boot exception or on-demand start), entitlement section honored, kTCCServiceWillow alert, fast "no account" path, HomeUIService hosting. | `HMProbe` passes HK-B01–B16 on the Thor, outputs equal to the Mac's ignoring times and UUIDs. |
| R2 | S/owner | Account-enabled reference observations on the Mac (needs §4 inputs): homes, rooms, zones, groups, action sets, triggers, users UI, notifications, limits, name rules; then with HomeKit Accessory Simulator: accessories, characteristics, reads/writes/notifications, errors. Extend `HMProbe` (dirty side) and update `simulator-baseline.md`. | HK-A01–A30 recorded with expected results. |
| R3 | O | `HomeKitOpen` model library (Swift, Linux): type catalog from `type-identifiers.md`, value validation, error codes, model objects, delegates, main-queue delivery, in-memory daemon stub. | Unit tests T-O1–T-O6 pass on Linux. |
| R4 | O | `ycode-homed`: IPC, SQLite store, multi-client fan-out, authorization, action-set execution, timer and event triggers with a solar calculator. | T-O7–T-O12 pass; parity with R2's home-level observations. |
| R5 | O | HAP-IP controller: DNS-SD, pair-setup/verify, sessions, `/accessories`, reads, writes, timed writes, events; HAP status → `HMErrorCode` mapping. | T-H1–T-H8 pass against `ycode-hap-sim`. |
| R6 | O | `ycode-hap-sim` accessory simulator with presets, behaviors, control API, isolated network placement. (Can run in parallel with R5; R5 tests need it.) | T-A1–T-A6 pass; Apple's homed (R2 setup) can pair with it. |
| R7 | O | Setup flow: setup-payload parsing (X-HM), setup-hash matching, Ycode setup sheet, `HMAccessorySetupManager`. | T-H9–T-H10 pass. |
| R8 | O | Matter via connectedhomeip: commissioning, cluster→service mapping, `matterNodeID`/`matterEndpointID`. | T-M1–T-M3 pass with a connectedhomeip example device. |
| R9 | O | Cameras (HAP RTP stream setup, snapshots via `/resource`), BLE transport (BlueZ). Lowest priority. | Defined in a later spec round. |

## 2. Baseline checks (no account needed)

`simulator-baseline.md` §9, HK-B01–HK-B16. These are R1's acceptance
tests.

## 3. Account-enabled checks (need the owner's inputs, §4)

Expected results are to be filled in from the Mac in R2. Each is a new
`HMProbe` mode.

| ID | Probe | What to record |
|---|---|---|
| HK-A01 | addHome, duplicate, case-folded duplicate, empty, punctuation | Errors (31/32/35/36/60?), primary flag of first home, delegate callbacks on a second manager |
| HK-A02 | default room, rooms, rename, duplicate room, room named like home | Errors 29/31/33; `rooms` excludes default room |
| HK-A03 | zones: add room, add again, add default room, remove | Errors 24 and duplicate behavior |
| HK-A04 | service groups add/rename/remove | Callbacks |
| HK-A05 | two managers in one process | Same object instances or not; callback fan-out |
| HK-A06 | own change vs other client's change | Does the originating manager's delegate fire? |
| HK-A07 | built-in action sets | Which exist at home creation; execute empty (25); remove built-in (83) |
| HK-A08 | timer triggers | Past date (28), seconds not on minute boundary (70), recurrence limits (42/69/72), enable without hub |
| HK-A09 | event triggers | Activation state without hub (expect 1), calendar/sunset/presence/duration, predicates stored |
| HK-A10 | users | `currentUser`, admin flag, `manageUsers` UI |
| HK-A11 | persistence | Relaunch: same UUIDs and names |
| HK-A12 | limits | Max homes/rooms/name length (49, 46) |
| HK-A20 | pair Accessory Simulator lightbulb via setup UI | Accessory, category string, services, characteristic metadata and properties |
| HK-A21 | read/write On, Brightness bounds | Errors 44/45/43, value cache update timing |
| HK-A22 | notifications | `enableNotification`, value change from the Accessory Simulator → delegate callback latency and thread |
| HK-A23 | read-only / write-only / no-notify characteristics | Errors 5/6/7 |
| HK-A24 | unreachable accessory | Error 4/54, reachability callback |
| HK-A25 | action set with write actions | Execute, partial failure 64 |
| HK-A26 | characteristic event trigger | Activation without hub |
| HK-A27 | bridge with children | `bridgedAccessories`, removal rules (34) |
| HK-A28 | `HMAccessoryBrowser` with the Accessory Simulator advertising | Found/removed callbacks |
| HK-A29 | camera accessory | Profiles, snapshot, stream state |
| HK-A30 | setup payload from the Accessory Simulator's code | `HMAccessorySetupManager` with payload, result fields |

## 4. Owner inputs

| Input | Why | Without it |
|---|---|---|
| An Apple Account (a dedicated test account is best) signed in **by the owner** on a `ycode-test-homekit*` simulator | homed refuses to create homes without iCloud (error 2040). Everything in §3 depends on it. | Only the no-account baseline exists. |
| **Additional Tools for Xcode 27** → HomeKit Accessory Simulator, installed by the owner | Virtual HAP accessories for HK-A20–A30 and for checking `ycode-hap-sim` against Apple's own simulator. Needs an Apple developer download. | Use `ycode-hap-sim` only, with Apple's homed as the controller once an account exists. |
| Decision: may probes pair with a software accessory on an isolated network? | R2 and R6 need pairing, which we did not do in R0. Real accessories stay off-limits. | R2 accessory checks blocked. |
| (Optional) HAP Non-Commercial specification | Cross-check of ADK-derived facts. Requires sign-in and license acceptance. | ADK suffices. |
| Not needed | Development team or provisioning for simulator builds (entitlement section + ad hoc signing works). | — |

## 5. Open-implementation unit tests (Track O)

| ID | Test |
|---|---|
| T-O1 | Every constant string equals `type-identifiers.md` (184 HAP types, 33 categories, formats, units, properties). |
| T-O2 | Value validation: per format, min/max/step/maxLength/validValues → errors 43–46 before I/O. |
| T-O3 | Authorization states 0/1/5 and their callbacks; missing usage string aborts; missing entitlement → 47. |
| T-O4 | No-account mode (if enabled for parity) returns 2040 from `addHome` before name checks. |
| T-O5 | Events: copy/mutableCopy classes, fresh identifiers, `isSupportedForHome:` rules (`simulator-baseline.md` §7). |
| T-O6 | Setup payload: `X-HM://` + 13 characters accepted, others rejected. |
| T-O7 | Multi-client fan-out per HK-A05/A06 results. |
| T-O8 | Name rules and limits per HK-A01–A03, A12. |
| T-O9 | Timer trigger fire, recurrence, boundaries (HK-A08). |
| T-O10 | Sunrise/sunset with offsets for a fixed location and date (against a published solar table). |
| T-O11 | Action-set execution order, partial success (64). |
| T-O12 | Persistence and resync after daemon restart. |
| T-H1–T-H8 | HAP-IP: discovery TXT parsing; pair-setup with correct/incorrect code (retry limit); pair-verify; encrypted framing; `/accessories` parse; read/write/timed write; events; status mapping (`errors.md` §3). |
| T-H9–T-H10 | Setup URL parse/build round trip; setup-hash match. |
| T-A1–T-A6 | Accessory simulator: presets load; state transitions; forced errors; unreachable toggle; `c#` bump; isolation (no traffic outside its namespace). |
| T-M1–T-M3 | Matter commissioning with an example device; attribute read/write via mapped characteristic; subscription → notification. |

## Evidence

Planning document; Ycode-original. Facts referenced are evidenced in the
other files. Error-code expectations in §3 are level 1 guesses to be
replaced by level 3 results in R2.
