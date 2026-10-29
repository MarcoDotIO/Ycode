# Spec: Device Hub (the simulator and device window)

Status: **proposed** (OBS-DEVHUB, 2026-10-28); Ycode's implementation
in §I (HUB-UI, 2026-10-28). It tells a clean
implementer how the reference's Device Hub looks and behaves as a window,
so that Ycode's simulator window can be rebuilt to match. Reference:
Xcode 27.1 (Device Hub 27.1, build 255.6.6.1) on macOS 27.2. Dirty-room
notes: `research/notes/obs-devhub-2026-10-28.md`.

Xcode 27 has **no Simulator.app**. Simulators and physical devices are
shown and controlled in Device Hub, an app inside the Xcode bundle. Xcode's
"Manage Devices…" (run-destination pop-up, Product ▸ Destination) and
Xcode ▸ Open Developer Tool ▸ Device Hub open it; running an app on a
simulator opens that simulator's compact window.

**Already specified elsewhere (not repeated):**

- the Settings inspector's boxes and the Device / Controls menu items for
  appearance, accessibility, location and sound: `specs/simulator/simulator-features.md` §7.1;
- the iPhone Duo fold mechanism and its poses: `specs/simulator/foldable.md` §3, §4;
- visionOS canvas input and camera modes: `specs/simulator/visionos.md` §5.1;
- Ycode's current Devices and Simulators window: `specs/ide/devices.md`;
- the toolbar's glass metrics shared with the workspace window: `specs/ide/liquid-glass.md` §1, §2.2.

**Rules for the implementer.** Labels in quotation marks are exact. Shapes
and symbols are described in words: Ycode draws its own glyphs and device
frames (AGENTS.md rule 5; no Apple artwork, no device photographs). Colours
are system materials and semantic colours only. Sizes are in points; "AX"
means an accessibility frame, "drawn" means the visible shape. **Ycode
decision** marks a choice the reference does not dictate.

## 1. Summary

1. Two window kinds: one **hub window** (sidebar, canvas, inspector) and
   **compact device windows** (one device, no sidebar or inspector). A
   compact window expands into the hub; the hub opens a selected device in
   a compact window. Hub windows support macOS window tabs.
2. The **sidebar** lists simulators and paired devices in sections by
   availability, with a search field, an Add Device menu and a Filter menu.
3. The **canvas** shows the selected device: its live screen inside a
   device frame ("bezel") when it runs, otherwise a status view with an
   action button (Start, View Screen, Pair). Below the device sits a row of
   **device controls** in glass capsules (Home, Screenshot, Record, Rotate,
   and per-device extras such as the iPhone Duo poses).
4. The **inspector** has three tabs, Settings, Reports and Info; Info has
   sub-tabs Info, Apps, Profiles.
5. The **toolbar** is a unified, background-less toolbar of glass capsules,
   with the device's name and OS version as title and subtitle.

## 2. Window kinds

### 2.1 Hub window

- Title: the selected device's name; subtitle: platform and OS version
  ("iOS 27.0", "tvOS 26.5", "visionOS 27.0"). Nothing selected: title
  "Devices", subtitle "No Selection"; window title (Window menu, Mission
  Control) "Devices – No Selection", Window-menu entry "Devices (No
  Selection)".
- Default size observed: 1100 × 800, resizable. Areas (window 1100 wide):

  | Area | x range | Background | Notes |
  |---|---|---|---|
  | Sidebar | 0–240 | system sidebar background, full height including under the window buttons | no divider line to the canvas |
  | Canvas | 240–820 | plain window (content) background | takes all extra width when the window grows |
  | Inspector | 820–1100 (280 wide) | same kind as the sidebar | one-point divider line at its left edge |

- **Hide Sidebar** (toolbar button or View ▸ Hide Sidebar): the window keeps
  its width and the canvas takes the sidebar's space; the Add Device /
  Filter capsule goes with the sidebar; the toggle (now "Show Sidebar")
  moves next to the window buttons and the title follows it. The inspector
  does not move.
- **Hide Inspector**: View ▸ Inspectors ▸ Hide Inspector (behaviour of
  clicking the selected tab: OPEN Q4).
- **Tabs**: File ▸ New Tab, View ▸ Show Tab Bar / Show All Tabs, Window ▸
  Show Previous Tab / Show Next Tab / Move Tab to New Window / Merge All
  Windows (standard window tabbing). File ▸ New Window opens another hub
  window.
- **Persistence** (per user, survives relaunch): window frame and split
  widths, the last selected device, the selected inspector tab and the
  sub-tab chosen in each tab, which sidebar sections are collapsed, and
  whether the sidebar is shown.

### 2.2 Compact device window

- Opens when an app is run on a simulator from Xcode, from the hub's
  **Open in New Window** button ("Switch to compact window"), and by
  selecting several devices and double-clicking them in the sidebar (one
  compact window each).
- Layout, top to bottom: a toolbar with the window buttons, title (device
  name) and subtitle (OS) at the left and one capsule at the right with
  **Expand** (two arrows pointing outward along a diagonal; help "Expand to
  view all controls") and **More Actions** (…); the device in its frame;
  the device-control row (§4.4) centred below it, about 6–10 points above
  the window's bottom edge. No sidebar, inspector, zoom controls or status
  line.
- The device fills the width with a small margin (about 17 points each
  side for an iPhone). **Resizing the window scales the device**; the
  window keeps the device's aspect plus the toolbar and control row.
  **Rotating the device reshapes the window** (portrait → a tall window,
  landscape → a wide one). A saved compact iPhone window was 296 × 620.
- Expand turns the window into (or opens) the hub window with that device
  selected (whether the compact window closes: OPEN Q5).

### 2.3 Other windows

- **New Simulator** dialog (File ▸ New Simulator ▸ iPhone… / iPad… / Apple
  Watch… / Apple Vision Pro… / Apple TV…, or the Add Device menu): a
  grouped form of three rows, "Name:" (text field, placeholder = the model
  name), "OS Version:" (pop-up, e.g. "visionOS 27.0"), "Model:" (pop-up),
  then a separator and "Cancel" and "Create" (default) at the bottom right.
  The new simulator appears under Available.
- **Pair Nearby Device…**: a sheet with device-type buttons at the top and
  per-type instructions; then a PIN step. Not needed by Ycode.
- **Settings window**: the app menu shows no Settings… item; the app's
  strings name four options (OPEN Q3): "Simulate hardware keyboard by
  default", "Capture keyboard shortcuts" ("Most keyboard shortcuts will be
  sent to the device or simulator when active."), "Secure keyboard entry",
  "Stop simulators on quit". A preference (no UI seen) chooses how key
  combinations are split between Device Hub and the device: 0 rich
  shortcuts, 1 minimized while interacting, 2 minimal shortcuts.
- **Quit**: "Quit Device Hub" and "Quit and Keep Simulators Running" (and,
  by strings, "Quit and Shutdown Simulators"): quitting can shut down the
  simulators it started.

## 3. Toolbar (hub window)

Items left to right (AX frames for the 1100-point window; drawn shapes
follow `liquid-glass.md` §2.2: glass, about 36–38 tall, top at about
y 8, neighbours about 6–7 apart, no bar background or bottom line):

| # | Item (accessibility name) | Kind | AX frame | Drawn | Does |
|---|---|---|---|---|---|
| 1 | window buttons | — | x 18, 41, 64 (16 × 16) | — | — |
| 2 | "Add Device" | menu button, plus symbol | 118,12 30 × 28 | shares a capsule with 3, about x 113–189 | menu: simulator kinds (as File ▸ New Simulator) and "Pair Nearby Device…" |
| 3 | "Filter" | toggle that opens a menu; three horizontal lines of decreasing length | 153,12 31 × 28 | (with 2) | §5.3 |
| 4 | "Hide Sidebar" / "Show Sidebar" | button, sidebar symbol | 192,0 44 × 52 | circle about 195–233, ends 7 before the sidebar edge | §2.1 |
| 5 | title / subtitle | text | 244,0 287 × 52 | text from about x 260 | §2.1 |
| 6 | "Capture Keyboard" | toggle, keyboard symbol | 535,8 37 × 36 | circle, or one capsule with 7 | §4.6 |
| 7 | "Enter resize mode" / "Exit resize mode" | toggle, a rectangle with an inner panel | (shown only with a device) | with 6 | §4.7; selected = filled with the accent colour |
| 8 | "Zoom Out" · Zoom to Fit · "Zoom To Actual Size" · "Zoom In" | four segments (radio buttons), magnifier symbols (minus; a fit mark; "1"; plus) | 581, 618, 656, 693 (37–38 × 36) | one capsule about 580–732 with thin dividers | §4.2 |
| 9 | "Open in New Window" | button, two arrows pointing inward along a diagonal | 736,0 40 × 52 | capsule about 739–814 shared with 10 | §2.2 |
| 10 | "More Actions" | menu button, ellipsis | 779,12 30 × 28 | (with 9) | Shut Down, Restart (OPEN Q6) |
| 11 | inspector tabs | three segments: sliders symbol (Settings), document symbol (Reports), "i" (Info) | 981, 1018, 1055 (37 × 36) | capsule about 980–1093, 7 from the window's right edge, over the inspector | §6 |

- Items 6–10 sit together at the right end of the canvas area and are
  dimmed while nothing is selected. Item 7 is absent with no device and
  disabled for devices that cannot resize (physical, visionOS, older SDKs).
- Selected segment / on toggle: a recessed pill inside the capsule (as
  `liquid-glass.md` §2.2 item 4); the Zoom to Fit segment is selected by
  default; the resize toggle shows the accent fill when on.

## 4. Canvas

### 4.1 What it shows

| Selection | Canvas |
|---|---|
| none | "No Selection" centred, secondary text |
| several devices | "Multiple Devices Selected" |
| a simulator that is not running | a status view: a large picture of the device, its name, its OS ("tvOS 26.5"), and a **Start** button (Device ▸ Start does the same) |
| a simulator starting | OPEN Q1 (the app has a booting banner and a "Starting" state) |
| a running simulator | its live screen in the device frame, with the device controls below |
| a paired physical device | the status view with **View Screen** (a screen-with-person symbol and the label); once clicked, its live screen as for a simulator. Unpaired: instructions and **Pair** |
| a device with a problem | the issue (for example "Enable Developer Mode", "Pairing Required", "Screen Sharing Unavailable", "Connecting display", "Live device view took longer than expected to connect.") |

The device is centred both ways in the canvas. Below it, centred, the
device-control row (§4.4). For an iPhone paired with a watch simulator a
capsule button "Paired with <watch name> ›" sits between the device and
the controls.

### 4.2 Scale and zoom

- **Zoom to Fit** (default): the device (frame included) is scaled to fit
  the canvas with a margin; it rescales as the window or the split views
  resize.
- **Zoom In / Zoom Out**: step the scale; the canvas scrolls when the
  device is larger than it (step sizes: OPEN Q7).
- **Zoom To Actual Size** (View ▸ "Physical Size"): the device at its
  real-world size on the Mac's display. Disabled for visionOS.
- View menu: Zoom In, Zoom Out, Zoom to Fit, Physical Size. Device Hub has
  **no** point-accurate or pixel-accurate sizes (public feedback lists
  them as missing).
- Compact window: no zoom controls; window size sets the scale (§2.2).

### 4.3 Device frame ("bezel")

- iPhone, iPad, Apple Watch: the screen is drawn inside a frame resembling
  the device: a thin dark band of even width all round, outer corners
  concentric with the screen's corners, side buttons as short raised bars
  on the edges (volume and action on the left, side button on the right of
  a portrait iPhone), drawn flat with a slight shade. The Dynamic Island or
  notch belongs to the screen picture, not the frame. Ycode draws its own
  frame from the device type's screen size and corner radius.
- Frame parts are **clickable**: Sleep/Wake (click = Lock, hold = Siri), Volume Up / Down (click
  or hold), Action button; on a watch the Digital Crown (click; scroll over
  it to turn it) and side button.
- View ▸ "Show Bezels" / "Hide Bezels" toggles the frame; hidden, the
  screen shows with its rounded corners only.
- **iPhone Duo**: shown as a perspective view of the device in its pose
  (closed: the cover panel; partially open: the two halves meeting at a
  shallow angle, seen from the front; open: one flat panel). Which panel
  is lit follows `foldable.md` §3.
- **visionOS**: no frame; the simulated eye view fills the canvas width
  with rounded corners (`visionos.md` §5.1).
- **tvOS**: the TV picture (frame: OPEN Q2).

### 4.4 Device controls row

Glass capsules and circles about 37 tall, 6–8 apart, centred under the
device. Symbols in words:

| Device | Groups, left to right |
|---|---|
| iPhone, iPad simulator | [Home (a 3 × 3 grid of dots) · Screenshot (a camera inside a viewfinder frame) · Record (a dot in a ring)] [Rotate (a square with a curved arrow at two corners)] |
| physical iPhone or iPad | [Home · Screenshot] [Rotate] (no Record; video is simulator-only) |
| iPhone Duo | [Home · Screenshot · Record] [Rotate │ Closed (a closed phone) · Partially Open (an open book seen from above) · Open (a flat tablet)]; the current pose's button is highlighted |
| Apple Watch | side button and Digital Crown controls (labels OPEN Q2) |
| Apple TV | play/pause and navigation controls (labels OPEN Q2) |
| visionOS | [Home · Screenshot · Record] [interaction modes and Reset Camera] [Capture Pointer] … as `visionos.md` §5.1; compact window also [keyboard capture] [Simulated Scenes] [More …] |
| any device in resize mode | [Screenshot · Record] [a size field "667 × 428"] |

Behaviour:

- **Rotate**: click = Rotate Left, Option-click = Rotate Right (also
  Controls ▸ Rotate Left / Rotate Right; Device ▸ Orientation ▸, whose items include Portrait Upside Down, Face Up
  and Face Down; Face Up/Down do not turn the picture; full list OPEN Q13). The frame turns with
  the device and the compact window reshapes. With orientation lock on in
  the guest: alert "Orientation Locked", "Unable to rotate device.
  Orientation lock enabled." The turning animation: OPEN Q8.
- **iPhone Duo poses**: the three buttons move the hinge to closed,
  partially open and open (`foldable.md` §3.2, §4). **Option-drag** shows a
  slider below the frame to set any angle. There is no always-visible
  hinge slider.
- **Screenshot** (Controls ▸ Screenshot, **⇧⌘S**): saves a PNG of the
  screen at the device's full resolution, whatever the Mac display, to the
  Desktop, or to the user's chosen screenshot location; works without an
  interactive session. Feedback text "Screenshot Saved" (presentation:
  OPEN Q9).
- **Record** (Controls ▸ Record Screen): the button becomes **Stop**
  (Controls ▸ Stop Recording); the movie goes to the Desktop, named
  "Screen Recording" + the device name + a timestamp. If the device goes
  away: "Screen recording was stopped because the device disconnected."
- **Home**: Controls ▸ Home. Lock, Siri, App Switcher, Action Button,
  Shake are in the Controls menu only.

### 4.5 Pointer and touch on the screen

| Mac input | Device receives |
|---|---|
| click | tap (a direct finger touch) |
| double-click | double tap |
| click and hold | touch and hold |
| drag | one-finger drag; drag and drop = hold until the item lifts, then drag |
| scroll (wheel or trackpad) | scroll events (iOS 27 and later), not a finger drag |
| trackpad pinch / rotate | transform events (iOS 27 and later) |
| Option-drag | **nothing special**: Device Hub sends no two-finger touches (known issue) |

Device ▸ Keyboard ▸ "Simulate Trackpad or Mouse" switches to a true
pointer device; "Simulate Hardware Keyboard" and "Toggle Software
Keyboard" handle the keyboard. Input works only for iOS 18 / tvOS 18 /
watchOS 11 / visionOS 2 and later. tvOS: arrow keys move focus, Return
selects, Escape goes back.

### 4.6 Keyboard capture

"Capture Keyboard" (toolbar toggle; Device ▸ Keyboard ▸ Keyboard Capture
for visionOS) routes the Mac's keystrokes, including most shortcuts, to the
device. While on, a notice "Capturing Keyboard" / "Hold Escape to cancel"
is shown; holding Escape ends it.

### 4.7 Resize mode (iPhone, apps built with the iOS 27 SDK)

"Enter resize mode" hides the frame, Home and Rotate; the screen shows with
rounded corners and a short grab bar centred on each of its four sides;
dragging a bar resizes the app's screen, or the user types a size in the
"W × H" field below; the size snaps to the nearest valid size; "Exit resize
mode" restores. **Ycode decision**: not built until Ycode's guest supports
resizable scenes; the toggle is omitted.

## 5. Sidebar

### 5.1 Content and sections

- Lists the simulators added in Device Hub or used as run destinations
  (Ycode: every simulator in Ycode's device set) and paired physical
  devices.
- Grouped by availability: **"Available"** then **"Unavailable"**
  (disconnected or unsupported devices). Each section header is a small
  secondary-text label that collapses and expands the section when clicked;
  the collapsed state persists.
- Search field at the top (x 10–230, 28 tall, placeholder "Search", clear
  button at its right end) filters by name as you type. No match: a
  magnifying-glass symbol and "No Results for “<text>”" with "Check the
  spelling or try a new search." centred in the sidebar.

### 5.2 Rows

- Row 46 tall, content inset 10 from both sides of the 240-point sidebar:
  - a 32-point circle with the device-class glyph (phone, tablet, watch,
    TV, headset). **Running or connected: the glyph in colour with a lit
    screen on a white disc. Not running or not connected: the same glyph
    in grey on a grey disc.** No textual state badge.
  - name (body text, truncated at the tail) over a subtitle in secondary
    text: "Simulator" for simulators, the model name ("iPhone 12 Pro Max")
    for physical devices;
  - the OS version, major.minor, right-aligned in secondary text, 16 from
    the sidebar's right edge.
- Selection: a rounded rectangle with the content inset; accent-coloured
  while the sidebar has focus, neutral grey otherwise. Several rows can be
  selected (§4.1); double-click opens compact windows.
- **Context menu** (Control-click): Start / Shut Down / Restart for
  simulators, Remove (with "Removing these devices will make them
  unavailable as run destinations in Xcode."), Unpair and Stop Screen
  Sharing for physical devices, pairing an iPhone simulator with a watch
  simulator. Full order: OPEN Q6. File ▸ Rename… renames the selected
  device.

### 5.3 Filter and sort

The Filter control opens a menu: **All Devices** (default, checked),
**Simulators**, **Physical Devices**, a separator, **Sort By ▸** (options:
OPEN Q10). In Apple's screenshots the Filter button is drawn filled while
its menu is open or a filter applies.

## 6. Inspector

280 wide, its own tab capsule in the toolbar over it (§3 item 11). Order:

1. **Settings** (sliders symbol): the boxes of `simulator-features.md`
   §7.1. Rows are 32–36 tall with a leading symbol, the label, and the
   control at the trailing edge (pop-ups show the value with a small
   up/down chevron; switches; sliders with tick marks); the rows of a box
   share one rounded group background with inset separators; boxes are
   about 10 apart. tvOS shows Appearance, Increase Contrast, VoiceOver and
   Location only. visionOS adds a **Simulated Scenes** row whose button
   opens a popover titled "Simulated Scenes" with a two-column grid of
   scene thumbnails and names (`visionos.md`). Not running: "Start the
   simulator to customize behavior and appearance."
2. **Reports** (document symbol): the device's diagnostic reports
   (crashes, spins and others), Show in Finder, and a sysdiagnose action.
   Empty: "No Diagnostic Reports" / "No Crash Reports".
3. **Info** ("i" symbol): a three-segment control across the top, **Info
   · Apps · Profiles**.
   - Info: key-value rows in rounded group boxes, label leading and value
     trailing in secondary text: Name, OS; then Capacity, ECID, Model,
     Serial Number, UDID (under "Hardware Properties"), and for simulators
     their own properties. A centred **Edit Visibility** button below lets
     the user choose the rows (Done to finish).
   - Apps: a list of installed apps (icon, name, bundle identifier
     truncated at the head, version trailing), "+" and "−" buttons below
     it, and at the bottom of the inspector a "Filter" search field with a
     pop-up ("Developer"; also "All Apps", "App Clips", …). App data
     containers can be downloaded and replaced.
   - Profiles: configuration and provisioning profiles; drop a profile on
     the list to install it.

## 7. Menus and shortcuts

Menu bar: Device Hub, File, Edit, View, Device, Controls, Window, Help.

- File: New Simulator ▸ (iPhone…, iPad…, Apple Watch…, Apple Vision Pro…,
  Apple TV…), Pair Nearby Device…, New Tab, New Window, Rename…, Close,
  Close All.
- Edit: the standard items, then Use Shared Clipboard, Get Clipboard,
  Send Clipboard (host ↔ device pasteboard).
- View: Show Tab Bar, Show All Tabs, Filter, Hide Sidebar, Inspectors ▸
  (Settings, Reports, Info, Hide Inspector), Zoom In, Zoom Out, Zoom to
  Fit, Physical Size, Enter Full Screen; Show Bezels / Hide Bezels when a
  device with a frame is shown.
- Device: **Start** (not running) or **Restart** (running), Shut Down,
  Force Shut Down, Accessibility ▸, Appearance ▸, Battery ▸ (100%, 75%,
  50%, 25%), Face ID ▸ / Touch ID ▸ / Optic ID ▸ (each: Enrolled,
  Authorized with …, Unauthorized with …), Location ▸, Orientation ▸, Sound
  ▸, Enter Resize Mode, Keyboard ▸, Slow Animations, Pair Apple Watch…,
  Reset Content and Settings… (Apple's instructions shut the device down first). Items appear
  only for devices that support them (`simulator-features.md` §7.1 for
  the submenus not listed here).
- Controls: Home, Lock, Siri, App Switcher, Action Button, Rotate Left,
  Rotate Right, Shake, Screenshot, Record Screen / Stop Recording.
- Window: standard items and tab items, then one item per window.
- Help: Send Device Hub Feedback, Device Hub Help.

Key equivalents: **Screenshot ⇧⌘S** (stated by Apple). All others are
OPEN (Q9 in `simulator-features.md`). Public feedback notes that ⌘W did
not close the window in the first seeds. **Ycode decision** for the rest,
until observed: keep Ycode's current ones (⇧⌘H Home, ⌘L Lock, ⌘← / ⌘→
rotate, ⌥⌘↑ / ⌥⌘↓ volume) and move Screenshot from ⌘S to ⇧⌘S.

## 8. Look

- Toolbar: unified style, no bar background or separator; every item is a
  glass capsule or circle, grouped as in §3 (`liquid-glass.md` §1, §2.2:
  toolbar item groups, tracking separators over the sidebar and the
  inspector). The title and subtitle are the system's toolbar title and
  subtitle.
- Split layout: a sidebar with the system sidebar background that runs to
  the window's top edge, a content area with the plain window background,
  an inspector area with the same background kind as the sidebar and a
  one-point divider. No floating panels, no inset cards around areas.
- Canvas: plain content background in both appearances; the device
  controls are glass shapes floating over it (glass, not a bar).
- Sidebar list: standard sidebar list style; section headers in small
  secondary text; rows as §5.2.
- Inspector: grouped-form style (rounded group boxes, inset separators,
  leading symbols); segmented control for Info · Apps · Profiles.
- Text: title in the toolbar's title style (about 13, semibold), subtitle
  smaller in secondary colour; row name in body size, subtitle and version
  in small secondary text; empty-state messages in secondary text.
- Symbol names: Ycode picks public SF Symbols that match the descriptions
  (**Ycode decision**; the reference's own symbol names were not read).

## 9. What Ycode must change (priority order)

Ycode today: `ycode-sim-viewer` is a separate titled window ("Ycode
Simulator Viewer") with the stream filling the content, a footer of small
push buttons (Home, Lock, Vol +, Vol −, Rotate, Screenshot), a fold bar
(segmented Closed / Half Open / Open Flat, an always-visible hinge slider,
Rotate Left / Right) and a status line (phase, fps, KB/s, latency); menus
App, File (Save Screenshot ⌘S, Close), Device (Home, Lock, Volume, Rotate,
Fold ▸, Refresh Display), Window (Half Size ⌘1, Point Accurate ⌘2, Pixel
Accurate ⌘3). The IDE's Devices and Simulators window (`devices.md`) is a
Devices / Simulators switch, a table and key-value details, read-only,
with fold controls under the details. (FEAT-IMPL is adding feature menus
and Devices controls at the same time; coordinate file ownership.)

1. **Compact device window** replaces the viewer window (§2.2): unified
   toolbar with device name and OS as title and subtitle, the Expand │
   More Actions capsule, the device centred, glass device-control row at
   the bottom (Home, Screenshot, Record │ Rotate), window aspect following
   the device and its orientation, window size = scale. Remove the push
   buttons and the footer.
2. **Hub window** replaces the Devices and Simulators window, opened by
   "Manage Devices…" (⇧⌘2) (§2.1, §3, §5, §6): sidebar with the Available /
   Unavailable sections and rows of §5.2 (coloured glyph = running,
   grey = not), search and Filter menu; canvas showing the selected
   device's live screen, or its status view with **Start**; inspector with
   Settings / Reports / Info. The Devices / Simulators switch becomes the
   Filter menu (All Devices, Simulators, Physical Devices). "Open in New
   Window" and "Expand" move a device between the two window kinds.
3. **iPhone Duo controls** (§4.4): the three pose buttons (Closed,
   Partially Open, Open) in the capsule after Rotate; Option-drag shows the
   hinge slider; drop the always-visible slider and segmented control.
   Rename Ycode's "Half Open" / "Open Flat" to the reference's "Partially
   Open" / "Open" in the controls (`foldable.md` §4 names).
4. **Device frame** (§4.3): Ycode-drawn frame per device type (screen
   size, corner radius, button positions from the device type), clickable
   buttons, View ▸ Show / Hide Bezels; Duo pose view; no frame for
   visionOS.
5. **Zoom** (§4.2): toolbar segments Zoom Out, Zoom to Fit (default),
   Actual (physical) Size, Zoom In and the View-menu items; retire Half
   Size / Point Accurate / Pixel Accurate (keep pixel-accurate as a Ycode
   extra only if wanted).
6. **Menus** (§7): Device and Controls menus with the reference's items
   and order, contextual to the device; Screenshot ⇧⌘S; Record Screen /
   Stop Recording; Start / Restart / Shut Down / Force Shut Down; Edit's
   clipboard items when Ycode syncs the pasteboard.
7. **Rotation** (§4.4): one Rotate control (click left, Option-click
   right) instead of two buttons; the frame and compact window turn.
8. **Screenshot and recording feedback** (§4.4): save to the Desktop (or
   the configured location), show "Screenshot Saved"; Record toggles to
   Stop and names the file "Screen Recording <device> <time>". Recording
   is new work for Ycode's stream.
9. **Status line**: Device Hub has none. Move fps / KB/s / latency to a
   debug option (for example under More Actions); keep boot progress in
   the canvas status view instead.
10. **Keyboard capture** toggle with the "Capturing Keyboard" / "Hold
    Escape to cancel" notice (§4.6); today Ycode forwards non-⌘ keys
    whenever the screen has focus.
11. **Scrolling** (§4.5): the reference sends scroll events, not a drag;
    Ycode keeps its scroll-as-drag until its guest path can deliver scroll
    events. Ycode's Option-drag two-finger gestures stay as a **Ycode
    extension** (the reference has none).
12. **Empty and error states** (§4.1, §5.1): "No Selection", "Multiple
    Devices Selected", "No Results for “…”", "Start the simulator to
    customize behavior and appearance.", connection problems in the canvas
    instead of the status line.
13. **Inspector** content: Settings per `simulator-features.md` §6/§7;
    Info rows with Edit Visibility; Apps / Profiles / Reports later.
14. **Persistence** (§2.1): selection, tab, sub-tab, collapsed sections,
    sidebar visibility, window frames, in Ycode's own preferences domain.
15. Resize mode (§4.7) and physical-device pairing: not planned.

## 10. Open questions

- Q1. What the canvas shows while a simulator boots (progress bar,
  spinner, the Apple-logo screen, text), and whether Start becomes a
  progress state. **Ycode decision** (I.6): the device's picture with a
  spinner in place of Start, then the frame with "Starting… N s" on its
  screen until the first picture.
- Q2. Device controls and frames for Apple Watch and Apple TV (labels,
  symbols). **Ycode decision** (I.6): not built; Ycode has no watch or TV
  simulator, and Add Device lists them disabled.
- Q3. Whether a Settings window exists (no menu item seen) and its layout.
  **Ycode decision** (I.6): none; Capture Keyboard is the toolbar toggle,
  and devices started in the hub are shut down when Ycode quits.
- Q4. Whether clicking the selected inspector tab hides the inspector.
  **Ycode decision** (I.6): no; choosing a tab shows a collapsed inspector.
- Q5. Whether Expand closes the compact window or opens the hub beside it;
  how many compact windows a device can have. **Ycode decision** (I.6):
  Expand brings the hub forward with the device selected and closes the
  compact window; one compact window per device.
- Q6. Exact items and order of the More Actions menu and the sidebar
  context menu. **Ycode decision** (I.6).
- Q7. Zoom step sizes and limits; the margin used by Zoom to Fit.
  **Ycode decision** (I.4): steps ¼, ⅓, ½, ⅔, ¾, 1, 1¼, 1½, 2, 3, 4;
  margin 24 points.
- Q8. The rotation animation (duration, whether the frame spins or
  cross-fades). **Ycode decision** (I.6): none; the frame is redrawn turned
  and the compact window takes its new shape at once.
- Q9. How "Screenshot Saved" is presented (banner over the canvas, a
  system notification, a flash); the Record button's recording state.
  **Ycode decision** (I.5): a glass banner over the canvas for 2 s; Record
  shows a red stop symbol while recording.
- Q10. Sort By options and the default sort. **Ycode decision** (I.3):
  Name and OS Version; by default none (Ycode's own order).
- Q11. Key equivalents other than Screenshot. **Ycode decision** (I.5).
- Q12. How the Duo slider appears and what it shows (angle text?).
  **Ycode decision** (I.4): a glass capsule over the control row with a
  slider and the angle ("90°"); the hinge sweeps on release.
- Q13. The full Orientation submenu. **Ycode decision** (I.5): Portrait,
  Portrait Upside Down, Landscape Left, Landscape Right, Face Up, Face
  Down.

## I. Ycode implementation (HUB-UI, 2026-10-28)

Clean-room work from this spec, `simulator-features.md` §7 and its
"Ycode implementation", `foldable.md` §4 and §10, `liquid-glass.md`,
`liquid-glass-ycode.md`, `display-stream.md`, `hid-input.md`, `devices.md`,
Apple's public AppKit documentation and the public SF Symbols names. No
Apple binary, Xcode, Device Hub or Simulator was opened, run or observed;
no Apple artwork is used: Ycode draws its frames from its own device data.

### I.1 Where the code is

| Module | What |
|---|---|
| `YcodeDeviceModel` (every platform) | `DeviceFrameSpec` (each Ycode device type's panels: pixels, scale, pixels per inch, corner radii, family — the values of `ycode-simd`'s `DeviceTypes.swift`), `DeviceFrameGeometry` (band, body, screen, buttons, hinge, turning), `DevicePosture`, `DeviceOrientation`, `DeviceZoom` and `CompactWindowLayout` (scale and window-size math), `HubSidebarModel` (sections, filter, search, sort, collapse), `HubCanvasState`, `DeviceCommand` (titles and key equivalents), `DeviceCaptureNames` |
| `YcodeDeviceUI` (macOS) | `DeviceLiveSession` (one device's display-stream connection, shared by every window that shows it), `DeviceView` (the screen: touch, keys, Capture Keyboard), `DeviceFrameView`, `DeviceControlsRow`, `DeviceCanvasView`, `DeviceWindowController` (the compact window and its expanded form), `DeviceMenus`, `ScreenRecorder`, `ViewerConnection` and `ViewerSettingsMenu` (moved from the viewer) |
| `ycode-sim-viewer` | the command line, the menu bar, the script runner; one compact window |
| `YcodeUI` | `DevicesController` (now the hub), `DeviceHubToolbar`, `DeviceHubRemote.swift` (display socket, ssh forward, Start / Shut Down) |
| `ycode-simd` | the display hello's new `deviceType` and `osVersion` (`display-stream.md` §3.1) |

### I.2 Per gap item (§9)

| # | Item | Status | What Ycode does |
|---|---|---|---|
| 1 | Compact device window | done | `DeviceWindowController` (viewer and IDE): unified toolbar, no separator; title = the device type's name ("iPhone 18 Pro"; the hub's title is the row's, "iPhone 18 Pro (Ycode)"), subtitle = the OS from the hello ("iOS 27.1"); one capsule Expand (`arrow.up.left.and.arrow.down.right`, help "Expand to view all controls") │ More Actions (`ellipsis`); the device in Ycode's frame, 17 points from each side, 4 below the toolbar; the control row 8 above the bottom edge. `windowWillResize` keeps the device's aspect (the width decides), so resizing scales the device; a rotation, the Duo's other panel or Show / Hide Bezels reshapes the window at the same scale, keeping its top centre. The window is at least 340 points wide (AppKit's toolbar needs it for the capsule beside the title; the reference's saved window was 296 wide); a portrait iPhone 18 Pro opens at 340 × 751. Scale and position are kept per device type. The push buttons, the fold bar and the status line are gone |
| 2 | Hub window | done (Ycode's own simulators operate; others are listed) | Manage Devices… (⇧⌘2) and Ycode ▸ Open Developer Tool ▸ Device Hub open it. `NSSplitViewController`: sidebar 240 (full height), canvas, inspector 280 with a one-point divider. Sidebar: search field (placeholder "Search"), "Available" / "Unavailable" headers that collapse, 46-point rows (32-point disc: glyph `iphone`, `ipad` or `vision.pro` in the accent colour on white while running, grey on grey otherwise; name over "Simulator" or the model; major.minor version 16 from the right edge), the no-results view, multiple selection ("Multiple Devices Selected"; double-click opens a compact window per running device). Toolbar in §3's order (I.3). Canvas: the live screen of a running Ycode simulator, the status view with **Start** for a stopped one, "No Selection". Inspector: Settings hosts FEAT-IMPL's boxes unchanged (`settingsControls()`), followed by CAMERA-GUEST's Camera box (`cameraControls()`, after Sound, shown for a stopped device too; `devices.md` §Camera), Reports ("No Diagnostic Reports"), Info (Info · Apps · Profiles; Info rows in a rounded group box with inset separators and Edit Visibility / Done). The Devices / Simulators switch is the Filter menu. Open in New Window and Expand move a device between the window kinds |
| 3 | iPhone Duo controls | done | [Rotate │ Closed · Partially Open · Open] after Rotate, the current pose's button on a recessed pill; Option-drag on a pose button or on the Duo's frame shows the hinge slider (I.4). The always-visible slider and segmented control are gone (viewer and IDE); the presets are named "Closed", "Partially Open", "Open" everywhere (menus, context menu, Info's Fold row) |
| 4 | Device frame | done | `DeviceFrameGeometry`: a band of 12 points (phone) or 20 (iPad) all round, outer radii = screen radii + band (per corner: the Duo's cover has 8-point corners on its hinge side), buttons as 3-point bars — phone: Action, Volume Up, Volume Down on the left, Sleep/Wake on the right; iPad: top button on the top edge near the right corner, volume on the right edge near the top; the open Duo: Sleep/Wake and volume on its right edge, Action on the top edge. Drawn near-black with a lighter rim, buttons a step lighter; the screen keeps its rounded corners (a mask). The frame turns with the device. Clicking a button presses it on the device (down on mouse down, up on mouse up: a click is a press, a hold a long press); tooltips name them. Partially Open: the inner panel's frame with a hinge line and the left half in shade (Ycode's flat stand-in for the perspective view). visionOS: no frame. Show / Hide Bezels in the viewer's View menu and in More Actions (viewer and IDE), kept as a preference |
| 5 | Zoom | done | Hub canvas (and the viewer's expanded window): toolbar segments Zoom Out · Zoom to Fit · Zoom To Actual Size · Zoom In (`minus.magnifyingglass`, `arrow.up.left.and.down.right.magnifyingglass`, `1.magnifyingglass`, `plus.magnifyingglass`), Zoom to Fit selected by default; View menu Zoom In ⌘+, Zoom Out ⌘−, Zoom to Fit ⌘9, Physical Size ⌘0 (viewer). Physical size: one device point = scale ÷ pixels per inch inches, the Mac display's points per inch from its size in millimetres. The canvas scrolls when the device is larger. Half Size / Point Accurate / Pixel Accurate are retired; the compact window has no zoom (its width sets the scale) |
| 6 | Menus | done (viewer); IDE: toolbar, context and More Actions menus | Viewer: View (zoom, bezels, Show Frame Rate, Enter Full Screen), Device (Accessibility ▸, Appearance ▸, Color Filter ▸, Location ▸, Orientation ▸, Sound ▸, Keyboard ▸ Keyboard Capture ⇧⌘K, Fold ▸ for the Duo, Refresh Display), Controls (Home ⇧⌘H, Lock ⌘L, App Switcher, Action Button, Rotate Left ⌘←, Rotate Right ⌘→, Screenshot ⇧⌘S, Record Screen / Stop Recording ⇧⌘R, Volume Up ⌥⌘↑, Volume Down ⌥⌘↓), Window (Expand, Open in New Window). Items a device lacks are hidden (Action Button, Fold). IDE: its menu bar stays Xcode's (golden-tested); the hub and compact windows take the same key equivalents (the canvas handles them before the menu bar), Start / Shut Down / Restart / Force Shut Down are in More Actions and the row's context menu. Edit's clipboard items: not done (Ycode does not sync the pasteboard yet) |
| 7 | Rotation | done | One Rotate control: click = Rotate Left, Option-click = Rotate Right; the frame and the compact window turn. Ycode's stream turns foldables only (`display-stream.md` §11): for other devices Rotate is shown disabled |
| 8 | Screenshot and recording feedback | done | Screenshot (button, ⇧⌘S): the server's full-resolution PNG, saved to the system's screenshot location when one is set, else the Desktop, as "Screenshot <device> <yyyy-MM-dd at HH.mm.ss>.png"; banner "Screenshot Saved". Record: the shown pictures become an H.264 QuickTime movie on the Mac (`ScreenRecorder`), "Screen Recording <device> <time>.mov"; the button turns into a red stop symbol; Stop Recording writes it ("Recording Saved"); a dropped connection stops it with "Screen recording was stopped because the device disconnected." |
| 9 | Status line | done | Gone; More Actions ▸ Show Frame Rate (viewer: also View) shows the old line (phase, fps, KB/s, input → screen, round trip, the Duo's panel and hinge) at the canvas's bottom edge. Boot progress and connection problems are written on the device's screen in the canvas |
| 10 | Keyboard capture | done | Toolbar toggle (hub, expanded window), Device ▸ Keyboard ▸ Keyboard Capture (viewer). While on, command shortcuts go to the device too, a glass notice "Capturing Keyboard" / "Hold Escape to cancel" shows, and holding Escape for one second ends it. Off: unchanged (keys without ⌘ go to the device while its screen has focus; **Ycode decision**) |
| 11 | Scrolling | unchanged | scroll-as-drag stays until the guest takes scroll events; Option-drag two-finger gestures stay as a **Ycode extension** |
| 12 | Empty and error states | done | "No Selection", "Multiple Devices Selected", "No Results for “…”" with "Check the spelling or try a new search.", "Start the simulator to customize behavior and appearance." (FEAT-IMPL's), "Connecting display", "Starting… N s", "The device is not running or the connection dropped; reconnecting", "Waiting for the first frame" on the device's screen |
| 13 | Inspector content | partial | Settings: FEAT-IMPL's boxes and the Camera box for Ycode's simulators, else "No settings are available for the selected device. …"; Info: Name, OS, Model, State or Connection, Identifier, Available, the Duo's Fold row, Erase status, with Edit Visibility; Apps ("No Apps"), Profiles ("No Profiles") and Reports ("No Diagnostic Reports") are placeholders |
| 14 | Persistence | done | Ycode's preferences: the hub window's frame (autosave "YcodeDeviceHub") and split widths, the selected device, the inspector tab and Info sub-tab, collapsed sections, the filter, whether the sidebar is shown (View ▸ Hide Sidebar through the hub), zoom, bezels, hidden Info rows; the compact window's scale and position per device type |
| 15 | Resize mode, pairing | not planned | the resize toggle is left out (§4.7); Pair Nearby Device… is listed disabled |

### I.3 The hub's toolbar and menus

Items in §3's order: [Add Device (`plus`) · Filter
(`line.3.horizontal.decrease`, drawn filled while a filter other than All
Devices applies)], the system's sidebar toggle, the sidebar tracking
separator (the title and subtitle follow it), Capture Keyboard (`keyboard`),
the zoom segments, [Open in New Window
(`arrow.down.right.and.arrow.up.left`, help "Switch to compact window") ·
More Actions], the inspector tracking separator, and the inspector tabs
(`slider.horizontal.3` Settings, `doc.text` Reports, `info.circle` Info).
Capture Keyboard, zoom and More Actions are dimmed with nothing selected;
Open in New Window needs a running Ycode simulator.

- Add Device: iPhone…, iPad… (they open Settings ▸ Simulators, where
  Ycode's runtimes and device types are set), Apple Watch…, Apple Vision
  Pro…, Apple TV… (disabled), —, Pair Nearby Device… (disabled).
  **Ycode decision.**
- Filter: All Devices, Simulators, Physical Devices, —, Sort By ▸ Name, OS
  Version. **Ycode decision (Q10):** no sort is chosen by default: physical
  devices first, then simulators by platform, name and version (`simctl`'s
  list), Ycode's own simulators last; choosing the checked sort again
  returns to that order.

### I.4 Canvas and controls

- Scale: Zoom to Fit fits the frame into the canvas less the control row
  (37 + 2 × 10) with a 24-point margin; steps ¼ … 4 (Q7). The control row
  sits 10 points under the device, never below the canvas's bottom less 8.
- The control row's groups: [Home `circle.grid.3x3.fill` · Screenshot
  `camera.viewfinder` · Record `record.circle` / `stop.circle.fill`] and
  [Rotate `rotate.left`] — plus │ Closed `iphone` · Partially Open `book` ·
  Open `ipad.landscape` for the iPhone Duo; visionOS has no Rotate. Each
  group is one `NSGlassEffectView` capsule 37 tall (a material view before
  macOS 26), groups 8 apart.
- The hinge slider (Q12): Option-drag on a pose button or on the Duo's frame
  shows a glass capsule above the control row with a 0–180° slider and the
  angle; 1.2 points of drag per degree from the angle the hinge is at;
  releasing sweeps the hinge there (`display-stream.md` 0x89).
- The status view of a stopped simulator: its frame with a dark screen
  (62 % of the canvas's height), its name, its OS, and Start; while
  Start or Shut Down runs, a spinner instead (Q1).
- Frame buttons → the stream's buttons: Sleep/Wake and the iPad's top button
  → `lock`, volume → `volumeUp` / `volumeDown`, Action → `side`
  (`hid-input.md` §5.5). **Ycode decision.**

### I.5 Commands and key equivalents (Q9, Q11, Q13)

| Command | Keys | Notes |
|---|---|---|
| Home | ⇧⌘H | |
| Lock | ⌘L | |
| App Switcher | — | Home pressed twice, 250 ms apart (**Ycode decision**) |
| Action Button | — | the side usage; shown for devices with one |
| Rotate Left / Right | ⌘← / ⌘→ | the cycle portrait → landscape left → landscape right (upside down is not offered by Rotate; the guest path refuses it) |
| Screenshot | ⇧⌘S | the reference's |
| Record Screen / Stop Recording | ⇧⌘R | |
| Volume Up / Down | ⌥⌘↑ / ⌥⌘↓ | Ycode's |
| Zoom In / Out / to Fit / Physical Size | ⌘+ / ⌘− / ⌘9 / ⌘0 | hub and expanded window |
| Keyboard Capture | ⇧⌘K | |
| Closed / Partially Open / Open | ⌥⌘1 / ⌥⌘2 / ⌥⌘3 | the iPhone Duo |

Orientation ▸ (Q13): Portrait, Portrait Upside Down (disabled), Landscape
Left, Landscape Right, Face Up, Face Down — the stream's rotate codes 1–6.
The banner (Q9): a glass capsule centred 12 points under the top of the
canvas, 2 s ("Screenshot Saved", "Recording Saved"), 3–4 s for notices and
failures.

### I.6 Lifecycle and windows (Q1–Q6, Q8)

- **Start** (status view, More Actions, context menu) runs the launcher
  over ssh without an app, with the display server (`RemoteSimulator.
  startCommand`: `mkdir -p <data>/display; echo YCODE-REMOTE-PID $$; exec
  env YCODE_WARM_BOOT=… <launcher> --device DEV --runtime-root RR
  [--device-type T] --display-server unix:<data>/display/<device dir>.sock
  [extra options]`) — warm boot restores the saved device as for a run.
  **Shut Down** sends SIGINT to the launcher (with warm boot the device is
  saved), **Force Shut Down** SIGKILL to it (no save), **Restart** both in
  turn. A run on a started device shuts it down first; Shut Down of a
  device a run uses stops the run. Devices started in the hub belong to
  the IDE session and end with it (Q3).
- **Every IDE run** now passes `--display-server unix:<data>/display/<device
  dir>.sock` (and the upload's `mkdir` makes `<data>/display`), so a
  running device can be shown. The option is part of the launcher's
  snapshot fingerprint, so the first run after this change boots cold once.
- **The live display** of a running device: `ssh -N -o
  ExitOnForwardFailure=yes -o StreamLocalBindUnlink=yes -L
  <tmp>/ycode-hub-<pid>-<n>.sock:<host socket> <destination>` (keys only),
  restarted when it ends; one `DeviceLiveSession` per device feeds the
  canvas and the device's compact window together (the stream takes one
  viewer at a time, so they share it). The session reconnects every second
  while the device boots.
- Running state in the sidebar follows runs and started devices (polled
  every 2 s while the hub is shown).
- Expand (Q5): the IDE brings the hub forward with the device selected and
  closes the compact window; one compact window per device. The
  standalone viewer has no hub: its Expand turns the window into the
  expanded form (the hub's canvas toolbar without sidebar or inspector);
  Open in New Window returns to the compact form.
- More Actions (Q6): IDE — Start, or Shut Down, Restart, Force Shut Down;
  Show / Hide Bezels, Show Frame Rate; Erase All Content and Settings….
  Compact window — the IDE's lifecycle items, then Show / Hide Bezels, Show
  Frame Rate, Refresh Display. Sidebar context menu — Start or Shut Down /
  Restart / Force Shut Down, Open in New Window, the Duo's poses and Rotate
  Left / Right, Erase All Content and Settings….
- Q4: choosing an inspector tab shows a collapsed inspector; clicking the
  selected tab does nothing more.
- Q8: no rotation animation.
- Launch options of Ycode.app for verification runs (the argument
  domain): `-YcodeOpenDeviceHub YES` opens the hub once the first
  workspace window shows; `-YcodeDeviceHubSelect <row name>`,
  `-YcodeDeviceHubSearch <text>`, `-YcodeDeviceHubTab
  settings|reports|info`, `-YcodeDeviceHubStart YES`,
  `-YcodeDeviceHubCompact YES` (the compact window once the display is
  live). `YCODE_DEVICE_CAPTURE_DIR` puts screenshots and recordings in
  another directory (tests).
- The viewer's command line is unchanged except `--zoom` (now the compact
  window's scale; default: the saved one). Script commands added:
  `control <command>`, `expand`, `compact`, `window-size <width>`,
  `window-shot <path>` (`screencapture -l` of the viewer's own window),
  `expect-banner <text>`, `frame-button <kind> [ms]` (a mouse click on a
  drawn frame button).

### I.7 Verification

All on Ycode's own simulator on the Thor (iOS 27.1 runtime 24A94401 and
27.0 runtime 24A434, this branch's `ycode-simd` with the hello's new keys,
the launcher `scripts/ycode-sim.sh` with warm boot) and Ycode's own windows
on the Mac (`screencapture -l <window id>` of the viewer's and Ycode.app's
windows only; Ycode.app run as a test bundle with its own preferences
domain and the launch options of I.6's `-YcodeOpenDeviceHub` family).

| Check | Result |
|---|---|
| Viewer, iPhone Duo (`ycode-sim-viewer --script`) | compact window 391 × 621 titled "iPhone Duo" / "iOS 27.1" (from the hello); frame with the cover's 8-point hinge-side corners, Action, volume and Sleep/Wake bars; control row with the Closed pill. Open → the window turns wide at the same scale (inner panel, 2853 × 2007 upright); Partially Open → hinge line and shaded half, pill on Partially Open; Rotate Left → tall window, frame turned; Rotate Right back; Closed → portrait again; `window-size 420` keeps the aspect; Hide Bezels → the screen alone; Capture Keyboard → the notice; Expand → the expanded form (Capture Keyboard, zoom segments with Zoom to Fit selected, Open in New Window │ More), Open in New Window → compact |
| Frame buttons | `frame-button side` (a mouse click on the drawn Sleep/Wake bar) locked the device (lock screen, 82 % of the picture changed in 2.75 s); again + Home unlocked it; `frame-button volumeUp` showed the guest's volume indicator |
| Screenshot, recording | Screenshot: "Screenshot Saved", a 1398 × 2034 PNG of the cover; Record → Stop after 4 s: "Recording Saved", an H.264 movie 1398 × 2034, 4.0 s |
| Hub, iPhone Duo | Device Hub from the launch option, the Duo selected, **Start** → warm restore (home screen 7.7 s after `ycode-simd` started); the canvas showed the live screen in the frame with the control row; the Settings tab read the device's settings (Light, …, System) once live; its compact window opened from the same session (both live at once) |
| Hub, iPhone 18 Pro (27.0) | Start → "Starting… N s" on the frame's dark screen, then a cold boot to the home screen in 76.9 s; canvas, compact window 340 × 751 ("iPhone 18 Pro" / "iOS 27.0"), Info tab (Name, OS, Model, State Booted, Identifier, Available, Edit Visibility); Rotate shown disabled (the stream turns foldables only) |
| Hub, iPad (A16) (27.1) | Start → cold boot, home screen in 120.6 s; iPad frame (20-point band, top button near the right corner, volume on the right edge) in the canvas and the compact window |
| Quit | quitting Ycode sent Shut Down to the started device: "stop: the device was saved", the next Start restored it |
| Sidebar | the Mac's own `simctl` simulators and paired devices listed with Ycode's (Available; a disconnected device under Unavailable), search "Ycode" narrowed the list, the running row's glyph lit on a white disc |
| visionOS | not run this round (no visionOS device in this data area); the canvas draws it without a frame by `DeviceFrameSpec.visionPro` (unit tests) |

Before and after (outside the repository): the old viewer (title "Ycode
Simulator Viewer", stream filling the window, the fold bar, push buttons,
status line) and the old Devices and Simulators window (switch, list,
bold key-value details) against the compact window and the hub above.

Tests: `YcodeDeviceModelTests` (frame geometry, turning, hit testing,
zoom, physical size, compact layout, sidebar sections, filter, search,
sort, collapse, canvas states, commands, key equivalents, capture names;
also on Linux), `YcodeDeviceUITests` (window title and shape, aspect on
resize, reshaping on the Duo's panel and rotation, bezels, More Actions,
the expanded form and zoom, canvas states and controls, frame hit testing
and button mapping, Capture Keyboard and banners, the hinge slider, the
menus' titles, keys and validation), and in `YcodeUITests`
`FoldControlsTests`, `OrganizerTests`, `SimulatorSideR37Tests`,
`RunTargetTests` (the display server in the run command),
`MenuBarGoldenTests` and `MenuBarBehaviorTests` (Open Developer Tool ▸
Device Hub), `noTrademarkSymbols` (now also over the device windows'
sources).

### I.8 Not done

- Apps, Profiles and Reports content (placeholders); Edit's clipboard
  items; the New Simulator dialog (Add Device opens Settings ▸
  Simulators); the paired-watch capsule; watch and TV controls; resize mode.
- visionOS's own canvas controls (interaction modes, Reset Camera,
  Capture Pointer, Simulated Scenes; `visionos.md` §5.1): the visionOS
  canvas shows the screen without a frame and the common controls only.
- Physical devices are listed (from `devicectl`) but not shown or operated;
  other `simctl` simulators are listed with their picture and no Start.
- Rotation of devices other than foldables waits for the stream's rotate
  path (`display-stream.md` §11, `hid-input.md` §10).

## Evidence

| Claim | Level | Source |
|---|---|---|
| No Simulator.app; Device Hub opened by Manage Devices… and Open Developer Tool; compact window on run; expand to sidebar/canvas/inspector (§1, §2.1, §2.2) | 1 | Apple documentation "Device Hub", "Managing your simulated and physical devices in Device Hub", "Running your app on simulated or physical devices"; WWDC26 session 260 |
| Hub window title, subtitle, window-menu entry, 1100 × 800 size, area x ranges, backgrounds, divider (§2.1) | 3 | background window capture and accessibility tree |
| Hide Sidebar behaviour (§2.1) | 3 | pressed through accessibility, captured, restored |
| Tabs and window items (§2.1, §7) | 3 | menu bar read through accessibility (titles only) |
| Persisted state keys (§2.1, §2.2 compact size) | 3 | the app's preferences read with `defaults` |
| Compact window layout, device-control row, landscape reshaping, Duo pose view, visionOS canvas (§2.2, §4.3, §4.4) | 1 | Apple documentation screenshots (compact iPhone portrait and landscape, iPhone Duo, Apple Vision Pro) described in words |
| Multiple selection → compact windows (§2.2) | 1 | WWDC26 session 260 |
| New Simulator dialog fields (§2.3) | 1 | Apple documentation screenshot and text |
| Settings-window labels, "Quit and Shutdown Simulators" (§2.3) | 4 | strings of Device Hub (no level 1–3 source available) |
| Key-combination preference values (§2.3) | 1 | Xcode 27 release notes |
| "Quit and Keep Simulators Running", app menu without Settings… (§2.3) | 3 | menu bar |
| Toolbar items, order, accessibility names and frames (§3) | 3 | accessibility tree; drawn extents from the capture |
| Resize toggle, Zoom to Fit selected, paired-watch capsule, Info/Apps layout (§3, §4.1, §6) | 1 | Apple documentation screenshots |
| Canvas states: Start, View Screen, Pair, status picture (§4.1) | 1 | "Configuring the environment…", "Managing your simulated and physical devices…", "Interacting with your app…" and screenshots |
| "No Selection" in canvas and inspector (§4.1) | 3 | capture |
| "Multiple Devices Selected", problem texts, "Screenshot Saved", "Orientation Locked", recording-stopped text, "Capturing Keyboard" / "Hold Escape to cancel", "No Diagnostic Reports" (§4, §6) | 4 | strings of DeviceKit |
| Zoom items and meanings, compact window resizing (§4.2) | 1, 3 | "Configuring the environment of a simulated device"; View menu |
| No point/pixel-accurate zoom; ⌘W; Option two-finger removal (§4.2, §4.5, §7) | 1 | public developer feedback collected on mjtsai.com; developer forums; Xcode 27 release notes known issue 169537162 |
| Bezel, clickable parts, Show/Hide Bezels, Digital Crown (§4.3) | 1 | "Interacting with your app in Device Hub" |
| Bezel shape in words (§4.3) | 1 | documentation screenshots |
| Rotate click / Option-click, Orientation submenu, Duo pose buttons and Option-drag slider (§4.4) | 1 | "Interacting with your app in Device Hub" |
| Screenshot behaviour and location, ⇧⌘S (§4.4, §7) | 1 | "Capturing screenshots and videos from devices"; Xcode 27 release notes (save-location preference order); Apple engineer's forum reply |
| Recording name and controls (§4.4) | 1 | "Capturing screenshots and videos from devices" |
| Pointer, scroll and transform events, Simulate Trackpad or Mouse, OS minimums (§4.5) | 1 | Xcode 27 release notes; "Interacting with your app in Device Hub" |
| Keyboard capture (§4.6) | 1, 4 | WWDC26 session 260, visionOS documentation; DeviceKit strings for the notice |
| Resize mode (§4.7) | 1 | "Configuring the environment of a simulated device" and its screenshot |
| Sidebar sections, collapse, search empty state, row layout, filter menu (§5) | 3 | capture, accessibility tree, filter control pressed |
| Row glyph colour for running vs shut down (§5.2) | 3 | `ycode-test-hub-iphone` booted and shut down with `simctl`, sidebar captured each time |
| Unavailable section, physical-device subtitle, selection highlight, Filter button fill (§5) | 1, 3 | documentation screenshots; capture |
| Context-menu items, Remove/Unpair, which devices are listed (§5) | 1, 4 | "Managing your simulated and physical devices…", "Configuring the environment…", forum; DeviceKit strings for the Remove message |
| Inspector tabs and sub-tabs, Info rows, Edit Visibility, Apps list and filter (§6) | 1, 3 | "Locating device identifiers", "Managing apps on devices", Xcode 27 release notes; View ▸ Inspectors menu; preferences keys |
| Menus (§7) | 3 | menu bar read through accessibility; Device/Controls items beyond those seen come from OBS-FEATURES (`simulator-features.md` §7.1) and the documentation (Slow Animations, Shake, Stop Recording) |
| Look (§8) | 1, 3 | capture; `liquid-glass.md` |
| Gap list (§9) | — | comparison with `ycode-sim-viewer` and `specs/ide/devices.md`; Ycode decisions |
| Ycode implementation (§I): frame proportions, symbols, steps, banners, lifecycle, persistence, the answers to Q1–Q13 | — | Ycode decisions; public AppKit API (`NSSplitViewController`, `NSToolbarItemGroup`, `NSMenuToolbarItem`, `NSGlassEffectView`, `NSTrackingSeparatorToolbarItem`), public SF Symbols names, AVFoundation (`AVAssetWriter`) and Core Graphics (`CGDisplayScreenSize`) documentation (level 1) |
| Device panel data (§I.1): pixels, scale, pixels per inch, corner radii | — | Ycode's own device types (`Sources/ycode-simd/DeviceTypes.swift`, `device-capabilities.md`, `foldable.md` §10) |
| Verification (§I.7) | — | Ycode's own windows on the Mac (`screencapture -l` with their window ids), Ycode's devices on the Thor |

Level 5 was not used.
