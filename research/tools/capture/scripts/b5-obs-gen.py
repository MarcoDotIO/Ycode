#!/usr/bin/env python3
"""Writes the B5-OBS session scripts (b5-obs-*.json) next to this file: Xcode 27.1
only, for beta 5's second wave (B5-POPOVERS, B5-STATES, B5-ISSUES). Every session
runs its steps twice in one launch: first with Xcode's own Appearance at System
(the Mac is Dark), then set to Light through Settings, then back to System.

    python3 -I research/tools/capture/scripts/b5-obs-gen.py
"""
import json
import pathlib

HERE = pathlib.Path(__file__).resolve().parent
REC = {"fps": 120, "codec": "hevc", "pre": 0.5, "post": 1.0}
APP = {"mode": "app", "margin": 600}
PARITY = {"generator": "make-parity-project.py", "path": "Parity/Parity.xcodeproj"}
FORMATS = {"generator": "make-formats-project.py", "path": "formats/Parity/Parity.xcodeproj"}
SCRIPTS = []


def script(name, title, steps, project=PARITY, setup=None, window=None):
    s = {"name": name, "title": title, "targets": ["xcode"], "compare_order": ["xcode"],
         "focus": "foreground", "launch_settle": 3.0, "record": REC, "project": project,
         "window": window or {"size": [1400, 880], "display": "builtin", "title": "{project}", "timeout": 90,
                              "offset": ORIGIN},
         "steps": steps}
    if setup:
        s["setup"] = setup
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
    return step(sid, note, do, record={**APP, "post": post}, **extra)


def shot(sid, note, do, **extra):
    return step(sid, note, do, record={"video": False, "mode": "app", "margin": 600}, still="after", **extra)


def quiet(sid, note, do, **extra):
    return step(sid, note, do, record=False, still="none", **extra)


def tree(name):
    return {"tree": name, "depth": 40}


def hold(frm, to=(700, 500), secs=0.5, window=None):
    a = {"drag": {"from": frm, "to": list(to)}, "hold": secs, "duration": 0.3}
    if window:
        a["window"] = window
    return a


def tc(needle, occurrence=1, offset=0, **kw):
    a = {"textclick": {"needle": needle, "occurrence": occurrence, "offset": offset}}
    for k in ("dx", "dy"):
        if k in kw:
            a["textclick"][k] = kw.pop(k)
    a.update(kw)
    return a


AWAY = [700, 500]
ORIGIN = [1020, 300]   # the workspace window's place on the main display (1x fallback)
HOME = {"move": ORIGIN, "window": "Parity"}
ROW = lambda name: {"role": "AXRow", "text": f"{name}|{name}.swift"}
TB = lambda d, role="AXButton": {"role": role, "description": d}
PROW = lambda text: {"role": "AXRow", "subrole": "AXTableRow", "text": text, "scope": "app", "visible": True}
SCHEME = {"label": "Active Scheme", "role": "AXPopUpButton"}
DEST = {"label": "Active Run Destination", "role": "AXPopUpButton"}
CLOSE_MENUS = {"key": "escape escape escape"}
APPEAR = {"Light": {"role": "AXButton", "description": "AppearanceLight", "scope": "app"},
          "System": {"role": "AXButton", "description": "AppearanceAuto", "scope": "app"}}


def appearance(sid, which):
    return vid(sid, f"Settings ▸ Appearance: Xcode's own Appearance set to {which}; Settings closed.",
               [{"key": "cmd+,"}, {"wait": 2.0},
                {"select": {"role": "AXRow", "text": "Appearance", "scope": "app"}}, {"wait": 1.2},
                {"press": APPEAR[which]}, {"wait": 1.5}, tree("appearance"), {"key": "cmd+w"}, {"wait": 1.0}],
               post=0.5)


def both(name, title, make, **kw):
    """The steps from make(prefix) in dark, then Light, the same steps again, then System."""
    steps = make("d") + [appearance("l-appearance-light", "Light")] + make("l") + \
        [appearance("z-appearance-system", "System"), shot("z-end", "Back to System (dark). AX tree.", [tree("end")])]
    return script(name, title, steps, **kw)


def control(p, cid, note, match, press=True, window=None, after_press=None):
    """Hover 1.2 s then leave (one video), and pressed: held 0.5 s, released away (one video)."""
    hov = {"hover": match}
    if window:
        hov["window"] = window
    out = [vid(f"{p}-{cid}-hover", f"{note}: pointer onto it, rests 1.2 s, then leaves to window point (700, 500) "
               "for 1.0 s. Hover still = the video frame 1.0 s after the hover.",
               [hov, {"wait": 1.2}, {"hover": AWAY}, {"wait": 1.0}], post=0.5)]
    if press:
        # A press on a control that does not track the mouse (a disabled toolbar button) drags the window:
        # put the workspace window back at its place afterwards.
        do = [hold(match, AWAY, window=window), {"wait": 0.6}, HOME]
        if after_press:
            do += after_press
        out.append(vid(f"{p}-{cid}-press", f"{note}: mouse held 0.5 s, then dragged off and released at (700, 500) "
                       "(nothing triggers). Held still = the frame 0.4 s after mouse-down.", do, post=0.6))
    return out


# ---------------------------------------------------------------- 1 control states (#63, P-198)
def states(p):
    s = [shot(f"{p}-rest", "Shapes.swift and Counter.swift in two tabs, Shapes selected. AX tree (frames of every "
              "control).", [tree("rest")])]
    for cid, note, match, kw in [
        ("run", "Run (toolbar)", TB("Run"), {}),
        ("stop", "Stop (toolbar; disabled while nothing runs; no press: a press on it drags the window)", TB("Stop"),
         {"press": False}),
        ("nav-toggle", "the Navigators toggle (toolbar)", TB("Navigators", "AXRadioButton"), {}),
        ("assistant", "the Coding Assistant toggle (toolbar; released away, never clicked)",
         TB("Coding Assistant", "AXRadioButton"), {}),
        ("insp-toggle", "the inspector toggle (toolbar)", TB("Hide Inspector|Show Inspector"), {}),
        ("library", "the Library button (toolbar)", {"role": "AXButton", "description": "Show Library|Library|Add"}, {}),
        ("scheme", "the scheme capsule", SCHEME, {"after_press": [CLOSE_MENUS, {"wait": 0.4}]}),
        ("destination", "the destination capsule", DEST, {"after_press": [CLOSE_MENUS, {"wait": 0.4}]}),
        # The navigator selector tracks the drag across its segments and selects the last one passed (Reports):
        # back to the Project navigator afterwards.
        ("nav-tab", "the Find navigator tab", {"role": "AXRadioButton", "subrole": "AXTabButton", "description": "Find"},
         {"after_press": [{"key": "cmd+1"}, {"wait": 0.8}]}),
        ("insp-tab", "the History inspector tab", {"role": "AXRadioButton", "description": "History Inspector"}, {}),
        ("editor-tab", "the Counter.swift editor tab (not selected)",
         {"role": "AXRadioButton", "subrole": "AXTabButton", "title": "Counter.swift"}, {"press": False}),
        ("tab-close", "the selected tab's close button", {"role": "AXButton", "title": "close tab", "index": 0}, {}),
        ("jumpbar", "the jump bar's file segment (window point 586, 66)", None,
         {"after_press": [CLOSE_MENUS, {"wait": 0.4}]}),
        ("filter", "the navigator filter field (bottom bar)",
         {"role": "AXTextField", "subrole": "AXSearchField", "description": "Project navigator filter"}, {}),
        ("filter-menu", "the navigator bottom bar's filter options menu button",
         {"identifier": "filterControlBarActionMenuButton"}, {"after_press": [CLOSE_MENUS, {"wait": 0.4}]}),
        ("recent", "the bottom bar's Recent files toggle", {"role": "AXCheckBox", "title": "Recent files"}, {}),
        ("disclosure", "a group's disclosure triangle (second row)", {"role": "AXDisclosureTriangle", "index": 1}, {}),
        ("debug-toggle", "the editor's bottom bar Show Debug Area button", TB("show debug area"), {}),
    ]:
        if match is None:
            match = [586, 66]
        s += control(p, cid, note, match, **kw)
    s += [
        vid(f"{p}-find-open", "cmd+F: the find bar. AX tree.", [{"hover": AWAY}, {"key": "cmd+f"}, {"wait": 1.0},
                                                                 tree("findbar")], post=0.6),
    ]
    s += control(p, "find-field", "the find bar's Find field",
                 {"role": "AXTextField", "subrole": "AXSearchField", "description": "Find"})
    s += [quiet(f"{p}-find-close", "Escape closes the find bar.", [{"key": "escape"}, {"wait": 0.6}])]
    # keyboard focus with the system's own setting (not changed)
    walk = [{"click": AWAY}, {"wait": 0.4}]
    for i in range(1, 7):
        walk += [{"key": "tab"}, {"wait": 0.4}, {"snap": f"k{i:02d}", "mode": "app"}, tree(f"k{i:02d}")]
    s.append(step(f"{p}-focus-tab", "Click into the editor, then Tab ×6 with the system's keyboard-navigation "
                  "setting left as it is: where focus goes, whether a ring shows. Snaps + AX trees.", walk,
                  record=False, still="none"))
    walk = [{"click": {"role": "AXTextField", "subrole": "AXSearchField", "description": "Project navigator filter"}},
            {"wait": 0.5}, {"snap": "f00", "mode": "app"}]
    for i in range(1, 4):
        walk += [{"key": "tab"}, {"wait": 0.4}, {"snap": f"f{i:02d}", "mode": "app"}]
    walk += [{"key": "escape"}, {"click": AWAY}]
    s.append(step(f"{p}-focus-filter", "Click into the navigator filter field (its focus ring), then Tab ×3.", walk,
                  record=False, still="none"))
    # project editor: Build Settings segments
    s += [quiet(f"{p}-open-bs", "The project editor, target Parity, Build Settings.",
                [{"click": {"role": "AXRow", "text": "Parity", "index": 0}}, {"wait": 2.5},
                 {"click": {"role": "AXButton|AXRadioButton", "label": "Build Settings", "visible": True}},
                 {"wait": 1.5}, tree("bs")])]
    for cid, label in [("seg-basic", "Basic"), ("seg-customized", "Customized"), ("seg-all", "All"),
                       ("seg-combined", "Combined"), ("seg-levels", "Levels")]:
        s += control(p, cid, f"the Build Settings '{label}' segment",
                     {"role": "AXButton|AXRadioButton", "label": label, "visible": True}, )
    s += [quiet(f"{p}-back", "Back to Shapes.swift.", [{"click": ROW("Shapes")}, {"wait": 1.5}])]
    # sheet buttons: File ▸ New ▸ File from Template sheet
    s += [quiet(f"{p}-sheet-open", "cmd+N: the File from Template sheet.", [{"key": "cmd+n"}, {"wait": 2.0},
                                                                            tree("sheet")])]
    s += control(p, "sheet-next", "the sheet's default button (Next)",
                 {"role": "AXButton", "title": "Next", "scope": "app"}, )
    s += control(p, "sheet-cancel", "the sheet's Cancel button", {"role": "AXButton", "title": "Cancel", "scope": "app"})
    s += [quiet(f"{p}-sheet-close", "Cancel.", [{"press": {"role": "AXButton", "title": "Cancel", "scope": "app"}},
                                                {"key": "escape", "fallback": True}, {"wait": 1.0}])]
    # Settings: toolbar segments, a pop-up button and a checkbox
    s += [quiet(f"{p}-settings-open", "cmd+, then the General pane. AX tree.",
                [{"key": "cmd+,"}, {"wait": 2.0}, {"select": {"role": "AXRow", "text": "General", "scope": "app"}},
                 {"press": {"role": "AXButton|AXRadioButton", "label": "General", "scope": "app"}, "fallback": True},
                 {"wait": 1.2}, {"move": [1100, 300], "window": "General"}, {"wait": 0.6}, tree("settings")])]
    s += control(p, "set-pane", "the Settings pane selector's 'Navigation' item",
                 {"label": "Navigation", "role": "AXButton|AXRadioButton|AXRow|AXCell", "scope": "app"},
                 window="General", press=False)
    s += control(p, "set-popup", "the first pop-up button of Settings ▸ General",
                 {"role": "AXPopUpButton", "scope": "app", "index": 0}, window="General",
                 after_press=[CLOSE_MENUS, {"wait": 0.4}])
    s += control(p, "set-checkbox", "the first checkbox of Settings ▸ General",
                 {"role": "AXCheckBox", "scope": "app", "index": 0}, window="General")
    s += [quiet(f"{p}-settings-close", "cmd+W.", [{"key": "cmd+w"}, {"wait": 1.0}])]
    # tooltip and menu entrance (item 6)
    s += [vid(f"{p}-tip-run", "Pointer onto Run, rests 3 s (tooltip), then leaves for 1.5 s (its fade).",
              [{"hover": TB("Run")}, {"wait": 3.0}, {"hover": AWAY}, {"wait": 1.5}], post=0.4),
          vid(f"{p}-menu-view", "Click View in the menu bar, 1.2 s, Escape (entrance and dismissal).",
              [{"click": {"role": "AXMenuBarItem", "title": "View", "scope": "app"}}, {"wait": 1.2},
               {"key": "escape"}, {"wait": 0.8}], post=0.6)]
    return s


both("b5-obs-states", "B5-OBS 1/6: hover, pressed, focus and disabled states of the toolbar, tabs, segments, "
     "fields, bottom bars, sheet buttons and Settings controls; tooltip; menu entrance.", states,
     setup=[{"select": ROW("Shapes")}, {"wait": 2.0}, {"key": "cmd+t"}, {"wait": 1.0}, {"select": ROW("Counter")},
            {"wait": 1.5}, {"click": {"role": "AXRadioButton", "subrole": "AXTabButton", "title": "Shapes.swift"}},
            {"wait": 1.0}])


# ---------------------------------------------------------------- 1b Settings controls (by window point: Settings
# sits at (1100, 300) on the main display, 80 pt right of the workspace window's origin; its sidebar rows are the
# pane selector in 27.1, there is no toolbar)
def settings(p):
    s = [quiet(f"{p}-open", "cmd+, then the General row; Settings moved to (1100, 300). AX tree.",
               [{"key": "cmd+,"}, {"wait": 2.0}, {"select": {"role": "AXRow", "text": "General", "scope": "app"}},
                {"wait": 1.0}, {"move": [1100, 300], "window": "General"}, {"wait": 0.8}, tree("settings")])]
    s += control(p, "popup", "Settings ▸ General's first pop-up button ('Use System Setting', window point 677, 117)",
                 [677, 117], after_press=[CLOSE_MENUS, {"wait": 0.4}])
    s += control(p, "checkbox", "Settings ▸ General's 'Window tabs have independent…' switch (window point 742, 396)",
                 [742, 396])
    s += control(p, "row", "the Settings sidebar's Navigation row (window point 170, 228)", [170, 228])
    # The row press leaves the Navigation pane selected; close Settings by its own close button (cmd+W closed the
    # workspace window in the first run, when Settings was not key).
    s += [quiet(f"{p}-close", "Settings' close button (window 'Navigation', else 'General').",
                [{"press": {"role": "AXButton", "subrole": "AXCloseButton"}, "window": "Navigation"},
                 {"press": {"role": "AXButton", "subrole": "AXCloseButton"}, "window": "General", "fallback": True},
                 {"wait": 1.0}])]
    return s


both("b5-obs-settings", "B5-OBS 1b: hover and pressed states of a Settings pop-up button, switch and sidebar row.",
     settings, setup=[{"select": ROW("Shapes")}, {"wait": 1.5}])


# ---------------------------------------------------------------- 3 popovers and in-window panels
def popovers(p):
    s = [shot(f"{p}-rest", "Showcase.swift open. AX tree.", [tree("rest")]),
         vid(f"{p}-scheme-open", "Click the scheme capsule: the chooser popover appears. AX tree.",
             [{"click": SCHEME}, {"wait": 1.2}, tree("scheme")], post=0.6)]
    for k, text in enumerate(["Parity", "Edit Scheme…", "New Scheme…", "Manage Schemes…"]):
        s.append(vid(f"{p}-scheme-hover-{k}", f"Pointer onto the '{text}' row, 1.0 s.",
                     [{"hover": PROW(text)}, {"wait": 1.0}], post=0.3))
    s += [vid(f"{p}-scheme-keys", "Down, Down, Up (keyboard selection).",
              [{"key": "down"}, {"wait": 0.5}, {"key": "down"}, {"wait": 0.5}, {"key": "up"}, {"wait": 0.6}],
              post=0.4),
          vid(f"{p}-scheme-escape", "Escape: the popover leaves.", [{"key": "escape"}, {"wait": 0.8}], post=0.6),
          vid(f"{p}-newscheme", "Chooser again, click 'New Scheme…': the New Scheme sheet. AX tree.",
              [{"click": SCHEME}, {"wait": 1.0}, {"click": PROW("New Scheme…")}, {"wait": 1.5}, tree("newscheme")],
              post=0.8),
          vid(f"{p}-newscheme-target", "Click the sheet's Target pop-up (its menu). AX tree; Escape.",
              [{"click": {"role": "AXPopUpButton", "scope": "app", "visible": True, "index": 0}}, {"wait": 1.0},
               tree("target"), {"key": "escape"}, {"wait": 0.5}], post=0.5),
          vid(f"{p}-newscheme-cancel", "Cancel.", [{"press": {"role": "AXButton", "title": "Cancel", "scope": "app"}},
                                                   {"key": "escape", "fallback": True}, {"wait": 1.0}], post=0.6),
          vid(f"{p}-dest-open", "Click the destination capsule: its popover. AX tree.",
              [{"click": DEST}, {"wait": 1.2}, tree("dest")], post=0.6),
          vid(f"{p}-dest-hover-mac", "Pointer onto the 'My Mac' row, 1.0 s.", [{"hover": PROW("My Mac")}, {"wait": 1.0}],
              post=0.3),
          vid(f"{p}-dest-incompatible", "Click 'Incompatible': the section expands in place (rows listing devices "
              "are painted out). AX tree.", [{"click": PROW("Incompatible")}, {"wait": 1.5}, tree("incompat")],
              post=0.8),
          vid(f"{p}-dest-escape", "Escape.", [{"key": "escape"}, {"wait": 0.8}], post=0.5),
          vid(f"{p}-qh-top", "option+click 'Store0' (line 38, upper part of the editor): Quick Help popover. AX tree.",
              [tc("Store0", offset=2, modifiers="alt"), {"wait": 2.5}, tree("qh-top")], post=0.8),
          vid(f"{p}-qh-top-close", "Escape.", [{"key": "escape"}, {"wait": 0.8}], post=0.5),
          vid(f"{p}-qh-bottom", "option+click 'name' in 'nonisolated let name' (line 40, the editor's last full "
              "line at 1400 × 880): Quick Help. AX tree.",
              [tc("let name", offset=5, modifiers="alt"), {"wait": 2.5}, tree("qh-bottom")], post=0.8),
          vid(f"{p}-qh-bottom-close", "Escape.", [{"key": "escape"}, {"wait": 0.8}], post=0.5),
          vid(f"{p}-jump-line", "cmd+L: Jump to Line. AX tree.", [{"hover": AWAY}, {"key": "cmd+l"}, {"wait": 1.2},
                                                                   tree("jumpline")], post=0.6),
          shot(f"{p}-jump-line-workspace", "Still with Jump to Line open (active look of the workspace).", []),
          vid(f"{p}-jump-line-escape", "Escape.", [{"key": "escape"}, {"wait": 0.8}], post=0.5),
          vid(f"{p}-quick-actions", "cmd+shift+A: Quick Actions. AX tree.",
              [{"key": "cmd+shift+a"}, {"wait": 1.5}, tree("quickactions")], post=0.6),
          vid(f"{p}-quick-actions-escape", "Escape.", [{"key": "escape"}, {"wait": 0.8}], post=0.5),
          vid(f"{p}-open-quickly", "cmd+shift+O: Open Quickly (active look behind it). AX tree.",
              [{"key": "cmd+shift+o"}, {"wait": 1.5}, tree("openquickly")], post=0.6),
          vid(f"{p}-open-quickly-escape", "Escape.", [{"key": "escape"}, {"wait": 0.8}], post=0.5),
          vid(f"{p}-library-open", "shift+cmd+L: the Library appears. AX tree.",
              [{"key": "cmd+shift+l"}, {"wait": 1.5}, tree("library")], post=0.6),
          vid(f"{p}-library-outside", "Click outside it (window point 150, 700, the navigator): does it leave?",
              [{"click": [150, 700]}, {"wait": 1.2}], post=0.8),
          quiet(f"{p}-library-esc0", "Escape in case it stayed.", [{"key": "escape"}, {"wait": 0.5}]),
          vid(f"{p}-library-open-2", "shift+cmd+L again.", [{"key": "cmd+shift+l"}, {"wait": 1.5}], post=0.4),
          vid(f"{p}-library-escape", "Escape: its exit.", [{"key": "escape"}, {"wait": 1.0}], post=0.6),
          vid(f"{p}-quick-new-project", "cmd+shift+N with the workspace open: what appears. AX tree.",
              [{"key": "cmd+shift+n"}, {"wait": 2.5}, tree("newproject")], post=0.8),
          vid(f"{p}-quick-new-project-cancel", "Cancel (button), else Escape.",
              [{"press": {"role": "AXButton", "title": "Cancel", "scope": "app"}}, {"key": "escape", "fallback": True},
               {"wait": 1.2}], post=0.6),
          vid(f"{p}-settings-front", "cmd+,: Settings in front of the workspace (active look).",
              [{"key": "cmd+,"}, {"wait": 1.5}, {"move": [1100, 300], "window": "Appearance"}, {"wait": 1.0}], post=0.4),
          quiet(f"{p}-settings-close", "cmd+W.", [{"key": "cmd+w"}, {"wait": 1.0}]),
          vid(f"{p}-about-front", "Xcode ▸ About Xcode in front of the workspace (active look).",
              [{"menu": "Xcode > About Xcode"}, {"wait": 2.0}, tree("about")], post=0.4),
          quiet(f"{p}-about-close", "cmd+W.", [{"key": "cmd+w"}, {"wait": 1.0}]),
          vid(f"{p}-product-dest", "Product menu, pointer on Destination (its sub-menu; device rows painted out). "
              "AX tree.", [{"click": {"role": "AXMenuBarItem", "title": "Product", "scope": "app"}}, {"wait": 0.8},
                           {"hoveritem": "Destination"}, {"wait": 1.5}, tree("product-dest")], post=0.5),
          step(f"{p}-product-dest-items", "Items of the open menus.", [{"submenus": "items", "all_windows": True}],
               record=False, still="none"),
          quiet(f"{p}-product-close", "Escape.", [CLOSE_MENUS, {"wait": 0.5}])]
    return s


both("b5-obs-popovers", "B5-OBS 2/6: scheme and destination popovers, New Scheme sheet, Quick Help top and "
     "bottom, Jump to Line, Quick Actions, Open Quickly, Library, Quick New Project, active look, Product ▸ "
     "Destination.", popovers, setup=[{"select": ROW("Showcase")}, {"wait": 2.5}])


# ---------------------------------------------------------------- 3b Quick Help near the editor's top (the popovers
# session's two lookups, lines 38 and 40, both sat in the lower part of the editor)
def qh(p):
    return [vid(f"{p}-qh-near-top", "option+click 'Foundation' in 'import Foundation' (line 3, the editor's top): "
                "Quick Help. AX tree.", [tc("import Foundation", offset=9, modifiers="alt"), {"wait": 2.5},
                                         tree("qh")], post=0.8),
            vid(f"{p}-qh-near-top-close", "Escape.", [{"key": "escape"}, {"wait": 0.8}], post=0.5),
            vid(f"{p}-qh-mid", "option+click 'Mode0' (line 7, upper third): Quick Help.",
                [tc("enum Mode0", offset=6, modifiers="alt"), {"wait": 2.5}], post=0.8),
            vid(f"{p}-qh-mid-close", "Escape.", [{"key": "escape"}, {"wait": 0.8}], post=0.5)]


both("b5-obs-qh", "B5-OBS 3b: Quick Help popovers for symbols in the upper part of the editor.", qh,
     setup=[{"select": ROW("Showcase")}, {"wait": 2.5}])


# ---------------------------------------------------------------- 2 glass and scroll edges
def glass(p):
    s = [shot(f"{p}-top", "Showcase.swift at the top. AX tree.", [tree("top")])]
    total = 0
    for dy in (6, 6, 12, 24, 48, 96, 200):
        total += dy
        s.append(shot(f"{p}-scroll-{total}", f"Editor scrolled down to {total} pt (phase-less wheel events, exact).",
                      [{"scroll": {"at": [700, 450]}, "dy": -dy, "steps": max(2, dy // 6), "interval": 0.016},
                       {"wait": 0.8}]))
    s += [vid(f"{p}-scroll-video", "Scroll back to the top over 0.6 s (the edge effect fading).",
              [{"scroll": {"at": [700, 450]}, "dy": total, "steps": 36, "interval": 0.016}, {"wait": 0.8}], post=0.6),
          quiet(f"{p}-open-stripes", "Click Stripes.png in the navigator (strong colours).",
                [{"click": {"role": "AXRow", "text": "Stripes|Stripes.png"}}, {"wait": 2.0}]),
          shot(f"{p}-stripes", "Stripes.png in the editor. AX tree.", [tree("stripes")]),
          shot(f"{p}-stripes-library", "Library over the stripes.", [{"key": "cmd+shift+l"}, {"wait": 1.5}]),
          quiet(f"{p}-stripes-library-close", "Escape.", [{"key": "escape"}, {"wait": 0.8}]),
          shot(f"{p}-stripes-openquickly", "Open Quickly over the stripes.", [{"key": "cmd+shift+o"}, {"wait": 1.5}]),
          quiet(f"{p}-stripes-oq-close", "Escape.", [{"key": "escape"}, {"wait": 0.8}]),
          shot(f"{p}-stripes-quickactions", "Quick Actions over the stripes.", [{"key": "cmd+shift+a"}, {"wait": 1.5}]),
          quiet(f"{p}-stripes-qa-close", "Escape.", [{"key": "escape"}, {"wait": 0.8}]),
          shot(f"{p}-stripes-scheme", "Scheme popover over the stripes.", [{"click": SCHEME}, {"wait": 1.2}]),
          quiet(f"{p}-stripes-scheme-close", "Escape.", [{"key": "escape"}, {"wait": 0.8}]),
          shot(f"{p}-stripes-sheet", "File from Template sheet over the stripes.", [{"key": "cmd+n"}, {"wait": 2.0}]),
          quiet(f"{p}-stripes-sheet-close", "Cancel.", [{"press": {"role": "AXButton", "title": "Cancel",
                                                                   "scope": "app"}},
                                                        {"key": "escape", "fallback": True}, {"wait": 1.0}]),
          quiet(f"{p}-open-assets", "Click Assets.xcassets, then the Stripes image set.",
                [{"click": {"role": "AXRow", "text": "Assets|Assets.xcassets"}}, {"wait": 2.5}]),
          shot(f"{p}-assets", "The asset catalog. AX tree.", [tree("assets")]),
          quiet(f"{p}-back", "Back to Showcase.swift.", [{"click": ROW("Showcase")}, {"wait": 1.5}])]
    return s


both("b5-obs-glass", "B5-OBS 3/6: the toolbar scroll edge at several offsets; panels, popovers and sheets over a "
     "strongly coloured image.", glass, project=FORMATS, setup=[{"select": ROW("Showcase")}, {"wait": 2.5}])


# ---------------------------------------------------------------- 4 narrow window and toolbar overflow
def narrow(p):
    s = [shot(f"{p}-1400", "1400 × 880, navigator and inspector shown. AX tree.", [tree("w1400")])]
    widths = list(range(1375, 475, -25))
    for w in widths:
        do = [{"resize": [w, 880]}, {"wait": 0.6}] + ([tree(f"w{w}")] if w % 50 == 0 else [])
        s.append(shot(f"{p}-w{w}", f"Window set to {w} × 880 through Accessibility (AX tree at every 50 pt).", do))
    s += [vid(f"{p}-overflow", "Click the toolbar's overflow button (the chevron at its right end). AX tree.",
              [{"click": {"role": "AXButton|AXMenuButton|AXPopUpButton",
                          "description~": "more|More|overflow|Overflow|chevron"}},
               {"wait": 1.2}, tree("overflow")], post=0.6),
          step(f"{p}-overflow-items", "The overflow menu's items.", [{"submenus": "items", "all_windows": True}],
               record=False, still="none"),
          quiet(f"{p}-overflow-close", "Escape.", [CLOSE_MENUS, {"wait": 0.5}]),
          vid(f"{p}-widen", "Back to 1400 × 880.", [{"resize": [1400, 880]}, {"wait": 1.2}], post=0.6)]
    return s


both("b5-obs-narrow", "B5-OBS 4/6: the window narrowed from 1400 pt (25-pt steps down to 500) with "
     "AX trees at each width; the toolbar overflow menu at the narrowest; widened back.", narrow,
     setup=[{"select": ROW("Shapes")}, {"wait": 2.0}])


# ---------------------------------------------------------------- 5 the live project warning
def issues(p):
    s = [shot(f"{p}-rest", "The unbuilt project after the wait; the toolbar's issue capsule. AX tree.",
              [{"wait": 2.0}, tree("rest")]),
         vid(f"{p}-capsule-hover", "Pointer onto the toolbar's issue capsule, 1.5 s.",
             [{"hover": TB("Issues")}, {"wait": 1.5}, {"hover": AWAY}, {"wait": 0.6}], post=0.4),
         vid(f"{p}-issue-nav", "cmd+5: the issue navigator. AX tree.", [{"key": "cmd+5"}, {"wait": 1.5},
                                                                       tree("issuenav")], post=0.6),
         shot(f"{p}-jumpbar", "Shapes.swift in the editor: the jump bar's issue stepper.", [tree("jumpbar")]),
         vid(f"{p}-stepper-next", "Click the jump bar's Show Next Issue arrow. AX tree.",
             [{"click": TB("Show Next Issue")}, {"wait": 1.5}, tree("next")], post=0.8),
         vid(f"{p}-issue-click", "Click the warning's row in the issue navigator (its 'Update to recommended "
             "settings' child, else the warning). AX tree.",
             [{"click": {"role": "AXRow", "text~": "Update to recommended settings"}},
              {"click": {"role": "AXRow", "text~": "recommended"}, "fallback": True}, {"wait": 2.5},
              tree("sheet")], post=1.0),
         step(f"{p}-sheet-snap", "Snap of whatever is in front (the sheet).", [{"snap": "sheet", "mode": "app"}],
              record=False, still="none"),
         vid(f"{p}-sheet-cancel", "Cancel (never Perform Changes).",
             [{"press": {"role": "AXButton", "title": "Cancel", "scope": "app"}}, {"key": "escape", "fallback": True},
              {"wait": 1.2}, tree("after")], post=0.6),
         quiet(f"{p}-nav-back", "cmd+1, Shapes.swift.", [{"key": "cmd+1"}, {"wait": 0.8}, {"select": ROW("Shapes")},
                                                         {"wait": 1.0}])]
    return s


both("b5-obs-issues", "B5-OBS 5/6: an unbuilt Parity copy's project-validation warning: issue navigator row, "
     "toolbar capsule, jump bar stepper, the 'Update to recommended settings' sheet (cancelled).", issues,
     setup=[{"select": ROW("Shapes")}, {"wait": 20.0}])

for s in SCRIPTS:
    (HERE / f"{s['name']}.json").write_text(json.dumps(s, indent=1, ensure_ascii=False) + "\n")
    print(s["name"], len(s["steps"]), "steps")
