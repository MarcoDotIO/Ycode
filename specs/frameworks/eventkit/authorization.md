# EventKit spec: authorization and privacy

Part of `specs/frameworks/eventkit/`. Level 3 facts come from `EKProbe` and
its variants (`EKProbeWO`, `EKProbeLegacy`, `EKProbeNone`; they differ only
in Info.plist usage strings) on the iOS 27.1 simulator; level 1 from Apple's
public documentation in our words. Key and service names are interop facts.

## 1. Info.plist keys

| Key | Purpose | Shown in the prompt |
|---|---|---|
| `NSCalendarsFullAccessUsageDescription` (iOS 17+) | needed for `requestFullAccessToEventsWithCompletion:` | yes |
| `NSCalendarsWriteOnlyAccessUsageDescription` (iOS 17+) | needed for `requestWriteOnlyAccessToEventsWithCompletion:` | yes |
| `NSRemindersFullAccessUsageDescription` (iOS 17+) | needed for `requestFullAccessToRemindersWithCompletion:` | yes |
| `NSCalendarsUsageDescription` (legacy) | accepted by the deprecated `requestAccessToEntityType:completion:` for events (full-access prompt) | yes |
| `NSRemindersUsageDescription` (legacy) | the same for reminders | yes |

No entitlement is needed for EventKit (level 1; confirmed: the probes carry
only `application-identifier`).

## 2. Status values

`[EKEventStore authorizationStatusForEntityType:]` per entity (event,
reminder): 0 not determined, 1 restricted, 2 denied, 3 full access
(`EKAuthorizationStatusAuthorized` is a deprecated alias of 3), 4 write-only
(events only). Status is per app (bundle identifier) and survives app
restarts.

## 3. Requests

| Call | Usage string present | Observed |
|---|---|---|
| `requestFullAccessToEventsWithCompletion:` | full-access key | prompt (§5.1); completion `granted` YES / NO, error nil; status 3 / 2 |
| … | key missing (only the write-only key, or none) | **no prompt**; completion at once with NO and nil error; status unchanged (0, or 4 if write-only was granted before) |
| `requestWriteOnlyAccessToEventsWithCompletion:` | write-only key | prompt (§5.2); status 4 when allowed |
| `requestFullAccessToRemindersWithCompletion:` | reminders key | prompt (§5.3); status 3 / 2 |
| `requestAccessToEntityType:completion:` (deprecated) | legacy keys only | events: the **full-access** prompt with the legacy string, status 3 when allowed; reminders: the reminders prompt, status 3 |
| any request when the status is already decided | — | completion at once (< 0.1 s) with the current answer (YES for 3/4 when that level was asked; NO for 2), no prompt |

Completions run on a private queue (`interface.md` §6). The prompt took
10–45 s to appear on the heavily loaded host and the completion arrived
right after the tap; nothing in the API times out.

Write-only to full (level 1): an app that holds write-only access and asks
for full access gets the full-access prompt again; denying leaves status 4.
Not exercised in the probe (C-AUTH-Q1).

## 4. What each access level sees

| Level | Sources / calendars | Reads | Writes |
|---|---|---|---|
| none / denied / not determined | none; defaults nil; `eventStoreIdentifier` nil | events: empty arrays; reminders fetch: empty array | save → code 1 (no default calendar), calendar save → code 14 |
| write-only (events 4) | one virtual source "Account" and calendar "Calendar" (`interface.md` §2.3) | nothing, not even the app's own events | save into the virtual calendar works (lands in the real default calendar); edit/remove of the held object work; calendar creation → 17 |
| full events (3) | all event sources and calendars; the reminder lists only if reminders are also 3 | everything | everything allowed by the calendar's flags |
| full reminders only | source "Local" with the reminder lists | reminders | reminders |

## 5. The prompts (observed)

All prompts are system alerts drawn over the app (the app stays in the
foreground; dimmed background). Layout: the app's icon with a small
privacy-hand badge, a bold title naming the app's **display name** in curly
quotes, the usage string in a secondary color, then buttons. Ycode draws its
own artwork and words its own titles with the same structure.

### 5.1 Full calendar access

- Title: Allow "‹App›" to access your calendar?
- Usage string.
- A **preview card** showing the next upcoming event of the user's calendars
  (on a fresh device: the date in red capitals "JAN 20, 2027", the event
  "Kate Bell's 49th Birthday", "all-day"), drawn as a stack of cards.
- A summary line "N events in the next year" (fresh device: 4, all from the
  Birthdays calendar) and a note that calendar events may include additional
  data such as locations, email addresses or notes.
- Buttons stacked vertically: **Allow Full Access**, **Don't Allow**.

The legacy events request shows the same prompt with the legacy string.

### 5.2 Write-only

- Title: Allow "‹App›" to add events to your calendar?
- Usage string. No preview.
- Buttons side by side: **Don't Allow**, **Allow**.

### 5.3 Reminders

- Title: Allow "‹App›" to access your reminders?
- Usage string. No preview.
- Buttons side by side: **Don't Allow**, **Allow**.

## 6. TCC records (level 2: the device's `Library/TCC/TCC.db`, table `access`)

| Service | App state | `auth_value` | `auth_reason` | `auth_version` | `flags` |
|---|---|---|---|---|---|
| `kTCCServiceCalendar` | full access (prompt) | 2 | 2 | 2 | 16 |
| `kTCCServiceCalendar` | write-only (prompt) | 4 | 2 | 2 | 0 |
| `kTCCServiceReminders` | allowed (prompt) | 2 | 2 | 1 | 0 |
| `kTCCServiceReminders` | denied (prompt) | 0 | 2 | 1 | 0 |

Rows written by `simctl privacy` instead of a prompt: `grant` → `auth_value` 2,
`auth_reason` 4, `flags` 0; `revoke` → `auth_value` 0, `auth_reason` 4.

Ycode's own authorization store does not have to use this database; it is
recorded so that a Ycode guest running Apple's runtime can pre-seed or read
grants (plan R1).

## 7. `simctl privacy`

The `xcrun simctl privacy <device> grant|revoke|reset <service> <bundle-id>`
command maps `calendar` → events and `reminders` → reminders (observed with
the app terminated before each step):

| Command | Resulting status |
|---|---|
| `reset calendar` | events 0 (other entity unchanged) |
| `grant calendar` | events **3** (full access) — also for an app without any usage string |
| `revoke calendar` | events 2 |
| `grant reminders` | reminders 3 |
| `grant calendar` on the write-only app (only the write-only string) after `reset` | events 3 (full access, not 4) |

There is no `simctl` service for write-only access. Ycode's `simctl`
equivalent must offer the same verbs and services with the same results.

## 8. Changing grants later

In the 27.1 simulator there is no Calendar or Reminders app, but Settings →
Privacy & Security → Calendars/Reminders exists (level 1; not exercised).
Erasing the device or `simctl privacy reset` clears the answer.

## Evidence

| Claim | Level |
|---|---|
| Keys and their pairing with calls | 1 + 3 |
| No entitlement needed | 3 |
| Status values | 4 + 3 |
| Request behavior with and without strings, immediate answers | 3 |
| Write-only → full upgrade prompt | 1 (not probed) |
| Per-level visibility | 3 |
| Prompt texts and layout | 3 (screenshots in `research/dirty/eventkit-contacts/`, not committed) |
| TCC rows | 2 |
| `simctl privacy` mapping | 3 |
| Settings panes | 1 |
