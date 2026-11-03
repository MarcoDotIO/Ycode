"""Receiver for the HealthProbe phone app (local network only).

Advertises `_healthprobe._tcp` with Bonjour (the system `dns-sd` tool), accepts TCP
connections only from private, link-local or loopback addresses, and appends each
newline-delimited JSON event to `<out>/live/<session>.jsonl`. Only whitelisted fields
are written, and an absolute start time is dropped if one ever arrives. The console
shows counts only, never values.

Usage: python3 -I healthprobe_receiver.py --out <dir> [--port 8765]
"""
import argparse
import asyncio
import ipaddress
import json
import math
import os
import re
import signal
import subprocess

FIELDS_NUM = {"v", "seq", "startOffset", "endOffset", "deliveredOffset", "phoneReceivedOffset", "value", "sum",
              "seriesCount", "activity", "location"}
FIELDS_STR = {"session", "origin", "kind", "type", "unit", "note", "transport"}
SAFE_STR = re.compile(r"^[A-Za-z0-9_.:/\-]{0,100}$")
SESSION_RE = re.compile(r"^[A-F0-9\-]{36}$")
MAX_LINE = 64 * 1024


def clean(event):
    out = {}
    for k, v in event.items():
        if k in FIELDS_NUM and isinstance(v, (int, float)) and not isinstance(v, bool) and math.isfinite(v):
            out[k] = v
        elif k in FIELDS_STR and isinstance(v, str) and SAFE_STR.match(v):
            out[k] = v
        elif k == "metadataKeys" and isinstance(v, list):
            out[k] = [s for s in v if isinstance(s, str) and SAFE_STR.match(s)][:50]
    return out


def allowed_peer(host):
    try:
        ip = ipaddress.ip_address(host.split("%", 1)[0])
    except ValueError:
        return False
    if isinstance(ip, ipaddress.IPv6Address) and ip.ipv4_mapped:
        ip = ip.ipv4_mapped
    return ip.is_private or ip.is_link_local or ip.is_loopback


class Receiver:
    def __init__(self, out_dir):
        self.live = os.path.join(out_dir, "live")
        os.makedirs(self.live, exist_ok=True)
        self.counts = {}

    async def handle(self, reader, writer):
        peer = writer.get_extra_info("peername")
        if not peer or not allowed_peer(peer[0]):
            print("refused a connection from a non-local address")
            writer.close()
            return
        print("phone connected")
        try:
            while True:
                line = await reader.readline()
                if not line:
                    break
                if len(line) > MAX_LINE:
                    continue
                try:
                    ev = clean(json.loads(line))
                except (ValueError, AttributeError):
                    continue
                sid = ev.get("session", "")
                if not SESSION_RE.match(sid):
                    continue
                with open(os.path.join(self.live, sid + ".jsonl"), "a") as f:
                    f.write(json.dumps(ev, sort_keys=True) + "\n")
                n = self.counts.get(sid, 0) + 1
                self.counts[sid] = n
                if n % 100 == 0:
                    print(f"session {sid[:8]}: {n} events")
        finally:
            writer.close()
            print("phone disconnected; totals:", {k[:8]: v for k, v in self.counts.items()})


async def main(out_dir, port):
    rec = Receiver(out_dir)
    server = await asyncio.start_server(rec.handle, host=None, port=port)
    adv = subprocess.Popen(["dns-sd", "-R", "HealthProbe", "_healthprobe._tcp", "local", str(port)],
                           stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    print(f"listening on port {port}, advertised as _healthprobe._tcp; writing to {rec.live}")
    stop = asyncio.Event()
    loop = asyncio.get_running_loop()
    for sig in (signal.SIGINT, signal.SIGTERM):
        loop.add_signal_handler(sig, stop.set)
    async with server:
        await stop.wait()
    adv.terminate()
    print("stopped; totals:", {k[:8]: v for k, v in rec.counts.items()})


if __name__ == "__main__":
    ap = argparse.ArgumentParser()
    ap.add_argument("--out", required=True)
    ap.add_argument("--port", type=int, default=8765)
    a = ap.parse_args()
    asyncio.run(main(a.out, a.port))
