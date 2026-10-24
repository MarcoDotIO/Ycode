# EventKit spec: recurrence rules and occurrence expansion

Part of `specs/frameworks/eventkit/`. Level 3 facts come from `EKProbe`
(phases `basic` and `events`) on the iOS 27.1 simulator; level 1 from Apple's
public documentation and RFC 5545 (iCalendar), summarized in our words. The
rule model of EventKit is the RFC 5545 `RRULE` subset below; Ycode's engine
should be an RFC 5545 expander with the EventKit-specific rules of §4.

## 1. Model

A recurring item (event or reminder) carries an ordered list of rules
(`recurrenceRules`; `addRecurrenceRule:`, `removeRecurrenceRule:`,
`hasRecurrenceRules`). A rule (`EKRecurrenceRule`) has:

| Property | Meaning | RRULE part |
|---|---|---|
| `frequency` | 0 daily, 1 weekly, 2 monthly, 3 yearly (`EKRecurrenceFrequency`) | `FREQ` |
| `interval` | every N periods, N ≥ 1 | `INTERVAL` |
| `firstDayOfTheWeek` | week start used for weekly rules with interval > 1 and week numbers; reported as 2 (Monday) on new rules in the en_US locale | `WKST` |
| `recurrenceEnd` | nil (forever), or an end date, or an occurrence count | `UNTIL` / `COUNT` |
| `daysOfTheWeek` | array of `EKRecurrenceDayOfWeek` (weekday 1 = Sunday … 7 = Saturday, plus an optional week number, 0 = every) | `BYDAY` |
| `daysOfTheMonth` | 1…31 and −1…−31 | `BYMONTHDAY` |
| `monthsOfTheYear` | 1…12 | `BYMONTH` |
| `weeksOfTheYear` | 1…53 and −1…−53 | `BYWEEKNO` |
| `daysOfTheYear` | 1…366 and −1…−366 | `BYYEARDAY` |
| `setPositions` | ±1…366 | `BYSETPOS` |

Constructors: the short form (frequency, interval, end) and the long form
(frequency, interval, the six `BY` arrays, end). `EKRecurrenceEnd` has two
constructors (end date; occurrence count). `EKRecurrenceDayOfWeek` has
`dayOfWeek:` and `dayOfWeek:weekNumber:`.

## 2. Validation at construction (observed)

| Input | Result |
|---|---|
| interval 0 or negative | `NSInvalidArgumentException`, reason "Interval must be greater than 0" |
| occurrence count 0 | `NSInvalidArgumentException`, reason "occurrenceCount == 0" |
| weekday outside 1…7 (e.g. 9) | `NSInvalidArgumentException`, reason "Invalid day number" |
| week number outside ±53 (e.g. 60) | accepted; the description shows `60SU` |
| `BY` parts that RFC 5545 forbids for the frequency (BYDAY in daily, BYMONTHDAY in weekly, BYWEEKNO in monthly), out-of-range values (month day 32, month 13), set position 0, a week-numbered weekday in a weekly rule (`2MO`) | **accepted** at construction and kept in the text form; no exception |

Ycode must accept the same inputs (no stricter validation) and raise the same
three exceptions with these reasons.

## 3. Text form

`description` of a rule is `EKRecurrenceRule <0x…> RRULE ` followed by an
RFC 5545 value. Observed ordering of parts: `FREQ`, `INTERVAL` (always
present, also when 1), then `COUNT` or `UNTIL`, then `BYDAY`, `BYMONTHDAY`,
`BYMONTH`, `BYWEEKNO`, `BYYEARDAY`, `BYSETPOS`, then `WKST`.

| Rule built | Text after `RRULE ` |
|---|---|
| daily | `FREQ=DAILY;INTERVAL=1` |
| daily, interval 2, count 5 | `FREQ=DAILY;INTERVAL=2;COUNT=5` |
| weekly, until 2026-12-31 23:59 UTC | `FREQ=WEEKLY;INTERVAL=1;UNTIL=20261231T235900Z` |
| weekly MO,WE,FR | `FREQ=WEEKLY;INTERVAL=1;BYDAY=MO,WE,FR` |
| monthly 1, 15, −1 | `FREQ=MONTHLY;INTERVAL=1;BYMONTHDAY=1,15,-1` |
| monthly last Friday | `FREQ=MONTHLY;INTERVAL=1;BYDAY=-1FR` |
| monthly 2nd Tuesday | `FREQ=MONTHLY;INTERVAL=1;BYDAY=2TU` |
| monthly weekdays, set position −2 | `FREQ=MONTHLY;INTERVAL=1;BYDAY=MO,TU,WE,TH,FR;BYSETPOS=-2` |
| yearly March and September | `FREQ=YEARLY;INTERVAL=1;BYMONTH=3,9` |
| yearly week 20 Monday | `FREQ=YEARLY;INTERVAL=1;BYWEEKNO=20;BYDAY=MO` |
| yearly days 100, −1 | `FREQ=YEARLY;INTERVAL=1;BYYEARDAY=100,-1` |
| yearly 4th Thursday of November | `FREQ=YEARLY;INTERVAL=1;BYMONTH=11;BYDAY=4TH` |
| weekly, interval 2, TU,TH, count 6 (after save) | `FREQ=WEEKLY;INTERVAL=2;COUNT=6;BYDAY=TU,TH;WKST=MO` |

`UNTIL` is always written in UTC with a `Z` suffix and second precision.
`EKRecurrenceDayOfWeek` describes itself as `EKRecurrenceDayOfWeek <0x…> { -1SU }`;
`EKRecurrenceEnd` with a date as `EKRecurrenceEnd <0x…> { UNTIL=20261231T235900Z }`
(its `occurrenceCount` is 0 when an end date is set).

`WKST=MO` appeared only on the saved weekly rule with interval 2; rules with
interval 1 did not print it (Ycode: print `WKST` only for weekly rules with
interval > 1; open question whether other frequencies with `BYWEEKNO` print
it).

## 4. Normalization on save (observed, EventKit-specific)

1. **Monthly rule with no `BY` parts whose start is on day 29, 30 or 31**
   is stored as "last matching day": a plain monthly rule started on
   October 31 reads back as `BYMONTHDAY=28,29,30,31;BYSETPOS=-1`, so it
   occurs on the last day of shorter months (Nov 30, Feb 28). An explicit
   `BYMONTHDAY=31` is kept and **skips** months without a 31st.
2. **Yearly rule with no `BY` parts started on February 29** reads back as
   `BYMONTHDAY=28,29;BYSETPOS=-1` and occurs on Feb 29 in leap years and
   Feb 28 otherwise (the month is implied by the start date).
3. Other rules read back unchanged (including `COUNT`).
4. Splitting a series (§6) rewrites `COUNT` of the original.
5. Deleting "this and future" occurrences (§6) replaces the end by
   `UNTIL` = the last second (in the event's time zone) of the day before the
   removed occurrence, written in UTC.

## 5. Expansion rules (observed)

Occurrences are produced by `eventsMatchingPredicate:` /
`enumerateEventsMatchingPredicate:usingBlock:` for the predicate's window
(`events.md` §5 for the window rules).

1. The **start counts as the first occurrence** even if it does not match the
   rule (RFC 5545 behavior): weekly `BYDAY=WE`, count 3, started on a Monday
   → Mon, Wed, next Wed.
2. Wall-clock time is kept across daylight-saving changes in the event's
   zone: an 08:30 New York series is 12:30Z before 2026-11-01 and 13:30Z after.
3. A **floating** series (no time zone) recurs at the same wall-clock time in
   the time zone that is current in the reading process.
4. `UNTIL` is inclusive (an occurrence starting exactly at `UNTIL` is
   produced).
5. `UNTIL` earlier than the start: the series has **no occurrences at all**;
   even the first (master) instance is not returned.
6. Several rules on one item: the occurrence set is the **union** of the sets
   of each rule, duplicates removed (weekly count 2 + daily count 2 from Monday
   Nov 2 → Nov 2, Nov 3, Nov 9). The item reports both rules.
7. Week numbers (`BYWEEKNO`) follow ISO 8601 weeks starting Monday.
   **Quirk**: a yearly `BYWEEKNO=20;BYDAY=MO` rule with count 3 started
   2027-05-17 produced only the first occurrence in a window to 2030-09-01
   (expected 2028-05-15 and 2029-05-14 by RFC 5545). Ycode records this as an
   open question (plan C-REC-Q1) and implements RFC behavior unless a later
   round confirms the quirk.

### 5.1 Golden expansions (time zone America/New_York unless floating)

| # | Start (local) | Rule | Occurrences (UTC) |
|---|---|---|---|
| R1 | 2026-10-26 08:30 Mon, 30 min | weekly MO,WE,FR, count 10 | 10-26 12:30, 10-28 12:30, 10-30 12:30, 11-02 13:30, 11-04 13:30, 11-06 13:30, 11-09 13:30, 11-11 13:30, 11-13 13:30, 11-16 13:30 |
| R2 | 2026-10-10 07:00 Sat | daily, interval 2, until 2026-10-20 07:00 local | 10-10, 10-12, 10-14, 10-16, 10-18, 10-20 (all 11:00) |
| R3 | 2026-10-31 12:00 | monthly (plain), count 6 | 2026-10-31 16:00, 11-30 17:00, 12-31 17:00, 2027-01-31 17:00, 02-28 17:00, 03-31 16:00 |
| R3b | 2026-10-31 12:00 | monthly `BYMONTHDAY=31`, count 6 | 2026-10-31, 12-31, 2027-01-31, 03-31, 05-31, 07-31 (12:00 local) |
| R4 | 2026-10-30 17:00 Fri | monthly `-1FR`, count 5 | 2026-10-30 21:00, 11-27 22:00, 12-25 22:00, 2027-01-29 22:00, 02-26 22:00 |
| R5 | 2026-10-29 10:00 | monthly MO–FR `BYSETPOS=-2`, count 4 | 2026-10-29 14:00, 11-27 15:00, 12-30 15:00, 2027-01-28 15:00 |
| R6 | 2028-02-29 09:00 | yearly (plain), count 3 | 2028-02-29 14:00, 2029-02-28 14:00, 2030-02-28 14:00 |
| R7 | 2026-11-26 15:00 | yearly `BYMONTH=11;BYDAY=4TH`, count 3 | 2026-11-26 20:00, 2027-11-25 20:00, 2028-11-23 20:00 |
| R8 | 2026-10-01 11:00 Thu | weekly interval 2 TU,TH, count 6 | 10-01, 10-13, 10-15, 10-27, 10-29 (15:00), 11-10 16:00 |
| R9 | 2027-05-17 09:00 Mon | yearly `BYWEEKNO=20;BYDAY=MO`, count 3 | 2027-05-17 13:00 only (quirk, §5 item 7) |
| R10 | 2027-04-10 09:00 | yearly `BYYEARDAY=100`, count 3 | 2027-04-10 13:00, 2028-04-09 13:00, 2029-04-10 13:00 |
| R11 | 2026-10-31 22:00 floating (reader in New York) | daily, count 3 | 2026-11-01 02:00, 11-02 03:00, 11-03 03:00 |
| R12 | 2026-12-25 all-day floating | yearly, count 3 | 2026-12-25 05:00, 2027-12-25 05:00, 2028-12-25 05:00 (local midnight) |
| R13 | 2026-11-02 09:00 Mon | weekly count 2 **and** daily count 2 | 11-02 14:00, 11-03 14:00, 11-09 14:00 |
| R14 | 2026-11-02 12:00 Mon | weekly `BYDAY=WE`, count 3 | 11-02 17:00, 11-04 17:00, 11-11 17:00 |
| R15 | 2026-11-03 12:00 | daily, until 2026-11-01 00:00 | none |

## 6. Editing recurring events

Occurrences returned by a fetch are distinct `EKEvent` objects sharing the
master's `eventIdentifier`; `occurrenceDate` is the original start of the
occurrence; `isDetached` is NO.

| Operation | Observed result |
|---|---|
| Change an occurrence (title, +90 min) and save with `EKSpanThisEvent` | creates a **detached** occurrence: `isDetached` YES, no rules, `occurrenceDate` unchanged; its `eventIdentifier` and `calendarItemExternalIdentifier` become `<master id>/RID=<n>` where n is the occurrence's original start as whole seconds since 2001-01-01 00:00:00 UTC (2026-10-30T12:30Z → `RID=815056200`); a new `calendarItemIdentifier` |
| Remove an occurrence with `EKSpanThisEvent` | the occurrence disappears (exception date); others stay |
| Move an occurrence exactly onto the next occurrence's time | accepted (no `EKErrorStartDateCollidesWithOtherOccurrence`); both instances are returned |
| Change occurrence 7 and save with `EKSpanFutureEvents` | **splits** the series: the original keeps occurrences 1–6 (`COUNT=6`), a new master with a new identifier starts at occurrence 7 with the change applied and `COUNT=4`; exceptions before the split stay with the original |
| Remove the rule from the master and save with `EKSpanFutureEvents` | a single event remains |
| Remove occurrence 3 with `EKSpanFutureEvents` | occurrences 1–2 remain; the rule's end becomes `UNTIL` per §4 item 5 (`UNTIL=20261013T035959Z` for an occurrence on 10-14 in New York) |
| Invalid span value (7) | accepted, treated like `EKSpanThisEvent` (no error) |

## 7. Reminders

Recurring reminders need a due date (error 18 otherwise, `errors.md`).
Completing a recurring reminder (observed, daily count 3 due 10-22 07:00):
the reminder object (same `calendarItemIdentifier`) **moves to the next
occurrence** (due 10-23 07:00, `COUNT=2`, not completed), and a **new,
completed** reminder without rules is created for 10-22. See `reminders.md`.

## Evidence

| Claim | Level |
|---|---|
| Property list, enum values, constructors | 4 (SDK names and raw values) + 1 |
| Construction exceptions and reasons; accepted odd inputs | 3 |
| Text form and part order | 3 |
| Normalization on save (31st, Feb 29, split counts, future-delete `UNTIL`) | 3 |
| Expansion rules and golden table | 3 (+ 1: RFC 5545 for the general semantics) |
| `BYWEEKNO` quirk | 3 (single observation; flagged as open) |
| Detached occurrence identifier format (`/RID=` seconds since 2001) | 3 (two samples: 815056200 and 814710600, 4 days apart) |
| Recurring reminder completion | 3 |
