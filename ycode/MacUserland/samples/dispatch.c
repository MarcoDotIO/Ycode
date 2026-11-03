// Milestone A sample: libdispatch queues, groups, semaphores, apply, once
// and blocks (specs/macos/macos-apps.md §9.1). Ycode's own test program.
#include <dispatch/dispatch.h>
#include <stdio.h>
#include <stdlib.h>

static void add_one(void *context) { __atomic_fetch_add((long *)context, 1, __ATOMIC_RELAXED); }

int main(void) {
    dispatch_queue_t serial = dispatch_queue_create("ycode.sample.serial", NULL);
    dispatch_queue_t global = dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0);
    dispatch_group_t group = dispatch_group_create();

    __block long total = 0;
    for (int i = 1; i <= 100; i++) {
        dispatch_group_async(group, global, ^{
            long square = (long)i * i;
            dispatch_sync(serial, ^{ total += square; });
        });
    }
    dispatch_group_wait(group, DISPATCH_TIME_FOREVER);
    printf("sum of squares %ld (expected 338350)\n", total);

    long counter = 0;
    dispatch_apply_f(1000, global, &counter, (void (*)(void *, size_t))add_one);
    printf("apply %ld (expected 1000)\n", counter);

    dispatch_semaphore_t sem = dispatch_semaphore_create(0);
    static int order[3];
    __block int next = 0;
    for (int i = 0; i < 3; i++) dispatch_async(serial, ^{ order[next++] = i; });
    dispatch_async(serial, ^{ dispatch_semaphore_signal(sem); });
    dispatch_semaphore_wait(sem, DISPATCH_TIME_FOREVER);
    printf("serial order %d %d %d\n", order[0], order[1], order[2]);

    static dispatch_once_t once;
    __block int initialized = 0;
    for (int i = 0; i < 3; i++) dispatch_once(&once, ^{ initialized++; });
    printf("once %d\n", initialized);

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 20 * NSEC_PER_MSEC), dispatch_get_main_queue(), ^{
        printf("main queue after 20 ms\n");
        exit(total == 338350 && counter == 1000 && initialized == 1 && order[2] == 2 ? 0 : 1);
    });
    dispatch_main();
}
