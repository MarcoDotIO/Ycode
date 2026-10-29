// Guest probe: JavaScriptCore's conservative collector across threads
// (specs/simulator/threads-and-events.md §1.6). Several threads share one
// context group. Each keeps objects it made referenced only from its own
// stack (unprotected JSValueRefs in a volatile array) while the threads
// allocate garbage and collect. A collection on one thread must suspend the
// others (thread_suspend), read their registers (thread_get_state) and scan
// their stacks; if it cannot, objects still in use are freed and their
// properties read back wrong, or the process crashes.
//   p_jsgc [threads] [seconds]      defaults 4 and 20
#include <JavaScriptCore/JavaScriptCore.h>
#include <pthread.h>
#include <stdatomic.h>
#include <stdio.h>
#include <stdlib.h>
#include <time.h>

static JSContextGroupRef group;
static _Atomic long rounds, mismatches, collections;
static double seconds = 20;

static double now(void) {
    struct timespec t;
    clock_gettime(CLOCK_MONOTONIC, &t);
    return (double)t.tv_sec + (double)t.tv_nsec * 1e-9;
}

static void *worker(void *arg) {
    long id = (long)arg;
    JSGlobalContextRef ctx = JSGlobalContextCreateInGroup(group, NULL);
    JSStringRef name = JSStringCreateWithUTF8CString("v");
    JSStringRef script = JSStringCreateWithUTF8CString(
        "var a = []; for (var i = 0; i < 2000; i++) a.push({x: i, s: 'str' + i, l: [i, i + 1, i + 2]}); a.length");
    double end = now() + seconds;
    long round = 0;
    while (now() < end) {
        // Objects referenced only from this thread's stack.
        JSObjectRef volatile keep[32];
        for (int i = 0; i < 32; i++) {
            keep[i] = JSObjectMake(ctx, NULL, NULL);
            JSObjectSetProperty(ctx, keep[i], name, JSValueMakeNumber(ctx, (double)(id * 1000000 + round * 32 + i)),
                                kJSPropertyAttributeNone, NULL);
        }
        // Garbage, and sometimes a full collection on this thread.
        for (int k = 0; k < 4; k++) JSEvaluateScript(ctx, script, NULL, NULL, 0, NULL);
        if (round % 8 == id % 8) {
            JSGarbageCollect(ctx);
            atomic_fetch_add(&collections, 1);
        }
        for (int i = 0; i < 32; i++) {
            JSValueRef v = JSObjectGetProperty(ctx, keep[i], name, NULL);
            double want = (double)(id * 1000000 + round * 32 + i);
            if (!JSValueIsNumber(ctx, v) || JSValueToNumber(ctx, v, NULL) != want) atomic_fetch_add(&mismatches, 1);
        }
        round++;
        atomic_fetch_add(&rounds, 1);
    }
    JSStringRelease(script);
    JSStringRelease(name);
    JSGlobalContextRelease(ctx);
    return NULL;
}

int main(int argc, char **argv) {
    setvbuf(stdout, NULL, _IOLBF, 0);
    int threads = argc > 1 ? atoi(argv[1]) : 4;
    if (argc > 2) seconds = atof(argv[2]);
    if (threads < 1 || threads > 32) threads = 4;
    group = JSContextGroupCreate();
    pthread_t t[32];
    double start = now();
    for (long i = 0; i < threads; i++) pthread_create(&t[i], NULL, worker, (void *)i);
    for (int i = 0; i < threads; i++) pthread_join(t[i], NULL);
    printf("p_jsgc: %d threads, %.1f s: %ld rounds, %ld collections requested, %ld mismatches\n", threads,
           now() - start, atomic_load(&rounds), atomic_load(&collections), atomic_load(&mismatches));
    printf("p_jsgc: %s\n", atomic_load(&mismatches) == 0 ? "ok" : "FAILED");
    JSContextGroupRelease(group);
    return atomic_load(&mismatches) == 0 ? 0 : 1;
}
