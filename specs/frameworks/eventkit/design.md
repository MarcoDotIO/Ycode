# EventKit spec: Ycode design note (original)

Part of `specs/frameworks/eventkit/`. This file is **Ycode's own design**, not
a description of Apple's implementation. It says how Ycode reaches the
behavior of the other files in two stages.

## 1. Two targets

1. **Baseline**: Ycode's simulator runs Apple's iOS runtime unchanged, so
   EventKit, `calaccessd`, `remindd` and `tccd` are Apple's. Ycode only has
   to provide the guest services they depend on (§2).
2. **Open EventKit**: a drop-in `EventKit.framework` / `EventKitUI.framework`
   for the guest and a Linux Swift package with the same names, built from
   these specs (§3–§7).

## 2. Guest dependencies for the baseline

| # | Dependency | Why |
|---|---|---|
| G1 | persistent, writable `/var/mobile/Library/Calendar`, `Library/Caches`, `Library/Preferences` | the calendar database and its WAL files |
| G2 | app-group containers (`group.com.apple.reminders`) created by the container manager | the reminders store |
| G3 | XPC to `com.apple.calaccessd`, `com.apple.remindd`, `com.apple.tccd` with the client's audit token / bundle identifier | per-app authorization |
| G4 | system alerts drawn over the app and touch input to them | the access prompts (`authorization.md` §5) |
| G5 | a remote view service host (`EventViewService.app`) for EventKitUI | `ui.md` |
| G6 | `notifyd` and Darwin notifications across processes | change notifications between apps and daemons |
| G7 | `contactsd` with the seed address book | the Birthdays calendar and the prompt preview |
| G8 | time zone database and the host's zone propagated to the guest | floating events, all-day normalization |
| G9 | a `simctl privacy` equivalent that writes TCC records (`authorization.md` §6–§7) | test automation |
| G10 | `Library/TCC/TCC.db` survives reboots | remembered answers |

## 3. Architecture of the open implementation

```
app process                          ycode-calendard (one per device)
EventKit.framework  ── XPC ──>  authorization broker ── consent UI (Ycode's own alert)
  object model, predicates          store (SQLite, our schema)
  recurrence engine (shared)        recurrence engine (occurrence cache)
  change notification relay  <──    change journal, Darwin notify
EventKitUI.framework (in process, UIKit; no remote service needed)
```

- One daemon serves events and reminders (Apple uses two; the split is not
  observable to apps except through queue labels, which apps must not rely
  on).
- The model objects are local snapshots with change tracking
  (`hasChanges`, `rollback`, `reset`) and a staging area per store instance
  for `commit:NO` saves.
- Identifiers: Ycode generates UUIDs; `eventIdentifier` = source identifier
  + ":" + UUID; detached occurrences append `/RID=<seconds since 2001>`
  (`recurrence.md` §6) so that apps parsing nothing still round-trip. The
  fixed identifiers of the fresh device (`simulator-baseline.md` §2) are
  reproduced.

## 4. Store

Our own SQLite schema (not Apple's): sources, calendars (entity mask, color,
flags), items (common columns + event and reminder columns), rules (RRULE
text), exception dates, detached occurrences, alarms, locations, change
journal with a sequence number. All-day and floating values are stored as
local wall-clock components plus a "floating" flag; timed values as UTC
instants plus a zone name.

## 5. Recurrence engine

An RFC 5545 expander written for Ycode (no Apple code), with the
EventKit-specific normalizations of `recurrence.md` §4 and the expansion
rules of §5, exposed to the store (occurrence cache window, e.g. ±2 years,
refilled lazily) and to the framework (predicate windows capped at four
years). Open-source references that may be read: RFC 5545, libical
(MPL-2.0/LGPL-2.1, read for behavior only), python-dateutil `rrule`
(Apache-2.0/BSD). Golden tests: `recurrence.md` §5.1.

## 6. Authorization

Per (bundle identifier, entity): not determined, denied, write-only,
full. The broker checks the app's Info.plist for the matching usage string
before showing Ycode's alert; missing string → answer NO without UI. A test
hook (environment variable or `ycode-simctl privacy`) sets answers without
UI, with the same verbs as `simctl privacy`.

## 7. EventKitUI

Ycode's controllers are ordinary in-process UIKit view controllers with the
public classes and delegate calls of `ui.md`. Saving from the edit controller
goes through the daemon with the app's identity but **without** requiring
read access (the system-mediated save that Apple performs out of process is
granted by the broker because the user tapped Add in Ycode's own UI).

## Evidence

This file is design, not observation. It relies on the level 1–4 facts of
the other files in this directory; no Apple implementation detail is used.
