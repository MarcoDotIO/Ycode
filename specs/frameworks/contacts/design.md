# Contacts spec: Ycode design note (original)

Part of `specs/frameworks/contacts/`. This file is **Ycode's own design**, not
a description of Apple's implementation.

## 1. Two targets

1. **Baseline**: Ycode's simulator runs Apple's runtime; Contacts,
   `contactsd`, `tccd` and the ContactsUI services are Apple's. Ycode provides
   the guest services of §2.
2. **Open Contacts / ContactsUI**: drop-in frameworks for the guest and a
   Linux Swift package with the same names (§3–§7).

## 2. Guest dependencies for the baseline

| # | Dependency | Why |
|---|---|---|
| G1 | `Library/AddressBook` seeded at device creation (Ycode's own made-up records, same shape as `simulator-baseline.md` §2) and persistent | the store and its seed |
| G2 | XPC to `com.apple.contactsd` and `com.apple.tccd` with client identity | per-app access and limited sets |
| G3 | system alerts **and** a full-screen system sheet over the app, both driven by user-notification-style extensions (`com.apple.internal.springboard.cfusernotification` extension point) | the two-step prompt |
| G4 | remote view services for `com.apple.people-picker` and `com.apple.contact-view` extensions | the picker and contact views (`ui.md`) |
| G5 | Darwin notifications and distributed notifications | change notifications, limited-access changes |
| G6 | a `simctl privacy` equivalent for `contacts` and `contacts-limited` | test automation |
| G7 | the simulated-entitlements section of app binaries honoured (`com.apple.developer.contacts.notes`) | notes access |

## 3. Architecture of the open implementation

```
app process                           ycode-contactsd
Contacts.framework  ── XPC ──>   access broker (full / limited set per bundle)
  model (immutable snapshots,       store (SQLite, our schema; FTS index for name search)
  key availability tracking)        change journal (history tokens, authors)
  formatters, vCard (pure code)     notification fan-out
ContactsUI.framework (in process; picker and views are our own UIKit code)
```

- Formatting, postal formatting and vCard live entirely in the framework
  (no daemon): pure functions over the model, testable on Linux.
- Key availability: each fetched contact carries the set of fetched keys;
  accessors check it and raise `CNPropertyNotFetchedException`.
- Identifiers: `<UUID>:ABPerson` / `<UUID>:ABGroup` for new records, plain
  UUIDs for seeded ones; the local container keeps the fixed identifier of
  the reference so that apps that stored it keep working.

## 4. Store and search

Our own SQLite schema: records, multi-values (label, value, identifier),
groups and memberships, containers, change journal with author and sequence,
limited sets (bundle → record identifiers). Name search: an FTS index over
given, middle, family, nickname, organization, job title and the phonetic
fields, tokenized by word, case- and diacritic-folded, queried as
word-prefix AND. Phone matching: digits-only comparison with the default
country code added when missing; no suffix matching. Email: case-folded
exact.

## 5. Sorting

Collation by ICU root/locale rules (open source, Unicode-3/ICU license) on
the key (family or given first per `sortOrder`) + organization; organization
contacts sort by organization; CJK after Latin as ICU orders scripts by
default.

## 6. Authorization and limited access

States per bundle: not determined, denied, limited (+ set), full. The broker
shows Ycode's two-step UI; "Select Contacts" opens Ycode's picker; the
result writes the set. Implicit prompt: a data call while not determined
starts the same UI and blocks the caller until answered. Limited views
filter every query by (set ∪ records created by the app); groups unfiltered.

## 7. ContactsUI

Ycode's `CNContactPickerViewController` runs in the app's process but only
returns what the user picked (the app never reads the store through it).
`ContactAccessButton` and `contactAccessPicker` are SwiftUI views from
Ycode's SwiftUI track that call the broker.

## Evidence

Design, not observation; it relies on the level 1–4 facts of the other files.
