#!/usr/bin/env python3
"""Writes the parity run's part A session scripts (parity-a-*.json) next to
this file. Part A: launch, Welcome window, New Project, window chrome and
toolbar, every menu and sub-menu, navigators, window behaviours.

    python3 -I research/tools/capture/scripts/parity-a-gen.py
"""
import json
import pathlib

HERE = pathlib.Path(__file__).resolve().parent
REC = {"fps": 120, "codec": "hevc", "pre": 0.5, "post": 1.2}
APP = {"mode": "app", "margin": 600}       # every window of the app on the built-in display
PANEL_DIR = "/private/tmp/ycode-parity-a/panel"


def script(name, title, steps, project=True, window=None, setup=None, per_target_setup=None):
    s = {"name": name, "title": title, "targets": ["xcode", "ycode"], "compare_order": ["xcode", "ycode"],
         "focus": "foreground", "launch_settle": 3.0, "record": REC, "steps": steps}
    if project:
        s["project"] = {"generator": "make-test-project.py", "path": "GlassScroll/GlassScroll.xcodeproj"}
        s["window"] = window or {"size": [1400, 880], "display": "builtin", "title": "{project}", "timeout": 90}
    else:
        s["project_targets"] = []
        s["window"] = window or {"size": None, "display": "builtin", "title": "Welcome to {app}", "timeout": 60}
    if setup:
        s["setup"] = setup
    if per_target_setup:
        s["per_target_setup"] = per_target_setup
    return s


def step(sid, note, do=(), record=None, still="both", **extra):
    s = {"id": sid, "note": note, "do": list(do)}
    if record is not None:
        s["record"] = record
    s["still"] = still
    s.update(extra)
    return s


def tree(name):
    return {"tree": name, "depth": 40}


def tab_walk(sid, note, count, key="tab"):
    do = []
    for i in range(1, count + 1):
        do += [{"key": key}, {"wait": 0.4}, {"snap": f"k{i:02d}", "mode": "app"}, tree(f"k{i:02d}")]
    return step(sid, note, do, record=False, still="none")


def esc_or_cancel():
    return [{"press": {"role": "AXButton", "title": "Cancel", "scope": "app"}}, {"key": "escape", "fallback": True}]


MB = lambda title: {"role": "AXMenuBarItem", "title": title, "scope": "app"}
MI = lambda title: {"role": "AXMenuItem", "title": title, "scope": "app", "visible": True}

PANEL_SETUP = {"ycode": [{"run": ["defaults", "write", "io.github.MarcoDotIO.Ycode.capture",
                                  "NSNavLastRootDirectory", PANEL_DIR]}]}

# ---------------------------------------------------------------- A1 Welcome
welcome = script("parity-a-welcome", "Part A 1: launch to the Welcome window, its buttons' hover, tooltips and "
                 "key-view order, the New Project menu, the Open panel and the Clone window (all cancelled). Clone "
                 "comes last: Xcode closes the Welcome window when its Clone window opens.", [
    step("rest", "The Welcome window at rest after launch (no project). AX tree and the whole menu bar.",
         [tree("welcome"), {"menubar": "welcome"}], record=False, still="after"),
    tab_walk("tab-order", "Tab through the Welcome window: a still and AX tree after each Tab (focus ring, "
             "key-view order).", 6),
    step("hover-open", "Pointer onto Open…, held 2.2 s (hover state, tooltip).",
         [{"hover": {"label": "Open…", "scope": "app"}}, {"wait": 2.2}], record={**APP, "post": 0.6}),
    step("hover-clone", "Pointer onto Clone…, held 2.2 s.",
         [{"hover": {"label": "Clone…", "scope": "app"}}, {"wait": 2.2}], record={**APP, "post": 0.6}),
    step("hover-new", "Pointer onto New Project (a menu button), held 2.2 s.",
         [{"hover": {"label": "New Project", "role": "AXMenuButton", "scope": "app"}}, {"wait": 2.2}],
         record={**APP, "post": 0.6}),
    step("hover-close", "Pointer onto the close (x) button, held 2.2 s.",
         [{"hover": {"role": "AXButton", "description": "Close", "scope": "app"}}, {"wait": 2.2}],
         record={**APP, "post": 0.6}),
    step("hover-out", "Pointer off the buttons (onto the version text).",
         [{"hover": {"role": "AXStaticText", "value~": "Version", "scope": "app"}}], record={**APP, "post": 0.8}),
    step("new-menu", "Click New Project: its menu opens (animation). AX tree.",
         [{"click": {"label": "New Project", "role": "AXMenuButton", "scope": "app"}}, {"wait": 0.8},
          tree("new-menu")], record={**APP, "post": 0.8}),
    step("new-menu-keys", "Keyboard in the open menu: Down, Down, then Escape (stills after each).",
         [{"key": "down"}, {"wait": 0.3}, {"snap": "down1", "mode": "app"}, {"key": "down"}, {"wait": 0.3},
          {"snap": "down2", "mode": "app"}, {"key": "escape"}, {"wait": 0.5}, {"snap": "escaped", "mode": "app"}],
         record=False, still="none"),
    step("open", "Click Open…: the open panel (it starts in a folder of test projects; its sidebar is painted out "
         "afterwards). AX tree.", [{"click": {"label": "Open…", "scope": "app"}}, {"wait": 2.0},
                                   tree("open-panel")], record={**APP, "post": 1.0}),
    tab_walk("open-tab-order", "Tab through the open panel (key-view order).", 4),
    step("open-cancel", "Cancel the open panel.", esc_or_cancel(), record={**APP, "post": 1.0}),
    step("welcome-again", "Window ▸ Welcome (cmd+shift+1), in case the panel closed the Welcome window.",
         [{"key": "cmd+shift+1"}, {"wait": 1.0}], record={**APP, "post": 0.6}),
    step("clone", "Click Clone…: the Clone window or sheet appears (animation). AX tree.",
         [{"click": {"label": "Clone…", "scope": "app"}}, {"wait": 1.5}, tree("clone")], record={**APP, "post": 1.0}),
    tab_walk("clone-tab-order", "Tab through the Clone UI (key-view order).", 5),
    step("clone-cancel", "Cancel the Clone UI (Cancel button, else Escape).", esc_or_cancel(), record={**APP, "post": 1.0}),
    step("after-clone", "What is left on screen after cancelling Clone.", [{"wait": 0.5}, tree("after-clone")],
         record=False, still="after"),
], project=False, per_target_setup=PANEL_SETUP)

# ---------------------------------------------------------------- A2 New Project
PLATFORMS = ["iOS", "macOS", "watchOS", "tvOS", "visionOS", "Multiplatform"]
newproj = [
    step("quick-open", "File ▸ New ▸ Project… by its shortcut (cmd+shift+N) from the Welcome window: what opens "
         "(Xcode 27.1: a quick New Project panel). AX tree.",
         [{"key": "cmd+shift+n"}, {"wait": 2.0}, tree("quick")], record={**APP, "post": 1.0}),
    step("quick-keys", "Keyboard in that panel: Down twice (selection), then type 'Play' (filter).",
         [{"key": "down"}, {"wait": 0.3}, {"snap": "down1", "mode": "app"}, {"key": "down"}, {"wait": 0.3},
          {"snap": "down2", "mode": "app"}, {"text": "Play"}, {"wait": 0.8}, {"snap": "typed", "mode": "app"},
          tree("typed")], record=False, still="none"),
    step("quick-escape", "Escape closes it.", [{"key": "escape"}], record={**APP, "post": 1.0}),
    step("quick-reopen", "cmd+shift+N again.", [{"key": "cmd+shift+n"}, {"wait": 1.5}], record={**APP, "post": 0.6}),
    step("choose-template", "Choose Template… (the full template chooser; animation). AX tree.",
         [{"click": {"role": "AXRow", "text": "Choose Template…", "scope": "app"}},
          {"key": "escape", "fallback": True}, {"wait": 2.0}, tree("chooser")], record={**APP, "post": 1.0}),
]
for p in PLATFORMS:
    newproj.append(step(f"tab-{p.lower()}", f"Click the {p} platform tab in the template chooser.",
                        [{"click": {"role": "AXRadioButton", "label": p, "scope": "app", "visible": True}},
                         {"click": {"label": p, "scope": "app", "visible": True}, "fallback": True}, {"wait": 0.6}],
                        record={**APP, "post": 0.8}))
newproj += [
    step("tab-macos-again", "Back to macOS.", [{"click": {"role": "AXRadioButton", "label": "macOS", "scope": "app",
                                                          "visible": True}},
                                               {"click": {"label": "macOS", "scope": "app", "visible": True},
                                                "fallback": True}, {"wait": 0.6}, tree("macos")],
         record={**APP, "post": 0.6}),
    step("select-app", "Select the App template (click).",
         [{"click": {"role": "AXCell", "text": "App", "scope": "app", "visible": True}},
          {"click": {"text": "App", "scope": "app", "visible": True}, "fallback": True}],
         record={**APP, "post": 0.8}),
    step("template-keys", "Arrow keys in the template grid: Right, Right, Left (stills).",
         [{"key": "right"}, {"wait": 0.3}, {"snap": "r1", "mode": "app"}, {"key": "right"}, {"wait": 0.3},
          {"snap": "r2", "mode": "app"}, {"key": "left"}, {"key": "left"}, {"wait": 0.3}, {"snap": "back", "mode": "app"}],
         record=False, still="none"),
    tab_walk("chooser-tab-order", "Tab through the template chooser (key-view order).", 6),
    step("next", "Next: the options page (transition). AX tree (names in it are scrubbed afterwards).",
         [{"press": {"role": "AXButton", "title": "Next", "scope": "app"}}, {"wait": 1.5}, tree("options")],
         record={**APP, "post": 1.0}),
]
# Ycode has no cmd+shift+N at the Welcome window (finding of the first run): it goes through the Welcome
# window's New Project menu instead, so the template chooser is still compared.
NEWMENU = {"label": "New Project", "role": "AXMenuButton", "scope": "app"}
YC = {
    "quick-open": [{"key": "cmd+shift+n"}, {"wait": 2.0}, tree("quick"), {"click": NEWMENU}, {"wait": 1.0}],
    "quick-escape": [{"key": "escape"}],
    "quick-reopen": [{"click": NEWMENU}, {"wait": 1.0}],
    # Ycode opens the new project's window on the main display, not on the display of the Welcome window
    # (a finding): it is moved to where Xcode put its own (56, 57 on the built-in display) for the next steps.
    "choose-template": [{"click": MI("Choose Template…")}, {"wait": 2.0}, {"move": [56, 57], "window": "Untitled"},
                        {"wait": 1.0}, tree("chooser")],
}
for st in newproj:
    if st["id"] in YC:
        st["per_target"] = {"ycode": {"do": YC[st["id"]], "note": st["note"] + " Ycode: cmd+shift+N first (nothing "
                                      "happens), then the Welcome window's New Project menu."}}
newproject = script("parity-a-newproject", "Part A 2: the New Project assistant up to its options page.", newproj,
                    project=False)

for s in (welcome, newproject):
    (HERE / f"{s['name']}.json").write_text(json.dumps(s, indent=1, ensure_ascii=False) + "\n")
    print(s["name"], len(s["steps"]), "steps")

# ---------------------------------------------------------------- A3 menus
CLOSE_MENUS = {"key": "escape escape escape"}
MENUS = [
    ("{app}", ["Behaviors", "Open Developer Tool", "Services"]),
    ("File", ["New", "Open Recent", "Packages"]),
    ("Edit", ["Sort", "Format", "Convert"]),
    ("View", ["Editor", "Navigators", "Debug Area", "Inspectors"]),
    ("Find", []),
    ("Navigate", []),
    ("Editor", ["Structure", "Code Folding", "Syntax Coloring", "Canvas", "Minimap"]),
    ("Product", ["Build For", "Perform Action", "Scheme", "Destination", "Test Plan"]),
    ("Debug", ["Breakpoints", "Console", "Debug Workflow", "Simulate Location"]),
    ("Integrate", []),
    ("Window", ["Move & Resize"]),
    ("Help", []),
]
menu_steps = [step("rest", "The workspace window at rest, Long.swift not open. The whole menu bar (titles, key "
                   "equivalents, enabled state, checkmarks) through Accessibility.",
                   [{"menubar": "workspace"}], record=False, still="after")]
for title, subs in MENUS:
    key = "app" if title == "{app}" else title.lower()
    menu_steps.append(step(f"{key}-open", f"Open the {title} menu by clicking its menu bar title (animation); the "
                           "after still is the whole menu.", [{"click": MB(title)}, {"wait": 0.5}],
                           record={**APP, "post": 0.8}))
    for sub in subs:
        menu_steps.append(step(f"{key}-{sub.lower().replace(' & ', '-').replace(' ', '-')}",
                               f"Hover {title} ▸ {sub}: its sub-menu cascades open (or, if it is a plain item, its "
                               "highlight).", [{"hover": MI(sub)}, {"wait": 0.4}], record={**APP, "post": 0.9}))
    if subs:
        menu_steps.append(step(f"{key}-diagonal", f"Diagonal pointer move from {title} ▸ {subs[0]} into its sub-menu "
                               "(right 220 pt, down 90 pt over 0.35 s) then onto the sibling item: does the sub-menu "
                               "stay open, and how do siblings switch?",
                               [{"hover": MI(subs[0])}, {"wait": 0.7},
                                {"glide": {"from": MI(subs[0]), "to": MI(subs[0]), "to_dx": 220, "to_dy": 90},
                                 "duration": 0.35}, {"wait": 0.6},
                                {"hover": MI(subs[-1] if len(subs) > 1 else subs[0])}, {"wait": 0.7}],
                               record={**APP, "post": 0.8}))
        menu_steps.append(step(f"{key}-walk", f"Every enabled sub-menu of {title}, hovered one by one: a still of each "
                               "cascade (no video).", [{"submenus": "sub", "wait": 0.8}], record=False, still="none"))
    menu_steps.append(step(f"{key}-close", f"Escape closes the {title} menu.", [CLOSE_MENUS, {"wait": 0.4}],
                           record=False, still="after"))
menu_steps += [
    step("bar-slide", "Open File, then slide the pointer along the menu bar to Edit and View: menu switching.",
         [{"click": MB("File")}, {"wait": 0.6}, {"hover": MB("Edit")}, {"wait": 0.6}, {"hover": MB("View")},
          {"wait": 0.6}], record={**APP, "post": 0.8}),
    step("bar-slide-close", "Escape.", [CLOSE_MENUS], record=False, still="after"),
    step("keys-file", "Keyboard in the File menu: open it, Down ×3, Right (into a sub-menu if any), Down, Left, "
         "Escape: stills after each.",
         [{"click": MB("File")}, {"wait": 0.5}, {"snap": "open", "mode": "app"}]
         + [x for i in range(1, 4) for x in ({"key": "down"}, {"wait": 0.25}, {"snap": f"down{i}", "mode": "app"})]
         + [{"key": "up"}, {"key": "up"}, {"wait": 0.2}, {"key": "right"}, {"wait": 0.5}, {"snap": "right", "mode": "app"},
            {"key": "down"}, {"wait": 0.25}, {"snap": "sub-down", "mode": "app"}, {"key": "left"}, {"wait": 0.4},
            {"snap": "left", "mode": "app"}, {"key": "escape"}, {"wait": 0.4}, {"snap": "escape1", "mode": "app"},
            CLOSE_MENUS], record=False, still="none"),
    step("keys-typeselect", "Type-select in the open Edit menu: type 'f' (moves to the first item starting with F?).",
         [{"click": MB("Edit")}, {"wait": 0.5}, {"text": "f"}, {"wait": 0.4}, {"snap": "f", "mode": "app"},
          CLOSE_MENUS], record=False, still="none"),
    step("help-search", "Help menu: type 'scheme' into its search field (results appear).",
         [{"click": MB("Help")}, {"wait": 0.6}, {"text": "scheme"}, {"wait": 1.5}], record={**APP, "post": 1.0}),
    step("help-search-hover", "Down arrow onto the first result (the menu item is pointed at in its menu).",
         [{"key": "down"}, {"wait": 1.2}], record={**APP, "post": 0.8}),
    step("help-close", "Escape.", [CLOSE_MENUS, {"wait": 0.3}, CLOSE_MENUS], record=False, still="after"),
    step("menubar-after", "The whole menu bar again after every menu has been opened once (Xcode fills some "
         "menus, Editor among them, only when they open).", [{"menubar": "after-tour"}], record=False, still="none"),
]
menus = script("parity-a-menus", "Part A 3: every top-level menu opened by mouse, every sub-menu, diagonal moves, "
               "menu-bar sliding, keyboard navigation, the Help search field.", menu_steps)

# ---------------------------------------------------------------- A4 toolbar and workspace
TB = lambda d: {"role": "AXButton", "description": d}
ws = [
    step("first-launch", "The workspace window as first opened (first-launch layout). AX tree and menu bar.",
         [tree("workspace"), {"menubar": "workspace"}], record=False, still="after"),
    tab_walk("tab-order", "Tab through the workspace window (key-view order).", 10),
]
for sid, match, note in [
    ("hover-navigators", {"role": "AXRadioButton|AXCheckBox", "description": "Navigators"}, "the navigator toggle"),
    ("hover-assistant", {"description": "Coding Assistant"}, "the coding assistant button"),
    ("hover-run", TB("Run"), "Run"),
    ("hover-stop", TB("Stop"), "Stop (disabled)"),
    ("hover-back", TB("Go Back"), "Go Back (disabled)"),
    ("hover-activity", {"description": "Window Title/Activity|Ycode project"}, "the activity area / title"),
    ("hover-new-conversation", TB("New Conversation"), "New Conversation"),
    ("hover-scheme", {"label": "Active Scheme", "role": "AXPopUpButton"}, "the scheme pop-up"),
    ("hover-destination", {"label": "Active Run Destination", "role": "AXPopUpButton"}, "the destination pop-up"),
    ("hover-add-editor", {"description": "Add Editor"}, "Add Editor"),
    ("hover-editor-options", {"description": "Editor Options"}, "Editor Options"),
    ("hover-canvas", {"description": "Canvas"}, "the Canvas segment"),
    ("hover-inspector", {"description": "Hide Inspector|Show Inspector"}, "the inspector toggle"),
]:
    ws.append(step(sid, f"Pointer onto {note}, held 2.2 s: hover state and tooltip.",
                   [{"hover": match}, {"wait": 2.2}], record={**APP, "post": 0.5}))
ws += [
    step("hover-off", "Pointer off the toolbar (onto the editor).", [{"hover": [800, 500]}], record={**APP, "post": 0.6}),
    step("scheme-menu", "Click the scheme pop-up: its menu (animation). AX tree.",
         [{"click": {"label": "Active Scheme", "role": "AXPopUpButton"}}, {"wait": 0.8}, tree("scheme-menu")],
         record={**APP, "post": 0.8}),
    step("scheme-menu-walk", "Sub-menus of the scheme menu, if any.", [{"submenus": "sub", "all_windows": True}],
         record=False, still="none"),
    step("edit-scheme", "Choose Edit Scheme… in that menu: the scheme editor sheet (animation). AX tree.",
         [{"menuclick": "Edit Scheme…"}, {"wait": 1.5}, tree("scheme-sheet")],
         record={**APP, "post": 1.0}),
    tab_walk("edit-scheme-tabs", "Tab through the scheme editor (key-view order).", 6),
    step("edit-scheme-close", "Close it (Close or Cancel, else Escape).",
         [{"press": {"role": "AXButton", "title": "Close|Cancel|Done", "scope": "app"}},
          {"key": "escape", "fallback": True}], record={**APP, "post": 1.0}),
    step("manage-schemes", "Scheme pop-up ▸ Manage Schemes…: the sheet (animation). AX tree.",
         [{"click": {"label": "Active Scheme", "role": "AXPopUpButton"}}, {"wait": 0.7},
          {"menuclick": "Manage Schemes…"}, {"wait": 1.5}, tree("manage")],
         record={**APP, "post": 1.0}),
    step("manage-schemes-close", "Close it.",
         [{"press": {"role": "AXButton", "title": "Close|Cancel|Done|OK", "scope": "app"}},
          {"key": "escape", "fallback": True}], record={**APP, "post": 1.0}),
    # The scheme pop-up of Xcode 27.1 is a popover (Filter, schemes, Edit/New/Manage Scheme…), not a menu, and
    # Ycode's holds only the scheme (finding of the first run), so the two sheets are opened from the menu bar too.
    step("edit-scheme-menubar", "Product ▸ Scheme ▸ Edit Scheme… (menu bar): the scheme editor sheet. AX tree.",
         [{"menu": "Product > Scheme > Edit Scheme…"}, {"wait": 1.5}, tree("scheme-sheet")], record={**APP, "post": 1.0}),
    tab_walk("edit-scheme-menubar-tabs", "Tab through the scheme editor (key-view order).", 6),
    step("edit-scheme-menubar-close", "Close it (Close, else Escape).",
         [{"press": {"role": "AXButton", "title": "Close|Cancel|Done", "scope": "app"}},
          {"key": "escape", "fallback": True}], record={**APP, "post": 1.0}),
    step("manage-schemes-menubar", "Product ▸ Scheme ▸ Manage Schemes… (menu bar): the sheet. AX tree.",
         [{"menu": "Product > Scheme > Manage Schemes…"}, {"wait": 1.5}, tree("manage")], record={**APP, "post": 1.0}),
    step("manage-schemes-menubar-close", "Close it.",
         [{"press": {"role": "AXButton", "title": "Close|Cancel|Done|OK", "scope": "app"}},
          {"key": "escape", "fallback": True}], record={**APP, "post": 1.0}),
    step("destination-menu", "Click the run destination pop-up: its menu (animation). AX tree.",
         [{"click": {"label": "Active Run Destination", "role": "AXPopUpButton"}}, {"wait": 0.8},
          tree("destination-menu")], record={**APP, "post": 0.8}),
    step("destination-walk", "Every sub-menu of the destination menu, hovered: a still of each.",
         [{"submenus": "sub", "all_windows": True}], record=False, still="none"),
    step("destination-close", "Escape.", [CLOSE_MENUS], record={**APP, "post": 0.8}),
    step("activity-click", "Click the activity area (title / status in the middle of the toolbar).",
         [{"click": {"description": "Window Title/Activity|Ycode project"}}, {"wait": 1.0}, tree("activity")],
         record={**APP, "post": 1.0}),
    step("activity-close", "Escape (closes whatever opened).", [{"key": "escape"}], record={**APP, "post": 0.8}),
    # The coding assistant button is hovered only (above), never clicked: its panel can show sign-in and account
    # screens, which must not be captured.
    step("library-open", "View ▸ Show Library (cmd+shift+L): the Library panel (animation). AX tree.",
         [{"key": "cmd+shift+l"}, {"wait": 1.5}, tree("library")], record={**APP, "post": 1.0}),
    tab_walk("library-tabs", "Tab inside the Library (key-view order).", 4),
    step("library-close", "Escape closes the Library.", [{"key": "escape"}], record={**APP, "post": 0.8}),
    step("inspector-hide", "Click Hide Inspector (animation).", [{"click": {"description": "Hide Inspector"}}],
         record={**APP, "post": 1.0}),
    step("inspector-show", "Click Show Inspector (animation).", [{"click": {"description": "Show Inspector"}}],
         record={**APP, "post": 1.0}),
    step("navigator-hide", "Click the Navigators toggle to hide the navigator (animation).",
         [{"click": {"description": "Navigators"}}], record={**APP, "post": 1.0}),
    step("navigator-show", "Click it again to show the navigator.",
         [{"click": {"description": "Navigators"}}], record={**APP, "post": 1.0}),
    step("run", "Click Run: the macOS test app builds and runs (activity area progress, Run/Stop states).",
         [{"click": TB("Run")}, {"wait": 6.0}], record={**APP, "post": 0.5}),
    step("running", "While it runs (or after the build): toolbar and activity area.", [{"wait": 4.0}, tree("running")],
         record=False, still="after"),
    step("stop", "Click Stop (cmd+. if the button is not enabled).",
         [{"click": TB("Stop")}, {"key": "cmd+.", "fallback": True}, {"wait": 1.5}], record={**APP, "post": 1.0}),
]
workspace = script("parity-a-workspace", "Part A 4: the workspace window, toolbar items one by one: hover, tooltip "
                   "and press; scheme and destination menus, Edit/Manage Schemes, activity area, coding assistant "
                   "button, Library, navigator and inspector toggles, Run and Stop.", ws)

for s in (menus, workspace):
    (HERE / f"{s['name']}.json").write_text(json.dumps(s, indent=1, ensure_ascii=False) + "\n")
    print(s["name"], len(s["steps"]), "steps")

# ---------------------------------------------------------------- A5 navigators
NAVS = [("project", "Show the Project navigator"), ("source-control", "Show the Source Control navigator"),
        ("bookmarks", "Show the Bookmark navigator"), ("find", "Show the Find navigator"),
        ("issues", "Show the Issue navigator"), ("tests", "Show the Test navigator"),
        ("debug", "Show the Debug Navigator"), ("breakpoints", "Show the Breakpoints Navigator"),
        ("reports", "Show the Report navigator")]
ROW = lambda name: {"role": "AXRow", "text": f"{name}|{name}.swift" if "." not in name else name}
FILTER = {"subrole": "AXSearchField", "index": 0}
nav = [step("rest", "The project navigator at rest. AX tree.", [tree("rest")], record=False, still="after")]
for i, (nid, _) in enumerate(NAVS, 1):
    nav.append(step(f"cmd{i}-{nid}", f"cmd+{i}: the {nid} navigator (switch animation). AX tree.",
                    [{"key": f"cmd+{i}"}, {"wait": 0.6}, tree(nid)], record={**APP, "post": 1.0}))
for nid, helptext in [NAVS[0]] + NAVS[1:]:
    nav.append(step(f"click-{nid}", f"Pointer onto the {nid} navigator tab (1.6 s: hover, tooltip), then click it.",
                    [{"hover": {"help": helptext}}, {"wait": 1.6}, {"click": {"help": helptext}}],
                    record={**APP, "post": 0.9}))
nav.append(step("click-project-again", "Back to the project navigator by clicking its tab.",
                [{"click": {"help": NAVS[0][1]}}], record={**APP, "post": 0.8}))
nav += [
    step("filter-type", "Click the navigator's filter field and type 'Model1' (rows filter).",
         [{"click": FILTER}, {"wait": 0.3}, {"text": "Model1"}, {"wait": 0.8}], record={**APP, "post": 1.0},
         per_target={"xcode": {"do": [{"click": {"description": "Project navigator filter"}}, {"wait": 0.3},
                                      {"text": "Model1"}, {"wait": 0.8}]}}),
    step("filter-empty", "Replace the filter text with 'zzzz': the empty state.",
         [{"key": "cmd+a"}, {"text": "zzzz"}, {"wait": 1.0}, tree("filter-empty")], record={**APP, "post": 1.0}),
    step("filter-clear", "Clear the filter (cmd+A, Delete), then Escape.",
         [{"key": "cmd+a delete"}, {"wait": 0.6}, {"key": "escape"}], record={**APP, "post": 1.0}),
    step("filter-options", "The filter field's options menu (the control at the field's left end).",
         [{"click": {"description": "Filter options"}}, {"wait": 0.8}, tree("filter-options")],
         record={**APP, "post": 0.8},
         per_target={"xcode": {"do": [{"click": {"description": "Icon View Drop Down"}}, {"wait": 0.8},
                                      tree("filter-options")]}}),
    step("filter-options-close", "Escape.", [CLOSE_MENUS], record=False, still="after"),
    step("bottom-action-menu", "The bottom bar's leftmost button (+ / options menu).",
         [{"click": {"description": "Options"}}, {"wait": 0.8}, tree("action-menu")], record={**APP, "post": 0.8},
         per_target={"xcode": {"do": [{"click": {"identifier": "filterControlBarActionMenuButton"}}, {"wait": 0.8},
                                      tree("action-menu")]}}),
    step("bottom-action-walk", "Its sub-menus, if any.", [{"submenus": "sub", "all_windows": True}],
         record=False, still="none"),
    step("bottom-action-close", "Escape.", [CLOSE_MENUS], record=False, still="after"),
    step("recent-files-on", "Bottom bar: the Recent files toggle on (hover 1.6 s first).",
         [{"hover": {"label": "Recent files"}}, {"wait": 1.6}, {"click": {"label": "Recent files"}}, {"wait": 0.6}],
         record={**APP, "post": 0.8}),
    step("recent-files-off", "Recent files toggle off.", [{"click": {"label": "Recent files"}}],
         record={**APP, "post": 0.8}),
    step("scm-status-on", "Bottom bar: the source-control status toggle on (hover 1.6 s first).",
         [{"hover": {"label": "Files with source-control status"}}, {"wait": 1.6},
          {"click": {"label": "Files with source-control status"}}, {"wait": 0.6}], record={**APP, "post": 0.8}),
    step("scm-status-off", "Source-control status toggle off.",
         [{"click": {"label": "Files with source-control status"}}], record={**APP, "post": 0.8}),
    step("ctx-file", "Right-click Long.swift: the file's context menu (animation). AX tree.",
         [{"click": ROW("Long"), "button": "right"}, {"wait": 0.8}, tree("ctx-file")], record={**APP, "post": 0.8}),
    step("ctx-file-walk", "Every sub-menu of that context menu, hovered: a still of each.",
         [{"submenus": "sub", "all_windows": True}], record=False, still="none"),
    step("ctx-file-close", "Escape.", [CLOSE_MENUS], record=False, still="after"),
    step("ctx-group", "Right-click the Models group: its context menu.",
         [{"click": {"role": "AXRow", "text": "Models"}, "button": "right"}, {"wait": 0.8}, tree("ctx-group")],
         record={**APP, "post": 0.8}),
    step("ctx-group-close", "Escape.", [CLOSE_MENUS], record=False, still="after"),
    step("ctx-project", "Right-click the project row (GlassScroll, the first row): its context menu.",
         [{"click": {"role": "AXRow", "text": "GlassScroll", "index": 0}, "button": "right"}, {"wait": 0.8},
          tree("ctx-project")], record={**APP, "post": 0.8}),
    step("ctx-project-close", "Escape.", [CLOSE_MENUS], record=False, still="after"),
    step("rename", "Select Bands.swift, press Return: inline rename (field, selection of the name).",
         [{"click": ROW("Bands")}, {"wait": 0.5}, {"key": "return"}, {"wait": 0.8}, tree("rename")],
         record={**APP, "post": 0.8}),
    step("rename-cancel", "Escape cancels the rename.", [{"key": "escape"}], record={**APP, "post": 0.8}),
    step("collapse-plain", "Select the Plain group and press Left: it collapses (disclosure animation).",
         [{"click": ROW("Plain")}, {"wait": 0.4}, {"key": "left"}], record={**APP, "post": 1.0}),
    step("expand-plain", "Right: it expands again.", [{"key": "right"}], record={**APP, "post": 1.0}),
    step("disclose-click", "Click the Models group's disclosure triangle (expand, animation).",
         [{"click": {"role": "AXDisclosureTriangle", "index": 2}}], record={**APP, "post": 1.0}),
    step("disclose-click-back", "Click it again (collapse).",
         [{"click": {"role": "AXDisclosureTriangle", "index": 2}}], record={**APP, "post": 1.0}),
    step("keys-outline", "Keyboard in the outline: select Bands.swift, Down ×3, Up, then type-select 'lo' "
         "(Long.swift): stills after each.",
         [{"click": ROW("Bands")}, {"wait": 0.3}]
         + [x for i in range(1, 4) for x in ({"key": "down"}, {"wait": 0.3}, {"snap": f"down{i}", "mode": "app"})]
         + [{"key": "up"}, {"wait": 0.3}, {"snap": "up", "mode": "app"}, {"text": "lo"}, {"wait": 0.6},
            {"snap": "typeselect", "mode": "app"}], record=False, still="none"),
    step("multi-select", "Select Bands.swift, then shift+Down twice: three rows selected.",
         [{"click": ROW("Bands")}, {"wait": 0.3}, {"key": "shift+down"}, {"wait": 0.2}, {"key": "shift+down"},
          {"wait": 0.4}, tree("multi")], record={**APP, "post": 0.8}),
    step("new-group", "Select Zeta.swift (in the plain group Plain), then File ▸ New ▸ Group (cmd+option+N): the "
         "new group and its inline name field.",
         [{"click": ROW("Zeta")}, {"wait": 0.4}, {"key": "cmd+alt+n"}, {"wait": 1.0}, tree("new-group")],
         record={**APP, "post": 1.0}),
    step("new-group-undo", "Escape, then Undo (cmd+Z) removes the group.",
         [{"key": "escape"}, {"wait": 0.5}, {"key": "cmd+z"}, {"wait": 0.8}], record={**APP, "post": 1.0}),
    step("new-file", "File ▸ New ▸ File (cmd+N) with Zeta.swift selected: what opens (animation). AX tree.",
         [{"click": ROW("Zeta")}, {"wait": 0.3}, {"key": "cmd+n"}, {"wait": 1.5}, tree("new-file")],
         record={**APP, "post": 1.0}),
    tab_walk("new-file-tabs", "Tab through it (key-view order).", 4),
    step("new-file-cancel", "Cancel it (Cancel, else Escape).", esc_or_cancel(), record={**APP, "post": 1.0}),
    step("drag-reorder", "Drag Zeta.swift below Beta.swift inside the plain group Plain (drop indicator, row "
         "animation).", [{"drag": {"from": ROW("Zeta"), "to": ROW("Beta"), "to_dy": 8}, "duration": 1.0},
                         {"wait": 0.8}], record={**APP, "post": 1.0}),
    step("drag-undo", "Undo (cmd+Z): the order comes back.", [{"key": "cmd+z"}, {"wait": 0.8}],
         record={**APP, "post": 1.0}),
]
navigators = script("parity-a-navigators", "Part A 5: every navigator by cmd+1…9 and by click, the filter field and "
                    "its menus, bottom bar, context menus, rename, disclosure, keyboard, multi-select, New Group, "
                    "New File, drag to reorder.", nav)

# ---------------------------------------------------------------- A6 window behaviours
win = [
    step("rest", "1400 × 880 at rest.", [tree("rest")], record=False, still="after"),
    step("drag-narrower", "Drag the window's right edge 600 pt to the left over 1.2 s (live layout, toolbar "
         "overflow).", [{"drag": {"from": [1399, 500], "to": [799, 500]}, "duration": 1.2}, {"wait": 0.5}],
         record={**APP, "post": 1.0}),
    step("narrow-tree", "At about 800 pt: AX tree (which toolbar items moved to the overflow).", [tree("narrow")],
         record=False, still="after"),
    step("overflow-menu", "Click the toolbar overflow (») button if there is one: its menu.",
         [{"click": {"role": "AXButton|AXMenuButton|AXPopUpButton", "description~": "overflow|more|Show More"}},
          {"click": {"role": "AXButton", "subrole": "AXToolbarOverflowButton"}, "fallback": True}, {"wait": 0.8}],
         record={**APP, "post": 0.8}),
    step("overflow-close", "Escape.", [CLOSE_MENUS], record=False, still="after"),
    step("resize-640", "Set the window to 640 × 880 (very narrow) through Accessibility.", [{"resize": [640, 880]},
                                                                                          {"wait": 0.8}],
         record={**APP, "post": 0.8}),
    step("resize-640-tree", "At 640 pt: AX tree.", [tree("w640")], record=False, still="after"),
    step("drag-wider", "Drag the right edge from 640 to 1490 pt over 1.2 s (very wide on this display).",
         [{"drag": {"from": [639, 500], "to": [1489, 500]}, "duration": 1.2}, {"wait": 0.5}],
         record={**APP, "post": 1.0}),
    step("wide-tree", "Wide: AX tree.", [tree("wide")], record=False, still="after"),
    step("resize-back", "Back to 1400 × 880.", [{"resize": [1400, 880]}, {"wait": 0.8}], record={**APP, "post": 0.6}),
    step("hide-navigator", "cmd+0: hide the navigator (animation).", [{"key": "cmd+0"}], record={**APP, "post": 1.0}),
    step("show-navigator", "cmd+0: show it again.", [{"key": "cmd+0"}], record={**APP, "post": 1.0}),
    step("hide-inspector", "cmd+option+0: hide the inspector (animation).", [{"key": "cmd+alt+0"}],
         record={**APP, "post": 1.0}),
    step("show-inspector", "cmd+option+0: show it again.", [{"key": "cmd+alt+0"}], record={**APP, "post": 1.0}),
    step("hide-both", "Both hidden (cmd+0 then cmd+option+0): editor only.",
         [{"key": "cmd+0"}, {"wait": 0.6}, {"key": "cmd+alt+0"}], record={**APP, "post": 1.0}),
    step("show-both", "Both shown again.", [{"key": "cmd+0"}, {"wait": 0.6}, {"key": "cmd+alt+0"}],
         record={**APP, "post": 1.0}),
    step("new-tab", "cmd+T: a new window tab (tab bar appears, animation). AX tree.",
         [{"key": "cmd+t"}, {"wait": 1.2}, tree("tab")], record={**APP, "post": 1.0}),
    step("tab-hover", "Pointer onto the first tab of the tab bar (hover, close button), 1.6 s.",
         [{"hover": {"role": "AXRadioButton", "subrole": "AXTabButton", "index": 0}}, {"wait": 1.6}],
         record={**APP, "post": 0.5}),
    step("close-tab", "cmd+W closes the new tab (tab bar disappears).", [{"key": "cmd+w"}, {"wait": 0.8}],
         record={**APP, "post": 1.0}),
    step("new-window", "File ▸ New ▸ Window (cmd+shift+T): a second workspace window (where it appears, "
         "animation). AX tree.", [{"key": "cmd+shift+t"}, {"wait": 1.5}, tree("new-window")],
         record={**APP, "post": 1.0}),
    step("close-new-window", "cmd+W closes that window.", [{"key": "cmd+w"}, {"wait": 0.8}],
         record={**APP, "post": 1.0}),
    step("window-menu", "The Window menu now (open by click): list of windows.",
         [{"click": MB("Window")}, {"wait": 0.6}], record={**APP, "post": 0.6}),
    step("window-menu-close", "Escape.", [CLOSE_MENUS], record=False, still="after"),
    step("zoom", "Window ▸ Zoom (fills the display; animation).", [{"menu": "Window > Zoom"}, {"wait": 0.8}],
         record={**APP, "post": 1.0}),
    step("zoom-back", "Window ▸ Zoom again (back).", [{"menu": "Window > Zoom"}, {"wait": 0.8}],
         record={**APP, "post": 1.0}),
]
window = script("parity-a-window", "Part A 6: window behaviours: live resize narrower and wider (toolbar overflow), "
                "very narrow and very wide, cmd+0 / cmd+option+0, window tabs, a new window, Zoom.", win)

for s in (navigators, window):
    (HERE / f"{s['name']}.json").write_text(json.dumps(s, indent=1, ensure_ascii=False) + "\n")
    print(s["name"], len(s["steps"]), "steps")

# ---------------------------------------------------------------- A2b New Project options and save panel
TAB_MACOS = [{"click": {"role": "AXRadioButton", "label": "macOS", "scope": "app", "visible": True}},
             {"click": {"label": "macOS", "scope": "app", "visible": True}, "fallback": True}, {"wait": 0.8}]
NEXT = {"press": {"role": "AXButton", "title": "Next", "scope": "app"}}
POP = lambda v: {"role": "AXPopUpButton", "value": v, "scope": "app"}
np2 = [
    step("to-options", "Not judged: reach the options page of macOS ▸ App (the first macOS template, selected by "
         "default).", [{"key": "cmd+shift+n"}, {"wait": 2.0},
                       {"click": {"role": "AXRow", "text": "Choose Template…", "scope": "app"}}, {"wait": 2.5}]
         + TAB_MACOS + [{"wait": 0.5}, NEXT, {"wait": 1.5}, tree("options")], record=False, still="after",
         per_target={"ycode": {"do": [{"click": NEWMENU}, {"wait": 1.0}, {"click": MI("Choose Template…")},
                                      {"wait": 2.0}, {"move": [56, 57], "window": "Untitled"}, {"wait": 1.0}]
                               + TAB_MACOS + [{"wait": 0.5}, NEXT, {"wait": 1.5}, tree("options")]}}),
    tab_walk("options-tab-order", "Tab through the options page (key-view order). The Team, organization and bundle "
             "identifier values are painted out in Xcode's stills.", 8),
    step("product-name", "Click the Product Name field and type 'ParityApp' (the bundle identifier follows).",
         [{"click": {"identifier": "productName", "scope": "app"}}, {"key": "cmd+a"},
          {"text": "ParityApp"}, {"wait": 0.6}], record={**APP, "post": 0.8}),
]
for pid, ident in [("interface", "userInterface"), ("language", "languageChoice"), ("testing", "testingSystem"),
                   ("storage", "storageType")]:
    np2 += [step(f"popup-{pid}", f"Open the {pid} pop-up (identifier {ident}; never the Team pop-up): its menu "
                 "(animation). AX tree.",
                 [{"click": {"identifier": ident, "scope": "app"}}, {"wait": 0.8}, tree(f"popup-{pid}")],
                 record={**APP, "post": 0.8}),
            step(f"popup-{pid}-close", "Escape (the value stays).", [{"key": "escape"}, {"wait": 0.4}],
                 record=False, still="after")]
np2 += [
    step("save-panel", "Next: the save sheet (animation). Its sidebar is painted out afterwards. AX tree.",
         [NEXT, {"wait": 2.0}, tree("save")], record={**APP, "post": 1.0}),
    tab_walk("save-tab-order", "Tab through the save sheet (key-view order).", 5),
    step("save-cancel", "Cancel the save sheet: back to the options page.", esc_or_cancel(),
         record={**APP, "post": 1.0}),
    step("assistant-cancel", "Cancel the assistant (its Cancel button).", esc_or_cancel(),
         record={**APP, "post": 1.2}),
    step("after-cancel", "What is left: the untitled window or nothing.", [{"wait": 0.5}, tree("after")],
         record=False, still="after"),
]
newproject2 = script("parity-a-newproject2", "Part A 2b: the New Project options page: key-view order, the product "
                     "name, its pop-up menus, the save sheet (cancelled), cancelling the assistant.", np2,
                     project=False, per_target_setup=PANEL_SETUP)
(HERE / f"{newproject2['name']}.json").write_text(json.dumps(newproject2, indent=1, ensure_ascii=False) + "\n")
print(newproject2["name"], len(newproject2["steps"]), "steps")

# ---------------------------------------------------------------- A3b menus with a source file open
# Xcode's Editor menu holds only a few items while no editor is open (finding of the first menus run), so the
# Editor, Find and Navigate menus are recorded again with Long.swift open in the editor.
ed_steps = [step("rest", "Long.swift open (selected in the navigator). The whole menu bar.",
                 [{"menubar": "long-open"}], record=False, still="after")]
ed_steps += [s for s in menu_steps if s["id"].split("-")[0] in ("editor", "find", "navigate")]
ed_steps.append(step("menubar-after", "The whole menu bar after these menus were opened.",
                     [{"menubar": "after-tour"}], record=False, still="none"))
menus_editor = script("parity-a-menus-editor", "Part A 3b: the Editor, Find and Navigate menus again with Long.swift "
                      "open in the editor.", ed_steps,
                      setup=[{"select": {"role": "AXRow", "text": "Long|Long.swift"}}, {"wait": 2.0}])
(HERE / f"{menus_editor['name']}.json").write_text(json.dumps(menus_editor, indent=1, ensure_ascii=False) + "\n")
print(menus_editor["name"], len(menus_editor["steps"]), "steps")
