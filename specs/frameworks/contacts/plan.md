# Contacts spec: implementation rounds and conformance tests

Part of `specs/frameworks/contacts/`. This plan is Ycode's own. Clean-room
agents read only `specs/`, public documentation and permissively licensed
open source; they must not open the reference tools (the Xcode copy,
Ghidra, the IPSW), `research/dirty/`, or Ghidra projects, and must not run
Apple's simulator or Xcode.

## 1. Targets

1. **Baseline in Ycode's simulator** with Apple's Contacts (`design.md` §2).
2. **Open Contacts / ContactsUI**: drop-in frameworks (same install names,
   classes, selectors, enum values, the string constants of
   `identifiers.md`, the Swift-overlay names of `authorization.md` §5.2) and
   a Linux Swift package.

## 2. Rounds

| Round | Owner | Scope | Done when |
|---|---|---|---|
| R0 | KIT-EVENTKIT-CONTACTS (this) | Specification and probe | merged |
| R1 | simulator track | **Baseline**: G1–G7 of `design.md`; Ycode's own seed address book; run `CNProbe` basic → status → req → req [Lim] (Select Contacts, pick two) → noaccess → data → data [Lim] → list → ui*; answer by taps | rows C1–C11 of `simulator-baseline.md` §6 match (modulo identifiers and times) |
| R2 | clean room | **Model and pure code**: `CNContact`/mutable copies, labeled values with identifiers, key availability and the two exceptions, labels and localization tables, value classes, `CNContactFormatter` (F1–F24), `CNPostalAddressFormatter` (P1–P14 with an open address-layout table), `CNContactVCardSerialization` (V1–V8, I1–I12) | C-CN-MODEL and C-CN-FORMAT pass on Linux |
| R3 | clean room | **Store and daemon**: schema, containers (fixed local identifier), groups, save requests with the atomicity and error rules of `interface.md` §5, identifiers, notifications in pairs | C-CN-STORE passes |
| R4 | clean room | **Fetch and search**: predicates and their matching rules, sort orders, enumeration, `CNFetchResult`, key descriptors | C-CN-FETCH passes (golden §4.2–§4.3) |
| R5 | clean room | **Change history**: tokens, events, authors, drop-everything, visitors | C-CN-HISTORY passes |
| R6 | clean room | **Authorization**: two-step UI, limited sets, implicit prompt, notes entitlement, `ycode-simctl privacy contacts / contacts-limited`, termination without usage string | C-CN-AUTH passes |
| R7 | clean room | **ContactsUI**: picker (with property selection and predicates), contact view controller (new, unknown, existing), SwiftUI `ContactAccessButton` and `contactAccessPicker` | C-CN-UI passes |
| R8 | clean room (optional) | CardDAV sync (RFC 6352) as a second container type | C-CN-SYNC against a local CardDAV server |
| R9 | simulator track + clean room | drop-in switch | whole suite passes with both stacks |

## 3. Conformance tests (golden values)

- **C-CN-MODEL**: constant values (`identifiers.md`); label localizations
  (`interface.md` §2.4); `CNPropertyInvalidTypeException` text pattern;
  new identifiers `<UUID>:ABPerson`; labeled-value identifier kept when the
  label changes.
- **C-CN-FORMAT**: `formats.md` §1.2 (24 rows), §2 (14 rows), §3.1 line
  tables for V1, V3, V4, V6, V7, V8 byte-exact except `PRODID`, §3.2 import
  table.
- **C-CN-STORE**: fresh store — 6 seed persons, groups Friends + Work,
  container `BC25D81B-8966-48EF-8FF9-D7389B6F89BD`; save table of
  `interface.md` §5 (201 duplicate, 200 for same-request group members,
  200 with `CNInvalidRecordIdentifiers` for an unknown container, double
  delete YES); two notifications per save.
- **C-CN-FETCH**: predicate table §4.2 (counts and members); sort tables
  §4.3; unknown identifier → nil + 200; note key without entitlement → 102.
- **C-CN-HISTORY**: 8 add events since the pre-data token, 5 excluding the
  author, nil token → drop-everything + 15 contacts + 3 groups.
- **C-CN-AUTH**: `authorization.md` §3–§6 (status matrix, prompt steps,
  limited visibility table, `simctl` table).
- **C-CN-UI**: `ui.md`.

## 4. Open questions

| Id | Question |
|---|---|
| C-CN-Q1 | Probe `ContactAccessButton` and `contactAccessPicker` with a Swift app (callbacks, identifiers returned, search behavior). |
| C-CN-Q2 | `predicateForContainerOfGroupWithIdentifier:` returned nothing for an app-created group — confirm with seed groups. |
| C-CN-Q3 | Exact field set of name matching (job title confirmed indirectly; department, note?). |
| C-CN-Q4 | `auth_reason` values in TCC for prompt answers vs `simctl` (both 4 for contacts; 2 for calendar prompts). |
| C-CN-Q5 | Behavior of `unifyResults` with linked contacts (no public way to link; needs seeded links). |

## Evidence

Plan is Ycode's own; golden values are level 3 from the topic files.
