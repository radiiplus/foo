#ifndef FOO_SERVICE_H
#define FOO_SERVICE_H
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
typedef struct {
  const uint8_t *data;
  size_t len;
} FooText;
typedef struct {
  int error;
  void *pointer;
  uint64_t number;
  FooText text;
} FooResult;
void foo_service_init(int count, char **arguments);
void foo_service_close(void);
FooResult foo_text_release(FooText text);
FooResult foo_text_concatenate(FooText left, FooText right);
FooResult foo_text_trim(FooText text);
FooResult foo_text_length(FooText text);
FooResult foo_text_slice(FooText text, uint64_t first, uint64_t last);
FooResult foo_io_input(void);
FooResult foo_io_output(void);
FooResult foo_io_report(void);
FooResult foo_io_read(void *stream, uint64_t size);
FooResult foo_io_line(void *stream);
FooResult foo_io_write(void *stream, FooText text);
FooResult foo_io_close(void *stream);
FooResult foo_fs_open(FooText path, FooText mode);
FooResult foo_fs_read(FooText path);
FooResult foo_fs_write(FooText path, FooText text);
FooResult foo_fs_directory(FooText path);
FooResult foo_fs_join(FooText left, FooText right);
FooResult foo_fs_flush(void *stream);
FooResult foo_fs_seek(void *stream, int64_t offset, FooText origin);
FooResult foo_fs_position(void *stream);
FooResult foo_fs_size(void *stream);
FooResult foo_net_connect(FooText host, uint64_t port);
FooResult foo_net_listen(FooText host, uint64_t port);
FooResult foo_net_accept(void *listener);
FooResult foo_net_port(void *listener);
FooResult foo_net_send(void *socket, FooText text);
FooResult foo_net_sendSome(void *socket, FooText text);
FooResult foo_net_receive(void *socket, uint64_t size);
FooResult foo_net_shutdown(void *socket, FooText direction);
FooResult foo_net_nodelay(void *socket, bool enabled);
FooResult foo_net_keepalive(void *socket, bool enabled);
FooResult foo_net_close(void *socket);
FooResult foo_process_run(FooText command);
FooResult foo_process_argument(uint64_t index);
FooResult foo_process_count(void);
FooResult foo_process_environment(FooText name);
FooResult foo_time_current(void);
FooResult foo_time_sleep(uint64_t nanos);
FooResult foo_thread_spawn(void (*function)(void *), void *context);
FooResult foo_thread_wait(void *thread);
FooResult foo_thread_mutex(void);
FooResult foo_thread_lock(void *mutex);
FooResult foo_thread_unlock(void *mutex);
FooResult foo_thread_condition(void);
FooResult foo_thread_signal(void *condition);
FooResult foo_thread_await(void *condition, void *mutex);
FooResult foo_thread_close(void *resource);
FooResult foo_task_backend(void);
FooResult foo_task_which(void);
FooResult foo_task_executor(void);
FooResult foo_task_block(void (*callback)(void));
FooResult foo_task_channel(void);
FooResult foo_task_send(void *channel, int64_t value);
FooResult foo_task_receive(void *channel, int64_t *output);
FooResult foo_task_scope(void);
FooResult foo_task_launch(void *scope, void (*callback)(int64_t), int64_t argument);
FooResult foo_task_join(void *scope);
FooResult foo_task_pool(void);
FooResult foo_task_submit(void *pool, void (*callback)(int64_t), int64_t argument);
FooResult foo_task_wait(void *pool);
FooResult foo_task_affinity(uint64_t cpu);
FooResult foo_task_label(FooText name);
#endif
