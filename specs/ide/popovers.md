# Popovers, in-window panels and sheets

**Status:** boundary spec for B5-POPOVERS (inventory rows P-014, P-031, P-083,
P-086, P-111, P-112, P-113, P-180, P-195). It describes the reference, Xcode
27.1: the scheme and destination choosers, the New Scheme sheet, Quick Help's
placement, the Jump to Line, Quick Actions and Open Quickly capsules, the Library,
sheets in general, the workspace's look while these are in front, and the
Product ▸ Destination menu. §9 turns them into one component model that both of
Ycode's IDEs build. Prose, tables and measured numbers only: no code, no copied
resources.

**Council round 12 (2026-11-21)** adds the destination chooser's initial
highlight and Ycode's own rows (§2.7), Quick Help for module names and the size
of a body symbol's popover (§4.1, §4.2) and the Quick Actions rows (§5.1),
recorded at the same 1x / 100 Hz, dark, host load 3.7–12.8, both apps side by
side.

**Capture conditions.** b5-obs capture of 2026-11-20: a **1x** display at
**100 Hz**, the workspace window 1400 × 880 pt at its default place, key and in
front, dark then light appearance, host load 7–150 (the popover session ran
while the load fell from 150 to 12). Sizes are points at 1x, **±1 pt**; timings
**±20 ms**, and start latencies vary with the load. "Frame" sizes are the
accessibility frames of the popover or panel window; "body" is the drawn shape
inside it. Window coordinates have their origin at the window's top left.
Earlier measurements (the parity run of 2026-11-15 at 2x / 120 Hz, council
rounds) are quoted where they differ; for timings the 2x value is preferred, for
behaviour the newer one.

Related specs: `specs/ui/glass-materials.md` (materials),
`specs/ui/control-states.md` (the capsule's hover and press),
`specs/ide/schemes.md` (the scheme editor and Manage Schemes),
`specs/ide/destinations.md` (what the destination list contains),
`specs/ide/open-quickly.md` (matching and result rows), `specs/ide/library.md`
(Library content).

## 1. Which kind of surface for what

| Kind | Members | Anchor | Arrow | Workspace behind |
|---|---|---|---|---|
| Anchored popover | scheme chooser, destination chooser, Quick Help | a control or a symbol | yes | stays active (§8) |
| In-window panel | Jump to Line, Quick Actions, Open Quickly, Library, (Quick New Project, P-180) | the window: centred near its top | no | stays active (§8) |
| Sheet | New Scheme, Manage Schemes, Edit Scheme, File from Template, the recommended-settings checklist | the window: centred both ways | no | dimmed (§7) |

## 2. The scheme and destination choosers (P-111, P-113, P-195)

### 2.1 Opening

- The scheme › destination capsule has two targets: the scheme half and the
  destination half. **Mouse-down** on a half opens its popover at once (the arrow
  is already drawn in the frame taken while the button is held); there is no
  menu-style press-drag-release selection.
- While the popover is open its half keeps a pressed tint (dark #505050,
  light #DFDFDF).
- The **current row is highlighted** on opening (scheme: "✓ Parity";
  destination: "✓ My Mac"), and the Filter field has keyboard focus (a caret in
  it).

### 2.2 Geometry

| | Scheme chooser | Destination chooser |
|---|---|---|
| Frame (arrow included) | 241 × 191 at window (549, 40) | 442 × 251 at (535, 40) |
| Body | ≈ 213 × 163 (x 563–776, y 54–217) | ≈ 415 wide (x 548–963) |
| Placement | **centred horizontally on its half** (arrow tip at x ≈ 670, the scheme half's centre) | centred on the destination half (tip at x ≈ 755) |
| Arrow | ≈ **26 pt wide at the base, ≈ 11 pt tall**, pointing up, its tip at the capsule's bottom edge | the same |
| Corners | ≈ 17 pt | ≈ 17 pt |
| Filter field | 201 × 30, ≈ 7 pt inside the body's edges, at the top: a capsule with a filter glyph and the placeholder "Filter" | 402 × 30 |
| Rows | 215 wide, **24 tall**; separators are 12-tall rows with a hairline inset ≈ 24 pt | 416 wide, 24 tall; section headings are 24-tall rows in small secondary text |

A popover that would cross the screen's edge is shifted along it; its arrow stays
on the anchor (system behaviour; not exercised in this capture).

### 2.3 Rows

**Scheme chooser:** Filter; "✓ <scheme>" with the scheme's app icon (one row per
scheme); separator; **Edit Scheme…**; **New Scheme…**; **Manage Schemes…**.
Commands are indented to the text column of the scheme rows.

**Destination chooser:** Filter; heading **Recent**; "✓ My Mac" with a laptop
glyph and the OS version **"27.2" right-aligned**; heading **Build**; "Any Mac
(arm64, x86_64)" with a hammer glyph; separator; **Incompatible ›** (a disclosure
row, chevron at the right edge); separator; **Manage Devices…**. The Mac is
listed once only. Ycode lists "My Computer" on Linux (decided, inventory §5) and
keeps its own rows (remote simulator, Ycode runtimes) under the matching
headings, never as extra commands at the bottom.

**Highlight:** an accent-blue rounded rectangle (radius ≈ 8) inset ≈ 12 pt from
the body's sides, white text; hover moves it in one frame; Up and Down move it.
The checkmark marks the current choice, independent of the highlight.

### 2.4 Incompatible expands in place

Clicking **Incompatible** (or Down to it, then Right) expands it **inside the same
popover**: the chevron turns down, rows "<device> (mismatched platform)" with
their OS version right-aligned are inserted under it, Manage Devices… moves to
the bottom, and the popover **grows downward** in place (442 × 251 → 442 × 1044
here, past the window's bottom edge; 2026-11-15 at 2x: ≈ 800 pt with a scroller).
It is not a cascading sub-menu, and hovering it does nothing.
Timing: one frame, 150–220 ms after the click (2026-11-15: one frame at
+117 ms).

### 2.5 Keys and dismissal

| Input | Effect |
|---|---|
| Up / Down | move the highlight (wrapping at the ends not recorded) |
| Right on Incompatible | expands it |
| typing | goes to the Filter field, which has focus (filtering not exercised) |
| a click on a row | chooses it or runs the command (Edit Scheme… and New Scheme… open their sheets, 2026-11-15); Return was not recorded |
| Escape | closes it, one frame |
| a click outside | closes it (system popover behaviour; not recorded here) |

### 2.6 Entrance and exit

| Transition | b5-obs (1x) | 2026-11-15 (2x) | Use |
|---|---|---|---|
| Scheme chooser appears | one frame, 25–213 ms after mouse-down (load-dependent), then a ≈ 130–200 ms settle of the material behind it | one frame at +127…+207 ms | one frame; let the system material settle |
| Scheme chooser leaves (Escape) | one frame (≈ 40–60 ms) | one frame (+79 ms) | one frame |
| Destination chooser appears | dark ≈ 140 ms to full; light one frame | one frame | one frame |
| Destination chooser leaves | dark ≈ 130 ms ease-in; light one frame | one frame | one frame; **OPEN** (dark fade under load) |
| Incompatible expands | one frame after 150–220 ms | one frame at +117 ms | one frame |

Menus (not popovers) fade out on Escape over ≈ 100 ms, and a chosen menu item
blinks (2026-11-15; inventory §5): Ycode's chooser must not use that menu fade.

### 2.7 The highlight on opening, and Ycode's own rows (C06)

Council round 12 confirms §2.1: the destination chooser opens with the **current
destination's row highlighted** (✓ My Mac under Recent), whatever row the
pointer is near.

Ycode adds two rows the reference does not have: **Get a Simulator Runtime…**
and **Set Up Ycode Simulator…** with a trailing **Experimental** label. They
stay (they are Ycode-only and follow the HIG), with these rules:

1. **Place.** They are the last rows of Ycode's **Simulators** section, which
   sits where the reference puts its simulators (Recent, Devices, Simulators,
   Build, then Incompatible ›, then Manage Devices…; `destinations.md`). Inside
   the section: Ycode's simulator destination rows first, then **Get a
   Simulator Runtime…**, then **Set Up Ycode Simulator…**. With no Ycode
   simulators the section holds the two rows alone.
2. **Never the initial highlight.** On opening, the highlight is on the checked
   (current) destination's row. If no row is checked, the first destination row
   (not a heading, not a command) is highlighted (the reference's behaviour
   without a current destination was not recorded: OPEN).
3. **Otherwise ordinary rows.** Hover highlights them in one frame, Up and Down
   pass through them in visual order, a click or Return runs them. They have no
   checkmark and no OS version.
4. **Look.** Command rows like Manage Devices… (title in the primary colour,
   indented to the text column, no glyph); "Experimental" right-aligned in the
   secondary text colour, where destination rows show their OS version.
5. In round 12 Ycode opened with "Set Up Ycode Simulator…" highlighted and its
   Simulators section between Recent and Build; the section's place is right,
   the highlight is not.

## 3. The New Scheme sheet (P-112)

New Scheme… in the chooser (and Product ▸ Scheme ▸ New Scheme…) opens a sheet:

| Property | Value |
|---|---|
| Size and place | **493 × 122**, centred in the window both ways (window (454, 379)) |
| Rows | "Target" label and a pop-up (the target's icon and name, up/down chevrons; 408 wide); "Name" label and a text field (416 × 21) whose text, the target's name, is **selected** |
| Labels | right-aligned, ending ≈ 55 pt from the sheet's left edge |
| Buttons | **Cancel** and **OK** (default, blue), 84 × 23 each, 12 pt apart, 20 pt from the sheet's right edge and 17 pt from its bottom |
| Keys | OK is the default button (Return); Cancel answers Escape (Cancel was used in the capture) |
| Motion | as every sheet (§7) |

The Target pop-up lists the workspace's targets (2026-11-15: "GlassScroll" in
that project). What OK writes was not exercised; `schemes.md` (Writing) applies.

## 4. Quick Help placement (P-083)

Quick Help (⌥-click on a symbol, as captured) is an anchored popover with
these rules, observed for symbols near the bottom, in the middle and near the top
of the editor:

1. **Always above the symbol**, arrow pointing **down**, the arrow's tip ≈ 3 pt
   above the symbol's line.
2. **Centred horizontally on the clicked symbol** (Mode0 at x 1413 → popover
   1227–1613, global points; "name" on line 40 → popover centred on the word).
3. **Never flipped below and never clipped to the window**: for a symbol on line
   3 it extends over the toolbar and beyond the window's top edge (to ≈ 175 pt
   above it). It is limited only by the screen (not reached here: **OPEN**).
4. Width: body ≈ 358 pt (Store0) to ≈ 386–418 pt (Foundation, Mode0) in
   b5-obs, frame 413–446 wide; **417 pt** for both symbols of council round 12
   (§4.2). Use 417.
5. Content: the symbol's name (bold title); its declaration in an inset code box
   (darker than the body in dark, white in light); for a project symbol the
   file link ("Showcase.swift" with the file glyph); then **Relationships** /
   **Conforms To** with the protocols in monospaced type; for an SDK symbol a
   summary paragraph, an **Overview** section and an "Open in Developer
   Documentation" link instead of the file link. Markdown in the documentation
   is rendered (P-083's rendering items stand).
6. Appears in one frame once the information is ready (latency 0.3–3.4 s here,
   indexing under load); Escape removes it in one frame.

Material: `glass-materials.md` §1 (the Quick Help row: more transparent than the
choosers; light body mid grey).

### 4.1 A module name in an import (C07)

⌥-click on a module's name in an `import` line (Foundation on line 3 of
Showcase.swift) shows Quick Help for the **module**, like any symbol (Ycode in
round 12 showed nothing):

| Property | Reference (council round 12, 1x) |
|---|---|
| Placement | the rules above: above the line, arrow down, tip ≈ 3 pt above line 3, the popover's centre on the word's centre (±1 pt); it covers the toolbar and reaches ≈ 173 pt above the window's top edge |
| Size | body **417 × ≈ 288 pt**, plus the ≈ 11-pt arrow |
| Content, in order | (1) the module's name as the bold title; (2) the module's one- or two-line abstract in body text; (3) a hairline separator across the body's text width; (4) the heading **Overview** (bold, smaller than the title); (5) the overview paragraphs (six lines here); (6) **Open in Developer Documentation** as a small accent-blue link at the bottom right |
| Not shown | no declaration box, no file link, no Relationships section |

The text comes from the SDK's documentation for the module. Ycode shows the
module's own documentation from its documentation source; when that source has
no abstract or overview for the module, the popover still opens with the title
and the documentation link (never nothing). The reference's documentation text
is not copied into Ycode.

### 4.2 The size of a body symbol's popover (C07)

`name` on line 40 (`nonisolated let name: String`), both apps:

| Property | Reference | Ycode (round 12) |
|---|---|---|
| Body | **417 × 132 pt** (+ ≈ 11-pt arrow), window x 307–725, centred on the word (x 517) | 384 × 103 pt |
| Title | "name", bold ≈ 15 pt, 16 pt from the body's left edge | the same text, smaller margins |
| Declaration box | **385 × 50 pt**, inset 16 pt from the body's left and right edges, ≈ 8 pt below the title; fill ≈ #262626 in dark, **no border**, corners ≈ 6 pt; the declaration in the editor's monospaced font, syntax-coloured, **broken over two lines: the modifier (`nonisolated`) on the first, `let name: String` on the second**, line pitch ≈ 17.5 pt | one line in a bordered box that hugs its text |
| File link | the Swift file glyph (orange) and "Showcase.swift" in accent blue, ≈ 12 pt below the box | a generic document glyph |
| Scroller | an overlay scroller at the body's right edge when the content is taller than the body | none |

- **Width.** Both popovers recorded in round 12 were **417 pt** wide, as were
  Foundation and Mode0 in b5-obs (≈ 418); only Store0 in b5-obs was narrower
  (358). Use **417 pt** for the body and let the height follow the content;
  narrower bodies are OPEN.
- **Declaration lines.** Attributes and modifiers before the declaration's
  keyword go on their own line, as the reference printed them here (one case
  recorded: OPEN for several attributes).

## 5. Jump to Line, Quick Actions, Open Quickly (P-086)

Three in-window glass capsules, **55 pt tall**, fully rounded, horizontally
**centred on the window** (not on the editor), with a magnifier glyph at the left
and a borderless search field (no focus ring, caret only):

| | Jump to Line (⌘L) | Quick Actions (⇧⌘A) | Open Quickly (⇧⌘O) |
|---|---|---|---|
| Frame | **640 × 55** at window (380, 69) | **560 × 55** at (420, 55) | **640 × 55** at (380, 70) |
| Vertical place | 17 pt below the toolbar's bottom edge (y 52) | 3 pt below it | 18 pt below it |
| Field | 560 × 36, 61 pt in from the left, 10 pt down | 480 × 36 | as Jump to Line |
| Placeholder | "Line Number" | "Quick Actions" | "Open Quickly" |
| Below the field | nothing | an empty results list that grows with results | results (`open-quickly.md`) |
| Appears | one frame (+ ≈ 200 ms settle of the material) | one frame | one frame |
| Leaves on Escape | **fades over 120–165 ms**, ease-in | one frame | not measured |
| Return | jumps to the line and closes, one frame (2026-11-15) | runs the action | opens the item |

- The accessibility tree reports Quick Actions as the same kind of panel as Open
  Quickly, and both as dialogs, not sheets.
- The reference stores a position and width for Jump to Line and for the Open
  Quickly panel in its preferences once they have been used (keys absent before
  this run were created by it). The b5-obs places are therefore the **defaults**.
  Council round 9 (row 215) found Open Quickly's top at y 200: probably a stored
  position from earlier use. **OPEN**: whether the user can move or resize these
  panels; until settled, Ycode uses the defaults above and does not store them.
- 2026-11-15 gave Jump to Line as a "≈ 535-pt capsule"; use 640 (measured from
  both the frame and the drawn shape here).

### 5.1 Quick Actions results (C08)

⇧⌘A and "build" typed (dark, council round 12):

| Property | Reference |
|---|---|
| Panel | **560 pt wide**, at (420, 55), the same width with and without results; it grows downward to ≈ 495 pt here (window y 55–550) and the list scrolls inside it, with an overlay scroller at the right |
| Under the field | a 1-pt hairline at the field row's bottom (window y ≈ 110), lighter than the body; the rows start ≈ 10 pt below it |
| Row | **two lines, 56 pt tall**, rows touching (no gap) |
| Glyph | the command's own symbol (a hammer for Build, a page for Build Documentation, a play triangle for Build For › Running, and so on), ≈ 22–26 pt, in a ≈ 28-pt column whose centre is ≈ 33 pt from the panel's left edge; vertically centred in the row; white when selected, light grey otherwise |
| Title (line 1) | ≈ 17 pt (cap height ≈ 12 pt); the part that matches the query semibold white, the rest regular light grey (≈ #D0D0D0); a command in a sub-menu shows the sub-menu's path in its title ("Build For 〉 Running", "Syntax Coloring 〉 Build Phase File List") |
| Subtitle (line 2) | ≈ 14 pt regular, secondary grey (≈ #B0B0B4): the menu path of the command's parent ("Product", "Product 〉 Build For", "Editor 〉 Syntax Coloring") |
| Text column | 64 pt from the panel's left edge, aligned with the search field's text; the title's centre ≈ 18 pt below the row's top, the subtitle's ≈ 21 pt below the title's |
| Key equivalent | right-aligned, ending ≈ 30 pt left of the highlight's right edge, ≈ 14 pt, grey (≈ #A8A8A8), white when selected; none when the command has none |
| Selected row | a rounded rectangle in the accent blue (**#0059D1** in dark), corner radius ≈ 14 pt, the row's full 56-pt height, inset 8 pt from the panel's left edge and ≈ 21 pt from its right (the scroller's lane); glyph, title, subtitle and key all white |
| Initial selection | the first result |
| Order (this query) | Build; Build Documentation; Build For 〉 Running, Testing, Profiling; Syntax Coloring 〉 Build Phase File List; Perform Action 〉 Build with Timing Summary; Perform Action 〉 Build and Export Test Products: titles that begin with the query first, in menu order, then sub-menu items whose own title begins with it (ranking beyond this query: OPEN) |

Ycode in round 12: the same 560-pt panel, but one-line 32-pt rows, the menu path
in a right-hand column, no glyphs, an #007BFF highlight and a different result
list (Build Documentation, Build Configuration File, Clean Build Folder…, …).

## 6. The Library (⇧⌘L)

| Property | Value |
|---|---|
| Frame | **681 × 504** at window (357, 69): centred horizontally on the window, its top 17 pt below the toolbar (as Jump to Line) |
| Shape | in-window glass panel, corners ≈ 24 pt (`glass-materials.md` §1) |
| Header | a filter-options glyph, the search field (placeholder **"Snippets"** in a source file), a detail-pane toggle at the right |
| Category row | four category glyphs under the header, the current one tinted accent |
| Body | a list at the left (section heading "Swift"; rows ≈ 48 pt with a 32-pt icon tile and a title; the selected row highlighted) and a detail pane at the right (bold title, summary, a code-sample box, then Language / Platform / Completion / Availability) |
| Closes | on a **click outside** (one frame; b5-obs dark ≈ 60 ms ease-in, 2026-11-15 one frame +6 ms after the click) and on Escape |

Content and insertion: `specs/ide/library.md` (content is owner decision 8).

## 7. Sheets

- **Centred on the window both ways**, not attached under the toolbar (New Scheme
  at (454, 379), the recommended-settings checklist 581 × 364 at (410, 258)).
- The window behind, toolbar included, is **dimmed** (`glass-materials.md` §1);
  its traffic lights turn grey.
- **Motion:** in and out reach 50 % at 120–160 ms and **90 % at ≈ 210 ms after the
  click**; the entrance fits an ease-out best; the exit's curve was not fitted
  (b5-obs, both appearances). 2026-11-15 at 2x
  timed the template sheet's own motion at 133–150 ms (ease-out) and its exit at
  17 frames (≈ 140 ms); the New Branch sheet at ≈ 205 ms. Use a ≈ 150 ms ease-out
  entrance and a ≈ 150 ms exit that start with the next frame after the request.
- Buttons at the bottom right: default (blue) rightmost, Cancel to its left, 12 pt
  apart, 20 pt from the right edge, 17 pt from the bottom; Return and Escape map
  to them.

## 8. The workspace while a panel is in front (P-031)

With the scheme or destination chooser, Quick Help, the Library, Jump to Line,
Quick Actions, Open Quickly, About or Settings in front, the workspace keeps its
**active look**: coloured traffic lights (close dark #F26057 / light #F87D76,
minimise #FDC200 / #FCC836), toolbar glyphs at full contrast, the toolbar
unchanged. Only the navigator's selection turns to its unfocused grey (dark
#464647, light #D7D7D8) while a popover or palette has the keyboard. About changes
nothing in the workspace. Only a sheet dims it (§7). Ycode must make these panels
child panels or in-window overlays that do not take key-window status from the
workspace, with borderless fields (no focus ring).

## 9. Product ▸ Destination (P-014)

Light appearance (the dark menu opened outside the capture):

| Row | Notes |
|---|---|
| Choose Destination | |
| Select Next Destination | |
| Select Previous Destination | |
| — | |
| Show All Run Destinations | |
| — | |
| **Devices** | a heading |
| My Mac 27.2 | checked; the OS version at the right edge of the title |
| — | |
| **Build** | a heading |
| Any Mac (arm64, x86_64) | |
| — | |
| Incompatible › | a sub-menu (in the menu it is a cascade, unlike the popover) |
| — | |
| Manage Devices… | |

The menu's first heading reads **Devices** where the popover's reads **Recent**.
2026-11-15 found the Incompatible items enabled (choosing one switches) and the
headings enabled; those findings stand.

## 10. Quick New Project (P-180): not observed

⌘⇧N with a workspace open showed nothing in the capture or in the accessibility
tree within 2.5 s, twice (it may have opened on the other display). The inventory
row (from 2026-11-15) stays the spec: a **640 × 355** Open-Quickly-style panel
with a + icon, a search field, App / Command Line Tool / Package… / Playground /
Choose Template… rows with icons and subtitles; Down moves, typing filters,
Escape closes. Build it from the in-window panel of §11 with the capsules' width
(640) and place (§5).

## 11. One component model for both IDEs

Every surface above is one of three components. Each IDE implements each once
(macOS in `YcodeUI`, Linux on OpenViews) and the features configure them.

### 11.1 Anchored popover

| Parameter | Values |
|---|---|
| Anchor | a rectangle in window coordinates: a control (a capsule half) or a text range (the symbol's line box) |
| Preferred edge | **below** for toolbar choosers; **above** for Quick Help, with no flip and no clipping to the window |
| Horizontal place | centred on the anchor; shifted only to stay on screen, the arrow staying on the anchor |
| Arrow | 26 × 11 pt, tip touching the anchor's edge (≈ 3 pt off for a text anchor) |
| Material | popover glass (chooser) or the more transparent Quick Help glass (`glass-materials.md` §1) |
| Corners | ≈ 17 pt |
| Size | width fixed per use (scheme ≈ 213 body, destination ≈ 415, Quick Help 417, §4.2); height from content; in-place growth downward (Incompatible) |
| Opening | on **mouse-down** of the anchor control; one frame |
| Keyboard | focus in the popover's first field; Up/Down move a highlight; Right expands a disclosure row; Return chooses; typing filters |
| Dismissal | Escape (one frame), a click outside, choosing a row; the parent window keeps its active look |

On macOS the system popover gives the arrow, material and outside-click
dismissal; Ycode sets the anchor and edge and must not let the popover make the
workspace inactive. On Linux, OpenViews needs a popover window with the same
parameters (B5-OPENVIEWS: pop-ups and materials, P-217).

### 11.2 In-window panel

| Parameter | Values |
|---|---|
| Place | centred horizontally on the window; top 17 pt (Jump to Line, Open Quickly, Library), 3 pt (Quick Actions) below the toolbar |
| Shape | a 55-pt capsule that grows downward when it lists results; the Library a 24-pt-radius panel |
| Field | borderless, magnifier glyph, placeholder, caret only |
| Opening | one frame |
| Dismissal | Escape (Jump to Line fades 120–165 ms; the others one frame), a click outside, choosing a result |
| Parent | stays active (§8) |

### 11.3 Sheet

Centred both ways; the parent dimmed; ≈ 150 ms ease-out in, ≈ 150 ms out;
default and Cancel buttons as §7. Motion constants come from B5-MOTION's shared
set; the dimming and centring are system behaviour on macOS and an OpenViews
sheet on Linux (P-215).

## 12. OPEN

1. The destination chooser's dark entrance (≈ 140 ms) and exit (≈ 130 ms) under
   load 150, against one frame in light and at 2x.
2. Where Quick Help goes when there is no room above the symbol on the screen.
3. Whether Jump to Line and Open Quickly can be moved or resized by the user (the
   stored position and width), and Open Quickly's default top (y 70 here, y 200 in
   council round 9).
4. Open Quickly's and the Library's exit timing on Escape.
5. Whether the Incompatible list's height is capped by the screen or by its
   content (1044 pt at 1x on a 1440-pt screen, ≈ 800 at 2x).
6. Quick New Project (§10).
7. The destination chooser's highlight when no destination is checked (§2.7).
8. Quick Help bodies narrower than 417 pt (b5-obs's Store0 at 358), and the
   declaration's line breaks with several attributes (§4.2).
9. Quick Actions' ranking beyond prefix matches in menu order (§5.1), and its
   light appearance.

## Evidence

| Claim | Level | Source |
|---|---|---|
| §2 choosers: geometry, rows, highlight, keys, Escape, mouse-down | 3 | b5-obs 2026-11-20, item 3 (stills and accessibility frames of both popovers open, hovered, after Down/Up and Escape, both appearances; the capsule's held frame in item 1); parity 2026-11-15, items D-015, D-016, D-017, A-M-024 |
| §2.4 Incompatible | 3 | b5-obs 2026-11-20, item 3 (the device list itself painted over for privacy; only its geometry used); parity 2026-11-15, item D-017 |
| §2.6, §5, §6, §7 timings | 3 | b5-obs 2026-11-20, item 3: change timing per region in the recordings; parity 2026-11-15 (inventory §5, P-086, P-111, P-195) |
| §3 New Scheme sheet | 3 | b5-obs 2026-11-20, item 3 (still and accessibility frames); parity 2026-11-15, item D-015 |
| §4 Quick Help | 3 | b5-obs 2026-11-20, item 3 (symbols low in the editor, in the middle and on lines 3 and 8; popover frames from the accessibility tree) |
| §5 capsules and stored positions | 3 | b5-obs 2026-11-20, items 2 and 3 (stills, accessibility frames; the preference domain exported before and after the run, compared by key name only); council round 9, row 215 |
| §8 active look | 3 | b5-obs 2026-11-20, item 3 (traffic-light, glyph and selection colours with each panel in front) |
| §9 Destination menu | 3 | b5-obs 2026-11-20, item 3 (the light menu, accessibility tree); parity 2026-11-15, item A-S-050 |
| §10 | 3 | b5-obs 2026-11-20, item 3 (not observed); parity 2026-11-15, items A-S-001, A-M-009 |
| §2.7 | 3 | council round 12 (2026-11-21), C06: both choosers' stills just after opening (the highlighted row), rows from the stills (Ycode's rows are not in its accessibility tree) |
| §4.1, §4.2 | 3 | council round 12, C07: stills of both popovers in both apps, edges and colours measured on the 1x stills |
| §5.1 | 3 | council round 12, C08: the Quick Actions still with results in both apps; edges by pixel scans, colours sampled, type sizes from cap heights |
| §11 | 1 / — | Public AppKit documentation (popovers, panels, sheets); Ycode's own toolkit |

Nothing here rests on levels 4 or 5.
