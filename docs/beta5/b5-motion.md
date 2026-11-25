# B5-MOTION (1.0.0-beta.5): the motion layer

Clean-room workstream for the motion system of beta 5
(`docs/ROADMAP-1.0.md`, beta 5; rows in `specs/ide/parity-inventory.md`).
Items: P-024, P-078, P-137, P-190, P-191, P-192, P-193, P-194, P-196, P-197,
P-201.

## The shared layer (`YcodeIDECore`, next to `EditorMetrics`)

| File | What it holds |
|---|---|
| `Model/MotionCatalog.swift` | `Motion`: every measured curve as the reference's start and end (ms from the input) and its Bézier; `delay` subtracts `Motion.inputLatency` (57 ms: the parity run's inspector hide moved at +132 on a 75 ms delay). Navigator, debug area, ⌘Y dim, inspector (toolbar and ⌥⌘1/2/3), selector disc and ⌘1 fade, outline collapse/expand, sheet exits, merge alert, tooltip hold and fade. `MotionClock`: the inspector's clock for any curve (late first frame starts the motion, a stall advances one 30 Hz frame at most). |
| `Model/FlickProfile.swift` | The flick per display (P-078): momentum gain time constant, main 04's stretch at the top and X03's at the bottom, the springs; `forDisplay(scale:)`; the council's logged input (`mainFlick`, `slowFlick`). |
| `Model/NarrowWindowLayout.swift` | P-024 (`specs/ide/window-layout.md` §1, §4): above 850 pt only the editor narrows (290 / 300 / 260); editor ≥ 300; on a live drag the navigator gives up room to about 140 (135 here: Ycode's 290 + 260 areas and 1-pt dividers leave 138 at 700) and hides, then the inspector shrinks to 201.5; window minimum 503; a hidden navigator stays hidden. |

`EditorMetrics.inspectorSlide*` and `InspectorSlideClock` read `Motion.inspector`;
`EditorMomentum`, `TopBounce` and `EditorFlick` take a profile (round 9's by
default, so older callers and tests keep their numbers).

| Curve | Reference (from the input) | Delay + motion (from the press) | Bézier |
|---|---|---|---|
| Navigator hide (toolbar, ⌘0) | +93 → +334 | 36 + 241 | (0.25, 1, 0.7, 1): 33 % at +25, 90 % at +125 |
| Navigator show | +102 → +344 | 45 + 242 | ease-in |
| Navigator show (View menu) | +38 → +280 | 0 + 242 | ease-in |
| Debug area hide / show | +74 → +307 / +127 → +319 | 17 + 233 / 70 + 192 | ease-in / ease-out |
| ⌘Y breakpoint dim | +88 → +155 | 31 + 67 | linear |
| Inspector hide / show | +129 → +404 / +78 → +320 | 72 + 275 / 21 + 242 | ease-out / ease-in-out |
| Inspector ⌥⌘N hide / show | +67 → +367 / +111 → +377 | 10 + 300 / 54 + 266 | ease-out / ease-in-out |
| Selector disc (click) | +147 → +430 | 69 after the content swap + 283 | ease-out |
| ⌘1 fade | 75 ms | — | fade |
| Outline collapse (Left) / expand | 75 / 150–200 ms | — | system |
| Merge alert drop, veil | +85 → +368 | 28 + 283 | ease-in-out |
| Sheet exits | 250–315 (scheme +75 → +246, Create Branch +177 → +493) | 0.28 s generic | ease-in |
| New Project options page fade-in / Welcome fade-out before Open… (B5-NEWPROJECT) | 190 ms / 100 ms | `Motion.newProjectOptionsFadeIn`, `Motion.welcomeFadeOut` | — |
| Run button menu hold (B5-TOOLBAR, P-028) | 374 ms | `Motion.runMenuHoldDelay` (read by `RunButtonMenu.holdDelay`) | — |
| Tooltip | appears after 1.6 s (toolbar; 0.3 s chained), 1.1 s (editor tab), in one frame, 18 pt below the pointer, 24 pt tall, #444446 with a #101012 outline; 290 ms hold, 310 ms fade (the 1x 360 + 460 is OPEN) | — | linear fade |

## Per item

| Item | macOS | Linux |
|---|---|---|
| P-190 navigator slide | `+PaneSlide.swift`: ⌘0 and the toolbar toggle slide divider 0 on a display link with `MotionClock` (36 + 241 ms hide, 45 + 242 show, the menu path from 0); the item opens with the first moving frame and collapses with the last; the contents keep their width and leave by the leading edge (`RigidSlide`: their leading constraints are set aside for the slide, since the selector bar would hold the pane at 266 pt). The pane holds its last 10 pt for the hide's ease-out tail. Only a window on a display slides. | `PaneSlideState(.navigator)` + `NavigatorSlidePane` (content pinned, leaves by the leading edge) on the shared curves; frame cadence waits for P-200. |
| P-191 debug area | `slideDebugArea` (divider 0 of the centre split), the same driver. ⌘Y's 11-frame dim of the breakpoint arrows is not done (the gutter is not B5-MOTION's file): `Motion.breakpointDim` is ready. | `PaneSlideState(.debugArea)` + `DebugSlidePane`. |
| P-192 inspector | Curves from the catalogue; ⌥⌘1/2/3 on the shown inspector toggles it on the selector's curves (`toggleInspector(bySelector:)`). | Same curves; `toggleInspector(bySelector:)` in the model (`+PaneMotion.swift`). |
| P-193 selector disc | `SelectionPillView+Slide.swift`: a click slides the pill (69 ms after the content swap, 283 ms ease-out), ⌘1 fades it (75 ms), ⌘2–⌘9 jump. The ⌘N content swap's +55 ms difference is the navigator's (not changed). | Not done: the Linux selector is B5-NAVIGATOR's `NavigatorArea.swift`. |
| P-194 outline collapse | `NavigatorOutlineView+Motion.swift`: Left arrow collapses with a 75 ms animation. The disclosure flicker (labels vanishing ≈ 60 ms) is not reproduced off screen and not fixed. | Not done: `OutlineRows.swift` is B5-NAVIGATOR's. |
| P-196 sheet exits | Constants only. Clone and New Branch are app-modal alerts (`runModal`) in files of other workstreams; they need to become sheets to animate. | OpenViews' sheets (B5-OPENVIEWS). |
| P-197 tooltips | Constants only (`Motion.tooltipDelay`, placement and colours, `Motion.tooltipOpacity`). Ycode's tooltips are the system's `toolTip`; the stale tooltip and the one-frame removal need an on-screen trace. | OpenViews' `.help` (B5-OPENVIEWS). |
| P-137 merge alert | The alert drops 32 pt into place over 28 + 283 ms (ease-in-out) while the veil darkens on the same curve; Merge turns accent at the end. | The same drop; the veil uses the macOS ease-out (0, 0, 0.58, 1) instead of (0.215, 0.61, 0.355, 1) (L-174). |
| P-078 flicks | `EditorTopBounce` picks `FlickProfile.forDisplay(window.backingScaleFactor)`. | `SourceEditorController+Flick` picks it by the editor's display scale. |
| P-024 narrow windows | Minimum 503; editor ≥ 300; navigator holding priority below the inspector's; a live resize hides the navigator once it would go below its floor, for good. The navigator's content (its selector bar) holds it at ≈ 266 pt, so a live drag hides it at ≈ 828 pt rather than ≈ 700, and a frame set below 850 keeps it at 266 while the inspector gives up room (the editor stays at 300; `window-layout.md` §4 rule 3). | Editor ≥ 300, inspector ≥ 201.5, navigator capped by `NarrowWindowLayout` at rest so it gives up room first from 850; narrowing hides it once it would go below 135. |
| P-201 live resize | Not changed: needs an on-screen trace (the off-screen step is already under 100 ms). | Not checked. |

## Flicks from the council's logged input (shared model, 120 Hz frames)

| Profile | Main 04 stretch | X03 past the end | X05 travel |
|---|---|---|---|
| 2x 120 Hz (round 11) | 23.0 (deepest +200, rest +708) | 18.0 (rest +525) | 394.0, short of the top |
| 1x 100 Hz (round 10) | 181.8 (rest +850; reference +830) | 110.9 (rest +808) | 552.0, short of the top |

On macOS off screen (2x profile, synthesized whole-point events): main 04
stretches 23.6; X05 applies 257 of its momentum and stops 208 short of the top.

The frame cadence: the bounce draws on the window's display link every
frame; the model has no held frame from the first move to rest. The
on-screen cadence (20 ms in round 11) can only be measured on screen.

## Tests

- `ycode/Tests/YcodeIDECoreTests/B5MotionTests.swift` (both machines): every
  curve against the reference's start and end, shapes, the clocks, tooltip,
  narrow panes, the flicks on both profiles.
- `ycode/Tests/YcodeUITests/B5MotionUITests.swift` (macOS, off screen):
  navigator and debug slides frame by frame, hidden windows do not slide,
  ⌥⌘N toggles, the selector disc, Left-arrow collapse, the merge alert,
  narrow windows, the flick profile; `R8_TIMING=1` for frame-stepped timing,
  `R8_PROFILE=1` for a scroll-frame profile.
- Linux walk `YCODE_IDE_MOTION5=<prefix>` (`ShellDriver+Motion5.swift`).
- Older tests that pinned round 10's inspector timing and round 9's flick
  now read the catalogue or pin `FlickProfile.round9`.

## Linux slide frame rates (after B5-OPENVIEWS' incremental pipeline)

Release build on the x86 (load ≈ 5), `YCODE_IDE_MOTION5_FPS=1`: frames presented
between each curve's start and end.

| Slide | Hide | Show | Frame work (median / max) |
|---|---|---|---|
| Navigator | 58 fps (14 in 241 ms) | 59 fps (17 in 289 ms) | 18–19 / 20 ms |
| Inspector | 49 fps (14 in 287 ms) | 51 fps (13 in 253 ms) | 18–19 / 25–37 ms |
| Debug area | 59 fps (14 in 238 ms) | 50 fps (10 in 198 ms) | 14–16 / 24–35 ms |

No slide went above 59 fps, which suggests a 60 Hz display (not checked). On
that reading the navigator and the debug area's hide draw about every frame,
and the inspector and the debug area's show still drop about one frame in six.
