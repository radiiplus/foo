#include <pthread.h>
#include <stdint.h>
#include <stdio.h>

extern uint64_t foo_qbe_atomic_add8(void *, uint64_t, int);
extern uint64_t foo_qbe_atomic_add16(void *, uint64_t, int);
extern uint64_t foo_qbe_atomic_add32(void *, uint64_t, int);
extern uint64_t foo_qbe_atomic_add64(void *, uint64_t, int);

static uint8_t counter8;
static uint16_t counter16;
static uint32_t counter32;
static uint64_t counter64;
enum { threads = 4, iterations = 100000 };
static uint64_t sums[threads];

static void *worker(void *context) {
    int index = (int)(intptr_t)context;
    uint64_t sum = 0;
    for (int i = 0; i < iterations; ++i) {
        foo_qbe_atomic_add8(&counter8, 1, 4);
        foo_qbe_atomic_add16(&counter16, 1, 4);
        foo_qbe_atomic_add32(&counter32, 1, 4);
        sum += foo_qbe_atomic_add64(&counter64, 1, 4);
    }
    sums[index] = sum;
    return 0;
}

int main(void) {
    pthread_t workers[threads];
    uint64_t sum = 0;
    const uint64_t total = threads * iterations;
    for (int i = 0; i < threads; ++i)
        if (pthread_create(&workers[i], 0, worker, (void *)(intptr_t)i))
            return 2;
    for (int i = 0; i < threads; ++i)
        if (pthread_join(workers[i], 0))
            return 3;
    for (int i = 0; i < threads; ++i)
        sum += sums[i];
    if (counter8 != (uint8_t)total || counter16 != (uint16_t)total ||
        counter32 != (uint32_t)total || counter64 != total ||
        sum != total * (total - 1) / 2) {
        fprintf(stderr, "atomic contention failed: %u %u %u %llu %llu\n",
            counter8, counter16, counter32,
            (unsigned long long)counter64, (unsigned long long)sum);
        return 1;
    }
    puts("atomic contention: ok");
    return 0;
}
