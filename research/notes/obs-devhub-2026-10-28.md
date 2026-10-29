# Device Hub as a window (agent OBS-DEVHUB, 2026-10-28)

Dirty-room notes behind `specs/ide/device-hub.md`. Prose only. Raw window
captures, the rendered documentation pages and Apple's documentation
screenshots are in `research/dirty/obs-devhub/` (git-ignored). No
disassembly or decompilation. Ghidra, the reference tools folder and the
IPSWs were not opened. Evidence levels as in AGENTS.md rule 4.

## Setup

- Xcode 27.1; Device Hub is `Contents/Applications/DeviceHub.app` inside
  the Xcode bundle (bundle id `com.apple.dt.Devices`, version 27.1, build
  255.6.6.1). It was already running with one window.
- Load average 10–40 during the session; one throwaway simulator,
  `ycode-test-hub-iphone` (iPhone 18 Pro, iOS 27.0), created with `simctl`,
  booted once, shut down and deleted. No other simulator was touched.
- Background tools only (window captures, accessibility tree, menu-bar
  listing, accessibility presses). No full-screen control.

## What the background tools could and could not do

- Could: capture the window, read accessibility frames and labels, list
  every menu and submenu title, press plain buttons and toggles
  (Hide/Show Sidebar, the Filter control, the section header, inspector
  tab segments, the search field's clear button), and insert text into
  the search field.
- Could not: select a sidebar row (refused: "selecting this row via
  accessibility was refused"), send keys to the list, open the Add Device
  or More Actions menus (pop-up menu controls are refused), or press menu
  commands that need the app to be frontmost (New Window, Filter, Hide
  Inspector and New Simulator were reported disabled). Two batched action
  calls were aborted with "user interrupt"; single calls went through.
- So **no device was ever shown in the canvas** during this session. Every
  canvas, device-control and inspector-content claim in the spec comes from
  Apple's public documentation, its screenshots, the WWDC26 session "Get
  the most out of Device Hub", and the Xcode 27 release notes (level 1),
  or is marked OPEN.

## Window (level 3)

- One window, title "Devices – No Selection", 1100 × 800 points. The
  Window menu lists it as "Devices (No Selection)".
- Toolbar, accessibility frames (x, y, w × h, window points):
  close 18,18; minimize 41,18; full screen 64,18 (16 × 16 each);
  Add Device (menu button) 118,12 30 × 28; Filter (toggle) 153,12 31 × 28;
  Hide Sidebar 192,0 44 × 52; title block 244,0 287 × 52 ("Devices",
  subtitle "No Selection"); Capture Keyboard (toggle) 535,8 37 × 36;
  Zoom Out 581,8; an unnamed segment 618,8 (Zoom to Fit by the View menu
  and Apple's docs); Zoom To Actual Size 656,8; Zoom In 693,8 (segments
  37–38 × 36, radio-button role); Open in New Window 736,0 40 × 52; More
  Actions (menu button) 779,12 30 × 28; inspector tabs as radio segments
  at 981, 1018, 1055 (37 × 36) whose accessibility names are "Edit",
  "Text Document" and "Info" (the symbols' default descriptions; the View ▸
  Inspectors menu calls them Settings, Reports, Info).
- Drawn shapes (from the capture): Add Device and Filter share one capsule
  about x 113–189; Hide Sidebar is a circle about 195–233; Capture
  Keyboard a circle about 534–573; the four zoom segments one capsule
  about 580–732 with thin dividers; Open in New Window and More Actions one
  capsule about 739–814; the three inspector tabs one capsule about
  980–1093 (7 from the window's right edge). All about 36–38 tall, top at
  about y 8. With nothing selected the canvas items are dimmed.
- Areas: sidebar x 0–240, full height, sidebar background under the window
  buttons; canvas x 240–820, plain window background; inspector x 820–1100
  with a one-point divider at its left edge, same background kind as the
  sidebar. No line between sidebar and canvas.
- Sidebar: search field 10,61 220 × 28 (placeholder "Search", clear button
  at its right end, 28 × 28). Outline from y 98. Section header row 32
  tall ("Available", a button 16,107 208 × 15; pressing it collapses and
  expands the section). Device row 46 tall: glyph in a circle (image
  26,142 12 × 22 for a phone), name 56,138 134 × 16 (tail-truncated),
  subtitle "Simulator" 56,155, OS version "27.0" right-aligned at
  202,146 22 × 14.
- The glyph of a **booted** simulator is drawn in colour (a lit screen); a
  **shut-down** one is grey. No "Booted" text badge. A simulator created
  with `simctl` appeared under Available at once.
- With every device present (search cleared), the list showed an
  "Available" section with simulators (subtitle "Simulator") and a paired
  physical watch (subtitle = its model name), then an "Unavailable"
  section header, collapsed. Names were not recorded.
- Empty search result: a magnifying-glass symbol (26 × 26) centred in the
  sidebar, "No Results for “<text>”" and "Check the spelling or try a new
  search."; canvas and inspector each show "No Selection" centred in
  secondary text.
- Filter control: a menu of All Devices (checked), Simulators, Physical
  Devices, a separator, Sort By ▸. The Sort By items were not reached.
- Hide Sidebar: the window keeps its width, the canvas widens to x 0–820,
  the Add/Filter capsule leaves with the sidebar, the button (now "Show
  Sidebar") moves next to the window buttons (92,0) and the title to
  x 152. The inspector does not move.
- Quirk (not for the spec): clearing the search field through
  accessibility cleared the text but not the list's filter; the list
  followed the field again only after real text editing. The session found
  the field in that state ("No Results for “ycode-test-features-1”" over
  an empty field) and left it cleared.

## Menus (level 3; titles only, key equivalents not readable)

- Device Hub: About Device Hub, Services, Hide Device Hub, Hide Others,
  Show All, Quit Device Hub, Quit and Keep Simulators Running. No
  Settings… item was listed.
- File: New Simulator ▸ (iPhone…, iPad…, Apple Watch…, Apple Vision Pro…,
  Apple TV…), Pair Nearby Device…, New Tab, New Window, Rename…, Close,
  Close All.
- Edit: Undo, Redo, Cut, Copy, Paste, Delete, Select All, Use Shared
  Clipboard, Get Clipboard, Send Clipboard, AutoFill, Start Dictation…,
  Emoji & Symbols.
- View: Show Tab Bar, Show All Tabs, Filter, Hide Sidebar, Inspectors ▸
  (Settings, Reports, Info, Hide Inspector), Zoom In, Zoom Out, Zoom to
  Fit, Physical Size, Enter Full Screen.
- Device (no device selected): Start, Shut Down, Force Shut Down,
  Accessibility ▸, Appearance ▸, Battery ▸ (100%, 75%, 50%, 25%), Face ID ▸
  (Enrolled, Authorized with Face ID, Unauthorized with Face ID), Touch ID ▸
  (Enrolled, Authorized with Touch ID, Unauthorized with Touch ID), Optic
  ID ▸ (Enrolled, Authorized with Optic ID, Unauthorized with Optic ID),
  Location ▸, Sound ▸, Enter Resize Mode, Keyboard ▸ (Toggle Software
  Keyboard), Reset Content and Settings…
- Compared with OBS-FEATURES (2026-10-27, a booted iPhone Duo selected):
  that menu began with Restart and had Orientation ▸ and Pair Apple
  Watch…; Controls had Rotate Left and Rotate Right. So the Device and
  Controls menus change with the selection.
- Controls (no selection): Home, Lock, Siri, App Switcher, Action Button,
  Screenshot, Record Screen.
- Window: Fill, Center, Move & Resize, Full Screen Tile, Minimize, Zoom,
  Show Previous Tab, Show Next Tab, Move Tab to New Window, Merge All
  Windows, Stay On Top, Bring All to Front, Arrange in Front, Remove Window
  from Set, then one item per window.
- Help: Send Device Hub Feedback, Device Hub Help.

## Persisted state (level 3: the app's preferences, read with `defaults`)

Frames of two window kinds: the management window (1100 × 800 here) with
its split-view subview frames, and a device window (296 × 620 saved from an
earlier run). Keys: last selected device identifier; selected inspector
category ("settings", "content" = Reports, "info"); the sub-inspector
chosen in each (`…inspector.appearance`, `…inspector.reports`,
`…inspector.info`); collapsed sidebar sections by grouping
(`{"Availability": ["unavailable"]}`); sidebar column visibility.

## Public documentation (level 1)

Read: the Device Hub collection on developer.apple.com (overview;
Managing your simulated and physical devices; Interacting with your app;
Interacting with your visionOS app; Configuring the environment of a
simulated device; Capturing screenshots and videos; Managing apps;
Locating device identifiers; Running your app), the Xcode 27 and 27.1
release notes, and the WWDC26 session page. Their screenshots were looked
at to describe layout in words: expanded window anatomy (labels "Add
simulators & devices", "Filter & sort devices", "Device interactions",
"Canvas controls", "Compress/expand window", "Sidebar", "Canvas", "Device
controls", "Inspector"), compact iPhone window (portrait and landscape),
compact iPhone Duo (half-open pose), compact and expanded visionOS, resize
mode, Info and Apps inspectors, the New Simulator dialog, the filter menu.
Details are in the spec. An Apple engineer on the developer forums gave
the Screenshot shortcut as Shift-Command-S.

## Binary metadata consulted (level 4, labels only)

`strings` of Device Hub and DeviceKit for user-visible labels the
background tools could not reach: "Switch to compact window", "Expand to
view all controls", "Multiple Devices Selected", "Screenshot Saved",
"Orientation Locked" / "Unable to rotate device. Orientation lock
enabled.", "Capturing Keyboard" / "Hold Escape to cancel", "Connecting
display", "Live device view took longer than expected to connect.",
"Removing these devices will make them unavailable as run destinations in
Xcode.", "No Diagnostic Reports", "No Crash Reports", Settings-window
labels "Simulate hardware keyboard by default", "Capture keyboard
shortcuts" ("Most keyboard shortcuts will be sent to the device or
simulator when active."), "Secure keyboard entry", "Stop simulators on
quit", and the quit alternative "Quit and Shutdown Simulators". Why: no
level 1–3 source showed them and the canvas could not be reached in the
background. Short labels (under 16 bytes) are not visible this way.

## Not observed

The canvas of a selected device (shut down, booting, running), boot
progress, rotation animation, screenshot/recording feedback on screen, the
More Actions and sidebar context menus, Sort By options, the Reports tab,
the Settings window (if any), and every key equivalent except the one
Apple stated.
