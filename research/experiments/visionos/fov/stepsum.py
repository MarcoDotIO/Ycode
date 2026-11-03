# stepsum.py (our code, OBS-VISION-FOV): summarise camstep's yaw.csv for runs whose script is pose steps.
# usage: python3 -I stepsum.py <run dir> [--fov 90] [--trans]   (needs sent.txt, script.txt, yaw.csv)
# For each SENT whose script line changes the pose: the commanded yaw (or, --trans, the picture shift),
# the times after the send of the first frame that moved (> 0.1 deg), 50 %, 90 %, and within 0.1 deg of
# the final value, plus the first 12 per-frame values.
import sys, csv, math, os
d = sys.argv[1]
sent = [l.split() for l in open(os.path.join(d, 'sent.txt')) if l.startswith('SENT')]
poses = [l.split() for l in open(os.path.join(d, 'script.txt')) if l.startswith('pose')]
rows = list(csv.DictReader(open(os.path.join(d, 'yaw.csv'))))
T = [int(r['t']) for r in rows]; Y = [float(r['yaw_deg']) for r in rows]
tick = 125 / 3 / 1e6
prev = None
for k, (s, p) in enumerate(zip(sent, poses)):
    qy, qw = float(p[6]), float(p[8]); deg = math.degrees(2 * math.atan2(qy, qw)); tx = float(p[2])
    key = (round(deg, 3), tx)
    if key == prev: continue
    prev = key; ts = int(s[1])
    # the window ends at the next send of a different pose (repeats of the same pose stay in it)
    nxt = T[-1] + 1
    for j in range(k + 1, len(sent)):
        pj = poses[j]; dj = round(math.degrees(2 * math.atan2(float(pj[6]), float(pj[8]))), 3)
        if (dj, float(pj[2])) != key: nxt = int(sent[j][1]); break
    idx = [i for i in range(len(T)) if ts <= T[i] < nxt]
    if not idx: continue
    i0 = max(0, idx[0] - 1); y0 = Y[i0]; yf = Y[idx[-1]]
    def when(cond):
        for i in idx:
            if cond(Y[i]): return (T[i] - ts) * tick
        return float('nan')
    D = yf - y0
    first = when(lambda y: abs(y - y0) > 0.1)
    t50 = when(lambda y: (y - y0) / D >= 0.5) if abs(D) > 0.2 else float('nan')
    t90 = when(lambda y: (y - y0) / D >= 0.9) if abs(D) > 0.2 else float('nan')
    # settled: last frame outside 0.1 deg of final
    out = [i for i in idx if abs(Y[i] - yf) > 0.1]
    tset = ((T[out[-1] + 1] - ts) * tick) if out and out[-1] + 1 < len(T) else first
    seq = ' '.join(f"{(T[i]-ts)*tick:.0f}:{Y[i]:.2f}" for i in idx[:14])
    print(f"cmd yaw {deg:7.2f} tx {tx:5.2f}  picture {y0:7.2f} -> {yf:7.2f}  first {first:6.1f}  t50 {t50:6.1f}  t90 {t90:6.1f}  settled(0.1) {tset:6.1f} ms\n   {seq}")
