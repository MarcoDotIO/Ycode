# EventKit and Contacts in Apple's iOS Simulator: observations (2026-10-19/20)

Dirty-room notes (prose, no code) behind `specs/frameworks/eventkit/` and
`specs/frameworks/contacts/`. Agent: KIT-EVENTKIT-CONTACTS (two sessions).
Host: the Apple-silicon Mac, Xcode 27.1 (27A9269), extremely loaded during
the second session (load average between 230 and 970; single simulator
commands took up to ten minutes).

## Setup

- Probes: `research/experiments/eventkit-contacts/EKProbe/` and `CNProbe/`
  (our own Objective-C apps, built with `clang` from the installed Xcode,
  ad-hoc signed, entitlements only in the `__TEXT,__entitlements` section).
  Variants (see `build.sh`) differ only in usage strings and entitlements:
  EKProbe (all three iOS 17 strings), EKProbeWO (write-only string only),
  EKProbeLegacy (pre-iOS-17 strings only), EKProbeNone (none); CNProbe,
  CNProbeLim (same as CNProbe, used for the limited-access answer),
  CNProbeNone (no string), CNProbeNotes (plus the contacts-notes
  entitlement).
- Devices: `ycode-test-ekcn-271` (iPhone Duo, iOS 27.1, first session; most
  data phases), `ycode-test-eventkit-271` (iPhone Duo, iOS 27.1, fresh,
  second session; prompts, `simctl privacy`, fresh-device state, UI). The
  27.1 runtime only accepts the iPhone Duo device type.
- Screenshots: the iPhone Duo's default `simctl io screenshot` captures the
  inner display, which stays black; the cover display (1398 pixels wide,
  466 × 678 points at 3×) is captured by passing its display UUID from
  `simctl io <device> enumerate` to `--display`.
- Taps: the repository's `hidsend` research driver
  (`research/experiments/simulator/hid/`), ratio coordinates of the cover
  display. Under the extreme load some taps were lost; the probe's request
  wait was raised from 120/180 s to 900 s after one contacts request timed
  out before the tap arrived.
- Raw reports and screenshots: `research/dirty/eventkit-contacts/r271/`
  (first session) and `research/dirty/eventkit-contacts/r271b/` (second,
  with `shots/`);
  SDK name inventory `research/dirty/eventkit-contacts/inventory.json`.
- No account was signed in. All events, reminders and contacts written by
  the probes are made-up ("Probe …", example.com/.org/.net, 555-010-xxxx).
  The six contacts that the device template ships (Apple's sample people)
  were read but not changed by the full-access app; the limited app deleted
  one probe contact it had been granted.

## EventKit

- The prompt appeared 10–45 s after the request; completions arrived on the
  XPC queue of the connection to `calaccessd`.
- The full-access prompt shows a live preview of the next event and a count
  of events in the next year (on a fresh device the four seed-contact
  birthdays, first "Kate Bell's 49th Birthday" on 2027-01-20). Write-only and
  reminders prompts are plain two-button alerts.
- The legacy request with only the old strings shows the full-access prompt
  with the old string (first session: answered Don't Allow, status 2; second:
  Allow, status 3), then the reminders prompt.
- With only reminders access, the reminder list is reported under a source
  named "Local" with a fixed identifier; with calendar access as well, under
  "Default". The default list identifier is the same on both devices.
- Write-only access exposes a virtual source "Account" and calendar
  "Calendar" with literal identifiers `VIRTUAL_APP_SOURCE_UUID` and
  `VIRTUAL_APP_CALENDAR_UUID`; saved events land in the real calendar.
- `simctl privacy grant calendar` gave full access even to the app with
  only the write-only string, and to the app with no strings.
- Recurrence: a plain monthly rule started on the 31st and a plain yearly
  rule started on Feb 29 were rewritten on save to "last day" rules; an
  explicit BYMONTHDAY=31 skips short months; a yearly week-number rule gave
  only one occurrence in a four-year window (open question).
- The four-year window cap of event predicates was confirmed.
- Reminders: completing a recurring reminder moves the saved object to the
  next occurrence and creates a separate completed copy.

## Contacts

- The device template ships `AddressBook.sqlitedb` (dated before device
  creation) with six people and the groups Friends and Work; the local
  container identifier is identical across devices.
- iOS 18+ two-step prompt: alert (Don't Allow / Continue), then a sheet
  with monograms of all contacts and the choice Select Contacts / Share All
  N Contacts.
- A first data call without a prior request shows the same prompt and
  blocks (15 s in our run).
- `simctl privacy grant contacts-limited` produced full access (status 3),
  the same TCC row as `grant contacts`.
- The limited app sees all groups but only granted and own contacts; it can
  delete a granted contact.
- vCard export never contained the note, even with the notes entitlement;
  the store refused the note key without the entitlement (code 102).
- Two change notifications per save: one on the saving thread, one later on
  the main thread marked as originating externally.
- Limited flow on the fresh device: Continue → Select Contacts → a selection
  list (search, sections, index, Continue disabled until a pick, "Select
  Contacts Later") → a confirmation "Allow access to 2 contacts?" (Allow
  Selected Contacts / Not Now). Result status 4; the app then saw exactly
  the two picked seed contacts; two `LimitedAccess` rows were written.
- The app without a usage string was killed on `requestAccess…`: the crash
  report names the TCC namespace and the missing key. The same app could
  present the contact picker (banner "Private Access to Contacts"), and a
  pick returned a full contact with its identifier but left no grant.
- The new-contact view controller saved the contact on Done even though
  the app had not set a store.
- The seed contacts and groups have the same identifiers on both devices.

## EventKitUI

- The event edit controller presented from an app with denied access shows
  the default calendar's name; Add saved the event (visible as a new row in
  the calendar database) and reported action 1, while the app's own event
  object stayed empty.
- The calendar chooser listed a "US Holidays" subscribed calendar that had
  appeared on its own about an hour after the device's first boot (a third
  source "Subscribed Calendars").

## Things that did not work or were skipped

- No Calendar, Reminders or Contacts app exists in the 27.1 runtime, so
  "what the built-in apps show" can only be recorded for 27.0/26.5 as file
  presence; those runtimes were not booted.
- The SwiftUI `ContactAccessButton` and `contactAccessPicker` were not
  probed (would need a Swift probe app).
- Level 5 (disassembly/decompilation) was not used. The reference tools
  folder, Ghidra and other agents' `research/dirty/` were not opened.
