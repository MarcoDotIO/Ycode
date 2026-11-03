# posegen.py (our code, OBS-VISION-FOV): vhid script lines for pose experiments (target 300).
#  step <deg> [hold_ms]                 one pose, yaw deg, then hold
#  tstep <x_m> [hold_ms]                one pose, translation x, then hold
#  repeat <deg> <hz> <dur_ms>           the same yaw pose sent at hz for dur_ms
#  ramp <deg> <hz> <dur_ms> [hold_ms]   yaw from 0 to deg linearly over dur_ms, sent at hz
#  sine <amp_deg> <freq_hz> <hz> <dur_ms>  yaw = amp*sin(2*pi*f*t), sent at hz
#  home [hold_ms]                       identity
import sys, math
def pose(deg, tx=0.0):
    h = math.radians(deg) / 2
    return f"pose 300 {tx:.4f} 0 0 0 {math.sin(h):.6f} 0 {math.cos(h):.6f}"
a = sys.argv[1:]; v = a[0]; out = []
if v == 'step': out += [pose(float(a[1])), f"sleep {a[2] if len(a) > 2 else 1500}"]
elif v == 'tstep': out += [pose(0, float(a[1])), f"sleep {a[2] if len(a) > 2 else 1500}"]
elif v == 'home': out += [pose(0), f"sleep {a[1] if len(a) > 1 else 1500}"]
elif v == 'repeat':
    deg, hz, dur = float(a[1]), float(a[2]), float(a[3]); n = int(dur * hz / 1000)
    for i in range(n): out += [pose(deg), f"sleep {int(1000 / hz)}"]
elif v == 'ramp':
    deg, hz, dur = float(a[1]), float(a[2]), float(a[3]); n = int(dur * hz / 1000)
    for i in range(1, n + 1): out += [pose(deg * i / n), f"sleep {int(1000 / hz)}"]
    out += [f"sleep {a[4] if len(a) > 4 else 1000}"]
elif v == 'sine':
    amp, f, hz, dur = float(a[1]), float(a[2]), float(a[3]), float(a[4]); n = int(dur * hz / 1000)
    for i in range(n): out += [pose(amp * math.sin(2 * math.pi * f * i / hz)), f"sleep {int(1000 / hz)}"]
    out += [pose(0), "sleep 800"]
print('\n'.join(out))
