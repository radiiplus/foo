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
#ifndef FOO_SERVICE_SELECTIVE
#define FOO_SERVICE_FS 1
#define FOO_SERVICE_NET 1
#define FOO_SERVICE_THREAD 1
#define FOO_SERVICE_TASK 1
#endif
#ifdef _WIN32
#define WIN32_LEAN_AND_MEAN
#include <direct.h>
#include <io.h>
#include <process.h>
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
#include <fcntl.h>
#include <netdb.h>
#include <netinet/in.h>
#include <netinet/tcp.h>
#include <pthread.h>
#include <sched.h>
#include <sys/socket.h>
#include <sys/wait.h>
#include <unistd.h>
#ifdef __linux__
#include <sys/epoll.h>
#include <sys/eventfd.h>
#endif
typedef int Socket;
#define INVALID (-1)
#define disconnect close
#define FOO_SHUT_READ SHUT_RD
#define FOO_SHUT_WRITE SHUT_WR
#define FOO_SHUT_BOTH SHUT_RDWR
#endif

enum { OK, MEMORY, ARGUMENT, IO, CLOSED, MISSING, SYSTEM, BOUNDS };
enum { TEXT = 1, FILES, SOCKETS, THREADS, MUTEX, CONDITION,
       TASK_EXECUTOR, TASK_CHANNEL, TASK_SCOPE, TASK_POOL };
typedef struct Resource {
  void *data;
  size_t size;
  int kind;
  atomic_int closed;
  struct Resource *next;
  struct Resource *prev;
  struct Resource *chain;
} Resource;
static Resource *resources;
enum { BINS = 256 };
static Resource *bins[BINS];
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
static size_t bucket(void *data) {
  uintptr_t address = (uintptr_t)data >> 4;
  address ^= address >> 11;
  return address % BINS;
}
static void forget(Resource *entry) {
  Resource **slot = &bins[bucket(entry->data)];
  while (*slot && *slot != entry)
    slot = &(*slot)->chain;
  if (*slot)
    *slot = entry->chain;
}
static FooResult failure(int code) { return (FooResult){.error = code}; }
static int adopt(void *data, size_t size, int kind) {
  Resource *entry = calloc(1, sizeof(*entry));
  if (!entry)
    return 0;
  entry->data = data;
  entry->size = size;
  entry->kind = kind;
  atomic_init(&entry->closed, 0);
  enter();
  entry->next = resources;
  if (resources)
    resources->prev = entry;
  resources = entry;
  size_t index = bucket(data);
  entry->chain = bins[index];
  bins[index] = entry;
  leave();
  return 1;
}
static void *owned(size_t size, int kind) {
  void *data = calloc(1, size ? size : 1);
  if (!data || !adopt(data, size, kind)) {
    free(data);
    return NULL;
  }
  return data;
}
static Resource *resource(void *data, int kind) {
  enter();
  Resource *entry = bins[bucket(data)];
  while (entry && (entry->data != data || entry->kind != kind))
    entry = entry->chain;
  if (entry && entry->closed)
    entry = NULL;
  leave();
  return entry;
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
  Resource *entry = bins[bucket((void *)value.data)];
  while (entry && (entry->data != value.data || entry->kind != TEXT))
    entry = entry->chain;
  if (!entry || entry->size != value.len) {
    leave();
    return failure(ARGUMENT);
  }
  if (entry->prev)
    entry->prev->next = entry->next;
  else
    resources = entry->next;
  if (entry->next)
    entry->next->prev = entry->prev;
  forget(entry);
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
FooResult foo_text_find(FooText value, FooText needle) {
  if (!needle.len)
    return (FooResult){.pointer = (void *)1};
  if (!value.data || !needle.data || needle.len > value.len)
    return (FooResult){0};
  if (needle.len == 1) {
    const uint8_t *found = memchr(value.data, needle.data[0], value.len);
    return found ? (FooResult){.pointer = (void *)1,
                               .number = (uint64_t)(found - value.data)}
                 : (FooResult){0};
  }
  if (value.len < 64 || needle.len < 4) {
    for (size_t index = 0; index <= value.len - needle.len; index++)
      if (!memcmp(value.data + index, needle.data, needle.len))
        return (FooResult){.pointer = (void *)1, .number = index};
    return (FooResult){0};
  }
  size_t skip[256];
  for (size_t index = 0; index < 256; index++)
    skip[index] = needle.len;
  for (size_t index = 0; index + 1 < needle.len; index++)
    skip[needle.data[index]] = needle.len - index - 1;
  size_t index = 0;
  while (index <= value.len - needle.len) {
    if (needle.data[needle.len - 1] == value.data[index + needle.len - 1] &&
        !memcmp(value.data + index, needle.data, needle.len - 1))
      return (FooResult){.pointer = (void *)1, .number = index};
    index += skip[value.data[index + needle.len - 1]];
  }
  return (FooResult){0};
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
FooResult foo_fs_handle(void *pointer) {
  File *stream = file(pointer);
  if (!stream || !stream->file)
    return failure(CLOSED);
#ifdef _WIN32
  int descriptor = _fileno(stream->file);
  if (descriptor < 0)
    return failure(IO);
  intptr_t handle = _get_osfhandle(descriptor);
  return handle == -1 ? failure(IO)
                      : (FooResult){.number = (uint64_t)(uintptr_t)handle};
#else
  int descriptor = fileno(stream->file);
  return descriptor < 0 ? failure(IO)
                        : (FooResult){.number = (uint64_t)descriptor};
#endif
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
FooResult foo_fs_sync(void *pointer) {
  File *stream = file(pointer);
  if (!stream || !stream->file)
    return failure(CLOSED);
  if (fflush(stream->file))
    return failure(IO);
#ifdef _WIN32
  return _commit(_fileno(stream->file)) ? failure(IO) : (FooResult){0};
#else
  return fsync(fileno(stream->file)) ? failure(IO) : (FooResult){0};
#endif
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
  FooResult measured = foo_fs_size(opened.pointer);
  if (!measured.error && measured.number <= SIZE_MAX)
    capacity = measured.number ? (size_t)measured.number : 1;
  uint8_t *buffer = malloc(capacity);
  if (!buffer) {
    foo_io_close(opened.pointer);
    return failure(MEMORY);
  }
  for (;;) {
    size += fread(buffer + size, 1, capacity - size, handle);
    if (size < capacity)
      break;
    int extra = fgetc(handle);
    if (extra == EOF)
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
    buffer[size++] = (uint8_t)extra;
  }
  FooResult result = {0};
  if (ferror(handle)) {
    free(buffer);
    result = failure(IO);
  } else if (!size) {
    free(buffer);
  } else if (!adopt(buffer, size, TEXT)) {
    free(buffer);
    result = failure(MEMORY);
  } else {
    result.text = (FooText){buffer, size};
  }
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
FooResult foo_fs_readbytes(FooText path) { return foo_fs_read(path); }
FooResult foo_fs_writebytes(FooText path, FooText value) {
  return foo_fs_write(path, value);
}
FooResult foo_fs_releasebytes(FooText value) {
  return foo_text_release(value);
}
#ifndef _WIN32
static int syncparent(const char *path) {
  char *copy = strdup(path);
  if (!copy)
    return -1;
  char *separator = strrchr(copy, '/');
  const char *parent = ".";
  if (separator) {
    if (separator == copy)
      separator[1] = 0;
    else
      *separator = 0;
    parent = copy;
  }
  int flags = O_RDONLY;
#ifdef O_DIRECTORY
  flags |= O_DIRECTORY;
#endif
  int descriptor = open(parent, flags);
  int result = descriptor < 0 || fsync(descriptor);
  if (descriptor >= 0 && close(descriptor))
    result = 1;
  free(copy);
  return result;
}
#endif
FooResult foo_fs_replace(FooText source, FooText destination) {
  char *from = string(source), *to = string(destination);
  if (!from || !to) {
    free(from);
    free(to);
    return failure(ARGUMENT);
  }
#ifdef _WIN32
  int result = !MoveFileExA(from, to,
      MOVEFILE_REPLACE_EXISTING | MOVEFILE_WRITE_THROUGH);
#else
  int result = rename(from, to);
  if (!result)
    result = syncparent(to);
#endif
  free(from);
  free(to);
  return result ? failure(IO) : (FooResult){0};
}
FooResult foo_fs_remove(FooText path) {
  char *name = string(path);
  if (!name)
    return failure(ARGUMENT);
  int result = remove(name);
  free(name);
  return result ? failure(IO) : (FooResult){0};
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
FooResult foo_fs_exists(FooText path) {
  char *name = string(path);
  if (!name)
    return failure(ARGUMENT);
  struct stat status;
  int result = stat(name, &status);
  int problem = errno;
  free(name);
  if (!result)
    return (FooResult){.number = 1};
  return problem == ENOENT ? (FooResult){0} : failure(IO);
}
FooResult foo_fs_kind(FooText path) {
  char *name = string(path);
  if (!name)
    return failure(ARGUMENT);
  struct stat status;
  int result = stat(name, &status);
  int problem = errno;
  free(name);
  if (result)
    return problem == ENOENT ? failure(MISSING) : failure(IO);
#ifdef _WIN32
  const char *value = (status.st_mode & _S_IFMT) == _S_IFREG ? "file" :
                      (status.st_mode & _S_IFMT) == _S_IFDIR ? "directory" :
                                                               "other";
#else
  const char *value = S_ISREG(status.st_mode) ? "file" :
                      S_ISDIR(status.st_mode) ? "directory" : "other";
#endif
  return text(value, strlen(value));
}
FooResult foo_fs_copy(FooText source, FooText destination) {
  FooResult content = foo_fs_readbytes(source);
  if (content.error)
    return content;
  FooResult written = foo_fs_writebytes(destination, content.text);
  FooResult released = foo_fs_releasebytes(content.text);
  return written.error ? written : released;
}
FooResult foo_fs_working(void) {
  size_t capacity = 256;
  for (;;) {
    char *buffer = malloc(capacity);
    if (!buffer)
      return failure(MEMORY);
#ifdef _WIN32
    char *result = _getcwd(buffer, (int)capacity);
#else
    char *result = getcwd(buffer, capacity);
#endif
    if (result) {
      FooResult value = text(buffer, strlen(buffer));
      free(buffer);
      return value;
    }
    int problem = errno;
    free(buffer);
    if (problem != ERANGE || capacity > SIZE_MAX / 2)
      return failure(problem == ERANGE ? BOUNDS : IO);
    capacity *= 2;
  }
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
FooResult foo_net_handle(void *pointer) {
  if (!resource(pointer, SOCKETS))
    return failure(CLOSED);
  return (FooResult){.number = (uint64_t)((Connection *)pointer)->socket};
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
FooResult foo_net_push(void *pointer, FooText value) {
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
FooResult foo_process_execute(FooText program, FooText items) {
  if (items.len > (SIZE_MAX / sizeof(char *)) - 2)
    return failure(BOUNDS);
  char *name = string(program);
  if (!name)
    return failure(ARGUMENT);
  const FooText *values = (const FooText *)items.data;
  char **vector = calloc(items.len + 2, sizeof(*vector));
  if (!vector) {
    free(name);
    return failure(MEMORY);
  }
  vector[0] = name;
  size_t index = 0;
  for (; index < items.len; index++) {
    vector[index + 1] = string(values[index]);
    if (!vector[index + 1])
      break;
  }
  if (index != items.len) {
    for (size_t item = 0; item <= index; item++)
      free(vector[item]);
    free(vector);
    return failure(ARGUMENT);
  }
#ifdef _WIN32
  intptr_t spawned = _spawnvp(_P_WAIT, name, (const char *const *)vector);
  int status = (int)spawned;
  int problem = spawned < 0 ? errno : 0;
#else
  int channel[2];
  if (pipe(channel) || fcntl(channel[1], F_SETFD, FD_CLOEXEC)) {
    int problem = errno;
    for (size_t item = 0; item <= items.len; item++)
      free(vector[item]);
    free(vector);
    errno = problem;
    return failure(IO);
  }
  pid_t child = fork();
  if (!child) {
    close(channel[0]);
    execvp(name, vector);
    int problem = errno;
    (void)write(channel[1], &problem, sizeof(problem));
    _exit(127);
  }
  close(channel[1]);
  int problem = 0;
  ssize_t reported;
  do {
    reported = read(channel[0], &problem, sizeof(problem));
  } while (reported < 0 && errno == EINTR);
  close(channel[0]);
  int state = 0;
  while (child > 0 && waitpid(child, &state, 0) < 0) {
    if (errno != EINTR) {
      child = -1;
      break;
    }
  }
  int status = child < 0 ? -1 : WIFEXITED(state) ? WEXITSTATUS(state) :
               WIFSIGNALED(state) ? 128 + WTERMSIG(state) : -1;
  if (reported < 0)
    status = -1;
#endif
  for (size_t item = 0; item <= items.len; item++)
    free(vector[item]);
  free(vector);
  return problem ? failure(problem == ENOENT ? MISSING : IO) :
         status < 0 ? failure(IO) :
                      (FooResult){.number = (uint64_t)status};
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
typedef struct ScopedCall {
  void (*callback)(int64_t);
  int64_t argument;
  struct ScopedCall *next;
} ScopedCall;
#if defined(_WIN32) || defined(__linux__)
typedef struct {
  atomic_size_t pending;
  size_t count;
  atomic_int stopping;
#ifdef _WIN32
  HANDLE poll, done, workers[32];
#else
  int poll, wake;
  pthread_t workers[32];
  pthread_mutex_t lock;
  pthread_cond_t done;
  ScopedCall *head, *tail;
#endif
} TaskPool;

static size_t workers(void) {
#ifdef _WIN32
  DWORD available = GetActiveProcessorCount(ALL_PROCESSOR_GROUPS);
#else
  long available = sysconf(_SC_NPROCESSORS_ONLN);
#endif
  if (available < 2)
    return 1;
  return (size_t)(available > 33 ? 32 : available - 1);
}

#ifdef _WIN32
static DWORD WINAPI dispatch(void *pointer) {
  TaskPool *pool = pointer;
  for (;;) {
    DWORD bytes;
    ULONG_PTR key = 0;
    OVERLAPPED *overlap = NULL;
    BOOL ok = GetQueuedCompletionStatus(pool->poll, &bytes, &key, &overlap,
                                        INFINITE);
    (void)bytes;
    (void)overlap;
    if (!ok && !key)
      continue;
    ScopedCall *call = (ScopedCall *)key;
    if (!call)
      break;
    call->callback(call->argument);
    free(call);
    if (atomic_fetch_sub_explicit(&pool->pending, 1, memory_order_acq_rel) == 1)
      SetEvent(pool->done);
  }
  return 0;
}
#else
static void *dispatch(void *pointer) {
  TaskPool *pool = pointer;
  struct epoll_event event;
  for (;;) {
    if (epoll_wait(pool->poll, &event, 1, -1) < 0) {
      if (errno == EINTR)
        continue;
      break;
    }
    uint64_t signal;
    if (read(pool->wake, &signal, sizeof(signal)) != sizeof(signal))
      continue;
    pthread_mutex_lock(&pool->lock);
    ScopedCall *call = pool->head;
    if (call) {
      pool->head = call->next;
      if (!pool->head)
        pool->tail = NULL;
    }
    int stopping = atomic_load_explicit(&pool->stopping, memory_order_acquire);
    pthread_mutex_unlock(&pool->lock);
    if (!call) {
      if (stopping)
        break;
      continue;
    }
    call->callback(call->argument);
    free(call);
    if (atomic_fetch_sub_explicit(&pool->pending, 1, memory_order_acq_rel) == 1) {
      pthread_mutex_lock(&pool->lock);
      pthread_cond_broadcast(&pool->done);
      pthread_mutex_unlock(&pool->lock);
    }
  }
  return NULL;
}
#endif

static void dispose(TaskPool *pool) {
  if (!pool)
    return;
#ifdef _WIN32
  atomic_store_explicit(&pool->stopping, 1, memory_order_release);
  while (atomic_load_explicit(&pool->pending, memory_order_acquire)) {
    ResetEvent(pool->done);
    if (atomic_load_explicit(&pool->pending, memory_order_acquire) &&
        WaitForSingleObject(pool->done, INFINITE) != WAIT_OBJECT_0)
      break;
  }
  for (size_t index = 0; index < pool->count; index++)
    PostQueuedCompletionStatus(pool->poll, 0, 0, NULL);
  for (size_t index = 0; index < pool->count; index++) {
    WaitForSingleObject(pool->workers[index], INFINITE);
    CloseHandle(pool->workers[index]);
  }
  if (pool->done)
    CloseHandle(pool->done);
  if (pool->poll)
    CloseHandle(pool->poll);
#else
  pthread_mutex_lock(&pool->lock);
  atomic_store_explicit(&pool->stopping, 1, memory_order_release);
  while (atomic_load_explicit(&pool->pending, memory_order_acquire))
    pthread_cond_wait(&pool->done, &pool->lock);
  pthread_mutex_unlock(&pool->lock);
  uint64_t signal = pool->count;
  if (pool->wake >= 0)
    (void)write(pool->wake, &signal, sizeof(signal));
  for (size_t index = 0; index < pool->count; index++)
    pthread_join(pool->workers[index], NULL);
  if (pool->wake >= 0)
    close(pool->wake);
  if (pool->poll >= 0)
    close(pool->poll);
  pthread_cond_destroy(&pool->done);
  pthread_mutex_destroy(&pool->lock);
#endif
}

static void abandon(TaskPool *pool) {
  Resource *entry = resource(pool, TASK_POOL);
  if (entry)
    entry->closed = 1;
}
#endif

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
FooResult foo_task_pool(void) {
#if defined(_WIN32) || defined(__linux__)
  TaskPool *pool = owned(sizeof(*pool), TASK_POOL);
  if (!pool)
    return failure(MEMORY);
  atomic_init(&pool->pending, 0);
  atomic_init(&pool->stopping, 0);
  size_t desired = workers();
#ifdef _WIN32
  pool->poll = CreateIoCompletionPort(INVALID_HANDLE_VALUE, NULL, 0, 0);
  pool->done = CreateEventW(NULL, TRUE, TRUE, NULL);
  if (!pool->poll || !pool->done) {
    if (pool->done) CloseHandle(pool->done);
    if (pool->poll) CloseHandle(pool->poll);
    abandon(pool);
    return failure(SYSTEM);
  }
  for (size_t index = 0; index < desired; index++) {
    pool->workers[index] = CreateThread(NULL, 0, dispatch, pool, 0, NULL);
    if (!pool->workers[index]) {
      dispose(pool);
      abandon(pool);
      return failure(SYSTEM);
    }
    pool->count++;
  }
#else
  pool->poll = -1;
  pool->wake = -1;
  pool->poll = epoll_create1(EPOLL_CLOEXEC);
  pool->wake = eventfd(0, EFD_CLOEXEC | EFD_SEMAPHORE);
  if (pool->poll < 0 || pool->wake < 0) {
    if (pool->wake >= 0) close(pool->wake);
    if (pool->poll >= 0) close(pool->poll);
    abandon(pool);
    return failure(SYSTEM);
  }
  if (pthread_mutex_init(&pool->lock, NULL)) {
    close(pool->wake); close(pool->poll); abandon(pool);
    return failure(SYSTEM);
  }
  if (pthread_cond_init(&pool->done, NULL)) {
    pthread_mutex_destroy(&pool->lock);
    close(pool->wake); close(pool->poll); abandon(pool);
    return failure(SYSTEM);
  }
  struct epoll_event event = {.events = EPOLLIN, .data.fd = pool->wake};
  if (epoll_ctl(pool->poll, EPOLL_CTL_ADD, pool->wake, &event)) {
    dispose(pool);
    abandon(pool);
    return failure(SYSTEM);
  }
  for (size_t index = 0; index < desired; index++)
    if (pthread_create(&pool->workers[index], NULL, dispatch, pool)) {
      dispose(pool);
      abandon(pool);
      return failure(SYSTEM);
    } else
      pool->count++;
#endif
  return (FooResult){.pointer = pool};
#else
  return task_scope();
#endif
}
static FooResult task_launch(void *pointer, void (*callback)(int64_t),
                             int64_t argument) {
  TaskScope *scope = resource(pointer, TASK_SCOPE) ? pointer : NULL;
  if (!scope) return failure(CLOSED);
  enter();
  if (scope->count == 128) { leave(); return (FooResult){.number = 0}; }
  leave();
  ScopedCall *call = malloc(sizeof(*call));
  if (!call) return failure(MEMORY);
  *call = (ScopedCall){callback, argument, NULL};
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
#if defined(_WIN32) || defined(__linux__)
  TaskPool *queue = resource(pool, TASK_POOL) ? pool : NULL;
  if (!queue || !callback)
    return failure(CLOSED);
  ScopedCall *call = calloc(1, sizeof(*call));
  if (!call)
    return failure(MEMORY);
  call->callback = callback;
  call->argument = argument;
#ifdef _WIN32
  if (atomic_load_explicit(&queue->stopping, memory_order_acquire)) {
    free(call);
    return failure(CLOSED);
  }
  ResetEvent(queue->done);
  atomic_fetch_add_explicit(&queue->pending, 1, memory_order_release);
  if (!PostQueuedCompletionStatus(queue->poll, 0, (ULONG_PTR)call, NULL)) {
    free(call);
    if (atomic_fetch_sub_explicit(&queue->pending, 1, memory_order_acq_rel) == 1)
      SetEvent(queue->done);
    return failure(SYSTEM);
  }
#else
  pthread_mutex_lock(&queue->lock);
  if (atomic_load_explicit(&queue->stopping, memory_order_acquire)) {
    pthread_mutex_unlock(&queue->lock);
    free(call);
    return failure(CLOSED);
  }
  ScopedCall *previous = queue->tail;
  if (previous)
    previous->next = call;
  else
    queue->head = call;
  queue->tail = call;
  uint64_t signal = 1;
  ssize_t written;
  do {
    written = write(queue->wake, &signal, sizeof(signal));
  } while (written < 0 && errno == EINTR);
  if (written != sizeof(signal)) {
    if (previous)
      previous->next = NULL;
    else
      queue->head = NULL;
    queue->tail = previous;
    pthread_mutex_unlock(&queue->lock);
    free(call);
    return failure(SYSTEM);
  }
  atomic_fetch_add_explicit(&queue->pending, 1, memory_order_release);
  pthread_mutex_unlock(&queue->lock);
#endif
  return (FooResult){.number = 1};
#else
  return task_launch(pool, callback, argument);
#endif
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
FooResult foo_task_wait(void *pool) {
#if defined(_WIN32) || defined(__linux__)
  TaskPool *queue = resource(pool, TASK_POOL) ? pool : NULL;
  if (!queue)
    return failure(CLOSED);
#ifdef _WIN32
  while (atomic_load_explicit(&queue->pending, memory_order_acquire)) {
    ResetEvent(queue->done);
    if (atomic_load_explicit(&queue->pending, memory_order_acquire) &&
        WaitForSingleObject(queue->done, INFINITE) != WAIT_OBJECT_0)
      return failure(SYSTEM);
  }
#else
  pthread_mutex_lock(&queue->lock);
  while (atomic_load_explicit(&queue->pending, memory_order_acquire))
    pthread_cond_wait(&queue->done, &queue->lock);
  pthread_mutex_unlock(&queue->lock);
#endif
  return (FooResult){0};
#else
  return task_join(pool);
#endif
}
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
#ifdef FOO_SERVICE_THREAD
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
#endif
  while (resources) {
    Resource *entry = resources;
    if (!entry->closed) {
#ifdef FOO_SERVICE_FS
      if (entry->kind == FILES)
        foo_io_close(entry->data);
#endif
#ifdef FOO_SERVICE_NET
      if (entry->kind == SOCKETS)
        foo_net_close(entry->data);
#endif
#ifdef FOO_SERVICE_THREAD
      if (entry->kind == MUTEX || entry->kind == CONDITION)
        foo_thread_close(entry->data);
#endif
#ifdef FOO_SERVICE_TASK
#if defined(_WIN32) || defined(__linux__)
      if (entry->kind == TASK_POOL) {
        dispose(entry->data);
        entry->closed = 1;
      }
#endif
#endif
    }
    resources = entry->next;
    if (resources)
      resources->prev = NULL;
    forget(entry);
    free(entry->data);
    free(entry);
  }
  count = 0;
  arguments = NULL;
#ifdef _WIN32
#ifdef FOO_SERVICE_NET
  if (winsock) {
    WSACleanup();
    winsock = 0;
  }
#endif
#endif
}
