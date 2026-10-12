/* Ycode stage-4 probe: pthread_create, a contended mutex, a condition variable, join. Original Ycode code. */
#include <pthread.h>
#include <stdio.h>
#include <unistd.h>

static pthread_mutex_t m = PTHREAD_MUTEX_INITIALIZER;
static pthread_cond_t c = PTHREAD_COND_INITIALIZER;
static int counter, ready;

static void *worker(void *arg)
{
    for (int i = 0; i < 100000; i++) {
        pthread_mutex_lock(&m);
        counter++;
        pthread_mutex_unlock(&m);
    }
    pthread_mutex_lock(&m);
    ready++;
    pthread_cond_signal(&c);
    pthread_mutex_unlock(&m);
    return arg;
}

int main(void)
{
    pthread_t t[2];
    for (long i = 0; i < 2; i++)
        if (pthread_create(&t[i], NULL, worker, (void *)i) != 0) { printf("create failed\n"); return 2; }
    pthread_mutex_lock(&m);
    while (ready < 2) pthread_cond_wait(&c, &m);
    pthread_mutex_unlock(&m);
    for (int i = 0; i < 2; i++) { void *r; pthread_join(t[i], &r); }
    printf("threads ok counter=%d\n", counter);
    return counter == 200000 ? 0 : 1;
}
