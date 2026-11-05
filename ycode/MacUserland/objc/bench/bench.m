// bench.m - micro-benchmarks of an Objective-C runtime (specs/macos/
// objc-runtime.md §12). The same program runs against the Mac's runtime,
// against Ycode's runtime natively on a Mac, and under ycode-simd --macos.
// Prints "<name>\t<ns per op>\t<ops>" per benchmark (median of trials).
//
//   bench [<bundle dir> <variant>]   (dir holds warm.bundle and, for t = 0-4,
//                                     cats<t>-<variant>.bundle and its
//                                     cats<t>-<variant>-control.bundle)
#include <objc/NSObject.h>
#include <objc/runtime.h>
#include <objc/message.h>
#include <dlfcn.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

id objc_retain(id);
void objc_release(id);
id objc_autorelease(id);
void *objc_autoreleasePoolPush(void);
void objc_autoreleasePoolPop(void *);
id objc_storeWeak(id *, id);
id objc_loadWeakRetained(id *);
id objc_alloc_init(Class);
id objc_msgSendSuper2(struct objc_super *, SEL, ...);

extern const int gen_r_count, gen_u_count, gen_u_methods;
extern Class gen_r_classes[], gen_u_classes[];
extern const char *gen_u_names[];

#define TRIALS 7

static double now_ns(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (double)ts.tv_sec * 1e9 + (double)ts.tv_nsec;
}

static int cmpd(const void *a, const void *b) {
    double x = *(const double *)a, y = *(const double *)b;
    return x < y ? -1 : x > y;
}
static double median(double *v, int n) {
    qsort(v, n, sizeof(double), cmpd);
    return v[n / 2];
}
static void report(const char *name, double ns, long ops) {
    printf("%s\t%.2f\t%ld\n", name, ns, ops);
    fflush(stdout);
}

@interface Base : NSObject
- (void)nop;
@end
@implementation Base
- (void)nop {}
@end
@interface Sub : Base
@end
@implementation Sub
@end

@interface L0 : NSObject - (void)deep; @end
@implementation L0 - (void)deep {} @end
@interface L1 : L0 @end @implementation L1 @end
@interface L2 : L1 @end @implementation L2 @end
@interface L3 : L2 @end @implementation L3 @end
@interface L4 : L3 @end @implementation L4 @end
@interface L5 : L4 @end @implementation L5 @end

typedef void (*Send0)(id, SEL);

#define LOOP_BENCH(NAME, N, SETUP, BODY)                                  \
    do {                                                                  \
        double t[TRIALS];                                                 \
        SETUP;                                                            \
        for (int tr = 0; tr < TRIALS; tr++) {                             \
            double s = now_ns();                                          \
            for (long i = 0; i < (N); i++) { BODY; }                      \
            t[tr] = (now_ns() - s) / (double)(N);                         \
        }                                                                 \
        report(NAME, median(t, TRIALS), (long)(N) * TRIALS);              \
    } while (0)

int main(int argc, char **argv) {
    long scale = getenv("BENCH_SCALE") ? atol(getenv("BENCH_SCALE")) : 1;
    long N = 20000000 / scale, M = 2000000 / scale, K = 200000 / scale;
    Send0 send = (Send0)objc_msgSend;
    SEL nop = @selector(nop);

    Base *obj = [Sub new];
    LOOP_BENCH("send_cached", N, send(obj, nop), send(obj, nop));

    volatile id nilobj = nil;
    LOOP_BENCH("send_nil", N, , send(nilobj, nop));

    struct objc_super sup = { obj, [Sub class] };
    LOOP_BENCH("send_super", N, ((void (*)(struct objc_super *, SEL))objc_msgSendSuper2)(&sup, nop),
               ((void (*)(struct objc_super *, SEL))objc_msgSendSuper2)(&sup, nop));

    // Uncached: the first send of each of 200 selectors to fresh instances,
    // 10 classes per trial (5 trials).
    {
        SEL sels[512];
        for (int j = 0; j < gen_u_methods; j++) sels[j] = sel_registerName(gen_u_names[j]);
        id objs[64];
        for (int i = 0; i < gen_u_count; i++) objs[i] = [gen_u_classes[i] new];
        int per = gen_u_count / 5;
        double t[5];
        for (int tr = 0; tr < 5; tr++) {
            double s = now_ns();
            for (int i = tr * per; i < (tr + 1) * per; i++)
                for (int j = 0; j < gen_u_methods; j++) send(objs[i], sels[j]);
            t[tr] = (now_ns() - s) / (double)(per * gen_u_methods);
        }
        report("send_uncached", median(t, 5), (long)gen_u_count * gen_u_methods);
    }

    // Class realization: the first message to each of 1000 classes
    // (realize class and metaclass, +initialize, cache fill); 5 trials.
    {
        int per = gen_r_count / 5;
        double t[5];
        for (int tr = 0; tr < 5; tr++) {
            double s = now_ns();
            for (int i = tr * per; i < (tr + 1) * per; i++) send((id)gen_r_classes[i], @selector(self));
            t[tr] = (now_ns() - s) / per;
        }
        report("class_realize_first_msg", median(t, 5), gen_r_count);
    }

    // Runtime class creation.
    {
        double t[5];
        char name[64];
        for (int tr = 0; tr < 5; tr++) {
            double s = now_ns();
            for (int i = 0; i < 200; i++) {
                snprintf(name, sizeof name, "Dyn_%d_%d", tr, i);
                Class c = objc_allocateClassPair([NSObject class], name, 0);
                objc_registerClassPair(c);
            }
            t[tr] = (now_ns() - s) / 200;
        }
        report("class_create_register", median(t, 5), 1000);
    }

    Class l5 = [L5 class];
    [L5 new];
    LOOP_BENCH("lookup_getInstanceMethod_depth5", M, , class_getInstanceMethod(l5, @selector(deep)));
    LOOP_BENCH("lookup_getMethodImplementation", N, class_getMethodImplementation(l5, @selector(deep)),
               class_getMethodImplementation(l5, @selector(deep)));

    LOOP_BENCH("retain_release", N, , { objc_retain(obj); objc_release(obj); });

    Class base = [Base class];
    LOOP_BENCH("alloc_init_release", M, , objc_release(objc_alloc_init(base)));

    LOOP_BENCH("pool_push_autorelease_pop", M, , {
        void *p = objc_autoreleasePoolPush();
        objc_autorelease(objc_retain(obj));
        objc_autoreleasePoolPop(p);
    });

    {
        double t[TRIALS];
        long n = K / 100;
        for (int tr = 0; tr < TRIALS; tr++) {
            double s = now_ns();
            for (long i = 0; i < n; i++) {
                void *p = objc_autoreleasePoolPush();
                for (int j = 0; j < 1000; j++) objc_autorelease(objc_retain(obj));
                objc_autoreleasePoolPop(p);
            }
            t[tr] = (now_ns() - s) / (double)(n * 1000);
        }
        report("autorelease_1000_per_object", median(t, TRIALS), n * 1000 * TRIALS);
    }

    id other = [Sub new];
    id weak = nil;
    LOOP_BENCH("weak_store", M, objc_storeWeak(&weak, obj), { objc_storeWeak(&weak, other); objc_storeWeak(&weak, obj); });
    LOOP_BENCH("weak_load_retained", N / 4, , objc_release(objc_loadWeakRetained(&weak)));
    objc_storeWeak(&weak, nil);

    // Category attachment: dlopen of 1000 categories x 4 methods on the
    // (now realized) R classes, minus dlopen of the same bundle with its
    // sections renamed so that no runtime reads them; five trials.
    if (argc > 2) {
        char path[1024];
        snprintf(path, sizeof path, "%s/warm.bundle", argv[1]);
        dlopen(path, RTLD_NOW);   // the first dlopen's one-time costs
        double t[5], f[5];
        int ok = 1;
        id rinst[1000];
        for (int i = 0; i < gen_r_count; i++) rinst[i] = [gen_r_classes[i] new];
        for (int tr = 0; tr < 5; tr++) {
            snprintf(path, sizeof path, "%s/cats%d-%s-control.bundle", argv[1], tr, argv[2]);
            double s = now_ns();
            void *h = dlopen(path, RTLD_NOW);
            double control = now_ns() - s;
            snprintf(path, sizeof path, "%s/cats%d-%s.bundle", argv[1], tr, argv[2]);
            s = now_ns();
            void *c = dlopen(path, RTLD_NOW);
            double cats = now_ns() - s;
            if (!h || !c) {
                printf("dlopen failed: %s\n", dlerror());
                return 1;
            }
            char name[32];
            snprintf(name, sizeof name, "cat%d_0", tr);
            SEL first = sel_registerName(name);
            s = now_ns();
            for (int i = 0; i < gen_r_count; i++) ((int (*)(id, SEL))objc_msgSend)(rinst[i], first);
            f[tr] = (now_ns() - s) / gen_r_count;
            snprintf(name, sizeof name, "cat%d_3", tr);
            ok &= ((int (*)(id, SEL))objc_msgSend)(rinst[999], sel_registerName(name)) == 9993;
            t[tr] = (cats - control) / gen_r_count;
            if (getenv("BENCH_VERBOSE")) printf("# trial %d: cats %.0f us control %.0f us\n", tr, cats / 1000, control / 1000);
        }
        report("category_attach_per_category", median(t, 5), gen_r_count * 5);
        // The first send of a category method to each class afterwards
        // (lookup and cache fill; a lazily merged table is built here).
        report("category_first_send_per_class", median(f, 5), gen_r_count * 5);
        printf("# category check %d\n", ok);
    }
    return 0;
}
