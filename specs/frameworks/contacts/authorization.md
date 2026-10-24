# Contacts spec: authorization, limited access and the access picker

Part of `specs/frameworks/contacts/`. Level 3 facts come from `CNProbe` and
its variants (`CNProbeLim` — a second app answered with limited access,
`CNProbeNone` — no usage string, `CNProbeNotes` — notes entitlement) on the
iOS 27.1 simulator; level 1 from Apple's public documentation in our words.

## 1. Keys and entitlements

| Item | Effect |
|---|---|
| `NSContactsUsageDescription` (Info.plist) | required for any store access; shown in the first prompt step |
| `com.apple.developer.contacts.notes` (entitlement, simulated-entitlements section in the simulator) | allows the `note` key (`interface.md` §2.2); in the reference simulator an ad-hoc build carrying it in `__TEXT,__entitlements` is accepted (level 3: the variant launched; level 1: on devices it needs Apple's approval) |

## 2. Status values

`[CNContactStore authorizationStatusForEntityType:CNEntityTypeContacts]`:
0 not determined, 1 restricted, 2 denied, 3 authorized (full), 4 limited
(iOS 18+). Per app, persistent.

## 3. Requesting

`requestAccessForEntityType:completion:` (also its Swift async form).
Completion on a global concurrent queue (`com.apple.root.default-qos`
observed), not main; `granted` YES for full **and** for limited access.

| Situation | Observed |
|---|---|
| status 0 | two-step prompt (§4); full → status 3, limited → status 4 |
| status decided | immediate answer, no UI (level 1; same pattern as EventKit) |
| **no request, first data call** (history token, fetch, save …) while status 0 | the same prompt appears and the call **blocks** until the user answers (15 s in our run), then proceeds with the new status |
| no usage string | see §3.1 |

### 3.1 Without `NSContactsUsageDescription`

Observed (`CNProbeNone -phase req`): the app is **terminated** at once by the
privacy system — crash report with exception type `EXC_CRASH` (`SIGABRT`),
termination namespace `TCC`, code 0, and a detail text saying that the app
attempted to access privacy-sensitive data without a usage description and
that its Info.plist must contain an `NSContactsUsageDescription` key. No
prompt appears. `authorizationStatusForEntityType:` alone does not
terminate. Ycode reproduces the termination with a message naming the key.

## 4. The prompt (iOS 18+, observed)

**Step 1 — system alert** over the app:

- app icon with the privacy-hand badge;
- title: Allow "‹App›" to access your contacts?
- the usage string;
- buttons side by side: **Don't Allow**, **Continue**.

**Step 2 — full-screen sheet** (after Continue):

- a grid of round monograms (initials) of the user's contacts — fresh
  device: AH, DH, DT, JA, KB, HZ;
- "You have N contacts." and a line saying that contact information includes
  names, emails, photos, phone numbers, addresses, and more;
- heading "How do you want to share contacts?" and an explanation that
  selecting contacts lets the user pick some now and add more later, while
  full access shares all current and future contacts;
- buttons stacked: **Select Contacts**, **Share All N Contacts**.

Share All → full access (3). Select Contacts → **step 3**, the selection
list → **step 4**, a confirmation → limited access (4). Don't Allow in
step 1 → denied (2).

**Step 3 — selection list** (title "Select Contacts", back button):
heading "Contacts", a search field with dictation, contacts in sections by
the sort key's initial with a round selection mark each, an index strip,
a header "Show Selected (N)" once something is selected, and buttons
**Continue** (disabled until at least one contact is selected) and
**Select Contacts Later**.

**Step 4 — confirmation**: the selected contacts' monograms, "Show Selected",
heading "Allow access to N contacts?", a text that the app will only have
access to the selected contacts' information (names, emails, photos, …),
buttons **Allow Selected Contacts** and **Not Now**.

Observed: Continue → Select Contacts → pick John Appleseed and Kate Bell →
Continue → Allow Selected Contacts: completion `granted` YES after the
interaction, status 4; the app then lists exactly those 2 contacts (plus
groups Friends and Work and the local container). The monogram order in
step 2 differed between two runs (not sorted).

Ycode draws its own alert and sheet with its own words and artwork, with the
same two steps and the same three outcomes.

## 5. Limited access

### 5.1 What a limited app sees (observed)

| Data | Visible |
|---|---|
| contacts the user picked | yes, with every key it may fetch |
| contacts the app created itself | yes (always) |
| other contacts | no — they do not exist for the app (counts, predicates, enumeration exclude them) |
| groups | **all** groups, including the user's (Friends, Work) |
| containers, default container | yes |
| deleting a picked contact | allowed (deletes it from the real store) |
| change history | events only for visible records; a bogus token returns the whole visible history (12 events in our run) instead of nothing |
| notifications | as for full access; the first one of a save may carry "originated externally" |

### 5.2 Adding more contacts later

- The picker can be shown again from the app with the SwiftUI modifier
  `contactAccessPicker(isPresented:completionHandler:)` (iOS 18), which calls
  back with the identifiers the user added.
- `ContactAccessButton(queryString:ignoredEmails:ignoredPhoneNumbers:approvalCallback:)`
  (iOS 18, SwiftUI) shows inline search results from contacts the app cannot
  see and grants one with a tap; styling via `contactAccessButtonStyle(_:)`
  (`ContactAccessButton.Style`: image trailing-edge padding, image width,
  image color) and `contactAccessButtonCaption(_:)` (`Caption`: `defaultText`,
  `email`, `phone`).
- The notify name `CNContactStoreLimitedAccessDidChangeNotification` is a
  launch event of `contactsd` (level 2); apps observe changes through the
  normal store notification (level 1).

These SwiftUI APIs were not probed (they need a Swift probe app; plan
C-CN-Q1). Their names are level 4 facts from the SDK's Swift interface.

### 5.3 Storage (level 2)

Granted contacts are recorded per bundle identifier in the `LimitedAccess`
table of `AddressBook.sqlitedb` (`simulator-baseline.md` §5): after the run
above, two rows (bundle `dev.ycode.cnprobe.lim`, the contact guid, sequence
numbers 2 and 3, active 1). Rows disappear when the contact is deleted
(trigger), which is why an earlier device that had deleted its granted
contact showed an empty table. TCC records the
level: `kTCCServiceAddressBook` with `auth_value` 3 for limited, 2 for full,
0 for denied.

## 6. `simctl privacy`

| Command | Status afterwards | TCC row |
|---|---|---|
| (fresh) | 0 | none |
| `grant contacts-limited` | **3** (not 4) | `auth_value` 2, `auth_reason` 4, version 2, flags 0 |
| `grant contacts` | 3 | same |
| `revoke contacts` | 2 | `auth_value` 0, `auth_reason` 4 |
| `reset contacts` | 0 | row removed |

So `simctl` cannot produce iOS 18 limited access; only the prompt can.
Ycode's `simctl` equivalent should keep these results for compatibility and
may add a separate, clearly named verb for limited access with a contact
list.

## Evidence

| Claim | Level |
|---|---|
| Key, entitlement, status values | 1 + 4 + 3 |
| Completion queue, granted YES for limited | 3 |
| Implicit prompt and blocking first call | 3 |
| Termination without usage string | 3 (crash report) + 1 |
| Prompt steps 1–4, texts, buttons | 3 (screenshots in `research/dirty/eventkit-contacts/`, not committed) |
| Limited visibility table | 3 |
| SwiftUI picker and button | 4 (names) + 1 (behavior) |
| `LimitedAccess` table rows, TCC values | 2 |
| `simctl privacy` table | 3 |
