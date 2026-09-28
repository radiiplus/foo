#include "service.h"
#include <assert.h>
#include <stdatomic.h>
#include <stdio.h>
#include <string.h>

static void *mutex;
static void *condition;
static int ready;
static atomic_int total;

static void accumulate(int64_t value) {
  atomic_fetch_add_explicit(&total, (int)value, memory_order_relaxed);
}

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

  const char *path = "foo-service-read.tmp";
  FILE *file = fopen(path, "wb");
  assert(file);
  for (int index = 0; index < 10000; index++)
    assert(fputc('a' + index % 26, file) != EOF);
  assert(!fclose(file));
  FooResult content = foo_fs_read((FooText){(const uint8_t *)path, strlen(path)});
  assert(!content.error && content.text.len == 10000);
  for (size_t index = 0; index < content.text.len; index++)
    assert(content.text.data[index] == (uint8_t)('a' + index % 26));
  assert(!foo_text_release(content.text).error);
  assert(!remove(path));

  FooText haystack = {(const uint8_t *)"short searchable text", 21};
  FooText needle = {(const uint8_t *)"search", 6};
  FooResult found = foo_text_find(haystack, needle);
  assert(found.pointer && found.number == 6);
  uint8_t large[4096];
  memset(large, 'x', sizeof(large));
  memcpy(large + 3000, "adaptive", 8);
  found = foo_text_find((FooText){large, sizeof(large)},
                        (FooText){(const uint8_t *)"adaptive", 8});
  assert(found.pointer && found.number == 3000);
  found = foo_text_find((FooText){large, sizeof(large)},
                        (FooText){(const uint8_t *)"missing", 7});
  assert(!found.pointer);

  FooResult pool = foo_task_pool();
  assert(!pool.error);
  atomic_store(&total, 0);
  for (int value = 1; value <= 200; value++)
    assert(foo_task_submit(pool.pointer, accumulate, value).number == 1);
  assert(!foo_task_wait(pool.pointer).error);
  assert(atomic_load(&total) == 20100);
}

#ifdef FOO_SERVICE_TEST_MAIN
int main(int argc, char **argv) {
  foo_service_init(argc, argv);
  verify();
  FooResult pool = foo_task_pool();
  assert(!pool.error);
  atomic_store(&total, 0);
  for (int value = 1; value <= 200; value++)
    assert(foo_task_submit(pool.pointer, accumulate, value).number == 1);
  foo_service_close();
  assert(atomic_load(&total) == 20100);
  puts("native service parity: ok");
  return 0;
}
#endif
