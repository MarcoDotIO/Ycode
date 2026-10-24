# ycode-contacts — open Contacts

A clean-room, Linux-buildable reimplementation of Apple's Contacts framework,
written only from `specs/frameworks/contacts/` under the protocol in
`AGENTS.md`. Package `ycode-contacts`, library module `Contacts` (the
framework's module name, an interop identifier), so `import Contacts` source
compiles against it.

```
swift build && swift test          # macOS and Linux, Swift 6.4
```

## Status by round (`specs/frameworks/contacts/plan.md`)

| Round | State | What is here |
|---|---|---|
| R2 model and pure code | done | `CNContact` / `CNMutableContact` with key availability and `CNPropertyNotFetchedException`; `CNPropertyInvalidTypeException` for wrongly typed labeled values; labeled values with stable identifiers; value classes; every string constant of `identifiers.md`; label and key localization; `CNContactFormatter` (F1–F24); `CNPostalAddressFormatter` (P1–P14); vCard 3.0 writer and a lenient 2.1/3.0/4.0 reader (`formats.md` §3) |
| R3 store | done (no daemon) | our own SQLite schema; the local container with its fixed identifier; groups Friends and Work with the fixed seed identifiers; Ycode's own made-up seed of six persons; atomic save requests with the error rules of `interface.md` §5; two change notifications per save |
| R4 fetch and search | done | predicates and their matching rules (§4.2), sort orders (§4.3), `enumerateContacts`, `CNFetchResult`, key descriptors, the notes-key rule (102) |
| R5 change history | done | history tokens, coalesced add/update/delete events, group and membership events, excluded authors, drop-everything, the visitor |
| R6 authorization | deferred | statuses come from the store configuration (recorded answers, as in `ycode-eventkit`); requests answer from it; no prompts, no usage-string termination, no `simctl privacy` verbs; limited access filters by the configured identifier set plus the app's own contacts |
| R7–R9 | not started | ContactsUI, CardDAV, guest drop-in |

The guest side of R3 (a daemon and XPC, `design.md` §3) is not built: on
Linux every store opens the same SQLite file (WAL mode) directly.

## Tests

Swift Testing; each suite and test names the spec section it checks. 76 tests
(F1–F24 and P1–P14 run as parameterized cases).

| File | Spec |
|---|---|
| `ModelTests.swift` | C-CN-MODEL: `identifiers.md` constants (all 309, read from the generated table) and enumerations, `errors.md` §1 codes, `interface.md` §2.2–§2.4 (keys, exceptions, identifiers, labeled values, localization) |
| `FormatterTests.swift` | C-CN-FORMAT: `formats.md` §1.2 F1–F24 (string, order, delimiter, attributed runs, phonetic style) and §2 P1–P14 |
| `VCardTests.swift` | C-CN-FORMAT: `formats.md` §3.1 line mapping (byte-exact except `PRODID`), §3.2 I1–I12, the round trip |
| `StoreTests.swift` | C-CN-STORE: fresh store, containers and groups (§3), the save table (§5), images (§2.5), notifications (§6.1), recorded access levels |
| `FetchTests.swift` | C-CN-FETCH: predicate table §4.2, sort tables §4.3, fetch calls §4.1 |
| `HistoryTests.swift` | C-CN-HISTORY: §6.2 |

## Dependencies

| Dependency | Licence | How |
|---|---|---|
| SQLite 3 | public domain | the system library (`libsqlite3` in the macOS SDK; `libsqlite3-dev` on Linux), through the `CSQLite` system-library target |
| Foundation, Dispatch, Swift Testing | Apache-2.0 (Swift project) | the toolchain |

No other packages. The vCard reader and writer are written from RFC 2426 /
RFC 6350 and the spec; no vCard library is used or vendored.

## The module name on macOS

The library module is called `Contacts`. Inside this package's own build
SwiftPM puts the package's module directory ahead of the SDK, so the tests'
`import Contacts` resolves to this module and nothing links Apple's
framework; no workaround was needed. Do not add this package to a target that
also needs Apple's Contacts.

## Ycode-specific API

- `YcodeContactStoreConfiguration` (database URL, recorded authorization
  status, limited identifier set, bundle identifier, country code) and
  `CNContactStore(ycodeConfiguration:)`; `CNContactStore.ycodeDefaultConfiguration`
  backs `CNContactStore()` and `authorizationStatus(for:)`. The default
  database is `$YCODE_CONTACTS_DATABASE`, else `ycode-contacts/AddressBook.sqlite`
  under `$XDG_DATA_HOME` / `~/.local/share` (Linux) or Application Support
  (macOS). The default status is full access.
- `YcodeContactsEnvironment.notesEntitlement` (default no) stands for the
  `com.apple.developer.contacts.notes` entitlement;
  `YcodeContactsEnvironment.$notesOverride` overrides it per task (tests).
- `CNException` and `CNException.catching { … }` (see Exceptions below).
- `CNKeyDescriptor` has one requirement, `_cnKeys` (the plain keys); `String`
  and `NSString` conform, so `CNContactGivenNameKey as CNKeyDescriptor` works
  on both platforms.

## Behavior notes and deviations

- **Exceptions.** Swift cannot raise Objective-C exceptions portably. A raise
  stops the process (`fatalError`) with "<name>: <reason>". Inside
  `CNException.catching { … }` it is recorded instead: the offending getter
  returns an empty value, the setter does nothing, and `catching` throws the
  `CNException` (name and reason as in `errors.md` §3).
- **Wrongly typed labeled values** can only be expressed through key-value
  setting: `CNMutableContact.setValue(_:forKey:)` checks the class and raises
  `CNPropertyInvalidTypeException`. On Linux (no KVC in Foundation)
  `value(forKey:)` and `setValue(_:forKey:)` are plain methods of the classes.
- **Predicates.** The constructors return an `NSPredicate` subclass that the
  store matches with its own rules. Other predicates are evaluated with
  `evaluate(with:)` on full contact objects: block predicates work on both
  platforms; format-string predicates are not available in Foundation on
  Linux.
- **Enumerators.** `enumerator(for:)` returns `CNFetchResult<NSEnumerator>`
  (Foundation's `NSEnumerator` is not generic in Swift); `value.nextObject()`
  yields `CNContact` or `CNChangeHistoryEvent` objects.
- **Not determined.** Without the R6 broker there is no implicit prompt: data
  calls while the recorded status is not determined, denied or restricted
  fail with code 100. `defaultContainerIdentifier()` and
  `currentHistoryToken` work at every level.
- **Thumbnails.** Ycode does not decode images; the stored thumbnail is the
  image data itself (the reference generated a smaller image).
- **History tokens** are Ycode's own (`YCNH1:<database id>:<sequence>` as
  UTF-8); apps treat them as opaque. Events are coalesced per record since
  the token: added (and still present) → add event with the current contact;
  added and deleted → nothing; existing and changed → update; existing and
  deleted → delete. Membership changes are reported as recorded.
- **Notifications.** First on the saving thread with
  `CNNotificationSaveIdentifiersKey` = [save request id, store id] and
  `CNNotificationSourcesKey` = [bundle identifier, process name]; then on the
  main queue with empty arrays and `CNNotificationOriginationExternally` = 1.
  Commits by other processes are found by polling the change journal every
  200 ms and posted as the main-queue form.
- **Unification.** Every contact is its own unified contact (`interface.md`
  §4.4); `unifyResults` has no effect.
- **Postal layouts.** The countries of `formats.md` §2 follow its rows; the
  other entries of the layout table (nz, at, ch, nl, be, the Nordic
  countries, pl, pt, es, it, ie, mx) are Ycode's reading of common national
  practice, not verified against the reference.
- **vCard.** `PRODID:-//Ycode//Ycode Contacts 1.0//EN`. Export of a contact
  without the required keys logs "Exception writing contacts to vCard
  (data): …" and throws `CNError` 701 (Apple returns nil there). Types for
  labels the spec does not list are Ycode's: work fax `WORK;FAX`, pager
  `PAGER`; other predefined labels (other, school, other fax, …) are written
  through an `itemN.` group with `X-ABLabel`. Instant-message services other
  than AIM and Jabber use Ycode's choice of `X-` property and URI scheme.

## Storage

Our own schema (`design.md` §4): `meta`, `container`, `contact` (one column
per scalar property; image and thumbnail blobs; birthdays as JSON),
`multivalue` (contact, property, ordinal, identifier, label, value), `grp`,
`member`, `journal` (sequence, transaction, author, writer token, kind,
operation, record, group, container). The seed is Ycode's own made-up
address book with the reference's *shape*; only the container and the two
group identifiers are the reference's (interop facts, `interface.md` §2.3).

## Spec questions found while implementing

1. `plan.md` §3 names export cases V1, V3, V4, V6, V7, V8, but `formats.md`
   does not give their inputs. The tests check every row of the §3.1 mapping
   table with Ycode-made contacts instead.
2. `interface.md` §4.3: the family-order golden (Avery, Blake, then Avery
   with an organization) does not follow from the stated inference
   ("family + given + organization" gives Avery, Avery-with-org, Blake).
   Ycode sorts by the phonetic part of a name when it is set; the golden test
   assumes that c1 (the Avery with the organization) carried F19's phonetic
   names. The other explanation is that ties on the family name keep storage
   order. Which is it?
3. `interface.md` §6.2: "8 add events since the pre-data token, 5 with the
   author excluded" does not fit the save table, where the 7-contact request
   carried the author. The test reconstructs 3 authored + 5 unauthored adds.
   Also: are later updates of a contact added after the token folded into its
   add event (Ycode) or reported separately?
4. `formats.md` §3.2 I2: Ycode's lenient rule is "the first `NAME=value`
   parameter the reader does not know becomes the label, ahead of `TYPE`"
   (gives "VALUE" and "LABEL"). Is an unlabeled email nil or ""? (Ycode: "".)
5. `X-ALTBDAY`: the one example is `-57500718`. Ycode always writes the
   minus sign and ignores it when reading. What does the sign mean?
6. Save rules: membership changes are checked against the records as they
   were before the request (the group-in-same-request row). Does the same
   hold for a contact added in the same request (Ycode: yes, it fails)?
7. The contents of the two-element arrays in the change notification are not
   observed; Ycode's choice is listed above.
8. C-CN-Q2: Ycode answers `predicateForContainerOfGroupWithIdentifier:` with
   the group's container (the observation returned nothing).
9. What does `CNInvalidRecords` hold for the 102 notes error? (Ycode: empty.)
10. History from a nil token: are group add events included only with
    `includeGroupChanges` (Ycode) or always?
11. `localizedStringForKey:` returned nil for three keys; Ycode's Swift API
    returns `String` and gives "" there.
12. C-CN-Q3: name search covers given, middle, family, nickname,
    organization, job title and the phonetic fields (`design.md` §4);
    department, previous family name and note are not searched.
