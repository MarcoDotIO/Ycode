/*
 * isserve: run the isserver.h test server as a guest process and publish it
 * under a name of our own with bootstrap_register (original Ycode code, R5).
 * The isinterpose dylib (YC_IS_REDIRECT=<name>) then points a process's
 * IOSurface connection at it. Usage: isserve <name> [seconds]
 *        isserve -checkin <name>   (as a launchd job whose MachServices has <name>)
 */
#include "isserver.h"
#include <unistd.h>
extern kern_return_t bootstrap_register(mach_port_t bp, const char *name, mach_port_t sp);
extern kern_return_t bootstrap_check_in(mach_port_t bp, const char *name, mach_port_t *sp);
int main(int argc, char **argv)
{
    if (argc < 2) return 2;
    if (!strcmp(argv[1], "-checkin") && argc > 2) {
        mach_port_t rcv = MACH_PORT_NULL;
        kern_return_t kr = bootstrap_check_in(bootstrap_port, argv[2], &rcv);
        printf("isserve: check-in %s -> %d\n", argv[2], kr);
        fflush(stdout);
        if (kr) return 1;
        srv_start_on(rcv);
        for (;;) sleep(3600);
    }
    mach_port_t p = srv_start();
    kern_return_t kr = bootstrap_register(bootstrap_port, argv[1], p);
    printf("isserve: register %s -> %d\n", argv[1], kr);
    fflush(stdout);
    if (kr) return 1;
    sleep(argc > 2 ? (unsigned)atoi(argv[2]) : 3600);
    return 0;
}
