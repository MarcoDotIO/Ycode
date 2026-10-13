// clockprobe: our probe (stage 7, agent I4). On 8 threads, compares the
// counter read in place (mach_absolute_time) with the kernel's mach time of
// the same instant (BSD 116's third argument). Prints each thread's skew.
#include <stdio.h>
#include <stdint.h>
#include <pthread.h>
#include <unistd.h>
#include <sys/time.h>
#include <mach/mach_time.h>
extern int __gettimeofday(struct timeval *, void *, uint64_t *);
static void *run(void *arg) {
    long id = (long)arg;
    usleep(100000 * id);
    int64_t worst = 0;
    for (int i = 0; i < 50; i++) {
        uint64_t a = mach_absolute_time(), m = 0;
        struct timeval tv;
        syscall(116, &tv, 0, &m);
        uint64_t b = mach_absolute_time();
        int64_t skew = (int64_t)m < (int64_t)a ? (int64_t)m - (int64_t)a : ((int64_t)m > (int64_t)b ? (int64_t)m - (int64_t)b : 0);
        if (skew < 0 ? -skew > (worst < 0 ? -worst : worst) : skew > (worst < 0 ? -worst : worst)) worst = skew;
    }
    uint64_t a = mach_absolute_time(), m = 0; struct timeval tv; syscall(116, &tv, 0, &m); uint64_t b = mach_absolute_time();
    printf("thread %ld: worst skew %lld ticks (last: before %llu kernel %llu after %llu)\n", id, (long long)worst,
           (unsigned long long)a, (unsigned long long)m, (unsigned long long)b);
    return 0;
}
int main(void) {
    pthread_t t[8];
    for (long i = 0; i < 8; i++) pthread_create(&t[i], 0, run, (void *)i);
    for (int i = 0; i < 8; i++) pthread_join(t[i], 0);
    return 0;
}
