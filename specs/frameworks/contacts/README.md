# Contacts and ContactsUI (iOS) — specification index

Status: **round 0 (specification)**, 2026-10-20; implementation status
below. Reference: the iOS 27.1 SDK in Xcode 27.1 (27A9269) and the iOS 27.1
simulator runtime (24A94401); the iOS 27.0 (24A434) and 26.5 (23F77)
runtimes were inspected as files only.

Implementation status (2026-10-28): `frameworks/contacts/` (package
`ycode-contacts`: library product `Contacts`, test target `ContactsTests`).
Rounds R2–R5 of `plan.md` are done (R3 without a daemon); R6 (authorization)
is deferred; R7–R9 are not started. The package README lists what is done,
deferred and not started.

## Scope

The Contacts API an iPhone app links against: the contact store, contacts
and their keys and labeled values, partial fetches, containers and groups,
predicates and sorting, save requests, change notifications and change
history, name and postal-address formatting, vCard serialization, the
authorization model with the iOS 18 limited access, its two-step prompt and
the SwiftUI access picker/button, errors, and ContactsUI's controllers. It
records what Apple's simulator does today — the baseline Ycode's simulator
must match first. Contacts works fully there without an account (with six
sample contacts in the device template); only the Contacts **app** is
missing from the 27.1 runtime.

Not covered: CardDAV/Exchange account protocols (named only), contact
linking/unification internals (not public), contact posters and the
"Me" card, macOS-only API.

## Files

| File | Content |
|---|---|
| `simulator-baseline.md` | Behavior in Apple's simulator; seed data and fixed container identifier; daemons, Mach services, ContactsUI extensions; data files; **conformance checklist** C1–C11 |
| `interface.md` | Classes; keys and partial contacts; identifiers; labeled values and labels; containers and groups; fetching with predicate and sort **golden tables**; saving rules; notifications; change history |
| `formats.md` | `CNContactFormatter` (24 golden cases), `CNPostalAddressFormatter` (14 countries), vCard export line mapping and import table |
| `authorization.md` | Usage key and notes entitlement, statuses, implicit prompt, the two-step prompt as observed, limited access, SwiftUI picker and button, `simctl privacy` |
| `errors.md` | `CNErrorDomain` codes, situations, user-info keys, exceptions |
| `ui.md` | `CNContactPickerViewController`, `CNContactViewController` |
| `design.md` | **Ycode-original design note** |
| `plan.md` | Rounds R1–R9, conformance tests, open questions |
| `identifiers.md` | Generated appendix: enumerations with raw values; every string constant (keys, labels, services) with its value |
| `api-inventory.md` | Generated appendix: classes, superclasses, member names, versions |

Black-box observations: `research/notes/eventkit-contacts-simulator-observations-2026-10-20.md`.
Probe app (our own code): `research/experiments/eventkit-contacts/CNProbe/`.
Generators: `research/experiments/eventkit-contacts/{extract_names,gen_api}.py`.

## Framework layout facts (level 4)

- Install names `/System/Library/Frameworks/Contacts.framework/Contacts` and
  `/System/Library/Frameworks/ContactsUI.framework/ContactsUI`; API from
  iOS 9.0, limited access (status 4) from iOS 18.0.
- Swift overlay: Contacts adds accessors on `CNError` (`affectedRecords`,
  `affectedRecordIdentifiers`, `keyPaths`), an `Identifiable` conformance of
  `CNContact` with a `UUID` `id` (iOS 17) and Swift `description`,
  `shortDebugDescription`, `debugDescription`; ContactsUI adds `ContactAccessButton` (with `Caption`
  and `Style`), `contactAccessButtonStyle(_:)`,
  `contactAccessButtonCaption(_:)` and `contactAccessPicker(isPresented:completionHandler:)`
  (iOS 18), plus an `id` override on `CNMutableContact` (iOS 16).
- In the runtime, `Contacts.framework/Support/contactsd` serves the store;
  ContactsUI's picker and contact view run as extensions in
  `ContactsUI.framework/PlugIns`; private frameworks `ContactsFoundation`,
  `ContactsPersistence`, `ContactsUICore`, `AddressBookLegacy` (names only).

## Evidence summary

Level 1: Apple's public documentation, RFC 2426/6350 (our words). Level 2:
runtime layout, launchd property lists, extension metadata, the template
database as a format (table names, columns of `LimitedAccess`, properties),
TCC rows. Level 3: `CNProbe` and variants on `ycode-test-ekcn-271` and
`ycode-test-eventkit-271` (iPhone Duo, iOS 27.1). Level 4: SDK and Swift
interface names, enum values, availability. Level 5 was **not** used.

## What the owner must provide

Nothing for the simulator work. Note: the notes entitlement works in the
simulator from an ad-hoc build; on a device it requires Apple's approval for
the owner's team (not attempted).
