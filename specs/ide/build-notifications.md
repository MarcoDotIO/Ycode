# Build notifications: the result bezel and system notifications

Ycode's design for the Behaviors action "Notify with bezel or system
notification" (`reference-ui.md` §4, `reference-ui-5.md` §9.4,
`settings.md` Behaviors). It applies to both IDEs: the AppKit IDE on macOS
(`YcodeUI`) and the SwiftUI shell (`ycode-ide`, on OpenViews on Linux).

Sources: Apple's public documentation on Behaviors (Settings ▸ Behaviors
lists events such as "When build succeeds" and "When build fails", each
with actions, one of which notifies "with bezel or system notification"),
the reference defaults recorded in `reference-ui.md` §4, and the project
owner's description of what the reference shows. Every size, colour and
duration below is **Ycode's own choice**; none was measured from the
reference.

## 1. Events

| Event (row title) | Category | Raised when | Default actions |
|---|---|---|---|
| When build succeeds | Build | a build, clean or analyze finishes with no error | Notify |
| When build fails | Build | a build, clean or analyze finishes with an error (after "When build generates errors" when there are errors) | Notify |
| When testing succeeds | Testing | a test run finishes and every test passed ("Test Succeeded", or "Test Completed" for selected tests) | Notify (Ycode's choice: the reference lists four Testing behaviors but their actions were not recorded) |
| When testing fails | Testing | a test run finishes with a failure ("Test Failed") | Notify (as above) |

The other Build and Running events are unchanged (`settings.md`); any of
them can be given the Notify action in Settings ▸ Behaviors and then
notify as below, with the event's own title.

"Run failed" and "Run Failed" (a run that could not launch) raise "When
running exits unexpectedly", never "When build fails".

The event decision (activity → events) is one type in `YcodeIDECore`,
`BehaviorEventTracker`, used by both IDEs; `BuildNotificationPolicy`
turns an event and its activity text into the notification's content and
picks its route.

## 2. Content

| Event | Title | Glyph |
|---|---|---|
| Build succeeds | the activity text: "Build Succeeded", "Clean Succeeded", "Analyze Succeeded" | hammer |
| Build fails | "Build Failed" (or "Clean Failed", "Analyze Failed") | hammer |
| Testing succeeds | "Test Succeeded" ("Test Completed" for selected tests) | checkmark in a circle |
| Testing fails | "Test Failed" | cross in a circle |
| any other event with Notify | the event's title without "When " ("Running completes") | play triangle for Running events, hammer for Build events |

The glyph is drawn by Ycode: on macOS the system's symbol API is used at
run time by name (as the IDE's toolbar already does). In the SwiftUI shell
the hammer is Ycode's own outline (`HammerGlyph` in `ycode-ide`: a head
with a flat face and a tapered claw over a tapered handle, tilted 40°,
stroked 4.5 pt with round joins), and the other glyphs are OpenViews' own
drawings (`frameworks/swiftui`'s symbol set). No picture is copied.

## 3. Route: bezel or system notification

- **Bezel** when the workspace window is on screen, not minimised, is the
  key window and the app is active. In OpenViews the window's scene phase
  stands for all of these: `active` → bezel, `inactive` or `background` →
  system notification (OpenViews does not yet report keyboard focus
  moving to another application's window as a phase change).
- **System notification** otherwise (window minimised, hidden, behind
  another app's window, or the app in the background):
  - macOS: `UserNotifications` (title = the content's title, body = the
    workspace name). Authorisation is requested once, the first time a
    notification is needed. If it is denied, unavailable (a process with
    no app bundle, such as a test runner) or fails, Ycode bounces the Dock
    icon instead (`requestUserAttention(.informationalRequest)`), and says
    nothing.
  - Linux: `org.freedesktop.Notifications.Notify` on the session bus
    (app name "Ycode", summary = title, body = workspace name, expire
    timeout −1 = the server's default), through OpenViews' own D-Bus
    client. If there is no session bus, or no name owns
    `org.freedesktop.Notifications`, nothing is shown and nothing is
    logged as an error.

## 4. The bezel

Layout (points):

| Part | Value |
|---|---|
| Size | 200 × 200, centred in the window's content area |
| Corners | radius 18 |
| Material | dark and translucent in both appearances and on both platforms: near-black (white 0.08) at 86 % opacity (enough that text behind it does not compete with the title), drawn by the bezel itself (so an offscreen snapshot shows it as the window does); no blur |
| Glyph | a symbol in a 112 × 96 box (80 pt, light weight on macOS), white at 90 %, centred horizontally, the box 40 from the top |
| Label | one line, 17 pt semibold, white, centred, 28 from the bottom; truncated in the middle if too long |
| Hit testing | none: clicks pass through to the window |

Timing:

- Appears at full opacity at once (no fade in).
- Stays fully visible for **1.6 s**, then fades to transparent over
  **0.35 s** (ease-out), then is removed.
- **Repeated notifications replace the bezel, they never stack**: a new
  one swaps the content and restarts the 1.6 s; the earlier one's pending
  fade and removal are cancelled (each show has a generation number; a
  timer only acts on its own generation).
- **Reduce Motion** (macOS: the accessibility display setting; OpenViews:
  `accessibilityReduceMotion`): no fade; the bezel is removed at once
  after 1.6 s.

Accessibility: each bezel posts an announcement with its title (macOS:
`announcementRequested` at high priority; OpenViews:
`AccessibilityNotification.Announcement`). The bezel itself is not a
focusable element.

## 5. Settings

Settings ▸ Behaviors lists the Testing events under Testing; the
"Notify with bezel or system notification" action can be added to or
removed from any event. The Notifications pane's per-event toggle is the
same flag. Stored as before under `Ycode.behavior.<caseName>`.

## 6. Open questions (for the dirty room)

1. The reference's default actions for the four Testing behaviors.
2. Whether a test run also shows the build's bezel before the test
   result (Ycode shows only what the activity reports).
3. Whether the reference uses a different glyph for failure.

## Evidence

| Claim | Level |
|---|---|
| Event names, the action's label, success/failure defaults (§1) | 1 (public Behaviors documentation) and the recorded reference defaults (`reference-ui.md` §4) |
| What the bezel looks like in general (dark translucent square, hammer, one-line result, short display then fade) | owner's description |
| Every number, the route rule, replacement, Reduce Motion, the fallbacks (§2–§4) | Ycode's own design |
| `UserNotifications`, `NSAccessibility` announcements | 1 (Apple's public API documentation) |
| `org.freedesktop.Notifications` | freedesktop.org Desktop Notifications Specification (public) |
