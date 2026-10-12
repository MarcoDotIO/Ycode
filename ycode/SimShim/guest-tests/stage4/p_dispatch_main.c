/* Ycode stage-4 probe: the main queue, a timer source, dispatch_main. Original Ycode code. */
#include <dispatch/dispatch.h>
#include <stdio.h>
#include <stdlib.h>

int main(void)
{
    __block int ticks = 0;
    dispatch_source_t t = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_main_queue());
    dispatch_source_set_timer(t, dispatch_time(DISPATCH_TIME_NOW, 0), 5 * NSEC_PER_MSEC, 0);
    dispatch_source_set_event_handler(t, ^{
        if (++ticks == 3) { printf("dispatch_main ok ticks=%d\n", ticks); exit(0); }
    });
    dispatch_resume(t);
    dispatch_main();
}
