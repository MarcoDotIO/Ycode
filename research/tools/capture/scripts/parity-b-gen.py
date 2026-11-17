#!/usr/bin/env python3
"""Writes the parity run's part B session scripts (parity-b-*.json) next to
this file. Part B: the source editor, inspectors, the project editor, build,
run and debug, the scheme editor and tests, source control.

    python3 -I research/tools/capture/scripts/parity-b-gen.py

Projects: Parity (make-parity-project.py: a macOS SwiftUI app, a host-less
unit test bundle, a shared scheme, a git history by a fixed test identity)
and Merger (make-conflict-project.py) for source control.
"""
import json
import pathlib

HERE = pathlib.Path(__file__).resolve().parent
REC = {"fps": 120, "codec": "hevc", "pre": 0.5, "post": 1.2}
APP = {"mode": "app", "margin": 600}       # every window of the app on the built-in display
PARITY = {"generator": "make-parity-project.py", "path": "Parity/Parity.xcodeproj"}
MERGER = {"generator": "make-conflict-project.py", "path": "Merger/Merger.xcodeproj"}


def script(name, title, steps, project=PARITY, setup=None, per_target_setup=None, window=None):
    s = {"name": name, "title": title, "targets": ["xcode", "ycode"], "compare_order": ["xcode", "ycode"],
         "focus": "foreground", "launch_settle": 3.0, "record": REC, "steps": steps, "project": project,
         "window": window or {"size": [1400, 880], "display": "builtin", "title": "{project}", "timeout": 90}}
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


def vid(sid, note, do, post=1.0, **extra):
    """A recorded step (app mode, the whole built-in display). Snaps are left out of
    recorded steps: a still taken while the same window is being recorded can wait
    for a frame forever (the video has those moments anyway)."""
    do = [a for a in do if "snap" not in a]
    return step(sid, note, do, record={**APP, "post": post}, **extra)


def shot(sid, note, do, **extra):
    """No video: an app-mode after still."""
    return step(sid, note, do, record={"video": False, "mode": "app", "margin": 600}, still="after", **extra)


def tree(name):
    return {"tree": name, "depth": 40}


def tab_walk(sid, note, count, key="tab"):
    do = []
    for i in range(1, count + 1):
        do += [{"key": key}, {"wait": 0.4}, {"snap": f"k{i:02d}", "mode": "app"}, tree(f"k{i:02d}")]
    return step(sid, note, do, record=False, still="none")


def tc(needle, occurrence=1, offset=0, **kw):
    """Click at a piece of visible editor text (textclick)."""
    a = {"textclick": {"needle": needle, "occurrence": occurrence, "offset": offset}}
    for k in ("dx", "dy"):
        if k in kw:
            a["textclick"][k] = kw.pop(k)
    a.update(kw)
    return a


ROW = lambda name: {"role": "AXRow", "text": f"{name}|{name}.swift"}
MI = lambda title: {"role": "AXMenuItem", "title": title, "scope": "app", "visible": True}
CLOSE_MENUS = {"key": "escape escape escape"}
ESC_OR_CANCEL = [{"press": {"role": "AXButton", "title": "Cancel", "scope": "app"}}, {"key": "escape", "fallback": True}]
# Jump bar segments, window points (the reference's jump bar is not in its accessibility tree; both apps put
# the segments at these places at 1400 x 880 with the navigator at its default width).
JUMP = [("project", [370, 66]), ("group", [437, 66]), ("file", [515, 66]), ("symbol", [600, 66])]
MINIMAP_X = 1060

# ---------------------------------------------------------------- B1a editor: Showcase.swift
e1 = [
    shot("rest", "Showcase.swift open (selected in the navigator), at rest: syntax colouring of the first screen. "
         "AX tree and the whole menu bar.", [tree("rest"), {"menubar": "showcase"}]),
    shot("focus", "Click into the editor at 'import Foundation' (caret, current-line highlight). The menu bar again "
         "(enabled states with the editor focused).", [tc("import Foundation", offset=3), {"wait": 0.6},
                                                        {"menubar": "editor-focused"}, tree("focused")]),
    vid("scroll-down", "Wheel scroll 1200 pt down over 1 s (phase-less wheel events, exact deltas).",
        [{"scroll": {"at": [700, 500]}, "dy": -1200, "steps": 120, "interval": 0.008333}], post=1.0),
    vid("flick-down", "A fast flick down (8 gesture events of 40 pt, then momentum).",
        [{"scroll": {"at": [700, 500]}, "dy": -320, "steps": 8, "interval": 0.008333, "momentum": True,
          "momentum_tau": 0.33, "phases": True}], post=1.8),
    vid("to-top", "cmd+Up: back to the top of the file.", [{"key": "cmd+up"}], post=1.0),
    vid("minimap-hover", "Pointer onto the minimap (about a third down), held 2 s: hover highlight, the section "
        "label under the pointer.", [{"hover": [MINIMAP_X, 330]}, {"wait": 2.0}], post=0.6),
    vid("minimap-click", "Click in the minimap 60 % down: the editor jumps there.", [{"click": [MINIMAP_X, 560]},
                                                                                    {"wait": 0.8}], post=1.0),
    vid("minimap-drag", "Drag in the minimap from 15 % to 75 % of its height over 1.2 s (the visible-region box "
        "follows).", [{"drag": {"from": [MINIMAP_X, 150], "to": [MINIMAP_X, 680]}, "duration": 1.2}], post=1.0),
    vid("minimap-off", "Editor ▸ Minimap: hide it.", [{"menu": "Editor > Minimap"}, {"wait": 0.5}], post=1.0),
    vid("minimap-on", "Editor ▸ Minimap: show it again.", [{"menu": "Editor > Minimap"}, {"wait": 0.5}], post=1.0),
    vid("to-top-2", "cmd+Up, caret on line 1.", [{"key": "cmd+up"}, {"wait": 0.5}], post=0.6),
    vid("ribbon-hover", "Pointer onto the gutter just left of 'enum Mode0' (line 8; the code folding ribbon), held "
        "2 s.", [tc("enum Mode0", dx=-10, hover=True), {"wait": 2.0}], post=0.6),
    vid("ribbon-click", "Click there: fold the enumeration (animation).", [tc("enum Mode0", dx=-10), {"wait": 0.8}],
        post=1.0),
    vid("ribbon-unfold", "Click there again: unfold.", [tc("enum Mode0", dx=-10), {"wait": 0.8}], post=1.0),
    vid("fold-caret", "Caret inside struct Box0 ('values.append'), Editor ▸ Code Folding ▸ Fold (option+cmd+Left).",
        [tc("values.append", offset=2), {"wait": 0.3}, {"key": "cmd+alt+left"}, {"wait": 0.6}], post=1.0),
    vid("unfold-caret", "Unfold (option+cmd+Right).", [{"key": "cmd+alt+right"}, {"wait": 0.6}], post=1.0),
    vid("fold-methods", "Fold Methods & Functions (option+shift+cmd+Left).", [{"key": "cmd+alt+shift+left"},
                                                                              {"wait": 0.8}], post=1.0),
    vid("unfold-methods", "Unfold Methods & Functions (option+shift+cmd+Right).",
        [{"key": "cmd+alt+shift+right"}, {"wait": 0.8}], post=1.0),
    vid("fold-comments", "Fold Comment Blocks (control+shift+cmd+Left).", [{"key": "cmd+ctrl+shift+left"},
                                                                           {"wait": 0.8}], post=1.0),
    vid("unfold-comments", "Unfold Comment Blocks (control+shift+cmd+Right).", [{"key": "cmd+ctrl+shift+right"},
                                                                                {"wait": 0.8}], post=1.0),
]
for jid, at in JUMP:
    e1 += [vid(f"jump-{jid}", f"Click the jump bar's {jid} segment (window point {at}): its menu (animation). AX tree.",
               [{"click": at}, {"wait": 0.8}, tree(f"jump-{jid}")], post=0.8),
           shot(f"jump-{jid}-type", "Type-select in that menu: type 'S', still.", [{"text": "S"}, {"wait": 0.5}]),
           step(f"jump-{jid}-close", "Escape.", [CLOSE_MENUS, {"wait": 0.3}], record=False, still="none")]
e1 += [
    vid("related-items", "The Related Items button (left end of the jump bar): its menu. AX tree.",
        [{"click": {"description": "Related Items"}}, {"wait": 0.8}, tree("related")], post=0.8),
    step("related-walk", "Every sub-menu of the Related Items menu, hovered: a still of each.",
         [{"submenus": "sub", "all_windows": True}], record=False, still="none"),
    step("related-close", "Escape.", [CLOSE_MENUS, {"wait": 0.3}], record=False, still="after"),
    vid("find-bar", "cmd+F: the find bar (animation). AX tree.", [tc("import Foundation"), {"wait": 0.3},
                                                                   {"key": "cmd+f"}, {"wait": 0.8}, tree("find")],
        post=1.0),
    vid("find-type", "Type 'values': matches highlighted, match count.", [{"text": "values"}, {"wait": 1.0}],
        post=1.0),
    vid("find-next", "Return, Return: next match (scroll, current-match flash).", [{"key": "return"}, {"wait": 0.6},
                                                                                  {"key": "return"}, {"wait": 0.6}],
        post=1.0),
    tab_walk("find-tab-order", "Tab through the find bar (key-view order).", 5),
    vid("find-replace", "Find ▸ Find and Replace… (option+cmd+F): the replace row (animation). AX tree.",
        [{"key": "cmd+alt+f"}, {"wait": 0.8}, tree("replace")], post=1.0),
    vid("find-close", "Escape (twice) closes the find bar.", [{"key": "escape"}, {"wait": 0.3}, {"key": "escape"}],
        post=1.0),
    vid("goto-line", "Navigate ▸ Jump to Line (cmd+L): the line field (animation). AX tree.",
        [tc("import Foundation"), {"wait": 0.3}, {"key": "cmd+l"}, {"wait": 0.8}, tree("goto")], post=0.8),
    vid("goto-line-enter", "Type 120 and Return: the editor jumps to line 120.", [{"text": "120"}, {"wait": 0.4},
                                                                                 {"key": "return"}, {"wait": 0.8}],
        post=1.0),
    vid("to-top-3", "cmd+Up.", [{"key": "cmd+up"}], post=0.5),
    vid("multi-cursor", "Click in 'case idle', then control+shift+click in 'case .idle' and 'case .running': three "
        "insertion points.", [tc("case idle", offset=2), {"wait": 0.3},
                              tc("case .idle", offset=2, modifiers="ctrl,shift"), {"wait": 0.3},
                              tc("case .running", offset=2, modifiers="ctrl,shift"), {"wait": 0.8}], post=1.0),
    vid("multi-type", "Type 'x' at all of them, then cmd+Z.", [{"text": "x"}, {"wait": 0.8}, {"snap": "typed", "mode": "app"},
                                                               {"key": "cmd+z"}, {"wait": 0.6}], post=1.0),
    vid("comment-toggle", "Caret in 'let limit', Editor ▸ Structure ▸ Comment Selection (cmd+/).",
        [{"key": "escape"}, tc("let limit", offset=2), {"wait": 0.3}, {"key": "cmd+/"}, {"wait": 0.6}], post=1.0),
    vid("comment-toggle-back", "cmd+/ again: uncomment.", [{"key": "cmd+/"}, {"wait": 0.6}], post=1.0),
    vid("shift-right", "Editor ▸ Structure ▸ Shift Right (cmd+]) on that line.", [{"key": "cmd+]"}, {"wait": 0.6}],
        post=1.0),
    vid("reindent", "Editor ▸ Structure ▸ Re-Indent (control+I): back in place.", [{"key": "ctrl+i"}, {"wait": 0.6}],
        post=1.0),
    vid("shift-left", "Shift Left (cmd+[) then Re-Indent (control+I).", [{"key": "cmd+["}, {"wait": 0.6},
                                                                         {"key": "ctrl+i"}, {"wait": 0.6}], post=1.0),
    vid("authors", "Editor ▸ Authors (control+shift+cmd+A): the blame column (two commits by Capture Test). AX tree.",
        [{"menu": "Editor > Authors"}, {"wait": 2.0}, tree("authors")], post=1.0),
    vid("authors-hover", "Pointer onto the authors column at line 8, held 2 s (hover, tooltip or popover).",
        [tc("enum Mode0", dx=-160, hover=True), {"wait": 2.0}], post=0.6),
    vid("authors-off", "Editor ▸ Authors again: off.", [{"menu": "Editor > Authors"}, {"wait": 1.0}], post=1.0),
    shot("menubar-after", "The whole menu bar after this session's actions.", [{"menubar": "after"}]),
]
editor1 = script("parity-b-editor", "Part B 1a: the source editor with Showcase.swift: syntax colouring, scrolling, "
                 "minimap, code folding, jump bar menus, Related Items, find and replace, Go to Line, multiple "
                 "insertion points, comment toggling, indentation, Authors.", e1,
                 setup=[{"select": ROW("Showcase")}, {"wait": 2.5}])

# ---------------------------------------------------------------- B1b editor: Shapes.swift, ContentView, tabs
e2 = [
    shot("rest", "Shapes.swift open. AX tree.", [tree("rest")]),
    vid("completion", "Caret at the end of 'let bigger = circle.scaled(by: 2)', Return, type 'circle.': the "
        "completion list (animation). AX tree.",
        [tc("scaled(by: 2)", offset=12), {"wait": 0.3}, {"key": "cmd+right"}, {"key": "return"},
         {"text": "circle."}, {"wait": 1.8}, tree("completion")], post=1.0),
    vid("completion-arrows", "Down, Down, Up in the list (selection, detail line).",
        [{"key": "down"}, {"wait": 0.5}, {"snap": "down1", "mode": "app"}, {"key": "down"}, {"wait": 0.5},
         {"snap": "down2", "mode": "app"}, {"key": "up"}, {"wait": 0.5}], post=0.8),
    vid("completion-filter", "Type 'sc': the list narrows to scaled(by:).", [{"text": "sc"}, {"wait": 1.0},
                                                                            tree("completion-sc")], post=0.8),
    vid("completion-accept", "Return: accept (placeholder for the argument).", [{"key": "return"}, {"wait": 1.0}],
        post=1.0),
    vid("placeholder-next", "Tab (or control+/): to the placeholder; then Escape.", [{"key": "tab"}, {"wait": 0.6},
                                                                                    {"key": "escape"}], post=0.8),
    vid("completion-explicit", "Undo the inserted text (cmd+Z until clean, up to 6), then Editor ▸ Show Completions "
        "(control+Space) after 'circle.' typed again.",
        [{"key": "cmd+z cmd+z cmd+z cmd+z cmd+z cmd+z"}, {"wait": 0.5}, tc("scaled(by: 2)", offset=12),
         {"key": "cmd+right"}, {"key": "return"}, {"text": "circle."}, {"key": "escape"}, {"wait": 0.5},
         {"key": "ctrl+space"}, {"wait": 1.5}], post=1.0),
    vid("completion-escape", "Escape closes it; undo the typing.",
        [{"key": "escape"}, {"wait": 0.4}, {"key": "cmd+z cmd+z cmd+z cmd+z"}, {"wait": 0.5}], post=0.8),
    vid("quick-help-own", "option+click on 'scaled' in 'circle.scaled(by: 2)': Quick Help popover for our own "
        "documented method (animation). AX tree.",
        [tc("scaled(by: 2)", offset=2, modifiers="alt"), {"wait": 2.0}, tree("quick-help")], post=1.0),
    vid("quick-help-close", "Escape.", [{"key": "escape"}], post=0.8),
    vid("quick-help-sdk", "option+click on 'reduce': Quick Help for a standard library method.",
        [tc("reduce(", offset=2, modifiers="alt"), {"wait": 2.5}, tree("quick-help-sdk")], post=1.0),
    vid("quick-help-sdk-close", "Escape.", [{"key": "escape"}], post=0.8),
    vid("cmd-hover", "Hold cmd over 'Circle' in 'Circle(radius: 2)' (cmd+hover: link underline)? Pointer there, "
        "2 s (without cmd: hover only).", [tc("Circle(radius: 2)", offset=2, hover=True), {"wait": 2.0}], post=0.5),
    vid("jump-definition", "Caret in 'Circle(radius: 2)', Navigate ▸ Jump to Definition (control+cmd+J).",
        [tc("Circle(radius: 2)", offset=2), {"wait": 0.3}, {"key": "ctrl+cmd+j"}, {"wait": 1.5}], post=1.0),
    vid("code-actions", "Caret in 'totalArea', Editor ▸ Show Code Actions (cmd+shift+A): the code actions menu. "
        "AX tree.", [tc("totalArea", offset=3), {"wait": 0.3}, {"key": "cmd+shift+a"}, {"wait": 1.5},
                     tree("code-actions")], post=1.0),
    step("code-actions-walk", "Sub-menus of the code actions menu, if any.", [{"submenus": "sub", "all_windows": True}],
         record=False, still="none"),
    vid("code-actions-close", "Escape.", [CLOSE_MENUS], post=0.8),
    vid("rename", "Caret in 'bigger', Editor ▸ Refactor ▸ Rename…: the rename mode (all occurrences, animation). "
        "AX tree.", [tc("let bigger", offset=6), {"wait": 0.3}, {"menu": "Editor > Refactor > Rename…"},
                     {"wait": 3.0}, tree("rename")], post=1.0),
    vid("rename-type", "Type 'larger' (every occurrence follows).", [{"text": "larger"}, {"wait": 1.0}], post=1.0),
    vid("rename-cancel", "Escape: cancel the rename (Cancel button first if there is one).",
        ESC_OR_CANCEL + [{"wait": 1.0}], post=1.0),
    vid("split-right", "File ▸ New ▸ Editor Pane On Right (control+cmd+T): a second editor (animation). AX tree.",
        [{"key": "ctrl+cmd+t"}, {"wait": 1.5}, tree("split-right")], post=1.0),
    vid("split-below", "File ▸ New ▸ Editor Pane Below (control+option+cmd+T).",
        [{"key": "ctrl+alt+cmd+t"}, {"wait": 1.5}, tree("split-below")], post=1.0),
    vid("split-close-1", "File ▸ Close Editor Pane (control+shift+cmd+W).", [{"key": "ctrl+shift+cmd+w"},
                                                                            {"wait": 1.0}], post=1.0),
    vid("split-close-2", "Close Editor Pane again (one editor left).", [{"key": "ctrl+shift+cmd+w"}, {"wait": 1.0}],
        post=1.0),
    vid("add-editor-menu", "The Add Editor toolbar menu (its items). AX tree.",
        [{"click": {"description": "Add Editor"}}, {"wait": 0.8}, tree("add-editor")], post=0.8),
    vid("add-editor-close", "Escape.", [CLOSE_MENUS], post=0.5),
    vid("editor-options-menu", "The Editor Options toolbar menu (Canvas, Minimap, Authors, Code Coverage…). AX tree.",
        [{"click": {"description": "Editor Options"}}, {"wait": 0.8}, tree("editor-options")], post=0.8),
    step("editor-options-walk", "Its sub-menus: a still of each.", [{"submenus": "sub", "all_windows": True}],
         record=False, still="none"),
    vid("editor-options-close", "Escape.", [CLOSE_MENUS], post=0.5),
    vid("assistant", "Editor ▸ Assistant (control+option+cmd+Return): the assistant editor (animation). AX tree.",
        [{"key": "ctrl+alt+cmd+return"}, {"wait": 2.0}, tree("assistant")], post=1.0),
    vid("assistant-menu", "The assistant pane's jump bar first segment (Automatic / Counterparts…): click near its "
        "left end. AX tree.", [{"click": [1000, 66]}, {"wait": 0.8}, tree("assistant-menu")], post=0.8),
    vid("assistant-menu-close", "Escape.", [CLOSE_MENUS], post=0.5),
    vid("assistant-off", "Show the standard editor again (cmd+Return).", [{"key": "cmd+return"}, {"wait": 1.5}],
        post=1.0),
    vid("open-contentview", "Click ContentView in the navigator (it has a #Preview): the canvas opens beside the "
        "code (animation).", [{"click": ROW("ContentView")}, {"wait": 6.0}, tree("canvas")], post=1.0),
    shot("canvas-later", "8 s later: the preview rendered (or its status).", [{"wait": 8.0}, tree("canvas-later")]),
    vid("canvas-toggle-off", "Editor ▸ Canvas (option+cmd+Return): hide the canvas.", [{"key": "cmd+alt+return"},
                                                                                      {"wait": 1.5}], post=1.0),
    vid("canvas-toggle-on", "option+cmd+Return again: show it.", [{"key": "cmd+alt+return"}, {"wait": 4.0}], post=1.0),
    vid("open-quickly", "File ▸ Open Quickly (shift+cmd+O): the panel (animation). AX tree.",
        [{"key": "cmd+shift+o"}, {"wait": 1.0}, tree("open-quickly")], post=0.8),
    vid("open-quickly-type", "Type 'Count' one character at a time (results update).", [{"text": "Count"},
                                                                                     {"wait": 1.5},
                                                                                     tree("open-quickly-count")],
        post=1.0),
    vid("open-quickly-arrows", "Down, Up (selection).", [{"key": "down"}, {"wait": 0.5}, {"snap": "down", "mode": "app"},
                                                         {"key": "up"}, {"wait": 0.5}], post=0.6),
    vid("open-quickly-open", "Return: Counter.swift opens.", [{"key": "return"}, {"wait": 1.5}], post=1.0),
    vid("tab-open-1", "Select Shapes in the navigator, File ▸ Open in New Tab (option+cmd+O): a second editor tab.",
        [{"click": ROW("Shapes")}, {"wait": 0.6}, {"menu": "File > Open in New Tab"}, {"wait": 1.0}, tree("tabs")],
        post=1.0),
    vid("tab-open-2", "Select Showcase, Open in New Tab: a third.", [{"click": ROW("Showcase")}, {"wait": 0.6},
                                                                     {"menu": "File > Open in New Tab"},
                                                                     {"wait": 1.0}], post=1.0),
    vid("tab-prev", "Navigate ▸ Show Previous Tab (cmd+{).", [{"key": "cmd+shift+["}, {"wait": 0.6}], post=0.8),
    vid("tab-next", "Navigate ▸ Show Next Tab (cmd+}).", [{"key": "cmd+shift+]"}, {"wait": 0.6}], post=0.8),
    vid("tab-hover", "Pointer onto the first editor tab, held 1.6 s (close button, tooltip).",
        [{"hover": {"role": "AXRadioButton", "subrole": "AXTabButton", "description~": "ContentView|Counter",
                    "index": 0}}, {"wait": 1.6}], post=0.5),
    vid("tab-close", "cmd+W closes the current editor tab (animation).", [{"key": "cmd+w"}, {"wait": 0.8}], post=1.0),
    vid("tab-close-2", "cmd+W again.", [{"key": "cmd+w"}, {"wait": 0.8}], post=1.0),
    shot("end", "What is left: AX tree.", [tree("end")]),
]
editor2 = script("parity-b-editor2", "Part B 1b: code completion, Quick Help, Jump to Definition, code actions, "
                 "rename, split editors, Add Editor and Editor Options menus, the assistant, the SwiftUI canvas, "
                 "Open Quickly, editor tabs.", e2, setup=[{"select": ROW("Shapes")}, {"wait": 2.5}])

# ---------------------------------------------------------------- B2 inspectors
INSP = [("file", "Show the File inspector", "cmd+alt+1"), ("history", "Show the History inspector", "cmd+alt+2"),
        ("quick-help", "Show Quick Help inspector", "cmd+alt+3")]
ins = [shot("rest", "Shapes.swift open, File inspector. AX tree.", [tree("rest")])]
for iid, helptext, key in INSP:
    ins.append(vid(f"key-{iid}", f"{key}: the {iid} inspector (switch animation). AX tree.",
                   [{"key": key}, {"wait": 1.5}, tree(iid)], post=1.0))
for iid, helptext, key in INSP:
    ins.append(vid(f"click-{iid}", f"Pointer onto the {iid} inspector tab (1.6 s: hover, tooltip), then click it.",
                   [{"hover": {"help": helptext}}, {"wait": 1.6}, {"click": {"help": helptext}}, {"wait": 1.0}],
                   post=1.0))
ins += [
    vid("quick-help-symbol", "Quick Help inspector, caret in 'scaled' (our documented method): the inspector shows "
        "its documentation. AX tree. (Its tab is clicked: option+cmd+3 hides the reference's inspector when Quick Help is "
        "already showing.)", [{"click": {"help": "Show Quick Help inspector"}}, {"wait": 0.5},
                             tc("scaled(by: 2)", offset=2), {"wait": 2.0},
                                        tree("qh-symbol")], post=1.0),
    vid("quick-help-sdk", "Caret in 'reduce': standard library documentation.", [tc("reduce(", offset=2),
                                                                                {"wait": 2.5}, tree("qh-sdk")],
        post=1.0),
    vid("quick-help-none", "Caret on a blank line: the no-symbol state.", [tc("// Shapes.swift", offset=1),
                                                                          {"key": "down"}, {"wait": 1.5}], post=1.0),
    vid("history-file", "History inspector with Shapes.swift: the commit list (Capture Test). AX tree.",
        [{"key": "cmd+alt+2"}, {"wait": 2.5}, tree("history-file")], post=1.0),
    vid("history-showcase", "Select Showcase.swift: two commits in its history.",
        [{"click": ROW("Showcase")}, {"wait": 2.5}, tree("history-showcase")], post=1.0),
    vid("history-hover", "Pointer onto the first history entry, held 2 s.",
        [{"hover": {"role": "AXRow|AXCell|AXGroup", "text~": "Revise", "scope": "app"}}, {"wait": 2.0}], post=0.6),
    vid("history-click", "Click it (the commit's popover or detail). AX tree.",
        [{"click": {"role": "AXRow|AXCell|AXGroup", "text~": "Revise", "scope": "app"}}, {"wait": 1.5},
         tree("history-click")], post=1.0),
    vid("history-close", "Escape.", [{"key": "escape"}], post=0.6),
    vid("file-inspector-folder", "File inspector with the Parity folder (a synchronized group) selected.",
        [{"key": "cmd+alt+1"}, {"click": {"role": "AXRow", "text": "Parity", "index": 1}}, {"wait": 1.5},
         tree("folder")], post=1.0),
    vid("file-inspector-project", "File inspector with the project (first row) selected: the project document's "
        "inspector.", [{"click": {"role": "AXRow", "text": "Parity", "index": 0}}, {"wait": 2.0}, tree("project")],
        post=1.0),
    vid("file-inspector-test", "File inspector with ParityTests.swift (target membership: the test bundle).",
        [{"set": {"role": "AXRow", "text": "ParityTests", "index": 0}, "attr": "AXDisclosing", "value": True},
         {"wait": 0.5}, {"click": {"role": "AXRow", "text": "ParityTests|ParityTests.swift", "index": 1}},
         {"wait": 2.0}, tree("test-file")], post=1.0),
    vid("multi-select", "Shapes and Showcase both selected (cmd+click): the inspector for several files.",
        [{"click": ROW("Shapes")}, {"wait": 0.5},
         {"click": ROW("Showcase"), "modifiers": "cmd"}, {"wait": 1.5}, tree("multi")], post=1.0),
    vid("hide-inspector", "View ▸ Inspectors ▸ Hide Inspector (option+cmd+0).", [{"key": "cmd+alt+0"}], post=1.0),
    vid("show-inspector-history", "option+cmd+2 while hidden: shows the inspector on History.",
        [{"key": "cmd+alt+2"}, {"wait": 1.0}], post=1.0),
    tab_walk("tab-order", "Tab through the inspector area (key-view order), starting from the editor.", 6),
]
inspectors = script("parity-b-inspectors", "Part B 2: the File, History and Quick Help inspectors by keyboard and by "
                    "click, Quick Help for our own and SDK symbols, history entries, folder/project/test file/multiple "
                    "selection, hide and show.", ins, setup=[{"select": ROW("Shapes")}, {"wait": 2.5}])

# ---------------------------------------------------------------- B3 project editor
TABS = ["General", "Signing & Capabilities", "Resource Tags", "Info", "Build Settings", "Build Phases", "Build Rules"]
TAB = lambda t: {"role": "AXButton|AXRadioButton", "label": t, "visible": True}
pe = [vid("open-project", "Click the project row (Parity, first row): the project editor (target Parity selected). "
          "AX tree.", [{"click": {"role": "AXRow", "text": "Parity", "index": 0}}, {"wait": 2.5}, tree("project")],
          post=1.0)]
for t in TABS:
    tid = t.lower().replace(" & ", "-").replace(" ", "-")
    pe.append(vid(f"tab-{tid}", f"Click the {t} tab (switch animation). AX tree. (Never the Team pop-up.)",
                  [{"click": TAB(t)}, {"wait": 1.5}, tree(tid)], post=1.0))
    if t == "General":
        pe += [vid("general-scroll", "Scroll the General tab 1500 pt down (every section).",
                   [{"scroll": {"at": [800, 500]}, "dy": -1500, "steps": 120, "interval": 0.008333}, {"wait": 0.5},
                    tree("general-bottom")], post=0.8),
               vid("general-disclosure", "Collapse the first section (its disclosure/'Hide' control).",
                   [{"scroll": {"at": [800, 500]}, "dy": 3000, "steps": 30, "interval": 0.008333}, {"wait": 0.4},
                    {"click": {"role": "AXDisclosureTriangle|AXButton", "description~": "Supported Destinations|"
                               "Minimum Deployments|disclos", "visible": True}}, {"wait": 0.8}], post=1.0)]
    if t == "Signing & Capabilities":
        pe += [vid("capability-library", "Click '+ Capability': the capability library (animation). AX tree.",
                   [{"click": {"role": "AXButton", "label~": "Capability", "visible": True}}, {"wait": 2.0},
                    tree("capabilities")], post=1.0),
               vid("capability-type", "Type 'iCloud' in its filter.", [{"text": "iCloud"}, {"wait": 1.0}], post=0.8),
               vid("capability-close", "Escape (nothing added).", [{"key": "escape"}, {"wait": 0.5}], post=0.8)]
    if t == "Info":
        pe += [vid("info-hover-row", "Pointer onto the first property row, held 1.6 s (row +/− buttons).",
                   [{"hover": {"role": "AXRow", "index": 0, "visible": True}}, {"wait": 1.6}], post=0.5)]
    if t == "Build Settings":
        pe += [shot("bs-tree", "Build Settings at rest: AX tree.", [tree("bs")]),
               vid("bs-all", "Click 'All' (all settings).", [{"click": {"role": "AXButton|AXRadioButton", "label": "All",
                                                                           "visible": True}}, {"wait": 1.5}], post=1.0),
               vid("bs-levels", "Click 'Levels' (resolved, target, project, defaults columns).",
                   [{"click": {"role": "AXButton|AXRadioButton", "label": "Levels", "visible": True}}, {"wait": 1.5},
                    tree("bs-levels")], post=1.0),
               vid("bs-combined", "Click 'Combined'.", [{"click": {"role": "AXButton|AXRadioButton", "label": "Combined",
                                                                   "visible": True}}, {"wait": 1.5}], post=1.0),
               vid("bs-search", "Type 'swift' into the settings search field (rows filter).",
                   [{"click": {"subrole": "AXSearchField", "visible": True, "index": 1}},
                    {"key": "cmd+a"}, {"text": "swift"}, {"wait": 1.5}, tree("bs-swift")], post=1.0),
               vid("bs-search-empty", "Replace with 'zzzz': empty result.", [{"key": "cmd+a"}, {"text": "zzzz"},
                                                                             {"wait": 1.5}], post=1.0),
               vid("bs-basic", "Clear the search, click 'Basic'.", [{"key": "cmd+a delete"}, {"wait": 0.6},
                                                                    {"click": {"role": "AXButton|AXRadioButton",
                                                                               "label": "Basic", "visible": True}},
                                                                    {"wait": 1.5}], post=1.0),
               vid("bs-hover", "Pointer onto the 'Product Name' setting, held 2 s (tooltip with the setting name).",
                   [{"hover": {"role": "AXRow|AXStaticText|AXCell", "text~": "Product Name", "visible": True}},
                    {"wait": 2.0}], post=0.5)]
    if t == "Build Phases":
        pe += [vid("phases-disclose", "Expand the Compile Sources phase (disclosure animation).",
                   [{"click": {"role": "AXDisclosureTriangle|AXButton", "text~": "Compile Sources|Sources",
                               "visible": True}}, {"wait": 1.0}, tree("phases-open")], post=1.0),
               vid("phases-add-menu", "The '+' button above the phases: its menu (New Run Script Phase…).",
                   [{"click": {"role": "AXButton|AXMenuButton", "label": "add|Add", "visible": True}},
                    {"wait": 0.8}, tree("phases-add")], post=0.8),
               vid("phases-add-close", "Escape.", [CLOSE_MENUS], post=0.5)]
pe += [
    vid("project-item", "Select the PROJECT entry (Parity under Project) in the editor's list: its Info tab. AX tree.",
        [{"click": {"role": "AXRow", "text": "Parity", "scope": "window", "index": 2}}, {"wait": 2.0},
         tree("project-info")], post=1.0),
    vid("project-info-tab", "Click Info.", [{"click": TAB("Info")}, {"wait": 1.5}], post=1.0),
    vid("project-bs", "Click Build Settings (project level).", [{"click": TAB("Build Settings")}, {"wait": 1.5}],
        post=1.0),
    vid("package-deps", "Click Package Dependencies: the empty list (+ not pressed). AX tree.",
        [{"click": TAB("Package Dependencies")}, {"wait": 1.5}, tree("packages")], post=1.0),
    vid("test-target", "Select the ParityTests target: General tab.",
        [{"click": {"role": "AXRow", "text": "ParityTests", "scope": "window", "visible": True}}, {"wait": 1.5},
         {"click": TAB("General")}, {"wait": 1.5}, tree("tests-general")], post=1.0),
    vid("hide-list", "Hide the project and targets list (the button at the editor's top left).",
        [{"click": {"role": "AXButton", "description~": "project and targets list|navigation bar"}}, {"wait": 1.0}],
        post=1.0),
    vid("show-list", "Show it again.", [{"click": {"role": "AXButton", "description~": "project and targets list|"
                                                                                     "navigation bar"}},
                                        {"wait": 1.0}], post=1.0),
    vid("target-context", "Right-click the Parity target in the list: its context menu. AX tree.",
        [{"click": {"role": "AXRow", "text": "Parity", "scope": "window", "index": 3}, "button": "right"},
         {"wait": 0.8}, tree("target-context")], post=0.8),
    vid("target-context-close", "Escape.", [CLOSE_MENUS], post=0.5),
    tab_walk("tab-order", "Tab through the project editor (key-view order).", 8),
]
projed = script("parity-b-project", "Part B 3: the project editor: every target tab, the capability library, Build "
                "Settings modes and search, Build Phases, the project's Info and Package Dependencies, the targets "
                "list.", pe, setup=[{"select": ROW("Shapes")}, {"wait": 2.0}])

# ---------------------------------------------------------------- B4 build, issues, run, debug
BROKEN = {"run": ["cp", ".parity/issues-broken.txt", "Parity/Issues.swift"]}
CLEAN = {"run": ["cp", ".parity/issues-clean.txt", "Parity/Issues.swift"]}
bd = [
    shot("rest", "Issues.swift open (clean). AX tree.", [tree("rest")]),
    vid("break-file", "The file is replaced on disk with a version that has a warning (var never mutated) and an "
        "error with fix-its (call can throw, not marked with try): the editor reloads.",
        [BROKEN, {"wait": 3.0}], post=1.0),
    vid("build", "Product ▸ Build (cmd+B): progress in the activity area (snaps at +0.8, +2.3, +5 s), 25 s.",
        [{"key": "cmd+b"}, {"wait": 0.8}, {"snap": "building-1", "mode": "app"}, {"wait": 1.5},
         {"snap": "building-2", "mode": "app"}, {"wait": 2.7}, {"snap": "building-3", "mode": "app"}, {"wait": 20.0}],
        post=0.5),
    shot("after-build", "After the build: inline issue annotations, the toolbar's issue counts. AX tree.",
         [tree("after-build")]),
    vid("issue-navigator", "cmd+5: the Issue navigator (the warning and the error). AX tree.",
        [{"key": "cmd+5"}, {"wait": 1.0}, tree("issues")], post=1.0),
    vid("issue-row", "Click the error row: the editor jumps to it.", [{"click": {"role": "AXRow", "text~": "throw",
                                                                                 "index": 0}}, {"wait": 1.0}],
        post=1.0),
    vid("issue-hover", "Pointer onto the error's annotation at the end of its line, held 2 s.",
        [tc("risky()", occurrence=2, offset=6, dx=380, hover=True), {"wait": 2.0}], post=0.5),
    vid("fixit-click", "Click the annotation (fix-it list, animation). AX tree.",
        [tc("risky()", occurrence=2, offset=6, dx=380), {"wait": 1.5}, tree("fixit")], post=1.0),
    vid("fixit-close", "Escape.", [{"key": "escape"}, {"wait": 0.4}], post=0.6),
    vid("code-actions-error", "Caret in the failing call, Editor ▸ Show Code Actions (cmd+shift+A): fix-its there? "
        "AX tree.", [tc("risky()", occurrence=2, offset=2), {"wait": 0.3}, {"key": "cmd+shift+a"}, {"wait": 1.5},
                     tree("code-actions")], post=1.0),
    vid("code-actions-close", "Escape.", [CLOSE_MENUS], post=0.5),
    vid("fix-all", "Editor ▸ Fix All Issues (control+option+cmd+F).", [{"key": "ctrl+alt+cmd+f"}, {"wait": 1.5}],
        post=1.0),
    vid("fix-file", "The clean file is written back on disk (the editor reloads).", [{"key": "cmd+s"}, {"wait": 0.5},
                                                                                     CLEAN, {"wait": 3.0}], post=1.0),
    vid("rebuild", "cmd+B again: 20 s.", [{"key": "cmd+b"}, {"wait": 1.0}, {"snap": "building-1", "mode": "app"},
                                          {"wait": 19.0}], post=0.5),
    shot("after-rebuild", "After the second build: no issues. AX tree.", [{"key": "cmd+5"}, {"wait": 0.8},
                                                                          tree("after-rebuild")]),
    vid("report-navigator", "cmd+9: the Report navigator (both builds listed). AX tree.",
        [{"key": "cmd+9"}, {"wait": 1.0}, tree("reports")], post=1.0),
    vid("report-open", "Click the older build (the failed one): its log in the editor. AX tree.",
        [{"click": {"role": "AXRow", "text~": "Build", "index": 1}}, {"wait": 2.0}, tree("log")], post=1.0),
    vid("log-expand", "Expand the first step that has details (disclosure).",
        [{"click": {"role": "AXDisclosureTriangle|AXButton", "description~": "disclos|expand|Show details|transcript",
                    "visible": True}}, {"wait": 1.0}, tree("log-expanded")], post=1.0),
    vid("log-filter", "The log's filter: type 'Issues'.",
        [{"click": {"subrole": "AXSearchField", "visible": True, "index": 1}}, {"text": "Issues"}, {"wait": 1.0}],
        post=0.8),
    vid("log-all-messages", "Back to the project navigator (cmd+1), open Counter.swift.",
        [{"key": "cmd+1"}, {"wait": 0.6}, {"click": ROW("Counter")}, {"wait": 1.5}], post=1.0),
    vid("breakpoint-add", "Caret on 'let message' (line 12), Debug ▸ Breakpoints ▸ Create Breakpoint at Current Line "
        "(cmd+\\): the breakpoint arrow in the gutter.", [tc("let message", offset=4), {"wait": 0.3},
                                                         {"key": "cmd+\\"}, {"wait": 0.8}], post=1.0),
    vid("breakpoint-hover", "Pointer onto the breakpoint arrow, held 2 s.",
        [tc("let message", dx=-50, hover=True), {"wait": 2.0}], post=0.5),
    vid("run-to-breakpoint", "Product ▸ Run (cmd+R): build, launch, stop at the breakpoint (debug area, Debug "
        "navigator). Snaps at +3, +8, +15 s; 30 s in all.",
        [{"key": "cmd+r"}, {"wait": 3.0}, {"snap": "run-3s", "mode": "app"}, {"wait": 5.0},
         {"snap": "run-8s", "mode": "app"}, {"wait": 7.0}, {"snap": "run-15s", "mode": "app"}, {"wait": 15.0}],
        post=0.5),
    shot("paused", "Paused at the breakpoint: the green line, variables view, console, Debug navigator. AX tree.",
         [tree("paused")]),
    vid("step-over", "Debug ▸ Step Over (F6): the line moves to the print; variables update.",
        [{"key": "f6"}, {"wait": 1.5}], post=1.0),
    vid("step-over-2", "F6 again: the console prints the greeting.", [{"key": "f6"}, {"wait": 1.5}, tree("stepped")],
        post=1.0),
    vid("variables-hover", "Pointer onto 'message' in the editor, held 2.5 s (data tip). AX tree.",
        [tc("message =", offset=2, hover=True), {"wait": 2.5}, tree("datatip")], post=0.6),
    vid("debug-navigator", "cmd+7: the Debug navigator (gauges, threads, frames). AX tree.",
        [{"key": "cmd+7"}, {"wait": 1.0}, tree("debug-nav")], post=1.0),
    vid("cpu-gauge", "Click the CPU gauge: its report in the editor. AX tree.",
        [{"click": {"role": "AXRow|AXCell|AXGroup|AXButton", "text~": "CPU", "visible": True}}, {"wait": 2.0},
         tree("cpu")], post=1.0),
    vid("back-to-source", "Back to Counter.swift (Navigate ▸ Jump to Program Counter, control+cmd+P, or the "
        "frame row).", [{"key": "ctrl+cmd+p"}, {"wait": 1.5}], post=1.0),
    vid("breakpoint-navigator", "cmd+8: the Breakpoint navigator. AX tree.", [{"key": "cmd+8"}, {"wait": 1.0},
                                                                              tree("bp-nav")], post=1.0),
    vid("breakpoint-context", "Right-click the breakpoint row: its context menu. AX tree.",
        [{"click": {"role": "AXRow", "text~": "greeting|Counter.swift|line 12|Line 12", "index": 0},
          "button": "right"}, {"wait": 0.8}, tree("bp-context")], post=0.8),
    vid("breakpoint-edit", "Choose Edit Breakpoint…: the edit popover (animation). AX tree.",
        [{"menuclick": "Edit Breakpoint…"}, {"wait": 1.5}, tree("bp-edit")], post=1.0),
    tab_walk("breakpoint-edit-tabs", "Tab through the popover (key-view order).", 5),
    vid("breakpoint-edit-close", "Escape (or Done).", [{"press": {"role": "AXButton", "title": "Done", "scope": "app"}},
                                                       {"key": "escape", "fallback": True}], post=0.8),
    vid("breakpoints-deactivate", "Debug ▸ Deactivate Breakpoints (cmd+Y): the arrows dim, the toolbar button "
        "changes.", [{"key": "cmd+y"}, {"wait": 0.8}], post=1.0),
    vid("debug-area-hide", "View ▸ Debug Area ▸ Hide Debug Area (shift+cmd+Y).", [{"key": "cmd+shift+y"}], post=1.0),
    vid("debug-area-show", "Show it again.", [{"key": "cmd+shift+y"}], post=1.0),
    vid("console-activate", "View ▸ Debug Area ▸ Activate Console (shift+cmd+C).", [{"key": "cmd+shift+c"},
                                                                                    {"wait": 0.6}], post=1.0),
    vid("console-type", "Type 'p 1 + 2' and Return in the console (lldb).", [{"text": "p 1 + 2"}, {"key": "return"},
                                                                            {"wait": 1.5}], post=1.0),
    vid("continue", "Debug ▸ Continue (control+cmd+Y): the app runs on.", [{"key": "ctrl+cmd+y"}, {"wait": 3.0}],
        post=1.0),
    shot("running", "Running (not paused): toolbar, debug bar, Debug navigator. AX tree.", [tree("running")]),
    vid("stop", "Product ▸ Stop (cmd+.).", [{"key": "cmd+."}, {"wait": 2.0}], post=1.0),
    vid("breakpoints-activate", "cmd+Y: breakpoints active again.", [{"key": "cmd+y"}, {"wait": 0.6}], post=0.8),
    vid("breakpoint-remove", "Drag-free removal: Debug ▸ Breakpoints ▸ Delete All Breakpoints, or cmd+\\ on the "
        "line again.", [tc("let message", offset=4), {"key": "cmd+\\"}, {"wait": 0.8}], post=1.0),
]
build = script("parity-b-build", "Part B 4: build with a warning and an error (activity area, Issue navigator, inline "
               "annotations, fix-its), fix and build again, the Report navigator's build log, a breakpoint, run, "
               "step, data tip, Debug and Breakpoint navigators, the edit popover, debug area and console, continue, "
               "stop.", bd, setup=[{"select": ROW("Issues")}, {"wait": 2.5}])

# ---------------------------------------------------------------- B5 scheme editor and tests
SECTIONS = ["Build", "Run", "Test", "Profile", "Analyze", "Archive"]
SEC = lambda s: {"role": "AXRow", "text": s, "scope": "app", "visible": True}
STAB = lambda t: {"role": "AXRadioButton|AXButton", "label": t, "scope": "app", "visible": True}
sc = [vid("edit-scheme", "Product ▸ Scheme ▸ Edit Scheme… (cmd+<): the scheme editor sheet (animation). AX tree.",
          [{"menu": "Product > Scheme > Edit Scheme…"}, {"wait": 2.0}, tree("scheme")], post=1.0)]
for s in SECTIONS:
    sc.append(vid(f"section-{s.lower()}", f"Click the {s} section in the sheet's list. AX tree.",
                  [{"click": SEC(s)}, {"wait": 1.2}, tree(s.lower())], post=1.0))
    if s in ("Run", "Test", "Profile"):
        for t in ["Info", "Arguments", "Options", "Diagnostics"]:
            if s != "Run" and t in ("Diagnostics",) and s == "Profile":
                continue
            sc.append(vid(f"{s.lower()}-{t.lower()}", f"{s} ▸ {t} tab (switch animation). AX tree.",
                          [{"click": STAB(t)}, {"wait": 1.0}, tree(f"{s.lower()}-{t.lower()}")], post=0.8))
sc += [
    vid("run-arguments-add", "Run ▸ Arguments: click '+' under Arguments Passed On Launch (a new editable row). "
        "(No Escape afterwards: it closes the reference's sheet.)",
        [{"click": SEC("Run")}, {"wait": 0.8}, {"click": STAB("Arguments")}, {"wait": 0.8},
         {"click": {"role": "AXButton", "label": "add|Add", "scope": "app", "visible": True}}, {"wait": 0.8},
         tree("argument-row")], post=0.8),
    vid("build-config-popup", "Run ▸ Info: the Build Configuration pop-up (menu). AX tree.",
        [{"click": STAB("Info")}, {"wait": 0.8},
         {"click": {"role": "AXPopUpButton", "value": "Debug", "scope": "app", "visible": True}}, {"wait": 0.8},
         tree("config-popup")], post=0.8),
    vid("build-config-close", "Escape.", [{"key": "escape"}], post=0.5),
    tab_walk("scheme-tab-order", "Tab through the sheet (key-view order).", 8),
    vid("scheme-keys", "Down and Up in the section list after clicking Build (keyboard in the list).",
        [{"click": SEC("Build")}, {"wait": 0.5}, {"key": "down"}, {"wait": 0.6}, {"snap": "down", "mode": "app"},
         {"key": "down"}, {"wait": 0.6}, {"key": "up"}, {"wait": 0.6}], post=0.6),
    vid("scheme-close", "Close (button).", [{"press": {"role": "AXButton", "title": "Close|Done", "scope": "app"}},
                                            {"key": "escape", "fallback": True}], post=1.0),
    vid("manage-schemes", "Product ▸ Scheme ▸ Manage Schemes…: the sheet (Parity listed, shared). AX tree.",
        [{"menu": "Product > Scheme > Manage Schemes…"}, {"wait": 1.5}, tree("manage")], post=1.0),
    tab_walk("manage-tab-order", "Tab through it.", 5),
    vid("manage-close", "Close.", [{"press": {"role": "AXButton", "title": "Close|Done|OK", "scope": "app"}},
                                   {"key": "escape", "fallback": True}], post=1.0),
    vid("test-navigator", "cmd+6: the Test navigator. AX tree.", [{"key": "cmd+6"}, {"wait": 1.5}, tree("tests")],
        post=1.0),
    vid("test-expand", "Expand Parity and ParityTests (the two tests listed).",
        [{"set": {"role": "AXRow", "text~": "ParityTests", "index": 0}, "attr": "AXDisclosing", "value": True},
         {"wait": 0.8}, tree("tests-open")], post=1.0),
    vid("test-row-hover", "Pointer onto the testAddition() row, held 2 s (its run button).",
        [{"hover": {"role": "AXRow", "text~": "testAddition"}}, {"wait": 2.0}, tree("test-hover")], post=0.5),
    vid("test-row-context", "Right-click testAddition(): its context menu. AX tree.",
        [{"click": {"role": "AXRow", "text~": "testAddition"}, "button": "right"}, {"wait": 0.8},
         tree("test-context")], post=0.8),
    vid("test-row-context-close", "Escape.", [CLOSE_MENUS], post=0.5),
    vid("open-test-file", "Open ParityTests.swift (click its row in the project navigator): the test diamonds in "
        "the gutter.", [{"key": "cmd+1"}, {"wait": 0.5},
                        {"set": {"role": "AXRow", "text": "ParityTests", "index": 0}, "attr": "AXDisclosing",
                         "value": True}, {"wait": 0.5},
                        {"click": {"role": "AXRow", "text": "ParityTests|ParityTests.swift", "index": 1}},
                        {"wait": 2.0}, tree("test-file")], post=1.0),
    vid("diamond-hover", "Pointer onto the diamond of testAddition (gutter, left of 'func testAddition'), held 2 s.",
        [tc("func testAddition", dx=-40, hover=True), {"wait": 2.0}], post=0.5),
    vid("diamond-run", "Click it: build and run that one test (25 s). Snaps at +3 and +10 s.",
        [tc("func testAddition", dx=-40), {"wait": 3.0}, {"snap": "t3", "mode": "app"}, {"wait": 7.0},
         {"snap": "t10", "mode": "app"}, {"wait": 15.0}], post=0.5),
    shot("diamond-result", "After the single test: the diamond's state. AX tree.", [tree("one-test")]),
    vid("test-all", "Product ▸ Test (cmd+U): both tests (one fails on purpose), 30 s. Snaps at +3 and +10 s.",
        [{"key": "cmd+u"}, {"wait": 3.0}, {"snap": "t3", "mode": "app"}, {"wait": 7.0}, {"snap": "t10", "mode": "app"},
         {"wait": 20.0}], post=0.5),
    shot("test-results-editor", "After the tests: pass and fail diamonds, the failure annotation. AX tree.",
         [tree("results")]),
    vid("test-results-navigator", "cmd+6: the Test navigator with results. AX tree.",
        [{"key": "cmd+6"}, {"wait": 1.0}, tree("results-nav")], post=1.0),
    vid("test-report", "cmd+9: the Report navigator; click the test report (the newest row). AX tree.",
        [{"key": "cmd+9"}, {"wait": 1.0}, {"click": {"role": "AXRow", "text~": "Test", "index": 0}}, {"wait": 2.5},
         tree("test-report")], post=1.0),
]
schemes = script("parity-b-scheme", "Part B 5: the scheme editor (every section and tab, an argument row, the "
                 "configuration pop-up, keyboard), Manage Schemes, the Test navigator, running one test from the "
                 "gutter and all tests, results.", sc, setup=[{"select": ROW("Shapes")}, {"wait": 2.0}])

# ---------------------------------------------------------------- B6 source control (Merger)
LOCAL_EDIT = {"run": ["sh", "-c", "sed -i '' 's/Good morning/Good evening/' Merger/Greeting.swift && "
                      "printf '\\n// A local change for the source control captures.\\nlet localChange = 1\\n' "
                      ">> Merger/Greeting.swift"]}
scm = [
    shot("rest", "Merger open (clean main). AX tree.", [tree("rest")]),
    vid("scm-navigator", "cmd+2: the Source Control navigator (its Changes view, empty). AX tree.",
        [{"key": "cmd+2"}, {"wait": 1.5}, tree("scm")], post=1.0),
    vid("repositories", "Its Repositories view; Merger, Branches and Tags expanded. AX tree.",
        [{"press": {"role": "AXRadioButton", "label": "Repositories"}}, {"wait": 1.0},
         {"set": {"role": "AXRow", "text": "project|Merger"}, "attr": "AXDisclosing", "value": True}, {"wait": 0.6},
         {"set": {"role": "AXRow", "text": "Branches"}, "attr": "AXDisclosing", "value": True}, {"wait": 0.6},
         {"set": {"role": "AXRow", "text": "Tags"}, "attr": "AXDisclosing", "value": True}, {"wait": 0.6},
         tree("repos")], post=1.0),
    vid("branch-main", "Click the main branch row: its history in the editor (commits by Capture Test). AX tree.",
        [{"click": {"role": "AXRow", "text~": "main"}}, {"wait": 2.0}, tree("history")], post=1.0),
    vid("commit-click", "Click the newest commit in that history (its files / detail). AX tree.",
        [{"click": {"role": "AXRow|AXCell|AXGroup|AXButton", "text~": "Time-of-day", "scope": "app",
                    "visible": True}}, {"wait": 2.0}, tree("commit")], post=1.0),
    vid("branch-context", "Right-click the feature branch row: its context menu. AX tree.",
        [{"click": {"role": "AXRow", "text": "feature"}, "button": "right"}, {"wait": 1.0}, tree("feature-menu")],
        post=0.8),
    vid("merge-alert", "Choose 'Merge “feature” into “main”…': the confirmation (alert or sheet). AX tree.",
        [{"press": {"role": "AXMenuItem", "title~": "into “main”", "scope": "app"}}, {"wait": 1.5},
         tree("merge-alert")], post=1.0),
    vid("merge-sheet", "Press Merge: the merge (conflict) sheet (animation), 4 s. AX tree.",
        [{"press": {"role": "AXButton", "title": "Merge", "scope": "app"}}, {"key": "return", "fallback": True},
         {"wait": 4.0}, tree("merge-sheet")], post=1.0),
    vid("merge-cancel", "Cancel the merge sheet.", ESC_OR_CANCEL + [{"wait": 2.0}], post=1.0),
    shot("merge-cleanup", "Not judged: the copy's merge state is reset with git (merge --abort, reset --hard) so "
         "the next steps start clean.", [{"run": ["sh", "-c", "git merge --abort 2>/dev/null; git reset -q --hard; "
                                                              "git status --short"], "allow_fail": True},
                                         {"wait": 3.0}]),
    vid("new-branch-menu", "Right-click the main branch: context menu (New Branch from “main”…).",
        [{"click": {"role": "AXRow", "text~": "main", "index": 0}, "button": "right"}, {"wait": 1.0},
         tree("main-menu")], post=0.8),
    vid("new-branch-sheet", "Choose New Branch…: the sheet (animation). AX tree.",
        [{"press": {"role": "AXMenuItem", "title~": "New Branch", "scope": "app"}}, {"wait": 1.5},
         tree("new-branch")], post=1.0),
    vid("new-branch-type", "Type 'parity-temp' and press Create.",
        [{"text": "parity-temp"}, {"wait": 0.6}, {"snap": "typed", "mode": "app"},
         {"press": {"role": "AXButton", "title": "Create", "scope": "app"}}, {"key": "return", "fallback": True},
         {"wait": 3.0}, tree("branch-created")], post=1.0),
    shot("branch-delete", "Not judged: back to main and the new branch deleted with git; the navigator refreshes.",
         [{"run": ["sh", "-c", "git checkout -q main && git branch -D parity-temp"], "allow_fail": True},
          {"wait": 4.0}, tree("branch-deleted")]),
    vid("local-edit", "Greeting.swift changed on disk (one line edited, two appended); open it from the project "
        "navigator: change bars in the gutter, the M badge.",
        [LOCAL_EDIT, {"wait": 2.0}, {"key": "cmd+1"}, {"wait": 0.6}, {"click": ROW("Greeting")}, {"wait": 2.5},
         tree("changed")], post=1.0),
    vid("change-bar-hover", "Pointer onto the change bar of the edited line ('Good evening'), held 2 s.",
        [tc("Good evening", dx=-120, hover=True), {"wait": 2.0}], post=0.5),
    vid("change-bar-click", "Click the change bar: its menu or inline comparison. AX tree.",
        [tc("Good evening", dx=-120), {"wait": 1.5}, tree("change-bar")], post=1.0),
    vid("change-bar-close", "Escape.", [{"key": "escape"}, {"wait": 0.4}], post=0.6),
    vid("scm-changes", "cmd+2, Changes view: Greeting.swift listed as modified.",
        [{"key": "cmd+2"}, {"wait": 0.6}, {"press": {"role": "AXRadioButton", "label": "Changes"}}, {"wait": 1.5},
         tree("changes")], post=1.0),
    vid("code-review", "Editor ▸ Code Review (option+shift+cmd+Return): the comparison of Greeting.swift "
        "(animation). AX tree.", [{"key": "cmd+1"}, {"wait": 0.4}, {"click": ROW("Greeting")}, {"wait": 1.0},
                                  {"key": "cmd+alt+shift+return"}, {"wait": 2.5}, tree("review")], post=1.0),
    vid("code-review-scroll", "Scroll the comparison 200 pt down and back.", [{"scroll": {"at": [800, 450]},
                                                                             "dy": -200, "steps": 30,
                                                                             "interval": 0.008333}, {"wait": 0.6},
                                                                            {"scroll": {"at": [800, 450]}, "dy": 200,
                                                                             "steps": 30, "interval": 0.008333}],
        post=0.8),
    vid("code-review-off", "Back to the standard editor (cmd+Return).", [{"key": "cmd+return"}, {"wait": 1.5}],
        post=1.0),
    vid("history-inspector", "option+cmd+2: the History inspector for Greeting.swift (three commits). AX tree.",
        [{"key": "cmd+alt+2"}, {"wait": 2.0}, tree("history-inspector")], post=1.0),
    vid("commit-sheet", "Integrate ▸ Commit… (option+cmd+C): the commit sheet (animation). AX tree.",
        [{"key": "cmd+alt+c"}, {"wait": 3.0}, tree("commit-sheet")], post=1.0),
    tab_walk("commit-tab-order", "Tab through the commit sheet (key-view order).", 6),
    vid("commit-message", "Type a message 'Parity capture' into the focused field (stills show where it went).",
        [{"text": "Parity capture"}, {"wait": 0.8}], post=0.8),
    vid("commit-stage-toggle", "Toggle the file's stage checkbox (first checkbox in the sheet), twice.",
        [{"click": {"role": "AXCheckBox", "scope": "app", "visible": True, "index": 0}}, {"wait": 0.8},
         {"snap": "unstaged", "mode": "app"}, {"click": {"role": "AXCheckBox", "scope": "app", "visible": True,
                                                         "index": 0}}, {"wait": 0.8}], post=0.8),
    vid("commit-cancel", "Cancel the commit sheet (nothing committed).", ESC_OR_CANCEL + [{"wait": 1.0}], post=1.0),
    vid("discard-menu", "Right-click Greeting.swift in the project navigator: Source Control ▸ sub-menu (Discard "
        "Changes, Commit, …). AX tree.", [{"click": ROW("Greeting"), "button": "right"}, {"wait": 0.8},
                                         {"hover": MI("Source Control")}, {"wait": 0.8}, tree("scm-submenu")],
        post=0.8),
    vid("discard-menu-close", "Escape.", [CLOSE_MENUS], post=0.5),
    shot("menubar-integrate", "The Integrate menu with a local change (menu bar dump).", [{"menubar": "integrate"}]),
]
source_control = script("parity-b-scm", "Part B 6: source control with Merger: the Source Control navigator (Changes, "
                        "Repositories, branches, tags, history, a commit), the merge confirmation and sheet "
                        "(cancelled), a new branch (deleted again), change bars, Code Review, the History "
                        "inspector, the commit sheet (cancelled), the Source Control context sub-menu.",
                        scm, project=MERGER)

for s in (editor1, editor2, inspectors, projed, build, schemes, source_control):
    (HERE / f"{s['name']}.json").write_text(json.dumps(s, indent=1, ensure_ascii=False) + "\n")
    print(s["name"], len(s["steps"]), "steps")

# ---------------------------------------------------------------- B3b the capability library's way out (Ycode)
# Finding of the first project run: Ycode's capability library is a sheet with only an Add button, and Escape did
# not close it, so every later step of that run happened behind it. This short session tries the other ways out.
cap = [
    shot("open-project", "Not judged: the project editor, Signing & Capabilities.",
         [{"click": {"role": "AXRow", "text": "Parity", "index": 0}}, {"wait": 2.5},
          {"click": TAB("Signing & Capabilities")}, {"wait": 1.5}]),
    vid("capability-library", "Click '+ Capability': the library. AX tree.",
        [{"click": {"role": "AXButton", "label~": "Capability", "visible": True}}, {"wait": 2.0}, tree("library")]),
    tab_walk("library-tab-order", "Tab through the library (key-view order).", 5),
    vid("try-escape", "Escape.", [{"key": "escape"}, {"wait": 1.0}]),
    vid("try-cmd-period", "cmd+. (the standard cancel shortcut).", [{"key": "cmd+."}, {"wait": 1.0}]),
    vid("try-click-outside", "Click outside it, on the navigator.", [{"click": [150, 600]}, {"wait": 1.0}]),
    vid("try-double-click-row", "Double-click App Sandbox (adds it?): what closes the library. AX tree.",
        [{"click": {"role": "AXRow|AXCell|AXStaticText", "text~": "App Sandbox", "scope": "app", "visible": True},
          "count": 2}, {"wait": 1.5}, tree("after-double-click")]),
    shot("end", "What is left: AX tree.", [tree("end")]),
]
caplib = script("parity-b-project-caplib", "Part B 3b: the capability library opened, then Escape, cmd+., a click "
                "outside, and a double-click on a capability (the ways out).", cap,
                setup=[{"select": ROW("Shapes")}, {"wait": 2.0}])
(HERE / f"{caplib['name']}.json").write_text(json.dumps(caplib, indent=1, ensure_ascii=False) + "\n")
print(caplib["name"], len(caplib["steps"]), "steps")
