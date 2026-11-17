#!/usr/bin/env python3
"""Writes the parity run's part D session scripts (parity-d-*.json) next to
this file. Part D is the mop-up: the steps that parts A, B and C left invalid
or missing, and a few states nobody captured (pressed controls, editor-tab and
fold-ribbon hover, keyboard focus with the system's defaults).

    python3 -I research/tools/capture/scripts/parity-d-gen.py
"""
import json
import pathlib

HERE = pathlib.Path(__file__).resolve().parent
REC = {"fps": 120, "codec": "hevc", "pre": 0.5, "post": 1.2}
APP = {"mode": "app", "margin": 600}       # every window of the app on the built-in display
GLASS = {"generator": "make-test-project.py", "path": "GlassScroll/GlassScroll.xcodeproj"}
PARITY = {"generator": "make-parity-project.py", "path": "Parity/Parity.xcodeproj"}
MERGER = {"generator": "make-conflict-project.py", "path": "Merger/Merger.xcodeproj"}
FORMATS = {"generator": "make-formats-project.py", "path": "formats/Parity/Parity.xcodeproj"}
PANEL_DIR = "/private/tmp/ycode-parity-d/panel"
SCRIPTS = []


def script(name, title, steps, project=PARITY, setup=None, per_target_setup=None, window=None, **extra):
    s = {"name": name, "title": title, "targets": ["xcode", "ycode"], "compare_order": ["xcode", "ycode"],
         "focus": "foreground", "launch_settle": 3.0, "record": REC, "steps": steps}
    if project:
        s["project"] = project
        s["window"] = window or {"size": [1400, 880], "display": "builtin", "title": "{project}", "timeout": 90}
    else:
        s["project_targets"] = []
        s["window"] = window or {"size": None, "display": "builtin", "title": "Welcome to {app}", "timeout": 60}
    if setup:
        s["setup"] = setup
    if per_target_setup:
        s["per_target_setup"] = per_target_setup
    s.update(extra)
    SCRIPTS.append(s)
    return s


def step(sid, note, do=(), record=None, still="both", **extra):
    s = {"id": sid, "note": note, "do": list(do)}
    if record is not None:
        s["record"] = record
    s["still"] = still
    s.update(extra)
    return s


def vid(sid, note, do, post=1.0, **extra):
    """A recorded step (app mode, the whole built-in display); no snaps inside."""
    do = [a for a in do if "snap" not in a]
    return step(sid, note, do, record={**APP, "post": post}, **extra)


def shot(sid, note, do, **extra):
    """No video: an app-mode after still."""
    return step(sid, note, do, record={"video": False, "mode": "app", "margin": 600}, still="after", **extra)


def quiet(sid, note, do, **extra):
    return step(sid, note, do, record=False, still="none", **extra)


def tree(name):
    return {"tree": name, "depth": 40}


def tab_walk(sid, note, count, key="tab", trees=True):
    do = []
    for i in range(1, count + 1):
        do += [{"key": key}, {"wait": 0.4}, {"snap": f"k{i:02d}", "mode": "app"}]
        if trees:
            do.append(tree(f"k{i:02d}"))
    return step(sid, note, do, record=False, still="none")


def per(s, **targets):
    """Replace the step's actions per target."""
    s["per_target"] = {t: {"do": do} for t, do in targets.items()}
    return s


def tc(needle, occurrence=1, offset=0, **kw):
    """Click at (or with hover=True point at) a piece of visible editor text."""
    a = {"textclick": {"needle": needle, "occurrence": occurrence, "offset": offset}}
    for k in ("dx", "dy"):
        if k in kw:
            a["textclick"][k] = kw.pop(k)
    a.update(kw)
    return a


def hold(frm, to, secs=0.6):
    """Press and hold (the pressed state), then leave the control and release away from it."""
    return {"drag": {"from": frm, "to": to}, "hold": secs, "duration": 0.4}


MB = lambda title: {"role": "AXMenuBarItem", "title": title, "scope": "app"}
MI = lambda title: {"role": "AXMenuItem", "title": title, "scope": "app", "visible": True}
ROW = lambda name: {"role": "AXRow", "text": f"{name}|{name}.swift"}
TB = lambda d: {"role": "AXButton", "description": d}
CLOSE_MENUS = {"key": "escape escape escape"}
ESC_OR_CANCEL = [{"press": {"role": "AXButton", "title": "Cancel", "scope": "app"}}, {"key": "escape", "fallback": True}]

# ---------------------------------------------------------------- D1 menus the AX walk missed (no file open)
ym = [
    shot("rest", "GlassScroll open, no file in the editor. Menu bar.", [{"menubar": "rest"}]),
    vid("edit-open", "Click Edit in the menu bar (the first menu opened in this app's life).",
        [{"click": MB("Edit")}, {"wait": 1.0}, tree("edit")], post=0.6),
    vid("edit-format", "Point at Edit ▸ Format by its frame (hovering the parent opens the cascade).",
        [{"hoveritem": "Format"}, {"wait": 1.2}, tree("format")], post=0.6),
    vid("edit-format-font", "Move right onto Format ▸ Font (its own cascade).",
        [{"hoveritem": "Font"}, {"wait": 1.2}, tree("font")], post=0.6),
    vid("edit-format-text", "Move onto Format ▸ Text.", [{"hoveritem": "Text"}, {"wait": 1.2}, tree("text")], post=0.6),
    vid("edit-convert", "Back up to Edit ▸ Convert (sibling sub-menu of Format).",
        [{"hoveritem": "Convert"}, {"wait": 1.2}, tree("convert")], post=0.6),
    vid("edit-sort", "Edit ▸ Sort (if there).", [{"hoveritem": "Sort"}, {"wait": 1.2}], post=0.6),
    vid("edit-autofill", "Edit ▸ AutoFill.", [{"hoveritem": "AutoFill"}, {"wait": 1.2}], post=0.6),
    vid("edit-speech", "Edit ▸ Speech.", [{"hoveritem": "Speech"}, {"wait": 1.2}], post=0.6),
    quiet("edit-close", "Escape.", [CLOSE_MENUS, {"wait": 0.5}]),
    vid("editor-open", "Click Editor in the menu bar with no file open.", [{"click": MB("Editor")}, {"wait": 1.0},
                                                                         tree("editor")], post=0.6),
    step("editor-walk", "Every sub-menu parent of the open Editor menu hovered by its frame (frames read once, "
         "before any cascade opens): a still of each, and the open menu's items.", [{"submenus": "sub"}],
         record=False, still="none"),
    quiet("editor-close", "Escape.", [CLOSE_MENUS, {"wait": 0.5}]),
    vid("edit-open-2", "Edit again (a second time in this app's life).", [{"click": MB("Edit")}, {"wait": 1.0}],
        post=0.6),
    step("edit-walk", "Every sub-menu parent of the open Edit menu hovered by its frame: a still of each.",
         [{"submenus": "sub"}], record=False, still="none"),
    quiet("edit-close-2", "Escape.", [CLOSE_MENUS, {"wait": 0.5}]),
]
ymenus = script("parity-d-menus", "Part D 1: the Edit menu's sub-menus (Format ▸ Font / Text, Convert, …) and the "
                "Editor menu with no file, pointed at by their frames.", ym, project=GLASS)

# ---------------------------------------------------------------- D2 window behaviours
WIN = [
    shot("rest", "1400 × 880 at rest, the navigator and inspector both shown (View menu items used only if one "
         "is hidden). AX tree.", [{"menu": "View > Navigators > Show Navigator"}, {"wait": 0.5},
                                  {"menu": "View > Inspectors > Show Inspector"}, {"wait": 0.5}, tree("rest")]),
    vid("resize-700", "Set the window to 700 × 880 through Accessibility (Ycode's minimum width).",
        [{"resize": [700, 880]}, {"wait": 0.8}, tree("w700")], post=0.8),
    vid("drag-narrower", "Drag the right edge from 700 pt 200 pt to the left over 1.0 s (narrower than Ycode's "
        "minimum).", [{"drag": {"from": [699, 500], "to": [499, 500]}, "duration": 1.0}, {"wait": 0.5},
                      tree("narrow")], post=1.0),
    quiet("resize-700-again", "Back to 700 × 880, window moved to x 10 (room to widen).",
          [{"resize": [700, 880]}, {"wait": 0.5}, {"move": [10, 71]}, {"wait": 0.5}]),
    vid("drag-wider", "Drag the right edge from 700 pt to 1490 pt over 1.2 s (live layout, toolbar items coming "
        "back).", [{"drag": {"from": [699, 500], "to": [1489, 500]}, "duration": 1.2}, {"wait": 0.5}, tree("wide")],
        post=1.0),
    quiet("resize-back", "Back to 1400 × 880 at x 56.", [{"resize": [1400, 880]}, {"wait": 0.5}, {"move": [56, 71]},
                                                        {"wait": 0.5}]),
    shot("both-shown", "Navigator and inspector shown again (View menu items if needed). AX tree.",
         [{"menu": "View > Navigators > Show Navigator"}, {"wait": 0.5},
          {"menu": "View > Inspectors > Show Inspector"}, {"wait": 0.5}, tree("start")]),
    vid("cmd0", "cmd+0 from that layout (Xcode 27.1 binds it to View ▸ Navigators ▸ Show Coding Assistant). "
        "AX tree.", [{"key": "cmd+0"}, {"wait": 1.0}, tree("cmd0")], post=1.0),
    vid("cmd0-again", "cmd+0 again.", [{"key": "cmd+0"}, {"wait": 1.0}, tree("cmd0-again")], post=1.0),
    vid("hide-navigator-menu", "View ▸ Navigators ▸ Hide Navigator (menu).",
        [{"menu": "View > Navigators > Hide Navigator"}, {"wait": 1.0}], post=1.0),
    vid("show-navigator-menu", "View ▸ Navigators ▸ Show Navigator (menu).",
        [{"menu": "View > Navigators > Show Navigator"}, {"wait": 1.0}], post=1.0),
    vid("cmd-alt-0", "cmd+option+0: hide the inspector.", [{"key": "cmd+alt+0"}, {"wait": 1.0}, tree("inspector-off")],
        post=1.0),
    vid("cmd-alt-0-again", "cmd+option+0: show it again.", [{"key": "cmd+alt+0"}, {"wait": 1.0}], post=1.0),
    vid("new-tab", "cmd+T: a new tab (editor tab in both 27.1 layouts).", [{"key": "cmd+t"}, {"wait": 1.2}, tree("tab")],
        post=1.0),
    vid("tab-hover", "Pointer along the tab bar by coordinate (window y 65; x 200, 450, 700, 950, 1.3 s each): "
        "tab hover, close buttons, tooltips.",
        [{"hover": [200, 65]}, {"wait": 1.3}, {"hover": [450, 65]}, {"wait": 1.3}, {"hover": [700, 65]},
         {"wait": 1.3}, {"hover": [950, 65]}, {"wait": 1.6}], post=0.5),
    shot("tab-hover-still", "Still with the pointer on the last tab position (x 950).", [{"hover": [950, 65]},
                                                                                       {"wait": 1.0}]),
    vid("close-tab", "cmd+W closes the new tab.", [{"hover": [700, 500]}, {"key": "cmd+w"}, {"wait": 0.8}], post=1.0),
    vid("new-window", "File ▸ New ▸ Window (menu; disabled in Ycode in part A). AX tree.",
        [{"menu": "File > New > Window"}, {"wait": 1.5}, tree("new-window")], post=1.0),
    per(quiet("close-new-window", "Xcode: cmd+W closes that window (Ycode: nothing to close).",
              [{"key": "cmd+w"}, {"wait": 0.8}]), ycode=[{"wait": 0.3}]),
    vid("welcome", "A second window by another route in both apps: Window ▸ Welcome to {app} (shift+cmd+1).",
        [{"menu": "Window > Welcome to {app}"}, {"wait": 1.5}, tree("welcome")], post=1.0),
    shot("welcome-where", "Where the Welcome window went (both windows in the tree).", [tree("where")]),
    vid("refocus", "Click the workspace window's navigator area (window point 150, 700) to make it key again.",
        [{"click": [150, 700]}, {"wait": 0.8}], post=0.6),
    vid("window-menu", "Click Window in the menu bar: the window list with two windows.",
        [{"click": MB("Window")}, {"wait": 0.8}, tree("window-menu")], post=0.6),
    quiet("window-menu-close", "Escape.", [CLOSE_MENUS, {"wait": 0.4}]),
    vid("zoom", "Window ▸ Zoom (the workspace fills the display; animation).", [{"menu": "Window > Zoom"},
                                                                               {"wait": 1.0}], post=1.0),
    vid("zoom-back", "Window ▸ Zoom again (back).", [{"menu": "Window > Zoom"}, {"wait": 1.0}], post=1.0),
]
window = script("parity-d-window", "Part D 2: resize from 700 pt narrower and wider, cmd+0 / cmd+option+0 from the "
                "same layout, the tab bar hovered by coordinate, a second window, the Window menu and Zoom.", WIN,
                project=GLASS)

# ---------------------------------------------------------------- D3 toolbar: scheme and destination choosers, Library
SCHEME = {"label": "Active Scheme", "role": "AXPopUpButton"}
DEST = {"label": "Active Run Destination", "role": "AXPopUpButton"}
PROW = lambda text: {"role": "AXRow", "subrole": "AXTableRow", "text": text, "scope": "app", "visible": True}
tb = [
    shot("rest", "GlassScroll open, Long.swift not open. AX tree.", [tree("rest")]),
    vid("scheme-open", "Click the scheme pop-up (Xcode: a popover; Ycode: a menu). AX tree.",
        [{"click": SCHEME}, {"wait": 1.0}, tree("scheme")], post=0.6),
]
for k, text in enumerate(["GlassScroll", "Edit Scheme…", "New Scheme…", "Manage Schemes…"]):
    s = vid(f"scheme-hover-{k}", f"Pointer onto the chooser's '{text}' row, 1.2 s (hover highlight).",
            [{"hover": PROW(text)}, {"wait": 1.2}], post=0.4)
    s["per_target"] = {"ycode": {"do": [{"hoveritem": text}, {"wait": 1.2}]}}
    tb.append(s)
tb += [
    vid("scheme-keys", "Down, Down, Up in the chooser (keyboard selection).",
        [{"key": "down"}, {"wait": 0.5}, {"key": "down"}, {"wait": 0.5}, {"key": "up"}, {"wait": 0.6}], post=0.5),
    vid("scheme-escape", "Escape closes it.", [{"key": "escape"}, {"wait": 0.6}], post=0.8),
]
for k, (text, sheet_close) in enumerate([("GlassScroll", None), ("Edit Scheme…", "Close"),
                                         ("New Scheme…", "Cancel"), ("Manage Schemes…", "Close")]):
    s = vid(f"scheme-click-{k}", f"Open the chooser, click '{text}' (what it does; a sheet is closed in the next "
            "step). AX tree.", [{"click": SCHEME}, {"wait": 1.0}, {"click": PROW(text)}, {"wait": 1.5},
                                tree(f"click-{k}")], post=1.0)
    s["per_target"] = {"ycode": {"do": [{"click": SCHEME}, {"wait": 1.0}, {"menuclick": text},
                                        {"key": "escape", "fallback": True}, {"wait": 1.5}, tree(f"click-{k}")]}}
    tb.append(s)
    if sheet_close:
        tb.append(vid(f"scheme-click-{k}-close", f"{sheet_close} (button), else Escape.",
                      [{"press": {"role": "AXButton", "title": f"{sheet_close}|Done|OK|Cancel", "scope": "app"}},
                       {"key": "escape", "fallback": True}, {"wait": 1.0}], post=0.8))
tb += [
    vid("destination-open", "Click the destination pop-up. AX tree.", [{"click": DEST}, {"wait": 1.0},
                                                                     tree("destination")], post=0.6),
    per(vid("destination-incompatible", "Pointer onto 'Incompatible' (its cascade; the owner's devices in it are "
            "painted out). AX tree.", [{"hover": PROW("Incompatible")}, {"wait": 1.5}, tree("incompatible")],
            post=0.6), ycode=[{"hoveritem": "Incompatible"}, {"wait": 1.5}, tree("incompatible")]),
    vid("destination-build", "Pointer onto the 'Build' / Any Mac row (sibling: does the cascade close?).",
        [{"hover": PROW("Any Mac (arm64, x86_64)")}, {"wait": 1.2}], post=0.5,
        per_target={"ycode": {"do": [{"hoveritem": "Any Mac"}, {"wait": 1.2}]}}),
    vid("destination-escape", "Escape.", [CLOSE_MENUS, {"wait": 0.6}], post=0.6),
    vid("library-open", "View ▸ Show Library (shift+cmd+L). AX tree.", [{"key": "cmd+shift+l"}, {"wait": 1.5},
                                                                       tree("library")], post=0.8),
    vid("library-click-outside", "Click outside the Library (window point 150, 800: the navigator's empty area): "
        "does it close?", [{"click": [150, 800]}, {"wait": 1.2}, tree("after-outside")], post=1.0),
    quiet("library-escape", "Escape (in case it stayed).", [{"key": "escape"}, {"wait": 0.5}]),
    # Xcode 27.1's destination popover does not open the Incompatible cascade on hover (first run): click it,
    # then the keyboard route (Right arrow on the row).
    vid("destination-open-2", "Destination chooser again.", [{"click": DEST}, {"wait": 1.0}], post=0.5),
    per(vid("incompatible-click", "Click 'Incompatible': its cascade (painted where it lists the owner's devices). "
            "AX tree.", [{"click": PROW("Incompatible")}, {"wait": 1.5}, tree("incompatible-click")], post=0.8),
        ycode=[{"hoveritem": "Incompatible"}, {"wait": 0.3}, {"click": MI("Incompatible")}, {"wait": 1.5},
               tree("incompatible-click")]),
    quiet("incompatible-click-close", "Escape.", [CLOSE_MENUS, {"wait": 0.6}]),
    vid("destination-open-3", "Destination chooser again; Down until Incompatible is selected, then Right.",
        [{"click": DEST}, {"wait": 1.0}, {"key": "down"}, {"wait": 0.3}, {"key": "down"}, {"wait": 0.3},
         {"key": "down"}, {"wait": 0.3}, {"key": "right"}, {"wait": 1.5}, tree("keys")], post=0.8),
    quiet("destination-close-3", "Escape.", [CLOSE_MENUS, {"wait": 0.6}]),
]
toolbar = script("parity-d-toolbar", "Part D 3: the scheme chooser's rows (hover, keys, each clicked), the "
                 "destination chooser's Incompatible cascade, closing the Library by clicking outside it.", tb,
                 project=GLASS)

# ---------------------------------------------------------------- D4 New Project with an organization identifier
TAB_MACOS = [{"click": {"role": "AXRadioButton", "label": "macOS", "scope": "app", "visible": True}},
             {"click": {"label": "macOS", "scope": "app", "visible": True}, "fallback": True}, {"wait": 0.8}]
NEXT = {"press": {"role": "AXButton", "title": "Next", "scope": "app"}}
NEWMENU = {"label": "New Project", "role": "AXMenuButton", "scope": "app"}
np = [
    shot("welcome", "The Welcome window (centred on the built-in display by the session). AX tree.",
         [tree("welcome")]),
    per(vid("chooser-appears", "Open the template chooser (Xcode: shift+cmd+N, then Choose Template…; Ycode: the "
            "Welcome window's New Project menu ▸ Choose Template…). Recorded where it appears; nothing moved. AX "
            "tree (window frames).", []),
        xcode=[{"key": "cmd+shift+n"}, {"wait": 2.0}, {"click": {"role": "AXRow", "text": "Choose Template…",
                                                                  "scope": "app"}}, {"wait": 2.5}, tree("chooser")],
        ycode=[{"click": NEWMENU}, {"wait": 1.0}, {"click": MI("Choose Template…")}, {"wait": 2.5},
               tree("chooser")]),
    quiet("chooser-move", "If the chooser is not on the built-in display, move it there (56, 57) for the next steps.",
          [{"move": [56, 57], "window": "Untitled"}, {"wait": 1.0}]),
    vid("macos-app", "macOS tab; App is selected by default. Next: the options page.",
        TAB_MACOS + [{"wait": 0.5}, NEXT, {"wait": 1.5}, tree("options")], post=1.0),
    vid("product-name", "Click Product Name, type 'ParityApp'.",
        [{"click": {"identifier": "productName", "scope": "app"}}, {"key": "cmd+a"}, {"text": "ParityApp"},
         {"wait": 0.6}], post=0.8),
    vid("organization", "Click Organization Identifier, select all, type 'org.example.parity' (the bundle "
        "identifier follows; Next becomes enabled). AX tree.",
        [{"click": {"identifier": "bundleIdentifierPrefix", "scope": "app"}}, {"key": "cmd+a"},
         {"text": "org.example.parity"}, {"wait": 0.8}, tree("typed")], post=0.8),
    per(vid("save-sheet", "Next: the save sheet (animation; its sidebar and file list are painted out). AX tree. "
            "(Ycode: a pointer click on Next; its AX press did nothing in the first run.)",
            [NEXT, {"wait": 2.0}, tree("save")], post=1.0),
        ycode=[{"click": {"role": "AXButton", "title": "Next", "scope": "app"}}, {"wait": 2.5}, tree("save"),
               {"key": "tab"}, {"wait": 0.5}, {"click": {"role": "AXButton", "title": "Next", "scope": "app"}},
               {"wait": 2.5}, tree("save-after-tab"), {"key": "return"}, {"wait": 2.5}, tree("save-after-return")]),
    tab_walk("save-tab-order", "Tab through the save sheet (key-view order).", 6),
    vid("save-options", "The save sheet's options (Source Control checkbox, Add to, Group) if it has them: AX "
        "tree only; then Escape/Cancel.", ESC_OR_CANCEL + [{"wait": 1.0}, tree("after-save")], post=1.0),
    vid("assistant-cancel", "Cancel the assistant.", ESC_OR_CANCEL + [{"wait": 1.0}], post=1.0),
    shot("after-cancel", "What is left. AX tree.", [tree("after")]),
]
newproject = script("parity-d-newproject", "Part D 4: the New Project assistant with an organization identifier "
                    "typed in, through to its save sheet (cancelled); where the template chooser appears.", np,
                    project=None,
                    per_target_setup={"ycode": [{"run": ["defaults", "write", "io.github.MarcoDotIO.Ycode.capture",
                                                         "NSNavLastRootDirectory", PANEL_DIR]}]})

# ---------------------------------------------------------------- D5 project editor (Ycode's invalid part B steps)
TAB = lambda t: {"role": "AXButton|AXRadioButton", "label": t, "visible": True}
TARGET_ROW = {"role": "AXRow", "text": "Parity", "scope": "window", "index": 3}
pe = [
    vid("open-project", "Click the project row (Parity, first navigator row): the project editor, target Parity. "
        "AX tree.", [{"click": {"role": "AXRow", "text": "Parity", "index": 0}}, {"wait": 2.5}, tree("project")]),
    vid("tab-build-settings", "Click Build Settings (in part B Ycode widened its window to 1530 pt here). AX tree.",
        [{"click": TAB("Build Settings")}, {"wait": 1.5}, tree("bs")]),
    quiet("resize-back-1", "Window back to 1400 × 880 at x 56.", [{"resize": [1400, 880]}, {"move": [56, 71]},
                                                                  {"wait": 0.6}]),
    vid("tab-build-phases", "Click Build Phases. AX tree.", [{"resize": [1400, 880]}, {"click": TAB("Build Phases")},
                                                            {"wait": 1.5}, tree("phases")]),
    vid("phases-disclose", "Expand Compile Sources (its disclosure: AX match, else the row's label).",
        [{"click": {"role": "AXDisclosureTriangle", "visible": True, "index": 1}},
         {"click": {"label~": "Compile Sources", "visible": True}, "fallback": True}, {"wait": 1.0},
         tree("phases-open")]),
    vid("phases-collapse", "Click the same disclosure again (collapse).",
        [{"click": {"role": "AXDisclosureTriangle", "visible": True, "index": 1}},
         {"click": {"label~": "Compile Sources", "visible": True}, "fallback": True}, {"wait": 1.0}]),
    vid("phases-add-menu", "The '+' above the phases: its menu. AX tree. (Ycode: its '+' pop-up by coordinate, "
        "window point 510, 171; the AX match found nothing in the first run.)",
        [{"click": {"role": "AXButton|AXMenuButton", "label": "add|Add|New Build Phase", "visible": True}},
         {"wait": 0.8}, tree("phases-add")], post=0.8,
        per_target={"ycode": {"do": [{"click": [510, 171]}, {"wait": 0.8}, tree("phases-add")]}}),
    quiet("phases-add-close", "Escape.", [CLOSE_MENUS, {"wait": 0.4}]),
    vid("tab-build-rules", "Click Build Rules. AX tree.", [{"resize": [1400, 880]}, {"click": TAB("Build Rules")},
                                                          {"wait": 1.5}, tree("rules")]),
    vid("project-item", "Select the PROJECT entry (Parity under Project) in the editor's list. AX tree.",
        [{"resize": [1400, 880]}, {"click": {"role": "AXRow", "text": "Parity", "scope": "window", "index": 2}},
         {"wait": 2.0}, tree("project-item")]),
    vid("project-info-tab", "Click Info (project level). AX tree.", [{"click": TAB("Info")}, {"wait": 1.5},
                                                                    tree("project-info")]),
    vid("package-deps", "Click Package Dependencies (nothing added). AX tree.",
        [{"resize": [1400, 880]}, {"click": TAB("Package Dependencies")}, {"wait": 1.5}, tree("packages")]),
    vid("test-target", "Select the ParityTests target, then General. AX tree.",
        [{"resize": [1400, 880]}, {"click": {"role": "AXRow", "text": "ParityTests", "scope": "window", "visible": True}},
         {"wait": 1.5}, {"click": TAB("General")}, {"wait": 1.5}, tree("tests")],
        per_target={"ycode": {"do": [{"resize": [1400, 880]}, {"click": [294, 209]}, {"wait": 1.5},
                                     {"click": TAB("General")}, {"wait": 1.5}, tree("tests")]}}),
    vid("hide-list", "Hide the project and targets list (button at the editor's top left).",
        [{"resize": [1400, 880]}, {"click": {"role": "AXButton", "description~": "project and targets list"}},
         {"wait": 1.0}, tree("list-hidden")]),
    vid("show-list", "Show it again.", [{"click": {"role": "AXButton", "description~": "project and targets list"}},
                                        {"wait": 1.0}]),
    vid("target-context", "Right-click the Parity target row in the list: its context menu. AX tree.",
        [{"click": TARGET_ROW, "button": "right"}, {"wait": 0.9}, tree("target-context")], post=0.8,
        per_target={"ycode": {"do": [{"click": [294, 187], "button": "right"}, {"wait": 0.9},
                                     tree("target-context")]}}),
    step("target-context-items", "Its items (and sub-menus) as stills.", [{"submenus": "items", "all_windows": True}],
         record=False, still="none"),
    quiet("target-context-close", "Escape.", [CLOSE_MENUS, {"wait": 0.4}]),
    tab_walk("tab-order", "Tab through the project editor (key-view order).", 6),
]
# Xcode coordinates (window points) from the first run, where its AX matches missed or hit the navigator:
# Compile Sources' disclosure, the phases '+', ParityTests in the targets list, the list's hide/show button.
XCODE_PE = {
    "phases-disclose": [{"click": [484, 249]}, {"wait": 1.0}, tree("phases-open")],
    "phases-collapse": [{"click": [484, 249]}, {"wait": 1.0}],
    "phases-add-menu": [{"click": [468, 137]}, {"wait": 0.8}, tree("phases-add")],
    "test-target": [{"click": [354, 271]}, {"wait": 1.5}, {"click": TAB("General")}, {"wait": 1.5}, tree("tests")],
    "hide-list": [{"click": [302, 103]}, {"wait": 1.0}, tree("list-hidden")],
    "show-list": [{"click": [302, 103]}, {"wait": 1.0}],
}
for st in pe:
    if st["id"] in XCODE_PE:
        st.setdefault("per_target", {})["xcode"] = {"do": XCODE_PE[st["id"]]}
project = script("parity-d-project", "Part D 5: the project editor: Build Settings width, Build Phases with a "
                 "disclosure and its + menu, Build Rules, the project's Info and Package Dependencies, ParityTests, "
                 "the targets list hidden and shown, the target context menu.", pe,
                 setup=[{"select": ROW("Shapes")}, {"wait": 2.0}])

# ---------------------------------------------------------------- D6 editor: shortcuts, Quick Help warm, tabs, ribbon,
# counterparts, breakpoint popover, scheme arguments
NAVS = [("cmd+5", "cmd+1"), ("cmd+6", "cmd+1"), ("cmd+7", "cmd+1"), ("cmd+1", "cmd+3")]
ed = []
for key, before in NAVS:
    k = key.replace("+", "")
    ed += [quiet(f"pre-{k}", f"{before} first (another navigator), so {key} switches rather than toggles.",
                 [{"key": before}, {"wait": 1.0}]),
           vid(f"switch-{k}", f"{key}: the navigator switch. AX tree.", [{"key": key}, {"wait": 1.0}, tree(k)])]
for key, before in [("cmd+alt+1", "cmd+alt+2"), ("cmd+alt+2", "cmd+alt+1"), ("cmd+alt+3", "cmd+alt+1")]:
    k = key.replace("+", "")
    ed += [quiet(f"pre-{k}", f"{before} first.", [{"key": before}, {"wait": 1.0}]),
           vid(f"switch-{k}", f"{key}: the inspector switch. AX tree.", [{"key": key}, {"wait": 1.0}, tree(k)])]
ed += [
    quiet("nav-project", "cmd+2 then cmd+1 (the Project navigator shown, not toggled away), cmd+alt+1.",
          [{"key": "cmd+2"}, {"wait": 0.6}, {"key": "cmd+1"}, {"wait": 0.6}, {"key": "cmd+alt+1"}, {"wait": 0.6}]),
    vid("qh-own-1", "option+click 'scaled' in 'circle.scaled(by: 2)': Quick Help (first lookup).",
        [tc("scaled(by: 2)", offset=2, modifiers="alt"), {"wait": 2.5}, tree("qh1")]),
    quiet("qh-own-1-close", "Escape.", [{"key": "escape"}, {"wait": 0.8}]),
    vid("qh-own-2", "The same option+click again (warm lookup).", [tc("scaled(by: 2)", offset=2, modifiers="alt"),
                                                                    {"wait": 2.0}]),
    quiet("qh-own-2-close", "Escape.", [{"key": "escape"}, {"wait": 0.8}]),
    vid("qh-sdk-1", "option+click 'reduce' (standard library; first lookup).",
        [tc("reduce(", offset=2, modifiers="alt"), {"wait": 2.5}, tree("qh-sdk")]),
    quiet("qh-sdk-1-close", "Escape.", [{"key": "escape"}, {"wait": 0.8}]),
    vid("qh-sdk-2", "option+click 'reduce' again (warm).", [tc("reduce(", offset=2, modifiers="alt"), {"wait": 2.0}]),
    quiet("qh-sdk-2-close", "Escape.", [{"key": "escape"}, {"wait": 0.8}]),
    vid("ribbon-hover-1", "Pointer onto the gutter just left of 'struct Circle' (code folding ribbon), 2 s.",
        [tc("struct Circle", dx=-10, hover=True), {"wait": 2.0}], post=0.6),
    vid("ribbon-hover-2", "Then 4 pt further left, 1.5 s.", [tc("struct Circle", dx=-14, hover=True), {"wait": 1.5}],
        post=0.6),
    vid("ribbon-hover-3", "Then onto the ribbon beside the struct's body (two lines lower), 1.5 s.",
        [tc("struct Circle", dx=-10, dy=36, hover=True), {"wait": 1.5}], post=0.6),
    vid("ribbon-off", "Pointer back into the text.", [tc("struct Circle", offset=3, hover=True), {"wait": 1.0}],
        post=0.6),
    vid("tab-open-1", "Select Counter, File ▸ Open in New Tab.", [{"click": ROW("Counter")}, {"wait": 0.8},
                                                                  {"menu": "File > Open in New Tab"}, {"wait": 1.0}]),
    vid("tab-open-2", "Select Showcase, Open in New Tab.", [{"click": ROW("Showcase")}, {"wait": 0.8},
                                                            {"menu": "File > Open in New Tab"}, {"wait": 1.0},
                                                            tree("tabs")]),
    vid("tab-hover-coords", "Pointer along the editor tab bar by coordinate (window y 65; x 440, 600, 725, 860, "
        "1000, 1.3 s each): hover, close buttons, tooltips.",
        [{"hover": [440, 65]}, {"wait": 1.3}, {"hover": [600, 65]}, {"wait": 1.3}, {"hover": [725, 65]},
         {"wait": 1.3}, {"hover": [860, 65]}, {"wait": 1.3}, {"hover": [1000, 65]}, {"wait": 1.6}], post=0.5),
    shot("tab-hover-first", "Still: pointer on the first tab (x 440), 1.5 s.", [{"hover": [440, 65]}, {"wait": 1.5}]),
    shot("tab-hover-last", "Still: pointer on the last tab (x 1000), 1.5 s.", [{"hover": [1000, 65]}, {"wait": 1.5}]),
    vid("tab-close-hover", "Pointer onto the first tab's left end (x 365, its close button), 1.2 s.",
        [{"hover": [365, 65]}, {"wait": 1.2}], post=0.5),
    quiet("tabs-close", "Pointer away; cmd+W twice (the two new tabs).", [{"hover": [700, 500]}, {"key": "cmd+w"},
                                                                         {"wait": 0.6}, {"key": "cmd+w"}, {"wait": 0.6}]),
    quiet("open-counter", "Open Counter.swift.", [{"click": ROW("Counter")}, {"wait": 1.5}]),
    vid("breakpoint-add", "Caret on 'let message', cmd+\\: a breakpoint arrow.",
        [tc("let message", offset=4), {"wait": 0.3}, {"key": "cmd+\\"}, {"wait": 0.8}]),
    vid("breakpoint-double-click", "Double-click the breakpoint arrow in the gutter (left of the line): the edit "
        "popover (animation). AX tree. (90 pt left of the text: the line-number badge.)", [tc("let message", dx=-90, count=2), {"wait": 1.5}, tree("bp-popover")],
        post=1.0),
    tab_walk("breakpoint-popover-tabs", "Tab through whatever opened (key-view order).", 4),
    vid("breakpoint-popover-close", "Escape.", [{"key": "escape"}, {"wait": 0.8}], post=0.8),
    vid("breakpoint-remove", "cmd+\\ on the line again (no breakpoint left).",
        [tc("let message", offset=4), {"key": "cmd+\\"}, {"wait": 0.8}]),
    vid("assistant", "Editor ▸ Assistant (control+option+cmd+Return).", [{"key": "ctrl+alt+cmd+return"}, {"wait": 2.0},
                                                                        tree("assistant")]),
    vid("assistant-mode-menu", "The assistant pane's jump bar first segment (window point 1000, 66): its menu.",
        [{"click": [1000, 66]}, {"wait": 1.0}, tree("assistant-menu")], post=0.6,
        per_target={"xcode": {"do": [{"click": [940, 65]}, {"wait": 1.0}, tree("assistant-menu")]},
                    "ycode": {"do": [{"click": [760, 65]}, {"wait": 1.0}, tree("assistant-menu")]}}),
    vid("assistant-counterparts", "Point at 'Counterparts' in that menu (its cascade).",
        [{"hoveritem": "Counterparts"}, {"wait": 1.2}, tree("counterparts")], post=0.6),
    quiet("assistant-menu-close", "Escape.", [CLOSE_MENUS, {"wait": 0.4}]),
    vid("navigate-menu", "Click Navigate in the menu bar.", [{"click": MB("Navigate")}, {"wait": 1.0}], post=0.6),
    vid("navigate-counterpart", "Point at Navigate ▸ Jump to Next Counterpart (highlight; enabled state in the tree).",
        [{"hoveritem": "Jump to Next Counterpart"}, {"wait": 1.2}, tree("navigate")], post=0.6),
    quiet("navigate-close", "Escape.", [CLOSE_MENUS, {"wait": 0.4}]),
    vid("next-counterpart", "control+cmd+Up (Jump to Next Counterpart).", [{"key": "ctrl+cmd+up"}, {"wait": 1.2}]),
    vid("assistant-off", "cmd+Return (standard editor).", [{"key": "cmd+return"}, {"wait": 1.5}]),
    vid("scheme-editor", "Product ▸ Scheme ▸ Edit Scheme…, Run ▸ Arguments.",
        [{"menu": "Product > Scheme > Edit Scheme…"}, {"wait": 2.0},
         {"click": {"role": "AXRow", "text": "Run", "scope": "app", "visible": True}}, {"wait": 0.8},
         {"click": {"role": "AXRadioButton|AXButton", "label": "Arguments", "scope": "app", "visible": True}},
         {"wait": 1.0}, tree("arguments")]),
    per(vid("arguments-add", "The '+' under Arguments Passed On Launch (Xcode: help 'Add items', the first one): "
            "a new editable row. AX tree.", []),
        xcode=[{"click": {"role": "AXButton", "description": "add", "help": "Add items", "scope": "app",
                          "visible": True}}, {"wait": 1.0}, tree("row")],
        ycode=[{"click": {"role": "AXButton", "description": "Add", "scope": "app", "visible": True}},
               {"wait": 1.0}, tree("row")]),
    vid("arguments-type", "Type '-ParityFlag YES'.", [{"text": "-ParityFlag YES"}, {"wait": 0.8}, tree("typed")]),
    vid("arguments-cancel", "Escape (end editing), then Escape again (the sheet).",
        [{"key": "escape"}, {"wait": 0.6}, {"key": "escape"}, {"wait": 1.0}, tree("after")], post=1.0),
    quiet("scheme-close", "Close the sheet if it is still there.",
          [{"press": {"role": "AXButton", "title": "Close|Done", "scope": "app"}}, {"wait": 0.8}]),
]
editor = script("parity-d-editor", "Part D 6: navigator and inspector shortcuts after another one, Quick Help twice "
                "(warm), the folding ribbon and editor tabs hovered by coordinate, the breakpoint popover by "
                "double-click, the assistant's Counterparts, the scheme's argument row.", ed,
                setup=[{"select": ROW("Shapes")}, {"wait": 2.5}])

# ---------------------------------------------------------------- D7 build log step expansion
BROKEN = {"run": ["cp", ".parity/issues-broken.txt", "Parity/Issues.swift"]}
CLEAN = {"run": ["cp", ".parity/issues-clean.txt", "Parity/Issues.swift"]}
bl = [
    quiet("break-file", "The file is replaced on disk with the broken version (a warning and an error).",
          [BROKEN, {"wait": 3.0}]),
    vid("build", "cmd+B; 30 s.", [{"key": "cmd+b"}, {"wait": 30.0}], post=0.5),
    vid("report-navigator", "cmd+9: the Report navigator.", [{"key": "cmd+9"}, {"wait": 1.5}, tree("reports")]),
    vid("report-open", "Click the build row (the only one). AX tree.",
        [{"click": {"role": "AXRow", "text~": "Build", "index": 0}}, {"wait": 2.5}, tree("log")]),
    vid("log-all-messages", "Click 'All Messages' in the log's filter bar (window point 456, 98). AX tree.",
        [{"click": [456, 98]}, {"wait": 1.5}, tree("all-messages")]),
    vid("log-step-disclosure", "Click the disclosure of the 'Compiling Issues.swift' step by coordinate "
        "(window point 321, 166): collapse.", [{"click": [321, 166]}, {"wait": 1.2}, tree("collapsed")]),
    vid("log-step-disclosure-2", "Click it again: expand.", [{"click": [321, 166]}, {"wait": 1.2}]),
    vid("log-transcript", "Click the step's transcript button at the right (window point 1095, 166): the build "
        "command transcript. AX tree.", [{"click": [1095, 166]}, {"wait": 1.5}, tree("transcript")]),
    vid("log-transcript-close", "Click it again.", [{"click": [1095, 166]}, {"wait": 1.2}]),
    vid("log-all-issues", "Click 'All Issues' (window point 535, 98).", [{"click": [535, 98]}, {"wait": 1.2}]),
    quiet("clean", "The clean file back.", [CLEAN, {"wait": 1.0}]),
]
buildlog = script("parity-d-buildlog", "Part D 7: the failed build's log: filter, a step collapsed and expanded "
                  "by coordinate, its transcript.", bl, setup=[{"select": ROW("Issues")}, {"wait": 2.5}])

# ---------------------------------------------------------------- D8 source control: the current branch's context menu
sc = [
    vid("scm-navigator", "cmd+2: Source Control navigator, Repositories, Merger and Branches expanded. AX tree.",
        [{"key": "cmd+2"}, {"wait": 1.5}, {"press": {"role": "AXRadioButton", "label": "Repositories"}}, {"wait": 1.0},
         {"set": {"role": "AXRow", "text": "project|Merger"}, "attr": "AXDisclosing", "value": True}, {"wait": 0.6},
         {"set": {"role": "AXRow", "text": "Branches"}, "attr": "AXDisclosing", "value": True}, {"wait": 0.8},
         tree("repos")]),
    vid("main-context", "Right-click the current branch's row 'main' by coordinate (window point 150, 193). AX tree.",
        [{"click": [150, 193], "button": "right"}, {"wait": 1.0}, tree("main-menu")], post=0.8),
    step("main-context-items", "Its items and sub-menus as stills.", [{"submenus": "items", "all_windows": True}],
         record=False, still="none"),
    quiet("main-context-close", "Escape.", [CLOSE_MENUS, {"wait": 0.4}]),
    vid("feature-context", "Right-click 'feature' (window point 150, 171) for comparison.",
        [{"click": [150, 171], "button": "right"}, {"wait": 1.0}, tree("feature-menu")], post=0.8),
    quiet("feature-context-close", "Escape.", [CLOSE_MENUS, {"wait": 0.4}]),
]
scm = script("parity-d-scm", "Part D 8: the current branch's context menu in the Source Control navigator, by "
             "coordinate.", sc, project=MERGER)

# ---------------------------------------------------------------- D9 Light: Quick Help popover; Interface Builder drag;
# canvas controls
APPEAR = {"xcode": {"Light": {"role": "AXButton", "description": "AppearanceLight", "scope": "app"},
                    "System": {"role": "AXButton", "description": "AppearanceAuto", "scope": "app"}},
          "ycode": {"Light": {"title": "Light", "scope": "app"}, "System": {"title": "System", "scope": "app"}}}
SETTINGS_AT = [401, 40]


def appearance(sid, note, which, kind=vid):
    s = kind(sid, note, [])
    s["per_target"] = {t: {"do": [{"key": "cmd+,"}, {"wait": 2.0},
                                  {"select": {"role": "AXRow", "text": "Appearance", "scope": "app"}}, {"wait": 1.5},
                                  {"move": SETTINGS_AT, "window": "Appearance"}, {"wait": 0.4},
                                  {"press": APPEAR[t][which]}, {"wait": 2.0}, tree("appearance")]}
                       for t in ("xcode", "ycode")}
    return s


li = [
    appearance("appearance-light", "Settings ▸ Appearance: the app's own Appearance set to Light.", "Light"),
    quiet("settings-close", "cmd+W.", [{"key": "cmd+w"}, {"wait": 1.0}]),
    quiet("open-shapes", "Click Shapes in the navigator; caret into the editor.", [{"click": ROW("Shapes")},
                                                                                 {"wait": 2.5}]),
    shot("shapes-light", "Shapes.swift in light. AX tree.", [tree("shapes")]),
    vid("popover-light", "option+click 'Circle' in 'struct Circle': the Quick Help popover in light. AX tree.",
        [tc("struct Circle", offset=9, modifiers="alt"), {"wait": 2.5}, tree("popover")]),
    quiet("popover-light-close", "Escape.", [{"key": "escape"}, {"wait": 0.8}]),
    vid("popover-light-2", "option+click 'scaled' in 'circle.scaled(by: 2)' (a second lookup, light).",
        [tc("scaled(by: 2)", offset=2, modifiers="alt"), {"wait": 2.5}]),
    quiet("popover-light-2-close", "Escape.", [{"key": "escape"}, {"wait": 0.8}]),
    appearance("appearance-system", "Settings ▸ Appearance back to System.", "System"),
    quiet("settings-close-2", "cmd+W.", [{"key": "cmd+w"}, {"wait": 1.0}]),
    shot("dark-after", "Back to dark.", []),
]
light = script("parity-d-light", "Part D 9: the Quick Help popover with each app's own Appearance set to Light "
               "(Shapes.swift open), then back to System.", li)

F_ROW = lambda x: {"role": "AXRow", "text": x}
fm = [
    quiet("open-storyboard", "Click Main.storyboard.", [{"click": F_ROW("Main|Main.storyboard")}, {"wait": 4.0}]),
    vid("ib-zoom-fit", "Editor ▸ Zoom ▸ Zoom to Fit.", [{"menu": "Editor > Zoom > Zoom to Fit"}, {"wait": 1.2}]),
    vid("ib-library", "shift+cmd+L, type 'button'. AX tree.", [{"key": "cmd+shift+l"}, {"wait": 1.5},
                                                               {"text": "button"}, {"wait": 1.5}, tree("library")]),
    per(vid("ib-drag-button", "Drag the library's button item onto the view controller's view (window point 700, "
            "600) over 1.2 s.", [], post=1.2),
        xcode=[{"drag": {"from": {"label~": "Push Button", "scope": "app", "visible": True}, "to": [700, 600]},
                "duration": 1.2}, {"wait": 1.5}, tree("dropped")],
        # Ycode's Library is a floating window that stays over the canvas (part C): drop right of it instead.
        ycode=[{"drag": {"from": {"label": "Button", "scope": "app", "visible": True}, "to": [1100, 500]},
                "duration": 1.2},
               {"drag": {"from": {"label~": "Button", "scope": "app", "visible": True}, "to": [1100, 500]},
                "duration": 1.2, "fallback": True}, {"wait": 1.5}, tree("dropped")]),
    quiet("ib-library-close", "Escape (the Library, if it stayed), then its window's close button if it is a window.",
          [{"key": "escape"}, {"wait": 0.6},
           {"press": {"role": "AXButton", "subrole": "AXCloseButton"}, "window": "Library"}, {"wait": 0.6}]),
    shot("ib-after", "After the drop. AX tree.", [tree("after")]),
    vid("ib-undo", "cmd+Z.", [{"key": "cmd+z"}, {"wait": 1.0}]),
    quiet("open-swiftui", "Click ContentView.swift.", [{"click": ROW("ContentView")}, {"wait": 3.0},
                                                       {"menubar": "canvas"}]),
    vid("canvas-resume", "The canvas's Refresh Canvas / Resume button (else option+cmd+P), then up to 60 s.",
        [{"click": {"role": "AXButton", "description": "Refresh Canvas|Resume", "visible": True}},
         {"key": "cmd+alt+p", "fallback": True}, {"wait": 12.0}], post=0.5),
    shot("canvas-60s", "60 s after the resume. AX tree.", [{"wait": 48.0}, tree("canvas")]),
    vid("canvas-live-menu", "Click the canvas's Live control (Xcode: menu button titled 'Live'): its menu.",
        [{"click": {"role": "AXMenuButton", "title": "Live", "scope": "app", "visible": True}}, {"wait": 1.0},
         tree("live")], post=0.6),
    step("canvas-live-items", "Its items.", [{"submenus": "items", "all_windows": True}], record=False, still="none"),
    quiet("canvas-live-close", "Escape.", [CLOSE_MENUS, {"wait": 0.5}]),
    vid("canvas-variants", "Click Variants (menu button): its menu.",
        [{"click": {"role": "AXMenuButton", "title": "Variants", "scope": "app", "visible": True}}, {"wait": 1.0},
         tree("variants")], post=0.6),
    quiet("canvas-variants-close", "Escape.", [CLOSE_MENUS, {"wait": 0.5}]),
    vid("canvas-device-settings", "Click Device Settings: its popover. AX tree.",
        [{"click": {"role": "AXButton", "description": "Device Settings", "scope": "app", "visible": True}},
         {"wait": 1.2}, tree("device-settings")], post=0.6),
    quiet("canvas-device-close", "Escape.", [{"key": "escape"}, {"wait": 0.5}]),
    shot("canvas-menubar", "Menu bar at the end.", [{"menubar": "end"}]),
]
formats = script("parity-d-formats", "Part D 10: the Interface Builder drag (Ycode's part C run lost it) and the "
                 "canvas's Live, Variants and Device Settings controls by their real names.", fm, project=FORMATS)

# ---------------------------------------------------------------- D11 pressed states, focus, tooltips
ps = [
    shot("rest", "Shapes.swift open. AX tree.", [tree("rest")]),
    vid("press-run", "Hold the mouse button on Run 0.6 s, slide off to the editor (window point 700, 500), release "
        "there (nothing runs).", [hold(TB("Run"), [700, 500])], post=0.8),
    vid("press-nav-tab", "Hold on the Find navigator tab 0.6 s, release on the editor.",
        [hold({"role": "AXRadioButton|AXCheckBox", "label": "Find"}, [700, 500])], post=0.8),
    vid("press-toggle", "Hold on the Hide Inspector toolbar toggle 0.6 s, release on the editor.",
        [hold(TB("Hide Inspector"), [700, 500])], post=0.8),
    vid("press-scheme-popup", "Hold on the scheme pop-up 0.6 s, release on the editor (Escape after).",
        [hold({"label": "Active Scheme", "role": "AXPopUpButton"}, [700, 500])], post=0.8),
    quiet("press-scheme-popup-close", "Escape.", [CLOSE_MENUS, {"wait": 0.5}]),
    quiet("sheet-open", "cmd+N: the File from Template sheet.", [{"key": "cmd+n"}, {"wait": 2.0}]),
    vid("press-sheet-default", "Hold on the sheet's default button (Next) 0.6 s, release on the sheet's grid "
        "(window point 700, 300).", [hold({"role": "AXButton", "title": "Next", "scope": "app"}, [700, 300])],
        post=0.8),
    quiet("sheet-close", "Cancel.", ESC_OR_CANCEL + [{"wait": 1.0}]),
    quiet("open-project-editor", "The project editor, Build Settings.",
          [{"click": {"role": "AXRow", "text": "Parity", "index": 0}}, {"wait": 2.5},
           {"click": {"role": "AXButton|AXRadioButton", "label": "Build Settings", "visible": True}}, {"wait": 1.5},
           {"resize": [1400, 880]}, {"move": [56, 71]}, {"wait": 0.5}]),
    vid("press-segment", "Hold on the Build Settings 'Customized' segment 0.6 s, release on the settings list "
        "(window point 700, 600).", [hold({"role": "AXButton|AXRadioButton", "label": "Customized", "visible": True},
                                          [700, 600])], post=0.8),
    vid("press-tab-segment", "Hold on the 'Build Phases' tab 0.6 s, release on the settings list.",
        [hold({"role": "AXButton|AXRadioButton", "label": "Build Phases", "visible": True}, [700, 600])], post=0.8),
    quiet("back-to-shapes", "Back to Shapes.swift.", [{"click": ROW("Shapes")}, {"wait": 2.0}]),
    tab_walk("focus-tab", "Tab from the editor with the system's keyboard navigation setting left as it is "
             "(full keyboard access off): which controls get focus. Stills and AX trees.", 6),
    tab_walk("focus-shift-tab", "shift+Tab back.", 3, key="shift+tab"),
]
for sid, match, note in [
    ("tip-run", TB("Run"), "Run"), ("tip-scheme", {"label": "Active Scheme", "role": "AXPopUpButton"}, "the scheme"),
    ("tip-destination", {"label": "Active Run Destination", "role": "AXPopUpButton"}, "the destination"),
    ("tip-library", {"description": "Library|Show Library|Add"}, "the Library button"),
    ("tip-nav-tab", {"role": "AXRadioButton|AXCheckBox", "label": "Find"}, "the Find tab"),
    ("tip-inspector-tab", {"role": "AXRadioButton|AXButton|AXCheckBox", "description~": "History inspector"},
     "the History inspector tab"),
]:
    ps.append(vid(sid, f"Pointer onto {note}, held 2.5 s (tooltip).", [{"hover": match}, {"wait": 2.5}], post=0.4))
ps.append(shot("end", "End. AX tree.", [{"hover": [700, 500]}, {"wait": 0.5}, tree("end")]))
states = script("parity-d-states", "Part D 11: pressed (mouse-down) states of Run, a navigator tab, a toolbar "
                "toggle, a pop-up button, a sheet's default button, a segmented control and a tab; keyboard focus "
                "with the system's defaults; tooltips.", ps, setup=[{"select": ROW("Shapes")}, {"wait": 2.5}])

# ---------------------------------------------------------------- D12 Ycode's Device Hub: iPad and watch re-selected
DEV = "ycode-test-parity-{}"
SIDEBAR = {"press": {"role": "AXButton", "description": "Sidebar|Show Sidebar|Hide Sidebar", "scope": "app"}}
ROTATE = {"press": {"role": "AXButton", "description": "Rotate Left|Rotate Right|Rotate (Option-click to rotate right)",
                    "scope": "app"}}
FIT = {"press": {"role": "AXRadioButton", "help": "Zoom to Fit", "scope": "app"}}
CLICK_DEV = lambda kind: {"click": {"role": "AXRow", "text~": DEV.format(kind), "scope": "app", "visible": True}}
dv = [
    shot("rest", "Ycode's Device Hub, ycode-test-parity-iphone selected (the sidebar lists every simulator on this "
         "Mac; painted out except our rows). AX tree.", [tree("rest")]),
    vid("sidebar-hide", "Hide the sidebar (toolbar button; View has no Hide Sidebar).", [SIDEBAR, {"wait": 1.0}]),
    vid("ipad-fit", "Show the sidebar (toolbar button), click the iPad's row (pointer on its frame), hide the sidebar, "
        "Zoom to Fit.", [SIDEBAR, {"wait": 1.0}, CLICK_DEV("ipad"), {"wait": 3.0}, SIDEBAR, {"wait": 1.0}, FIT,
                         {"wait": 1.5}, tree("ipad")], post=1.0),
    vid("ipad-rotate", "Rotate.", [ROTATE, {"wait": 2.5}], post=1.5),
    vid("ipad-rotate-back", "Rotate three more times.", [ROTATE, {"wait": 1.5}, ROTATE, {"wait": 1.5}, ROTATE,
                                                         {"wait": 2.0}], post=1.0),
    vid("watch-fit", "Sidebar shown; its Search field (window point 110, 72) filtered to 'parity-watch' (the watch's "
        "row is far below the fold: Ycode groups the list by platform), click the watch's row (pointer on its "
        "frame), clear the filter, sidebar hidden, Zoom to Fit. AX tree.",
        [SIDEBAR, {"wait": 1.0}, {"click": [110, 72]}, {"wait": 0.4}, {"text": "parity-watch"}, {"wait": 1.2},
         CLICK_DEV("watch"), {"wait": 3.0}, {"click": [110, 72]}, {"key": "cmd+a"}, {"key": "delete"},
         {"wait": 0.8}, SIDEBAR, {"wait": 1.0}, FIT, {"wait": 1.5}, tree("watch")], post=1.0),
    vid("watch-home", "Press the watch's first hardware control (Home / crown).",
        [{"press": {"role": "AXButton", "description": "Home|Digital Crown|Crown", "scope": "app"}}, {"wait": 2.0}],
        post=1.0),
    vid("back-iphone", "Sidebar, click the iPhone's row.", [SIDEBAR, {"wait": 1.0}, CLICK_DEV("iphone"),
                                                            {"wait": 3.0}]),
]
device = script("parity-d-device", "Part D 12: Ycode's Device Hub (Ycode ▸ Open Developer Tool ▸ Device Hub): the "
                "iPad and watch selected again by clicking their sidebar rows, Zoom to Fit, rotate, Home.", dv,
                project=GLASS,
                window={"size": [1100, 800], "display": "builtin", "title": DEV.format("iphone"), "wait_title": None,
                        "first_window_wait": 6.0, "timeout": 90},
                per_target_setup={"ycode": [{"menu": "Ycode > Open Developer Tool > Device Hub"}, {"wait": 3.0},
                                            {"select": {"role": "AXRow", "text~": DEV.format("iphone"), "scope": "app"}},
                                            {"wait": 2.0}]},
                project_targets=["ycode"], setup_settle=2.0)
device["targets"] = ["ycode"]
device["compare_order"] = ["ycode"]

if __name__ == "__main__":
    for s in SCRIPTS:
        (HERE / f"{s['name']}.json").write_text(json.dumps(s, indent=1, ensure_ascii=False) + "\n")
        print(s["name"], len(s["steps"]), "steps")
