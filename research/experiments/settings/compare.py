#!/usr/bin/env python3
"""Black-box conformance check: Ycode's settings resolution vs xcodebuild.

For each project, target, and configuration:
  1. actual   = `xcodebuild -showBuildSettings -json` on the real project.
  2. defaults = the same query on a copy whose build settings and xcconfigs
                are stripped (`ycode _strip-settings`). This approximates the
                platform/spec default level that Ycode does not model yet.
                For settings the project never assigns, the real value is used.
  3. ours     = `ycode settings -defaults defaults.json`.
Only settings that the project assigns (in buildSettings or xcconfigs) are
compared, so the check exercises levels, conditions, includes, and macro
evaluation.

Usage: python3 -I compare.py <ycode-binary> <scratch-dir> <manifest> [--configs Debug,Release]
The manifest is the pbxproj corpus manifest (lines "= path" / "~ path").
Writes a JSON report to stdout and a summary to stderr.
"""
import json
import os
import subprocess
import sys


def run(cmd):
    r = subprocess.run(cmd, capture_output=True, text=True)
    if r.returncode != 0:
        raise RuntimeError(f"{' '.join(cmd[:3])}…: {r.stderr.strip()[-400:]}")
    return r.stdout


def xcb(project, target, config):
    out = run(["xcodebuild", "-showBuildSettings", "-json", "-project", project, "-target", target, "-configuration", config])
    return json.loads(out)[0]["buildSettings"]


def targets(ycode, project):
    out = run([ycode, "describe", project])
    return [l.split("target ", 1)[1].split("  [")[0] for l in out.splitlines() if l.startswith("  target ")]


def main():
    ycode, scratch, manifest = sys.argv[1:4]
    configs = ["Debug", "Release"]
    if "--configs" in sys.argv:
        configs = sys.argv[sys.argv.index("--configs") + 1].split(",")
    projects = []
    for line in open(manifest):
        line = line.rstrip("\n")
        if len(line) > 2:
            path = line[2:]
            projects.append(path[: -len("/project.pbxproj")] if path.endswith("/project.pbxproj") else path)
    report = []
    totals = {"compared": 0, "mismatched": 0, "errors": 0}
    for n, proj in enumerate(projects):
        name = os.path.basename(proj)
        probe = os.path.join(scratch, f"p{n}", name)
        for target in targets(ycode, proj):
            for config in configs:
                entry = {"project": proj, "target": target, "configuration": config}
                try:
                    actual = xcb(proj, target, config)
                    run([ycode, "_strip-settings", proj, probe, f"SDKROOT={actual.get('SDKROOT', 'macosx')}"])
                    probed = xcb(probe, target, config)
                    assigned = json.loads(run([ycode, "settings", proj, "-target", target, "-configuration", config,
                                               "--assigned-only", "--json"]))
                    defaults = dict(probed)
                    # The probe's values already contain Xcode's derived
                    # additions; remove them so Ycode's derived level does
                    # not apply twice through $(inherited).
                    osf = defaults.get("OTHER_SWIFT_FLAGS", "")
                    cut = osf.find(" -plugin-path ")
                    if cut < 0 and osf.startswith("-plugin-path "):
                        cut = 0
                    if cut >= 0 and osf.endswith("/plugins/testing"):
                        defaults["OTHER_SWIFT_FLAGS"] = osf[:cut]
                    hsp = defaults.get("HEADER_SEARCH_PATHS", "")
                    prefix = defaults.get("BUILT_PRODUCTS_DIR", "\0") + "/include "
                    if hsp.startswith(prefix):
                        defaults["HEADER_SEARCH_PATHS"] = hsp[len(prefix):]
                    for k, v in actual.items():
                        if k not in assigned:
                            defaults[k] = v
                    dpath = os.path.join(scratch, f"p{n}", "defaults.json")
                    json.dump(defaults, open(dpath, "w"))
                    ours = json.loads(run([ycode, "settings", proj, "-target", target, "-configuration", config,
                                           "-defaults", dpath, "--assigned-only", "--json"]))
                    diffs = {k: {"xcodebuild": actual.get(k, ""), "ycode": ours.get(k, "")}
                             for k in sorted(assigned) if actual.get(k, "") != ours.get(k, "")}
                    entry.update(compared=len(assigned), mismatches=diffs)
                    totals["compared"] += len(assigned)
                    totals["mismatched"] += len(diffs)
                except Exception as e:  # noqa: BLE001 - report and continue
                    entry["error"] = str(e)
                    totals["errors"] += 1
                report.append(entry)
                status = entry.get("error") or f"{len(entry.get('mismatches', {}))}/{entry.get('compared', 0)} mismatched"
                print(f"{name} {target} {config}: {status}", file=sys.stderr)
    print(json.dumps({"totals": totals, "results": report}, indent=1))
    print(f"TOTAL {totals}", file=sys.stderr)


main()
