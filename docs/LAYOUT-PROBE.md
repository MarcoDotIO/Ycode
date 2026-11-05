# Layout probe: Ycode's macOS IDE on other macOS versions

Ycode's spacing was tuned on macOS 27.2. The layout probe built into
Ycode.app measures the IDE's chrome on any Mac, with no developer tools
(`specs/ide/metrics.md` §14 describes it and the fixes it led to).

## Running it

```sh
cd ycode
scripts/layout-probe.sh local                     # this Mac
scripts/layout-probe.sh <user>@<other-mac>        # another Mac over SSH (keys only)
python3 -I scripts/layout-probe-table.py \
    .build-ide/layout-probe/local/probe.json \
    .build-ide/layout-probe/<user>_<other-mac>/probe.json
```

The script builds `.build-ide/probe-app/Ycode.app` (`YCODE_APP_MINIMAL=1
scripts/make-app.sh`) when it is missing, copies it to the other Mac's
`~/ycode-layout-probe/`, launches it in the logged-in GUI session with
`open -n --env YCODE_LAYOUT_PROBE=...`, waits for the report (ending the
probe's own process after `YCODE_PROBE_TIMEOUT` seconds) and copies back
`probe.json`, `probe.log` and the snapshots in `shots/`. The other Mac
needs only a GUI session for the SSH user. `YCODE_PROBE_SHOW=1` orders the
windows in; a smaller screen then shortens them.

The app reads:

| Variable | Meaning |
|---|---|
| `YCODE_LAYOUT_PROBE` | where the JSON report goes (the probe runs only with it) |
| `YCODE_LAYOUT_PROBE_PROJECT` | the project to open (default: a package "Demo" in a temporary folder) |
| `YCODE_LAYOUT_PROBE_SHOTS` | a folder for `cacheDisplay` snapshots |
| `YCODE_LAYOUT_PROBE_SETTLE` | seconds per state (default 1.5) |
| `YCODE_LAYOUT_PROBE_SHOW` | `1`: order the windows in |
| `YCODE_LAYOUT_PROBE_APPEARANCE` | `dark` for the dark appearance (default light) |

The report holds the macOS version, the backing scale, the screen size,
every frame (`frames`) and each measure against its spec value
(`measures`: value, spec, `=`/`<=`/`>=`, tolerance, delta, ok, source).
The CI runner (macOS 27.0) can run it with `scripts/layout-probe.sh local`.

## Report: macOS 27.2 and 27.0 (2026-11-04, after the fixes)

Window points, origin at the top left; the workspace window 1400 × 900,
the plain navigator 280 × 600, Device Hub 1100 × 800, all off screen.
Delta is value − spec; a bound shows "ok". The filter rows are given for
the Project navigator; the other eight navigators (and the plain
navigator's nine) have 104 more rows, all met on both systems, with
identical values on both.

| Report | macOS | Backing scale | Glass layout | Windows shown | Screen |
|---|---|---|---|---|---|
| macOS 27.2.0 (1x) | Version 27.2 (Build 26B5112a) | 1 | True | False | 3440 x 1440 |
| macOS 27.0.0 (1x) | Version 27.0 (Build 26A428) | 1 | True | False | 1020 x 588 |

| Element | Spec | macOS 27.2.0 (1x) | delta | macOS 27.0.0 (1x) | delta | Source |
|---|---|---|---|---|---|---|
| toolbar.height | 52 (±0.5) | 52 | 0 | 52 | 0 | metrics.md §3 |
| toolbar.run.x | 208.5 (±0.5) | 209 | 0.5 | 209 | 0.5 | metrics.md §3 |
| toolbar.run.maxX | 281.5 (±0.5) | 282 | 0.5 | 282 | 0.5 | metrics.md §3 |
| toolbar.history.x | 297.5 (±0.5) | 298 | 0.5 | 298 | 0.5 | metrics.md §3 |
| toolbar.history.maxX | 370.5 (±0.5) | 371 | 0.5 | 371 | 0.5 | metrics.md §3 |
| toolbar.activityIcon.gapAfterHistory | 14 (±0.5) | 14 | 0 | 14 | 0 | liquid-glass.md §7.1 |
| toolbar.activityIcon.x | 385 (±0.5) | 385 | 0 | 385 | 0 | liquid-glass.md §7.1 |
| navigator.area.x | 0 (±0.5) | 0 | 0 | 0 | 0 | metrics.md §2 |
| navigator.area.w | 290 (±0.5) | 290 | 0 | 290 | 0 | metrics.md §2 |
| navigator.selector.x | 6 (±0.5) | 6 | 0 | 6 | 0 | metrics.md §2 |
| navigator.selector.y | 51 (±0.5) | 51 | 0 | 51 | 0 | metrics.md §2 |
| navigator.selector.w | 278 (±0.5) | 278 | 0 | 278 | 0 | metrics.md §2 |
| navigator.selector.h | 30 (±0.5) | 30 | 0 | 30 | 0 | metrics.md §2 |
| navigator.selectorPill.w | 30 (±0.5) | 30 | 0 | 30 | 0 | metrics.md §2 |
| navigator.selectorPill.h | 24 (±0.5) | 24 | 0 | 24 | 0 | metrics.md §2 |
| navigator.row0.gapBelowSelector | 7 (±0.5) | 7 | 0 | 7 | 0 | metrics.md §2 |
| navigator.row0.h | 22 (±0.5) | 22 | 0 | 22 | 0 | metrics.md §2 |
| navigator.plus.x | 6 (±0.5) | 6 | 0 | 6 | 0 | metrics.md §2 |
| navigator.plus.maxY | 893 (±0.5) | 893 | 0 | 893 | 0 | metrics.md §2 |
| navigator.plus.w | 31 (±0.5) | 31 | 0 | 31 | 0 | metrics.md §2 |
| navigator.plus.h | 30 (±0.5) | 30 | 0 | 30 | 0 | metrics.md §2 |
| navigator.filterCapsule.x | 42 (±0.5) | 42 | 0 | 42 | 0 | metrics.md §2 |
| navigator.filterCapsule.maxX | 284 (±0.5) | 284 | 0 | 284 | 0 | metrics.md §2 |
| navigator.filterCapsule.maxY | 893 (±0.5) | 893 | 0 | 893 | 0 | metrics.md §2 |
| navigator.filterCapsule.h | 30 (±0.5) | 30 | 0 | 30 | 0 | metrics.md §2 |
| navigator[0].options.leadingGap | <= 4 | 4 | ok | 4 | ok | NavigatorInspectorR45Tests (reference-ui-6.md §5.6) |
| navigator[0].options.inside | 1 | 1 | 0 | 1 | 0 | NavigatorInspectorR45Tests (reference-ui-6.md §5.6) |
| navigator[0].text.afterOptions | >= 0 (±0.5) | 0 | ok | 0 | ok | NavigatorInspectorR45Tests (reference-ui-6.md §5.6) |
| navigator[0].toggle0.inside | 1 | 1 | 0 | 1 | 0 | NavigatorInspectorR45Tests (reference-ui-6.md §5.6) |
| navigator[0].text.beforeToggle0 | >= 0 (±0.5) | 16 | ok | 16 | ok | NavigatorInspectorR45Tests (reference-ui-6.md §5.6) |
| navigator[0].toggle1.inside | 1 | 1 | 0 | 1 | 0 | NavigatorInspectorR45Tests (reference-ui-6.md §5.6) |
| navigator[0].text.beforeToggle1 | >= 0 (±0.5) | 36 | ok | 36 | ok | NavigatorInspectorR45Tests (reference-ui-6.md §5.6) |
| navigator[0].toggles.trailingGap | <= 6 | 6 | ok | 6 | ok | NavigatorInspectorR45Tests (reference-ui-6.md §5.6) |
| editor.jumpBar.y | 52 (±0.5) | 52 | 0 | 52 | 0 | metrics.md §12.3, UISpacingTests |
| editor.jumpBar.h | 34 (±0.5) | 34 | 0 | 34 | 0 | metrics.md §12.3, UISpacingTests |
| editor.textTop | 86 (±0.5) | 86 | 0 | 86 | 0 | UISpacingTests |
| editor.debugBar.maxY | 900 (±0.5) | 900 | 0 | 900 | 0 | metrics.md §4 |
| editor.debugBar.h | 36 (±0.5) | 36 | 0 | 36 | 0 | metrics.md §4 |
| inspector.area.w | 260 (±0.5) | 260 | 0 | 260 | 0 | metrics.md §5 |
| inspector.tabs.x | 1146 (±0.5) | 1146 | 0 | 1146 | 0 | LiquidGlassTests, liquid-glass-ycode.md §3 |
| inspector.tabs.y | 51 (±0.5) | 51 | 0 | 51 | 0 | LiquidGlassTests, liquid-glass-ycode.md §3 |
| inspector.tabs.maxX | 1394 (±0.5) | 1394 | 0 | 1394 | 0 | LiquidGlassTests, liquid-glass-ycode.md §3 |
| inspector.tabs.h | 30 (±0.5) | 30 | 0 | 30 | 0 | LiquidGlassTests, liquid-glass-ycode.md §3 |
| inspector.tabPill.w | 78 (±0.5) | 78 | 0 | 78 | 0 | metrics.md §5 |
| inspector.tabPill.h | 24 (±0.5) | 24 | 0 | 24 | 0 | metrics.md §5 |
| inspector.name.trailingInset | 7 (±1) | 6 | -1 | 6 | -1 | metrics.md §12.4, UISpacingTests |
| inspector.row.Indent Using.trailingInset | >= 8 (±1) | 8 | ok | 8 | ok | UISpacingTests |
| inspector.row.Indent Using.leadingInset | >= 8 | 79 | ok | 79 | ok | UISpacingTests |
| inspector.row.Line Endings.trailingInset | >= 8 (±1) | 8 | ok | 8 | ok | UISpacingTests |
| inspector.row.Line Endings.leadingInset | >= 8 | 79 | ok | 79 | ok | UISpacingTests |
| inspector.row.Location.trailingInset | >= 8 (±1) | 34 | ok | 35 | ok | UISpacingTests |
| inspector.row.Location.leadingInset | >= 8 | 79 | ok | 79 | ok | UISpacingTests |
| inspector.row.Text Encoding.trailingInset | >= 8 (±1) | 8 | ok | 8 | ok | UISpacingTests |
| inspector.row.Text Encoding.leadingInset | >= 8 | 79 | ok | 79 | ok | UISpacingTests |
| inspector.row.Type.trailingInset | >= 8 (±1) | 8 | ok | 8 | ok | UISpacingTests |
| inspector.row.Type.leadingInset | >= 8 | 79 | ok | 79 | ok | UISpacingTests |
| debug.variablesBar.maxY | 900 (±0.5) | 900 | 0 | 900 | 0 | metrics.md §7 |
| debug.variablesBar.h | 28 (±0.5) | 28 | 0 | 28 | 0 | metrics.md §7 |
| debug.variablesBar.controlsAboveBottom | >= 3.5 | 4 | ok | 4 | ok | UISpacingTests |
| debug.consoleBar.maxY | 900 (±0.5) | 900 | 0 | 900 | 0 | metrics.md §7 |
| debug.consoleBar.h | 28 (±0.5) | 28 | 0 | 28 | 0 | metrics.md §7 |
| debug.consoleBar.controlsAboveBottom | >= 3.5 | 4 | ok | 4 | ok | UISpacingTests |
| plainNavigator[0].options.leadingGap | <= 4 | 4 | ok | 4 | ok | NavigatorInspectorR45Tests (reference-ui-6.md §5.6) |
| plainNavigator[0].options.inside | 1 | 1 | 0 | 1 | 0 | NavigatorInspectorR45Tests (reference-ui-6.md §5.6) |
| plainNavigator[0].text.afterOptions | >= 0 (±0.5) | 0 | ok | 0 | ok | NavigatorInspectorR45Tests (reference-ui-6.md §5.6) |
| plainNavigator[0].toggle0.inside | 1 | 1 | 0 | 1 | 0 | NavigatorInspectorR45Tests (reference-ui-6.md §5.6) |
| plainNavigator[0].text.beforeToggle0 | >= 0 (±0.5) | 16 | ok | 16 | ok | NavigatorInspectorR45Tests (reference-ui-6.md §5.6) |
| plainNavigator[0].toggle1.inside | 1 | 1 | 0 | 1 | 0 | NavigatorInspectorR45Tests (reference-ui-6.md §5.6) |
| plainNavigator[0].text.beforeToggle1 | >= 0 (±0.5) | 36 | ok | 36 | ok | NavigatorInspectorR45Tests (reference-ui-6.md §5.6) |
| plainNavigator[0].toggles.trailingGap | <= 6 | 6 | ok | 6 | ok | NavigatorInspectorR45Tests (reference-ui-6.md §5.6) |
| hub.hideSidebar.gapToSidebarEdge | 7 (±1.5) | 8 | 1 | 8 | 1 | metrics.md §9, UISpacingTests |

Both systems drew at 1x here (the 27.2 Mac's main screen was an external
1x display; the VM is 1x). Point frames do not depend on the scale, but at
1x a half-point position rounds to a whole pixel; a run on 27.2 at 2x
before the fixes agreed with these values to half a point.

### Before the fixes, on macOS 27.0

| Element | Spec | 27.2 | 27.0 | Delta on 27.0 |
|---|---|---|---|---|
| Activity icon x | 385 (`liquid-glass.md` §7.1) | 375 | 379 | −6 (−10 on 27.2) |
| Debug navigator's first toggle inside the field (top y ≥ field's 870 − 0.5) | inside | 870.5 (2x) | 869 | −1: outside |
| New Conversation x | — | 581 | 585 | +4 against 27.2 |

### Positions with no spec value that differ between the versions (after the fixes)

| Element (x) | 27.2 | 27.0 | Difference |
|---|---|---|---|
| Activity view (its icon is at 385 on both) | 375, 77 wide | 379, 73 wide | the system's gap before it |
| New Conversation | 585 | 588 | +3 |
| Scheme capsule's contents | 629 | 632 | +3 |
| Add Editor, Editor Options, editor modes | 922, 963, 1009 | 923, 964, 1010 | +1 |
| Device Hub: Capture Keyboard, zoom group, Open, More | 534, 579, 739, 775 | 535, 580, 740, 776 | ±1 |
| Inspector: Location pop-up width | 147 | 146 | −1 |
