# lagfit.py (our code, OBS-VISION-FOV): picture yaw against the commanded yaw for continuous pose streams.
# usage: python3 -I lagfit.py <run dir> [--offset deg]   (sent.txt, script.txt, yaw.csv)
# The commanded yaw at time t is the last pose sent at or before t (by the message's own send time).
# Fits the delay L (ms) and gain g minimising sum (picture(t) - g * cmd(t - L))^2 over the frames while poses
# were being sent; prints L, g, the RMS error, and for a sine the amplitude ratio.
import sys, csv, math, os, bisect
import numpy as np
d = sys.argv[1]; off = float(sys.argv[3]) if len(sys.argv) > 3 and sys.argv[2] == '--offset' else 0.0
tick = 125 / 3 / 1e6
sent = [int(l.split()[1]) for l in open(os.path.join(d, 'sent.txt')) if l.startswith('SENT')]
poses = [l.split() for l in open(os.path.join(d, 'script.txt')) if l.startswith('pose')]
cmd = [math.degrees(2 * math.atan2(float(p[6]), float(p[8]))) for p in poses]
rows = list(csv.DictReader(open(os.path.join(d, 'yaw.csv'))))
T = np.array([int(r['t']) for r in rows], dtype=float); Y = np.array([float(r['yaw_deg']) for r in rows]) + off
S = np.array(sent, dtype=float)
def c_at(t):
    j = np.searchsorted(S, t, side='right') - 1
    return np.where(j >= 0, np.array(cmd)[np.clip(j, 0, None)], 0.0)
m = (T > S[0]) & (T < S[-1] + 300 / tick)
best = None
for Lms in range(0, 400, 2):
    c = c_at(T[m] - Lms / tick); den = (c * c).sum()
    g = (c * Y[m]).sum() / den if den else 0; e = math.sqrt(((Y[m] - g * c) ** 2).mean())
    if best is None or e < best[2]: best = (Lms, g, e)
L, g, e = best
rate = 1000 * (len(S) - 1) / ((S[-1] - S[0]) * tick)
print(f"{os.path.basename(d)}: {len(S)} poses at {rate:.1f}/s; best delay {L} ms gain {g:.3f} rms {e:.3f} deg; picture range {Y[m].min():.2f}..{Y[m].max():.2f}, commanded {min(cmd):.2f}..{max(cmd):.2f}")
