#include "service.h"
#include <assert.h>

static void *mutex;
static void *condition;
static int ready;

static void notify(void *context) {
  (void)context;
  assert(!foo_thread_lock(mutex).error);
  ready = 1;
  assert(!foo_thread_signal(condition).error);
  assert(!foo_thread_unlock(mutex).error);
}

void verify(void) {
  FooResult lock = foo_thread_mutex(), signal = foo_thread_condition();
  assert(!lock.error && !signal.error);
  mutex = lock.pointer;
  condition = signal.pointer;
  ready = 0;
  assert(!foo_thread_lock(mutex).error);
  FooResult worker = foo_thread_spawn(notify, NULL);
  assert(!worker.error);
  while (!ready) assert(!foo_thread_await(condition, mutex).error);
  assert(!foo_thread_unlock(mutex).error);
  assert(!foo_thread_wait(worker.pointer).error);
  assert(foo_thread_wait(worker.pointer).error);
  assert(!foo_thread_close(condition).error);
  assert(!foo_thread_close(mutex).error);
  assert(foo_thread_lock(mutex).error);
  assert(foo_thread_signal(condition).error);
  assert(foo_io_close(foo_io_output().pointer).error);
  assert(foo_process_argument(UINT64_MAX).error);
  FooText host = {(const uint8_t *)"127.0.0.1", 9};
  assert(foo_net_listen(host, 65536).error);
  FooText invalid = {(const uint8_t *)"A\0B", 3};
  assert(foo_process_environment(invalid).error);
}
