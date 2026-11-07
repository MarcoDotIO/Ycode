#!/usr/bin/env python3
"""Run one capture session script against one or more apps.

    python3 -I research/tools/capture/session.py SCRIPT.json --target ycode [--target xcode]
            [--council | --allow-focus] [--allow-1x] [--owner-approved]
            [--out DIR] [--keep-open] [--no-compare]

--council is the review council's preset: the foreground (the app is brought
to the front, so its window is active; implies --allow-focus), real
scroll-wheel events with gesture and momentum phases instead of AX scrolls,
and 120 fps recording where the display refreshes that fast.

For each target the session copies the test project, opens it in the app in
the background, places and sizes the app's window, runs the script's steps
and records each one with wincap (that window only). It writes
OUT/<target>/manifest.json, then comparison sheets in OUT/compare/.
OUT defaults to research/dirty/captures/<date>-<script name>/, which is
git-ignored. The script format is in README.md next to this file.

Limits that the tool enforces:
- A target marked "needs_owner_ok" (Xcode) runs only with --owner-approved.
- Steps that need keyboard focus (menu, key, text, click) run only when the
  script asks for "focus": "foreground" and --allow-focus is given: the app
  is then brought to the front for the session, which takes the keyboard
  from whoever uses the Mac. Without it, those steps are skipped.
- An app instance that this session did not start is never used or killed.
- Captures are made at 2x: the window goes on the built-in (Retina)
  display. If a full-screen app occupies it, the session stops before
  launching anything; --allow-1x uses the main display instead.
- A target with "require_current_sdk" (Ycode) must declare, in
  LC_BUILD_VERSION, an SDK whose major version is at least the running
  macOS's; otherwise AppKit draws its pre-macOS-26 fallback look. The
  capture wrapper stamps the SDK the way ycode/scripts/make-app.sh does.
"""

import argparse
import datetime
import json
import os
import pathlib
import plistlib
import shutil
import signal
import subprocess
import sys
import time

HERE = pathlib.Path(__file__).resolve().parent
REPO = HERE.parents[2]
WINCAP_DIR = REPO / "tools" / "capture" / "wincap"
AXDRIVE_DIR = HERE / "axdrive"
sys.path.insert(0, str(REPO / "tools" / "capture"))

# AppKit ignores posted keys, clicks and drags in an app that is not frontmost,
# and menu items that act on a window are disabled while the app has no main
# window; these need the foreground. press, set, hover and scroll (through AX
# scroll bars) work in the background.
FOCUS_ACTIONS = {"menu", "key", "text", "click", "drag"}
ACTION_KINDS = {"open", "press", "set", "select", "menu", "key", "text", "click", "hover", "scroll", "drag", "wait",
                "resize", "run", "move"}
COUNCIL_FPS = 120


def build_version(binary):
    """(minos, sdk) from the executable's LC_BUILD_VERSION, via vtool."""
    out = subprocess.run(["vtool", "-show-build", str(binary)], capture_output=True, text=True).stdout
    fields = dict(line.split(None, 1) for line in map(str.strip, out.splitlines()) if line and " " in line)
    return fields.get("minos", "?").strip(), fields.get("sdk", "?").strip()


def major(version):
    try:
        return int(str(version).split(".")[0])
    except ValueError:
        return 0


def macos_version():
    return subprocess.run(["sw_vers", "-productVersion"], capture_output=True, text=True).stdout.strip()


def stamp_sdk(src, dest):
    """Copy src to dest with LC_BUILD_VERSION's SDK set to the SDK it was
    built with (as make-app.sh does), then sign it ad hoc again."""
    sdk = subprocess.run(["xcrun", "--sdk", "macosx", "--show-sdk-version"], capture_output=True,
                         text=True, check=True).stdout.strip()
    minos, _ = build_version(src)
    subprocess.run(["vtool", "-set-build-version", "macos", minos, sdk, "-replace", "-output", str(dest), str(src)],
                   check=True, capture_output=True)
    subprocess.run(["codesign", "--force", "--sign", "-", str(dest)], check=True, capture_output=True)


def log(*parts):
    print("session:", *parts, file=sys.stderr, flush=True)


def tool(directory: pathlib.Path, name: str) -> pathlib.Path:
    binary = directory / ".build" / "debug" / name
    if not binary.exists():
        log(f"building {name}")
        subprocess.run(["swift", "build", "--package-path", str(directory)], check=True,
                       stdout=sys.stderr)
    return binary


def alert_buttons(tree_result):
    """The buttons inside AXSheet and AXDialog elements of an axdrive tree."""
    found = []

    def walk(node, inside):
        role = node.get("role", "")
        here = inside or role == "AXSheet" or node.get("subrole") in ("AXDialog", "AXSystemDialog")
        if here and role == "AXButton":
            found.append(node.get("title") or node.get("description") or "")
        for child in node.get("children", []):
            walk(child, here)

    for root in tree_result.get("tree", []):
        walk(root, False)
    return {"alert_buttons": found}


class Driver:
    """axdrive, bound to one PID."""

    def __init__(self, binary, pid=None):
        self.binary, self.pid = binary, pid

    def run(self, *args, check=True):
        cmd = [str(self.binary), *args]
        if self.pid and args[0] not in ("check", "apps", "displays"):
            cmd += ["--pid", str(self.pid)]
        proc = subprocess.run(cmd, capture_output=True, text=True)
        try:
            out = json.loads(proc.stdout.strip().splitlines()[-1])
        except (IndexError, json.JSONDecodeError):
            out = {"ok": False, "error": proc.stderr.strip() or proc.stdout.strip()}
        out["exit"] = proc.returncode
        if check and proc.returncode != 0:
            raise RuntimeError(f"axdrive {' '.join(args)}: {out.get('error', out)}")
        return out


def match_args(spec):
    """{"role": "AXButton", "description~": "Inspector", "index": 1} -> axdrive options."""
    args = []
    for key, value in spec.items():
        if key in ("index", "scope", "window"):
            args += [f"--{key}", str(value)]
        elif key.endswith("~"):
            args += ["--match", f"{key[:-1]}~={value}"]
        else:
            args += ["--match", f"{key}={value}"]
    return args


def point_args(action, key):
    target = action[key]
    if isinstance(target, list):
        return ["--at", f"{target[0]},{target[1]}"]
    if isinstance(target, dict) and "at" in target:
        return ["--at", f"{target['at'][0]},{target['at'][1]}"]
    return match_args(target)


def substitute(value, names):
    if isinstance(value, str):
        for k, v in names.items():
            value = value.replace("{" + k + "}", str(v))
        return value
    if isinstance(value, list):
        return [substitute(v, names) for v in value]
    if isinstance(value, dict):
        return {k: substitute(v, names) for k, v in value.items()}
    return value


class Target:
    def __init__(self, name, spec, args):
        self.name, self.spec, self.args = name, spec, args
        self.label = spec.get("label", name)
        self.bundle_id = spec.get("bundle_id")
        self.app_path = None

    def resolve_app(self, apps_dir: pathlib.Path):
        """The .app to open. A bare executable (Ycode from `swift build`) is
        wrapped in a minimal bundle with its own bundle ID, so it opens in the
        background like any app and never shares the installed app's settings."""
        spec = self.spec
        if "app_env" in spec and os.environ.get(spec["app_env"]):
            self.app_path = pathlib.Path(os.environ[spec["app_env"]])
        elif "app" in spec:
            self.app_path = (REPO / spec["app"]).resolve()
        elif "executable" in spec:
            exe = (REPO / spec["executable"]).resolve()
            if not exe.exists():
                raise SystemExit(f"{exe} is missing: build it first ({spec.get('build_hint', '')})")
            bundle = apps_dir / f"{spec.get('bundle_name', exe.name)}.app"
            macos = bundle / "Contents" / "MacOS"
            macos.mkdir(parents=True, exist_ok=True)
            dest = macos / exe.name
            stale = not dest.exists() or dest.stat().st_mtime < exe.stat().st_mtime
            if spec.get("stamp_sdk") and not stale:
                stale = major(build_version(dest)[1]) < major(macos_version())
            if stale:
                if spec.get("stamp_sdk"):
                    stamp_sdk(exe, dest)
                else:
                    shutil.copy2(exe, dest)
            info = {"CFBundleIdentifier": self.bundle_id, "CFBundleExecutable": exe.name,
                    "CFBundleName": spec.get("bundle_name", exe.name), "CFBundlePackageType": "APPL",
                    "CFBundleShortVersionString": "0.0-capture", "CFBundleVersion": "1",
                    "NSPrincipalClass": "NSApplication", "NSHighResolutionCapable": True}
            with open(bundle / "Contents" / "Info.plist", "wb") as f:
                plistlib.dump(info, f)
            self.app_path = bundle
        if not self.app_path or not self.app_path.exists():
            hint = f"set {spec['app_env']}" if "app_env" in spec else "check targets.json"
            raise SystemExit(f"target {self.name}: app not found ({hint})")
        info = plistlib.loads((self.app_path / "Contents" / "Info.plist").read_bytes())
        self.executable = self.app_path / "Contents" / "MacOS" / info["CFBundleExecutable"]
        self.minos, self.sdk = build_version(self.executable)
        if spec.get("require_current_sdk"):
            system = macos_version()
            if major(self.sdk) < major(system):
                raise SystemExit(f"{self.executable} declares SDK {self.sdk} (vtool -show-build) on macOS {system}: "
                                 "AppKit would draw its older look. Stamp it as ycode/scripts/make-app.sh does "
                                 "(vtool -set-build-version macos <minos> <SDK> -replace), or delete the wrapper "
                                 "so the session stamps it again.")
        return self.app_path


def choose_display(ax, wanted, allow_1x):
    """The display the test window goes on, decided before anything is
    launched. Default: the built-in Retina display, which must be free."""
    displays = ax.run("displays")["displays"]
    if wanted in ("builtin", "retina"):
        good = [d for d in displays if (d["builtin"] if wanted == "builtin" else d["scale"] >= 2)]
        free = [d for d in good if not d.get("full_screen_app")]
        if free:
            return free[0]
        if good:
            why = f"{good[0]['full_screen_app']} is full screen on the built-in display"
        else:
            why = "no Retina display is attached"
        if not allow_1x:
            raise SystemExit(f"{why}. Leave the built-in display free (no full-screen app on it), then rerun; "
                             "or pass --allow-1x to capture at 1x on the main display.")
        log(f"{why}; --allow-1x: using the main display")
    elif isinstance(wanted, int):
        for d in displays:
            if d["id"] == wanted and not d.get("full_screen_app"):
                return d
    main = next((d for d in displays if d["main"]), displays[0])
    if main["scale"] < 2 and not allow_1x:
        raise SystemExit("the chosen display is 1x; pass --allow-1x to accept 1x captures")
    return main


def win_display(script):
    return script.get("window", {}).get("display", "builtin")


class Session:
    def __init__(self, script_path, args):
        self.script_path = pathlib.Path(script_path).resolve()
        self.script = json.loads(self.script_path.read_text())
        self.args = args
        self.name = self.script["name"]
        date = datetime.date.today().isoformat()
        self.out = pathlib.Path(args.out).resolve() if args.out else REPO / "research" / "dirty" / "captures" / f"{date}-{self.name}"
        self.wincap = tool(WINCAP_DIR, "wincap")
        self.axdrive = tool(AXDRIVE_DIR, "axdrive")
        targets = json.loads((HERE / "targets.json").read_text())
        self.targets = {k: Target(k, v, args) for k, v in targets.items()}
        self.ax_window, self.window_select = [], []
        self.fps = 60
        if args.council:
            args.allow_focus = True

    # ------------------------------------------------------------ setup

    def check_permissions(self):
        w = subprocess.run([str(self.wincap), "check"], capture_output=True, text=True)
        a = subprocess.run([str(self.axdrive), "check"], capture_output=True, text=True)
        problems = []
        if w.returncode != 0:
            problems.append("Screen Recording (System Settings > Privacy & Security > Screen & System Audio Recording)")
        if a.returncode != 0:
            problems.append("Accessibility (System Settings > Privacy & Security > Accessibility)")
        if problems:
            chain = json.loads(w.stdout.strip().splitlines()[-1]).get("process_chain", []) if w.stdout.strip() else []
            raise SystemExit("missing permission: " + "; ".join(problems) +
                             ". Grant it to the app that runs this command (see the process chain), then restart it:\n  "
                             + "\n  ".join(chain))

    def project_copy(self, target_dir: pathlib.Path) -> pathlib.Path:
        """A fresh copy of the test project. With --project-dir it goes there
        (a folder outside any git repository: the apps would otherwise show
        the enclosing repository, this one, in their source control views)."""
        p = self.script["project"]
        source_root = REPO / "research" / "dirty" / "test-projects"
        if "generator" in p:
            subprocess.run([sys.executable, "-I", str(HERE / p["generator"]), str(source_root)], check=True,
                           stdout=subprocess.DEVNULL)
        src = source_root / p["path"].split("/")[0]
        if self.args.project_dir:
            dest = pathlib.Path(self.args.project_dir).resolve() / self.name / target_dir.name / "project"
            dest.parent.mkdir(parents=True, exist_ok=True)
        else:
            dest = target_dir / "project"
        if dest.exists():
            shutil.rmtree(dest)
        shutil.copytree(src, dest)
        return dest

    def launch(self, target: Target, documents):
        ax = Driver(self.axdrive)
        # Match by bundle path, not only by ID: other copies of the same app
        # (another Xcode version) may be open and are left alone.
        app_dir = str(target.app_path.resolve()) + "/"
        ours = lambda a: a.get("path", "").startswith(app_dir)
        running = [a for a in ax.run("apps", "--bundle", target.bundle_id)["apps"] if ours(a)]
        if running:
            raise SystemExit(f"{target.label} ({target.bundle_id}) is already running as PID "
                             f"{', '.join(str(a['pid']) for a in running)}; this session only uses an instance it "
                             "starts itself. Quit that one first.")
        frontmost = next((a for a in ax.run("apps")["apps"] if a["active"]), None)
        if target.spec.get("reset_defaults"):
            # Only the capture wrapper's own domain: restored window frames would
            # put the window wherever the last session left it.
            subprocess.run(["defaults", "delete", target.bundle_id], capture_output=True)
        t0 = time.time()
        extra = target.spec.get("launch_args", [])
        cmd = ["open", "-g", "-n", "-a", str(target.app_path), *map(str, documents)]
        if extra:
            cmd += ["--args", *extra]
        subprocess.run(cmd, check=True)
        deadline = time.time() + 60
        while time.time() < deadline:
            apps = [a for a in ax.run("apps", "--bundle", target.bundle_id)["apps"] if a["launched"] >= t0 - 1 and ours(a)]
            if apps:
                return apps[0]["pid"], frontmost
            time.sleep(0.25)
        raise SystemExit(f"{target.label} did not start within 60 s")

    def windows(self, pid, title):
        r = subprocess.run([str(self.wincap), "list", "--pid", str(pid)], capture_output=True, text=True)
        return [w for w in json.loads(r.stdout or "[]") if title.lower() in w["title"].lower() and w["layer"] == 0]

    def on_screen(self, pid, window_id):
        return any(w["on_screen"] for w in self.windows(pid, "") if w["id"] == window_id)

    def place(self, ax, pid, win, title, display):
        """Pick the session window (the frontmost window whose title contains
        `title`: opening a file may have made a new one), raise it within its
        app (no activation), size it and put it on
        the display chosen before launch. Afterwards wincap selects the
        window by its id and axdrive by its position, since titles change as
        files open."""
        candidates = self.windows(pid, title)
        if not candidates:
            raise SystemExit(f"no window titled {title!r}")
        front = [w for w in candidates if w["on_screen"] and w["z"] >= 0]
        chosen = min(front, key=lambda w: w["z"]) if front else candidates[0]
        self.window_select = ["--window-id", str(chosen["id"])]
        w, h = win.get("size", [1280, 800])
        dx, dy, dw, dh = display["frame"]
        w, h = min(w, dw - 20), min(h, dh - 60)
        px, py = win.get("position", [dx + (dw - w) / 2, dy + 40 + (dh - 40 - h) / 2])
        if "offset" in win:
            # [x, y] from the display's top left (room below the window for a
            # sheet taller than it, captured with a "margin").
            px, py = dx + win["offset"][0], dy + win["offset"][1]
        placed = ax.run("window", "--window", chosen["title"], "--position", f"{px},{py}", "--size", f"{w},{h}",
                        "--raise")
        frame = placed["window"]["frame"]
        self.ax_window = ["--window-origin", f"{frame[0]},{frame[1]}"]
        time.sleep(0.5)
        if not self.on_screen(pid, chosen["id"]):
            raise SystemExit(f"the test window is not visible on display {display['id']} "
                             "(did a full-screen app take it over?)")
        return {**placed["window"], "id": chosen["id"]}

    # ------------------------------------------------------------ actions

    def act(self, ax: Driver, action, names, project_dir, focus):
        kind = next((k for k in action if k in ACTION_KINDS), None)
        if kind is None:
            raise ValueError(f"unknown action {action}")
        if kind in FOCUS_ACTIONS and focus != "foreground":
            return {"ok": False, "skipped": "needs focus: run with \"focus\": \"foreground\" and --allow-focus"}
        a = substitute(action, names)
        window = ["--window", a["window"]] if "window" in a else list(self.ax_window)
        # In the foreground, pointer and wheel events go through the system's
        # event stream (axdrive --route tap); AppKit ignores them posted to a PID.
        route = ["--route", "tap"] if focus == "foreground" else []
        if kind == "wait":
            time.sleep(float(a["wait"]))
            return {"ok": True, "wall": time.time()}
        if kind == "open":
            path = project_dir / a["open"]
            start = time.time()
            subprocess.run(["open", "-g", "-a", str(names["app_path"]), str(path)], check=True)
            return {"ok": True, "wall_start": start, "wall": time.time()}
        if kind == "press":
            extra = ["--action", a["action"]] if "action" in a else []
            return ax.run("press", *match_args(a["press"]), *window, *extra, check=False)
        if kind == "set":
            value = a["value"]
            value = ("true" if value else "false") if isinstance(value, bool) else str(value)
            return ax.run("set", *match_args(a["set"]), *window, "--attr", a["attr"], "--value", value, check=False)
        if kind == "select":
            return ax.run("select", *match_args(a["select"]), *window, check=False)
        if kind == "menu":
            return ax.run("menu", "--path", a["menu"], check=False)
        if kind == "key":
            return ax.run("key", "--keys", a["key"], check=False)
        if kind == "text":
            return ax.run("key", "--text", a["text"], check=False)
        if kind in ("click", "hover"):
            extra = []
            if kind == "click":
                extra = ["--button", a.get("button", "left"), "--count", str(a.get("count", 1))]
            return ax.run(kind, *point_args(a, kind), *window, *route, *extra, check=False)
        if kind == "scroll":
            via = a.get("via", "events" if focus == "foreground" else "ax")
            extra = ["--ax"] if via == "ax" else list(route)
            extra += ["--dy", str(a.get("dy", 0)), "--dx", str(a.get("dx", 0)), "--steps", str(a.get("steps", 20)),
                     "--interval", str(a.get("interval", 1 / 60))]
            if a.get("phases"):
                extra.append("--phases")
            if a.get("momentum"):
                extra += ["--momentum", "--momentum-tau", str(a.get("momentum_tau", 0.33))]
            return ax.run("scroll", *point_args(a, "scroll"), *window, *extra, check=False)
        if kind == "drag":
            d = a["drag"]
            return ax.run("drag", "--from", f"{d['from'][0]},{d['from'][1]}", "--to", f"{d['to'][0]},{d['to'][1]}",
                          "--duration", str(a.get("duration", 0.4)), *window, *route, check=False)
        if kind == "run":
            # A command in the project copy (for example `git merge`), for an
            # app that has no menu path for that step.
            start = time.time()
            proc = subprocess.run([str(x) for x in a["run"]], cwd=project_dir, capture_output=True, text=True)
            return {"ok": proc.returncode == 0 or a.get("allow_fail", False), "wall_start": start, "wall": time.time(),
                    "exit_status": proc.returncode, "output": (proc.stdout + proc.stderr)[-400:]}
        if kind == "move":
            # Put another window of the app (Settings) on the session's display:
            # [x, y] from the display's top left; "window" picks it by title.
            dx, dy = self.display["frame"][:2]
            x, y = a["move"]
            return ax.run("window", *window, "--position", f"{dx + x},{dy + y}", "--raise", check=False)
        if kind == "resize":
            w, h = a["resize"]
            return ax.run("window", "--size", f"{w},{h}", *window, check=False)
        raise ValueError(kind)

    # ------------------------------------------------------------ capture

    def still(self, pid, path, mode, select=None, margin=None):
        extra = ["--margin", str(margin)] if margin and mode == "app" else []
        r = subprocess.run([str(self.wincap), "still", "--pid", str(pid), "--mode", mode, *(select or self.window_select),
                            *extra, "-o", str(path)], capture_output=True, text=True)
        if r.returncode != 0:
            log(f"still failed: {r.stderr.strip()}")
            return None
        return path.name

    def start_recording(self, pid, path, rec, select=None):
        cmd = [str(self.wincap), "record", "--pid", str(pid), *(select or self.window_select), "-o", str(path),
               "--fps", str(rec.get("fps", 60)), "--codec", rec.get("codec", "prores4444"),
               "--mode", rec.get("mode", "window"), "--duration", str(rec.get("max", 30))]
        if rec.get("margin"):
            cmd += ["--margin", str(rec["margin"])]
        if rec.get("cursor"):
            cmd.append("--cursor")
        proc = subprocess.Popen(cmd, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        deadline = time.time() + 10
        while time.time() < deadline:
            line = proc.stdout.readline()
            if not line:
                break
            event = json.loads(line)
            if event.get("event") == "first_frame":
                return proc, event["wall"]
        proc.kill()
        raise RuntimeError(f"wincap did not start: {proc.stderr.read()}")

    def stop_recording(self, proc):
        proc.send_signal(signal.SIGINT)
        out, err = proc.communicate(timeout=60)
        events = [json.loads(line) for line in out.splitlines() if line.strip()]
        return next((e for e in events if e.get("event") == "done"), {"error": err.strip()})

    # ------------------------------------------------------------ run

    def run_target(self, target: Target):
        spec = target.spec
        if spec.get("needs_owner_ok") and not self.args.owner_approved:
            raise SystemExit(f"{target.label} runs only with --owner-approved (the owner agrees to each such session)")
        focus = "foreground" if self.args.council else self.script.get("focus", "background")
        if focus == "foreground" and not self.args.allow_focus:
            log("the script asks for the foreground; without --allow-focus, focus steps are skipped")
            focus = "background"
        target_dir = self.out / target.name
        target_dir.mkdir(parents=True, exist_ok=True)
        app = target.resolve_app(REPO / "research" / "dirty" / "apps")
        display = choose_display(Driver(self.axdrive), win_display(self.script), self.args.allow_1x)
        self.display = display
        self.fps = self.frame_rate(display)
        if "project" in self.script and target.name in self.script.get("project_targets", [target.name]):
            project_dir = self.project_copy(target_dir)
            project_file = project_dir / self.script["project"]["path"].split("/", 1)[1]
            documents = [project_file]
        else:
            project_dir, project_file, documents = target_dir, None, []
        names = {"app": spec.get("app_name", target.label), "project": project_file.stem if project_file else "",
                 "app_path": app}
        names.update(self.script.get("names", {}).get(target.name, {}))
        win = self.script.get("window", {})
        title = substitute(win.get("title", "{project}"), names)
        self.window_select = ["--title", title]

        pid, frontmost = self.launch(target, documents)
        log(f"{target.label}: PID {pid}")
        ax = Driver(self.axdrive, pid)
        manifest = {
            "format": "capture-session/1", "session": self.name, "script": self.script_path.name,
            "issue": self.script.get("issue"), "target": target.name, "label": target.label,
            "created": datetime.datetime.now().astimezone().isoformat(timespec="seconds"),
            "app": {"pid": pid, "bundle_id": target.bundle_id, "name": app.name, "minos": target.minos,
                    "sdk": target.sdk},
            "macos": macos_version(), "focus": focus, "council": bool(self.args.council), "fps": self.fps,
            "display": display, "steps": [],
        }
        try:
            if "wait_title" in win and win["wait_title"] is None:
                # The first window's title is not known in advance (a tool
                # window showing whatever it showed last): wait for any.
                time.sleep(float(win.get("first_window_wait", 5.0)))
            else:
                ax.run("wait", "--window", substitute(win.get("wait_title", title), names), "--timeout",
                       str(win.get("timeout", 60)))
            self.ax_window = []
            time.sleep(float(self.script.get("launch_settle", 2.0)))
            setup = self.script.get("setup", [])
            setup = self.script.get("per_target_setup", {}).get(target.name, setup)
            if focus == "foreground" and setup:
                # Setup menus and keys (opening a tool window) need the front.
                ax.run("activate", check=False)
                time.sleep(0.5)
            for action in setup:
                r = self.act(ax, action, names, project_dir, focus)
                if not r.get("ok"):
                    log(f"setup {action}: {r}")
            time.sleep(float(self.script.get("setup_settle", 1.0)))
            manifest["window"] = self.place(ax, pid, win, title, display)
            if focus == "foreground":
                if not ax.run("activate", check=False).get("active"):
                    log("could not bring the app to the front; foreground steps may fail")
                ax.run("window", *self.ax_window, "--main", "--raise", check=False)
            time.sleep(0.5)
            for index, step in enumerate(self.script["steps"], 1):
                if step.get("only") and target.name not in step["only"]:
                    continue
                if self.args.steps and step["id"] not in self.args.steps.split(","):
                    continue  # a re-run of some steps keeps their numbers
                step = {**step, **step.get("per_target", {}).get(target.name, {})}
                step = {**step, **step.get("per_focus", {}).get(focus, {})}
                manifest["steps"].append(self.run_step(index, step, ax, pid, names, project_dir, focus, target_dir))
                (target_dir / "manifest.json").write_text(json.dumps(manifest, indent=1))
        finally:
            if not self.args.keep_open:
                try:
                    os.kill(pid, signal.SIGTERM)
                except ProcessLookupError:
                    pass
            if focus == "foreground" and frontmost:
                Driver(self.axdrive, frontmost["pid"]).run("activate", check=False)
            (target_dir / "manifest.json").write_text(json.dumps(manifest, indent=1))
        return target_dir / "manifest.json"

    def run_step(self, index, step, ax, pid, names, project_dir, focus, target_dir):
        sid = f"{index:02d}-{step['id']}"
        log(f"step {sid}")
        rec = {**self.script.get("record", {}), **(step.get("record") or {}), "fps": self.fps}
        # "record": {"video": false, "mode": "app"} keeps the still's mode without a video.
        record = step.get("record", True) is not False and rec.get("video", True)
        stills = step.get("still", "both")
        mode = rec.get("mode", "window")
        # "capture_title": this step records another window of the app (Settings),
        # chosen by title, instead of the session window.
        select = ["--title", substitute(step["capture_title"], names)] if step.get("capture_title") else None
        entry = {"index": index, "id": step["id"], "note": step.get("note", ""), "actions": [], "ok": True}
        if step.get("crop"):
            entry["crop"] = step["crop"]  # [x, y, w, h] in window points: a detail sheet of the after stills
        if focus == "foreground":
            # Something else may have taken the front since the last step;
            # take it back before the stills and the recording start.
            if not ax.run("activate", check=False).get("active"):
                log("  could not bring the app to the front")
            time.sleep(0.3)
        if stills in ("before", "both"):
            entry["still_before"] = self.still(pid, target_dir / f"{sid}-before.png", mode, select, rec.get("margin"))
        proc = None
        if record:
            video = target_dir / f"{sid}.mov"
            proc, first_wall = self.start_recording(pid, video, rec, select)
            entry["video"] = video.name
            entry["video_first_frame_wall"] = first_wall
            time.sleep(float(rec.get("pre", 0.4)))
        try:
            for action in step.get("do", []):
                t = time.time()
                if "tree" in action:
                    # The app's accessibility tree at this moment, as another
                    # process sees it (an alert's buttons): NN-step-<name>-tree.json,
                    # with the buttons inside sheets and dialogs counted.
                    name = f"{sid}-{action['tree']}-tree.json"
                    r = ax.run("tree", "--scope", "app", "--depth", str(action.get("depth", 12)), check=False)
                    (target_dir / name).write_text(json.dumps(r, indent=1))
                    entry.setdefault("trees", {})[action["tree"]] = {"file": name, **alert_buttons(r)}
                    continue
                if action.get("fallback"):
                    # Runs only when the action before it failed (a key press in
                    # place of an AX press whose element was not found).
                    last = entry["actions"][-1]["result"] if entry["actions"] else {"ok": False}
                    if last.get("ok"):
                        entry["actions"].append({"spec": action, "result": {"ok": True, "skipped": "fallback not needed",
                                                                            "wall_start": t, "wall": t}})
                        continue
                    entry["fallback_used"] = True
                if "snap" in action:
                    # A still in the middle of a step (an alert before its
                    # button is pressed): NN-step-<name>.png.
                    snap = f"{sid}-{action['snap']}.png"
                    entry.setdefault("snaps", {})[action["snap"]] = self.still(
                        pid, target_dir / snap, action.get("mode", mode), select, rec.get("margin"))
                    continue
                r = self.act(ax, action, names, project_dir, focus)
                r.setdefault("wall_start", r.get("wall", t))
                entry["actions"].append({"spec": action, "result": r})
                if not r.get("ok"):
                    entry["ok"] = False
                    log(f"  {action}: {r.get('error') or r.get('skipped')}")
        finally:
            if proc:
                time.sleep(float(rec.get("post", 1.2)))
                done = self.stop_recording(proc)
                entry["video_frames"] = done.get("frames")
        first = next((a["result"]["wall_start"] for a in entry["actions"] if a["result"].get("ok")), None)
        entry["t_action_wall"] = first
        if proc and first:
            entry["t_action_in_video"] = round(first - entry["video_first_frame_wall"], 4)
        time.sleep(float(step.get("settle", 0.3)))
        if stills in ("after", "both"):
            entry["still_after"] = self.still(pid, target_dir / f"{sid}-after.png", mode, select, rec.get("margin"))
        return entry

    def frame_rate(self, display):
        """The script's frame rate (120 under --council), capped at the
        display's refresh rate."""
        wanted = int(self.script.get("record", {}).get("fps", 60))
        if self.args.council:
            wanted = max(wanted, COUNCIL_FPS)
        refresh = int(round(display.get("refresh_hz") or 0))
        return min(wanted, refresh) if refresh else wanted

    def run(self):
        self.check_permissions()
        self.out.mkdir(parents=True, exist_ok=True)
        wanted = self.args.target or list(self.script.get("targets", ["ycode"]))
        manifests = []
        for name in wanted:
            if name not in self.targets:
                raise SystemExit(f"unknown target {name}; known: {', '.join(self.targets)}")
            manifests.append(self.run_target(self.targets[name]))
        if not self.args.no_compare:
            import sheets
            order = [m for name in self.script.get("compare_order", []) for m in manifests if m.parent.name == name]
            order += [m for m in manifests if m not in order]
            index = sheets.compare(order, self.out / "compare")
            log(f"comparison: {index}")
        log(f"done: {self.out}")


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("script")
    ap.add_argument("--target", action="append", help="target name from targets.json (repeatable)")
    ap.add_argument("--out", help="session folder (default research/dirty/captures/<date>-<name>)")
    ap.add_argument("--allow-focus", action="store_true", help="let a foreground script bring the app to the front")
    ap.add_argument("--council", action="store_true",
                    help="council preset: foreground (implies --allow-focus), event scrolling with momentum, 120 fps")
    ap.add_argument("--allow-1x", action="store_true", help="capture on a 1x display when no free Retina one exists")
    ap.add_argument("--owner-approved", action="store_true", help="the owner agreed to this session (needed for Xcode)")
    ap.add_argument("--keep-open", action="store_true", help="leave the app running afterwards")
    ap.add_argument("--steps", help="run only these step ids (comma-separated), to redo invalid captures")
    ap.add_argument("--project-dir", help="put the project copies here (a folder outside any git repository)")
    ap.add_argument("--no-compare", action="store_true")
    args = ap.parse_args()
    Session(args.script, args).run()


if __name__ == "__main__":
    main()
