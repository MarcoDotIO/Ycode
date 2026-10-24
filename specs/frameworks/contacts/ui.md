# Contacts spec: ContactsUI controllers

Part of `specs/frameworks/contacts/`. Names are level 4; behavior is level 3
(`CNProbe -phase uipicker|uinew|uiunknown`) where marked, otherwise level 1
(Apple's documentation in our words). The SwiftUI access picker and button
are in `authorization.md` §5.2.

## 1. `CNContactPickerViewController`

Presented modally; shows the user's contacts and returns a selection to the
app **without** the app needing contacts access (the picker runs out of
process: the `com.apple.people-picker` extension
`ContactsViewService.appex`, level 2).

| Member | Meaning |
|---|---|
| `displayedPropertyKeys` | which properties are shown in a contact's detail (property picking) |
| `predicateForEnablingContact` | contacts that can be chosen (others greyed) |
| `predicateForSelectionOfContact` | when true, tapping a contact selects it; otherwise its details open |
| `predicateForSelectionOfProperty` | which properties can be selected |
| `delegate` | `CNContactPickerDelegate` |

Delegate (the app implements one selection style): `contactPickerDidCancel:`,
`contactPicker:didSelectContact:` (single), `contactPicker:didSelectContacts:`
(multiple — implementing it turns on multi-selection),
`contactPicker:didSelectContactProperty:`,
`contactPicker:didSelectContactProperties:`. The picker dismisses itself
after a selection or cancel. The returned contacts are snapshots with the
keys the picker provides (level 1: all displayed keys).

## 2. `CNContactViewController`

Factories: `viewControllerForContact:` (existing, fetched with
`descriptorForRequiredKeys`), `viewControllerForUnknownContact:` (a contact
not in the store, e.g. from a call; offers create / add to existing),
`viewControllerForNewContact:` (editing form for a new contact, optionally
prefilled). Properties: `contact`, `displayedPropertyKeys`, `contactStore`
(needed for saving), `parentGroup`, `parentContainer`, `alternateName`,
`message`, `allowsEditing`, `allowsActions`, `shouldShowLinkedContacts`;
`highlightPropertyWithKey:identifier:`. Delegate:
`contactViewController:didCompleteWithContact:` (nil when cancelled),
`contactViewController:shouldPerformDefaultActionForContactProperty:`.
Runs as the `com.apple.contact-view` extension (`ContactViewViewService.appex`,
level 2).

## 3. Observed

| Step | Result |
|---|---|
| picker presented by an app **without** a usage string and status 0 | presents normally (no termination, no prompt); a banner at the top reads "Private Access to Contacts" and explains that the contacts are shown but the app can only access the ones the user selects; all contacts listed by section with an index strip; cancel and search buttons |
| tap one contact (only `contactPicker:didSelectContact:` implemented) | delegate called on the main thread with a `CNContact` carrying the contact's **store identifier** and its names, organization, job title, birthday, phones, emails, postal addresses and URLs |
| afterwards | no TCC row and no `LimitedAccess` row for the app: picking grants nothing persistent; status stays 0 |
| `viewControllerForNewContact:` prefilled "Prefilled Probe", in a navigation controller, full-access app, `contactStore` not set | "New Contact" form with monogram, Add Photo, the name fields (first focused, keyboard shown; on a fresh device a one-time keyboard tip covers the keyboard) and Done/Cancel |
| tap Done | `contactViewController:didCompleteWithContact:` with the new contact; the contact **is saved** in the store (identifier `<UUID>:ABPerson`) although no store was set |

## 4. What Ycode must provide

In-process UIKit controllers with these classes, properties and delegate
calls. The picker must not grant the app store access: it hands over only
what the user selected. Parity tests check classes, delegate calls and the
returned contacts/properties, not pixels.

## Evidence

| Claim | Level |
|---|---|
| Classes, members, delegate selectors | 4 |
| Out-of-process picker and contact view | 1 + 2 (extension points) |
| Delegate semantics | 1 |
| Observed presentations, delegate results, store side effects | 3 |
