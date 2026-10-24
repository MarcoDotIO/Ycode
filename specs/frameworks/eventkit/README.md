# EventKit and EventKitUI (iOS) — specification index

Status: **round 0 (specification)**, 2026-10-20. Reference: the iOS 27.1 SDK in
Xcode 27.1 (27A9269) and the iOS 27.1 simulator runtime (24A94401); the
iOS 27.0 (24A434) and 26.5 (23F77) runtimes were inspected as files only.

## Scope

The EventKit API an iPhone app links against: the event store, sources,
calendars and reminder lists, events (timed, all-day, floating), recurrence
rules and occurrence expansion, detached occurrences and series edits,
alarms and structured locations, reminders and their predicates, change
notifications, the iOS 17+ access model (full access, write-only access,
reminders access) with its prompts and TCC records, errors, and the three
EventKitUI controllers. It records what Apple's simulator does today — the
baseline Ycode's simulator must match first. EventKit works fully there
without any account; only the Calendar and Reminders **apps** are missing
from the 27.1 runtime.

Not covered: CalDAV/Exchange account protocols (named only; R7 is optional),
invitations and scheduling replies (no public API to create attendees), the
virtual-conference extension point (names only), macOS-only API.

## Files

| File | Content |
|---|---|
| `simulator-baseline.md` | What EventKit does in Apple's simulator; fresh-device state with fixed identifiers; daemons and Mach services; data files; **conformance checklist** K1–K12 |
| `interface.md` | Classes; store, sources and calendars; the write-only virtual view; identifiers; save/commit/reset; events, time zones, floating and all-day rules; alarms; fetch window rules; notifications; queues |
| `recurrence.md` | Rule model, validation, text form, normalization on save, expansion rules with a **golden table**, editing recurring events (detach, split, future delete) |
| `reminders.md` | Reminder model, lists, save rules, async fetch and predicates, recurring completion |
| `authorization.md` | Usage keys, statuses, requests, what each access level sees, the three prompts as observed, TCC records, `simctl privacy` |
| `errors.md` | `EKErrorDomain` codes, which situations produce them, exceptions |
| `ui.md` | `EKEventEditViewController`, `EKEventViewController`, `EKCalendarChooser` |
| `design.md` | **Ycode-original design note**: guest dependencies for the baseline; open implementation (daemon, store, recurrence engine, authorization broker, UI) |
| `plan.md` | Implementation rounds R1–R8 and conformance tests with golden values; open questions |
| `identifiers.md` | Generated appendix: every enumeration with raw values; string constants with values |
| `api-inventory.md` | Generated appendix: every class with superclass and member names, with introduction versions |

Black-box observations: `research/notes/eventkit-contacts-simulator-observations-2026-10-20.md`.
Probe app (our own code): `research/experiments/eventkit-contacts/EKProbe/`
with `build.sh` (variants) and `run.sh`. Generators:
`research/experiments/eventkit-contacts/{extract_names,gen_api}.py`.

## Framework layout facts (level 4)

- Install names `/System/Library/Frameworks/EventKit.framework/EventKit` and
  `/System/Library/Frameworks/EventKitUI.framework/EventKitUI`. EventKit
  availability starts at iOS 4.0 (members carry their own versions); the
  iOS 17 access calls (`requestFullAccessToEventsWithCompletion:`,
  `requestWriteOnlyAccessToEventsWithCompletion:`,
  `requestFullAccessToRemindersWithCompletion:`) and status values 3/4
  replaced the iOS 6 `requestAccessToEntityType:completion:`, now deprecated.
- The Swift overlay adds only `EKEventStore.EventStoreChanged` (iOS 26) and
  its `.changed` message identifier.
- In the runtime, the store work happens in `calaccessd` (events) and
  `remindd` (reminders), with private frameworks `CalendarDaemon`,
  `CalendarDatabase`, `CalendarFoundation`, `ReminderKit`, `EventKitUICore`,
  `EventKitTCCUI` (names only).

## Evidence summary

Level 1: Apple's public EventKit documentation and RFC 5545 (summarized in
our words). Level 2: runtime file layout (app bundles, launchd property
lists, store files as formats: table names and properties, TCC rows).
Level 3: `EKProbe` and its variants on simulators named
`ycode-test-ekcn-271` (earlier run) and `ycode-test-eventkit-271` (iPhone
Duo, iOS 27.1). Level 4: SDK metadata (header and module names, enum raw
values, availability). Level 5 (disassembly/decompilation) was **not**
used. Every file ends with its own Evidence section.

## What the owner must provide

Nothing for the simulator work: no account, team or entitlement is needed
for EventKit. A device run (to compare a real Calendar app, accounts and
CalDAV sync) would need the owner's device and accounts; not attempted.
