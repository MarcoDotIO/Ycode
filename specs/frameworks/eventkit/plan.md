# EventKit spec: implementation rounds and conformance tests

Part of `specs/frameworks/eventkit/`. This plan is Ycode's own. Each round is
sized for one clean-room agent. Clean-room agents read only `specs/`, public
documentation and permissively licensed open source; they must not open the
reference tools (the Xcode copy, Ghidra, the IPSW), `research/dirty/`, or
Ghidra projects, and must not run Apple's simulator or Xcode.

## 1. Targets

1. **Baseline in Ycode's simulator** with Apple's EventKit and daemons
   (`design.md` §2).
2. **Open EventKit / EventKitUI**: drop-in frameworks for the guest
   (binary-compatible: same install names, class names, selectors, enum
   values and string constants of `identifiers.md`, the Swift overlay's
   `EventStoreChanged` message) and a Linux Swift package with the same
   names and semantics (`design.md` §3–§7).

## 2. Rounds

| Round | Owner | Scope | Done when |
|---|---|---|---|
| R0 | KIT-EVENTKIT-CONTACTS (this) | Specification and probe | this directory reviewed and merged |
| R1 | simulator track | **Baseline in Ycode**: dependencies G1–G10 of `design.md` §2; run `EKProbe` phases basic → reqfull → reqrem → reqwo [WO] → reqlegacy [Legacy] → status → events → reminders → wo [WO] → count → ui*, answering prompts by taps | every row K1–K12 of `simulator-baseline.md` §7 matches (modulo UUIDs, addresses, times) |
| R2 | clean room | **Model and store**: object classes with change tracking, identifiers (§3.1), sources/calendars with the fixed identifiers, SQLite store and daemon, save/remove/commit/reset/rollback/refresh, staged batches, change journal and `EKEventStoreChangedNotification` (main thread, one per commit, cross-process) | C-EK-STORE passes on Linux and in the guest |
| R3 | clean room | **Recurrence engine**: RFC 5545 expander, normalizations, detached occurrences, splits, future deletes, predicate window rules and the four-year cap, floating and all-day rules | C-EK-REC passes (all golden rows of `recurrence.md` §5.1) |
| R4 | clean room | **Reminders**: reminder model, lists, async fetch with cancel, the three predicates, recurring completion | C-EK-REM passes |
| R5 | clean room | **Authorization**: per-entity states incl. write-only, usage-string checks, Ycode's three alerts, the write-only virtual source/calendar, `ycode-simctl privacy` verbs | C-EK-AUTH passes (taps in the guest, recorded answers on Linux) |
| R6 | clean room | **EventKitUI**: `EKEventEditViewController`, `EKEventViewController`, `EKCalendarChooser` with their delegate calls (`ui.md`) | C-EK-UI passes |
| R7 | clean room (optional) | **Accounts and derived calendars**: Birthdays calendar fed by Ycode Contacts, subscribed calendars (read-only ICS), CalDAV sync (open protocol, RFC 4791) | C-EK-SYNC passes against a local CalDAV test server |
| R8 | simulator track + clean room | **Drop-in switch**: load Ycode's frameworks and daemon in the guest instead of Apple's (opt-in), side-car seeding | the whole suite passes with both stacks |

## 3. Conformance tests

Every test is a list of probe steps and expected outputs from the topic
files; numbers below are the golden values.

### 3.1 C-EK-STORE (`interface.md`)

- Fresh device: sources "Default" + "Other" (`______NativeStorePersistentID_______`),
  calendars "Calendar" + "Birthdays", list "Reminders"
  `3C8C2A71-84BF-4C87-8EFD-BB4827650D15`; reminders-only source "Local"
  `3B242529-8F5D-47A1-9351-444101218C30`.
- Identifier forms: `<source>:<UUID>`; detached `/RID=815056200` for
  2026-10-30T12:30Z.
- All-day normalization table (§3.3), floating table (§3.2): 14:00 floating
  → 18:00Z (New York), 05:00Z (Tokyo), 12:00Z (Berlin), 14:00Z (UTC).
- Window rule: [14:00Z, 15:00Z) includes an event 13:00–14:00Z;
  [12:00Z, 13:00Z) excludes it; ten-year window returns only four years.
- Batch of 3 with `commit:NO` → visible in the same store before commit,
  one notification after commit; other store's save → one notification.
- `reset` → old objects' `eventIdentifier` nil.
- Errors 1, 2, 3, 4, 6, 11, 14, 17, 22 in the situations of `errors.md` §2;
  acceptances for zero duration, year 4100 and 1800, span 7.

### 3.2 C-EK-REC (`recurrence.md`)

Rows R1–R15 of §5.1 exactly; text forms of §3; normalizations of §4;
editing table of §6 (detach, delete one, collide accepted, split 6 + 4,
rule removal, future delete → `UNTIL=20261013T035959Z`); exceptions of §2.

### 3.3 C-EK-REM (`reminders.md`)

Save table §3 (codes 18, 26, 1, 23); fetch results §4 (7 / 1 / 6 / 1 / 1);
recurring completion §5 (8 reminders, next due 10-23, `COUNT=2`); cancelled
fetch never completes; double remove YES; 8 notifications for 8 commits.

### 3.4 C-EK-AUTH (`authorization.md`)

Status matrix of §3 and §4; prompts of §5 (titles, button sets, preview
and count on the full prompt); immediate answers for decided states and
missing strings; `simctl privacy` table §7.

### 3.5 C-EK-UI (`ui.md`)

Presentation of the three controllers without read access; delegate
callbacks and actions.

## 4. Open questions (for later dirty-side rounds)

| Id | Question |
|---|---|
| C-REC-Q1 | Is the single-occurrence result of yearly `BYWEEKNO=20;BYDAY=MO` (R9) a real limitation or a probe artifact? Re-run with other windows and week numbers. |
| C-REM-Q1 | Which zone is used to compare a date-only due date with the incomplete-reminder window? |
| C-AUTH-Q1 | Write-only → full upgrade prompt and the result of denying it. |
| C-EK-Q4 | Error 10 (collision) and 9 (too far in future): any input that produces them? |
| C-EK-Q5 | Does Settings → Privacy → Calendars change the access level live (notification to running apps)? |

## Evidence

Plan and test selection are Ycode's own. Golden values are level 3 from
the topic files (`EKProbe` on iOS 27.1).
