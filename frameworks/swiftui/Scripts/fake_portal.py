# OV-R10 test tool (not part of the package): a stand-in for
# org.freedesktop.portal.Settings on a private session bus, for checking the
# settings-portal path of OVPlatform/Settings.swift without changing a real
# desktop's settings. Answers ReadAll with light mode, then after 3 s
# switches to dark and a 1.3 text scale (SettingChanged signals). Uses the
# system's PyGObject (LGPL-2.1-or-later) at run time. Run:
#
#   dbus-run-session -- sh -c 'python3 -I fake_portal.py & sleep 1; ov-mini-ide'

import gi
gi.require_version("Gio", "2.0")
from gi.repository import Gio, GLib

XML = """<node><interface name="org.freedesktop.portal.Settings">
<method name="ReadAll"><arg type="as" direction="in"/><arg type="a{sa{sv}}" direction="out"/></method>
<signal name="SettingChanged"><arg type="s"/><arg type="s"/><arg type="v"/></signal>
<property name="version" type="u" access="read"/>
</interface></node>"""
state = {"scheme": 2, "scale": 1.0}
node = Gio.DBusNodeInfo.new_for_xml(XML)

def values():
    return {"org.freedesktop.appearance": {"color-scheme": GLib.Variant("u", state["scheme"])},
            "org.gnome.desktop.interface": {"text-scaling-factor": GLib.Variant("d", state["scale"])}}

def on_call(conn, sender, path, iface, method, params, inv):
    if method == "ReadAll":
        inv.return_value(GLib.Variant("(a{sa{sv}})", (values(),)))
    else:
        inv.return_dbus_error("org.freedesktop.DBus.Error.UnknownMethod", method)

def on_prop(conn, sender, path, iface, prop):
    return GLib.Variant("u", 2)

def flip(conn):
    state["scheme"] = 1
    state["scale"] = 1.3
    for ns, key, v in [("org.freedesktop.appearance", "color-scheme", GLib.Variant("u", 1)),
                       ("org.gnome.desktop.interface", "text-scaling-factor", GLib.Variant("d", 1.3))]:
        conn.emit_signal(None, "/org/freedesktop/portal/desktop", "org.freedesktop.portal.Settings", "SettingChanged",
                         GLib.Variant("(ssv)", (ns, key, v)))
    print("fake portal: switched to dark, text scale 1.3", flush=True)
    return False

def on_bus(conn, name):
    conn.register_object("/org/freedesktop/portal/desktop", node.interfaces[0], on_call, on_prop, None)
    GLib.timeout_add_seconds(3, flip, conn)

Gio.bus_own_name(Gio.BusType.SESSION, "org.freedesktop.portal.Desktop", Gio.BusNameOwnerFlags.NONE, on_bus, None, None)
loop = GLib.MainLoop()
GLib.timeout_add_seconds(20, loop.quit)
loop.run()
