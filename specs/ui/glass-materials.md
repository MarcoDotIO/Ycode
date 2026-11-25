# Glass materials and scroll edges

**Status:** boundary spec for B5-STATES (issues #57 and #58). Part A (§1–§5) is
**parity fact**: how the reference, Xcode 27.1, draws its toolbar, side areas,
popovers, in-window panels and sheets over dark and light content, and what
happens at the top and bottom edges of scrolled content. Part B (§6) is **Ycode's
own design rule** for glass surfaces the reference does not have. Prose, tables
and measured numbers only: no code, no copied resources.

**Relation to other specs.** `specs/ide/liquid-glass.md` holds the earlier
observations (rounds 1–3: the shapes, the toolbar geometry, the light active and
inactive values, and the strength of the veil behind the bars measured over solid
bands); `specs/ide/liquid-glass-ycode.md` is Ycode's record. This spec adds the
dark values, the popover, panel and sheet materials, and settles the scroll-edge
question. Where it differs from `liquid-glass.md`, §5 says which holds.

**Capture conditions.** b5-obs capture of 2026-11-20: a **1x** display at
**100 Hz**, the workspace window 1400 × 880 pt, key and in front, Xcode's
appearance System (dark), then Light, in one launch, host load 7–150. Sizes are
points at 1x, **±1 pt**; colours are sRGB from 1x stills (hairlines and sub-point
edges approximate); timings **±20 ms**. The rounds of `liquid-glass.md` ran at 1x
(rounds 1–2) and 2x (round 3).

## Part A: the reference

## 1. Surfaces

| Surface | Kind | Dark | Light | Shape |
|---|---|---|---|---|
| Toolbar band | opaque band; content beneath shows only as a faint veil (§3.3) | #29292A over the side areas, #262727 over the editor | #EDEDEE over the side areas, #FFFFFF over the editor | full width, y 0–51 |
| Toolbar items | glass capsules and circles | fill #434344–#444446, top rim #696A6C, bottom rim #747577 | fill #F0F0F3–#FCFCFC, top rim #FFFFFF, bottom rim #D8D8D9, a soft shadow ≈ 10 pt below | 36 tall (y 8–44), fully rounded; states in `control-states.md` §2 |
| Navigator and inspector areas | **opaque sidebars**, flush with the window edges | #29292A (navigator), #282829 (inspector) | #EDEDEE | no inset, no corner, no gap; editor content never passes under them |
| Navigator selector bar, inspector tab bar | glass capsules over the side area's content | `liquid-glass.md` §7.2, §9.2 | same | 30 tall, 7 pt in from the area's edges (so 276 wide in the 290-pt navigator, 246 wide in the 260-pt inspector) |
| Jump bar | opaque band, the editor's colour | #262627 | #FFFFFF (the toolbar shapes' shadow shades its top 10 pt to #FAFAFA–#FCFCFC) | y 52–83, then a **2-pt divider** (§3.1) |
| Editor bottom bar | opaque bar with a 1-pt separator; the veil of §3.3 | as the editor | #FFFFFF, separator #D7D7D7 | `liquid-glass.md` §3.2 |
| Scheme and destination popovers | system popover glass | body #3F3F40–#48484B (varies with what is behind) | #FCFBFE–#FDFCFE | arrow ≈ 26 wide × 11 tall; corners ≈ 17 pt; see `specs/ide/popovers.md` §2 |
| Quick Help popover | glass, noticeably **more transparent and darker** than the chooser popovers: the code behind shows blurred | body ≈ #3E3E3E–#444444, an inset declaration box darker than the body | body a **mid grey ≈ #8F8F8F–#929292** with the code behind blurred, an inset **white** declaration box | arrow pointing down; corners ≈ 17 pt |
| Jump to Line, Quick Actions, Open Quickly | in-window glass capsules, translucent: text behind them shows strongly blurred | fill ≈ #3F3D3D over the dark editor, a 1-pt lighter rim (#6F6E6E) at top and bottom | fill ≈ #FDFDFD | 55 tall, fully rounded (radius ≈ 27) |
| Library | in-window glass panel | fill ≈ #3A393A, lighter top rim | (light not recorded) | 681 × 504, corners ≈ 24 pt |
| Sheets (New Scheme, File from Template, the recommended-settings checklist) | **opaque** panel; the whole window behind it is dimmed | fill #232122, a 1-pt lighter top rim (#323131) over a dark outline; the window behind darkens by about a third (#29292A → #1C1C1D) | fill #FFFFFF, rim #E5E5E5 over #CCCCCC; the window behind darkens by about a sixth (#EDEDEE → #C5C5C6) | rounded rectangle, no arrow, centred in the window both ways; corners ≈ 17 pt (`liquid-glass.md` §2.9) |

Notes:
1. The **dimming under a sheet covers the toolbar too**: the close button turns
   grey and toolbar glyphs dim (Run's glyph #FFFFFF → #3B3B3C dark).
2. Popovers and in-window panels do **not** dim or deactivate the workspace
   (§4).
3. **Over light and dark content.** The Stripes image (four-colour diagonal
   stripes) was too small to sit behind most panels. Where content passed
   behind a palette it showed only as a blurred colour wash. The strength of
   the tint over solid colour is the round-2/3 measurement (`liquid-glass.md`
   §8.3, §9.1); the panels' tint over saturated colour is **OPEN**.

## 2. Corner radii and shadows

| Surface | Radius | Shadow |
|---|---|---|
| Toolbar capsule or circle | half the height (18) | light: soft, ≈ 10 pt below; dark: none visible at 1x |
| Selector and tab capsules | half the height (15) | none |
| Popovers | ≈ 17, continuous | not resolved at 1x |
| Jump to Line, Quick Actions, Open Quickly | half the height (≈ 27) | not resolved at 1x (the rim is) |
| Library | ≈ 24 | not resolved at 1x |
| Sheets | ≈ 17 | the dimming, plus a thin outline |

## 3. Scroll edges

### 3.1 No progressive scroll-edge effect

At every scroll offset recorded (0, 6, 12, 24, 48, 96, 192 and 392 pt, both
appearances) there is **no gradient, fade or blur ramp** below the toolbar or
the jump bar:

1. The jump bar ends in a **2-pt divider** at y 84–85: dark #3D3D3C over
   #363636, light #E3E3E3–#E5E5E5 over #E5E5E5. It looks **the same at the top
   of the file and scrolled**; it does not appear, darken or grow with the
   scroll.
2. Editor text is **clipped at the divider**: a line half under it shows its
   lower half at full colour right up to the divider.
3. The first visible row below the divider is at full colour (no fade).

### 3.2 The sticky first line of the enclosing declaration

When the first visible line lies inside a declaration whose own first line has
scrolled above the editor's top, that first line is **pinned under the jump
bar** (at 392 pt: "struct Box0<Value: …>: Sendable {", line 21):

- a band **20 pt tall** (y 85–104) in the editor's background colour, opaque,
  with the line's own **line number** in the gutter;
- a **2-pt separator** at its bottom (y 105–106): dark #3C3A3C over #353636,
  light #E6E5E6 over #E5E5E5, across the gutter and the text (not the minimap);
- the band starts at y 85, so it covers the second point of the jump bar's
  divider: with the header shown, only the divider's first point (y 84) is
  visible;
- following lines scroll **under** it and are clipped at its separator.

It was absent at 0–96 pt (no enclosing declaration) and present at 192 and 392.
`specs/ide/editor-area.md` §C.3 and §D.2 hold its earlier light measurements; they
agree.

### 3.3 The veil behind the toolbar band and jump bar

There is no fade, but the bars are not perfectly opaque. A faint, **uniform**
(not graded by height) blurred trace of the content beneath shows in the
toolbar band and the jump bar:

| Measurement | Conditions | Strength |
|---|---|---|
| b5-obs, Showcase.swift scrolled 392 pt (text, the current-line band) | 1x, dark and light | at most ≈ 7 levels per channel: dark #262627 → #2D292E under a purple keyword run, light #FFFFFF → #FAF7FC; the current-line band scrolled 12–24 pt under the jump bar lifts its bottom rows to #2D2C2D |
| Council round 2, Bands.swift over solid slate and red rows | 1x, light, active window | toolbar band ≈ 16–18 %, jump bar ≈ 8.5 %, bottom bar ≈ 12 % of the content's darkness |
| Council round 3, the same file | 2x, light | each bar shows the content beneath blurred (σ ≈ 6 pt), keeping its rows' structure; no vertical gradient |

Both hold: over ordinary text the veil is near the limit of visibility (the
b5-obs first pass called it "no blur visible"), over solid colour it is plain.
Ycode's target stays `liquid-glass.md` §9.1 item 3. The navigator outline's
passage under the selector and filter capsules is `liquid-glass.md` §8.4 and
§9.2.

### 3.4 Settings

The Settings window's scroll-edge blur under its pane bar (inventory P-154,
beta 9) was not re-observed. The workspace finding above does not apply to it.

## 4. The workspace's look while something is in front

| In front | Traffic lights | Toolbar | Navigator selection |
|---|---|---|---|
| Scheme or destination popover, Quick Help, Library, Jump to Line, Quick Actions, Open Quickly | **coloured** (close dark #F26057 / light #F87D76, minimise #FDC200 / #FCC836) | unchanged | the unfocused grey (dark #464647, light #D7D7D8), because focus moved into the popover or panel |
| About | coloured | unchanged | unchanged |
| Settings (a separate window) | coloured | unchanged | unchanged |
| A sheet | grey (#4D4D4D dark) | dimmed with the window | dimmed |

This **supersedes** `liquid-glass.md` §2.8's "the parent window draws inactive
while one of its popovers is key": in 27.1 the workspace keeps its active look
behind every popover and palette (inventory P-031).

## 5. Reconciliation with `liquid-glass.md`

| Topic | Earlier | Now | Holds |
|---|---|---|---|
| Parent window behind a popover | draws inactive (round 0, background capture) | stays active (§4) | now |
| Jump bar band | §3.3 item 1: no content; §7.3: a veil of ≈ 6 % | a faint veil, no fade (§3.3) | both, as §3.3 |
| Dark values | not observed (§4.1, §6 there) | §1 | now |
| Side areas | §2.1: flush, full height | the same, opaque, no content under them | both |
| Popover corners and arrow | ≈ 17 pt; arrow ≈ 10 × 26, tip 2 pt below the button | ≈ 17 pt; arrow ≈ 11 × 26, its tip at the capsule's bottom edge | both (±1 pt) |

## Part B: Ycode-only glass surfaces

## 6. Rule for surfaces the reference does not have

The owner's design rule: Ycode-only UI follows the HIG in the OS 26+ Liquid Glass
language; it never invents a material the reference does not use for the same
role. Choose by role:

| Role | Material | Shape | Examples in Ycode |
|---|---|---|---|
| A control in the toolbar | glass capsule or circle as §1 row 2, 36 tall, grouped with related items in one capsule | half-height radius | Device Hub, simulator controls in the toolbar |
| A transient chooser anchored to a control | the system popover (§1, chooser row), arrow to the control, `specs/ide/popovers.md` §9 | ≈ 17 pt | Ycode-only destinations, the remote-simulator chooser |
| A transient command or search field over the editor | an in-window glass capsule like Jump to Line: 55 tall, centred, 17 pt below the toolbar | half-height | any Ycode-only palette |
| A task that needs a decision | an opaque sheet centred in the window, the window dimmed (§1 sheet row) | ≈ 17 pt | Ycode-only setup sheets |
| Content areas (lists, inspectors, editors, the debug area) | **no glass**: opaque fills, flat controls (`liquid-glass.md` G10) | — | — |
| A bar floating over scrolling content in a Ycode-only area | a glass capsule like the navigator selector (30 tall, 7 pt inset), content passing under it blurred | half-height | Ycode-only navigators |

Further rules for Ycode-only surfaces:
1. No progressive scroll-edge effect in the workspace: match §3 (a hard edge,
   a 2-pt divider where a bar meets scrolling content). Use the system's soft
   scroll edge only in Ycode-only windows whose reference counterpart is a
   Settings-style window (P-154).
2. Use the system's material (on macOS the 26+ SDK's glass views and popovers);
   draw no custom blur on macOS. On Linux, OpenViews draws the material from the
   values in §1 (fill, rim, blur σ ≈ 6 pt at the shares of §3.3); B5-OPENVIEWS
   owns that renderer.
3. Respect the system's Reduce Transparency and Increase Contrast: glass becomes
   its opaque fill from §1 and rims become 1-pt outlines.
4. Accent colour only for the default button and the focused selection, as the
   reference does; never on a toolbar toggle.

## 7. OPEN

1. The tint of popovers, palettes and the Library over saturated colour (the
   stripes image was too small); light Library values.
2. Why the light Quick Help popover is mid grey where the chooser popovers are
   near white (observed in two sessions); confirm at 2x before Ycode copies it.
3. Shadows of the dark toolbar shapes, popovers, palettes and the Library (not resolved at 1x).
4. Settings' scroll-edge blur (P-154), not re-observed.

## Evidence

| Claim | Level | Source |
|---|---|---|
| §1 surfaces, §2 radii | 3 | b5-obs 2026-11-20, item 2 (glass stills at eight scroll offsets, panels and sheets over the editor and the Stripes image, both appearances) and item 3 (popover, palette, Library and sheet stills); colour samples of fully covered pixels; corner radii read from enlarged 1x stills (±2 pt) |
| §3.1 divider and clipping | 3 | b5-obs 2026-11-20, item 2: per-row colour columns through the jump bar and the first editor rows at each offset |
| §3.2 sticky line | 3 | b5-obs 2026-11-20, item 2; `editor-area.md` §C.3 (council round 1) |
| §3.3 veil | 3 | b5-obs 2026-11-20, item 2; `liquid-glass.md` §8.3 and §9.1 (council rounds 2 and 3) |
| §4 the look behind popovers | 3 | b5-obs 2026-11-20, item 3: traffic-light, toolbar-glyph and selection colours in each still with a popover, palette, About, Settings or a sheet in front |
| §6 | 1 / — | Apple's Human Interface Guidelines and "Adopting Liquid Glass" (public); the owner's design rule (2026-11-06) |

Nothing here rests on levels 4 or 5.
