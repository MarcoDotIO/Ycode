# EventKit spec: object model and store interface

Part of `specs/frameworks/eventkit/`. Type and member names are interop facts
(level 4, full list in `api-inventory.md`); descriptions are ours. Observed
behavior (level 3) is from `EKProbe` on the iOS 27.1 simulator, time zone
America/New_York, locale en_US. Reminders have their own file
(`reminders.md`), recurrence too (`recurrence.md`), authorization too
(`authorization.md`).

## 1. Classes

| Class | Superclass | Role |
|---|---|---|
| `EKEventStore` | `NSObject` | connection to the calendar database; every object belongs to exactly one store instance |
| `EKObject` | `NSObject` | base of model objects: `hasChanges`, `isNew`, `reset`, `rollback`, `refresh` |
| `EKSource` | `EKObject` | an account (local, CalDAV, Exchange, subscribed, birthdays) owning calendars |
| `EKCalendar` | `EKObject` | a calendar (events) or a list (reminders) |
| `EKCalendarItem` | `EKObject` | common part of events and reminders: identifiers, calendar, title, location, notes, URL, dates of creation/modification, time zone, alarms, recurrence rules, attendees |
| `EKEvent` | `EKCalendarItem` | timed or all-day event |
| `EKReminder` | `EKCalendarItem` | to-do item (`reminders.md`) |
| `EKAlarm` | `EKObject` | relative or absolute alarm, optionally location-based |
| `EKStructuredLocation` | `EKObject` | titled location with coordinates and radius |
| `EKParticipant` | `EKObject` | attendee or organizer (read-only for apps) |
| `EKRecurrenceRule`, `EKRecurrenceEnd`, `EKRecurrenceDayOfWeek` | `EKObject` / `NSObject` | recurrence (`recurrence.md`) |
| `EKVirtualConferenceProvider`, `EKVirtualConferenceDescriptor`, `EKVirtualConferenceURLDescriptor`, `EKVirtualConferenceRoomTypeDescriptor` | `NSObject` | extension point for conferencing apps (iOS 15; level 1 only, not probed) |

EventKitUI: `EKEventViewController`, `EKEventEditViewController`
(a `UINavigationController`), `EKCalendarChooser`, with delegate protocols
(`ui.md`).

## 2. The store

### 2.1 Creating and identity

- `[EKEventStore new]` (or `init`) may be created before any authorization;
  without access it simply sees nothing (`authorization.md` §4).
- `initWithSources:` creates a store limited to given (delegate) sources
  (level 1; `delegateSources` was empty in the simulator).
- `eventStoreIdentifier`: nil without full event access; with full access the
  database's unique identifier (observed equal to the `_UniqueIdentifier`
  property of the device's `Calendar.sqlitedb`, `simulator-baseline.md` §5).
  Two store instances in one process share it.
- Many stores may be open; changes made through one become visible to the
  others after commit and trigger their change notification (§7).

### 2.2 Sources and calendars

| Member | Observed |
|---|---|
| `sources` | full access on a fresh device: "Default" (type 0 local) and "Other" (type 5 birthdays, identifier `______NativeStorePersistentID_______`, a fixed string). Reminders-only access: one source "Local" (type 0) with fixed identifier `3B242529-8F5D-47A1-9351-444101218C30` holding the reminder lists. Write-only: one virtual source (§2.3). No access: empty |
| `calendarsForEntityType:` | events: "Birthdays" (type 4, source Other, not modifiable, immutable) and "Calendar" (type 0, source Default, modifiable); reminders: "Reminders" (type 0) with fixed identifier `3C8C2A71-84BF-4C87-8EFD-BB4827650D15` on every device |
| `defaultCalendarForNewEvents` / `…Reminders` | "Calendar" / "Reminders"; nil without the matching access |
| `calendarWithIdentifier:` | nil for unknown identifiers (no exception) |
| `sourceWithIdentifier:` | level 1 |
| `[EKCalendar calendarForEntityType:eventStore:]` | new calendar: type 0, source nil, `allowsContentModifications` YES, color nil until saved, `allowedEntityTypes` = mask of the entity (1 event, 2 reminder), a fresh identifier |
| `saveCalendar:commit:error:` | needs a source (code 14 "Calendar has no source"); the store assigns a color on save (new event calendar: RGB 0.7961, 0.1882, 0.8784; new reminder list: 0.0, 0.4784, 1.0); renaming works |
| `removeCalendar:commit:error:` | removes the calendar and its items; on the Birthdays calendar code 17 ("That account does not allow calendars to be added or removed.") |

About an hour after the fresh device first booted, a third source
"Subscribed Calendars" (type 4, random identifier) with the calendar
"US Holidays" (type 3 subscription, `subscribed` YES, not modifiable)
appeared without any app action (inference: a holiday subscription the
system adds by itself, probably fetched over the network; not present on the
other device during its shorter life). Ycode may seed an equivalent
read-only holiday calendar of its own or none; apps must not depend on it.

Calendar properties observed: "Calendar" color RGB (0.0, 0.5333, 1.0),
Birthdays (0.5098, 0.5843, 0.6863), Reminders list (0.0, 0.4784, 1.0), all in
the device RGB color space; `supportedEventAvailabilities` 0 (none) for
local calendars; `subscribed` NO. Calendar and source identifiers other than
the fixed ones above are random UUIDs per device.

### 2.3 Write-only view

With write-only access (`authorization.md`) the store shows **one virtual
source and calendar** instead of the real ones:

| Object | Values |
|---|---|
| source | title "Account", type 2 (CalDAV), identifier `VIRTUAL_APP_SOURCE_UUID` |
| calendar | title "Calendar", type 1 (CalDAV), identifier `VIRTUAL_APP_CALENDAR_UUID`, immutable YES, allows modifications YES, color RGB (1.0, 0.2196, 0.2353), events only |

It is `defaultCalendarForNewEvents`. Saving an event into it succeeds and the
event lands in the real default calendar: the returned `eventIdentifier`
carries the real source's identifier as prefix. The app cannot read anything
back: `eventWithIdentifier:` and `calendarItemWithIdentifier:` return nil for
the event it just saved, fetches return nothing; but editing and removing the
object it still holds succeed. Creating a calendar fails with code 17.

### 2.4 Items and identifiers

| Identifier | Form (observed) | Stability |
|---|---|---|
| `calendarItemIdentifier` | UUID string, assigned when the object is created (before save) | local to the device; changes for detached occurrences |
| `eventIdentifier` | nil until saved; then `<source identifier>:<UUID>`; detached occurrences append `/RID=<seconds since 2001-01-01 UTC>` (`recurrence.md` §6) | stable while the event exists |
| `calendarItemExternalIdentifier` | before save the same as `calendarItemIdentifier`; after save the UUID part of `eventIdentifier` (events) or the `calendarItemIdentifier` (reminders) | meant to survive sync (level 1) |
| `UUID` | deprecated; non-nil on new objects | — |

Lookups: `eventWithIdentifier:` (nil for unknown strings), `calendarItemWithIdentifier:`
(returns the concrete class, `EKEvent`/`EKReminder`; nil for unknown),
`calendarItemsWithExternalIdentifier:` (array; one element for an event).

### 2.5 Saving, committing, resetting

- `saveEvent:span:error:` = `saveEvent:span:commit:YES error:`. Same for
  remove, reminders and calendars.
- With `commit:NO` the change is staged in the store instance: a fetch
  through the same store already returns it; `commit:` writes all staged
  changes at once and produces **one** change notification for the batch.
- After a successful save: `isNew` NO, `hasChanges` NO, `creationDate` and
  `lastModifiedDate` set, `status` 0, `organizer` nil, `hasAttendees` NO.
- Saving the same saved object again updates it (no duplicate).
- `rollback` on an object discards unsaved edits (`hasChanges` back to NO).
- `refresh` returns YES for an object that still exists.
- `reset` on the store: objects fetched earlier become **invalid** — their
  `eventIdentifier` reads nil (other properties keep their last values); they
  must be fetched again.
- Removing an item that was already removed returns YES (reminders, observed;
  events level 1 assumption the same).

## 3. Events

### 3.1 Properties and defaults

A new `[EKEvent eventWithEventStore:]` has: empty title, nil start/end,
`timeZone` = the process's default time zone, `allDay` NO, nil calendar,
`availability` −1 (not supported) until a calendar is set, `status` 0,
`isNew` YES, `hasChanges` YES, nil `eventIdentifier`, non-nil
`calendarItemIdentifier`. Other properties: `location`, `structuredLocation`,
`notes`, `URL`, `availability` (`EKEventAvailability`), `organizer`,
`attendees` (read-only for apps), `isDetached`, `occurrenceDate`,
`birthdayContactIdentifier` (for Birthdays-calendar events), `alarms`,
`recurrenceRules`. New events get **no default alarms** (observed for timed
and all-day events in a local calendar).

### 3.2 Time zones and floating events

- A timed event stores an absolute start/end plus `timeZone`. Setting a
  different `timeZone` on an existing event **keeps the absolute instants**
  and only changes the zone used for wall-clock display and recurrence
  (9:00 New York becomes 15:00 Berlin).
- `timeZone` nil makes the event **floating**: its wall-clock time is fixed
  and its absolute instant follows the reading process's default time zone
  (14:00 floating = 18:00Z in New York, 05:00Z in Tokyo, 12:00Z in Berlin,
  14:00Z in UTC, re-read through a new store after changing the default
  zone).
- All-day events are floating (`timeZone` nil after save).

### 3.3 All-day normalization (observed)

Saving with `allDay` YES rewrites the dates in the reader's zone:
start → 00:00:00 of the start's day; end → 23:59:59 of the last day, where
the last day is the day of (end − 1 s) but not earlier than the start day.

| Input start → end (local) | Stored start → end (local) |
|---|---|
| 10-07 00:00 → 10-07 00:00 | 10-07 00:00:00 → 10-07 23:59:59 |
| 10-10 00:00 → 10-12 00:00 | 10-10 00:00:00 → 10-11 23:59:59 |
| 10-13 15:30 → 10-13 16:30 | 10-13 00:00:00 → 10-13 23:59:59 |

### 3.4 Validation on save

See `errors.md` §2 for the codes. Observed acceptances (no error): zero
duration (start = end), duration longer than the recurrence interval,
alarm earlier than the previous occurrence, start in year 4100, start in
1800, an unknown span value.

### 3.5 Alarms and locations

- `alarmWithRelativeOffset:` (seconds before/after start, negative = before),
  `alarmWithAbsoluteDate:`. Setting `absoluteDate` on a relative alarm sets
  `relativeOffset` to 0; setting `relativeOffset` on an absolute alarm clears
  `absoluteDate`.
- Location alarms: `structuredLocation` + `proximity` (1 enter, 2 leave).
- `EKStructuredLocation locationWithTitle:` with `geoLocation` and `radius`
  (meters) round-trips; an event's `structuredLocation` also sets `location`
  to the title.
- Duplicate alarms are kept (two −900 s alarms read back as two).
- Read-back order (observed): location alarm, relative alarms, absolute
  alarm — Ycode returns alarms ordered by kind then value, the same way.

### 3.6 Fetching

- `predicateForEventsWithStartDate:endDate:calendars:` (nil calendars = all;
  nil start or end raises `NSInvalidArgumentException` with a reason naming
  the method and "startDate is nil"). Its description reads
  `CADEventPredicate start:<local short date/time>; end:…; cals:(null), exclusions:[], filterdOutTitles:[(null)], limit:0, randomize:NO`.
- `eventsMatchingPredicate:` returns occurrences (recurring events expanded,
  `recurrence.md`), synchronously, unordered (sort yourself).
  `enumerateEventsMatchingPredicate:usingBlock:` yields the same set.
- **Window rule** (observed): an event is returned when it overlaps
  [start, end] **inclusive at the window start**: an event ending exactly at
  the window start is included; an event starting exactly at the window end
  is not; an event that began before and ends after the window is included.
- **Four-year cap** (level 1, confirmed): the window is cut to four years from
  its start; a 10-year predicate from 2026-01-01 returned the 2028 and 2029
  occurrences but not 2030-02-28.

## 4. Participants

Apps cannot add attendees (no public setter); `EKParticipant` exposes `URL`,
`name`, `participantStatus`, `participantRole`, `participantType`,
`isCurrentUser`, `contactPredicate`. Local events have no organizer and no
attendees. Ycode needs attendee support only for seeded or synced data
(plan R6).

## 5. Change notification

`EKEventStoreChangedNotification` (string value equal to its name) is posted
**on the main thread** with the store as object, after every committed change
made by this or another store instance or process, roughly one per commit
(observed 47 notifications for 47 commits in the events phase; one for a
3-event batch; one after another store's save). The observed user-info keys
are `EKEventStoreChangeTypeUserInfoKey`, `EKEventStoreCalendarDataChangedUserInfoKey`,
`EKEventStoreRemindersDataChangedUserInfoKey` and
`EKEventStoreChangedObjectIDsUserInfoKey` (not declared in the SDK; apps
should not depend on them; Ycode provides the same keys with its own
values). Swift (iOS 26+): the overlay adds `EKEventStore.EventStoreChanged`,
a main-actor `NotificationCenter` message whose subject is the store and
whose name is the same notification, and the message identifier `.changed`.
These are the only public Swift-overlay additions in the 27.1 SDK.

## 6. Threads and queues

| Call | Completion/notification thread |
|---|---|
| `request…AccessTo…` completion | private queue, label `com.apple.NSXPCConnection.m-user.com.apple.calaccessd` (not main) |
| `fetchRemindersMatchingPredicate:completion:` | private queue `com.apple.eventkit.reminders.search` |
| store change notification | main thread |
| save/remove/fetch of events | synchronous on the caller's thread |

## Evidence

| Claim | Level |
|---|---|
| Class list, member names, superclasses | 4 |
| Sources, fixed identifiers, calendar properties and colors | 3 (two devices) |
| Write-only virtual source/calendar and read-back behavior | 3 |
| Identifier formats, lookups | 3 |
| Commit/batch/rollback/reset/refresh | 3 |
| Event defaults, time-zone and floating behavior, all-day normalization | 3 |
| Alarms and structured location round-trip | 3 |
| Predicate exception, window rule | 3 |
| Four-year window cap | 1 + 3 |
| Participants read-only, virtual conference classes | 1 + 4 |
| Notification thread, keys, counts | 3 (keys are undeclared observations) |
| Queues | 3 |
