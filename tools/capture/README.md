# Capture tools (generic)

Tools for recording one app window and measuring how its UI moves. Nothing
here knows about a particular app: the dirty-room session driver
(`research/tools/capture/`) and the clean motion-diff harness (#32) both
use them. Needs macOS 15 or later for `wincap`; `motion.py` and `sheets.py`
need Python 3 with numpy and Pillow, and ffmpeg, and run on Linux too.

| Tool | What it does |
|---|---|
| `wincap/` | Swift command-line tool: stills (PNG) and videos of one window, or of one app's windows, through ScreenCaptureKit |
| `motion.py` | Timing from a video: per-frame difference, changed regions, start, end, duration, easing fit, plot |
| `sheets.py` | Comparison sheets from session manifests: stills side by side, frame strips, timing plots, an index page |

## wincap

```sh
swift build --package-path tools/capture/wincap
W=tools/capture/wincap/.build/debug/wincap
$W check                                   # Screen Recording permission, and who needs it
$W list --pid 1234                         # that app's windows (id, title, frame, z order)
$W still  --pid 1234 -o out.png            # frontmost normal window of PID 1234
$W record --bundle org.example.App --title Main -o out.mov --duration 3
```

- Selection: `--bundle ID` or `--pid N`, narrowed by `--window-id W` or
  `--title TEXT`. Default: the frontmost on-screen normal window of that app.
- `--mode window` (default) captures that window alone, with its sheets and
  child windows, even when other windows cover it. `--mode app` captures
  every window of that app (menus, popovers) inside the window's frame plus
  `--margin` points; other apps are not drawn.
- Scale: the window's backing scale (2 on a Retina display). A window on a
  1x display is captured at 1x; the scale is in every sidecar.
- Video: `--fps` caps the rate (default 60; 120 works on a 120 Hz display);
  `--codec prores4444` (default, 12-bit 4:4:4, visually lossless),
  `prores422hq`, `hevc` (quality 1.0) or `h264`. Only frames whose content
  changed are written, with their real times (variable frame rate), so a
  change's start and end are known to one display refresh. Stop with
  `--duration`, SIGINT or SIGTERM.
- Colour: `--colorspace srgb` (default) or `p3`. Stills are the colour
  reference; video goes through ProRes's YCbCr.
- Output: every file gets `FILE.json` next to it with the window, capture
  rect, pixel scale, display refresh rate and, for videos, each frame's
  time relative to the first frame and as wall-clock time. `record` prints
  JSON lines (`ready`, `first_frame`, `done`) on stdout.
- Exit 3: Screen Recording permission is missing. The JSON on stdout lists
  the process chain; the app that needs the permission is the `.app` that
  started the command (the terminal or agent host), granted in System
  Settings > Privacy & Security > Screen & System Audio Recording.

## Timing measurement (`motion.py`)

```sh
python3 -I tools/capture/motion.py clip.mov --start 0.4 --json t.json --plot t.png
```

Method (the docstring has the details):

1. Decode every frame with its presentation time (ffmpeg).
2. Compare each frame with the previous one: mean absolute difference
   (0-255), the fraction of pixels whose largest channel difference is above
   `--threshold` (2.5), and the bounding box of those pixels.
3. Frames with a changed fraction above `--min-fraction` are active; active
   frames less than `--gap` (0.12 s) apart form a segment; the segment with
   the most change is the primary change.
4. start = first active frame minus one frame interval; end = last active
   frame; duration = end - start.
5. Progress, 0 to 1: the projection of each frame onto the line from the
   frame before the change to its last frame (exact for cross-fades), or,
   when the change is a rigid move, the travel measured by phase correlation
   between consecutive frames (exact for slides and scrolls). The JSON says
   which (`progress_method`); `--pixels` or `--displacement` forces one.
6. Easing: least-squares fits of a cubic Bezier (x1, y1, x2, y2) and of a
   spring (response in seconds, damping fraction) to progress over time, and
   the error of the named curves (linear, ease, ease-in, ease-out,
   ease-in-out).

Use `--roi X,Y,W,H` (video pixels) to measure one element when other things
change at the same time (a blinking caret, say). Lengths in the output are
video pixels; divide by the sidecar's `pixel_scale` for points.

Checked on synthetic clips: a 300 ms ease-in-out slide at 60 fps measures
300 ms and Bezier (0.419, -0.005, 0.576, 0.993); a 250 ms linear fade at
120 fps measures 250 ms, best named curve linear.

## Session manifest

`sheets.py` reads one `manifest.json` per app, in the folder that holds its
captures:

```json
{
  "format": "capture-session/1", "session": "glass-scroll-edges", "target": "ycode",
  "label": "Ycode", "display": {"scale": 2, "refresh_hz": 120},
  "steps": [
    {"index": 2, "id": "editor-scroll-down", "note": "...",
     "still_before": "02-editor-scroll-down-before.png",
     "still_after": "02-editor-scroll-down-after.png",
     "video": "02-editor-scroll-down.mov",
     "t_action_in_video": 0.4878,
     "actions": [{"spec": {}, "result": {"ok": true, "wall_start": 1793814186.05}}]}
  ]
}
```

`t_action_in_video` is when the step's first action was sent, in seconds
from the video's first frame. Strips and timing are aligned on it.

## Sheets

```sh
python3 -I tools/capture/sheets.py OUT_DIR a/manifest.json b/manifest.json
```

For each step id: `NN-id-before.png` and `-after.png` (stills side by side
at the same pixel scale), `-strip.png` (frames every 33 ms from one frame
before the action, one line per manifest), `-detail.png` (the same, cropped
to the changed region), `-timing.json` and `-timing.png` (the measurements,
curves overlaid, each from its own detected start), and `index.html`.
