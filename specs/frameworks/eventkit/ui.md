# EventKit spec: EventKitUI controllers

Part of `specs/frameworks/eventkit/`. Names are level 4; behavior is level 3
(`EKProbe -phase uiedit|uiview|uichooser`) where marked, otherwise level 1
(Apple's documentation in our words).

## 1. `EKEventEditViewController`

A `UINavigationController` subclass (one view controller inside before
presentation) for creating or editing one event.

| Member | Meaning |
|---|---|
| `eventStore` | store to save into |
| `event` | event to edit; nil → a new event; a new event object may be prefilled (title, location, start, end) |
| `editViewDelegate` | `EKEventEditViewDelegate` |
| `cancelEditing` | dismiss without saving (level 1) |

Delegate: `eventEditViewController:didCompleteWithAction:` with
`EKEventEditViewAction` 0 canceled, 1 saved, 2 deleted (the delegate
dismisses the controller); optional
`eventEditViewControllerDefaultCalendarForNewEvents:`.

Observed: an app **without calendar access** (no usage strings, status 0,
and an app with status 2) can create and present the controller; presentation
completes normally. Since iOS 17 the controller's content runs out of
process and saving from it needs no access (level 1); the runtime ships the
hidden `EventViewService.app` (`com.apple.EventViewService`, level 2) that
hosts it. The delegate's default-calendar method was not called during
presentation. See §4 for the tap-driven result.

## 2. `EKEventViewController`

Shows one event (`event`), with `allowsEditing` (Edit button) and
`allowsCalendarPreview`; delegate `eventViewController:didCompleteWithAction:`
with `EKEventViewAction` 0 done, 1 responded, 2 deleted. Needs full access
to have an event to show. Observed: presented inside a
`UINavigationController` for a probe event; presentation completes.

## 3. `EKCalendarChooser`

`initWithSelectionStyle:displayStyle:entityType:eventStore:` (selection
0 single, 1 multiple; display 0 all calendars, 1 writable only),
`selectedCalendars`, `showsDoneButton`, `showsCancelButton`; delegate
`calendarChooserSelectionDidChange:`, `calendarChooserDidFinish:`,
`calendarChooserDidCancel:`. Observed: presented inside a navigation
controller with full access.

## 4. Observed interaction

Probe runs on the fresh device (screenshots in `research/dirty/`, not committed):

| Step | Result |
|---|---|
| present edit controller from an app with events status 0 (no strings) or 2 (denied), prefilled title, location, start, end | presented as a "New Event" sheet: title, date and time line ("Tue, Oct 27, 2026 1PM–2PM"), location with a clear button, "Video Call or Conference", options Calendar (shows the default calendar's name and color although the app has no access), Alert None, Travel Time None, details; Cancel (×) and Add (✓) |
| tap Add (status 2 app) | delegate `didCompleteWithAction:` **1 (saved)** on the main thread; the controller's `event` in the app still has an empty title and nil identifier (the app learns nothing); the event **is stored** in the default calendar (level 2: a new row with the prefilled title in the device's calendar database) |
| present view controller for a probe event (full access) | presented in the navigation controller |
| present chooser (multiple selection, all calendars, full access) | "Calendars" list with sections "On My iPhone" (Calendar) and "Other" (US Holidays, marked Subscribed; Birthdays with a gift icon), an "Add Calendar" row, Cancel (×) and Done (✓) |
| select one calendar, tap Done | `calendarChooserSelectionDidChange:` (1 selected), then `calendarChooserDidFinish:` with 1 selected calendar |

## 5. What Ycode must provide

In-process UIKit controllers with these classes, properties and delegate
calls; the edit controller saves through the broker without read access
(`design.md` §7). Visual layout is Ycode's own; parity tests check classes,
delegate calls, actions and the resulting store contents, not pixels.

## Evidence

| Claim | Level |
|---|---|
| Classes, members, delegate selectors, enum values | 4 |
| Presentation without access, Add result and stored event, chooser content and delegate calls | 3 (+ 2 for the stored row) |
| Out-of-process editing without access since iOS 17 | 1 + 2 (`EventViewService.app`) |
