/* Host test of vision_orientation.h (visionos.md §5.5.10): the quaternion
 * reaches IOHIDEventCreateQuaternionOrientationEvent normalised, in the
 * order w, x, y, z, with options 0; a missing constructor gives no event. */
#include <math.h>
#include <stdio.h>
#include "../vision_orientation.h"

static double got[4];
static uint32_t gotOptions = 99;
static uint64_t gotTs;
static int calls;
static char marker;

static void *fake(const void *a, uint64_t ts, double w, double x, double y, double z, uint32_t options) {
    (void)a;
    calls++;
    gotTs = ts;
    got[0] = w; got[1] = x; got[2] = y; got[3] = z;
    gotOptions = options;
    return &marker;
}

static int failures;
#define CHECK(c) do { if (!(c)) { printf("orientation_test: failed: %s (line %d)\n", #c, __LINE__); failures++; } } while (0)

int main(void) {
    /* Yaw +30° (turn left), w 0.965926, y 0.258819, given unnormalised (x 2). */
    double q[4] = {2 * 0.965926, 0, 2 * 0.258819, 0};
    CHECK(vision_quaternion_event(fake, 42, q) == &marker);
    CHECK(calls == 1 && gotTs == 42 && gotOptions == 0);
    CHECK(fabs(got[0] - 0.965926) < 1e-6 && fabs(got[2] - 0.258819) < 1e-6 && got[1] == 0 && got[3] == 0);
    double n = got[0] * got[0] + got[1] * got[1] + got[2] * got[2] + got[3] * got[3];
    CHECK(fabs(n - 1) < 1e-12);
    /* Pitch +20° (look up): x positive, order kept. */
    double p[4] = {0.984808, 0.173648, 0, 0};
    vision_quaternion_event(fake, 1, p);
    CHECK(fabs(got[1] - 0.173648) < 1e-6 && fabs(got[0] - 0.984808) < 1e-6);
    /* A zero or NaN quaternion becomes identity. */
    double z[4] = {0, 0, 0, 0};
    vision_quaternion_event(fake, 1, z);
    CHECK(got[0] == 1 && got[1] == 0 && got[2] == 0 && got[3] == 0);
    double nan_q[4] = {NAN, 0, 0, 0};
    vision_quaternion_event(fake, 1, nan_q);
    CHECK(got[0] == 1);
    /* No constructor: no event (the pose goes without rotation). */
    CHECK(vision_quaternion_event(0, 1, q) == 0);
    printf("orientation_test: %s\n", failures ? "FAILED" : "ok");
    return failures != 0;
}
