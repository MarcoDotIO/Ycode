#!/usr/bin/env python3
"""Writes the parity run's part C session scripts (parity-c-*.json) next to
this file. Part C: Settings, editors for other file types (asset catalog,
property list, entitlements, String Catalog, test plan, Interface Builder,
Core Data model, Markdown, JSON, image), the SwiftUI preview canvas, Device
Hub and Organizer, each app's own Appearance set to Light, Help, About and
the documentation window.

    python3 -I research/tools/capture/scripts/parity-c-gen.py

Project: Parity with one file of each kind (make-formats-project.py).
"""
import json
import pathlib

HERE = pathlib.Path(__file__).resolve().parent
REC = {"fps": 120, "codec": "hevc", "pre": 0.5, "post": 1.2}
APP = {"mode": "app", "margin": 600}       # every window of the app on the built-in display
FORMATS = {"generator": "make-formats-project.py", "path": "formats/Parity/Parity.xcodeproj"}
SCRIPTS = []


def script(name, title, steps, project=FORMATS, setup=None, per_target_setup=None, window=None, **extra):
    s = {"name": name, "title": title, "targets": ["xcode", "ycode"], "compare_order": ["xcode", "ycode"],
         "focus": "foreground", "launch_settle": 3.0, "record": REC, "steps": steps, "project": project,
         "window": window or {"size": [1400, 880], "display": "builtin", "title": "{project}", "timeout": 90}}
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


def quiet(sid, note, do):
    return step(sid, note, do, record=False, still="none")


def tree(name):
    return {"tree": name, "depth": 40}


def tab_walk(sid, note, count, key="tab", trees=True):
    do = []
    for i in range(1, count + 1):
        do += [{"key": key}, {"wait": 0.4}, {"snap": f"k{i:02d}", "mode": "app"}]
        if trees:
            do.append(tree(f"k{i:02d}"))
    return step(sid, note, do, record=False, still="none")


ROW = lambda text: {"role": "AXRow", "text": text}
MI = lambda title: {"role": "AXMenuItem", "title": title, "scope": "app", "visible": True}
CLOSE_MENUS = {"key": "escape escape escape"}

# ---------------------------------------------------------------- probe (not judged)
probe = script("parity-c-probe", "Part C probe (not judged): AX names of the Settings window, the navigator rows "
               "of the formats project and the menu bar.", [
                   shot("rest", "At rest. AX tree and menu bar.", [tree("rest"), {"menubar": "rest"}]),
                   shot("settings", "cmd+comma: Settings. AX tree.", [{"key": "cmd+,"}, {"wait": 2.0},
                                                                     tree("settings")]),
                   quiet("settings-close", "cmd+W.", [{"key": "cmd+w"}, {"wait": 0.5}]),
               ])

# Files of the formats project: (id, Xcode row match, Ycode row match)
FILES = [
    ("assets", ROW("Assets|Assets.xcassets"), ROW("Assets|Assets.xcassets")),
    ("plist", ROW("Defaults|Defaults.plist"), ROW("Defaults|Defaults.plist")),
    ("entitlements", ROW("Parity.entitlements"), {"role": "AXRow", "text": "Parity|Parity.entitlements", "index": 2}),
    ("strings", ROW("Localizable|Localizable.xcstrings"), ROW("Localizable|Localizable.xcstrings")),
    ("testplan", ROW("Parity.xctestplan"), {"role": "AXRow", "text": "Parity|Parity.xctestplan", "index": 3}),
    ("storyboard", ROW("Main|Main.storyboard"), ROW("Main|Main.storyboard")),
    ("datamodel", ROW("Model|Model.xcdatamodeld"), ROW("Model|Model.xcdatamodeld")),
    ("markdown", ROW("NOTES|NOTES.md"), ROW("NOTES|NOTES.md")),
    ("json", ROW("palette|palette.json"), ROW("palette|palette.json")),
    ("image", ROW("Stripes.png"), ROW("Stripes|Stripes.png")),
    ("swiftui", ROW("ContentView|ContentView.swift"), ROW("ContentView|ContentView.swift")),
]


def open_file(fid, xm, ym, sid=None, note=None, kind="shot", extra=()):
    """A step that clicks the file's row (per target) and waits."""
    mk = shot if kind == "shot" else vid
    s = mk(sid or f"open-{fid}", note or f"Click {fid}'s row in the project navigator.", [])
    s["per_target"] = {"xcode": {"do": [{"click": xm}, {"wait": 3.0}, *extra]},
                       "ycode": {"do": [{"click": ym}, {"wait": 3.0}, *extra]}}
    return s


probe2 = script("parity-c-probe2", "Part C probe 2 (not judged): each file of the formats project opened; AX tree "
                "and menu bar for each.",
                [open_file(fid, xm, ym, extra=[tree(fid), {"menubar": fid}]) for fid, xm, ym in FILES])

# ---------------------------------------------------------------- C1 Settings
# (id, Xcode sidebar label = window title, Ycode label = window title). Accounts is never opened.
PANES = [("general", "General", "General"), ("appearance", "Appearance", "Appearance"),
         ("intelligence", "Intelligence", "Coding Assistant"), ("behaviors", "Behaviors", "Behaviors"),
         ("navigation", "Navigation", "Navigation"), ("notifications", "Notifications", "Notifications"),
         ("editing", "Editing", "Editing"), ("shortcuts", "Shortcuts", "Shortcuts"),
         ("source-control", "Source Control", "Source Control"), ("components", "Components", "Components"),
         ("locations", "Locations", "Locations")]
SETTINGS_AT = [401, 40]          # display points: the Settings window centred near the top of the built-in display
POPUPS, SEGMENTS = 8, 5


def pane_select(label, tall=False):
    do = [{"select": {"role": "AXRow", "text": label, "scope": "app"}}, {"wait": 1.5},
          {"move": SETTINGS_AT, "window": label}, {"wait": 0.4}]
    if tall:
        do += [{"resize": [710, 900], "window": label}, {"wait": 0.6}]
    return do


def per_app(sid, note, maker, kind, panes_x, panes_y, **extra):
    s = kind(sid, note, [], **extra)
    s["per_target"] = {"xcode": {"do": maker(panes_x)}, "ycode": {"do": maker(panes_y)}}
    return s


st = [quiet("settings-open", "cmd+comma, then General in the sidebar, the window moved to the top middle of the "
            "built-in display (Xcode reopens on the last pane; Ycode's opens on the main display).",
            [{"key": "cmd+,"}, {"wait": 2.0}, *pane_select("General")]),
      shot("general-rest", "Settings ▸ General at its own size. AX tree.", [tree("general")])]
for pid, xl, yl in PANES[1:] + PANES[:1]:
    st.append(per_app(f"pane-{pid}", f"Click '{xl}' (Ycode: '{yl}') in the sidebar: the pane switch (animation) at "
                      "the window's own size. AX tree.", lambda l: [*pane_select(l), tree("pane")], vid, xl, yl))
st += [
    vid("general-tooltip", "Pointer on General's first pop-up button, held 2.5 s (tooltip).",
        [{"hover": {"role": "AXPopUpButton", "index": 0}, "window": "General"}, {"wait": 2.5}], post=0.5),
    tab_walk("general-tab-order", "Tab through General (key-view order; full keyboard access is the system's "
             "setting, left alone).", 6),
]
for pid, xl, yl in PANES:
    st.append(per_app(f"{pid}-tall", f"{xl} (Ycode: {yl}) with the window resized to 710 x 900 where it can be, so "
                      "the whole pane shows. AX tree.", lambda l: [*pane_select(l, tall=True), tree("tall")],
                      shot, xl, yl))
    if pid == "intelligence":
        continue      # accounts and sign-in live there: the pane is seen, nothing in it is opened
    for k in range(SEGMENTS):
        if pid == "appearance":
            continue  # Ycode's appearance chooser must not be clicked here (C4 sets it on purpose)
        st.append(per_app(f"{pid}-segment-{k}", f"Segment {k} of the pane's segmented control(s), if any: clicked "
                          "(a tab switch). AX tree.",
                          lambda l, k=k: [{"click": {"role": "AXRadioButton", "subrole": "AXSegment", "index": k,
                                                     "visible": True}, "window": l},
                                          {"wait": 1.0}, {"tree": "seg", "depth": 40, "if_ok": True}],
                          shot, xl, yl))
    if pid != "appearance":
        st.append(per_app(f"{pid}-segment-back", "Back to the first segment.",
                          lambda l: [{"click": {"role": "AXRadioButton", "subrole": "AXSegment", "index": 0,
                                                "visible": True}, "window": l}, {"wait": 0.8}], quiet, xl, yl))
    for k in range(POPUPS):
        s = per_app(f"{pid}-popup-{k}", f"Pop-up button {k} of the pane, if any: opened (snap 'menu', its items in "
                    "-items.json), then Escape.",
                    lambda l, k=k: [{"click": {"role": "AXPopUpButton", "index": k, "visible": True}, "window": l},
                                    {"wait": 0.9}, {"snap": "menu", "mode": "app", "if_ok": True}, {"submenus": "items", "all_windows": True, "if_ok": True},
                                    {"key": "escape", "if_ok": True}, {"wait": 0.4}],
                    step, xl, yl, record={"video": False, "mode": "app", "margin": 600}, still="none")
        st.append(s)
st.append(quiet("settings-close", "cmd+W.", [{"key": "cmd+w"}, {"wait": 0.8}]))
settings = script("parity-c-settings", "Part C 1: Settings, every pane except Accounts: the pane switch at the "
                  "window's own size (video), then each pane at 710 x 900 with each segment and each pop-up menu "
                  "opened once (stills, AX trees, menu items).", st)

# ---------------------------------------------------------------- C2 other editors
F = {fid: (xm, ym) for fid, xm, ym in FILES}


def open_vid(fid, note):
    xm, ym = F[fid]
    return open_file(fid, xm, ym, sid=f"open-{fid}", note=note, kind="vid", extra=[tree(fid)])


ed = [
    open_vid("assets", "Click Assets in the navigator: the asset catalog editor (asset list, empty detail). AX tree."),
    vid("asset-swatch", "Click the Swatch colour set in the asset list: its detail (Any/Dark swatches).",
        [{"click": {"role": "AXRow", "text": "Swatch", "scope": "app", "visible": True}}, {"wait": 1.2}]),
    vid("asset-attributes", "View ▸ Inspectors ▸ Attributes (option+cmd+5): the colour set's Attributes inspector. "
        "AX tree.", [{"key": "cmd+alt+5"}, {"wait": 1.2}, tree("attributes")]),
    vid("asset-plus-menu", "Click the asset list's + button: its menu (animation). Menu items in -items.json.",
        [{"click": {"role": "AXMenuButton", "description": "Add an image or other asset|Add", "scope": "app",
                    "visible": True}}, {"wait": 1.0}], post=0.6),
    step("asset-plus-walk", "Every sub-menu of that menu hovered: a still of each.",
         [{"submenus": "sub", "all_windows": True}], record=False, still="none"),
    quiet("asset-plus-close", "Escape.", [CLOSE_MENUS, {"wait": 0.4}]),
    vid("asset-add-image", "Editor ▸ Add New Asset ▸ Image Set: a new image set (name field editing). AX tree.",
        [{"menu": "Editor > Add New Asset > Image Set"}, {"wait": 1.5}, tree("image-set")]),
    vid("asset-add-image-return", "Return (accept the name).", [{"key": "return"}, {"wait": 1.0}]),
    vid("asset-add-color", "Editor ▸ Add New Asset ▸ Color Set: a new colour set, with its Attributes inspector. "
        "AX tree.", [{"menu": "Editor > Add New Asset > Color Set"}, {"wait": 1.5}, {"key": "return"},
                     {"wait": 1.0}, tree("color-set")]),
    tab_walk("asset-tab-order", "Tab through the asset catalog editor (key-view order).", 5, trees=False),
    open_vid("plist", "Click Defaults.plist: the property list editor. AX tree."),
    vid("plist-select", "Click the Greeting row.", [{"click": {"role": "AXRow", "text": "Greeting", "visible": True}},
                                                     {"wait": 0.8}]),
    vid("plist-add", "Editor ▸ Add Item: a new row with its key field editing. AX tree.",
        [{"menu": "Editor > Add Item"}, {"wait": 1.2}, tree("added")]),
    vid("plist-add-escape", "Escape (end editing).", [{"key": "escape"}, {"wait": 0.8}]),
    shot("plist-type-popup", "Click the first String type pop-up (the Greeting row's Type): the value type menu "
         "(items in -items.json).", [{"click": {"role": "AXPopUpButton", "value": "String", "index": 0,
                                               "visible": True}}, {"wait": 1.0}, {"submenus": "items", "all_windows": True}]),
    quiet("plist-type-close", "Escape.", [CLOSE_MENUS, {"wait": 0.4}]),
    vid("plist-disclose", "Collapse then expand the Window dictionary row (disclosure animation).",
        [{"set": {"role": "AXRow", "text": "Window"}, "attr": "AXDisclosing", "value": False}, {"wait": 0.8},
         {"set": {"role": "AXRow", "text": "Window"}, "attr": "AXDisclosing", "value": True}, {"wait": 0.8}]),
    shot("plist-context", "Right-click the Greeting row: its context menu (items in -items.json).",
         [{"click": {"role": "AXRow", "text": "Greeting", "visible": True}, "button": "right"}, {"wait": 1.0},
          {"submenus": "items", "all_windows": True}]),
    quiet("plist-context-close", "Escape.", [CLOSE_MENUS, {"wait": 0.4}]),
    open_vid("entitlements", "Click Parity.entitlements: the entitlements (property list) editor. AX tree."),
    open_vid("strings", "Click Localizable.xcstrings: the String Catalog editor (languages, keys, states). AX tree."),
    vid("strings-row", "Click the 'Hello, Parity!' row.", [{"click": {"role": "AXRow", "text~": "Hello, Parity",
                                                                      "visible": True}}, {"wait": 1.0}]),
    vid("strings-german", "Click German in the language list (if shown).",
        [{"click": {"role": "AXRow", "text~": "German", "visible": True}}, {"wait": 1.2}, tree("german")]),
    open_vid("testplan", "Click Parity.xctestplan: the test plan editor. AX tree."),
    vid("testplan-configurations", "Click the Configurations tab (if any). AX tree.",
        [{"click": {"label": "Configurations", "scope": "app", "visible": True}}, {"wait": 1.2},
         tree("configurations")]),
    open_vid("storyboard", "Click Main.storyboard: Interface Builder (document outline, canvas, inspector). AX tree."),
    vid("ib-zoom-fit", "Editor ▸ Zoom ▸ Zoom to Fit.", [{"menu": "Editor > Zoom > Zoom to Fit"}, {"wait": 1.2}]),
    vid("ib-library", "View ▸ Show Library (shift+cmd+L): the object library (animation), then type 'button'. "
        "AX tree.", [{"key": "cmd+shift+l"}, {"wait": 1.5}, {"text": "button"}, {"wait": 1.5}, tree("library")]),
    vid("ib-drag-button", "Drag the library's Push Button onto the view controller's view (window point 700, 600 "
        "after Zoom to Fit).", [{"drag": {"from": {"label~": "Push Button", "scope": "app", "visible": True},
                                          "to": [700, 600]}, "duration": 1.2}, {"wait": 1.5}], post=1.2),
    vid("ib-attributes", "View ▸ Inspectors ▸ Attributes (option+cmd+5): the selected object's Attributes "
        "inspector. AX tree.", [{"key": "cmd+alt+5"}, {"wait": 1.2}, tree("attributes")]),
    vid("ib-outline-hide", "Hide the document outline (its button at the canvas's bottom left).",
        [{"click": {"description": "Hide Document Outline", "visible": True}}, {"wait": 1.0}]),
    vid("ib-outline-show", "Show it again.", [{"click": {"description": "Show Document Outline", "visible": True}},
                                              {"wait": 1.0}]),
    vid("ib-zoom-50", "Editor ▸ Zoom ▸ Zoom to 50%.", [{"menu": "Editor > Zoom > Zoom to 50%"}, {"wait": 1.2}]),
    vid("ib-zoom-100", "Editor ▸ Zoom ▸ Zoom to 100%.", [{"menu": "Editor > Zoom > Zoom to 100%"}, {"wait": 1.2}]),
    shot("ib-menubar", "The menu bar with Interface Builder focused.", [{"menubar": "ib"}]),
    vid("ib-undo", "cmd+Z (undo the dropped button).", [{"key": "cmd+z"}, {"wait": 1.0}]),
    open_vid("datamodel", "Click Model.xcdatamodeld: the Core Data model editor. AX tree."),
    vid("datamodel-shelf", "Click the Shelf entity.", [{"click": {"role": "AXRow", "text": "Shelf", "visible": True}},
                                                       {"wait": 1.0}, tree("shelf")]),
    open_vid("markdown", "Click NOTES.md: the Markdown editor. AX tree."),
    open_vid("json", "Click palette.json: the JSON editor. AX tree."),
    open_vid("image", "Click Stripes.png: the image viewer. AX tree."),
    # SwiftUI preview canvas
    open_file("swiftui", *F["swiftui"], sid="open-swiftui", note="Click ContentView.swift: the canvas (both apps "
              "have Editor ▸ Canvas checked at the start, recorded in the menu bar dump; nothing to turn on). AX tree "
              "and menu bar.", extra=[tree("swiftui"), {"menubar": "canvas"}]),
    vid("canvas-resume", "Click the canvas's Refresh Canvas / Resume button (the canvas was paused), then wait 10 s.",
        [{"click": {"role": "AXButton", "description": "Refresh Canvas|Resume", "visible": True}},
         {"key": "cmd+alt+p", "fallback": True}, {"wait": 10.0}], post=0.5),
    shot("canvas-25s", "25 s after the resume.", [{"wait": 13.0}]),
    shot("canvas-60s", "60 s after the resume. AX tree.", [{"wait": 33.0}, tree("canvas")]),
    vid("canvas-selectable", "The canvas's Selectable mode button (if found).",
        [{"click": {"description~": "Selectable", "scope": "app", "visible": True}}, {"wait": 2.0}]),
    vid("canvas-live", "The canvas's Live mode button (if found).",
        [{"click": {"description~": "Live", "scope": "app", "visible": True}}, {"wait": 4.0}]),
    vid("canvas-device", "The canvas's device / preview settings pop-up (if found). AX tree.",
        [{"click": {"role": "AXPopUpButton|AXMenuButton", "description~": "Device", "scope": "app", "visible": True}},
         {"wait": 1.2}, tree("device")]),
    quiet("canvas-device-close", "Escape.", [CLOSE_MENUS, {"wait": 0.4}]),
    vid("canvas-click-text", "Click the Increment button inside the preview (canvas centre-ish, window point taken "
        "from the 60 s still is not known in advance: the text 'Increment' in the canvas, if exposed).",
        [{"click": {"label": "Increment", "scope": "app", "visible": True, "index": 1}}, {"wait": 1.5}]),
    shot("canvas-menubar", "The menu bar with the SwiftUI file and canvas.", [{"menubar": "canvas-end"}]),
]
editors = script("parity-c-editors", "Part C 2: editors for other file types (asset catalog, property list, "
                 "entitlements, String Catalog, test plan, Interface Builder, Core Data model, Markdown, JSON, "
                 "image) and the SwiftUI preview canvas.", ed)

# ---------------------------------------------------------------- C4 Light appearance (each app's own setting)
APPEAR = {"xcode": {"Light": {"role": "AXButton", "description": "AppearanceLight", "scope": "app"},
                    "System": {"role": "AXButton", "description": "AppearanceAuto", "scope": "app"}},
          "ycode": {"Light": {"title": "Light", "scope": "app"}, "System": {"title": "System", "scope": "app"}}}


def appearance(sid, note, which, kind=vid):
    s = kind(sid, note, [])
    s["per_target"] = {t: {"do": [{"key": "cmd+,"}, {"wait": 2.0}, *pane_select("Appearance"),
                                  {"press": APPEAR[t][which]}, {"wait": 2.0}, tree("appearance")]}
                       for t in ("xcode", "ycode")}
    return s


MENUBAR_ITEM = lambda title: {"role": "AXMenuBarItem", "title": title, "scope": "app"}
li = [
    quiet("open-shapes", "Open Shapes.swift.", [{"click": ROW("Shapes|Shapes.swift")}, {"wait": 2.5}]),
    shot("dark-rest", "Before: the workspace with the app's Appearance at System (the system is Dark).", []),
    appearance("appearance-light", "Settings ▸ Appearance, then the app's own Appearance set to Light (the "
               "workspace window behind changes too: the switch animation). AX tree.", "Light"),
    shot("settings-appearance-light", "Settings ▸ Appearance in light.", []),
    vid("settings-general-light", "Settings ▸ General in light.", [*pane_select("General")]),
    vid("settings-editing-light", "Settings ▸ Editing in light.", [*pane_select("Editing")]),
    quiet("settings-close", "cmd+W.", [{"key": "cmd+w"}, {"wait": 1.0}]),
    shot("main-light", "The workspace window in light: toolbar, navigator, editor theme, inspector. AX tree.",
         [tree("main")]),
    vid("menu-light", "Click Editor in the menu bar: the menu in light (animation).",
        [{"click": MENUBAR_ITEM("Editor")}, {"wait": 1.0}], post=0.6),
    step("menu-light-walk", "Every sub-menu of Editor hovered: a still of each.", [{"submenus": "sub"}],
         record=False, still="none"),
    quiet("menu-light-close", "Escape.", [CLOSE_MENUS, {"wait": 0.4}]),
    vid("sheet-light", "File ▸ New ▸ File from Template (cmd+N): the template sheet in light. AX tree.",
        [{"key": "cmd+n"}, {"wait": 2.0}, tree("sheet")]),
    vid("sheet-light-cancel", "Cancel (Escape).", [{"press": {"role": "AXButton", "title": "Cancel", "scope": "app"}},
                                                   {"key": "escape", "fallback": True}, {"wait": 1.0}]),
    vid("navigator-select-light", "Click Counter in the navigator: the focused selection in light.",
        [{"click": ROW("Counter|Counter.swift")}, {"wait": 1.5}]),
    vid("navigator-unfocused-light", "Click into the editor: the navigator's selection unfocused, in light.",
        [{"click": [800, 400]}, {"wait": 1.0}]),
    vid("completion-light", "Type 'Co' at the end of line 1 after a Return: the completion list in light; "
        "then Escape and undo.", [{"key": "cmd+up"}, {"key": "cmd+right"}, {"key": "return"}, {"text": "Co"},
                                  {"wait": 2.0}], post=0.6),
    quiet("completion-light-undo", "Escape, undo.", [{"key": "escape"}, {"key": "cmd+z cmd+z cmd+z"}, {"wait": 0.5}]),
    vid("popover-light", "Option-click 'Circle' on its declaration: Quick Help popover in light.",
        [{"textclick": {"needle": "struct Circle", "offset": 9}, "modifiers": "alt"}, {"wait": 2.0}], post=0.6),
    quiet("popover-light-close", "Escape.", [{"key": "escape"}, {"wait": 0.5}]),
    shot("menubar-light", "The whole menu bar (light run, Shapes.swift open).", [{"menubar": "light"}]),
    appearance("appearance-system", "Settings ▸ Appearance back to System (its value before the session; the "
               "workspace window turns dark again).", "System"),
    quiet("settings-close-2", "cmd+W.", [{"key": "cmd+w"}, {"wait": 1.0}]),
    shot("dark-after", "After: back to dark.", []),
]
light = script("parity-c-light", "Part C 4: each app's own Appearance set to Light (the system stays Dark): the "
               "switch, Settings, the main window, a menu, a sheet, the navigator selection, the editor theme, "
               "completion and a popover; then back to System.", li)

# ---------------------------------------------------------------- C5 Help, About, documentation, Organizer
he = [
    quiet("open-shapes", "Open Shapes.swift.", [{"click": ROW("Shapes|Shapes.swift")}, {"wait": 2.5}]),
    vid("help-menu", "Click Help in the menu bar: the menu with its search field (animation). AX tree.",
        [{"click": MENUBAR_ITEM("Help")}, {"wait": 1.2}, tree("help")], post=0.6),
    vid("help-search", "Type 'zoom' into the Help search field: the results (menu items and help topics). AX tree.",
        [{"text": "zoom"}, {"wait": 2.5}, tree("results")], post=0.8),
    vid("help-search-arrow", "Down arrow onto the first menu-item result: the pointer arrow shows the item in its "
        "menu (animation).", [{"key": "down"}, {"wait": 2.0}], post=0.8),
    quiet("help-close", "Escape.", [CLOSE_MENUS, {"wait": 0.5}]),
    vid("help-search-empty", "Help, then 'qqqzz' (no results).", [{"click": MENUBAR_ITEM("Help")}, {"wait": 1.0},
                                                                  {"text": "qqqzz"}, {"wait": 2.0}], post=0.6),
    quiet("help-close-2", "Escape.", [CLOSE_MENUS, {"wait": 0.5}]),
    vid("about", "{app} ▸ About {app}: the About window (animation). AX tree.",
        [{"menu": "{app} > About {app}"}, {"wait": 2.0}, tree("about")], post=0.8),
    vid("about-close", "cmd+W.", [{"key": "cmd+w"}, {"wait": 1.0}], post=0.5),
    vid("docs-open", "Window ▸ Developer Documentation (shift+cmd+0): the documentation window, moved onto the "
        "built-in display. AX tree.", [{"key": "cmd+shift+0"}, {"wait": 6.0}, {"move": [56, 40], "window": "Documentation"}, {"wait": 0.8}, tree("docs")], post=0.8),
    vid("docs-search", "Type 'VStack' into its search field and Return; wait 6 s. AX tree.",
        [{"text": "VStack"}, {"wait": 2.0}, {"snap": "typing"}, {"key": "return"}, {"wait": 6.0}, tree("docs-result")],
        post=0.8),
    vid("docs-close", "cmd+W.", [{"key": "cmd+w"}, {"wait": 1.0}], post=0.5),
    vid("organizer-open", "Window ▸ Organizer (option+shift+cmd+O). AX tree. (The Organizer can list the Mac's "
        "own archives and apps: painted out afterwards where it does.)",
        [{"key": "cmd+alt+shift+o"}, {"wait": 4.0}, {"move": [56, 40], "window": "Overview"},
         {"move": [56, 40], "window": "Archives", "fallback": True}, {"move": [56, 40], "window": "Organizer", "fallback": True},
         {"wait": 0.8}, tree("organizer")], post=0.8),
]
for k in range(12):
    he.append(shot(f"organizer-row-{k}", f"Organizer sidebar row {k} (if any): clicked (rows of the frontmost window come first in the app's AX order).",
                   [{"click": {"role": "AXRow", "index": k, "scope": "app", "visible": True}}, {"wait": 2.0}]))
he += [
    shot("organizer-tree", "AX tree of the Organizer at the end.", [tree("organizer-end")]),
    quiet("organizer-close", "cmd+W.", [{"key": "cmd+w"}, {"wait": 1.0}]),
]
helps = script("parity-c-help", "Part C 5: the Help menu's search field and results, the About window, the "
               "Developer Documentation window with a search, and the Organizer (each sidebar row).", he)

# ---------------------------------------------------------------- C3 Device Hub and Ycode's Device Hub
DEV = "ycode-test-parity-{}"
DH_WINDOW = {"size": [1100, 800], "display": "builtin", "title": DEV.format("iphone"), "wait_title": None,
             "first_window_wait": 6.0, "timeout": 90}
DH_SETUP = {"devicehub": [{"menu": "View > Show Sidebar"}, {"wait": 1.0},
                          {"select": {"role": "AXRow", "text~": DEV.format("iphone"), "scope": "app"}}, {"wait": 2.0}],
            "ycode": [{"menu": "Ycode > Open Developer Tool > Device Hub"}, {"wait": 3.0},
                      {"select": {"role": "AXRow", "text~": DEV.format("iphone"), "scope": "app"}}, {"wait": 2.0}]}


def dh_script(name, title, steps):
    s = script(name, title, steps, project={"generator": "make-test-project.py", "path": "GlassScroll/GlassScroll.xcodeproj"},
               per_target_setup=DH_SETUP, window=DH_WINDOW, project_targets=["ycode"], setup_settle=2.0)
    s["targets"] = ["devicehub", "ycode"]
    s["compare_order"] = ["devicehub", "ycode"]
    s["launch_settle"] = 1.0
    return s


dh_probe = dh_script("parity-c-dhprobe", "Part C probe 3 (not judged): Device Hub's and Ycode's Device Hub AX names "
                     "and menu bars.", [shot("rest", "At rest, sidebar shown. AX tree and menu bar.",
                                             [tree("rest"), {"menubar": "rest"}])])

SEL = lambda kind: {"select": {"role": "AXRow", "text~": DEV.format(kind), "scope": "app"}}
SEG = lambda helps: {"role": "AXRadioButton", "help": helps, "scope": "app"}
BTN = lambda desc: {"role": "AXButton", "description": desc, "scope": "app"}
dv = [
    shot("rest", "Device Hub (Ycode: its Device Hub) with the sidebar shown and ycode-test-parity-iphone selected "
         "(the sidebar lists every device on this Mac: other rows are painted out). AX tree, menu bar.",
         [tree("rest"), {"menubar": "device"}]),
    vid("select-ipad", "Select ycode-test-parity-ipad in the sidebar. AX tree.", [SEL("ipad"), {"wait": 3.0},
                                                                                 tree("ipad")], post=1.5),
    vid("select-watch", "Select ycode-test-parity-watch.", [SEL("watch"), {"wait": 3.0}], post=1.5),
    vid("select-iphone", "Select ycode-test-parity-iphone.", [SEL("iphone"), {"wait": 3.0}], post=1.5),
    vid("add-device", "The sidebar's add (+) control, or File ▸ New…: the add-device sheet/menu. AX tree.",
        [{"click": {"role": "AXButton|AXMenuButton", "description~": "Add", "visible": True}},
         {"menu": "File > New Simulator…|New Device…|Add Device…|New Simulator...", "fallback": True},
         {"wait": 2.0}, tree("add")], post=1.0),
    step("add-device-walk", "Sub-menus of an add menu (if it is a menu): a still of each.",
         [{"submenus": "sub", "all_windows": True}], record=False, still="none"),
    vid("add-device-cancel", "Cancel (or Escape).", [{"press": {"role": "AXButton", "title": "Cancel", "scope": "app"}},
                                                     {"key": "escape", "fallback": True}, {"wait": 1.0}]),
    tab_walk("tab-order", "Tab through the window (key-view order).", 6, trees=False),
    vid("sidebar-hide", "View ▸ Hide Sidebar.", [{"menu": "View > Hide Sidebar"},
                                                  {"press": BTN("Sidebar|Hide Sidebar"), "fallback": True},
                                                  {"wait": 1.0}]),
    vid("zoom-fit", "Zoom to Fit (the zoom control's segment).", [{"press": SEG("Zoom to Fit")},
                                                                   {"menu": "View > Zoom to Fit", "fallback": True},
                                                                   {"wait": 1.5}]),
    vid("zoom-physical", "Physical Size.", [{"press": SEG("Physical Size|Zoom To Actual Size")},
                                           {"menu": "View > Physical Size", "fallback": True}, {"wait": 1.5}]),
    vid("zoom-in", "Zoom In.", [{"press": SEG("Zoom In")}, {"wait": 1.5}]),
    vid("zoom-out", "Zoom Out.", [{"press": SEG("Zoom Out")}, {"wait": 1.5}]),
    vid("zoom-fit-2", "Zoom to Fit again. AX tree (control states).", [{"press": SEG("Zoom to Fit")},
                                                                       {"menu": "View > Zoom to Fit", "fallback": True},
                                                                       {"wait": 1.5}, tree("fit")]),
    vid("controls-hover", "Pointer on the Home control, held 2.5 s (hover, tooltip).",
        [{"hover": BTN("Home")}, {"wait": 2.5}], post=0.5),
    vid("home", "Press Home.", [{"press": BTN("Home")}, {"wait": 2.0}], post=1.5),
    vid("rotate", "Press Rotate (Device Hub: Rotate Right; Ycode: Rotate, left): the rotation animation.",
        [{"press": BTN("Rotate Left|Rotate Right|Rotate (Option-click to rotate right)")}, {"wait": 2.5}], post=1.5),
    vid("rotate-back", "Press it three more times (back to portrait).",
        [{"press": BTN("Rotate Left|Rotate Right|Rotate (Option-click to rotate right)")}, {"wait": 1.5},
         {"press": BTN("Rotate Left|Rotate Right|Rotate (Option-click to rotate right)")}, {"wait": 1.5},
         {"press": BTN("Rotate Left|Rotate Right|Rotate (Option-click to rotate right)")}, {"wait": 2.0}], post=1.5),
    vid("more-actions", "Click More Actions: its menu. Items in -items.json.",
        [{"click": {"role": "AXMenuButton", "description": "More Actions", "visible": True}}, {"wait": 1.2}], post=0.6),
    step("more-actions-walk", "Its sub-menus hovered: a still of each; items.", [{"submenus": "sub", "all_windows": True}],
         record=False, still="none"),
    quiet("more-actions-close", "Escape.", [CLOSE_MENUS, {"wait": 0.5}]),
    vid("inspector-reports", "Inspector ▸ Reports.", [{"press": SEG("Reports")}, {"wait": 1.5}, tree("reports")]),
    vid("inspector-info", "Inspector ▸ Info.", [{"press": SEG("Info")}, {"wait": 1.5}, tree("info")]),
    vid("inspector-settings", "Inspector ▸ Settings. AX tree.", [{"press": SEG("Settings")}, {"wait": 1.5},
                                                                tree("settings")]),
]
for k in range(4):
    dv.append(step(f"settings-popup-{k}", f"Settings inspector pop-up {k}: opened (snap), items, Escape.",
                   [{"click": {"role": "AXPopUpButton", "index": k, "visible": True}}, {"wait": 1.0},
                    {"snap": "menu", "mode": "app", "if_ok": True}, {"submenus": "items", "all_windows": True, "if_ok": True},
                    {"key": "escape", "if_ok": True}, {"wait": 0.4}],
                   record={"video": False, "mode": "app", "margin": 600}, still="none"))
dv += [
    vid("inspector-hide", "View ▸ Inspectors ▸ Hide Inspector.", [{"menu": "View > Inspectors > Hide Inspector"},
                                                                  {"wait": 1.5}]),
    vid("inspector-show", "View ▸ Inspectors ▸ Show Inspector.", [{"menu": "View > Inspectors > Show Inspector"},
                                                                  {"wait": 1.5}]),
    vid("ipad-fit", "Sidebar shown, the iPad selected, sidebar hidden, Zoom to Fit.",
        [{"menu": "View > Show Sidebar"}, {"wait": 1.0}, SEL("ipad"), {"wait": 3.0}, {"menu": "View > Hide Sidebar"},
         {"wait": 1.0}, {"press": SEG("Zoom to Fit")}, {"wait": 1.5}], post=1.0),
    vid("ipad-rotate", "Rotate the iPad.", [{"press": BTN("Rotate Left|Rotate Right|Rotate (Option-click to rotate right)")},
                                           {"wait": 2.5}], post=1.5),
    vid("ipad-rotate-back", "Rotate it three more times.",
        [{"press": BTN("Rotate Left|Rotate Right|Rotate (Option-click to rotate right)")}, {"wait": 1.5},
         {"press": BTN("Rotate Left|Rotate Right|Rotate (Option-click to rotate right)")}, {"wait": 1.5},
         {"press": BTN("Rotate Left|Rotate Right|Rotate (Option-click to rotate right)")}, {"wait": 2.0}], post=1.0),
    vid("watch-fit", "The watch selected, Zoom to Fit. AX tree.",
        [{"menu": "View > Show Sidebar"}, {"wait": 1.0}, SEL("watch"), {"wait": 3.0}, {"menu": "View > Hide Sidebar"},
         {"wait": 1.0}, {"press": SEG("Zoom to Fit")}, {"wait": 1.5}, tree("watch")], post=1.0),
    vid("watch-home", "Press the watch's first hardware control (Home / crown).",
        [{"press": BTN("Home|Digital Crown|Crown")}, {"wait": 2.0}], post=1.0),
    vid("narrow", "Window 700 x 600: the narrow layout.", [{"resize": [700, 600]}, {"wait": 1.5}]),
    vid("wide", "Window 1450 x 900: the wide layout.", [{"move": [30, 40]}, {"resize": [1450, 900]}, {"wait": 1.5}]),
    vid("back-iphone", "Back to 1100 x 800, the iPhone selected.",
        [{"resize": [1100, 800]}, {"menu": "View > Show Sidebar"}, {"wait": 1.0}, SEL("iphone"), {"wait": 3.0}]),
    shot("menubar-end", "Menu bar at the end.", [{"menubar": "end"}]),
]
device = dh_script("parity-c-device", "Part C 3: Device Hub (Ycode: its Device Hub) with three booted simulators "
                   "(iPhone, iPad, watch): sidebar selection, the add-device control, zoom modes, Home, rotation, "
                   "More Actions, the inspector's Settings/Reports/Info, sizes.", dv)

# ---------------------------------------------------------------- C1b Settings: drill-in pages, the Shortcuts filter
DRILL = [("editing", "Editing", "Editing", ["Display", "Completion", "Indentation"]),
         ("behaviors", "Behaviors", "Behaviors", ["Build", "Running"]),
         ("source-control", "Source Control", "Source Control", ["Git settings|Git Settings|Git"])]
s2 = [quiet("settings-open", "cmd+comma, General, moved.", [{"key": "cmd+,"}, {"wait": 2.0}, *pane_select("General", tall=True)])]
for pid, xl, yl in [(d[0], d[1], d[2]) for d in DRILL]:
    pass
for pid, xl, yl, rows in DRILL:
    s2.append(per_app(f"{pid}-pane", f"{xl} pane (710 x 900).", lambda l: [*pane_select(l, tall=True)], shot, xl, yl))
    for r in rows:
        rid = r.split("|")[0].lower().replace(" ", "-")
        first = r.split("|")[0]
        match = {"role": "AXButton|AXRow|AXCell", ("label" if "|" in r else "label~"): r, "visible": True}
        st_ = per_app(f"{pid}-{rid}", f"Click the '{first}' row: the drill-in page (push animation). AX tree. "
                      "(Ycode's rows are static text in Accessibility, so its click targets the row's label.)",
                      lambda l, match=match: [{"click": match, "window": l}, {"wait": 1.5}, tree("page")],
                      vid, xl, yl)
        st_["per_target"]["ycode"]["do"][0] = {"click": {"role": "AXStaticText", "value~": first, "visible": True},
                                               "window": yl}
        s2.append(st_)
        s2.append(per_app(f"{pid}-{rid}-back", "Back (the Go Back button; the window may be titled after the page).",
                          lambda l, first=first: [
                              {"press": {"role": "AXButton", "description": "Go Back|Back"}, "window": first},
                              {"press": {"role": "AXButton", "description": "Go Back|Back"}, "window": l, "fallback": True},
                              {"wait": 1.2}], vid, xl, yl))
s2 += [
    per_app("shortcuts-pane", "Shortcuts pane (710 x 900).", lambda l: [*pane_select(l, tall=True)], shot, "Shortcuts",
            "Shortcuts"),
    per_app("shortcuts-filter", "Click the Shortcuts filter field and type 'build': the filtered list. AX tree.",
            lambda l: [{"click": {"role": "AXTextField", "subrole": "AXSearchField", "visible": True}, "window": l},
                       {"wait": 0.5}, {"text": "build"}, {"wait": 1.5}, tree("filtered")], vid, "Shortcuts", "Shortcuts"),
    per_app("shortcuts-filter-empty", "Type 'qqqzz' more: no results (empty state).",
            lambda l: [{"text": "qqqzz"}, {"wait": 1.5}], vid, "Shortcuts", "Shortcuts"),
    per_app("shortcuts-filter-clear", "Select all and delete (clear the filter).",
            lambda l: [{"key": "cmd+a"}, {"key": "delete"}, {"wait": 1.0}], vid, "Shortcuts", "Shortcuts"),
    quiet("settings-close", "cmd+W.", [{"key": "cmd+w"}, {"wait": 0.8}]),
]
settings2 = script("parity-c-settings2", "Part C 1b: Settings drill-in pages (Editing ▸ Display / Completion / "
                   "Indentation, Behaviors ▸ Build / Running, Source Control ▸ Git settings) with Back, and the "
                   "Shortcuts filter with results, no results and cleared.", s2)

if __name__ == "__main__":
    for s in SCRIPTS:
        (HERE / f"{s['name']}.json").write_text(json.dumps(s, indent=1, ensure_ascii=False) + "\n")
        print(s["name"], len(s["steps"]), "steps")
