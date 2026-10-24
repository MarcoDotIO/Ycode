# Contacts spec: baseline behavior in Apple's iOS Simulator

Part of `specs/frameworks/contacts/`. What a Contacts app sees in the
reference simulator (Xcode 27.1; iOS 27.1 runtime 24A94401 on an iPhone Duo;
Apple-silicon Mac). Statements are level 3 (`CNProbe`, observations in
`research/notes/eventkit-contacts-simulator-observations-2026-10-20.md`)
unless marked.

## 1. Summary

Contacts **works fully** in the simulator without any account: the store
holds six sample contacts and two groups from the device template; apps can
fetch, search, create, update, delete, group and serialize contacts; the
two-step iOS 18+ access prompt (with the limited-access picker) works;
change history and notifications work; ContactsUI controllers present.
There is no Contacts **app** in the 27.1 runtime:

| | iOS 27.1 (24A94401) | iOS 27.0 (24A434), iOS 26.5 (23F77) |
|---|---|---|
| `Contacts.app` | **absent** (level 2) | present (level 2) |
| `PeopleViewService.app` (`com.apple.PeopleViewService`, hidden) | present | present |
| `LimitedAccessPromptView.app` (`com.apple.ContactsUI.LimitedAccessPromptView`, hidden) | present | present |
| `ContactPhotoCarouselRemoteAlert.app` (`com.apple.ContactsUI.Carousel`, hidden) | present | present |
| `contactsd` | present | present |

## 2. Fresh-device state

| Item | Value |
|---|---|
| Authorization | status 0 for every app |
| Container | one local container `BC25D81B-8966-48EF-8FF9-D7389B6F89BD` (type 1, name nil), the same on every device |
| Contacts | Kate Bell (Creative Consulting), Daniel Higgins, John Appleseed, Anna Haro, Hank Zakroff (Financial Services Inc.), David Taylor — identifiers are plain UUIDs; some have birthdays (they feed the Birthdays calendar, `specs/frameworks/eventkit/`) |
| Groups | Friends, Work (fixed identifiers, `interface.md` §2.3) |
| User defaults | sort order 3 (family name), country code "us" |
| Database | shipped in the device template (file dated before the device was created), level 2 |

Ycode ships its **own** made-up seed set with the same *shape* (a handful of
persons with names, phones, emails, addresses and birthdays, one with a
company, two groups), never Apple's records.

## 3. Behavior summary

1. Before authorization: `defaultContainerIdentifier` and the history token
   are available. On iOS 27.1 the first data call without a prior request
   shows the access prompt (implicit request) and waits for the answer.
2. Authorization (`authorization.md`): two-step prompt; full or limited
   (status 3 / 4); `simctl privacy grant contacts` and `grant
   contacts-limited` **both** give status 3.
3. Data: `interface.md` — all golden fetch, sort, save and history results.
4. Formatting and vCard: `formats.md` — need no authorization.
5. Notifications: two per save (saving thread, then main thread with
   "originated externally").
6. Persistence: contacts survive relaunch; limited grants survive.

## 4. Processes and services (level 2: launchd property lists; level 3 where seen)

| Job label | Program | Mach services (names) | Notes |
|---|---|---|---|
| `com.apple.contactsd` | `Contacts.framework/Support/contactsd` | `com.apple.contactsd`, `com.apple.contactsd.contact-provider`, `com.apple.contactsd.launch-services-proxy`, `com.apple.contactsd.support`, `com.apple.askto.client.com.apple.contacts.commlimits` | user `mobile`, on demand; launch events on notify names `__ABDataBaseChangedByOtherProcessNotification`, `CNContactStoreLimitedAccessDidChangeNotification`, `com.apple.LaunchServices.database`, and the distributed notification `com.apple.LaunchServices.applicationUnregistered` |
| `com.apple.contacts.postersyncd` | `Contacts.framework/Support/postersyncd` | `com.apple.contacts.poster.api`, `com.apple.aps.contacts.postersyncd` | contact posters |
| `com.apple.peopled` | `People.framework/peopled` | `com.apple.people.agent`, `com.apple.corespotlight.daemon.people` | RunAtLoad |
| `com.apple.tccd` | `TCC.framework/Support/tccd` | `com.apple.tccd` | privacy |
| `com.apple.dataaccess.dataaccessd` | `DataAccess.framework/Support/dataaccessd` | `com.apple.dataaccess.dataaccessd` | CardDAV/Exchange sync (idle) |

ContactsUI extensions in `ContactsUI.framework/PlugIns` (level 2: bundle
identifier, extension point):

| Bundle | Identifier | Extension point |
|---|---|---|
| `ContactsViewService.appex` | `com.apple.ContactsUI.ContactsViewService` | `com.apple.people-picker` (the out-of-process contact picker) |
| `ContactViewViewService.appex` | `com.apple.ContactsUI.ContactViewViewService` | `com.apple.contact-view` |
| `OnboardingPromptExtension.appex` | `com.apple.ContactsUI.CNOnboardingPromptExtension` | `com.apple.internal.springboard.cfusernotification` (inferred: the two-step access prompt) |
| `FullAccessSettingsPromptExtension.appex` | `com.apple.ContactsUI.FullAccessSettingsPromptExtension` | same |
| `MonogramPosterExtension.appex` | `com.apple.ContactsUI.MonogramPosterExtension` | `com.apple.posterkit.provider` |

`Contacts.framework/PlugIns/ContactsCoreSpotlightExtension.appex` indexes
contacts for search. Private frameworks (names only): `ContactsFoundation`,
`ContactsPersistence`, `ContactsUICore`, `ContactsAutocomplete`,
`ContactsDonation`, `AddressBookLegacy`, `People`, `PeopleUI`.

## 5. Where data lives (level 2, names and formats only)

| Path under `<device>/data/` | Format | Role |
|---|---|---|
| `Library/AddressBook/AddressBook.sqlitedb` (+ `-wal`, `-shm`) | SQLite 3, WAL, 38 tables: `ABPerson`, `ABMultiValue`, `ABMultiValueEntry`, `ABMultiValueLabel`, `ABGroup`, `ABGroupMembers`, `ABStore`, `ABAccount`, `ABPersonLink`, `ABPersonChanges`/`ABGroupChanges`, full-text-search tables, `LimitedAccess`, client cursors and sequences; properties table `_SqliteDatabaseProperties` (`_UniqueIdentifier`, `_ClientVersion` 109, sorting-cache keys) | the contacts database (template copy at device creation) |
| `Library/AddressBook/AddressBookImages.sqlitedb` | SQLite | contact images |
| `Library/TCC/TCC.db`, table `access`, service `kTCCServiceAddressBook` | SQLite | grants: `auth_value` 2 full, 3 limited, 0 denied (`authorization.md` §5) |

The `LimitedAccess` table has columns (bundle identifier, contact guid,
sequence number, active flag), primary key (bundle, guid), and triggers
that drop rows when a contact is deleted and move rows to the surviving
contact when a link is removed. Ycode's own Contacts keeps its own store
(`design.md`); for the baseline it only needs a writable, persistent
`/var/mobile/Library/AddressBook` seeded at device creation.

## 6. Conformance checklist

| # | Probe (`CNProbe -phase`, variant) | Expected |
|---|---|---|
| C1 | `basic` | all constant values of `identifiers.md`; label localizations; formatter table F1–F24; postal table P1–P14; vCard export V1–V8 and import I1–I12 of `formats.md`; `CNPropertyInvalidTypeException`; new contact identifier `<UUID>:ABPerson` |
| C2 | `status` fresh | 0 |
| C3 | `req` | two-step prompt; Continue → Share All → status 3, granted YES |
| C4 | `req` [Lim] | Continue → Select Contacts → picker → status 4, granted YES, only the chosen contacts (and the app's own) visible |
| C5 | `noaccess` | implicit prompt on the first data call |
| C6 | `data` | every row of `interface.md` §4–§6 |
| C7 | `data` [Lim] | the same calls with limited access: only granted and own contacts; groups all visible; history from a bogus token returns the full history |
| C8 | `basic` [Notes] | notes entitlement: note fetch allowed (status 3 when previously granted) |
| C9 | `status` after `simctl privacy` verbs | `authorization.md` §6 |
| C10 | `uipicker`, `uinew`, `uiunknown` | `ui.md` |
| C11 | relaunch, `list` | data and limited grants persist |

## Evidence

| Claim | Level |
|---|---|
| App and service presence per runtime | 2 |
| Seed data, container identifier | 2 (database) + 3 (API) |
| Daemons, Mach services, launch events, extension points | 2 |
| Behavior summary | 3 |
| Table names, columns of `LimitedAccess`, triggers, properties | 2 |
