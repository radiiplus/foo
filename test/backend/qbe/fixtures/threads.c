#include <pthread.h>
#include <stdatomic.h>
#include <stdint.h>
#include <stdio.h>

static _Atomic uint64_t counter;
extern uint64_t increment(_Atomic uint64_t *value);

static void *worker(void *unused) {
  (void)unused;
  for (int index = 0; index < 1000; ++index) increment(&counter);
  return 0;
}

int main(void) {
  pthread_t threads[4];
  for (int index = 0; index < 4; ++index) {
    int status = pthread_create(&threads[index], 0, worker, 0);
    if (status) {
      fprintf(stderr, "pthread_create failed: %d\n", status);
      return 1;
    }
  }
  for (int index = 0; index < 4; ++index) {
    int status = pthread_join(threads[index], 0);
    if (status) {
      fprintf(stderr, "pthread_join failed: %d\n", status);
      return 2;
    }
  }
  uint64_t result = atomic_load_explicit(&counter, memory_order_acquire);
  if (result != 4000) {
    fprintf(stderr, "atomic count: %llu\n", (unsigned long long)result);
    return 3;
  }
  return 0;
}
