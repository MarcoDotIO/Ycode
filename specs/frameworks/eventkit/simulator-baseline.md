# EventKit spec: baseline behavior in Apple's iOS Simulator

Part of `specs/frameworks/eventkit/`. What an EventKit app sees in the
reference simulator (Xcode 27.1; iOS 27.1 runtime 24A94401 on an iPhone Duo;
Apple-silicon Mac). Ycode's simulator must behave the same way first.
Statements are level 3 (`EKProbe`, observations in
`research/notes/eventkit-contacts-simulator-observations-2026-10-20.md`)
unless marked.

## 1. Summary

EventKit **works fully** in the simulator without any account: calendars,
events, recurrence, alarms, reminders and lists can be created, fetched,
changed and deleted; the three iOS 17+ access prompts appear and work;
data persists in the device's `Library`. EventKitUI's controllers present.
There is no Calendar or Reminders **app** in the 27.1 runtime:

| | iOS 27.1 (24A94401) | iOS 27.0 (24A434), iOS 26.5 (23F77) |
|---|---|---|
| `MobileCal.app` (Calendar), `Reminders.app` | **absent** from `RuntimeRoot/Applications` (level 2) | present (level 2) |
| `EventViewService.app` (hidden remote view service) | present | present |
| calendar and reminder daemons | present | present |
| home screen of a fresh device | Settings and Safari only | (not inspected) |

So on 27.1 nothing but apps and Settings can show or edit calendar data; the
Birthdays calendar is the only seeded content (from the seeded contacts).

## 2. Fresh-device state

| Item | Value |
|---|---|
| Event sources | "Default" (local, type 0; random identifier), "Other" (birthdays, type 5; identifier `______NativeStorePersistentID_______`) |
| Event calendars | "Calendar" (local, default for new events), "Birthdays" (type 4, read-only, from contacts' birthdays) |
| Reminder lists | "Reminders" (`3C8C2A71-84BF-4C87-8EFD-BB4827650D15`, the same on every device) |
| Upcoming events shown by the access prompt | 4 birthday events in the next year, first "Kate Bell's 49th Birthday" on 2027-01-20 (seed contact) |
| Default alarms for new events | none |
| Later (about an hour after first boot) | a source "Subscribed Calendars" with the read-only subscription calendar "US Holidays" appeared on its own (`interface.md` §2.2) |
| Time zone / locale of the probe | America/New_York (the Mac's), en_US |
| `eventStoreIdentifier` | the calendar database's `_UniqueIdentifier` property |

## 3. Behavior summary (details in the topic files)

1. Authorization (`authorization.md`): status 0 everywhere at first; the full
   calendar prompt (with a preview of the next event and a one-year count),
   the write-only prompt and the reminders prompt; denial is remembered;
   apps without the matching usage string get NO at once without a prompt;
   `simctl privacy grant calendar` gives full access.
2. Without access: no sources or calendars, empty fetches, saves fail with
   code 1, calendar saves with code 14; no exception, no crash.
3. Events, recurrence, alarms: `interface.md`, `recurrence.md` — every golden
   value there.
4. Reminders: `reminders.md`, served by `remindd`.
5. Change notifications arrive on the main thread about once per commit, also
   for changes from other store instances.
6. Persistence: everything survives app termination and relaunch (the
   `count` phase found the 62 probe occurrences after other runs); data lives
   in the device directory (§5).

## 4. Processes and services (level 2: launchd property lists in `RuntimeRoot/System/Library/LaunchDaemons`; level 3 where seen)

| Job label | Program | Mach services (names) | Notes |
|---|---|---|---|
| `com.apple.calaccessd` | `CalendarDaemon.framework/Support/calaccessd` | `com.apple.calaccessd`, `com.apple.calaccessd.xpc`, `com.apple.CalendarExtensionSupport`, `com.apple.corespotlight.daemon.calendar`, `com.apple.usernotifications.delegate.com.apple.mobilecal` | user `mobile`, on demand; the access-request completion arrives on the client's XPC connection to `com.apple.calaccessd` (queue label observed); launch events on notify names such as `_CalDatabaseChangedNotification`, `kCalEventOccurrenceCacheChangedNotification`, `SignificantTimeChangeNotification`, `com.apple.reminderkit.storeChanged`, `CalSyncClientBeginningMultiSave`/`…FinishedMultiSave` |
| `com.apple.remindd` | `/usr/libexec/remindd` | `com.apple.remindd`, `com.apple.remindd.userInteractive`, `com.apple.usernotifications.delegate.com.apple.reminders`, `com.apple.aps.remindd*` | RunAtLoad; alarms and location events as launch events |
| `com.apple.dataaccess.dataaccessd` | `DataAccess.framework/Support/dataaccessd` | `com.apple.dataaccess.dataaccessd` (+ push names) | account sync (CalDAV/Exchange); idle without accounts |
| `com.apple.tccd` | `TCC.framework/Support/tccd` | `com.apple.tccd` | privacy database and prompts |
| `com.apple.contactsd` | `Contacts.framework/Support/contactsd` | `com.apple.contactsd` … | source of the Birthdays calendar's data (`specs/frameworks/contacts/simulator-baseline.md`) |

System UI: the access prompts are system alerts (inferred to be shown by
the privacy system on behalf of `tccd`; the runtime keeps privacy icons such
as `kTCCServiceReminders@3x.png` in `tmp/com.apple.tccd`); EventKitUI's
controllers are covered in `ui.md`. Private frameworks involved (names only,
level 4): `CalendarDaemon`, `CalendarDatabase`, `CalendarFoundation`,
`CalendarUIKit`, `EventKitUICore`, `EventKitTCCUI`, `ReminderKit`,
`ReminderKitInternal`, `DataAccess`, `CalDAV`.

## 5. Where data lives (level 2, file names and formats only)

Per device under `<device>/data/`:

| Path | Format | Role (from names) |
|---|---|---|
| `Library/Calendar/Calendar.sqlitedb` (+ `-wal`, `-shm`) | SQLite 3, WAL, 47 tables (`Store`, `Calendar`, `CalendarItem`, `Recurrence`, `ExceptionDate`, `Alarm`, `Location`, `Participant`, `OccurrenceCache`, `OccurrenceCacheDays`, change tables per entity, client cursors …); properties table `_SqliteDatabaseProperties` with `_UniqueIdentifier`, `_ClientVersion` 20002, `BirthdayCalendarID`, an occurrence-cache window of ±2 years around creation | events and calendars; created at first boot |
| `Library/Calendar/Extras.db` | SQLite | auxiliary |
| `Library/Calendar/Notifications.Calendar.*` | small binary/plist files | alarm and notification bookkeeping |
| `Containers/Shared/AppGroup/<id>/Container_v1/Stores/Data-local.sqlite` (group `group.com.apple.reminders`), plus `Data-<UUID>.sqlite` | Core Data SQLite (`Z…` tables: `ZREMCDREMINDER`, `ZREMCDBASELIST`, `ZREMCDOBJECT`, …) | reminders (ReminderKit) |
| `Library/Caches/com.apple.remindd/Cache.db` | SQLite | remindd cache |
| `Library/TCC/TCC.db` | SQLite, table `access` | privacy grants (`authorization.md` §6) |

The seed rows of a fresh calendar database include placeholder calendar
names (`DEFAULT_CALENDAR_NAME`, `DEFAULT_TASK_CALENDAR_NAME`) that the
framework localizes to "Calendar"/"Reminders", and further birthday and
suggestion calendars that are not shown to apps without data. Ycode does not
need to read or write these formats with its own EventKit (`design.md`). It
needs only a writable, persistent `/var/mobile/Library` and app-group
containers for Apple's daemons.

## 6. `simctl privacy` and resets

`authorization.md` §7. Observed: `grant calendar` gives full access (3) even
without usage strings; `revoke` gives 2; `reset` gives 0; `grant reminders`
gives reminders 3. An app that holds only the write-only usage string
also gets **full** access (3) from `grant calendar` (there is no write-only
service in `simctl`).

## 7. Conformance checklist

Each row: the probe phase (`EKProbe -phase <p>`, variant in brackets) and
the expected result on the reference. A Ycode simulator running Apple's
runtime and a Ycode EventKit must both produce it. Identifiers differ per
device except the fixed ones named.

| # | Probe | Expected |
|---|---|---|
| K1 | `basic` (no access) | statuses 0/0; no sources; save → code 1; calendar save → 14; reminders fetch → empty array; rule texts and the three exceptions of `recurrence.md` §2–3; alarm and structured-location field coupling |
| K2 | `reqfull` | full-access prompt with preview and count; Allow → granted YES, status 3; second call → immediate YES |
| K3 | `reqrem` | reminders prompt; Don't Allow → status 2; second call → immediate NO |
| K4 | `reqwo` [WO] | write-only prompt; Allow → status 4 |
| K5 | `reqfull` [WO, no full key] and [None] | immediate NO, nil error, no prompt, status unchanged |
| K6 | `reqlegacy` [Legacy] | full-access prompt with the legacy string, then the reminders prompt; both Allow → 3/3 |
| K7 | `status` after each `simctl privacy` verb | the table of `authorization.md` §7 |
| K8 | `wo` [WO] | virtual source/calendar of `interface.md` §2.3; save works, read-back nil, fetch empty, calendar creation → 17 |
| K9 | `events` | sources and calendars of §2; all golden expansions R1–R15, edits, splits, future-delete `UNTIL`, all-day and floating rules, alarms, batch commit with one notification, rollback, reset, window edges, four-year cap, the error table of `errors.md` §2 |
| K10 | `reminders` | the save and fetch tables of `reminders.md`; recurring completion; cancel; double remove YES |
| K11 | `count` after relaunch | the probe's calendar is present with the same number of occurrences |
| K12 | `uiedit` [None], `uiview`, `uichooser` | controllers present (`ui.md`) |

## Evidence

| Claim | Level |
|---|---|
| App presence per runtime | 2 |
| Home screen content | 3 (screenshot) |
| Fresh-device sources, calendars, fixed identifiers | 3 (two devices) |
| Daemon programs, Mach service names, launch events | 2 |
| Completion queue naming `calaccessd` | 3 |
| Private framework names | 4 |
| File locations, table names, properties | 2 |
| Behavior summary | 3 |
