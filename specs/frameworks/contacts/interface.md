# Contacts spec: object model, store, fetching and saving

Part of `specs/frameworks/contacts/`. Type, member and key names are interop
facts (level 4; full lists in `api-inventory.md`, string values in
`identifiers.md`); descriptions are ours. Level 3 facts come from `CNProbe`
(phases `basic` and `data`) on the iOS 27.1 simulator (locale en_US, region
US). Formatting and vCard are in `formats.md`, authorization and the limited
picker in `authorization.md`, UI in `ui.md`.

## 1. Classes

| Class | Role |
|---|---|
| `CNContactStore` | access to the contacts database: authorization, fetch, enumerate, save, containers, groups, change history |
| `CNContact` / `CNMutableContact` | a person or organization; immutable snapshot with only the fetched keys available |
| `CNLabeledValue` | a (label, value) pair with its own stable `identifier`, used for multi-valued properties |
| value classes | `CNPhoneNumber`, `CNPostalAddress`/`CNMutablePostalAddress`, `CNContactRelation`, `CNSocialProfile`, `CNInstantMessageAddress`; strings for emails and URLs; `NSDateComponents` for dates |
| `CNGroup` / `CNMutableGroup` | a named group of contacts inside a container |
| `CNContainer` | an account's collection (local, Exchange, CardDAV) |
| `CNSaveRequest` | a batch of adds, updates and deletes executed atomically |
| `CNFetchRequest`, `CNContactFetchRequest`, `CNChangeHistoryFetchRequest` | fetch descriptions |
| `CNFetchResult` | value + `currentHistoryToken` |
| `CNChangeHistoryEvent` and subclasses (`…DropEverythingEvent`, `…AddContactEvent`, `…UpdateContactEvent`, `…DeleteContactEvent`, `…AddGroupEvent`, `…UpdateGroupEvent`, `…DeleteGroupEvent`, `…AddMemberToGroupEvent`, `…RemoveMemberFromGroupEvent`, `…AddSubgroupToGroupEvent`, `…RemoveSubgroupFromGroupEvent`) with `CNChangeHistoryEventVisitor` | change history |
| `CNContactFormatter`, `CNPostalAddressFormatter`, `CNContactVCardSerialization` | `formats.md` |
| `CNContactProperty` | (contact, key, value, identifier, label) — what the picker returns for a property selection |
| `CNContactsUserDefaults` | `sortOrder`, `countryCode` (observed 3 = family name, "us") |

## 2. Contacts

### 2.1 Keys

Each property has a key string equal to its property name (`givenName` …),
except: `CNContactPropertyAttribute` = "contactProperty",
`CNContactPostalAddressesKey` = "postalAddresses",
`CNContactRelationsKey` = "contactRelations". A full list with values is in
`identifiers.md`. Composite descriptors (`CNKeyDescriptor`) come from
formatters (`descriptorForRequiredKeysForStyle:`, `…ForNameOrder`,
`…ForDelimiter`), from `CNContactVCardSerialization descriptorForRequiredKeys`
and from `CNContactViewController descriptorForRequiredKeys`; they describe
themselves as `<CNAggregateKeyDescriptor: …: kind=…>`.

### 2.2 Partial contacts

A fetched contact holds only the requested keys.

- `isKeyAvailable:` / `areKeysAvailable:` tell which keys are present.
- Reading an unfetched property raises `CNPropertyNotFetchedException`
  ("A property was not requested when contact was fetched.").
- Formatting a contact whose name keys were not fetched raises the same
  exception; vCard export of such a contact does **not** raise (it logs
  "Exception writing contacts to vCard (data): …" and returns nil).
- Setting an unfetched property on a mutable copy also raises it.
- `note` requires the `com.apple.developer.contacts.notes` entitlement:
  without it, fetching with the note key fails with code 102 "Unauthorized
  Keys" (`CNKeyPaths` = ["note"]), and setting `note` on a new contact raises
  `CNPropertyNotFetchedException`; a contact saved without a note is fine.
  Contacts built from vCard data have all keys available, note included.

### 2.3 Identifiers

| Object | Form (observed) |
|---|---|
| contact created by an app (or from vCard) | `<UUID>:ABPerson`, assigned when the object is created, unchanged by the save |
| contacts of the device seed data | plain UUIDs (no suffix), identical on every device (e.g. the seed "John Appleseed" is `410FE041-5C4E-48DA-B4DE-04C15EA3DBAC`) |
| group | `<UUID>:ABGroup` (seed groups: plain UUIDs, identical on every device: Friends `CCDA4756-71B4-4B25-8DD2-D3DA109F4561`, Work `2D6515F9-AE3D-460D-98A2-EFE81516739D`) |
| container | plain UUID (the local container on every fresh device: `BC25D81B-8966-48EF-8FF9-D7389B6F89BD`) |
| labeled value | plain UUID, created with the value; changing the label keeps the identifier (but the new object is not `isEqual:` to the old); kept across updates of the contact |

### 2.4 Multi-valued properties

`phoneNumbers`, `emailAddresses`, `postalAddresses`, `urlAddresses`,
`contactRelations`, `socialProfiles`, `instantMessageAddresses`, `dates` are
arrays of `CNLabeledValue`. Labels are either the predefined constants
(`_$!<Home>!$_` style, see `identifiers.md`; `iCloud`, `iPhone`,
`Apple Watch` are plain strings) or any custom string.
`localizedStringForLabel:` maps predefined labels to lower-case words in
en ("home", "work", "school", "other", "homepage", "anniversary", "mobile",
"main", "home fax", "work fax", "other fax", "pager", "iPhone", "iCloud",
"Apple Watch", "father", "mother", "spouse", …) and returns custom labels
unchanged. Putting a value of the wrong class into a labeled value of a
property raises `CNPropertyInvalidTypeException` naming the expected class
(e.g. a string in `phoneNumbers` → "It should be CNPhoneNumber.").

`localizedStringForKey:` gives field names ("First name", "Last name",
"Maiden name" for `previousFamilyName`, "Company", "Job title",
"Alternate calendar birthday", "Related name", "Social profile", "Instant
message", …; nil for `identifier`, `thumbnailImageData`,
`imageDataAvailable`). Postal: "Street", "District" (`subLocality`), "City",
"County" (`subAdministrativeArea`), "State", "ZIP", "Country", "Country
code". Social/IM services localize to themselves.

### 2.5 Images

Saving `imageData` (a 324-byte PNG) produced a stored image of 324 bytes, a
**generated thumbnail** of 172 bytes and `imageDataAvailable` YES.

## 3. Store: containers and groups

| Call | Observed |
|---|---|
| `defaultContainerIdentifier` | the local container's identifier, **also without access** |
| `containersMatchingPredicate:nil` | one container, name nil, type 1 (local) |
| `groupsMatchingPredicate:nil` | seed groups "Friends" and "Work"; visible also with limited access |
| `predicateForGroupsInContainerWithIdentifier:` | both seed groups and app groups |
| `predicateForContainerOfContactWithIdentifier:` | the default container |
| `predicateForContainerOfGroupWithIdentifier:` | empty result for a group created by the app (observed; open question C-CN-Q2) |

Seed data of a fresh simulator device (level 2, shipped in the device
template's `AddressBook.sqlitedb`): six persons — Kate Bell (Creative
Consulting), Daniel Higgins, John Appleseed, Anna Haro, Hank Zakroff
(Financial Services Inc.), David Taylor — and two groups, Friends and Work.
These are Apple's sample data; Ycode ships its **own** made-up seed set
(plan R1), not these records.

## 4. Fetching

### 4.1 Calls

- `unifiedContactWithIdentifier:keysToFetch:error:` — unknown or deleted
  identifier → nil with code 200 "Updated Record Does Not Exist".
- `unifiedContactsMatchingPredicate:keysToFetch:error:` — predicate from the
  `CNContact` predicate constructors. A plain `NSPredicate` (format string)
  was **accepted** and returned the matching contacts; a nil predicate
  returned all contacts.
- `enumerateContactsWithFetchRequest:error:usingBlock:` — synchronous;
  `CNContactFetchRequest` has `keysToFetch`, `predicate`, `sortOrder`,
  `unifyResults`, `mutableObjects` (YES yields `CNMutableContact`).
- `enumeratorForContactFetchRequest:error:` → `CNFetchResult` whose value is
  an enumerator and which carries a history token.

### 4.2 Predicate semantics (golden, data set of §4.4)

| Predicate | Matches |
|---|---|
| name "Example" | the 3 contacts with family name Example and the earlier "Noaccess Example" (4) |
| name "exam" | same 4 (case-insensitive **word-prefix** match) |
| name "xample" | none (no infix matching) |
| name "avery example", "Example Avery" | the two Avery Example contacts (all words must match, any order) |
| name "Ave" | the two Averys (given name prefix; c1 also has nickname "Ave") |
| name "Widgets" | the organization contact and c1 (organization "Example Widgets LLC") |
| name "Ycode Probe Widgets" | the organization contact **and c1** — c1's job title is "ycode-probe": the name search also covers the job title (inference) |
| name "山田", "やまだ" | the Japanese contact (phonetic names are searched) |
| name "Avéry" | the two Averys (diacritic-insensitive) |
| email "avery@example.com", "AVERY@EXAMPLE.COM" | both contacts with that address (case-insensitive, exact) |
| email "avery@example" | none |
| phone "5550100601", "+1 555-010-0601" | the contact stored as "(555) 010-0601" |
| phone "555 010 0602" | the contact stored as "+1 555 010 0602" (missing country code matches the region's) |
| phone "0100601" | none (no suffix matching) |
| phone "+44 20 7946 0000" | c1 |
| identifiers [c2, c3, "bogus"] | c2, c3 (unknown ignored) |
| in container (default) | everything visible |

### 4.3 Sort orders (golden)

Probe contacts (given/family/organization): Avery Example, Avery Example
(org Example Widgets LLC), Blake Example, Casey Sample, Pixel Probe,
organization "Ycode Probe Widgets", 太郎 山田.

| `sortOrder` | Order |
|---|---|
| 2 given name | Avery/Example, Avery/Example/Example Widgets LLC, Blake/Example, Casey/Sample, Pixel/Probe, //Ycode Probe Widgets, 太郎/山田 |
| 3 family name, 1 user default (= family) | Avery/Example, Blake/Example, Avery/Example/Example Widgets LLC, Pixel/Probe, Casey/Sample, //Ycode Probe Widgets, 太郎/山田 |
| 0 none | unspecified (storage order; differed between runs) |

Observations: the organization contact sorts by its organization name;
CJK names sort after Latin; among equal family names the order is not by
given name (Avery, Blake, then Avery with organization) — inference: the
sort key is "family + given + organization" collated, where the empty
organization of the first Avery sorts it first. Sorting of in-memory arrays
with `comparatorForNameSortOrder:` (basic phase, contacts not saved):

| Order | Result |
|---|---|
| 2 given | //Acme Org, alice/Adams, Alice/young, bob/Zed, Émile/Xavier, 山田/太郎 |
| 3 family, 1 default, 0 none | //Acme Org, alice/Adams, Émile/Xavier, Alice/young, bob/Zed, 山田/太郎 |

(case- and diacritic-insensitive; an organization-only contact sorts first,
CJK last.)

### 4.4 Unification

`unifyResults` YES/NO gave the same counts (no linked contacts exist);
`isUnifiedWithContactWithIdentifier:` is NO even for the contact's own
identifier on a fetched contact. Linking is not public API; Ycode treats each
contact as its own unified contact (plan R5 note).

## 5. Saving

`executeSaveRequest:error:` with a `CNSaveRequest`. Adds go to a container
(nil = default). Observed:

| Request | Result |
|---|---|
| add 7 contacts (one request, `transactionAuthor` set) | YES; identifiers unchanged by the save; `shouldRefetchContacts` defaults YES |
| update a fetched contact (change given name, add a phone) | YES; existing labeled-value identifiers stay |
| update a **partially** fetched contact | YES; unfetched properties are kept in the store |
| add a contact that already exists | NO, code 201 "Duplicate Record" |
| add group + add members to it in the **same** request | NO, code 200 "Updated Record Does Not Exist" — the whole request is rejected (no group created) |
| add the same group object again (separately) | YES — this is when the group got created |
| add member twice, remove a non-member, rename the group (request referring to the group created by the failed request) | NO, code 200 |
| add to a bogus container identifier | NO, code 200 with `CNInvalidRecordIdentifiers` |
| delete a contact; delete it again | YES; YES (second delete is a no-op) |
| update a deleted contact | NO, code 200 |
| request "add new contact + delete missing contact" | YES; the add is applied (deleting a missing record does not fail the request) |

Errors carry `CNInvalidRecords` (the affected records) and
`NSLocalizedFailureReason` (`errors.md`).

## 6. Change notification and history

### 6.1 `CNContactStoreDidChangeNotification`

Object nil. After each successful save request **two** notifications
arrive:

1. on the **thread that executed the save**, user info
   `CNNotificationSaveIdentifiersKey` (array of 2 in our runs) and
   `CNNotificationSourcesKey` (array of 2);
2. later on the **main thread**, with the same keys holding empty arrays and
   `CNNotificationOriginationExternally` = 1.

(The user-info keys are not declared in the SDK; apps should not depend on
them. Ycode posts the same pair.) With limited access the first
notification of a deletion also carried `CNNotificationOriginationExternally`.

### 6.2 Change history

- `currentHistoryToken`: opaque data (191–194 bytes observed), available even
  before authorization.
- `enumeratorForChangeHistoryFetchRequest:error:` with a
  `CNChangeHistoryFetchRequest` (`startingToken`, `shouldUnifyResults`,
  `mutableObjects`, `additionalContactKeyDescriptors`,
  `includeGroupChanges`, `excludedTransactionAuthors`) yields events.
- From the token taken before the data phase: 8 add-contact events; with our
  author excluded: 5 (the later saves had no author).
- From a nil token: one **drop-everything** event, then add events for every
  existing contact and group (15 contacts, 3 groups).
- A bogus token: zero events and no error (full access); with limited access
  the bogus token returned the complete history (12 events: 1 drop, 8 adds,
  3 group adds).

## Evidence

| Claim | Level |
|---|---|
| Classes, members, key names | 4 |
| Key string values | 3 |
| Partial-contact rules and exceptions | 3 |
| Notes entitlement effects | 3 |
| Identifier formats, fixed local container identifier | 3 (two devices) + 2 (seed database) |
| Labels and their localization, field names | 3 |
| Image thumbnail generation | 3 |
| Containers and groups results | 3 |
| Seed data names | 2 |
| Predicate semantics, sort orders | 3; job-title search and sort-key composition are inferences |
| Save results and error codes | 3 |
| Notification pairs and keys | 3 (keys undeclared) |
| History behavior | 3 |
