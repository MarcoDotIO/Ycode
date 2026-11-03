#!/usr/bin/env python3
# OV-ATSPI: an AT-SPI client check of an OpenViews app, as an assistive
# technology sees it. Uses the system's libatspi through its GObject
# introspection bindings (at-spi2-core, LGPL-2.1-or-later; PyGObject,
# LGPL-2.1-or-later), run as a separate process; not part of the package.
#
#   python3 -I Scripts/atspi_client.py [app name] [--xdotool <command>]
#
# Finds the application on the desktop, prints its tree (role, name,
# states, actions), checks the window, menu bar, outline rows, editor and
# toolbar buttons, invokes the Build button's action, then listens for
# focus events while it moves the focus (Component.GrabFocus on the
# editor, then on the outline; with --xdotool, also real clicks on the
# outline and the editor). Prints PASS/FAIL lines and exits 1 on a failure.
import sys
import time

import gi

gi.require_version("Atspi", "2.0")
from gi.repository import Atspi, GLib  # noqa: E402

APP = sys.argv[1] if len(sys.argv) > 1 and not sys.argv[1].startswith("--") else "ov-mini-ide"
XDO = sys.argv[sys.argv.index("--xdotool") + 1] if "--xdotool" in sys.argv else None
failures = []


def check(ok, what):
    print(("PASS " if ok else "FAIL ") + what, flush=True)
    if not ok:
        failures.append(what)


def states(a):
    return sorted(Atspi.StateType(s).value_nick for s in a.get_state_set().get_states())


def actions(a):
    act = a.get_action_iface()
    if act is None:
        return []
    return [act.get_action_name(i) for i in range(act.get_n_actions())]


def children(a):
    return [a.get_child_at_index(i) for i in range(a.get_child_count())]


def walk(a, depth=0, out=None):
    if out is None:
        out = []
    out.append(a)
    line = "  " * depth + "%s %r [%s]" % (a.get_role_name(), a.get_name(), ",".join(states(a)))
    acts = actions(a)
    if acts:
        line += " actions=" + ",".join(acts)
    print(line, flush=True)
    for c in children(a):
        if c is not None:
            walk(c, depth + 1, out)
    return out


def find_app(name, timeout=20):
    deadline = time.time() + timeout
    while time.time() < deadline:
        desktop = Atspi.get_desktop(0)
        for app in children(desktop):
            if app is not None and app.get_name() == name:
                return app
        time.sleep(0.5)
    return None


ALIASES = {"push button": ("push button", "button")}


def first(nodes, role, name=None):
    for n in nodes:
        if n.get_role_name() in ALIASES.get(role, (role,)) and (name is None or n.get_name() == name):
            return n
    return None


def pump(seconds):
    loop = GLib.MainLoop()
    GLib.timeout_add(int(seconds * 1000), loop.quit)
    loop.run()


app = find_app(APP)
check(app is not None, "application %r is on the desktop" % APP)
if app is None:
    sys.exit(1)
print("toolkit", app.get_toolkit_name(), "id", app.get_id(), flush=True)
nodes = walk(app)

window = first(nodes, "frame")
check(window is not None and "mini IDE" in window.get_name(), "a frame named like the window title")
check(window is not None and "active" in states(window), "the window is active")
menubar = first(nodes, "menu bar")
menus = [c.get_name() for c in children(menubar)] if menubar else []
check(all(m in menus for m in ["File", "Edit", "View", "Project", "Window", "Help"]), "menu bar menus %s" % menus)
tree = first(nodes, "tree")
rows = [n for n in nodes if n.get_role_name() == "tree item"]
check(tree is not None and len(rows) >= 2, "an outline (tree) with rows: %s" % [r.get_name() for r in rows])
folder = next((r for r in rows if "expandable" in states(r)), None)
check(folder is not None and "expand or collapse" in actions(folder), "a folder row that expands")
# Open a file: the row's default action selects it, and the editor shows it.
file_row = next((r for r in rows if "expandable" not in states(r)), None)
check(file_row is not None and file_row.get_action_iface().do_action(0), "activate the row %r" % (file_row.get_name() if file_row else None))
time.sleep(1.0)
nodes = []
nodes = walk(app, out=nodes)
check(any("selected" in states(r) for r in nodes if r.get_role_name() == "tree item"), "the row is selected")
editor = first(nodes, "text")
content = Atspi.Text.get_text(editor, 0, -1) if editor is not None and editor.get_text_iface() else ""
check(editor is not None and "editable" in states(editor) and len(content) > 0,
      "an editable multi-line editor with text (%d characters)" % len(content))
toolbar = first(nodes, "tool bar")
build = first(nodes, "push button", "Build")
run = first(nodes, "push button", "Run")
check(toolbar is not None and build is not None and run is not None, "toolbar buttons Build and Run")
check(build is not None and actions(build) == ["click"], "Build's action is click")
if build is not None:
    ext = build.get_component_iface().get_extents(Atspi.CoordType.WINDOW)
    check(ext.width > 0 and ext.height > 0, "Build has extents %s" % [ext.x, ext.y, ext.width, ext.height])

# Invoke Build; the toolbar's status text follows.
status_before = [n.get_name() for n in nodes if n.get_role_name() == "label"]
ok = build.get_action_iface().do_action(0) if build else False
check(ok, "DoAction(click) on Build returned true")
time.sleep(1.0)


def collect(a, out):
    out.append(a)
    for c in children(a):
        if c is not None:
            collect(c, out)
    return out


nodes2 = collect(app, [])
labels_after = [n.get_name() for n in nodes2 if n.get_role_name() == "label"]
changed = [s for s in labels_after if s not in status_before]
print("labels new after Build:", changed, flush=True)
check(any("succeeded" in x for x in changed), "the toolbar status follows the build: %s" % changed)

# Focus events.
events = []


def on_event(e):
    try:
        src = e.source
        events.append((e.type, e.detail1, src.get_role_name() if src else None, src.get_name() if src else None))
    except Exception as x:  # noqa: BLE001
        events.append((e.type, e.detail1, "error", str(x)))


listener = Atspi.EventListener.new(on_event)
listener.register("object:state-changed:focused")
listener.register("focus:")
listener.register("object:text-changed")
pump(1.0)
tree = first(nodes2, "tree")
editor = first(nodes2, "text")
# Activating the row focused the outline: move the focus to the editor,
# then back to the outline.
check("focused" in states(tree), "the outline has the focus after the row was activated")
check(editor is not None and editor.get_component_iface().grab_focus(), "GrabFocus on the editor")
pump(1.5)
check(any(t.startswith("object:state-changed:focused") and d == 1 and r == "text" for t, d, r, _ in events),
      "focused event from the editor")
check(any(t.startswith("object:state-changed:focused") and d == 0 and r == "tree" for t, d, r, _ in events),
      "the outline lost focus")
check(any(t.startswith("focus") and r == "text" for t, d, r, _ in events), "focus: event from the editor")
check("focused" in states(editor), "the editor's state has focused")
print("events:", events, flush=True)
del events[:]
check(tree.get_component_iface().grab_focus(), "GrabFocus on the outline")
pump(1.5)
check(any(t.startswith("object:state-changed:focused") and d == 1 and r == "tree" for t, d, r, _ in events),
      "focused event from the outline")
print("events:", events, flush=True)

# Editing through EditableText: the editor reports the insertion.
del events[:]
check(Atspi.EditableText.insert_text(editor, 0, "// ", 3), "InsertText into the editor")
pump(1.5)
check(any(t.startswith("object:text-changed:insert") and r == "text" for t, d, r, _ in events),
      "text-changed:insert from the editor")
check(Atspi.Text.get_text(editor, 0, 3) == "// ", "the editor's text starts with the insertion")

if XDO:
    # A real click (XTEST) on the outline, then on the editor.
    import subprocess

    del events[:]
    ext = tree.get_component_iface().get_extents(Atspi.CoordType.SCREEN)
    subprocess.run(XDO.split() + ["mousemove", str(ext.x + ext.width // 2), str(ext.y + 40), "click", "1"], check=False)
    pump(1.5)
    ext = editor.get_component_iface().get_extents(Atspi.CoordType.SCREEN)
    subprocess.run(XDO.split() + ["mousemove", str(ext.x + ext.width // 2), str(ext.y + ext.height // 2), "click", "1"],
                   check=False)
    pump(1.5)
    print("events after clicks:", events, flush=True)
    check(any(t.startswith("object:state-changed:focused") and d == 1 and r == "text" for t, d, r, _ in events),
          "a real click on the editor sends focused")

listener.deregister("object:state-changed:focused")
listener.deregister("focus:")
listener.deregister("object:text-changed")
print("RESULT", "FAIL" if failures else "PASS", len(failures), flush=True)
sys.exit(1 if failures else 0)
