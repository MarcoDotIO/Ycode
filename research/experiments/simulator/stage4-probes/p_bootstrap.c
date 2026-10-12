/* Ycode stage-4 probe: a bootstrap lookup through libxpc, to see what reaches the bootstrap port. Original Ycode code. */
#include <mach/mach.h>
extern kern_return_t bootstrap_look_up(mach_port_t, const char *, mach_port_t *);
#include <stdio.h>

int main(void)
{
    mach_port_t p = MACH_PORT_NULL;
    kern_return_t kr = bootstrap_look_up(bootstrap_port, "com.apple.cfprefsd.daemon", &p);
    printf("bootstrap_look_up kr=%d port=%#x\n", kr, p);
    return 0;
}
