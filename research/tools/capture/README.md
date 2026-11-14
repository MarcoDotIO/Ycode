# Capture sessions (dirty room)

Scripted recordings of the same UI states in Xcode 27.1 and in Ycode, for
the motion and material observations (#31, #56 to #65) and the review
council. The generic recorder, timing measurer and sheet maker are in
`tools/capture/` (see its README); this folder holds what drives the apps.

| File | What it is |
|---|---|
| `session.py` | Runs a script against one or more targets, writes manifests and comparison sheets |
| `axdrive/` | Swift tool: drives one app by PID through Accessibility and events posted to that process only |
| `targets.json` | The apps: Ycode (the `swift build` binary, SDK-stamped and wrapped as a bundle with its own ID) and Xcode |
| `make-test-project.py` | Writes the GlassScroll test project (our own content) |
| `make-conflict-project.py` | Writes Merger: GlassScroll cut down, in a git repository whose `feature` branch conflicts with `main` in `Greeting.swift` (fixed test identity and dates) |
| `scripts/*.json` | Session scripts: `council-r2.json` (the review council's round 2, `specs/ide/fidelity-council.md`), `council-r3.json` (round 3: round 2's steps, then Settings ▸ General), `council-r3-conflict.json` (the conflict editor), `council-r3-device.json` (the device window: Device Hub against Ycode's Device Hub), `council-r4*.json` (round 4: round 3's steps and ids, plus Settings ▸ Text Editing, a navigator bottom-bar crop and the merge alert; Ycode's merge now goes through its own UI), `council-r5*.json` (round 5: round 4's steps and ids, then Settings ▸ Components, then the Appearance pane, General, Text Editing and Components with each app's own Appearance set to Light, then Appearance back to System; the conflict session leaves room for the reference's merge sheet), `council-r6*.json` (round 6: round 5's steps and ids; alert buttons pressed through Accessibility), `glass-scroll-edges.json` (#57) |
| `extra_sheets.py` | Sheets for `snap` stills and `crop` details (see Round 4 additions) |

## Procedure

1. **Recordings stay in `research/dirty/`.** Sessions write only to
   `research/dirty/captures/<date>-<session>/` (and the test project and
   app wrapper to `research/dirty/test-projects/` and
   `research/dirty/apps/`), all git-ignored. Recordings, stills and sheets
   of Xcode show Apple's artwork: they are never committed, attached to an
   issue, linked from one or copied out of that folder. Only prose specs
   with measured values cross into `specs/`.
2. **Test projects only.** Every target opens a fresh copy of the test
   project made by `make-test-project.py`; never the owner's own projects.
3. **The owner agrees to every Xcode session in advance.** `session.py`
   refuses the `xcode` target without `--owner-approved`. It also refuses
   to use an Xcode (or Ycode capture build) that is already running: it
   only drives and quits the instance it started.
4. **Background by default.** Apps are opened with `open -g` and never
   brought to the front; the owner can keep working. The test window is the
   only window that is moved or resized. A script that needs the keyboard
   or the pointer (menus, keys, clicks, drags, real scroll-wheel input) sets
   `"focus": "foreground"`, and those steps run only with `--allow-focus`
   or `--council`, given when the owner agrees to hand over the Mac for
   that session: the app is brought to the front before every step, pointer
   and wheel events go through the system's event stream (so the pointer
   moves over the test window and is put back after each action), and the
   app that was in front is brought back at the end. `axdrive` refuses to
   send pointer events unless the target app is frontmost and the
   accessibility hit test at that point lands in it.
5. **Permissions are granted by the owner,** never by an agent: Screen
   Recording (for `wincap`) and Accessibility (for `axdrive`), both to the
   app that runs the session (the terminal or agent host; `wincap check`
   and `axdrive check` print the process chain). System Settings > Privacy
   & Security > Screen & System Audio Recording, and > Accessibility.
6. **Scale and frame rate are recorded.** The window goes on the built-in
   (Retina) display. If a full-screen app occupies it, the session stops
   before launching anything ("leave the built-in display free, then
   rerun"); `--allow-1x` puts the window on the main display instead. The
   manifest records the display, its scale and refresh rate, the frame rate
   used, and each video's sidecar its pixel scale and frame times. Compare
   only sessions captured at the same scale; sheets enlarge a lower scale
   and say so.
7. **Input timing and window size come from the script**, so both apps get
   the same trigger: scroll distance, event count and interval, window size
   in points. Timed input runs on fixed wall-clock deadlines (event i at
   start + i x interval), so a slow app cannot stretch its own input; each
   action's result records the schedule's real duration and, for scrolls,
   the travel the app actually made (`measured_dy`).
8. **Ycode must declare the current SDK.** SwiftPM writes the deployment
   target (15.0) as the SDK in `LC_BUILD_VERSION`, and AppKit then draws
   its pre-macOS-26 look (no toolbar capsules, opaque toolbar). The capture
   wrapper stamps the SDK of `xcrun --show-sdk-version` with `vtool
   -set-build-version`, as `ycode/scripts/make-app.sh` does, and signs it
   ad hoc again; the session refuses to run a Ycode whose SDK major version
   is older than the running macOS's. Check with
   `vtool -show-build research/dirty/apps/Ycode.app/Contents/MacOS/YcodeApp`.

## Running a session

```sh
# the council's session, Ycode only (foreground, 120 fps, momentum flicks):
python3 -I research/tools/capture/session.py research/tools/capture/scripts/council-r2.json --target ycode --council
# with the owner's agreement, both apps side by side:
YCODE_REFERENCE_XCODE=/path/to/Xcode.app python3 -I research/tools/capture/session.py \
    research/tools/capture/scripts/council-r2.json --target xcode --target ycode --council --owner-approved
# a background session (no focus taken; AX scrolls, no momentum):
python3 -I research/tools/capture/session.py research/tools/capture/scripts/glass-scroll-edges.json --target ycode
```

`--council` = foreground with `--allow-focus`, wheel events with gesture
and momentum phases where the script asks for them, and 120 fps recording
capped at the display's refresh rate (the built-in display runs at 120 Hz).

Build Ycode first (`cd ycode && swift build --product YcodeApp`); `wincap`
and `axdrive` build themselves on first use. Output: `<target>/manifest.json`,
`NN-step.mov` (+ `.json`), `NN-step-before.png`, `NN-step-after.png`, and
`compare/index.html` with the sheets. `--keep-open` leaves the app running,
`--no-compare` skips the sheets, `--out DIR` changes the folder.

## Script format

```json
{
  "name": "glass-scroll-edges",          // folder name of the session
  "issue": 57,
  "targets": ["xcode", "ycode"],         // default targets; --target overrides
  "compare_order": ["xcode", "ycode"],   // left to right in the sheets
  "project": {"generator": "make-test-project.py", "path": "GlassScroll/GlassScroll.xcodeproj"},
  "window": {"size": [1400, 880], "display": "builtin", "title": "{project}", "timeout": 90},
  "focus": "background",                 // or "foreground" (needs --allow-focus)
  "launch_settle": 3.0,                  // seconds after the window appears
  "record": {"fps": 60, "codec": "prores4444", "pre": 0.4, "post": 1.2},
  "setup": [{"open": "GlassScroll/Long.swift"}, {"wait": 2.0}],
  "steps": [
    {"id": "editor-scroll-down", "note": "what the judges should look at",
     "do": [{"scroll": {"at": [700, 450]}, "dy": -600, "steps": 60, "interval": 0.016}],
     "record": {"post": 1.0},            // overrides; false = no video
     "still": "both",                    // before, after, both or none
     "only": ["ycode"],                  // optional: run for these targets only
     "per_target": {"xcode": {"do": []}}, // optional: replace fields per target
     "per_focus": {"foreground": {"do": []}}} // optional: replace fields in a foreground session
  ]
}
```

(The comments are for this README; scripts are plain JSON.)

Round 3 additions:
- `--project-dir DIR` puts the project copies outside the repository (and
  outside any path that names a person): otherwise the apps' source control
  views show this repository, and inspectors show the copy's full path.
- `--steps a,b` re-runs only those steps (they keep their numbers), to redo
  an invalid capture into another `--out` folder.
- Step fields: `"capture_title"` records and stills another window of the
  app chosen by title (Settings); `"record": {"video": false, "mode": "app"}`
  takes a still in that mode without a video.
- Actions: `run` (a command in the project copy, for example `git merge`,
  for an app without a menu path for that step) and `move` (`[x, y]` from
  the session display's top left, `"window"` by title).
- Script fields: `per_target_setup`, `project_targets` (targets that open
  the project; the others launch without a document), `names` (extra
  substitutions per target), and `window.wait_title: null` for an app whose
  first window title is not known (Device Hub reopens on the last device).
- Targets launch with `-ApplePersistenceIgnoreState YES`, so no window from
  an earlier session is restored. The `devicehub` target is Xcode's Device
  Hub (`YCODE_REFERENCE_DEVICEHUB`); it needs `--owner-approved`.

Round 4 additions:
- Action `{"snap": "<name>", "mode": "app"}` takes a still in the middle of a
  step (an alert before its button is pressed): `NN-step-<name>.png`, listed
  under the step's `snaps` in the manifest.
- Step field `"crop": [x, y, w, h]` (window points) is copied to the
  manifest; `extra_sheets.py OUT MANIFEST...` then makes `NN-step-crop.png`,
  that region of both after stills enlarged 2x, and the `snap` sheets.

Round 5 additions:
- Window field `"offset": [x, y]` places the session window from the
  session display's top left (`"position"` is in global coordinates).
- `"record": {"margin": PT}` now also applies to app-mode stills and snaps,
  not only to recordings: a sheet taller than its window (the reference's
  merge sheet) is captured whole. Leave room below the window with
  `offset`; the capture region is clipped to the display.
- An app's own Appearance setting is changed through its Settings window
  (the reference: the Appearance pane's thumbnails, AX descriptions
  `AppearanceLight` and `AppearanceAuto`) and set back to System in the
  same session; the reference's Settings window frame and last pane are
  restored with `defaults` afterwards, as in round 4.

Round 6 additions:
- Action `{"tree": "<name>", "depth": D}` writes the app's whole
  accessibility tree, as another process sees it, to
  `NN-step-<name>-tree.json`; the manifest's step `trees` lists the buttons
  found inside sheets and dialogs (`alert_buttons`), so a test can tell
  whether an alert's buttons are reachable from outside the app.
- An action with `"fallback": true` runs only when the action before it
  failed (Return after an AX press that found no button); the step records
  `fallback_used` when it ran.
- `council-r6*.json`: round 5's steps and ids; the conflict session presses
  both apps' alert Merge buttons through Accessibility and keeps Return
  only as the fallback.

`{app}` (the target's app name, "Xcode" or "Ycode") and `{project}` are
replaced in every string. After the setup actions the session picks the
frontmost window whose title contains `window.title`, raises it within its
app (without activating the app), sizes and places it; from then on
`wincap` selects it by window id and `axdrive` by position.

Each step records from `pre` seconds before its first action to `post`
seconds after its last, then takes the after still. Actions:

| Action | Fields | Background? |
|---|---|---|
| `open` | path inside the project copy; opened in the target app with `open -g` | yes |
| `press` | element match; `action` (default `AXPress`) | yes |
| `set` | element match, `attr` (`AXSelected`, `AXDisclosing`, `AXValue`...), `value` | yes |
| `select` | row match: selects that outline or table row through `AXSelectedRows` | yes |
| `scroll` | `{"at": [x, y]}` (window points) or a match; `dy`, `dx` (points, negative = down/right), `steps`, `interval`; `phases` (trackpad gesture phases), `momentum` and `momentum_tau` (a flick); `via` `ax` or `events` | background: `via: ax` (linear, no momentum); foreground: wheel events |
| `hover` | point or match | posted; effect not guaranteed in the background |
| `resize` | `[w, h]` of the test window | yes |
| `wait` | seconds | yes |
| `menu` | `"View > Navigators > Show Navigator"`; `A|B` accepts either title | foreground |
| `key` | `"cmd+shift+o"`; several chords separated by spaces | foreground |
| `text` | text to type | foreground |
| `click` | point or match; `button`, `count` | foreground |
| `drag` | `{"from": [x, y], "to": [x, y]}`, `duration` | foreground |

An element match is an object of AX attributes: `role`, `subrole`,
`title`, `description`, `identifier`, `value`, `help`, `label` (title,
description or value) or `text` (label of the element or of a descendant,
for outline rows); a key ending in `~` matches a substring; `index` picks
the nth match (breadth first). `axdrive tree --pid N --depth 8` shows what
can be matched.

What works where (checked against Ycode on macOS 27.2):
- An app that is not frontmost has no key or main window: AppKit drops
  posted keys, and menu items that act on a window are disabled. AX actions
  (press, set, select) and setting a scroll bar's value still work, so
  background scrolls are linear AX scrolls in `steps` steps, corrected
  against the document's measured position (no momentum or rubber-banding).
- Pointer and wheel events posted to a process are ignored even by the
  active app; keys posted to it work. In the foreground, axdrive therefore
  sends pointer and wheel events through the system's event stream
  (`--route tap`).
- Wheel events without phases move the content exactly by their deltas.
  With trackpad gesture phases the system scales them (about 1.1-1.2x at
  600 pt/s), so `phases` is off for linear drags and on for flicks, and
  each scroll reports its `measured_dy`.
- A flick is 8 gesture events, then momentum events whose velocity decays
  exponentially (time constant `momentum_tau`, 0.33 s). On a Mac the
  momentum events come from the system, not the app, so both apps get the
  same coasting input and the capture shows how each follows it.

## axdrive

```sh
A=research/tools/capture/axdrive/.build/debug/axdrive
$A check                      # Accessibility permission
$A displays                   # scale, refresh, and which show a full-screen app
$A tree --pid N --depth 8     # the AX tree, to write matches
$A press --pid N --match role=AXButton --match "description=Hide Inspector|Show Inspector"
$A scroll --ax --pid N --at 700,450 --dy -600 --steps 60                  # background
$A activate --pid N && $A scroll --route tap --pid N --at 700,450 --dy 320 --steps 8 --interval 0.008333 --momentum
```

Every result is one JSON object with `wall_start` (the moment the first
event or AX call was sent) and `wall`, used to align actions with frames.

Round 8 additions:
- `council-r8*.json`: round 7's scripts with the same steps, ids and order.
  `council-r8-conflict-narrow.json` step 02 (N02) now appends one compile
  error and one warning to the Merger copy's `Greeting.swift` (a `run`
  action) and builds with cmd+B before the Source Control view, so both
  apps have issues to show in the toolbar capsule.
- `council-r8-icons.json` (new): the project navigator with Swift, Python,
  JSON and Markdown rows, one still with each app's own Appearance set to
  Dark and one set to Light, then back to System. Its project comes from
  `make-icons-project.py`, which writes GlassScroll plus `convert.py`,
  `palette.json` and `NOTES.md` into `OUT_DIR/icons/GlassScroll`, a folder
  of its own, so the extra files never reach the plain GlassScroll copy.

Round 9 additions:
- `council-r9*.json`: round 8's scripts with the same sessions, steps, ids
  and order. The device session runs with its three simulators booted
  beforehand (`simctl boot`) and the host load back under 20.
- `council-r9-conflict-narrow-rerun.json`: the same script with step 02's
  build wait raised from 25 s to 60 s, for a reference whose build had not
  finished at 25 s.
- `council-r9-owner.json` (not scored): the icons copy of GlassScroll in
  dark and then light, with the navigator focused and unfocused, the
  pointer over the coding assistant button (`hover`, never clicked),
  NOTES.md open, and Open Quickly with "NOTES" typed (an app-mode `snap`).
- `council-r9-owner-json.json` (not scored): palette.json opened in dark
  and light (the JSON glyph in the navigator and the jump bar).
- `council-r9-device-watch.json` (not scored): an Apple Watch simulator
  (`ycode-test-council-watch`, booted beforehand) in both device windows:
  the sidebar with its row selected, then Zoom to Fit at both window sizes.
  The sidebar lists every simulator on the Mac: paint the other rows out of
  step 01's stills before they leave the dirty room.

Round 10 additions:
- `council-r10*.json`: round 9's sessions, steps, ids and order. Extra step
  15 scrolls the left pane 5000 pt (phase-less wheel events, exact deltas)
  before the workspace closes; reopen 01 takes snaps at its start, +2.5 s
  and +5 s; conflict-narrow 02 waits 60 s for the build with two snaps
  during it; the watch session adds Physical Size (04) and Zoom to Fit (05).
- `axdrive scroll` returns every event it posted as `events` (`t_s` from
  the first event, scroll phase, momentum phase, `dy`, `dx`) with
  `events_first_wall`, so a capture can quote its exact input.
- Do not record a step whose window does not change while taking snaps:
  the recorder delivers no first frame for a still window, and a still
  taken while a recording of the same window runs does not return.
