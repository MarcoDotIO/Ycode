/*
 * Ycode research probe (iOS simulator guest side): look up names in this
 * process's bootstrap (the guest launchd_sim) and send one message to each
 * port found, so the host side can see that the message arrives on the port it
 * registered. Prints its environment variables starting with YC or SIMULATOR_UDID.
 * Original Ycode code. Contains no Apple code.
 * Usage: lsguest <name>...
 */
#include <mach/mach.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

extern kern_return_t bootstrap_look_up(mach_port_t bp, const char *name, mach_port_t *sp);
extern char **environ;

int main(int argc, char **argv)
{
    setvbuf(stdout, NULL, _IOLBF, 0);
    printf("lsguest: pid %d ppid %d uid %d cwd ", getpid(), getppid(), getuid());
    char cwd[1024];
    printf("%s\n", getcwd(cwd, sizeof cwd) ? cwd : "?");
    for (char **e = environ; *e; e++)
        if (!strncmp(*e, "YC", 2) || !strncmp(*e, "SIMULATOR_UDID", 14) || !strncmp(*e, "XPC_", 4))
            printf("lsguest: env %s\n", *e);
    for (int i = 1; i < argc; i++) {
        mach_port_t p = MACH_PORT_NULL;
        kern_return_t kr = bootstrap_look_up(bootstrap_port, argv[i], &p);
        printf("lsguest: look_up(%s) = %d port 0x%x\n", argv[i], kr, p);
        if (kr == KERN_SUCCESS) {
            struct { mach_msg_header_t h; char text[64]; } m;
            memset(&m, 0, sizeof m);
            m.h.msgh_bits = MACH_MSGH_BITS_SET(MACH_MSG_TYPE_COPY_SEND, 0, 0, 0);
            m.h.msgh_size = sizeof m;
            m.h.msgh_remote_port = p;
            m.h.msgh_id = 0x59434f44; /* "YCOD" */
            snprintf(m.text, sizeof m.text, "hello from guest pid %d via %s", getpid(), argv[i]);
            kr = mach_msg(&m.h, MACH_SEND_MSG | MACH_SEND_TIMEOUT, sizeof m, 0, 0, 1000, 0);
            printf("lsguest: sent message to %s: 0x%x\n", argv[i], kr);
        }
    }
    fprintf(stderr, "lsguest: this line went to stderr\n");
    return 7;
}
