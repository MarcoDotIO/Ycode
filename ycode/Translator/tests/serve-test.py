#!/usr/bin/env python3 -I
"""serve-test.py: exercises `ycode-airc serve` (the persistent mode the
Vulkan back end uses) with our own test metallibs.

Usage: serve-test.py YCODE_AIRC METALLIB_DIR CACHE_DIR
"""
import json
import struct
import subprocess
import sys

airc, libs, cache = sys.argv[1], sys.argv[2], sys.argv[3]
p = subprocess.Popen([airc, "serve", "--cache", cache], stdin=subprocess.PIPE, stdout=subprocess.PIPE)


def request(header, payload=b""):
    h = json.dumps(header).encode()
    frame = struct.pack("<I", len(h)) + h + payload
    p.stdin.write(struct.pack("<I", len(frame)) + frame)
    p.stdin.flush()
    total = struct.unpack("<I", p.stdout.read(4))[0]
    body = p.stdout.read(total)
    hl = struct.unpack("<I", body[:4])[0]
    return json.loads(body[4:4 + hl]), body[4 + hl:]


failures = 0


def check(name, cond, detail=""):
    global failures
    print(("PASS " if cond else "FAIL ") + name + ("" if cond else " " + detail))
    if not cond:
        failures += 1


render = open(libs + "/render.metallib", "rb").read()
basic = open(libs + "/compute_basic.metallib", "rb").read()

h, _ = request({"id": 1, "op": "ping"})
check("ping", h.get("status") == "ok" and h.get("id") == 1, str(h))
h, _ = request({"id": 2, "op": "version"})
check("version", h.get("status") == "ok" and "ycode-airc" in h.get("version", ""), str(h))

h, words = request({"id": 3, "op": "translate", "function": "draw_vs"}, render)
check("translate vertex", h.get("status") == "ok" and words[:4] == struct.pack("<I", 0x07230203), str(h)[:300])
vs_hash = h["reflection"]["hash"]
check("vertex reflection", h["reflection"]["stage"] == "vertex" and len(h["reflection"]["vertex_inputs"]) == 2 and
      [v["name"] for v in h["reflection"]["varyings"]] == ["generated(2uvDv2_f)", "generated(5colorDv4_Dh)"], json.dumps(h["reflection"])[:400])
check("not cached first", h.get("cached") is False)
h2, words2 = request({"id": 4, "op": "translate", "function": "draw_vs"}, render)
check("cached second", h2.get("cached") is True and words2 == words and h2["key"] == h["key"], str(h2)[:200])

h, words = request({"id": 5, "op": "translate", "function": "draw_fs_swapped", "link_vertex": vs_hash}, render)
locs = {v["name"]: v["location"] for v in h["reflection"].get("varyings", [])}
check("linked fragment", h.get("status") == "ok" and h["reflection"].get("linked") is True and
      locs == {"generated(5colorDv4_Dh)": 1, "generated(2uvDv2_f)": 0}, json.dumps(h)[:400])

h, words = request({"id": 6, "op": "translate", "function": "draw_fs_swapped",
                    "varyings": {"generated(2uvDv2_f)": 3, "generated(5colorDv4_Dh)": 5}}, render)
locs = {v["name"]: v["location"] for v in h["reflection"].get("varyings", [])}
check("explicit varyings", h.get("status") == "ok" and locs == {"generated(5colorDv4_Dh)": 5, "generated(2uvDv2_f)": 3}, str(locs))

h, words = request({"id": 7, "op": "translate", "function": "add_arrays", "optimize": True, "assembly": True}, basic)
check("optimized kernel", h.get("status") == "ok" and "OpEntryPoint GLCompute" in h.get("assembly", "") and
      h["reflection"]["compute"]["grid_guard"] is True, str(h)[:300])

h, words = request({"id": 8, "op": "translate", "function": "no_such_function"}, basic)
check("function not found", h.get("status") == "error" and h["error"]["code"] == "function-not-found" and words == b"", str(h))
h, words = request({"id": 9, "op": "translate"}, b"not a metallib at all, just bytes")
check("bad container", h.get("status") == "error" and h["error"]["code"] == "bad-container", str(h))
h, words = request({"id": 10, "op": "translate", "function": "draw_fs", "link_vertex": "00" * 32}, render)
check("unknown link", h.get("status") == "error" and h["error"]["code"] == "bad-request", str(h))
kinds = open(libs + "/r8_kinds.metallib", "rb").read()
h, words = request({"id": 11, "op": "translate", "function": "tess_vs"}, kinds)
check("unsupported names the feature", h.get("status") == "error" and h["error"]["code"] == "unsupported-feature" and
      "patch_control_point" in h["error"]["detail"], str(h))
h, words = request({"id": 14, "op": "translate", "function": "fs_fconst", "constants": {"0": True, "1": 2}}, render)
check("specialized constants", h.get("status") == "ok" and h["reflection"]["function_constants"] == [], str(h)[:300])
h2, words2 = request({"id": 15, "op": "translate", "function": "fs_fconst"}, render)
check("unspecialized constants", h2.get("status") == "ok" and len(h2["reflection"]["function_constants"]) == 2 and h2["key"] != h["key"], str(h2)[:300])

h, words = request({"id": 16, "op": "translate", "function": "call_visible"}, basic)
check("unlinked visible call", h.get("status") == "error" and "vis_twice" in h["error"]["detail"], str(h)[:300])
h, words = request({"id": 17, "op": "translate", "function": "call_visible", "linked": [len(basic)]}, basic + basic)
check("linked visible call", h.get("status") == "ok", str(h)[:300])

h, _ = request({"id": 12, "op": "shutdown"})
check("shutdown", h.get("status") == "ok")
p.wait(timeout=10)
check("exit status", p.returncode == 0, str(p.returncode))

# A new process reads the disk cache.
p = subprocess.Popen([airc, "serve", "--cache", cache], stdin=subprocess.PIPE, stdout=subprocess.PIPE)
h, w = request({"id": 13, "op": "translate", "function": "draw_vs"}, render)
check("disk cache", h.get("cached") is True and w[:4] == struct.pack("<I", 0x07230203), str(h)[:200])
p.stdin.close()
p.wait(timeout=10)
check("exit on EOF", p.returncode == 0, str(p.returncode))
# --dump-dir saves requests and outcomes; replay runs them again.
import os, shutil
dump = cache + "/dump"
shutil.rmtree(dump, ignore_errors=True)
p = subprocess.Popen([airc, "serve", "--dump-dir", dump], stdin=subprocess.PIPE, stdout=subprocess.PIPE)
h, _ = request({"id": 20, "op": "translate", "function": "draw_vs"}, render)
vs_hash = h["reflection"]["hash"]
request({"id": 21, "op": "translate", "function": "draw_fs_swapped", "link_vertex": vs_hash}, render)
request({"id": 22, "op": "translate", "function": "tess_vs"}, kinds)
request({"id": 23, "op": "translate", "function": "call_visible", "linked": [len(basic)]}, basic + basic)
p.stdin.close()
p.wait(timeout=10)
files = sorted(os.listdir(dump))
check("dump files", len([f for f in files if f.endswith(".request.json")]) == 4 and len(files) == 12, str(files))
res = json.load(open(dump + "/000002.result.json"))
check("dumped error", res["status"] == "error" and res["error"]["code"] == "unsupported-feature", str(res))
out = subprocess.run([airc, "replay", dump], capture_output=True, text=True).stdout
check("replay", "replayed 4 requests: 3 ok, 1 errors, 0 changed" in out, out)
print("serve tests: %d failed" % failures)
sys.exit(1 if failures else 0)
