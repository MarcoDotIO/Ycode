# ycode-eventkit — open EventKit

A clean-room, Linux-buildable reimplementation of Apple's EventKit, written
only from `specs/frameworks/eventkit/` under the protocol in `AGENTS.md`.
Package `ycode-eventkit`, library module `EventKit` (the framework's module
name, an interop identifier), so `import EventKit` source compiles against it.

```
swift build && swift test          # macOS and Linux, Swift 6.4
```

## Status by round (`specs/frameworks/eventkit/plan.md`)

| Round | State | What is here |
|---|---|---|
| R2 model and store | done (Linux package) | `EKObject` change tracking (`hasChanges`, `isNew`, `rollback`, `reset`, `refresh`); sources and calendars with the fresh-device seed and the fixed identifiers; identifiers (`<source>:<UUID>`, `/RID=<seconds since 2001>`); SQLite store; save/remove/commit/reset; staged batches (`commit: false`); change journal and `EKEventStoreChanged` on the main queue, one per commit, also across processes; all-day normalization; floating events; window rule and four-year cap; the error codes of `errors.md` §2; the write-only virtual view and the no-access view |
| R3 recurrence engine | done | Ycode's own RFC 5545 expander; EventKit's normalizations (§4); rule text form; detached occurrences; splits; future deletes; several rules as a union; floating and all-day series |
| R4 reminders | done | reminder model, lists, async fetch with cancel, the three predicates, recurring completion |
| R5 authorization | deferred | statuses come from the store configuration (recorded answers); requests answer from it; no prompts, no usage-string checks, no `simctl privacy` verbs |
| R6–R8 | not started | EventKitUI, accounts and derived calendars (the Birthdays calendar exists but stays empty), guest drop-in |

The guest side of R2 (a daemon and XPC, design.md §3) is not built: on Linux
every store opens the same SQLite file (WAL mode) directly.

## Tests

Swift Testing; each suite and test names the spec section it checks.

| File | Spec |
|---|---|
| `RecurrenceRuleTests.swift` | `recurrence.md` §1–§3: every text-form row, the three exceptions (as exit tests), accepted odd inputs |
| `ExpansionGoldenTests.swift` | `recurrence.md` §5.1 rows R1–R15 (saved, then read through a second store), §4 normalizations, expander unit checks |
| `EditingTests.swift` | `recurrence.md` §6 and §4 items 4–5: detach (`RID=815056200`), remove one, collision accepted, split 6 + 4, rule removal, future delete (`UNTIL=20261013T035959Z`) |
| `StoreTests.swift` | C-EK-STORE: `interface.md` §2–§3, §5; `errors.md` §2; `authorization.md` §4 (levels only) |
| `ReminderTests.swift` | C-EK-REM: `reminders.md` §1–§6 |

## Dependencies

| Dependency | Licence | How |
|---|---|---|
| SQLite 3 | public domain | the system library (`libsqlite3` in the macOS SDK; `libsqlite3-dev` on Linux), through the `CSQLite` system-library target |
| Foundation, Dispatch, Swift Testing | Apache-2.0 (Swift project) | the toolchain |

No other packages. The recurrence engine is written from RFC 5545; no
iCalendar library is used or vendored.

## The module name on macOS

The library module is called `EventKit`. Inside this package's own build
SwiftPM puts the package's module directory ahead of the SDK, so the tests'
`import EventKit` resolves to this module and nothing links Apple's
framework; no workaround was needed. Do not add this package to a target that
also needs Apple's EventKit. (As `frameworks/README.md` says, each package is
built and tested on its own.)

## Ycode-specific API

- `YcodeEventStoreConfiguration` (database URL, reader time zone, recorded
  access levels) and `EKEventStore(ycodeConfiguration:)`;
  `EKEventStore.ycodeDefaultConfiguration` backs `EKEventStore()` and
  `authorizationStatus(for:)`. The default database is
  `$YCODE_EVENTKIT_DATABASE`, else `ycode-eventkit/Calendar.sqlite` under
  `$XDG_DATA_HOME` / `~/.local/share` (Linux) or Application Support (macOS).
  The default access levels are full access.
- `EKCalendar.ycodeColor` (`YcodeRGBColor`): the calendar color without
  CoreGraphics. On Apple platforms `cgColor` mirrors it.
- On platforms without Core Location, a minimal `CLLocation` /
  `CLLocationCoordinate2D` (coordinate only) for `EKStructuredLocation`.

## Behavior notes and deviations

- **Exceptions.** Swift cannot raise Objective-C exceptions portably. The
  three `NSInvalidArgumentException` cases of `recurrence.md` §2 stop the
  process (`fatalError`) with the same reason text.
- **Swift enums.** `EKSpan` and `EKWeekday` are Swift enums, so the spec's
  "span 7" input and weekday 9 cannot be expressed through the public API
  (the weekday check exists for raw values and is tested).
- **Main queue.** Change notifications go to `DispatchQueue.main`. On Linux
  the main queue may be served by a thread other than the process's first
  thread (under `dispatch_main`); the tests check the queue, not the thread.
- **Staged changes.** A store with changes saved with `commit: false` holds a
  write transaction; another store's write waits up to 5 s for it.
- **Cross-process notifications** come from polling the change journal every
  200 ms.
- **Detached identifiers.** The detached occurrence's
  `calendarItemExternalIdentifier` is the master's external identifier plus
  `/RID=<n>`; its `eventIdentifier` is the master's `eventIdentifier` plus
  `/RID=<n>`.
- **Masters and occurrences.** Objects from `event(withIdentifier:)` are
  series masters; saving one changes the whole series whatever the span.
  Removing a master with `.thisEvent` removes its first occurrence.
- **BYWEEKNO.** RFC 5545 behavior, not the single-occurrence quirk recorded
  for R9 (open question C-REC-Q1).

## Storage

Our own schema (`design.md` §4): `meta`, `source`, `calendar`, `item`
(events and reminders; timed values as UTC instant plus zone name, floating
and all-day values as wall-clock text), `rule` (RRULE text), `exception_date`,
`alarm`, `journal` (sequence, writer token, entity mask, object ids).

## Spec questions found while implementing

1. `recurrence.md` §3 states the part order BYDAY, BYMONTHDAY, BYMONTH,
   BYWEEKNO, …, but its golden rows print `BYMONTH=11;BYDAY=4TH` and
   `BYWEEKNO=20;BYDAY=MO`. Ycode follows the rows: BYMONTH, BYWEEKNO,
   BYYEARDAY, BYMONTHDAY, BYDAY, BYSETPOS, WKST. The place of BYMONTHDAY
   relative to BYDAY is not observed.
2. §4 item 5 says UNTIL is the last second of "the day before the removed
   occurrence", but the golden `UNTIL=20261013T035959Z` (removing 10-14 from
   an every-other-day series) is the end of 10-12, the day of the previous
   occurrence. Ycode uses the end of the day of the last remaining
   occurrence, which matches the golden value and the text whenever the
   previous occurrence is the day before.
3. §4 item 1 shows only the 31st (`BYMONTHDAY=28,29,30,31`). Ycode applies
   the same rule to starts on the 29th and 30th (`28…day`, `BYSETPOS=-1`).
4. §4 item 2: a yearly rule whose only day part is BYMONTHDAY is expanded in
   the start's month (as the spec says), which differs from RFC 5545 (every
   month). Is that true for any yearly BYMONTHDAY rule, or only for the
   normalized February 29 form?
5. Detached occurrences: is the external identifier `<master external>/RID=n`
   or `<master eventIdentifier>/RID=n`? (§6 says both "become `<master
   id>/RID=<n>`".)
6. `reminders.md` §4 lists 7 reminders, but the §3 table has 6 successful
   saves; the test reconstructs a seventh (the priority-12 reminder saved
   again with priority 9).
7. Underlying integer types of the enums (Int vs UInt) are not in the spec;
   Ycode uses `Int` except `EKEntityType`, `EKReminderPriority` and the masks.
8. Saving a series master with `.thisEvent` and removing a master object
   (not an occurrence) are not covered by the observations.
