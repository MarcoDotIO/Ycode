# EventKit spec: reminders

Part of `specs/frameworks/eventkit/`. Level 3 facts come from `EKProbe -phase
reminders` (app with full events and full reminders access) on the iOS 27.1
simulator; level 1 from Apple's public documentation in our words.

## 1. Model

`EKReminder` (subclass of `EKCalendarItem`) adds:

| Property | Type / meaning |
|---|---|
| `startDateComponents`, `dueDateComponents` | date components (calendar, optional time zone, year-month-day, optional hour-minute-second) |
| `completed` | BOOL |
| `completionDate` | date or nil |
| `priority` | 0 none, 1…4 high, 5 medium, 6…9 low (`EKReminderPriority`: none 0, high 1, medium 5, low 9) |
| inherited | `title`, `notes`, `URL`, `calendar` (a list), `timeZone`, `alarms`, `recurrenceRules`, identifiers |

Created with `[EKReminder reminderWithEventStore:]`: empty title, nil
start/due, not completed, priority 0, nil time zone, nil calendar.

Coupling of completion fields (observed on an unsaved object):
`completed = YES` sets `completionDate` to now; `completionDate = nil` sets
`completed` NO.

## 2. Lists and sources

Reminder lists are `EKCalendar` objects with `allowedEntityTypes` = 2. On a
fresh device there is one list, "Reminders", whose identifier
`3C8C2A71-84BF-4C87-8EFD-BB4827650D15` is the same on every device. With
full event access it is listed under the event source "Default"; with
reminders-only access under a source "Local" (type 0, identifier
`3B242529-8F5D-47A1-9351-444101218C30`, also fixed). New lists are created
with `calendarForEntityType:EKEntityTypeReminder` in the source of the
default list and get the system-blue color (0.0, 0.4784, 1.0).

In the reference runtime reminders are served by `remindd` (ReminderKit),
not by the calendar database (`simulator-baseline.md` §4); EventKit presents
them through the same API.

## 3. Saving

`saveReminder:commit:error:`, `removeReminder:commit:error:`.

| Case | Observed |
|---|---|
| due date only (2026-10-20, no time, no zone) | saved; reads back with gregorian calendar added; `startDateComponents` becomes the same day at 0:00:00 |
| due 10-21 09:30 and start 08:00 New York, one −600 s alarm | saved as given; `timeZone` New York; 1 alarm |
| due 10-02 12:00 floating, `completionDate` 10-03 12:00Z | saved completed; start = due |
| no dates, priority high | saved, priority reads 1 |
| due 10-22 07:00 New York, daily count 3 | saved; start = due |
| recurring without due date | code 18 "A repeating reminder must have a due date." |
| priority 12 | setter accepts the value; save fails with code 26 "Priorities must be between 0 and 9." |
| location alarm (leave, radius 100 m) without dates | saved, 1 alarm |
| no list | code 1 "No calendar has been set." |
| list = an event calendar | code 23 "That calendar does not allow reminders to be added." |
| remove twice | both return YES |

Rule (observed): when `startDateComponents` is unset, the stored start equals
the due components (with zero time fields added for a date-only due date).

## 4. Fetching

Asynchronous: `fetchRemindersMatchingPredicate:completion:` returns an opaque
fetch identifier; the completion runs on a private queue
(`com.apple.eventkit.reminders.search`) with an array (empty, not nil, when
there is no access). `cancelFetchRequest:` stops it — the completion of a
cancelled fetch was **not** called within 2 s.

| Predicate | Golden result (list with the reminders of §3) |
|---|---|
| `predicateForRemindersInCalendars:` (list) | all 7 |
| `predicateForIncompleteRemindersWithDueDateStarting:` 10-20 00:00 NY `ending:` 10-22 00:00 NY | only "due 10-21 09:30" (the date-only reminder due 10-20 is **not** included; inference: a date-only due date is compared as midnight UTC, which is before the window start in New York — to be confirmed, plan C-REM-Q1) |
| incomplete, nil, nil | the 6 incomplete reminders, including those without a due date |
| `predicateForCompletedRemindersWithCompletionDateStarting:nil ending:nil` | the 1 completed reminder |
| completed, window 10-03 00:00Z – 10-04 00:00Z | the completed reminder (completed 10-03 12:00Z) |

Predicate descriptions read `ReminderPredicate`.

## 5. Completing a recurring reminder

Daily, count 3, due 10-22 07:00; set `completed` YES and save:

1. The saved object keeps its `calendarItemIdentifier` but now describes the
   **next** occurrence: due 10-23 07:00, rule `COUNT=2`, not completed.
2. A **new** reminder appears: same title, due 10-22 07:00, completed, no
   rules.
3. The list now holds 8 reminders.

## 6. Notifications

Each committed reminder save posts `EKEventStoreChangedNotification`
(8 notifications for 7 reminder saves plus 1 list creation; failed saves post
none).

## Evidence

| Claim | Level |
|---|---|
| Property names, priority values | 4 |
| Defaults and completion coupling | 3 |
| Fixed list and source identifiers, source naming per access level | 3 (two devices) |
| Save table, error codes and messages | 3 |
| Start defaults to due | 3 |
| Fetch queue, cancel, predicate results | 3 |
| Date-only due date compared in UTC | inference from one observation (flagged) |
| Recurring completion behavior | 3 |
| remindd as backing service | 2 (launchd job, `simulator-baseline.md`) |
