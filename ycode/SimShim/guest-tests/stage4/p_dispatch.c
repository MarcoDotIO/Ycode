/* Ycode stage-4 probe: libdispatch global queues, a group, a semaphore. Original Ycode code. */
#include <dispatch/dispatch.h>
#include <stdio.h>

int main(void)
{
    __block int sum = 0;
    dispatch_queue_t q = dispatch_get_global_queue(QOS_CLASS_DEFAULT, 0);
    dispatch_queue_t serial = dispatch_queue_create("probe.serial", NULL);
    dispatch_group_t g = dispatch_group_create();
    for (int i = 1; i <= 10; i++)
        dispatch_group_async(g, q, ^{ dispatch_sync(serial, ^{ sum += i; }); });
    dispatch_group_wait(g, DISPATCH_TIME_FOREVER);
    dispatch_semaphore_t s = dispatch_semaphore_create(0);
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 10 * NSEC_PER_MSEC), q, ^{ dispatch_semaphore_signal(s); });
    dispatch_semaphore_wait(s, DISPATCH_TIME_FOREVER);
    printf("dispatch ok sum=%d\n", sum);
    return sum == 55 ? 0 : 1;
}
