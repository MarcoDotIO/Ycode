# camstep.py (our code, OBS-VISION-FOV 2026-11-01): the rendered camera's yaw per presented frame.
# usage: python3 -I camstep.py <frames.bin> <sent.txt> [--ref N] [--fov 90] [--row 0] [--csv out.csv] [--quiet]
# frames.bin: camrec's samples (rows of each presented frame, every 2nd pixel, luma).
# sent.txt: vhid STAMP output ("SENT <mach> <ts in message>").
# For each frame: yaw (deg) of the camera relative to frame --ref, from the best shift of the row
# resampled to view angle (pinhole, horizontal FOV --fov), and the time (ms) since the latest SENT.
# Positive yaw = the picture moved right = the camera turned left.
import struct, sys, math, argparse
import numpy as np
ap = argparse.ArgumentParser(); ap.add_argument('frames'); ap.add_argument('sent'); ap.add_argument('--ref', type=int, default=0)
ap.add_argument('--fov', type=float, default=90.0); ap.add_argument('--row', type=int, default=0); ap.add_argument('--csv')
ap.add_argument('--tick', type=float, default=125 / 3); ap.add_argument('--maxshift', type=float, default=40.0); ap.add_argument('--quiet', action='store_true')
a = ap.parse_args()
T, R = [], []
with open(a.frames, 'rb') as f:
    while True:
        h = f.read(24)
        if len(h) < 24: break
        t, sid, w, rows, n = struct.unpack('<QIIII', h); d = f.read(rows * n)
        T.append(t); R.append(np.frombuffer(d[a.row * n:(a.row + 1) * n], dtype=np.uint8).astype(float))
sent = sorted(int(l.split()[1]) for l in open(a.sent) if l.startswith('SENT'))
n = len(R[0]); w = 2 * n
fx = (w / 2) / math.tan(math.radians(a.fov / 2))
STEP = 0.05; grid = np.arange(-a.fov / 2, a.fov / 2 + 1e-9, STEP)
xi = (w / 2 + fx * np.tan(np.radians(grid))) / 2 - 0.5
xi = np.clip(xi, 0, n - 1.001)
def rs(row): return np.interp(xi, np.arange(n), row)
ref = rs(R[a.ref]); K = int(a.maxshift / STEP)
def ncc(r, s, k):
    if k >= 0: x, y = r[k:], s[:len(s) - k]
    else: x, y = r[:k], s[-k:]
    x = x - x.mean(); y = y - y.mean(); d = math.sqrt((x * x).sum() * (y * y).sum())
    return (x * y).sum() / d if d > 0 else -2
out = []
for i, row in enumerate(R):
    s = rs(row)
    cs = np.array([ncc(ref, s, k) for k in range(-K, K + 1)]); b = int(cs.argmax())
    sub = 0
    if 0 < b < len(cs) - 1:
        c0, c1, c2 = cs[b - 1], cs[b], cs[b + 1]; den = c0 - 2 * c1 + c2; sub = 0.5 * (c0 - c2) / den if den else 0
    yaw = -((b - K) + sub) * STEP   # s(x) = ref(x + k): picture moved left by k when k > 0
    import bisect; j = bisect.bisect_right(sent, T[i]) - 1
    since = (T[i] - sent[j]) * a.tick / 1e6 if j >= 0 else float('nan')
    dt = (T[i] - T[i - 1]) * a.tick / 1e6 if i else 0
    out.append((i, T[i], dt, since, yaw, cs[b]))
    if not a.quiet: print(f"{i:5d} dt {dt:6.1f} since_sent {since:9.1f} ms yaw {yaw:8.3f} ncc {cs[b]:.3f}")
if a.csv:
    with open(a.csv, 'w') as f:
        f.write('idx,t,dt_ms,since_ms,yaw_deg,ncc\n')
        for r in out: f.write(','.join(str(x) for x in r) + '\n')
