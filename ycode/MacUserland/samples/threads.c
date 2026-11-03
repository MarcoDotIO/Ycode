// Milestone A sample: pthreads, a mutex, a condition variable, and
// thread-specific data (specs/macos/macos-apps.md §9.1). Ycode's own test program.
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>

enum { THREADS = 8, ROUNDS = 10000 };
static pthread_mutex_t lock = PTHREAD_MUTEX_INITIALIZER;
static pthread_cond_t done = PTHREAD_COND_INITIALIZER;
static long counter;
static int finished;
static pthread_key_t key;

static void *worker(void *arg) {
    long id = (long)arg;
    pthread_setspecific(key, arg);
    for (int i = 0; i < ROUNDS; i++) {
        pthread_mutex_lock(&lock);
        counter++;
        pthread_mutex_unlock(&lock);
    }
    pthread_mutex_lock(&lock);
    finished++;
    pthread_cond_signal(&done);
    pthread_mutex_unlock(&lock);
    return (void *)(id * 10 + (long)pthread_getspecific(key));
}

int main(void) {
    pthread_key_create(&key, NULL);
    pthread_t threads[THREADS];
    for (long i = 0; i < THREADS; i++) {
        if (pthread_create(&threads[i], NULL, worker, (void *)i) != 0) { printf("pthread_create failed\n"); return 1; }
    }
    pthread_mutex_lock(&lock);
    while (finished < THREADS) pthread_cond_wait(&done, &lock);
    pthread_mutex_unlock(&lock);
    long sum = 0;
    for (int i = 0; i < THREADS; i++) {
        void *result;
        pthread_join(threads[i], &result);
        sum += (long)result;
    }
    printf("counter %ld (expected %d), join sum %ld (expected %d)\n", counter, THREADS * ROUNDS, sum, 11 * 28);
    return counter == THREADS * ROUNDS && sum == 11 * 28 ? 0 : 1;
}
