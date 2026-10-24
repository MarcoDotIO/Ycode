# EventKit spec: errors and exceptions

Part of `specs/frameworks/eventkit/`. Codes and names are from the SDK
(level 4, full table in `identifiers.md`); which call produces which code,
and the message text, were observed with `EKProbe` on iOS 27.1 (level 3).
Errors are `NSError` in domain `EKErrorDomain` (string value
`EKErrorDomain`); the only user-info key observed is
`NSLocalizedDescription`.

## 1. Codes (`EKErrorCode`)

0 event not mutable · 1 no calendar · 2 no start date · 3 no end date ·
4 dates inverted · 5 internal failure · 6 calendar read-only · 7 duration
greater than recurrence · 8 alarm greater than recurrence · 9 start date too
far in future · 10 start date collides with other occurrence · 11 object
belongs to different store · 12 invites cannot be moved · 13 invalid span ·
14 calendar has no source · 15 calendar source cannot be modified ·
16 calendar is immutable · 17 source does not allow calendar add/delete ·
18 recurring reminder requires due date · 19 structured locations not
supported · 20 reminder locations not supported · 21 alarm proximity not
supported · 22 calendar does not allow events · 23 calendar does not allow
reminders · 24 source does not allow reminders · 25 source does not allow
events · 26 priority is invalid · 27 invalid entity type · 28 procedure
alarms not mutable · 29 event store not authorized · 30 OS not supported ·
31 invalid invite reply calendar · 32 notifications collection flag not set ·
33 source mismatch · 34 notification collection mismatch · 35 notification
saved without collection.

## 2. Observed errors

| Situation | Code | `localizedDescription` (en) |
|---|---|---|
| save an event or reminder with no calendar (also: no access, so the default calendar is nil) | 1 | "No calendar has been set." |
| save an event without start | 2 | "No start date has been set." |
| save an event without end | 3 | "No end date has been set." |
| end before start | 4 | "The start date must be before the end date." |
| save into the Birthdays calendar | 6 | "The calendar is read only." |
| save an event created with another store instance | 11 | "That event does not belong to that event store." |
| save a calendar without source (also: without access) | 14 | "Calendar has no source" |
| remove the Birthdays calendar; create a calendar with write-only access | 17 | "That account does not allow calendars to be added or removed." |
| recurring reminder without due date | 18 | "A repeating reminder must have a due date." |
| event into a reminder list | 22 | "That calendar does not allow events to be added." |
| reminder into an event calendar | 23 | "That calendar does not allow reminders to be added." |
| reminder priority 12 | 26 | "Priorities must be between 0 and 9." |

The messages are localized resources of Apple's framework; Ycode writes its
own English strings with the same meaning (the codes are the contract). Apps
in the wild do compare codes, rarely strings.

Not produced although the code exists (observed acceptances): 7 (duration
longer than the recurrence interval), 8 (alarm before the previous
occurrence), 9 (start in year 4100), 10 (occurrence moved onto the next one),
13 (span value 7). Without authorization, no call returned 29: reads are
empty and writes fail with 1 or 14 (`authorization.md` §4).

## 3. Exceptions

| Call | Exception | Reason (observed) |
|---|---|---|
| `EKRecurrenceRule` with interval ≤ 0 | `NSInvalidArgumentException` | "Interval must be greater than 0" |
| `EKRecurrenceEnd recurrenceEndWithOccurrenceCount:0` | `NSInvalidArgumentException` | "occurrenceCount == 0" |
| `EKRecurrenceDayOfWeek` with weekday outside 1…7 | `NSInvalidArgumentException` | "Invalid day number" |
| `predicateForEventsWithStartDate:nil …` | `NSInvalidArgumentException` | names the method, then "startDate is nil" |
| an access request without the matching usage string | none — completion with NO, no error (`authorization.md` §3) | — |

Not raising (observed): lookups with unknown identifiers return nil;
setting `priority` 10 on a reminder object (rejected only at save).

## Evidence

| Claim | Level |
|---|---|
| Domain and code names/values | 4 |
| Which situation yields which code, message texts | 3 |
| Codes not produced | 3 |
| Exceptions and reasons | 3 |
