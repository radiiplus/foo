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
  FooText process_arguments[] = {
      {(const uint8_t *)"-e", 2},
      {(const uint8_t *)"process.exit(9)", 15},
  };
  FooResult executed = foo_process_execute(
      (FooText){(const uint8_t *)"node", 4},
      (FooText){(const uint8_t *)process_arguments, 2});
  assert(!executed.error && executed.number == 9);

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

  const char *draft = "foo-service-draft.tmp";
  const char *live = "foo-service-live.tmp";
  FooText bytes = {(const uint8_t *)"A\0B\xff", 4};
  FooResult output = foo_fs_open(
      (FooText){(const uint8_t *)draft, strlen(draft)},
      (FooText){(const uint8_t *)"write", 5});
  assert(!output.error);
  assert(!foo_io_write(output.pointer, bytes).error);
  assert(!foo_fs_sync(output.pointer).error);
  assert(!foo_io_close(output.pointer).error);
  assert(!foo_fs_replace(
      (FooText){(const uint8_t *)draft, strlen(draft)},
      (FooText){(const uint8_t *)live, strlen(live)}).error);
  FooResult exists = foo_fs_exists(
      (FooText){(const uint8_t *)live, strlen(live)});
  assert(!exists.error && exists.number == 1);
  FooResult kind = foo_fs_kind(
      (FooText){(const uint8_t *)live, strlen(live)});
  assert(!kind.error && kind.text.len == 4 &&
         !memcmp(kind.text.data, "file", 4));
  assert(!foo_text_release(kind.text).error);
  FooResult working = foo_fs_working();
  assert(!working.error && working.text.len > 0);
  assert(!foo_text_release(working.text).error);
  const char *copy = "foo-service-copy.tmp";
  assert(!foo_fs_copy(
      (FooText){(const uint8_t *)live, strlen(live)},
      (FooText){(const uint8_t *)copy, strlen(copy)}).error);
  assert(!foo_fs_remove(
      (FooText){(const uint8_t *)copy, strlen(copy)}).error);
  content = foo_fs_readbytes(
      (FooText){(const uint8_t *)live, strlen(live)});
  assert(!content.error && content.text.len == bytes.len);
  assert(!memcmp(content.text.data, bytes.data, bytes.len));
  assert(!foo_fs_releasebytes(content.text).error);
  assert(!foo_fs_remove(
      (FooText){(const uint8_t *)live, strlen(live)}).error);
  exists = foo_fs_exists((FooText){(const uint8_t *)live, strlen(live)});
  assert(!exists.error && exists.number == 0);
  assert(foo_fs_read(
      (FooText){(const uint8_t *)live, strlen(live)}).error);

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
