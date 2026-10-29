# Menu bar and shortcuts

Ycode module: `YcodeUI` (`CommandTable`, `MainMenu`). The menu bar is
data (`CommandTable.menus`); each item sends an action up the responder
chain, handled by the workspace window controller or the editor.

Menus, in order: Ycode (application menu), File, Edit, View, Find,
Navigate, Editor, Product, Debug, Integrate, Window, Help.

**Correction (2026-10-19).** `reference-ui-5.md` §1–§2 is now the
normative menu bar: every item, its order, separators, alternates,
dynamic titles and default shortcut, read from the reference's own menu
bar. Where the table below disagrees, §2 of that spec wins. The rows that
were wrong are corrected in place and marked †.

| Command | Shortcut | Menu |
|---|---|---|
| Open… / Open Quickly… | ⌘O / ⇧⌘O | File |
| Close Tab / Close "<file>" / Close Editor Pane / Close Window / Close Project or Package | ⌘W / ⌃⌘W / ⌃⇧⌘W / ⇧⌘W / ⌃⌥⌘W | File (reference-ui-2.md §8) |
| Open in New Tab / Duplicate Editor Tab / Open with External Editor | ⌥⌘O / — / — | File |
| Show/Hide Editor Tab Bar / Pin Editor Tab | — / ⇧⌘P | View |
| Choose Scheme / Select Next, Previous Scheme / Manage Schemes… | ⌃0 / ⌃⌘], ⌃⌘[ / — | Product ▸ Scheme (reference-ui-2.md §7.8) |
| Save | ⌘S | File |
| Navigators 1–9; Show Coding Assistant; Show/Hide Navigator † | ⌘1–⌘9; ⌘0; none | View ▸ Navigators |
| Inspectors; Show/Hide Inspector † | ⌥⌘1…; none | View ▸ Inspectors |
| Show/Hide Debug Area; Activate Console | ⇧⌘Y; ⇧⌘C | View ▸ Debug Area |
| Show Library | ⇧⌘L | View |
| Find in Project / Workspace / Package † (no ellipsis) | ⇧⌘F | Find |
| Find… / Next / Previous / Find and Replace… | ⌘F / ⌘G / ⇧⌘G / ⌥⌘F | Find |
| Reveal in Project Navigator | ⇧⌘J | Navigate |
| Next / Previous Issue | ⌘' / ⇧⌘' | Navigate |
| Jump to Definition | ⌃⌘J | Navigate |
| Jump to Line in “<file>”… † (source editor only, after the counterpart commands) | ⌘L | Navigate |
| Go Back / Forward | ⌃⌘← / ⌃⌘→ | Navigate |
| Show Completions | ⌃Space | Editor |
| Re-Indent † | ⌃I | Editor ▸ Structure |
| Shift Left / Right / Comment | ⌘[ / ⌘] / ⌘/ | Editor ▸ Structure |
| Fold / Unfold | ⌥⌘← / ⌥⌘→ | Editor ▸ Code Folding |
| Minimap | ⌃⇧⌘M | Editor |
| Run / Test / Profile / Analyze | ⌘R / ⌘U / ⌘I / ⇧⌘B | Product |
| Build / Clean Build Folder… / Stop | ⌘B / ⇧⌘K / ⌘. | Product |
| Edit Scheme… | ⌘< | Product ▸ Scheme |
| Pause / Continue | ⌃⌘Y | Debug |
| Step Over / Into / Out | F6 / F7 / F8 | Debug |
| Create Breakpoint at Current Line † | ⌘\ | Debug ▸ Breakpoints |
| Activate/Deactivate Breakpoints | ⌘Y | Debug |
| Commit… | ⌥⌘C | Integrate |
| Use Selection for Find | ⌘E | Find |
| Fold / Unfold Methods & Functions †; Unfold All | ⌥⇧⌘← / ⌥⇧⌘→; none | Editor ▸ Code Folding |
| Code Review / Assistant † | ⌥⇧⌘↩ / ⌃⌥⌘↩ | Editor (View ▸ Editor holds the jump-bar commands ⌃1–⌃6) |
| New Tab / Close Tab / Previous, Next Tab | ⌘T / ⌘W / ⇧⌘[, ⇧⌘] | File, Window |
| Editor Pane On Right / Editor Pane Below † | ⌃⌘T / ⌃⌥⌘T | File ▸ New |
| Organizer; Manage Devices… † | ⌥⇧⌘O; ⇧⌘2 | Window; Product ▸ Destination (there is no Devices and Simulators item) |
| Archive | (none) | Product |
| Canvas † | ⌥⌘↩ | Editor |
| Show Quick Actions… †; Show Coding Tools… † (Ycode: code actions at the caret); Refactor ▸ Rename…; Fix All Issues | ⇧⌘A; ⌥⌘0; —; ⌃⌥⌘F | View; Editor ▸ Show Coding Tools; Editor |
| Find Selected Symbol in Workspace / Find Call Hierarchy | ⌃⇧⌘F / ⌃⇧⌘H | Find |
| Jump to Original Source | (none) | Navigate |
| Assistant modes † | (none) | the assistant jump bar's mode pop-up (reference-ui-4.md §16); not in the Editor menu |
| Open Quickly… | ⇧⌘O | File |
| Add Package Dependencies… / Resolve Package Versions | (none) | File, File ▸ Packages |

Invariant (tested): no two commands share a shortcut. The one command
listed in two menus (Developer Documentation ⇧⌘0, Window and Help;
`reference-ui-5.md` §2.12, §2.13) counts once.

The coding assistant's items (File ▸ New ▸ Conversation ⌃⌘H, Navigate ▸
Jump to Next Active Conversation ⌃⌘K, Editor ▸ Show Coding Tools ▸
Explain / Document / Generate a Playground / Generate a Preview) perform
their commands (`coding-assistant.md` §4); Conversation in New Tab and in
Editor Pane stay unavailable.

Item lists and order follow `specs/ide/reference-ui.md` §1 and
`reference-ui-2.md` §7.8 and §8. Items Ycode cannot perform are listed
with a unique unimplemented action (`ycodeUnavailable<Name>:`), so AppKit
shows them disabled; they are left out of Settings ▸ Shortcuts.

## Evidence

- Corrections marked † and the full menu bar: `reference-ui-5.md` §2
  (level 3: the reference's menu bar read through the accessibility API,
  2026-10-19; the user's key-binding set was empty, so these are factory
  defaults).

- Menu names and shortcuts: Apple's published Xcode keyboard-shortcut
  reference and Xcode Help (level 1); standard items from the macOS HIG
  (level 1).
- Item lists and order, and the menu name Integrate:
  `specs/ide/reference-ui.md` §1 (level 3). Items Ycode cannot perform are
  listed with a unique unimplemented action (`ycodeUnavailable<Name>:`)
  so AppKit shows them disabled; Ycode does not invent their behavior.
