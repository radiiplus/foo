#ifndef _WIN32
#define _GNU_SOURCE
#else
#define _CRT_RAND_S
#define _CRT_SECURE_NO_WARNINGS
#endif
#define _POSIX_C_SOURCE 200809L
#include "service.h"
#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <stdatomic.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <time.h>
#if !defined(FOO_SERVICE_SELECTIVE) || defined(FOO_SERVICE_CPU)
#if defined(_MSC_VER) && (defined(_M_X64) || defined(_M_IX86))
#include <intrin.h>
#elif defined(__x86_64__) || defined(__i386__)
#include <cpuid.h>
#endif
#if defined(_M_X64) || defined(_M_IX86) || defined(__x86_64__) || defined(__i386__)
#include <immintrin.h>
#if defined(__clang__) && defined(_MSC_VER) && !defined(__AVX2__)
#include <avxintrin.h>
#include <avx2intrin.h>
#include <smmintrin.h>
#include <avx512fintrin.h>
#endif
#elif defined(__aarch64__)
#include <arm_neon.h>
#endif
#endif
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
#include <winsock2.h>
#include <windows.h>
#include <tlhelp32.h>
#include <ws2tcpip.h>
#include <windns.h>
#include <iphlpapi.h>
typedef SOCKET Socket;
#define INVALID INVALID_SOCKET
#define disconnect closesocket
#define FOO_SHUT_READ SD_RECEIVE
#define FOO_SHUT_WRITE SD_SEND
#define FOO_SHUT_BOTH SD_BOTH
#else
#include <arpa/inet.h>
#include <dirent.h>
#include <ifaddrs.h>
#include <net/if.h>
#include <poll.h>
#include <sys/file.h>
#include <sys/ioctl.h>
#include <sys/statvfs.h>
#include <sys/resource.h>
#include <netdb.h>
#include <arpa/inet.h>
#include <arpa/nameser.h>
#include <resolv.h>
#include <netinet/in.h>
#include <netinet/tcp.h>
#include <pthread.h>
#include <signal.h>
#include <sched.h>
#include <sys/socket.h>
#include <sys/time.h>
#include <sys/mman.h>
#include <sys/wait.h>
#include <unistd.h>
#include <dlfcn.h>
#if defined(__linux__) && defined(__aarch64__)
#include <sys/auxv.h>
#endif
#ifdef __linux__
#include <sys/epoll.h>
#include <sys/eventfd.h>
#include <linux/netlink.h>
#include <linux/rtnetlink.h>
#endif
#ifdef __APPLE__
#include <sys/sysctl.h>
#include <net/route.h>
#endif
typedef int Socket;
#define INVALID (-1)
#define disconnect close
#define FOO_SHUT_READ SHUT_RD
#define FOO_SHUT_WRITE SHUT_WR
#define FOO_SHUT_BOTH SHUT_RDWR
#endif

enum { OK, MEMORY, ARGUMENT, IO, CLOSED, MISSING, SYSTEM, BOUNDS,
       INVALID_ORDER, INVALID_LOAD_ORDER, INVALID_STORE_ORDER };

#if defined(FOO_SERVICE_ARCH) || (!defined(FOO_SERVICE_SELECTIVE) && \
    (defined(_M_X64) || defined(_M_AMD64) || defined(__x86_64__) || \
     defined(__i386__) || defined(__aarch64__) || defined(__riscv)))
typedef FooText FOOText;
#define FOO_ARCH 1
#include "../cpu/arch.h"
FooResult foo_arch_count(uint64_t value) {
  return (FooResult){.number = foo_arch_impl_count(value)};
}
FooResult foo_arch_tally(FooText values) {
  if (values.len > SIZE_MAX / sizeof(uint64_t)) return (FooResult){.error = ARGUMENT};
  return (FooResult){.number = foo_arch_impl_tally(values)};
}
FooResult foo_arch_combine(FooText left, FooText right, FooText output,
                           uint64_t operation) {
  return (FooResult){.number = foo_arch_impl_combine(left, right, output, operation)};
}
FooResult foo_arch_pause(void) {
  foo_arch_impl_pause();
  return (FooResult){0};
}
FooResult foo_arch_ticks(void) {
  return (FooResult){.number = foo_arch_impl_ticks()};
}
FooResult foo_arch_target(FooText feature) {
  return (FooResult){.number = foo_arch_impl_target(feature)};
}
FooResult foo_arch_prefetch(FooText bytes, uint64_t offset) {
  foo_arch_impl_prefetch(bytes, offset);
  return (FooResult){0};
}
FooResult foo_arch_stage(FooText bytes, uint64_t offset) {
  foo_arch_impl_stage(bytes, offset);
  return (FooResult){0};
}
#endif

#if !defined(FOO_SERVICE_SELECTIVE) || defined(FOO_SERVICE_SYSTEM)
FooResult foo_system_cores(void) {
#ifdef _WIN32
  SYSTEM_INFO info;
  GetSystemInfo(&info);
  return info.dwNumberOfProcessors ? (FooResult){.number = info.dwNumberOfProcessors}
                                   : (FooResult){.error = SYSTEM};
#else
  long count = sysconf(_SC_NPROCESSORS_ONLN);
  return count < 1 ? (FooResult){.error = SYSTEM}
                   : (FooResult){.number = (uint64_t)count};
#endif
}
FooResult foo_system_page(void) {
#ifdef _WIN32
  SYSTEM_INFO info;
  GetSystemInfo(&info);
  return info.dwPageSize ? (FooResult){.number = info.dwPageSize}
                         : (FooResult){.error = SYSTEM};
#else
  long size = sysconf(_SC_PAGESIZE);
  return size < 1 ? (FooResult){.error = SYSTEM}
                  : (FooResult){.number = (uint64_t)size};
#endif
}
#endif

enum { TEXT = 1, FILES, SOCKETS, THREADS, MUTEX, CONDITION,
       TASK_EXECUTOR, TASK_CHANNEL, TASK_SCOPE, TASK_POOL, MAPS, DIRS,
       DATAGRAMS, PACKETS, DNS_SETS, ADAPTER_LISTS, ROUTE_LISTS, METADATA,
       WALKS, VIRTUAL_REGIONS,
       RINGS, BLOOMS, DYNAMIC_LIBRARIES, DYNAMIC_SYMBOLS, CHILDREN, TIMERS,
       TLS_CONNECTIONS,
       PLACEMENTS, METERS, SPANS, VULKAN_DEVICES, VULKAN_BUFFERS,
       VULKAN_KERNELS, POLLERS };
enum { FAULT_NONE, FAULT_WRITE, FAULT_SYNC, FAULT_REPLACE };
static _Thread_local int fault_kind;
static _Thread_local uint64_t fault_count;
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
static int supports(FooText feature, const char *name) {
  size_t length = strlen(name);
  return feature.len == length && feature.data &&
         !memcmp(feature.data, name, length);
}
#include "../atomic.c"

#include "../cpu/hosted.c"

FooResult foo_fs_fault(FooText operation, uint64_t count) {
  if (operation.len && !operation.data) return failure(ARGUMENT);
  int kind = operation.len == 5 && !memcmp(operation.data, "write", 5)
      ? FAULT_WRITE : operation.len == 4 && !memcmp(operation.data, "sync", 4)
      ? FAULT_SYNC : operation.len == 7 && !memcmp(operation.data, "replace", 7)
      ? FAULT_REPLACE : FAULT_NONE;
  if (!kind || (kind != FAULT_WRITE && count)) return failure(ARGUMENT);
  fault_kind = kind;
  fault_count = count;
  return (FooResult){0};
}
FooResult foo_fs_clear(void) {
  fault_kind = FAULT_NONE;
  fault_count = 0;
  return (FooResult){0};
}
static int fault(int kind, uint64_t *count) {
  if (fault_kind != kind) return 0;
  if (count) *count = fault_count;
  fault_kind = FAULT_NONE;
  fault_count = 0;
  return 1;
}
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
static FooResult usage(int kind, int bytes) {
  uint64_t total = 0;
  enter();
  for (Resource *entry = resources; entry; entry = entry->next) {
    if (entry->kind != kind || atomic_load_explicit(&entry->closed,
                                                      memory_order_relaxed)) continue;
    uint64_t amount = bytes ? entry->size : 1;
    if (amount > UINT64_MAX - total) { leave(); return failure(BOUNDS); }
    total += amount;
  }
  leave();
  return (FooResult){.number = total};
}
FooResult foo_resource_files(void) { return usage(FILES, 0); }
FooResult foo_resource_mapped(void) { return usage(MAPS, 1); }
FooResult foo_resource_threads(void) { return usage(THREADS, 0); }
static atomic_uint_fast64_t task_work;
static atomic_uint_fast64_t task_queued;
FooResult foo_resource_tasks(void) {
  return (FooResult){.number = atomic_load_explicit(&task_work, memory_order_acquire)};
}
FooResult foo_resource_pending(void) {
  return (FooResult){.number = atomic_load_explicit(&task_queued, memory_order_acquire)};
}
static FooResult text(const void *data, size_t size);
#include "../telemetry.c"

#include "../process/limits.c"

#include "../memory/collections.c"

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

#ifdef FOO_SERVICE_VULKAN
#include "vulkan.c"
#endif
#ifdef FOO_SERVICE_GPU
#include "gpu.c"
#endif
void foo_service_init(int argc, char **argv) {
  count = argc;
  arguments = argv;
}
#include "../codec/text.c"

#include "../files/handles.c"

#include "../memory/virtual.c"

#include "../files/paths.c"


#include "../net/hosted.c"


#include "../dylib.c"

#include "../process/hosted.c"

#include "../time/hosted.c"


#include "../tasks/hosted.c"

void foo_service_close(void) {
#ifdef FOO_SERVICE_TASK
  for (Resource *entry = resources; entry; entry = entry->next) {
    if (entry->closed) continue;
    if (entry->kind == TASK_SCOPE)
      atomic_store_explicit(&((Scope *)entry->data)->cancel->cancelled,
                            1, memory_order_release);
  }
#endif
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
#ifdef FOO_SERVICE_VULKAN
  for (Resource *entry = resources; entry; entry = entry->next)
    if (!entry->closed && entry->kind == VULKAN_KERNELS)
      foo_vulkan_discard(entry->data);
  for (Resource *entry = resources; entry; entry = entry->next)
    if (!entry->closed && entry->kind == VULKAN_BUFFERS)
      foo_vulkan_dispose(entry->data);
  for (Resource *entry = resources; entry; entry = entry->next)
    if (!entry->closed && entry->kind == VULKAN_DEVICES)
      foo_vulkan_close(entry->data);
#endif
  while (resources) {
    Resource *entry = resources;
    if (!entry->closed) {
#ifdef FOO_SERVICE_FS
      if (entry->kind == FILES)
        foo_io_close(entry->data);
      if (entry->kind == MAPS && foo_fs_unmap(entry->data).error) {
        Mapping *mapping = entry->data;
        unmap(mapping);
        mapping->base = NULL;
        mapping->stream = NULL;
        entry->closed = 1;
      }
      if (entry->kind == DIRS)
        foo_fs_finish(entry->data);
      if (entry->kind == WALKS)
        foo_fs_cease(entry->data);
      if (entry->kind == METADATA)
        foo_fs_retire(entry->data);
#endif
      if (entry->kind == VIRTUAL_REGIONS)
        foo_vm_release(entry->data);
      if (entry->kind == RINGS)
        foo_ring_close(entry->data);
      if (entry->kind == BLOOMS)
        foo_bloom_close(entry->data);
      if (entry->kind == DYNAMIC_LIBRARIES)
        foo_dylib_close(entry->data);
      if (entry->kind == CHILDREN)
        foo_process_close(entry->data);
      if (entry->kind == TIMERS)
        foo_timer_close(entry->data);
      if (entry->kind == PLACEMENTS)
        foo_topology_restore(entry->data);
      if (entry->kind == METERS)
        foo_metric_close(entry->data);
      if (entry->kind == SPANS) {
        Span *span = entry->data;
        free(span->name);
        span->name = NULL;
        entry->closed = 1;
      }
#ifdef FOO_SERVICE_NET
      if (entry->kind == TLS_CONNECTIONS)
        foo_tls_close(entry->data);
      if (entry->kind == POLLERS)
        foo_net_cease(entry->data);
      if (entry->kind == SOCKETS)
        foo_net_close(entry->data);
      if (entry->kind == DATAGRAMS)
        foo_net_detach(entry->data);
      if (entry->kind == PACKETS)
        foo_net_discard(entry->data);
      if (entry->kind == DNS_SETS)
        foo_net_forget(entry->data);
      if (entry->kind == ADAPTER_LISTS)
        foo_net_retire(entry->data);
      if (entry->kind == ROUTE_LISTS)
        foo_net_dismiss(entry->data);
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
      if (entry->kind == TASK_SCOPE)
        for (size_t index = 0; index < ((Scope *)entry->data)->count; index++)
          foo_thread_wait(((Scope *)entry->data)->threads[index]);
#endif
#ifdef FOO_SERVICE_VULKAN
      if (entry->kind == VULKAN_KERNELS)
        foo_vulkan_discard(entry->data);
      if (entry->kind == VULKAN_BUFFERS)
        foo_vulkan_dispose(entry->data);
      if (entry->kind == VULKAN_DEVICES)
        foo_vulkan_close(entry->data);
#endif
    }
    resources = entry->next;
    if (resources)
      resources->prev = NULL;
    forget(entry);
#ifdef FOO_SERVICE_TASK
    if (entry->kind == TASK_SCOPE)
      foo_cancel_revoke(((Scope *)entry->data)->cancel);
#if defined(_WIN32) || defined(__linux__)
    if (entry->kind == TASK_POOL)
      foo_cancel_revoke(((Pool *)entry->data)->cancel);
#endif
#endif
    free(entry->data);
    free(entry);
  }
  count = 0;
  arguments = NULL;
  active = NULL;
#ifdef _WIN32
#ifdef FOO_SERVICE_NET
  if (winsock) {
    WSACleanup();
    winsock = 0;
  }
#endif
#endif
}
