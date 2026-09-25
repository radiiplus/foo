#ifndef _WIN32
#define _GNU_SOURCE
#endif
#define _POSIX_C_SOURCE 200809L
#include "service.h"
#include <errno.h>
#include <limits.h>
#include <stdatomic.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <time.h>
#ifdef _WIN32
#define WIN32_LEAN_AND_MEAN
#include <direct.h>
#include <windows.h>
#include <winsock2.h>
#include <ws2tcpip.h>
typedef SOCKET Socket;
#define INVALID INVALID_SOCKET
#define disconnect closesocket
#define FOO_SHUT_READ SD_RECEIVE
#define FOO_SHUT_WRITE SD_SEND
#define FOO_SHUT_BOTH SD_BOTH
#else
#include <netdb.h>
#include <netinet/in.h>
#include <netinet/tcp.h>
#include <pthread.h>
#include <sched.h>
#include <sys/socket.h>
#include <sys/wait.h>
#include <unistd.h>
typedef int Socket;
#define INVALID (-1)
#define disconnect close
#define FOO_SHUT_READ SHUT_RD
#define FOO_SHUT_WRITE SHUT_WR
#define FOO_SHUT_BOTH SHUT_RDWR
#endif

enum { OK, MEMORY, ARGUMENT, IO, CLOSED, MISSING, SYSTEM, BOUNDS };
enum { TEXT = 1, FILES, SOCKETS, THREADS, MUTEX, CONDITION,
       TASK_EXECUTOR, TASK_CHANNEL, TASK_SCOPE };
typedef struct Resource {
  void *data;
  size_t size;
  int kind;
  int closed;
  struct Resource *next;
} Resource;
static Resource *resources;
static atomic_flag gate = ATOMIC_FLAG_INIT;
static int count;
static char **arguments;
#ifdef _WIN32
static int winsock;
#endif
static void enter(void) {
  while (atomic_flag_test_and_set_explicit(&gate, memory_order_acquire)) {
  }
}
static void leave(void) {
  atomic_flag_clear_explicit(&gate, memory_order_release);
}
static FooResult failure(int code) { return (FooResult){.error = code}; }
static void *owned(size_t size, int kind) {
  Resource *entry = calloc(1, sizeof(*entry));
  void *data = calloc(1, size ? size : 1);
  if (!entry || !data) {
    free(entry);
    free(data);
    return NULL;
  }
  entry->data = data;
  entry->size = size;
  entry->kind = kind;
  enter();
  entry->next = resources;
  resources = entry;
  leave();
  return data;
}
static Resource *resource(void *data, int kind) {
  enter();
  Resource *entry = resources;
  while (entry && (entry->data != data || entry->kind != kind))
    entry = entry->next;
  leave();
  return entry && !entry->closed ? entry : NULL;
}
static FooResult text(const void *data, size_t size) {
  if (!size)
    return (FooResult){0};
  void *copy = owned(size, TEXT);
  if (!copy)
    return failure(MEMORY);
  memcpy(copy, data, size);
  return (FooResult){.text = {copy, size}};
}
static char *string(FooText value) {
  if (value.len == SIZE_MAX || (value.len && memchr(value.data, 0, value.len)))
    return NULL;
  char *result = malloc(value.len + 1);
  if (!result)
    return NULL;
  if (value.len)
    memcpy(result, value.data, value.len);
  result[value.len] = 0;
  return result;
}
void foo_service_init(int argc, char **argv) {
  count = argc;
  arguments = argv;
}
FooResult foo_text_release(FooText value) {
  if (!value.len)
    return (FooResult){0};
  enter();
  Resource **slot = &resources;
  while (*slot && ((*slot)->data != value.data || (*slot)->kind != TEXT))
    slot = &(*slot)->next;
  Resource *entry = *slot;
  if (!entry || entry->size != value.len) {
    leave();
    return failure(ARGUMENT);
  }
  *slot = entry->next;
  leave();
  free(entry->data);
  free(entry);
  return (FooResult){0};
}
FooResult foo_text_length(FooText value) {
  return (FooResult){.number = value.len};
}
FooResult foo_text_concatenate(FooText left, FooText right) {
  if (right.len > SIZE_MAX - left.len)
    return failure(BOUNDS);
  size_t size = left.len + right.len;
  if (!size)
    return (FooResult){0};
  uint8_t *data = owned(size, TEXT);
  if (!data)
    return failure(MEMORY);
  if (left.len)
    memcpy(data, left.data, left.len);
  if (right.len)
    memcpy(data + left.len, right.data, right.len);
  return (FooResult){.text = {data, size}};
}
static int space(uint8_t byte) {
  return byte == ' ' || byte == '\t' || byte == '\n' || byte == '\r' ||
         byte == '\v' || byte == '\f';
}
FooResult foo_text_trim(FooText value) {
  size_t first = 0, last = value.len;
  while (first < last && space(value.data[first]))
    first++;
  while (last > first && space(value.data[last - 1]))
    last--;
  return text(value.data ? value.data + first : NULL, last - first);
}
FooResult foo_text_slice(FooText value, uint64_t first, uint64_t last) {
  if (first > last || last > value.len)
    return failure(BOUNDS);
  return text(value.data ? value.data + first : NULL, (size_t)(last - first));
}
typedef struct {
  FILE *file;
  int borrowed;
} File;
static File standard[3];
static FooResult stream(FILE *file, int index) {
  enter();
  if (!standard[index].file) {
    standard[index].file = file;
    standard[index].borrowed = 1;
  }
  leave();
  return (FooResult){.pointer = &standard[index]};
}
FooResult foo_io_input(void) { return stream(stdin, 0); }
FooResult foo_io_output(void) { return stream(stdout, 1); }
FooResult foo_io_report(void) { return stream(stderr, 2); }
static File *file(void *pointer) {
  for (int index = 0; index < 3; index++)
    if (pointer == &standard[index])
      return standard[index].file ? pointer : NULL;
  return resource(pointer, FILES) ? pointer : NULL;
}
FooResult foo_io_write(void *pointer, FooText value) {
  File *stream = file(pointer);
  if (!stream || !stream->file)
    return failure(CLOSED);
  if (value.len && fwrite(value.data, 1, value.len, stream->file) != value.len)
    return failure(IO);
  return fflush(stream->file) ? failure(IO) : (FooResult){0};
}
FooResult foo_io_read(void *pointer, uint64_t size) {
  File *stream = file(pointer);
  if (!stream || !stream->file)
    return failure(CLOSED);
  if (size > SIZE_MAX)
    return failure(BOUNDS);
  if (!size)
    return (FooResult){0};
  void *buffer = malloc((size_t)size);
  if (!buffer)
    return failure(MEMORY);
  size_t received = fread(buffer, 1, (size_t)size, stream->file);
  FooResult result =
      ferror(stream->file) ? failure(IO) : text(buffer, received);
  free(buffer);
  return result;
}
FooResult foo_io_line(void *pointer) {
  File *stream = file(pointer);
  if (!stream || !stream->file)
    return failure(CLOSED);
  size_t length = 0, capacity = 128;
  char *buffer = malloc(capacity);
  if (!buffer)
    return failure(MEMORY);
  int byte;
  while ((byte = fgetc(stream->file)) != EOF && byte != '\n') {
    if (length == capacity) {
      if (capacity > SIZE_MAX / 2) {
        free(buffer);
        return failure(BOUNDS);
      }
      char *next = realloc(buffer, capacity * 2);
      if (!next) {
        free(buffer);
        return failure(MEMORY);
      }
      buffer = next;
      capacity *= 2;
    }
    buffer[length++] = (char)byte;
  }
  if (length && buffer[length - 1] == '\r')
    length--;
  FooResult result = ferror(stream->file) ? failure(IO) : text(buffer, length);
  free(buffer);
  return result;
}
FooResult foo_io_close(void *pointer) {
  File *stream = file(pointer);
  if (!stream || !stream->file)
    return failure(CLOSED);
  if (stream->borrowed)
    return failure(ARGUMENT);
  int result = fclose(stream->file);
  stream->file = NULL;
  resource(pointer, FILES)->closed = 1;
  return result ? failure(IO) : (FooResult){0};
}
FooResult foo_fs_open(FooText path, FooText mode) {
  char *name = string(path), *access = string(mode);
  if (!name || !access) {
    free(name);
    free(access);
    return failure(ARGUMENT);
  }
  if (strcmp(access, "read") && strcmp(access, "write") &&
      strcmp(access, "append")) {
    free(name);
    free(access);
    return failure(ARGUMENT);
  }
  FILE *handle = fopen(name, !strcmp(access, "read")    ? "rb"
                             : !strcmp(access, "write") ? "wb"
                                                        : "ab");
  free(name);
  free(access);
  if (!handle)
    return failure(IO);
  File *result = owned(sizeof(*result), FILES);
  if (!result) {
    fclose(handle);
    return failure(MEMORY);
  }
  result->file = handle;
  return (FooResult){.pointer = result};
}
FooResult foo_fs_flush(void *pointer) {
  File *stream = file(pointer);
  return !stream || !stream->file ? failure(CLOSED)
                                  : fflush(stream->file) ? failure(IO)
                                                        : (FooResult){0};
}
static int file_seek(FILE *stream, int64_t offset, int origin) {
#ifdef _WIN32
  return _fseeki64(stream, offset, origin);
#else
  return fseeko(stream, (off_t)offset, origin);
#endif
}
static int64_t file_position(FILE *stream) {
#ifdef _WIN32
  return _ftelli64(stream);
#else
  return (int64_t)ftello(stream);
#endif
}
FooResult foo_fs_seek(void *pointer, int64_t offset, FooText origin) {
  File *stream = file(pointer);
  if (!stream || !stream->file)
    return failure(CLOSED);
  int base = origin.len == 5 && !memcmp(origin.data, "start", 5)     ? SEEK_SET
             : origin.len == 7 && !memcmp(origin.data, "current", 7) ? SEEK_CUR
             : origin.len == 3 && !memcmp(origin.data, "end", 3)     ? SEEK_END
                                                                       : -1;
  return base < 0 ? failure(ARGUMENT)
                  : file_seek(stream->file, offset, base) ? failure(IO)
                                                          : (FooResult){0};
}
FooResult foo_fs_position(void *pointer) {
  File *stream = file(pointer);
  if (!stream || !stream->file)
    return failure(CLOSED);
  int64_t result = file_position(stream->file);
  return result < 0 ? failure(IO) : (FooResult){.number = (uint64_t)result};
}
FooResult foo_fs_size(void *pointer) {
  File *stream = file(pointer);
  if (!stream || !stream->file)
    return failure(CLOSED);
  int64_t position = file_position(stream->file);
  if (position < 0 || file_seek(stream->file, 0, SEEK_END))
    return failure(IO);
  int64_t result = file_position(stream->file);
  if (file_seek(stream->file, position, SEEK_SET))
    return failure(IO);
  return result < 0 ? failure(IO) : (FooResult){.number = (uint64_t)result};
}
FooResult foo_fs_read(FooText path) {
  FooResult opened = foo_fs_open(path, (FooText){(const uint8_t *)"read", 4});
  if (opened.error)
    return opened;
  FILE *handle = ((File *)opened.pointer)->file;
  size_t size = 0, capacity = 4096;
  uint8_t *buffer = malloc(capacity);
  if (!buffer) {
    foo_io_close(opened.pointer);
    return failure(MEMORY);
  }
  for (;;) {
    size += fread(buffer + size, 1, capacity - size, handle);
    if (size < capacity)
      break;
    if (capacity > SIZE_MAX / 2) {
      free(buffer);
      foo_io_close(opened.pointer);
      return failure(BOUNDS);
    }
    void *next = realloc(buffer, capacity * 2);
    if (!next) {
      free(buffer);
      foo_io_close(opened.pointer);
      return failure(MEMORY);
    }
    buffer = next;
    capacity *= 2;
  }
  FooResult result = ferror(handle) ? failure(IO) : text(buffer, size);
  free(buffer);
  FooResult closed = foo_io_close(opened.pointer);
  return result.error ? result : closed.error ? closed : result;
}
FooResult foo_fs_write(FooText path, FooText value) {
  FooResult opened = foo_fs_open(path, (FooText){(const uint8_t *)"write", 5});
  if (opened.error)
    return opened;
  FooResult result = foo_io_write(opened.pointer, value),
            closed = foo_io_close(opened.pointer);
  return result.error ? result : closed;
}
FooResult foo_fs_directory(FooText path) {
  char *name = string(path);
  if (!name)
    return failure(ARGUMENT);
#ifdef _WIN32
  int result = _mkdir(name);
#else
  int result = mkdir(name, 0777);
#endif
  struct stat status;
#ifdef _WIN32
  int exists = result && errno == EEXIST && !stat(name, &status) &&
               (status.st_mode & _S_IFMT) == _S_IFDIR;
#else
  int exists = result && errno == EEXIST && !stat(name, &status) &&
               S_ISDIR(status.st_mode);
#endif
  free(name);
  return !result || exists ? (FooResult){0} : failure(IO);
}
FooResult foo_fs_join(FooText left, FooText right) {
  if (!left.len ||
      (right.len && (right.data[0] == '/' || right.data[0] == '\\' ||
                     (right.len > 1 && right.data[1] == ':'))))
    return text(right.data, right.len);
  if (!right.len)
    return text(left.data, left.len);
  int separator =
      left.data[left.len - 1] != '/' && left.data[left.len - 1] != '\\';
  if (right.len > SIZE_MAX - left.len - (size_t)separator)
    return failure(BOUNDS);
  size_t length = left.len + right.len + separator;
  uint8_t *result = owned(length, TEXT);
  if (!result)
    return failure(MEMORY);
  memcpy(result, left.data, left.len);
  if (separator)
    result[left.len] = '/';
  memcpy(result + left.len + separator, right.data, right.len);
  return (FooResult){.text = {result, length}};
}

typedef struct {
  Socket socket;
} Connection;
static int interrupted(void) {
#ifdef _WIN32
  return WSAGetLastError() == WSAEINTR;
#else
  return errno == EINTR;
#endif
}
static FooResult connection(Socket socket) {
  Connection *result = owned(sizeof(*result), SOCKETS);
  if (!result) {
    disconnect(socket);
    return failure(MEMORY);
  }
  result->socket = socket;
  return (FooResult){.pointer = result};
}
static FooResult network(FooText host, uint64_t port, int server) {
  if (port > 65535)
    return failure(BOUNDS);
#ifdef _WIN32
  enter();
  if (!winsock) {
    WSADATA data;
    if (WSAStartup(MAKEWORD(2, 2), &data)) {
      leave();
      return failure(SYSTEM);
    }
    winsock = 1;
  }
  leave();
#endif
  char *name = string(host), service[6];
  if (!name)
    return failure(ARGUMENT);
  snprintf(service, sizeof(service), "%u", (unsigned)port);
  struct addrinfo hints = {0}, *addresses = NULL;
  hints.ai_family = AF_UNSPEC;
  hints.ai_socktype = SOCK_STREAM;
  hints.ai_flags = server ? AI_PASSIVE : 0;
  int error = getaddrinfo(*name ? name : NULL, service, &hints, &addresses);
  free(name);
  if (error)
    return failure(SYSTEM);
  Socket handle = INVALID;
  for (struct addrinfo *address = addresses; address;
       address = address->ai_next) {
    handle =
        socket(address->ai_family, address->ai_socktype, address->ai_protocol);
    if (handle == INVALID)
      continue;
    int enabled = 1;
#ifdef SO_NOSIGPIPE
    setsockopt(handle, SOL_SOCKET, SO_NOSIGPIPE, (const void *)&enabled,
               sizeof(enabled));
#endif
    if (server)
      setsockopt(handle, SOL_SOCKET, SO_REUSEADDR, (const void *)&enabled,
                 sizeof(enabled));
    int result =
        server ? bind(handle, address->ai_addr, (int)address->ai_addrlen)
               : connect(handle, address->ai_addr, (int)address->ai_addrlen);
    if (!result && (!server || !listen(handle, 128)))
      break;
    disconnect(handle);
    handle = INVALID;
  }
  freeaddrinfo(addresses);
  return handle == INVALID ? failure(IO) : connection(handle);
}
FooResult foo_net_connect(FooText host, uint64_t port) {
  return network(host, port, 0);
}
FooResult foo_net_listen(FooText host, uint64_t port) {
  return network(host, port, 1);
}
FooResult foo_net_accept(void *pointer) {
  if (!resource(pointer, SOCKETS))
    return failure(CLOSED);
  Socket handle;
  do {
    handle = accept(((Connection *)pointer)->socket, NULL, NULL);
  } while (handle == INVALID && interrupted());
  return handle == INVALID ? failure(IO) : connection(handle);
}
FooResult foo_net_port(void *pointer) {
  if (!resource(pointer, SOCKETS))
    return failure(CLOSED);
  struct sockaddr_storage address;
#ifdef _WIN32
  int size = sizeof(address);
#else
  socklen_t size = sizeof(address);
#endif
  if (getsockname(((Connection *)pointer)->socket, (struct sockaddr *)&address,
                  &size))
    return failure(IO);
  return (FooResult){
      .number = ntohs(address.ss_family == AF_INET
                          ? ((struct sockaddr_in *)&address)->sin_port
                          : ((struct sockaddr_in6 *)&address)->sin6_port)};
}
FooResult foo_net_send(void *pointer, FooText value) {
  if (!resource(pointer, SOCKETS))
    return failure(CLOSED);
  size_t sent = 0;
  while (sent < value.len) {
    size_t chunk = value.len - sent;
    if (chunk > INT_MAX)
      chunk = INT_MAX;
#ifdef MSG_NOSIGNAL
    int flags = MSG_NOSIGNAL;
#else
    int flags = 0;
#endif
    int result = (int)send(((Connection *)pointer)->socket,
                           (const char *)value.data + sent, (int)chunk, flags);
    if (result < 0 && interrupted())
      continue;
    if (result <= 0)
      return failure(IO);
    sent += (size_t)result;
  }
  return (FooResult){.number = sent};
}
FooResult foo_net_sendSome(void *pointer, FooText value) {
  if (!resource(pointer, SOCKETS))
    return failure(CLOSED);
  if (!value.len)
    return (FooResult){0};
  size_t size = value.len > INT_MAX ? INT_MAX : value.len;
#ifdef MSG_NOSIGNAL
  int flags = MSG_NOSIGNAL;
#else
  int flags = 0;
#endif
  int sent;
  do {
    sent = (int)send(((Connection *)pointer)->socket,
                     (const char *)value.data, (int)size, flags);
  } while (sent < 0 && interrupted());
  return sent <= 0 ? failure(IO) : (FooResult){.number = (uint64_t)sent};
}
FooResult foo_net_receive(void *pointer, uint64_t size) {
  if (!resource(pointer, SOCKETS))
    return failure(CLOSED);
  if (size > INT_MAX)
    return failure(BOUNDS);
  if (!size)
    return (FooResult){0};
  void *buffer = malloc((size_t)size);
  if (!buffer)
    return failure(MEMORY);
  int received;
  do {
    received = (int)recv(((Connection *)pointer)->socket, buffer, (int)size, 0);
  } while (received < 0 && interrupted());
  FooResult result =
      received < 0 ? failure(IO) : text(buffer, (size_t)received);
  free(buffer);
  return result;
}
FooResult foo_net_shutdown(void *pointer, FooText direction) {
  if (!resource(pointer, SOCKETS))
    return failure(CLOSED);
  int mode = direction.len == 4 && !memcmp(direction.data, "read", 4)    ? FOO_SHUT_READ
             : direction.len == 5 && !memcmp(direction.data, "write", 5) ? FOO_SHUT_WRITE
             : direction.len == 4 && !memcmp(direction.data, "both", 4)  ? FOO_SHUT_BOTH
                                                                           : -1;
  return mode < 0 ? failure(ARGUMENT)
                  : shutdown(((Connection *)pointer)->socket, mode)
                      ? failure(IO)
                      : (FooResult){0};
}
FooResult foo_net_nodelay(void *pointer, bool enabled) {
  if (!resource(pointer, SOCKETS))
    return failure(CLOSED);
  int value = enabled ? 1 : 0;
  return setsockopt(((Connection *)pointer)->socket, IPPROTO_TCP, TCP_NODELAY,
                    (const char *)&value, sizeof(value))
             ? failure(IO)
             : (FooResult){0};
}
FooResult foo_net_keepalive(void *pointer, bool enabled) {
  if (!resource(pointer, SOCKETS))
    return failure(CLOSED);
  int value = enabled ? 1 : 0;
  return setsockopt(((Connection *)pointer)->socket, SOL_SOCKET, SO_KEEPALIVE,
                    (const char *)&value, sizeof(value))
             ? failure(IO)
             : (FooResult){0};
}
FooResult foo_net_close(void *pointer) {
  Resource *entry = resource(pointer, SOCKETS);
  if (!entry)
    return failure(CLOSED);
  int result = disconnect(((Connection *)pointer)->socket);
  entry->closed = 1;
  return result ? failure(IO) : (FooResult){0};
}
FooResult foo_process_run(FooText command) {
  char *value = string(command);
  if (!value)
    return failure(ARGUMENT);
  int status = system(value);
  free(value);
  if (status == -1)
    return failure(SYSTEM);
#ifndef _WIN32
  status = WIFEXITED(status)     ? WEXITSTATUS(status)
           : WIFSIGNALED(status) ? 128 + WTERMSIG(status)
                                 : status;
#endif
  return (FooResult){.number = (uint64_t)status};
}
FooResult foo_process_count(void) {
  return (FooResult){.number = (uint64_t)count};
}
FooResult foo_process_argument(uint64_t index) {
  return index >= (uint64_t)count
             ? failure(BOUNDS)
             : text(arguments[index], strlen(arguments[index]));
}
FooResult foo_process_environment(FooText name) {
  char *key = string(name);
  if (!key)
    return failure(ARGUMENT);
  const char *value = getenv(key);
  free(key);
  return value ? text(value, strlen(value)) : failure(MISSING);
}
FooResult foo_time_current(void) {
#ifdef _WIN32
  LARGE_INTEGER counter, frequency;
  if (!QueryPerformanceCounter(&counter) ||
      !QueryPerformanceFrequency(&frequency))
    return failure(SYSTEM);
  return (FooResult){
      .number = (uint64_t)(counter.QuadPart / frequency.QuadPart) * 1000000000 +
                (uint64_t)(counter.QuadPart % frequency.QuadPart) * 1000000000 /
                    (uint64_t)frequency.QuadPart};
#else
  struct timespec stamp;
  if (clock_gettime(CLOCK_MONOTONIC, &stamp))
    return failure(SYSTEM);
  return (FooResult){.number = (uint64_t)stamp.tv_sec * 1000000000 +
                               (uint64_t)stamp.tv_nsec};
#endif
}
FooResult foo_time_sleep(uint64_t nanos) {
#ifdef _WIN32
  uint64_t milliseconds = nanos / 1000000 + (nanos % 1000000 != 0);
  while (milliseconds) {
    DWORD chunk = milliseconds >= INFINITE ? INFINITE - 1 : (DWORD)milliseconds;
    Sleep(chunk);
    milliseconds -= chunk;
  }
#else
  struct timespec duration = {(time_t)(nanos / 1000000000),
                              (long)(nanos % 1000000000)};
  while (nanosleep(&duration, &duration))
    if (errno != EINTR)
      return failure(SYSTEM);
#endif
  return (FooResult){0};
}

typedef struct {
  void (*function)(void *);
  void *context;
#ifdef _WIN32
  HANDLE handle;
  CRITICAL_SECTION mutex;
  CONDITION_VARIABLE condition;
#else
  pthread_t handle;
  pthread_mutex_t mutex;
  pthread_cond_t condition;
#endif
} Task;
#ifdef _WIN32
static DWORD WINAPI work(void *pointer) {
  Task *task = pointer;
  task->function(task->context);
  return 0;
}
#else
static void *work(void *pointer) {
  Task *task = pointer;
  task->function(task->context);
  return NULL;
}
#endif
FooResult foo_thread_spawn(void (*function)(void *), void *context) {
  Task *task = owned(sizeof(*task), THREADS);
  if (!task)
    return failure(MEMORY);
  task->function = function;
  task->context = context;
#ifdef _WIN32
  task->handle = CreateThread(NULL, 0, work, task, 0, NULL);
  int failed = !task->handle;
#else
  int failed = pthread_create(&task->handle, NULL, work, task);
#endif
  if (failed) {
    resource(task, THREADS)->closed = 1;
    return failure(SYSTEM);
  }
  return (FooResult){.pointer = task};
}
FooResult foo_thread_wait(void *pointer) {
  Resource *entry = resource(pointer, THREADS);
  if (!entry)
    return failure(CLOSED);
  Task *task = pointer;
#ifdef _WIN32
  int failed = WaitForSingleObject(task->handle, INFINITE) != WAIT_OBJECT_0;
  if (!failed)
    CloseHandle(task->handle);
#else
  int failed = pthread_join(task->handle, NULL);
#endif
  if (failed)
    return failure(SYSTEM);
  entry->closed = 1;
  return (FooResult){0};
}
FooResult foo_thread_mutex(void) {
  Task *task = owned(sizeof(*task), MUTEX);
  if (!task)
    return failure(MEMORY);
#ifdef _WIN32
  InitializeCriticalSection(&task->mutex);
#else
  if (pthread_mutex_init(&task->mutex, NULL)) {
    resource(task, MUTEX)->closed = 1;
    return failure(SYSTEM);
  }
#endif
  return (FooResult){.pointer = task};
}
FooResult foo_thread_condition(void) {
  Task *task = owned(sizeof(*task), CONDITION);
  if (!task)
    return failure(MEMORY);
#ifdef _WIN32
  InitializeConditionVariable(&task->condition);
#else
  if (pthread_cond_init(&task->condition, NULL)) {
    resource(task, CONDITION)->closed = 1;
    return failure(SYSTEM);
  }
#endif
  return (FooResult){.pointer = task};
}
FooResult foo_thread_lock(void *pointer) {
  if (!resource(pointer, MUTEX))
    return failure(CLOSED);
  Task *task = pointer;
#ifdef _WIN32
  EnterCriticalSection(&task->mutex);
#else
  if (pthread_mutex_lock(&task->mutex))
    return failure(SYSTEM);
#endif
  return (FooResult){0};
}
FooResult foo_thread_unlock(void *pointer) {
  if (!resource(pointer, MUTEX))
    return failure(CLOSED);
  Task *task = pointer;
#ifdef _WIN32
  LeaveCriticalSection(&task->mutex);
#else
  if (pthread_mutex_unlock(&task->mutex))
    return failure(SYSTEM);
#endif
  return (FooResult){0};
}
FooResult foo_thread_signal(void *pointer) {
  if (!resource(pointer, CONDITION))
    return failure(CLOSED);
  Task *task = pointer;
#ifdef _WIN32
  WakeConditionVariable(&task->condition);
#else
  if (pthread_cond_signal(&task->condition))
    return failure(SYSTEM);
#endif
  return (FooResult){0};
}
FooResult foo_thread_await(void *condition, void *mutex) {
  if (!resource(condition, CONDITION) || !resource(mutex, MUTEX))
    return failure(CLOSED);
  Task *c = condition, *m = mutex;
#ifdef _WIN32
  if (!SleepConditionVariableCS(&c->condition, &m->mutex, INFINITE))
    return failure(SYSTEM);
#else
  if (pthread_cond_wait(&c->condition, &m->mutex))
    return failure(SYSTEM);
#endif
  return (FooResult){0};
}
FooResult foo_thread_close(void *pointer) {
  Resource *entry = resource(pointer, MUTEX);
  if (!entry)
    entry = resource(pointer, CONDITION);
  if (!entry)
    return failure(CLOSED);
  Task *task = pointer;
#ifdef _WIN32
  if (entry->kind == MUTEX)
    DeleteCriticalSection(&task->mutex);
#else
  int failed = entry->kind == MUTEX ? pthread_mutex_destroy(&task->mutex)
                                    : pthread_cond_destroy(&task->condition);
  if (failed)
    return failure(SYSTEM);
#endif
  entry->closed = 1;
  return (FooResult){0};
}

typedef struct {
  int64_t slots[256];
  size_t head, tail, count;
} TaskChannel;
typedef struct {
  void *threads[128];
  size_t count;
} TaskScope;
typedef struct {
  void (*callback)(int64_t);
  int64_t argument;
} ScopedCall;
static void scoped_work(void *pointer) {
  ScopedCall *call = pointer;
  call->callback(call->argument);
  free(call);
}
static uint64_t task_backend(void) {
#ifdef _WIN32
  return 3;
#elif defined(__linux__)
  return 1;
#elif defined(__APPLE__) || defined(__FreeBSD__) || defined(__OpenBSD__) || defined(__NetBSD__)
  return 2;
#else
  return 0;
#endif
}
FooResult foo_task_backend(void) { return (FooResult){.number = task_backend()}; }
FooResult foo_task_which(void) {
  static const char *names[] = {"threaded", "epoll", "kqueue", "iocp"};
  return (FooResult){.pointer = (void *)names[task_backend()]};
}
FooResult foo_task_executor(void) {
  uint64_t *executor = owned(sizeof(*executor), TASK_EXECUTOR);
  if (!executor) return failure(MEMORY);
  *executor = task_backend();
  return (FooResult){.pointer = executor};
}
FooResult foo_task_block(void (*callback)(void)) {
  callback();
  return (FooResult){0};
}
FooResult foo_task_channel(void) {
  TaskChannel *channel = owned(sizeof(*channel), TASK_CHANNEL);
  return channel ? (FooResult){.pointer = channel} : failure(MEMORY);
}
FooResult foo_task_send(void *pointer, int64_t value) {
  TaskChannel *channel = resource(pointer, TASK_CHANNEL) ? pointer : NULL;
  if (!channel) return failure(CLOSED);
  enter();
  if (channel->count == 256) { leave(); return (FooResult){.number = 0}; }
  channel->slots[channel->tail] = value;
  channel->tail = (channel->tail + 1) % 256;
  channel->count++;
  leave();
  return (FooResult){.number = 1};
}
FooResult foo_task_receive(void *pointer, int64_t *output) {
  TaskChannel *channel = resource(pointer, TASK_CHANNEL) ? pointer : NULL;
  if (!channel || !output) return failure(CLOSED);
  enter();
  if (!channel->count) { leave(); return (FooResult){.number = 0}; }
  *output = channel->slots[channel->head];
  channel->head = (channel->head + 1) % 256;
  channel->count--;
  leave();
  return (FooResult){.number = 1};
}
static FooResult task_scope(void) {
  TaskScope *scope = owned(sizeof(*scope), TASK_SCOPE);
  return scope ? (FooResult){.pointer = scope} : failure(MEMORY);
}
FooResult foo_task_scope(void) { return task_scope(); }
FooResult foo_task_pool(void) { return task_scope(); }
static FooResult task_launch(void *pointer, void (*callback)(int64_t),
                             int64_t argument) {
  TaskScope *scope = resource(pointer, TASK_SCOPE) ? pointer : NULL;
  if (!scope) return failure(CLOSED);
  enter();
  if (scope->count == 128) { leave(); return (FooResult){.number = 0}; }
  leave();
  ScopedCall *call = malloc(sizeof(*call));
  if (!call) return failure(MEMORY);
  *call = (ScopedCall){callback, argument};
  FooResult spawned = foo_thread_spawn(scoped_work, call);
  if (spawned.error) { free(call); return spawned; }
  enter();
  scope->threads[scope->count++] = spawned.pointer;
  leave();
  return (FooResult){.number = 1};
}
FooResult foo_task_launch(void *scope, void (*callback)(int64_t), int64_t argument) {
  return task_launch(scope, callback, argument);
}
FooResult foo_task_submit(void *pool, void (*callback)(int64_t), int64_t argument) {
  return task_launch(pool, callback, argument);
}
static FooResult task_join(void *pointer) {
  TaskScope *scope = resource(pointer, TASK_SCOPE) ? pointer : NULL;
  if (!scope) return failure(CLOSED);
  for (size_t index = 0; index < scope->count; index++) {
    FooResult joined = foo_thread_wait(scope->threads[index]);
    if (joined.error) return joined;
  }
  scope->count = 0;
  return (FooResult){0};
}
FooResult foo_task_join(void *scope) { return task_join(scope); }
FooResult foo_task_wait(void *pool) { return task_join(pool); }
FooResult foo_task_affinity(uint64_t cpu) {
#ifdef _WIN32
  if (cpu >= sizeof(DWORD_PTR) * CHAR_BIT) return (FooResult){.number = 0};
  return (FooResult){.number = SetThreadAffinityMask(GetCurrentThread(),
      ((DWORD_PTR)1) << cpu) != 0};
#elif defined(__linux__)
  if (cpu >= CPU_SETSIZE) return (FooResult){.number = 0};
  cpu_set_t set;
  CPU_ZERO(&set);
  CPU_SET((int)cpu, &set);
  return (FooResult){.number = sched_setaffinity(0, sizeof(set), &set) == 0};
#else
  return (FooResult){.number = 0};
#endif
}
FooResult foo_task_label(FooText name) {
  char *value = string(name);
  if (!value) return failure(ARGUMENT);
#ifdef _WIN32
  int ok = 1;
#elif defined(__APPLE__)
  int ok = pthread_setname_np(value) == 0;
#else
  int ok = pthread_setname_np(pthread_self(), value) == 0;
#endif
  free(value);
  return (FooResult){.number = (uint64_t)ok};
}
void foo_service_close(void) {
  /* Join callbacks before reclaiming any memory they can still access. */
  for (;;) {
    enter();
    Resource *entry = resources;
    while (entry && (entry->closed || entry->kind != THREADS))
      entry = entry->next;
    leave();
    if (!entry)
      break;
    if (foo_thread_wait(entry->data).error)
      return;
  }
  while (resources) {
    Resource *entry = resources;
    if (!entry->closed) {
      if (entry->kind == FILES)
        foo_io_close(entry->data);
      if (entry->kind == SOCKETS)
        foo_net_close(entry->data);
      if (entry->kind == MUTEX || entry->kind == CONDITION)
        foo_thread_close(entry->data);
    }
    resources = entry->next;
    free(entry->data);
    free(entry);
  }
  count = 0;
  arguments = NULL;
#ifdef _WIN32
  if (winsock) {
    WSACleanup();
    winsock = 0;
  }
#endif
}
