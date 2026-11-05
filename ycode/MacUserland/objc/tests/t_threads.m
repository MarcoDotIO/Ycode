// t_threads.m - concurrency (specs/macos/objc-runtime.md §4.5, §5.3, §7,
// §9): +initialize runs once while other threads wait, cache fills race
// with sends, retain/release and weak loads race with each other,
// per-thread autorelease pools, @synchronized mutual exclusion.
#include <objc/NSObject.h>
#include <objc/runtime.h>
#include <pthread.h>
#include <stdio.h>
#include <unistd.h>

id objc_retain(id);
void objc_release(id);
id objc_loadWeakRetained(id *);
id objc_storeWeak(id *, id);
id objc_initWeak(id *, id);
void *objc_autoreleasePoolPush(void);
void objc_autoreleasePoolPop(void *);

#define THREADS 8

static volatile int initCount = 0;
static volatile int initDone = 0;

@interface SlowInit : NSObject
+ (int)ready;
@end
@implementation SlowInit
+ (void)initialize {
    if (self == [SlowInit class]) {
        __sync_fetch_and_add(&initCount, 1);
        usleep(20000);
        initDone = 1;
    }
}
+ (int)ready { return initDone; }
@end

@interface Worker : NSObject
- (long)m0; - (long)m1; - (long)m2; - (long)m3; - (long)m4; - (long)m5; - (long)m6; - (long)m7;
- (long)m8; - (long)m9; - (long)m10; - (long)m11; - (long)m12; - (long)m13; - (long)m14; - (long)m15;
@end
@implementation Worker
- (long)m0 { return 0; } - (long)m1 { return 1; } - (long)m2 { return 2; } - (long)m3 { return 3; }
- (long)m4 { return 4; } - (long)m5 { return 5; } - (long)m6 { return 6; } - (long)m7 { return 7; }
- (long)m8 { return 8; } - (long)m9 { return 9; } - (long)m10 { return 10; } - (long)m11 { return 11; }
- (long)m12 { return 12; } - (long)m13 { return 13; } - (long)m14 { return 14; } - (long)m15 { return 15; }
@end

static int deallocs = 0;
@interface Shared : NSObject
@end
@implementation Shared
- (void)dealloc { __sync_fetch_and_add(&deallocs, 1); [super dealloc]; }
@end

static Worker *worker;
static Shared *shared;
static id weakSlot;
static long counter;
static int notReady;

static void *initThread(void *arg) {
    if (![SlowInit ready]) __sync_fetch_and_add(&notReady, 1);
    return 0;
}

static void *sendThread(void *arg) {
    long sum = 0;
    for (int i = 0; i < 20000; i++) {
        switch (i & 15) {
        case 0: sum += [worker m0]; break; case 1: sum += [worker m1]; break;
        case 2: sum += [worker m2]; break; case 3: sum += [worker m3]; break;
        case 4: sum += [worker m4]; break; case 5: sum += [worker m5]; break;
        case 6: sum += [worker m6]; break; case 7: sum += [worker m7]; break;
        case 8: sum += [worker m8]; break; case 9: sum += [worker m9]; break;
        case 10: sum += [worker m10]; break; case 11: sum += [worker m11]; break;
        case 12: sum += [worker m12]; break; case 13: sum += [worker m13]; break;
        case 14: sum += [worker m14]; break; default: sum += [worker m15]; break;
        }
    }
    return (void *)sum;
}

static void *rrThread(void *arg) {
    for (int i = 0; i < 100000; i++) {
        objc_retain(shared);
        objc_release(shared);
    }
    return 0;
}

static void *weakThread(void *arg) {
    long hits = 0;
    for (int i = 0; i < 20000; i++) {
        id o = objc_loadWeakRetained(&weakSlot);
        if (o) {
            hits++;
            objc_release(o);
        }
    }
    return (void *)hits;
}

static void *poolThread(void *arg) {
    for (int round = 0; round < 50; round++) {
        void *p = objc_autoreleasePoolPush();
        for (int i = 0; i < 200; i++) [[Shared new] autorelease];
        objc_autoreleasePoolPop(p);
    }
    return 0;
}

static void *syncThread(void *arg) {
    for (int i = 0; i < 10000; i++) {
        @synchronized(worker) {
            counter++;
        }
    }
    return 0;
}

static long run(void *(*fn)(void *)) {
    pthread_t t[THREADS];
    long total = 0;
    for (int i = 0; i < THREADS; i++) pthread_create(&t[i], 0, fn, 0);
    for (int i = 0; i < THREADS; i++) {
        void *r;
        pthread_join(t[i], &r);
        total += (long)r;
    }
    return total;
}

int main(void) {
    run(initThread);
    printf("initialize ran %d time(s), threads that saw it unfinished %d\n", initCount, notReady);

    worker = [Worker new];
    printf("sends sum %ld (expected %ld)\n", run(sendThread), (long)THREADS * 20000 / 16 * 120);

    shared = [Shared new];
    run(rrThread);
    printf("retain/release rc %lu deallocs %d\n", (unsigned long)[shared retainCount], deallocs);

    objc_initWeak(&weakSlot, shared);
    long hits = run(weakThread);
    printf("weak hits %ld rc %lu\n", hits, (unsigned long)[shared retainCount]);
    [shared release];
    printf("after release weak %p deallocs %d\n", (void *)objc_loadWeakRetained(&weakSlot), deallocs);

    deallocs = 0;
    run(poolThread);
    printf("pool deallocs %d\n", deallocs);

    run(syncThread);
    printf("synchronized counter %ld\n", counter);
    printf("done\n");
    return 0;
}
