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

enum { OK, MEMORY, ARGUMENT, IO, CLOSED, MISSING, SYSTEM, BOUNDS };
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
static int cpu_named(FooText feature, const char *name) {
  size_t length = strlen(name);
  return feature.len == length && feature.data &&
         !memcmp(feature.data, name, length);
}
#if !defined(FOO_SERVICE_SELECTIVE) || defined(FOO_SERVICE_CPU)
#if defined(_M_X64) || defined(_M_IX86) || defined(__x86_64__) || defined(__i386__)
static void cpu_probe(unsigned leaf, unsigned subleaf, unsigned *a,
                      unsigned *b, unsigned *c, unsigned *d) {
#if defined(_MSC_VER)
  int registers[4];
  __cpuidex(registers, (int)leaf, (int)subleaf);
  *a = (unsigned)registers[0]; *b = (unsigned)registers[1];
  *c = (unsigned)registers[2]; *d = (unsigned)registers[3];
#else
  __cpuid_count(leaf, subleaf, *a, *b, *c, *d);
#endif
}
static uint64_t cpu_xcr(void) {
#if defined(_MSC_VER)
  return _xgetbv(0);
#else
  unsigned low, high;
  __asm__ volatile("xgetbv" : "=a"(low), "=d"(high) : "c"(0));
  return ((uint64_t)high << 32) | low;
#endif
}
#endif
FooResult foo_cpu_runtime(FooText feature) {
  if (feature.len && !feature.data) return failure(ARGUMENT);
#if defined(_M_X64) || defined(_M_IX86) || defined(__x86_64__) || defined(__i386__)
  unsigned a = 0, b = 0, c = 0, d = 0;
  cpu_probe(0, 0, &a, &b, &c, &d);
  unsigned maximum = a;
  if (maximum < 1) return (FooResult){0};
  cpu_probe(1, 0, &a, &b, &c, &d);
  if (cpu_named(feature, "sse2")) return (FooResult){.number = !!(d & (1u << 26))};
  int avx = (c & (1u << 27)) && (c & (1u << 28)) &&
            (cpu_xcr() & 0x6) == 0x6;
  if (cpu_named(feature, "fma"))
    return (FooResult){.number = avx && !!(c & (1u << 12))};
  if (maximum < 7) return (FooResult){0};
  cpu_probe(7, 0, &a, &b, &c, &d);
  if (cpu_named(feature, "avx2"))
    return (FooResult){.number = avx && !!(b & (1u << 5))};
  if (cpu_named(feature, "avx512f"))
    return (FooResult){.number = avx && (cpu_xcr() & 0xe6) == 0xe6 &&
                                  !!(b & (1u << 16))};
#elif defined(__aarch64__) || defined(_M_ARM64)
  if (cpu_named(feature, "neon")) return (FooResult){.number = 1};
#if defined(__linux__)
  if (cpu_named(feature, "sve"))
    return (FooResult){.number = !!(getauxval(AT_HWCAP) & (1ul << 22))};
#endif
#endif
  return (FooResult){0};
}
#if defined(_M_X64) || defined(_M_IX86) || defined(__x86_64__) || defined(__i386__)
#if defined(__clang__) || defined(__GNUC__)
#define CPU_SSE __attribute__((target("sse2")))
#define CPU_AVX __attribute__((target("avx2")))
#define CPU_AVX512 __attribute__((target("avx512f")))
#else
#define CPU_SSE
#endif
#if defined(__clang__) || defined(__GNUC__) || defined(_M_X64) || defined(__x86_64__)
static CPU_SSE size_t cpu_sse(const uint8_t *left, const uint8_t *right,
                            uint8_t *output, size_t size) {
  size_t index = 0;
  for (; size - index >= 16; index += 16) {
    __m128i a = _mm_loadu_si128((const __m128i *)(left + index));
    __m128i b = _mm_loadu_si128((const __m128i *)(right + index));
    _mm_storeu_si128((__m128i *)(output + index), _mm_add_epi8(a, b));
  }
  return index;
}
#endif
#if defined(__clang__) || defined(__GNUC__)
static CPU_AVX size_t cpu_avx(const uint8_t *left, const uint8_t *right,
                            uint8_t *output, size_t size) {
  size_t index = 0;
  for (; size - index >= 32; index += 32) {
    __m256i a = _mm256_loadu_si256((const __m256i *)(left + index));
    __m256i b = _mm256_loadu_si256((const __m256i *)(right + index));
    _mm256_storeu_si256((__m256i *)(output + index), _mm256_add_epi8(a, b));
  }
  return index;
}
#endif
#endif
static int cpu_overlap(const uint8_t *a, const uint8_t *b, size_t length) {
  uintptr_t left = (uintptr_t)a, right = (uintptr_t)b;
  return left != right && (left < right ? right - left : left - right) < length;
}
static unsigned cpu_vector_features(void) {
  static atomic_uint cache = 0;
  unsigned features = atomic_load_explicit(&cache, memory_order_relaxed);
  if (features) return features;
  features = 1;
#if defined(_M_X64) || defined(_M_IX86) || defined(__x86_64__) || defined(__i386__)
  if (foo_cpu_runtime((FooText){(const uint8_t *)"sse2", 4}).number)
    features |= 2;
  if (foo_cpu_runtime((FooText){(const uint8_t *)"avx2", 4}).number)
    features |= 4;
  if (foo_cpu_runtime((FooText){(const uint8_t *)"avx512f", 7}).number)
    features |= 8;
#elif defined(__aarch64__)
  features |= 16;
#endif
  atomic_store_explicit(&cache, features, memory_order_relaxed);
  return features;
}
FooResult foo_cpu_add(FooText left, FooText right, FooText output) {
  if (left.len != right.len || left.len != output.len ||
      (left.len && (!left.data || !right.data || !output.data)) ||
      cpu_overlap(output.data, left.data, output.len) ||
      cpu_overlap(output.data, right.data, output.len)) return failure(ARGUMENT);
  if (!output.len) return (FooResult){0};
  uint8_t *destination = (uint8_t *)output.data;
  size_t index = 0;
#if (defined(__clang__) || defined(__GNUC__)) && \
    (defined(_M_X64) || defined(_M_IX86) || defined(__x86_64__) || defined(__i386__))
  if (foo_cpu_runtime((FooText){(const uint8_t *)"avx2", 4}).number)
    index = cpu_avx(left.data, right.data, destination, output.len);
#endif
#if defined(_M_X64) || defined(_M_IX86) || defined(__x86_64__) || defined(__i386__)
#if defined(__clang__) || defined(__GNUC__) || defined(_M_X64) || defined(__x86_64__)
  if (foo_cpu_runtime((FooText){(const uint8_t *)"sse2", 4}).number)
    index += cpu_sse(left.data + index, right.data + index,
                     destination + index, output.len - index);
#endif
#elif defined(__aarch64__)
  for (; output.len - index >= 16; index += 16) {
    uint8x16_t a = vld1q_u8(left.data + index);
    uint8x16_t b = vld1q_u8(right.data + index);
    vst1q_u8(destination + index, vaddq_u8(a, b));
  }
#endif
  for (; index < output.len; index++)
    destination[index] = (uint8_t)(left.data[index] + right.data[index]);
  return (FooResult){0};
}
#if defined(_M_X64) || defined(_M_IX86) || defined(__x86_64__) || defined(__i386__)
#if defined(__clang__) || defined(__GNUC__)
#if !defined(FOO_DISABLE_AVX512)
static CPU_AVX512 size_t cpu_avx512f32(const float *left,
                                      const float *right, float *output,
                                      size_t count, uint64_t operation) {
  size_t index = 0;
  for (; count - index >= 16; index += 16) {
    __m512 a = _mm512_loadu_ps(left + index);
    __m512 b = _mm512_loadu_ps(right + index);
    __m512 value = operation == 0 ? _mm512_add_ps(a, b) :
        operation == 1 ? _mm512_sub_ps(a, b) :
        operation == 2 ? _mm512_mul_ps(a, b) : _mm512_div_ps(a, b);
    _mm512_storeu_ps(output + index, value);
  }
  return index;
}
static CPU_AVX512 size_t cpu_avx512f64(const double *left,
                                      const double *right, double *output,
                                      size_t count, uint64_t operation) {
  size_t index = 0;
  for (; count - index >= 8; index += 8) {
    __m512d a = _mm512_loadu_pd(left + index);
    __m512d b = _mm512_loadu_pd(right + index);
    __m512d value = operation == 0 ? _mm512_add_pd(a, b) :
        operation == 1 ? _mm512_sub_pd(a, b) :
        operation == 2 ? _mm512_mul_pd(a, b) : _mm512_div_pd(a, b);
    _mm512_storeu_pd(output + index, value);
  }
  return index;
}
#endif
static CPU_AVX size_t cpu_avxf32(const float *left, const float *right,
                               float *output, size_t count, uint64_t operation) {
  size_t index = 0;
  for (; count - index >= 8; index += 8) {
    __m256 a = _mm256_loadu_ps(left + index);
    __m256 b = _mm256_loadu_ps(right + index);
    __m256 value = operation == 0 ? _mm256_add_ps(a, b) :
        operation == 1 ? _mm256_sub_ps(a, b) :
        operation == 2 ? _mm256_mul_ps(a, b) : _mm256_div_ps(a, b);
    _mm256_storeu_ps(output + index, value);
  }
  return index;
}
static CPU_AVX size_t cpu_avxf64(const double *left, const double *right,
                               double *output, size_t count, uint64_t operation) {
  size_t index = 0;
  for (; count - index >= 4; index += 4) {
    __m256d a = _mm256_loadu_pd(left + index);
    __m256d b = _mm256_loadu_pd(right + index);
    __m256d value = operation == 0 ? _mm256_add_pd(a, b) :
        operation == 1 ? _mm256_sub_pd(a, b) :
        operation == 2 ? _mm256_mul_pd(a, b) : _mm256_div_pd(a, b);
    _mm256_storeu_pd(output + index, value);
  }
  return index;
}
#endif
#if defined(__clang__) || defined(__GNUC__) || defined(_M_X64) || defined(__x86_64__)
static CPU_SSE size_t cpu_ssef32(const float *left, const float *right,
                               float *output, size_t count, uint64_t operation) {
  size_t index = 0;
  for (; count - index >= 4; index += 4) {
    __m128 a = _mm_loadu_ps(left + index);
    __m128 b = _mm_loadu_ps(right + index);
    __m128 value = operation == 0 ? _mm_add_ps(a, b) :
        operation == 1 ? _mm_sub_ps(a, b) :
        operation == 2 ? _mm_mul_ps(a, b) : _mm_div_ps(a, b);
    _mm_storeu_ps(output + index, value);
  }
  return index;
}
static CPU_SSE size_t cpu_ssef64(const double *left, const double *right,
                               double *output, size_t count, uint64_t operation) {
  size_t index = 0;
  for (; count - index >= 2; index += 2) {
    __m128d a = _mm_loadu_pd(left + index);
    __m128d b = _mm_loadu_pd(right + index);
    __m128d value = operation == 0 ? _mm_add_pd(a, b) :
        operation == 1 ? _mm_sub_pd(a, b) :
        operation == 2 ? _mm_mul_pd(a, b) : _mm_div_pd(a, b);
    _mm_storeu_pd(output + index, value);
  }
  return index;
}
#endif
#endif
#define CPU_MAP(NAME, TARGET, LANES, SCALAR, VECTOR, LOAD, STORE, SPLAT, ADD, SUB, MUL, DIV) \
static TARGET size_t cpu_map_##NAME(const SCALAR *left, const SCALAR *right, \
    SCALAR *output, size_t count, uint64_t operation, uint64_t flags, \
    SCALAR first, SCALAR second, uint64_t follow, SCALAR post) { \
  size_t position = 0; \
  for (; count - position >= LANES; position += LANES) { \
    VECTOR a = (flags & 1) ? SPLAT(first) : LOAD(left + position); \
    VECTOR b = (flags & 2) ? SPLAT(second) : LOAD(right + position); \
    VECTOR value = operation == 4 ? a : \
        operation == 0 ? ADD(a, b) : operation == 1 ? SUB(a, b) : \
        operation == 2 ? MUL(a, b) : DIV(a, b); \
    if (follow != 4) { \
      VECTOR extra = SPLAT(post); \
      value = follow == 0 ? ADD(value, extra) : \
          follow == 1 ? ((flags & 4) ? SUB(extra, value) : SUB(value, extra)) : \
          follow == 2 ? MUL(value, extra) : \
          (flags & 4) ? DIV(extra, value) : DIV(value, extra); \
    } \
    STORE(output + position, value); \
  } \
  return position; \
}
#if defined(_M_X64) || defined(_M_IX86) || defined(__x86_64__) || defined(__i386__)
#if defined(__clang__) || defined(__GNUC__)
#if !defined(FOO_DISABLE_AVX512)
CPU_MAP(avx512f32, CPU_AVX512, 16, float, __m512, _mm512_loadu_ps,
  _mm512_storeu_ps, _mm512_set1_ps, _mm512_add_ps, _mm512_sub_ps,
  _mm512_mul_ps, _mm512_div_ps)
CPU_MAP(avx512f64, CPU_AVX512, 8, double, __m512d, _mm512_loadu_pd,
  _mm512_storeu_pd, _mm512_set1_pd, _mm512_add_pd, _mm512_sub_pd,
  _mm512_mul_pd, _mm512_div_pd)
#endif
CPU_MAP(avxf32, CPU_AVX, 8, float, __m256, _mm256_loadu_ps,
  _mm256_storeu_ps, _mm256_set1_ps, _mm256_add_ps, _mm256_sub_ps,
  _mm256_mul_ps, _mm256_div_ps)
CPU_MAP(avxf64, CPU_AVX, 4, double, __m256d, _mm256_loadu_pd,
  _mm256_storeu_pd, _mm256_set1_pd, _mm256_add_pd, _mm256_sub_pd,
  _mm256_mul_pd, _mm256_div_pd)
#endif
#if defined(__clang__) || defined(__GNUC__) || defined(_M_X64) || defined(__x86_64__)
CPU_MAP(ssef32, CPU_SSE, 4, float, __m128, _mm_loadu_ps,
  _mm_storeu_ps, _mm_set1_ps, _mm_add_ps, _mm_sub_ps,
  _mm_mul_ps, _mm_div_ps)
CPU_MAP(ssef64, CPU_SSE, 2, double, __m128d, _mm_loadu_pd,
  _mm_storeu_pd, _mm_set1_pd, _mm_add_pd, _mm_sub_pd,
  _mm_mul_pd, _mm_div_pd)
#endif
#elif defined(__aarch64__)
CPU_MAP(neonf32, , 4, float, float32x4_t, vld1q_f32,
  vst1q_f32, vdupq_n_f32, vaddq_f32, vsubq_f32,
  vmulq_f32, vdivq_f32)
CPU_MAP(neonf64, , 2, double, float64x2_t, vld1q_f64,
  vst1q_f64, vdupq_n_f64, vaddq_f64, vsubq_f64,
  vmulq_f64, vdivq_f64)
#endif
#undef CPU_MAP
FooResult foo_cpu_vectorize(FooText left, FooText right, FooText output,
                            uint64_t count, uint64_t width, uint64_t operation,
                            uint64_t start, uint64_t flags, double first,
                            double second, uint64_t post_operation, double post,
                            uint64_t *index) {
  if (!index || *index != start || count == UINT64_MAX || start >= count ||
      count - start < 32 || operation > 4 || post_operation > 4 ||
      flags > 7 || (width != 32 && width != 64) ||
      (!(flags & 1) && count > left.len) ||
      (!(flags & 2) && operation != 4 && count > right.len) ||
      count > output.len ||
      count > SIZE_MAX / (width / 8)) return (FooResult){0};
  size_t stride = (size_t)(width / 8);
  size_t length = ((size_t)count - (size_t)start) * stride;
  size_t offset = (size_t)start * stride;
  if (!output.data ||
      (!(flags & 1) && (!left.data ||
        cpu_overlap(output.data + offset, left.data + offset, length))) ||
      (!(flags & 2) && operation != 4 && (!right.data ||
        cpu_overlap(output.data + offset, right.data + offset, length))))
    return (FooResult){0};
  size_t cursor = (size_t)start;
  int direct = flags == 0 && operation < 4 && post_operation == 4;
  unsigned features = cpu_vector_features();
#if (defined(__clang__) || defined(__GNUC__)) && \
    (defined(_M_X64) || defined(_M_IX86) || defined(__x86_64__) || defined(__i386__))
#if !defined(FOO_DISABLE_AVX512)
  if (count - cursor >= 256 && (features & 8))
    cursor += width == 32
        ? (direct ? cpu_avx512f32((const float *)left.data + cursor,
                       (const float *)right.data + cursor,
                       (float *)output.data + cursor, (size_t)count - cursor,
                       operation)
            : cpu_map_avx512f32((const float *)left.data + cursor,
                       (const float *)right.data + cursor,
                       (float *)output.data + cursor, (size_t)count - cursor,
                       operation, flags, (float)first, (float)second,
                       post_operation, (float)post))
        : (direct ? cpu_avx512f64((const double *)left.data + cursor,
                       (const double *)right.data + cursor,
                       (double *)output.data + cursor, (size_t)count - cursor,
                       operation)
            : cpu_map_avx512f64((const double *)left.data + cursor,
                       (const double *)right.data + cursor,
                       (double *)output.data + cursor, (size_t)count - cursor,
                       operation, flags, first, second, post_operation, post));
#endif
  if (features & 4)
    cursor += width == 32
        ? (direct ? cpu_avxf32((const float *)left.data + cursor,
                     (const float *)right.data + cursor,
                     (float *)output.data + cursor, (size_t)count - cursor,
                     operation)
            : cpu_map_avxf32((const float *)left.data + cursor,
                     (const float *)right.data + cursor,
                     (float *)output.data + cursor, (size_t)count - cursor,
                     operation, flags, (float)first, (float)second,
                     post_operation, (float)post))
        : (direct ? cpu_avxf64((const double *)left.data + cursor,
                     (const double *)right.data + cursor,
                     (double *)output.data + cursor, (size_t)count - cursor,
                     operation)
            : cpu_map_avxf64((const double *)left.data + cursor,
                     (const double *)right.data + cursor,
                     (double *)output.data + cursor, (size_t)count - cursor,
                     operation, flags, first, second, post_operation, post));
#endif
#if defined(_M_X64) || defined(_M_IX86) || defined(__x86_64__) || defined(__i386__)
#if defined(__clang__) || defined(__GNUC__) || defined(_M_X64) || defined(__x86_64__)
  if (features & 2)
    cursor += width == 32
        ? (direct ? cpu_ssef32((const float *)left.data + cursor,
                     (const float *)right.data + cursor,
                     (float *)output.data + cursor, (size_t)count - cursor,
                     operation)
            : cpu_map_ssef32((const float *)left.data + cursor,
                     (const float *)right.data + cursor,
                     (float *)output.data + cursor, (size_t)count - cursor,
                     operation, flags, (float)first, (float)second,
                     post_operation, (float)post))
        : (direct ? cpu_ssef64((const double *)left.data + cursor,
                     (const double *)right.data + cursor,
                     (double *)output.data + cursor, (size_t)count - cursor,
                     operation)
            : cpu_map_ssef64((const double *)left.data + cursor,
                     (const double *)right.data + cursor,
                     (double *)output.data + cursor, (size_t)count - cursor,
                     operation, flags, first, second, post_operation, post));
#endif
#elif defined(__aarch64__)
  if (features & 16)
    cursor += width == 32
        ? cpu_map_neonf32((const float *)left.data + cursor,
            (const float *)right.data + cursor,
            (float *)output.data + cursor, (size_t)count - cursor,
            operation, flags, (float)first, (float)second,
            post_operation, (float)post)
        : cpu_map_neonf64((const double *)left.data + cursor,
            (const double *)right.data + cursor,
            (double *)output.data + cursor, (size_t)count - cursor,
            operation, flags, first, second, post_operation, post);
#endif
  if (cursor == start) return (FooResult){0};
  if (width == 32) {
    const float *a = (const float *)left.data, *b = (const float *)right.data;
    float *destination = (float *)output.data;
    for (; cursor < count; cursor++) {
      float x = (flags & 1) ? (float)first : a[cursor];
      float y = (flags & 2) ? (float)second : b[cursor];
      float value = operation == 4 ? x :
          operation == 0 ? x + y : operation == 1 ? x - y :
          operation == 2 ? x * y : x / y;
      if (post_operation != 4) {
        float next = (float)post;
        value = post_operation == 0 ? value + next :
            post_operation == 1 ? ((flags & 4) ? next - value : value - next) :
            post_operation == 2 ? value * next :
            (flags & 4) ? next / value : value / next;
      }
      destination[cursor] = value;
    }
  } else {
    const double *a = (const double *)left.data, *b = (const double *)right.data;
    double *destination = (double *)output.data;
    for (; cursor < count; cursor++) {
      double x = (flags & 1) ? first : a[cursor];
      double y = (flags & 2) ? second : b[cursor];
      double value = operation == 4 ? x :
          operation == 0 ? x + y : operation == 1 ? x - y :
          operation == 2 ? x * y : x / y;
      if (post_operation != 4)
        value = post_operation == 0 ? value + post :
            post_operation == 1 ? ((flags & 4) ? post - value : value - post) :
            post_operation == 2 ? value * post :
            (flags & 4) ? post / value : value / post;
      destination[cursor] = value;
    }
  }
  *index = count;
  return (FooResult){.number = 1};
}
#endif
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
static int take_fault(int kind, uint64_t *count) {
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
typedef struct {
  char *name;
  size_t length, size;
  uint64_t *bounds, *buckets;
  uint64_t value, count, sum;
  int kind;
} Meter;
FooResult foo_metric_create(FooText name, FooText kind, FooText bounds) {
  int type = cpu_named(kind, "counter") ? 1 : cpu_named(kind, "gauge") ? 2 :
             cpu_named(kind, "histogram") ? 3 : 0;
  if (!type || !name.data || !name.len || name.len > 255 ||
      (bounds.len && !bounds.data) || bounds.len > 64 ||
      (type != 3 && bounds.len)) return failure(ARGUMENT);
  for (size_t index = 1; index < bounds.len; index++) {
    uint64_t current, previous;
    memcpy(&current, bounds.data + index * sizeof(current), sizeof(current));
    memcpy(&previous, bounds.data + (index - 1) * sizeof(previous),
           sizeof(previous));
    if (current <= previous) return failure(ARGUMENT);
  }
  char *label = malloc(name.len + 1);
  uint64_t *values = type == 3 ? calloc(bounds.len + 1, sizeof(*values)) : NULL;
  uint64_t *edges = type == 3 && bounds.len
      ? malloc(bounds.len * sizeof(*edges)) : NULL;
  if (!label || (type == 3 && !values) || (type == 3 && bounds.len && !edges)) {
    free(label); free(values); free(edges);
    return failure(MEMORY);
  }
  memcpy(label, name.data, name.len);
  label[name.len] = 0;
  if (edges) memcpy(edges, bounds.data, bounds.len * sizeof(*edges));
  Meter *meter = owned(sizeof(*meter), METERS);
  if (!meter) { free(label); free(values); free(edges); return failure(MEMORY); }
  meter->name = label;
  meter->length = name.len;
  meter->kind = type;
  meter->size = bounds.len;
  meter->bounds = edges;
  meter->buckets = values;
  return (FooResult){.pointer = meter};
}
static FooResult meter_update(void *pointer, uint64_t amount, int action) {
  Resource *entry = resource(pointer, METERS);
  if (!entry) return failure(CLOSED);
  enter();
  if (entry->closed) { leave(); return failure(CLOSED); }
  Meter *meter = pointer;
  if ((action == 1 && meter->kind == 3) ||
      (action == 2 && meter->kind != 2) ||
      (action == 3 && meter->kind != 3)) { leave(); return failure(ARGUMENT); }
  if (action == 1) {
    if (amount > UINT64_MAX - meter->value) { leave(); return failure(BOUNDS); }
    meter->value += amount;
  } else if (action == 2) meter->value = amount;
  else {
    if (meter->count == UINT64_MAX || amount > UINT64_MAX - meter->sum) {
      leave(); return failure(BOUNDS);
    }
    size_t index = 0;
    while (index < meter->size && amount > meter->bounds[index]) index++;
    meter->buckets[index]++;
    meter->count++;
    meter->sum += amount;
  }
  leave();
  return (FooResult){0};
}
FooResult foo_metric_add(void *pointer, uint64_t amount) {
  return meter_update(pointer, amount, 1);
}
FooResult foo_metric_set(void *pointer, uint64_t amount) {
  return meter_update(pointer, amount, 2);
}
FooResult foo_metric_observe(void *pointer, uint64_t amount) {
  return meter_update(pointer, amount, 3);
}
static FooResult meter_read(void *pointer, uint64_t index, int field) {
  Resource *entry = resource(pointer, METERS);
  if (!entry) return failure(CLOSED);
  enter();
  if (entry->closed) { leave(); return failure(CLOSED); }
  Meter *meter = pointer;
  if ((field == 1 && meter->kind == 3) ||
      (field != 1 && meter->kind != 3) ||
      (field == 4 && index > meter->size)) {
    leave(); return failure(field == 4 && meter->kind == 3 ? BOUNDS : ARGUMENT);
  }
  uint64_t result = field == 1 ? meter->value : field == 2 ? meter->count :
                    field == 3 ? meter->sum : meter->buckets[index];
  leave();
  return (FooResult){.number = result};
}
FooResult foo_metric_value(void *pointer) { return meter_read(pointer, 0, 1); }
FooResult foo_metric_count(void *pointer) { return meter_read(pointer, 0, 2); }
FooResult foo_metric_sum(void *pointer) { return meter_read(pointer, 0, 3); }
FooResult foo_metric_bucket(void *pointer, uint64_t index) {
  return meter_read(pointer, index, 4);
}
FooResult foo_metric_name(void *pointer) {
  Resource *entry = resource(pointer, METERS);
  if (!entry) return failure(CLOSED);
  char label[256];
  enter();
  if (entry->closed) { leave(); return failure(CLOSED); }
  Meter *meter = pointer;
  size_t length = meter->length;
  memcpy(label, meter->name, length);
  leave();
  return text(label, length);
}
static bool metric_append(char *output, size_t *used, const char *part) {
  size_t length = strlen(part);
  if (length >= 8192 - *used) return false;
  memcpy(output + *used, part, length);
  *used += length;
  return true;
}
static bool metric_number(char *output, size_t *used, uint64_t value) {
  int length = snprintf(output + *used, 8192 - *used, "%llu",
                        (unsigned long long)value);
  if (length < 0 || (size_t)length >= 8192 - *used) return false;
  *used += (size_t)length;
  return true;
}
FooResult foo_metric_export(void *pointer) {
  Resource *entry = resource(pointer, METERS);
  if (!entry) return failure(CLOSED);
  char output[8192];
  size_t used = 0;
  static const char hex[] = "0123456789abcdef";
  bool valid = true;
  enter();
  if (entry->closed) { leave(); return failure(CLOSED); }
  Meter *meter = pointer;
  valid = metric_append(output, &used, "{\"name\":\"");
  for (size_t index = 0; valid && index < meter->length; index++) {
    unsigned char letter = (unsigned char)meter->name[index];
    if (letter == '"' || letter == '\\') {
      if (used > sizeof(output) - 2) { valid = false; break; }
      output[used++] = '\\';
      output[used++] = (char)letter;
    } else if (letter < 32) {
      if (used > sizeof(output) - 6) { valid = false; break; }
      output[used++] = '\\'; output[used++] = 'u';
      output[used++] = '0'; output[used++] = '0';
      output[used++] = hex[letter >> 4];
      output[used++] = hex[letter & 15];
    } else {
      if (used == sizeof(output)) { valid = false; break; }
      output[used++] = (char)letter;
    }
  }
  if (valid) valid = metric_append(output, &used,
      meter->kind == 1 ? "\",\"kind\":\"counter\",\"value\":" :
      meter->kind == 2 ? "\",\"kind\":\"gauge\",\"value\":" :
                         "\",\"kind\":\"histogram\",\"count\":");
  if (valid) valid = metric_number(output, &used,
      meter->kind == 3 ? meter->count : meter->value);
  if (valid && meter->kind == 3)
    valid = metric_append(output, &used, ",\"sum\":") &&
            metric_number(output, &used, meter->sum) &&
            metric_append(output, &used, ",\"bounds\":[");
  for (size_t index = 0; valid && meter->kind == 3 && index < meter->size; index++)
    valid = (index == 0 || metric_append(output, &used, ",")) &&
            metric_number(output, &used, meter->bounds[index]);
  if (valid && meter->kind == 3)
    valid = metric_append(output, &used, "],\"buckets\":[");
  for (size_t index = 0; valid && meter->kind == 3 && index <= meter->size; index++)
    valid = (index == 0 || metric_append(output, &used, ",")) &&
            metric_number(output, &used, meter->buckets[index]);
  if (valid && meter->kind == 3) valid = metric_append(output, &used, "]");
  if (valid) valid = metric_append(output, &used, "}");
  leave();
  return valid ? text(output, used) : failure(BOUNDS);
}
FooResult foo_metric_close(void *pointer) {
  Resource *entry = resource(pointer, METERS);
  if (!entry) return failure(CLOSED);
  enter();
  if (entry->closed) { leave(); return failure(CLOSED); }
  Meter *meter = pointer;
  free(meter->name); free(meter->bounds); free(meter->buckets);
  meter->name = NULL; meter->bounds = meter->buckets = NULL;
  atomic_store_explicit(&entry->closed, 1, memory_order_release);
  leave();
  return (FooResult){0};
}
typedef struct Span {
  char *name;
  size_t length;
  uint64_t id, parent, start, elapsed;
  struct Span *previous;
#ifdef _WIN32
  DWORD thread;
#else
  pthread_t thread;
#endif
  int finished;
} Span;
static _Thread_local Span *active_span;
static atomic_uint_fast64_t span_count;
static int span_owner(Span *span) {
#ifdef _WIN32
  return span->thread == GetCurrentThreadId();
#else
  return pthread_equal(span->thread, pthread_self());
#endif
}
FooResult foo_trace_begin(FooText name) {
  if (!name.data || !name.len || name.len > 255) return failure(ARGUMENT);
  FooResult now = foo_time_current();
  if (now.error) return now;
  char *label = malloc(name.len + 1);
  if (!label) return failure(MEMORY);
  memcpy(label, name.data, name.len);
  label[name.len] = 0;
  Span *span = owned(sizeof(*span), SPANS);
  if (!span) { free(label); return failure(MEMORY); }
  span->name = label;
  span->length = name.len;
  span->start = now.number;
#ifdef _WIN32
  span->thread = GetCurrentThreadId();
#else
  span->thread = pthread_self();
#endif
  span->previous = active_span;
  span->parent = active_span ? active_span->id : 0;
  span->id = atomic_fetch_add_explicit(&span_count, 1, memory_order_relaxed) + 1;
  active_span = span;
  return (FooResult){.pointer = span};
}
FooResult foo_trace_current(void) {
  return (FooResult){.number = active_span ? active_span->id : 0};
}
FooResult foo_trace_identity(void *pointer) {
  if (!resource(pointer, SPANS)) return failure(CLOSED);
  Span *span = pointer;
  return span_owner(span) ? (FooResult){.number = span->id} : failure(ARGUMENT);
}
FooResult foo_trace_parent(void *pointer) {
  if (!resource(pointer, SPANS)) return failure(CLOSED);
  Span *span = pointer;
  return span_owner(span) ? (FooResult){.number = span->parent} : failure(ARGUMENT);
}
FooResult foo_trace_name(void *pointer) {
  if (!resource(pointer, SPANS)) return failure(CLOSED);
  Span *span = pointer;
  if (!span_owner(span)) return failure(ARGUMENT);
  return text(span->name, span->length);
}
FooResult foo_trace_finish(void *pointer) {
  if (!resource(pointer, SPANS)) return failure(CLOSED);
  Span *span = pointer;
  if (!span_owner(span) || active_span != span || span->finished)
    return failure(ARGUMENT);
  FooResult now = foo_time_current();
  if (now.error) return now;
  if (now.number < span->start) return failure(SYSTEM);
  span->elapsed = now.number - span->start;
  span->finished = 1;
  active_span = span->previous;
  return (FooResult){.number = span->elapsed};
}
FooResult foo_trace_elapsed(void *pointer) {
  if (!resource(pointer, SPANS)) return failure(CLOSED);
  Span *span = pointer;
  if (!span_owner(span)) return failure(ARGUMENT);
  if (!span->finished) return failure(ARGUMENT);
  return (FooResult){.number = span->elapsed};
}
FooResult foo_trace_close(void *pointer) {
  Resource *entry = resource(pointer, SPANS);
  if (!entry) return failure(CLOSED);
  Span *span = pointer;
  if (!span_owner(span) || !span->finished) return failure(ARGUMENT);
  free(span->name);
  span->name = NULL;
  atomic_store_explicit(&entry->closed, 1, memory_order_release);
  return (FooResult){0};
}
static int limit_kind(FooText kind) {
  if (cpu_named(kind, "files")) return 1;
  if (cpu_named(kind, "address")) return 2;
  if (cpu_named(kind, "cpu")) return 3;
  if (cpu_named(kind, "stack")) return 4;
  return 0;
}
#ifndef _WIN32
static int limit_native(int kind) {
  switch (kind) {
    case 1: return RLIMIT_NOFILE;
#ifdef RLIMIT_AS
    case 2: return RLIMIT_AS;
#endif
    case 3: return RLIMIT_CPU;
    case 4: return RLIMIT_STACK;
    default: return -1;
  }
}
#endif
FooResult foo_limit_available(FooText kind) {
  int selected = limit_kind(kind);
  if (!selected) return (FooResult){0};
#ifdef _WIN32
  return (FooResult){0};
#else
  int native = limit_native(selected);
  struct rlimit bounds;
  return (FooResult){.number = native >= 0 && !getrlimit(native, &bounds)};
#endif
}
static FooResult limit_read(FooText kind, int hard) {
  int selected = limit_kind(kind);
  if (!selected) return failure(ARGUMENT);
#ifdef _WIN32
  return failure(MISSING);
#else
  int native = limit_native(selected);
  struct rlimit bounds;
  if (native < 0) return failure(MISSING);
  if (getrlimit(native, &bounds)) return failure(SYSTEM);
  rlim_t result = hard ? bounds.rlim_max : bounds.rlim_cur;
  return (FooResult){.number = result == RLIM_INFINITY
      ? UINT64_MAX : (uint64_t)result};
#endif
}
FooResult foo_limit_soft(FooText kind) { return limit_read(kind, 0); }
FooResult foo_limit_hard(FooText kind) { return limit_read(kind, 1); }
FooResult foo_limit_set(FooText kind, uint64_t value) {
  int selected = limit_kind(kind);
  if (!selected) return failure(ARGUMENT);
#ifdef _WIN32
  return failure(MISSING);
#else
  int native = limit_native(selected);
  struct rlimit bounds;
  if (native < 0) return failure(MISSING);
  if (getrlimit(native, &bounds)) return failure(SYSTEM);
  rlim_t desired = value == UINT64_MAX ? RLIM_INFINITY : (rlim_t)value;
  if (value != UINT64_MAX && (uint64_t)desired != value)
    return failure(BOUNDS);
  bounds.rlim_cur = desired;
  return setrlimit(native, &bounds) ? failure(SYSTEM) : (FooResult){0};
#endif
}
typedef struct {
  size_t capacity, head, tail, count;
  uint8_t *bytes;
} ByteRing;
FooResult foo_ring_create(uint64_t capacity) {
  if (!capacity || capacity > SIZE_MAX) return failure(ARGUMENT);
  uint8_t *bytes = malloc((size_t)capacity);
  if (!bytes) return failure(MEMORY);
  ByteRing *ring = owned(sizeof(*ring), RINGS);
  if (!ring) { free(bytes); return failure(MEMORY); }
  ring->capacity = (size_t)capacity;
  ring->bytes = bytes;
  return (FooResult){.pointer = ring};
}
FooResult foo_ring_push(void *pointer, uint8_t item) {
  Resource *entry = resource(pointer, RINGS);
  if (!entry) return failure(CLOSED);
  enter();
  if (entry->closed) { leave(); return failure(CLOSED); }
  ByteRing *ring = pointer;
  if (ring->count == ring->capacity) { leave(); return (FooResult){0}; }
  ring->bytes[ring->tail] = item;
  if (++ring->tail == ring->capacity) ring->tail = 0;
  ring->count++;
  leave();
  return (FooResult){.number = 1};
}
FooResult foo_ring_prepend(void *pointer, uint8_t item) {
  Resource *entry = resource(pointer, RINGS);
  if (!entry) return failure(CLOSED);
  enter();
  if (entry->closed) { leave(); return failure(CLOSED); }
  ByteRing *ring = pointer;
  if (ring->count == ring->capacity) { leave(); return (FooResult){0}; }
  ring->head = ring->head ? ring->head - 1 : ring->capacity - 1;
  ring->bytes[ring->head] = item;
  ring->count++;
  leave();
  return (FooResult){.number = 1};
}
FooResult foo_ring_pop(void *pointer) {
  Resource *entry = resource(pointer, RINGS);
  if (!entry) return failure(CLOSED);
  enter();
  if (entry->closed) { leave(); return failure(CLOSED); }
  ByteRing *ring = pointer;
  if (!ring->count) { leave(); return failure(MISSING); }
  uint8_t value = ring->bytes[ring->head];
  if (++ring->head == ring->capacity) ring->head = 0;
  ring->count--;
  leave();
  return (FooResult){.number = value};
}
FooResult foo_ring_remove(void *pointer) {
  Resource *entry = resource(pointer, RINGS);
  if (!entry) return failure(CLOSED);
  enter();
  if (entry->closed) { leave(); return failure(CLOSED); }
  ByteRing *ring = pointer;
  if (!ring->count) { leave(); return failure(MISSING); }
  ring->tail = ring->tail ? ring->tail - 1 : ring->capacity - 1;
  uint8_t value = ring->bytes[ring->tail];
  ring->count--;
  leave();
  return (FooResult){.number = value};
}
FooResult foo_ring_first(void *pointer) {
  Resource *entry = resource(pointer, RINGS);
  if (!entry) return failure(CLOSED);
  enter();
  if (entry->closed) { leave(); return failure(CLOSED); }
  ByteRing *ring = pointer;
  if (!ring->count) { leave(); return failure(MISSING); }
  uint8_t value = ring->bytes[ring->head];
  leave();
  return (FooResult){.number = value};
}
FooResult foo_ring_last(void *pointer) {
  Resource *entry = resource(pointer, RINGS);
  if (!entry) return failure(CLOSED);
  enter();
  if (entry->closed) { leave(); return failure(CLOSED); }
  ByteRing *ring = pointer;
  if (!ring->count) { leave(); return failure(MISSING); }
  size_t index = ring->tail ? ring->tail - 1 : ring->capacity - 1;
  uint8_t value = ring->bytes[index];
  leave();
  return (FooResult){.number = value};
}
FooResult foo_ring_length(void *pointer) {
  Resource *entry = resource(pointer, RINGS);
  if (!entry) return failure(CLOSED);
  enter();
  if (entry->closed) { leave(); return failure(CLOSED); }
  uint64_t count = ((ByteRing *)pointer)->count;
  leave();
  return (FooResult){.number = count};
}
FooResult foo_ring_capacity(void *pointer) {
  Resource *entry = resource(pointer, RINGS);
  if (!entry) return failure(CLOSED);
  enter();
  if (entry->closed) { leave(); return failure(CLOSED); }
  uint64_t capacity = ((ByteRing *)pointer)->capacity;
  leave();
  return (FooResult){.number = capacity};
}
FooResult foo_ring_close(void *pointer) {
  Resource *entry = resource(pointer, RINGS);
  if (!entry) return failure(CLOSED);
  enter();
  if (entry->closed) { leave(); return failure(CLOSED); }
  ByteRing *ring = pointer;
  free(ring->bytes);
  ring->bytes = NULL;
  entry->closed = 1;
  leave();
  return (FooResult){0};
}
typedef struct {
  uint64_t bits, rounds;
  uint8_t *bytes;
} Bloom;
FooResult foo_bloom_create(uint64_t bits, uint64_t rounds) {
  if (!bits || !rounds || rounds > 16) return failure(ARGUMENT);
  uint64_t size = bits / 8 + (bits % 8 != 0);
  if (size > SIZE_MAX) return failure(ARGUMENT);
  uint8_t *bytes = calloc((size_t)size, 1);
  if (!bytes) return failure(MEMORY);
  Bloom *filter = owned(sizeof(*filter), BLOOMS);
  if (!filter) { free(bytes); return failure(MEMORY); }
  filter->bits = bits;
  filter->rounds = rounds;
  filter->bytes = bytes;
  return (FooResult){.pointer = filter};
}
static void bloom_hash(FooText key, uint64_t *first, uint64_t *step) {
  uint64_t a = UINT64_C(14695981039346656037);
  uint64_t b = UINT64_C(7809847782465536322);
  for (size_t index = 0; index < key.len; index++) {
    a = (a ^ key.data[index]) * UINT64_C(1099511628211);
    b = (b ^ key.data[index]) * UINT64_C(14029467366897019727);
  }
  *first = a;
  *step = b | 1;
}
FooResult foo_bloom_add(void *pointer, FooText key) {
  if (key.len && !key.data) return failure(ARGUMENT);
  Resource *entry = resource(pointer, BLOOMS);
  if (!entry) return failure(CLOSED);
  uint64_t first, step;
  bloom_hash(key, &first, &step);
  enter();
  if (entry->closed) { leave(); return failure(CLOSED); }
  Bloom *filter = pointer;
  for (uint64_t round = 0; round < filter->rounds; round++) {
    uint64_t bit = (first + round * step) % filter->bits;
    filter->bytes[bit / 8] |= (uint8_t)(1u << (bit % 8));
  }
  leave();
  return (FooResult){0};
}
FooResult foo_bloom_contains(void *pointer, FooText key) {
  if (key.len && !key.data) return failure(ARGUMENT);
  Resource *entry = resource(pointer, BLOOMS);
  if (!entry) return failure(CLOSED);
  uint64_t first, step;
  bloom_hash(key, &first, &step);
  enter();
  if (entry->closed) { leave(); return failure(CLOSED); }
  Bloom *filter = pointer;
  for (uint64_t round = 0; round < filter->rounds; round++) {
    uint64_t bit = (first + round * step) % filter->bits;
    if (!(filter->bytes[bit / 8] & (uint8_t)(1u << (bit % 8)))) {
      leave();
      return (FooResult){0};
    }
  }
  leave();
  return (FooResult){.number = 1};
}
FooResult foo_bloom_bits(void *pointer) {
  Resource *entry = resource(pointer, BLOOMS);
  if (!entry) return failure(CLOSED);
  enter();
  if (entry->closed) { leave(); return failure(CLOSED); }
  uint64_t bits = ((Bloom *)pointer)->bits;
  leave();
  return (FooResult){.number = bits};
}
FooResult foo_bloom_rounds(void *pointer) {
  Resource *entry = resource(pointer, BLOOMS);
  if (!entry) return failure(CLOSED);
  enter();
  if (entry->closed) { leave(); return failure(CLOSED); }
  uint64_t rounds = ((Bloom *)pointer)->rounds;
  leave();
  return (FooResult){.number = rounds};
}
FooResult foo_bloom_close(void *pointer) {
  Resource *entry = resource(pointer, BLOOMS);
  if (!entry) return failure(CLOSED);
  enter();
  if (entry->closed) { leave(); return failure(CLOSED); }
  Bloom *filter = pointer;
  free(filter->bytes);
  filter->bytes = NULL;
  entry->closed = 1;
  leave();
  return (FooResult){0};
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
  int mode;
#ifdef _WIN32
  atomic_flag positional;
#endif
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
  uint64_t partial;
  if (take_fault(FAULT_WRITE, &partial)) {
    size_t length = partial < value.len ? (size_t)partial : value.len;
    if (length && fwrite(value.data, 1, length, stream->file) != length)
      return failure(IO);
    fflush(stream->file);
    return failure(IO);
  }
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
      strcmp(access, "append") && strcmp(access, "update") &&
      strcmp(access, "create")) {
    free(name);
    free(access);
    return failure(ARGUMENT);
  }
  FILE *handle = NULL;
  int selected = !strcmp(access, "read") ? 1 :
      !strcmp(access, "append") ? 3 :
      !strcmp(access, "write") ? 2 : 4;
  if (!strcmp(access, "create")) {
#ifdef _WIN32
    int descriptor = _open(name, _O_CREAT | _O_EXCL | _O_RDWR | _O_BINARY,
                           _S_IREAD | _S_IWRITE);
    if (descriptor >= 0) {
      handle = _fdopen(descriptor, "w+b");
      if (!handle) _close(descriptor);
    }
#else
    int descriptor = open(name, O_CREAT | O_EXCL | O_RDWR, 0666);
    if (descriptor >= 0) {
      handle = fdopen(descriptor, "w+b");
      if (!handle) close(descriptor);
    }
#endif
  } else {
    handle = fopen(name, !strcmp(access, "read") ? "rb" :
        !strcmp(access, "write") ? "wb" :
        !strcmp(access, "update") ? "r+b" : "ab");
  }
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
  result->mode = selected;
#ifdef _WIN32
  atomic_flag_clear(&result->positional);
#endif
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
  if (take_fault(FAULT_SYNC, NULL)) return failure(IO);
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
FooResult foo_fs_truncate(void *pointer, uint64_t size) {
  File *stream = file(pointer);
  if (!stream || !stream->file) return failure(CLOSED);
  if (stream->mode == 1) return failure(ARGUMENT);
  if (size > INT64_MAX || fflush(stream->file)) return failure(IO);
#ifdef _WIN32
  return _chsize_s(_fileno(stream->file), size) ? failure(IO) : (FooResult){0};
#else
  return ftruncate(fileno(stream->file), (off_t)size) ? failure(IO)
                                                     : (FooResult){0};
#endif
}
FooResult foo_fs_reserve(void *pointer, uint64_t size) {
  File *stream = file(pointer);
  if (!stream || !stream->file) return failure(CLOSED);
  if (stream->mode == 1) return failure(ARGUMENT);
  if (size > INT64_MAX || fflush(stream->file)) return failure(IO);
  FooResult current = foo_fs_size(pointer);
  if (current.error || size <= current.number) return current.error ? current : (FooResult){0};
#ifdef _WIN32
  intptr_t native = _get_osfhandle(_fileno(stream->file));
  if (native == -1) return failure(IO);
  FILE_ALLOCATION_INFO allocation = {.AllocationSize.QuadPart = (LONGLONG)size};
  if (!SetFileInformationByHandle((HANDLE)native, FileAllocationInfo,
                                  &allocation, sizeof(allocation))) return failure(IO);
  return _chsize_s(_fileno(stream->file), size) ? failure(IO) : (FooResult){0};
#else
  return posix_fallocate(fileno(stream->file), 0, (off_t)size) ? failure(IO)
                                                               : (FooResult){0};
#endif
}
FooResult foo_fs_lock(void *pointer, FooText mode) {
  File *stream = file(pointer);
  if (!stream || !stream->file) return failure(CLOSED);
  int exclusive = mode.len == 9 && !memcmp(mode.data, "exclusive", 9);
  int shared = mode.len == 6 && !memcmp(mode.data, "shared", 6);
  if (!exclusive && !shared) return failure(ARGUMENT);
  if (shared && stream->mode == 3) return failure(ARGUMENT);
  if (exclusive && stream->mode == 1) return failure(ARGUMENT);
  if (stream->mode != 1 && fflush(stream->file)) return failure(IO);
#ifdef _WIN32
  intptr_t native = _get_osfhandle(_fileno(stream->file));
  if (native == -1) return failure(IO);
  OVERLAPPED operation = {0};
  return LockFileEx((HANDLE)native, exclusive ? LOCKFILE_EXCLUSIVE_LOCK : 0,
      0, MAXDWORD, MAXDWORD, &operation) ? (FooResult){0} : failure(IO);
#else
  return flock(fileno(stream->file), exclusive ? LOCK_EX : LOCK_SH)
      ? failure(IO) : (FooResult){0};
#endif
}
FooResult foo_fs_unlock(void *pointer) {
  File *stream = file(pointer);
  if (!stream || !stream->file) return failure(CLOSED);
#ifdef _WIN32
  intptr_t native = _get_osfhandle(_fileno(stream->file));
  if (native == -1) return failure(IO);
  OVERLAPPED operation = {0};
  return UnlockFileEx((HANDLE)native, 0, MAXDWORD, MAXDWORD, &operation)
      ? (FooResult){0} : failure(IO);
#else
  return flock(fileno(stream->file), LOCK_UN) ? failure(IO) : (FooResult){0};
#endif
}
static FooResult transferat(void *pointer, uint64_t offset, FooText bytes,
                            int writing) {
  File *stream = file(pointer);
  if (!stream || !stream->file)
    return failure(CLOSED);
  if ((stream->mode != 4 && stream->mode != (writing ? 2 : 1)) ||
      (bytes.len && !bytes.data))
    return failure(ARGUMENT);
  if (offset > INT64_MAX || (bytes.len && offset == INT64_MAX))
    return failure(BOUNDS);
  uint64_t partial;
  if (writing && take_fault(FAULT_WRITE, &partial) && partial < bytes.len)
    bytes.len = (size_t)partial;
  if (!bytes.len)
    return (FooResult){0};
#ifdef _WIN32
  while (atomic_flag_test_and_set_explicit(&stream->positional,
                                            memory_order_acquire)) {
  }
  if (stream->mode == 4 && file_seek(stream->file, 0, SEEK_CUR)) {
    atomic_flag_clear_explicit(&stream->positional, memory_order_release);
    return failure(IO);
  }
  fpos_t saved;
  int positioned = fgetpos(stream->file, &saved) == 0;
  int descriptor = positioned ? _fileno(stream->file) : -1;
  intptr_t native = descriptor >= 0 ? _get_osfhandle(descriptor) : -1;
  DWORD count = 0;
  BOOL success = FALSE;
  if (native != -1) {
    OVERLAPPED operation = {0};
    operation.Offset = (DWORD)offset;
    operation.OffsetHigh = (DWORD)(offset >> 32);
    DWORD length = bytes.len > UINT32_MAX ? UINT32_MAX : (DWORD)bytes.len;
    success = writing
        ? WriteFile((HANDLE)native, bytes.data, length, &count, &operation)
        : ReadFile((HANDLE)native, (void *)bytes.data, length, &count,
                   &operation);
    if (!writing && !success && GetLastError() == ERROR_HANDLE_EOF)
      success = TRUE;
  }
  int restored = positioned && fsetpos(stream->file, &saved) == 0;
  atomic_flag_clear_explicit(&stream->positional, memory_order_release);
  return !success || !restored ? failure(IO) : (FooResult){.number = count};
#else
  int descriptor = fileno(stream->file);
  if (descriptor < 0 || (stream->mode == 4 && file_seek(stream->file, 0, SEEK_CUR)) ||
      (writing && fflush(stream->file)))
    return failure(IO);
  size_t length = bytes.len > SSIZE_MAX ? SSIZE_MAX : bytes.len;
  ssize_t count;
  do {
    count = writing ? pwrite(descriptor, bytes.data, length, (off_t)offset)
                    : pread(descriptor, (void *)bytes.data, length,
                            (off_t)offset);
  } while (count < 0 && errno == EINTR);
  if (stream->mode == 4 && file_seek(stream->file, 0, SEEK_CUR))
    return failure(IO);
  return count < 0 ? failure(IO) : (FooResult){.number = (uint64_t)count};
#endif
}
FooResult foo_fs_readat(void *pointer, uint64_t offset, FooText destination) {
  return transferat(pointer, offset, destination, 0);
}
FooResult foo_fs_writeat(void *pointer, uint64_t offset, FooText source) {
  return transferat(pointer, offset, source, 1);
}
FooResult foo_fs_fetch(void *pointer, uint64_t offset, FooText destination) {
  return foo_fs_readat(pointer, offset, destination);
}
FooResult foo_fs_store(void *pointer, uint64_t offset, FooText source) {
  return foo_fs_writeat(pointer, offset, source);
}
typedef struct {
  void *base;
  size_t mapped;
  size_t delta;
  size_t length;
  FILE *stream;
  int writable;
} FileMapping;
static void unmap_file(FileMapping *mapping) {
#ifdef _WIN32
  UnmapViewOfFile(mapping->base);
#else
  munmap(mapping->base, mapping->mapped);
#endif
  if (mapping->stream) fclose(mapping->stream);
}
static FooResult map_file(FooText path, uint64_t offset, uint64_t length,
                          int writable) {
  char *name = string(path);
  if (!name)
    return failure(ARGUMENT);
  FILE *stream = fopen(name, writable ? "r+b" : "rb");
  free(name);
  if (!stream)
    return failure(IO);
  if (file_seek(stream, 0, SEEK_END)) {
    fclose(stream);
    return failure(IO);
  }
  int64_t end = file_position(stream);
  if (end < 0) {
    fclose(stream);
    return failure(IO);
  }
  if (offset > (uint64_t)end ||
      (length && length > (uint64_t)end - offset)) {
    fclose(stream);
    return failure(BOUNDS);
  }
  uint64_t available = (uint64_t)end - offset;
  uint64_t count = length ? length : available;
  if (!count || count > SIZE_MAX) {
    fclose(stream);
    return failure(BOUNDS);
  }
#ifdef _WIN32
  SYSTEM_INFO system;
  GetSystemInfo(&system);
  uint64_t page = system.dwAllocationGranularity;
#else
  long page_size = sysconf(_SC_PAGESIZE);
  if (page_size <= 0) {
    fclose(stream);
    return failure(SYSTEM);
  }
  uint64_t page = (uint64_t)page_size;
#endif
  uint64_t aligned = offset - offset % page;
  uint64_t delta = offset - aligned;
#ifndef _WIN32
  if ((uint64_t)(off_t)aligned != aligned) {
    fclose(stream);
    return failure(BOUNDS);
  }
#endif
  if (count > SIZE_MAX - delta) {
    fclose(stream);
    return failure(BOUNDS);
  }
  size_t mapped = (size_t)(count + delta);
#ifdef _WIN32
  intptr_t descriptor = _get_osfhandle(_fileno(stream));
  HANDLE file_mapping = descriptor == -1 ? NULL :
      CreateFileMappingA((HANDLE)descriptor, NULL,
                         writable ? PAGE_READWRITE : PAGE_READONLY, 0, 0, NULL);
  void *base = file_mapping ? MapViewOfFile(file_mapping,
      writable ? FILE_MAP_WRITE : FILE_MAP_READ,
      (DWORD)(aligned >> 32), (DWORD)aligned, mapped) : NULL;
  if (file_mapping)
    CloseHandle(file_mapping);
#else
  void *base = mmap(NULL, mapped, writable ? PROT_READ | PROT_WRITE : PROT_READ,
      writable ? MAP_SHARED : MAP_PRIVATE, fileno(stream),
      (off_t)aligned);
  if (base == MAP_FAILED)
    base = NULL;
#endif
  if (!base) {
    fclose(stream);
    return failure(IO);
  }
  FileMapping *mapping = calloc(1, sizeof(*mapping));
  if (!mapping) {
    FileMapping temporary = {.base = base, .mapped = mapped, .stream = stream};
    unmap_file(&temporary);
    return failure(MEMORY);
  }
  *mapping = (FileMapping){base, mapped, (size_t)delta, (size_t)count,
                           stream, writable};
  if (!adopt(mapping, (size_t)count, MAPS)) {
    unmap_file(mapping);
    free(mapping);
    return failure(MEMORY);
  }
  return (FooResult){.pointer = mapping};
}
FooResult foo_fs_map(FooText path, uint64_t offset, uint64_t length) {
  return map_file(path, offset, length, 0);
}
FooResult foo_fs_edit(FooText path, uint64_t offset, uint64_t length) {
  return map_file(path, offset, length, 1);
}
FooResult foo_fs_mapped(void *pointer) {
  Resource *entry = resource(pointer, MAPS);
  if (!entry)
    return failure(CLOSED);
  FileMapping *mapping = pointer;
  return (FooResult){.text = {(const uint8_t *)mapping->base + mapping->delta,
                              mapping->length}};
}
FooResult foo_fs_borrow(void *pointer) {
  Resource *entry = resource(pointer, MAPS);
  if (!entry) return failure(CLOSED);
  FileMapping *mapping = pointer;
  if (!mapping->writable) return failure(ARGUMENT);
  return (FooResult){.text = {(uint8_t *)mapping->base + mapping->delta,
                              mapping->length}};
}
FooResult foo_fs_publish(void *pointer) {
  Resource *entry = resource(pointer, MAPS);
  if (!entry) return failure(CLOSED);
  FileMapping *mapping = pointer;
  if (!mapping->writable) return failure(ARGUMENT);
#ifdef _WIN32
  if (!FlushViewOfFile(mapping->base, mapping->mapped) ||
      !FlushFileBuffers((HANDLE)_get_osfhandle(_fileno(mapping->stream))))
    return failure(IO);
#else
  if (msync(mapping->base, mapping->mapped, MS_SYNC) ||
      fsync(fileno(mapping->stream))) return failure(IO);
#endif
  return (FooResult){0};
}
FooResult foo_fs_portion(void *pointer, uint64_t offset, uint64_t length) {
  Resource *entry = resource(pointer, MAPS);
  if (!entry) return failure(CLOSED);
  FileMapping *mapping = pointer;
  if (!mapping->writable) return failure(ARGUMENT);
  if (offset > mapping->length || length > mapping->length - offset)
    return failure(BOUNDS);
  if (!length) return (FooResult){0};
  uint8_t *first = (uint8_t *)mapping->base + mapping->delta + (size_t)offset;
#ifdef _WIN32
  if (!FlushViewOfFile(first, (SIZE_T)length) ||
      !FlushFileBuffers((HANDLE)_get_osfhandle(_fileno(mapping->stream))))
    return failure(IO);
#else
  long page = sysconf(_SC_PAGESIZE);
  if (page <= 0) return failure(SYSTEM);
  uintptr_t aligned = (uintptr_t)first - (uintptr_t)first % (uintptr_t)page;
  size_t span = (size_t)((uintptr_t)first + (size_t)length - aligned);
  if (msync((void *)aligned, span, MS_SYNC) ||
      fsync(fileno(mapping->stream))) return failure(IO);
#endif
  return (FooResult){0};
}
FooResult foo_fs_unmap(void *pointer) {
  Resource *entry = resource(pointer, MAPS);
  if (!entry)
    return failure(CLOSED);
  FileMapping *mapping = pointer;
  if (mapping->writable) {
    FooResult flushed = foo_fs_publish(pointer);
    if (flushed.error) return flushed;
  }
  unmap_file(mapping);
  mapping->base = NULL;
  mapping->stream = NULL;
  entry->closed = 1;
  return (FooResult){0};
}
typedef struct {
  uint8_t *base;
  size_t length;
  int mode;
  int committed;
} VirtualRegion;
FooResult foo_vm_reserve(uint64_t size) {
  if (!size) return failure(ARGUMENT);
#ifdef _WIN32
  SYSTEM_INFO system;
  GetSystemInfo(&system);
  size_t page = system.dwPageSize;
#else
  long measured = sysconf(_SC_PAGESIZE);
  if (measured <= 0) return failure(SYSTEM);
  size_t page = (size_t)measured;
#endif
  if (size > SIZE_MAX - (page - 1)) return failure(BOUNDS);
  size_t length = ((size_t)size + page - 1) / page * page;
#ifdef _WIN32
  uint8_t *base = VirtualAlloc(NULL, length, MEM_RESERVE, PAGE_NOACCESS);
#else
  uint8_t *base = mmap(NULL, length, PROT_NONE,
                       MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
  if (base == MAP_FAILED) base = NULL;
#endif
  if (!base) return failure(MEMORY);
  VirtualRegion *region = calloc(1, sizeof(*region));
  if (!region) {
#ifdef _WIN32
    VirtualFree(base, 0, MEM_RELEASE);
#else
    munmap(base, length);
#endif
    return failure(MEMORY);
  }
  *region = (VirtualRegion){base, length, 0, 0};
  if (!adopt(region, length, VIRTUAL_REGIONS)) {
#ifdef _WIN32
    VirtualFree(base, 0, MEM_RELEASE);
#else
    munmap(base, length);
#endif
    free(region);
    return failure(MEMORY);
  }
  return (FooResult){.pointer = region};
}
FooResult foo_vm_size(void *pointer) {
  if (!resource(pointer, VIRTUAL_REGIONS)) return failure(CLOSED);
  return (FooResult){.number = ((VirtualRegion *)pointer)->length};
}
FooResult foo_vm_commit(void *pointer) {
  if (!resource(pointer, VIRTUAL_REGIONS)) return failure(CLOSED);
  VirtualRegion *region = pointer;
#ifdef _WIN32
  if (region->committed) {
    DWORD previous;
    if (!VirtualProtect(region->base, region->length, PAGE_READWRITE,
                        &previous)) return failure(SYSTEM);
  } else if (!VirtualAlloc(region->base, region->length, MEM_COMMIT,
                           PAGE_READWRITE)) return failure(MEMORY);
#else
  if (mprotect(region->base, region->length, PROT_READ | PROT_WRITE))
    return failure(SYSTEM);
#endif
  region->mode = 2;
  region->committed = 1;
  return (FooResult){0};
}
FooResult foo_vm_protect(void *pointer, FooText mode) {
  if (!resource(pointer, VIRTUAL_REGIONS)) return failure(CLOSED);
  VirtualRegion *region = pointer;
  if (!region->committed) return failure(ARGUMENT);
  int selected = cpu_named(mode, "none") ? 0 :
      cpu_named(mode, "read") ? 1 : cpu_named(mode, "write") ? 2 :
      cpu_named(mode, "execute") ? 3 : -1;
  if (selected < 0) return failure(ARGUMENT);
#ifdef _WIN32
  DWORD protection = selected == 0 ? PAGE_NOACCESS :
                     selected == 1 ? PAGE_READONLY :
                     selected == 2 ? PAGE_READWRITE : PAGE_EXECUTE_READ;
  DWORD previous;
  if (!VirtualProtect(region->base, region->length, protection, &previous))
    return failure(SYSTEM);
#else
  int protection = selected == 0 ? PROT_NONE :
                   selected == 1 ? PROT_READ :
                   selected == 2 ? PROT_READ | PROT_WRITE :
                   PROT_READ | PROT_EXEC;
  if (mprotect(region->base, region->length, protection))
    return failure(SYSTEM);
#endif
  region->mode = selected;
  return (FooResult){0};
}
FooResult foo_vm_decommit(void *pointer) {
  if (!resource(pointer, VIRTUAL_REGIONS)) return failure(CLOSED);
  VirtualRegion *region = pointer;
  if (!region->committed) return (FooResult){0};
#ifdef _WIN32
  if (!VirtualFree(region->base, region->length, MEM_DECOMMIT))
    return failure(SYSTEM);
#else
  if (mprotect(region->base, region->length, PROT_NONE))
    return failure(SYSTEM);
  region->mode = 0;
  if (madvise(region->base, region->length, MADV_DONTNEED))
    return failure(SYSTEM);
#endif
  region->mode = 0;
  region->committed = 0;
  return (FooResult){0};
}
FooResult foo_vm_load(void *pointer, uint64_t offset) {
  if (!resource(pointer, VIRTUAL_REGIONS)) return failure(CLOSED);
  VirtualRegion *region = pointer;
  if (offset >= region->length) return failure(BOUNDS);
  if (!region->mode) return failure(ARGUMENT);
  return (FooResult){.number = region->base[offset]};
}
FooResult foo_vm_store(void *pointer, uint64_t offset, uint8_t data) {
  if (!resource(pointer, VIRTUAL_REGIONS)) return failure(CLOSED);
  VirtualRegion *region = pointer;
  if (offset >= region->length) return failure(BOUNDS);
  if (region->mode != 2) return failure(ARGUMENT);
  region->base[offset] = data;
  return (FooResult){0};
}
FooResult foo_vm_release(void *pointer) {
  Resource *entry = resource(pointer, VIRTUAL_REGIONS);
  if (!entry) return failure(CLOSED);
  VirtualRegion *region = pointer;
#ifdef _WIN32
  if (!VirtualFree(region->base, 0, MEM_RELEASE)) return failure(SYSTEM);
#else
  if (munmap(region->base, region->length)) return failure(SYSTEM);
#endif
  region->base = NULL;
  region->mode = 0;
  region->committed = 0;
  entry->closed = 1;
  return (FooResult){0};
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
FooResult foo_fs_load(FooText path) { return foo_fs_read(path); }
FooResult foo_fs_save(FooText path, FooText value) {
  return foo_fs_write(path, value);
}
FooResult foo_fs_release(FooText value) {
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
  if (take_fault(FAULT_REPLACE, NULL)) {
    free(from);
    free(to);
    return failure(IO);
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
#ifdef _WIN32
  DWORD attributes = GetFileAttributesA(name);
  int result = attributes != INVALID_FILE_ATTRIBUTES &&
      (attributes & FILE_ATTRIBUTE_DIRECTORY) ? !RemoveDirectoryA(name)
                                          : remove(name);
#else
  int result = remove(name);
#endif
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
typedef struct {
#ifdef _WIN32
  HANDLE handle;
  WIN32_FIND_DATAA entry;
  int first;
#else
  DIR *handle;
#endif
} DirectoryScan;
FooResult foo_fs_scan(FooText path) {
  char *name = string(path);
  if (!name) return failure(ARGUMENT);
#ifdef _WIN32
  size_t length = strlen(name);
  if (length > SIZE_MAX - 3) { free(name); return failure(BOUNDS); }
  char *pattern = malloc(length + 3);
  if (!pattern) { free(name); return failure(MEMORY); }
  memcpy(pattern, name, length);
  size_t suffix = length && (name[length - 1] == '/' || name[length - 1] == '\\')
      ? 0 : 1;
  if (suffix) pattern[length] = '/';
  pattern[length + suffix] = '*';
  pattern[length + suffix + 1] = 0;
  WIN32_FIND_DATAA entry = {0};
  HANDLE handle = FindFirstFileA(pattern, &entry);
  DWORD problem = handle == INVALID_HANDLE_VALUE ? GetLastError() : 0;
  free(pattern);
  DWORD attributes = GetFileAttributesA(name);
  free(name);
  if (attributes == INVALID_FILE_ATTRIBUTES ||
      !(attributes & FILE_ATTRIBUTE_DIRECTORY) ||
      (handle == INVALID_HANDLE_VALUE && problem != ERROR_FILE_NOT_FOUND)) {
    if (handle != INVALID_HANDLE_VALUE) FindClose(handle);
    return failure(IO);
  }
#else
  DIR *handle = opendir(name);
  free(name);
  if (!handle) return failure(IO);
#endif
  DirectoryScan *cursor = owned(sizeof(*cursor), DIRS);
  if (!cursor) {
#ifdef _WIN32
    if (handle != INVALID_HANDLE_VALUE) FindClose(handle);
#else
    closedir(handle);
#endif
    return failure(MEMORY);
  }
  cursor->handle = handle;
#ifdef _WIN32
  cursor->entry = entry;
  cursor->first = handle != INVALID_HANDLE_VALUE;
#endif
  return (FooResult){.pointer = cursor};
}
FooResult foo_fs_next(void *pointer) {
  if (!resource(pointer, DIRS)) return failure(CLOSED);
  DirectoryScan *cursor = pointer;
#ifdef _WIN32
  while (cursor->handle != INVALID_HANDLE_VALUE) {
    if (cursor->first) cursor->first = 0;
    else if (!FindNextFileA(cursor->handle, &cursor->entry)) {
      DWORD problem = GetLastError();
      FindClose(cursor->handle);
      cursor->handle = INVALID_HANDLE_VALUE;
      return problem == ERROR_NO_MORE_FILES ? (FooResult){0} : failure(IO);
    }
    const char *name = cursor->entry.cFileName;
    if (!strcmp(name, ".") || !strcmp(name, "..")) continue;
    return text(name, strlen(name));
  }
#else
  for (;;) {
    errno = 0;
    struct dirent *entry = readdir(cursor->handle);
    if (!entry) return errno ? failure(IO) : (FooResult){0};
    const char *name = entry->d_name;
    if (!strcmp(name, ".") || !strcmp(name, "..")) continue;
    return text(name, strlen(name));
  }
#endif
  return (FooResult){0};
}
FooResult foo_fs_finish(void *pointer) {
  Resource *entry = resource(pointer, DIRS);
  if (!entry) return failure(CLOSED);
  DirectoryScan *cursor = pointer;
#ifdef _WIN32
  int failed = cursor->handle != INVALID_HANDLE_VALUE &&
      !FindClose(cursor->handle);
  cursor->handle = INVALID_HANDLE_VALUE;
#else
  int failed = closedir(cursor->handle);
  cursor->handle = NULL;
#endif
  entry->closed = 1;
  return failed ? failure(IO) : (FooResult){0};
}
typedef struct {
  void *cursor;
  char *relative;
} WalkFrame;
typedef struct {
  char *root;
  WalkFrame *frames;
  size_t count;
  size_t capacity;
} DirectoryWalk;
static char *walk_path(const char *left, const char *right) {
  size_t first = strlen(left), second = strlen(right);
  int separator = first && left[first - 1] != '/' && left[first - 1] != '\\';
  if (first > SIZE_MAX - second - (size_t)separator - 1) return NULL;
  char *path = malloc(first + second + (size_t)separator + 1);
  if (!path) return NULL;
  memcpy(path, left, first);
  if (separator) path[first++] = '/';
  memcpy(path + first, right, second + 1);
  return path;
}
static int walk_push(DirectoryWalk *walk, void *cursor, char *relative) {
  if (walk->count == walk->capacity) {
    size_t capacity = walk->capacity ? walk->capacity * 2 : 4;
    if (capacity < walk->capacity || capacity > SIZE_MAX / sizeof(WalkFrame))
      return 0;
    WalkFrame *frames = realloc(walk->frames, capacity * sizeof(*frames));
    if (!frames) return 0;
    walk->frames = frames;
    walk->capacity = capacity;
  }
  walk->frames[walk->count++] = (WalkFrame){cursor, relative};
  return 1;
}
FooResult foo_fs_walk(FooText path) {
  FooResult root = foo_fs_scan(path);
  if (root.error) return root;
  char *name = string(path);
  DirectoryWalk *walk = name ? owned(sizeof(*walk), WALKS) : NULL;
  if (!walk) {
    foo_fs_finish(root.pointer);
    free(name);
    return failure(MEMORY);
  }
  walk->root = name;
  char *relative = calloc(1, 1);
  if (!relative || !walk_push(walk, root.pointer, relative)) {
    free(relative);
    foo_fs_finish(root.pointer);
    free(walk->root);
    resource(walk, WALKS)->closed = 1;
    return failure(MEMORY);
  }
  return (FooResult){.pointer = walk};
}
FooResult foo_fs_traverse(void *pointer) {
  if (!resource(pointer, WALKS)) return failure(CLOSED);
  DirectoryWalk *walk = pointer;
  while (walk->count) {
    WalkFrame *frame = &walk->frames[walk->count - 1];
    FooResult entry = foo_fs_next(frame->cursor);
    if (entry.error) return entry;
    if (!entry.text.len) {
      FooResult finished = foo_fs_finish(frame->cursor);
      free(frame->relative);
      walk->count--;
      if (finished.error) return finished;
      continue;
    }
    char *name = string(entry.text);
    foo_text_release(entry.text);
    char *relative = name ? walk_path(frame->relative, name) : NULL;
    free(name);
    char *full = relative ? walk_path(walk->root, relative) : NULL;
    if (!full) { free(relative); return failure(MEMORY); }
#ifdef _WIN32
    DWORD attributes = GetFileAttributesA(full);
    int failed = attributes == INVALID_FILE_ATTRIBUTES;
    int descend = !failed && (attributes & FILE_ATTRIBUTE_DIRECTORY) &&
                  !(attributes & FILE_ATTRIBUTE_REPARSE_POINT);
#else
    struct stat status;
    int failed = lstat(full, &status);
    int descend = !failed && S_ISDIR(status.st_mode);
#endif
    free(full);
    if (failed) { free(relative); return failure(IO); }
    if (descend) {
      char *childpath = walk_path(walk->root, relative);
      if (!childpath) { free(relative); return failure(MEMORY); }
      FooResult child = foo_fs_scan((FooText){(const uint8_t *)childpath,
                                               strlen(childpath)});
      free(childpath);
      if (child.error) { free(relative); return child; }
      if (!walk_push(walk, child.pointer, relative)) {
        foo_fs_finish(child.pointer);
        free(relative);
        return failure(MEMORY);
      }
    }
    FooResult value = text(relative, strlen(relative));
    if (!descend) free(relative);
    return value;
  }
  return (FooResult){0};
}
FooResult foo_fs_cease(void *pointer) {
  Resource *entry = resource(pointer, WALKS);
  if (!entry) return failure(CLOSED);
  DirectoryWalk *walk = pointer;
  int failed = 0;
  while (walk->count) {
    WalkFrame *frame = &walk->frames[--walk->count];
    if (resource(frame->cursor, DIRS) && foo_fs_finish(frame->cursor).error)
      failed = 1;
    free(frame->relative);
  }
  free(walk->frames);
  free(walk->root);
  walk->frames = NULL;
  walk->root = NULL;
  entry->closed = 1;
  return failed ? failure(IO) : (FooResult){0};
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
typedef struct {
  uint64_t size;
  uint64_t modified;
  uint64_t accessed;
  uint64_t changed;
  int readonly;
  char kind[10];
} FileMetadata;
#ifdef _WIN32
static uint64_t filetime_ns(LARGE_INTEGER value) {
  const uint64_t epoch = UINT64_C(116444736000000000);
  return (uint64_t)value.QuadPart < epoch ? 0 :
      ((uint64_t)value.QuadPart - epoch) * 100;
}
#else
static uint64_t stat_ns(time_t seconds, long nanos) {
  if (seconds < 0 || (uint64_t)seconds > UINT64_MAX / 1000000000)
    return 0;
  return (uint64_t)seconds * 1000000000 + (uint64_t)nanos;
}
#endif
FooResult foo_fs_metadata(FooText path) {
  char *name = string(path);
  if (!name) return failure(ARGUMENT);
  FileMetadata snapshot = {0};
#ifdef _WIN32
  WIN32_FILE_ATTRIBUTE_DATA data;
  if (!GetFileAttributesExA(name, GetFileExInfoStandard, &data)) {
    DWORD problem = GetLastError();
    free(name);
    return failure(problem == ERROR_FILE_NOT_FOUND || problem == ERROR_PATH_NOT_FOUND
        ? MISSING : IO);
  }
  HANDLE handle = CreateFileA(name, FILE_READ_ATTRIBUTES,
      FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE, NULL,
      OPEN_EXISTING, FILE_FLAG_BACKUP_SEMANTICS | FILE_FLAG_OPEN_REPARSE_POINT,
      NULL);
  free(name);
  FILE_BASIC_INFO basic;
  if (handle == INVALID_HANDLE_VALUE ||
      !GetFileInformationByHandleEx(handle, FileBasicInfo, &basic, sizeof(basic))) {
    if (handle != INVALID_HANDLE_VALUE) CloseHandle(handle);
    return failure(IO);
  }
  CloseHandle(handle);
  snapshot.size = ((uint64_t)data.nFileSizeHigh << 32) | data.nFileSizeLow;
  snapshot.modified = filetime_ns(basic.LastWriteTime);
  snapshot.accessed = filetime_ns(basic.LastAccessTime);
  snapshot.changed = filetime_ns(basic.ChangeTime);
  snapshot.readonly = !!(data.dwFileAttributes & FILE_ATTRIBUTE_READONLY);
  const char *kind = data.dwFileAttributes & FILE_ATTRIBUTE_REPARSE_POINT ? "link"
      : data.dwFileAttributes & FILE_ATTRIBUTE_DIRECTORY ? "directory" : "file";
#else
  struct stat status;
  int failed = lstat(name, &status);
  int problem = errno;
  free(name);
  if (failed) return failure(problem == ENOENT ? MISSING : IO);
  snapshot.size = status.st_size < 0 ? 0 : (uint64_t)status.st_size;
#ifdef __APPLE__
  snapshot.modified = stat_ns(status.st_mtimespec.tv_sec, status.st_mtimespec.tv_nsec);
  snapshot.accessed = stat_ns(status.st_atimespec.tv_sec, status.st_atimespec.tv_nsec);
  snapshot.changed = stat_ns(status.st_ctimespec.tv_sec, status.st_ctimespec.tv_nsec);
#else
  snapshot.modified = stat_ns(status.st_mtim.tv_sec, status.st_mtim.tv_nsec);
  snapshot.accessed = stat_ns(status.st_atim.tv_sec, status.st_atim.tv_nsec);
  snapshot.changed = stat_ns(status.st_ctim.tv_sec, status.st_ctim.tv_nsec);
#endif
  snapshot.readonly = !(status.st_mode & 0222);
  const char *kind = S_ISLNK(status.st_mode) ? "link" :
      S_ISDIR(status.st_mode) ? "directory" :
      S_ISREG(status.st_mode) ? "file" : "other";
#endif
  strcpy(snapshot.kind, kind);
  FileMetadata *result = owned(sizeof(*result), METADATA);
  if (!result) return failure(MEMORY);
  *result = snapshot;
  return (FooResult){.pointer = result};
}
FooResult foo_fs_measure(void *pointer) {
  if (!resource(pointer, METADATA)) return failure(CLOSED);
  return (FooResult){.number = ((FileMetadata *)pointer)->size};
}
FooResult foo_fs_timestamp(void *pointer, FooText field) {
  if (!resource(pointer, METADATA)) return failure(CLOSED);
  if (field.len && !field.data) return failure(ARGUMENT);
  FileMetadata *value = pointer;
  uint64_t selected = field.len == 8 && !memcmp(field.data, "modified", 8)
      ? value->modified : field.len == 8 && !memcmp(field.data, "accessed", 8)
      ? value->accessed : field.len == 7 && !memcmp(field.data, "changed", 7)
      ? value->changed : UINT64_MAX;
  return selected == UINT64_MAX ? failure(ARGUMENT)
      : (FooResult){.number = selected};
}
FooResult foo_fs_classify(void *pointer) {
  if (!resource(pointer, METADATA)) return failure(CLOSED);
  FileMetadata *value = pointer;
  return (FooResult){.text = {(const uint8_t *)value->kind, strlen(value->kind)}};
}
FooResult foo_fs_restricted(void *pointer) {
  if (!resource(pointer, METADATA)) return failure(CLOSED);
  return (FooResult){.number = (uint64_t)((FileMetadata *)pointer)->readonly};
}
FooResult foo_fs_retire(void *pointer) {
  Resource *entry = resource(pointer, METADATA);
  if (!entry) return failure(CLOSED);
  entry->closed = 1;
  return (FooResult){0};
}
FooResult foo_fs_temporary(FooText directory, FooText prefix) {
  if (!directory.len || prefix.len > 64 || (prefix.len && !prefix.data))
    return failure(ARGUMENT);
  for (size_t index = 0; index < prefix.len; index++) {
    uint8_t byte = prefix.data[index];
    if (!((byte >= 'a' && byte <= 'z') || (byte >= 'A' && byte <= 'Z') ||
          (byte >= '0' && byte <= '9') || byte == '-' || byte == '_'))
      return failure(ARGUMENT);
  }
  char *folder = string(directory);
  if (!folder || directory.len > SIZE_MAX - prefix.len - 40) {
    free(folder);
    return failure(ARGUMENT);
  }
  size_t length = strlen(folder);
  char *name = malloc(length + prefix.len + 40);
  if (!name) { free(folder); return failure(MEMORY); }
  int separator = length && folder[length - 1] != '/' && folder[length - 1] != '\\';
  memcpy(name, folder, length);
  free(folder);
  if (separator) name[length++] = '/';
  memcpy(name + length, prefix.data, prefix.len);
  length += prefix.len;
#ifdef _WIN32
  for (int attempt = 0; attempt < 32; attempt++) {
    unsigned first, second, third, fourth;
    if (rand_s(&first) || rand_s(&second) || rand_s(&third) || rand_s(&fourth)) {
      free(name);
      return failure(SYSTEM);
    }
    snprintf(name + length, 40, "%08x%08x%08x%08x.tmp",
             first, second, third, fourth);
    int descriptor = _open(name, _O_CREAT | _O_EXCL | _O_RDWR | _O_BINARY,
                           _S_IREAD | _S_IWRITE);
    if (descriptor < 0 && errno == EEXIST) continue;
    if (descriptor < 0) { free(name); return failure(IO); }
    int failed = _close(descriptor);
    if (failed) { remove(name); free(name); return failure(IO); }
    FooResult result = text(name, strlen(name));
    if (result.error) remove(name);
    free(name);
    return result;
  }
#else
  memcpy(name + length, "XXXXXX", 7);
  int descriptor = mkstemp(name);
  if (descriptor >= 0) {
    int failed = close(descriptor);
    if (failed) { remove(name); free(name); return failure(IO); }
    FooResult result = text(name, strlen(name));
    if (result.error) remove(name);
    free(name);
    return result;
  }
#endif
  free(name);
  return failure(IO);
}
FooResult foo_fs_free(FooText path) {
  char *name = string(path);
  if (!name) return failure(ARGUMENT);
#ifdef _WIN32
  ULARGE_INTEGER available;
  int failed = !GetDiskFreeSpaceExA(name, &available, NULL, NULL);
  free(name);
  return failed ? failure(IO) : (FooResult){.number = available.QuadPart};
#else
  struct statvfs status;
  int failed = statvfs(name, &status);
  free(name);
  if (failed) return failure(IO);
  uint64_t unit = status.f_frsize ? status.f_frsize : status.f_bsize;
  if (unit && status.f_bavail > UINT64_MAX / unit) return failure(BOUNDS);
  return (FooResult){.number = status.f_bavail * unit};
#endif
}
FooResult foo_fs_block(FooText path) {
  char *name = string(path);
  if (!name) return failure(ARGUMENT);
#ifdef _WIN32
  char root[MAX_PATH];
  DWORD sectors, bytes, clusters, total;
  int failed = !GetVolumePathNameA(name, root, MAX_PATH) ||
      !GetDiskFreeSpaceA(root, &sectors, &bytes, &clusters, &total);
  free(name);
  return failed ? failure(IO) :
      (FooResult){.number = (uint64_t)sectors * bytes};
#else
  struct statvfs status;
  int failed = statvfs(name, &status);
  free(name);
  return failed ? failure(IO) :
      (FooResult){.number = status.f_frsize ? status.f_frsize : status.f_bsize};
#endif
}
FooResult foo_fs_copy(FooText source, FooText destination) {
  FooResult content = foo_fs_load(source);
  if (content.error)
    return content;
  FooResult written = foo_fs_save(destination, content.text);
  FooResult released = foo_fs_release(content.text);
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
typedef struct {
  uint8_t *data;
  size_t length;
  char host[INET6_ADDRSTRLEN];
  uint16_t port;
  struct sockaddr_storage address;
} Packet;
static int interrupted(void) {
#ifdef _WIN32
  return WSAGetLastError() == WSAEINTR;
#else
  return errno == EINTR;
#endif
}
static FooResult socket_resource(Socket socket, int kind) {
  Connection *result = owned(sizeof(*result), kind);
  if (!result) {
    disconnect(socket);
    return failure(MEMORY);
  }
  result->socket = socket;
  return (FooResult){.pointer = result};
}
static FooResult connection(Socket socket) {
  return socket_resource(socket, SOCKETS);
}
static int network_init(void) {
#ifdef _WIN32
  enter();
  if (!winsock) {
    WSADATA data;
    if (WSAStartup(MAKEWORD(2, 2), &data)) {
      leave();
      return 0;
    }
    winsock = 1;
  }
  leave();
#endif
  return 1;
}
static FooResult network(FooText host, uint64_t port, int server) {
  if (port > 65535)
    return failure(BOUNDS);
  if (!network_init()) return failure(SYSTEM);
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
static FooResult network_six(uint64_t high, uint64_t low, uint64_t port,
                              uint64_t scope, int server) {
  if (port > 65535 || scope > UINT32_MAX) return failure(BOUNDS);
  if (!network_init()) return failure(SYSTEM);
  Socket handle = socket(AF_INET6, SOCK_STREAM, IPPROTO_TCP);
  if (handle == INVALID) return failure(IO);
  struct sockaddr_in6 address = {0};
  address.sin6_family = AF_INET6;
  address.sin6_port = htons((uint16_t)port);
  address.sin6_scope_id = (uint32_t)scope;
  for (int index = 7; index >= 0; index--) {
    address.sin6_addr.s6_addr[index] = (uint8_t)high;
    address.sin6_addr.s6_addr[index + 8] = (uint8_t)low;
    high >>= 8;
    low >>= 8;
  }
#ifdef SO_NOSIGPIPE
  int no_signal = 1;
  setsockopt(handle, SOL_SOCKET, SO_NOSIGPIPE, (const char *)&no_signal,
             sizeof(no_signal));
#endif
  if (server) {
    int reuse = 1;
    setsockopt(handle, SOL_SOCKET, SO_REUSEADDR, (const char *)&reuse,
               sizeof(reuse));
  }
  int error = server
      ? bind(handle, (struct sockaddr *)&address, sizeof(address))
      : connect(handle, (struct sockaddr *)&address, sizeof(address));
  if (!error && server) error = listen(handle, 128);
  if (error) { disconnect(handle); return failure(IO); }
  return connection(handle);
}
FooResult foo_net_establish(uint64_t high, uint64_t low, uint64_t port,
                              uint64_t scope) {
  return network_six(high, low, port, scope, 0);
}
FooResult foo_net_host(uint64_t high, uint64_t low, uint64_t port,
                             uint64_t scope) {
  return network_six(high, low, port, scope, 1);
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
FooResult foo_net_latency(void *pointer, bool enabled) {
  if (!resource(pointer, SOCKETS))
    return failure(CLOSED);
  int value = enabled ? 1 : 0;
  return setsockopt(((Connection *)pointer)->socket, IPPROTO_TCP, TCP_NODELAY,
                    (const char *)&value, sizeof(value))
             ? failure(IO)
             : (FooResult){0};
}
FooResult foo_net_probe(void *pointer, bool enabled) {
  if (!resource(pointer, SOCKETS))
    return failure(CLOSED);
  int value = enabled ? 1 : 0;
  return setsockopt(((Connection *)pointer)->socket, SOL_SOCKET, SO_KEEPALIVE,
                    (const char *)&value, sizeof(value))
             ? failure(IO)
             : (FooResult){0};
}
static FooResult socket_timeout(Socket handle, FooText direction,
                                uint64_t milliseconds) {
  int option = cpu_named(direction, "send") ? SO_SNDTIMEO
      : cpu_named(direction, "receive") ? SO_RCVTIMEO : -1;
  if (option < 0) return failure(ARGUMENT);
  if (milliseconds > INT_MAX) return failure(BOUNDS);
#ifdef _WIN32
  DWORD requested = (DWORD)milliseconds, effective = 0;
  int length = sizeof(effective);
#else
  struct timeval requested = {(time_t)(milliseconds / 1000),
                              (suseconds_t)((milliseconds % 1000) * 1000)};
  struct timeval effective = {0};
  socklen_t length = sizeof(effective);
#endif
  if (setsockopt(handle, SOL_SOCKET, option, (const char *)&requested,
                 sizeof(requested)) ||
      getsockopt(handle, SOL_SOCKET, option, (char *)&effective, &length))
    return failure(IO);
#ifdef _WIN32
  return (FooResult){.number = effective};
#else
  if (effective.tv_sec < 0 || effective.tv_usec < 0 ||
      (uint64_t)effective.tv_sec >
          (UINT64_MAX - ((uint64_t)effective.tv_usec + 999) / 1000) / 1000)
    return failure(SYSTEM);
  return (FooResult){.number = (uint64_t)effective.tv_sec * 1000 +
      ((uint64_t)effective.tv_usec + 999) / 1000};
#endif
}
FooResult foo_net_timeout(void *pointer, FooText direction,
                          uint64_t milliseconds) {
  if (!resource(pointer, SOCKETS)) return failure(CLOSED);
  return socket_timeout(((Connection *)pointer)->socket, direction, milliseconds);
}
FooResult foo_net_close(void *pointer) {
  Resource *entry = resource(pointer, SOCKETS);
  if (!entry)
    return failure(CLOSED);
  int result = disconnect(((Connection *)pointer)->socket);
  entry->closed = 1;
  return result ? failure(IO) : (FooResult){0};
}

typedef struct {
#ifdef _WIN32
  HMODULE library;
#else
  void *library;
#endif
  const void *(*TLS_client_method)(void);
  void *(*SSL_CTX_new)(const void *);
  void (*SSL_CTX_free)(void *);
  int (*SSL_CTX_set_default_verify_paths)(void *);
  void (*SSL_CTX_set_verify)(void *, int, void *);
  void *(*SSL_new)(void *);
  void (*SSL_free)(void *);
  int (*SSL_set1_host)(void *, const char *);
  long (*SSL_ctrl)(void *, int, long, void *);
  int (*SSL_set_fd)(void *, int);
  int (*SSL_connect)(void *);
  int (*SSL_get_error)(const void *, int);
  long (*SSL_get_verify_result)(const void *);
  int (*SSL_write)(void *, const void *, int);
  int (*SSL_read)(void *, void *, int);
  int (*SSL_shutdown)(void *);
} TlsApi;
typedef struct {
  void *context;
  void *session;
  void *socket;
} TlsConnection;
static TlsApi tls_api;
static int tls_state;
static void *tls_symbol(const char *name) {
#ifdef _WIN32
  return (void *)GetProcAddress(tls_api.library, name);
#else
  return dlsym(tls_api.library, name);
#endif
}
static int tls_load(void) {
  enter();
  if (tls_state) { int ready = tls_state > 0; leave(); return ready; }
  const char *configured = getenv("FOO_TLS_LIBRARY");
#ifdef _WIN32
  const char *names[] = {"libssl-3-x64.dll", "libssl-3.dll", "libssl.dll"};
#elif defined(__APPLE__)
  const char *names[] = {"libssl.3.dylib", "libssl.dylib"};
#else
  const char *names[] = {"libssl.so.3", "libssl.so.1.1", "libssl.so"};
#endif
  size_t count = sizeof(names) / sizeof(names[0]);
  for (size_t index = 0; index < (configured ? 1 : count); index++) {
    const char *name = configured ? configured : names[index];
#ifdef _WIN32
    tls_api.library = configured
        ? LoadLibraryExA(name, NULL, LOAD_WITH_ALTERED_SEARCH_PATH)
        : LoadLibraryExA(name, NULL, LOAD_LIBRARY_SEARCH_DEFAULT_DIRS);
#else
    tls_api.library = dlopen(name, RTLD_NOW | RTLD_LOCAL);
#endif
    if (tls_api.library) break;
  }
  if (!tls_api.library) { tls_state = -1; leave(); return 0; }
  int ready = 1;
#define TLS_ASSIGN(name) do { void *symbol = tls_symbol(#name); \
  memcpy(&tls_api.name, &symbol, sizeof(symbol)); if (!symbol) ready = 0; } while (0)
  TLS_ASSIGN(TLS_client_method);
  TLS_ASSIGN(SSL_CTX_new);
  TLS_ASSIGN(SSL_CTX_free);
  TLS_ASSIGN(SSL_CTX_set_default_verify_paths);
  TLS_ASSIGN(SSL_CTX_set_verify);
  TLS_ASSIGN(SSL_new);
  TLS_ASSIGN(SSL_free);
  TLS_ASSIGN(SSL_set1_host);
  TLS_ASSIGN(SSL_ctrl);
  TLS_ASSIGN(SSL_set_fd);
  TLS_ASSIGN(SSL_connect);
  TLS_ASSIGN(SSL_get_error);
  TLS_ASSIGN(SSL_get_verify_result);
  TLS_ASSIGN(SSL_write);
  TLS_ASSIGN(SSL_read);
  TLS_ASSIGN(SSL_shutdown);
#undef TLS_ASSIGN
  if (!ready) {
#ifdef _WIN32
    FreeLibrary(tls_api.library);
#else
    dlclose(tls_api.library);
#endif
    memset(&tls_api, 0, sizeof(tls_api));
  }
  tls_state = ready ? 1 : -1;
  leave();
  return ready;
}
FooResult foo_tls_available(void) {
  return (FooResult){.number = (uint64_t)tls_load()};
}
FooResult foo_tls_connect(FooText host, uint64_t port) {
  if (!host.data || !host.len || !port || port > 65535) return failure(ARGUMENT);
  if (!tls_load()) return failure(SYSTEM);
  char *name = string(host);
  if (!name) return failure(ARGUMENT);
  FooResult socket = network(host, port, 0);
  if (socket.error) { free(name); return socket; }
  Socket handle = ((Connection *)socket.pointer)->socket;
  FooText receive = {(const uint8_t *)"receive", 7};
  FooText send = {(const uint8_t *)"send", 4};
  if (socket_timeout(handle, receive, 30000).error ||
      socket_timeout(handle, send, 30000).error) {
    free(name);
    foo_net_close(socket.pointer);
    return failure(IO);
  }
  void *context = tls_api.SSL_CTX_new(tls_api.TLS_client_method());
  void *session = NULL;
  if (context && tls_api.SSL_CTX_set_default_verify_paths(context)) {
    tls_api.SSL_CTX_set_verify(context, 1, NULL);
    session = tls_api.SSL_new(context);
  }
  int valid = session && handle <= INT_MAX &&
    tls_api.SSL_set1_host(session, name) == 1 &&
    tls_api.SSL_ctrl(session, 55, 0, name) == 1 &&
    tls_api.SSL_set_fd(session, (int)handle) == 1 &&
    tls_api.SSL_connect(session) == 1 &&
    tls_api.SSL_get_verify_result(session) == 0;
  free(name);
  if (!valid) {
    if (session) tls_api.SSL_free(session);
    if (context) tls_api.SSL_CTX_free(context);
    foo_net_close(socket.pointer);
    return failure(IO);
  }
  TlsConnection *result = owned(sizeof(*result), TLS_CONNECTIONS);
  if (!result) {
    tls_api.SSL_free(session);
    tls_api.SSL_CTX_free(context);
    foo_net_close(socket.pointer);
    return failure(MEMORY);
  }
  result->context = context;
  result->session = session;
  result->socket = socket.pointer;
  return (FooResult){.pointer = result};
}
FooResult foo_tls_send(void *pointer, FooText content) {
  if (!resource(pointer, TLS_CONNECTIONS)) return failure(CLOSED);
  if (!content.data && content.len) return failure(ARGUMENT);
  TlsConnection *connection = pointer;
  size_t sent = 0;
  while (sent < content.len) {
    size_t size = content.len - sent;
    if (size > INT_MAX) size = INT_MAX;
    int count = tls_api.SSL_write(connection->session, content.data + sent,
                                  (int)size);
    if (count <= 0) return failure(IO);
    sent += (size_t)count;
  }
  return (FooResult){.number = sent};
}
FooResult foo_tls_receive(void *pointer, uint64_t size) {
  if (!resource(pointer, TLS_CONNECTIONS)) return failure(CLOSED);
  if (size > INT_MAX) return failure(BOUNDS);
  if (!size) return (FooResult){0};
  void *buffer = malloc((size_t)size);
  if (!buffer) return failure(MEMORY);
  void *session = ((TlsConnection *)pointer)->session;
  int count = tls_api.SSL_read(session, buffer, (int)size);
  int problem = count <= 0 ? tls_api.SSL_get_error(session, count) : 0;
  FooResult result = count > 0 ? text(buffer, (size_t)count) :
      problem == 6 ? (FooResult){0} : failure(IO);
  free(buffer);
  return result;
}
FooResult foo_tls_timeout(void *pointer, FooText direction,
                          uint64_t milliseconds) {
  if (!resource(pointer, TLS_CONNECTIONS)) return failure(CLOSED);
  Connection *socket = ((TlsConnection *)pointer)->socket;
  return socket_timeout(socket->socket, direction, milliseconds);
}
FooResult foo_tls_close(void *pointer) {
  Resource *entry = resource(pointer, TLS_CONNECTIONS);
  if (!entry) return failure(CLOSED);
  TlsConnection *connection = pointer;
  tls_api.SSL_shutdown(connection->session);
  tls_api.SSL_free(connection->session);
  tls_api.SSL_CTX_free(connection->context);
  FooResult closed = foo_net_close(connection->socket);
  entry->closed = 1;
  return closed;
}
static int parse_numeric(FooText host, int family, uint8_t *bytes) {
  if (!network_init()) return 0;
  char *name = string(host);
  if (!name || !host.len) { free(name); return 0; }
  int valid = inet_pton(family, name, bytes) == 1;
  free(name);
  return valid;
}
static uint64_t address_half(const uint8_t *bytes) {
  uint64_t value = 0;
  for (int index = 0; index < 8; index++) value = (value << 8) | bytes[index];
  return value;
}
FooResult foo_net_parse4(FooText host) {
  uint8_t bytes[4];
  if (!parse_numeric(host, AF_INET, bytes)) return failure(ARGUMENT);
  return (FooResult){.number = ((uint64_t)bytes[0] << 24) |
      ((uint64_t)bytes[1] << 16) | ((uint64_t)bytes[2] << 8) | bytes[3]};
}
FooResult foo_net_parse6high(FooText host) {
  uint8_t bytes[16];
  return parse_numeric(host, AF_INET6, bytes)
      ? (FooResult){.number = address_half(bytes)} : failure(ARGUMENT);
}
FooResult foo_net_parse6low(FooText host) {
  uint8_t bytes[16];
  return parse_numeric(host, AF_INET6, bytes)
      ? (FooResult){.number = address_half(bytes + 8)} : failure(ARGUMENT);
}
FooResult foo_net_format4(uint32_t bits) {
  if (!network_init()) return failure(SYSTEM);
  uint8_t bytes[4] = {(uint8_t)(bits >> 24), (uint8_t)(bits >> 16),
                      (uint8_t)(bits >> 8), (uint8_t)bits};
  char numeric[INET_ADDRSTRLEN];
  if (!inet_ntop(AF_INET, bytes, numeric, sizeof(numeric))) return failure(IO);
  return text(numeric, strlen(numeric));
}
FooResult foo_net_format6(uint64_t high, uint64_t low) {
  if (!network_init()) return failure(SYSTEM);
  uint8_t bytes[16];
  for (int index = 7; index >= 0; index--) {
    bytes[index] = (uint8_t)high;
    bytes[index + 8] = (uint8_t)low;
    high >>= 8;
    low >>= 8;
  }
  char numeric[INET6_ADDRSTRLEN];
  if (!inet_ntop(AF_INET6, bytes, numeric, sizeof(numeric))) return failure(IO);
  return text(numeric, strlen(numeric));
}
FooResult foo_net_lookup(FooText host, FooText family) {
  if (!network_init()) return failure(SYSTEM);
  int selected = family.len == 3 && !memcmp(family.data, "any", 3) ? AF_UNSPEC
      : family.len == 4 && !memcmp(family.data, "ipv4", 4) ? AF_INET
      : family.len == 4 && !memcmp(family.data, "ipv6", 4) ? AF_INET6 : -1;
  if (selected < 0 || !host.len) return failure(ARGUMENT);
  char *name = string(host);
  if (!name) return failure(ARGUMENT);
  struct addrinfo hints = {0}, *addresses = NULL;
  hints.ai_family = selected;
  hints.ai_socktype = SOCK_DGRAM;
  int problem = getaddrinfo(name, NULL, &hints, &addresses);
  free(name);
  if (problem) return failure(MISSING);
  char numeric[INET6_ADDRSTRLEN];
  const void *ip = addresses->ai_family == AF_INET
      ? (const void *)&((struct sockaddr_in *)addresses->ai_addr)->sin_addr
      : (const void *)&((struct sockaddr_in6 *)addresses->ai_addr)->sin6_addr;
  const char *converted = inet_ntop(addresses->ai_family, ip, numeric,
                                   sizeof(numeric));
  FooResult result = converted ? text(numeric, strlen(numeric)) : failure(IO);
  freeaddrinfo(addresses);
  return result;
}
typedef struct {
  char name[256];
  char value[512];
  char kind[6];
  uint32_t ttl;
} DnsEntry;
typedef struct {
  size_t count;
  DnsEntry entries[];
} DnsSet;
static int dns_type(FooText kind) {
  if (kind.len == 1 && !memcmp(kind.data, "a", 1)) return 1;
  if (kind.len == 4 && !memcmp(kind.data, "aaaa", 4)) return 28;
  if (kind.len == 5 && !memcmp(kind.data, "cname", 5)) return 5;
  if (kind.len == 2 && !memcmp(kind.data, "ns", 2)) return 2;
  if (kind.len == 3 && !memcmp(kind.data, "ptr", 3)) return 12;
  if (kind.len == 2 && !memcmp(kind.data, "mx", 2)) return 15;
  if (kind.len == 3 && !memcmp(kind.data, "srv", 3)) return 33;
  if (kind.len == 3 && !memcmp(kind.data, "txt", 3)) return 16;
  return 0;
}
static const char *dns_label(int kind) {
  return kind == 1 ? "a" : kind == 28 ? "aaaa" : kind == 5 ? "cname"
      : kind == 2 ? "ns" : kind == 12 ? "ptr" : kind == 15 ? "mx"
      : kind == 16 ? "txt" : "srv";
}
FooResult foo_net_records(FooText host, FooText kind) {
  if (!network_init()) return failure(SYSTEM);
  int selected = dns_type(kind);
  if (!selected || !host.len) return failure(ARGUMENT);
  char *name = string(host);
  if (!name) return failure(ARGUMENT);
#ifdef _WIN32
  DNS_RECORDA *answers = NULL;
  DNS_STATUS status = DnsQuery_A(name, (WORD)selected, DNS_QUERY_STANDARD,
                                 NULL, (PDNS_RECORD *)&answers, NULL);
  free(name);
  if (status != ERROR_SUCCESS) return failure(MISSING);
  size_t capacity = 0;
  for (DNS_RECORDA *item = answers; item; item = item->pNext) capacity++;
#else
  unsigned char answer[65536];
  int length = res_query(name, ns_c_in, selected, answer, sizeof(answer));
  free(name);
  if (length < 0) return failure(MISSING);
  ns_msg message;
  if (ns_initparse(answer, length, &message) < 0) return failure(IO);
  size_t capacity = (size_t)ns_msg_count(message, ns_s_an);
#endif
  if (capacity > (SIZE_MAX - sizeof(DnsSet)) / sizeof(DnsEntry)) {
#ifdef _WIN32
    DnsRecordListFree(answers, DnsFreeRecordList);
#endif
    return failure(BOUNDS);
  }
  DnsSet *set = owned(sizeof(*set) + capacity * sizeof(DnsEntry), DNS_SETS);
  if (!set) {
#ifdef _WIN32
    DnsRecordListFree(answers, DnsFreeRecordList);
#endif
    return failure(MEMORY);
  }
#ifdef _WIN32
  for (DNS_RECORDA *item = answers; item; item = item->pNext) {
    int type = item->wType;
    if (type != 1 && type != 28 && type != 5 && type != 2 && type != 12 &&
        type != 15 && type != 16 && type != 33) continue;
    DnsEntry *entry = &set->entries[set->count];
    const char *owner = item->pName ? item->pName : "";
    if (strlen(owner) >= sizeof(entry->name)) continue;
    memcpy(entry->name, owner, strlen(owner) + 1);
    strcpy(entry->kind, dns_label(type));
    entry->ttl = item->dwTtl;
    if (type == 16) {
      size_t used = 0;
      bool valid = true;
      for (DWORD part = 0; part < item->Data.TXT.dwStringCount; part++) {
        const char *value = item->Data.TXT.pStringArray[part];
        if (!value) { valid = false; break; }
        size_t length = strlen(value);
        if (length > sizeof(entry->value) - used - 1) { valid = false; break; }
        memcpy(entry->value + used, value, length);
        used += length;
      }
      if (!valid) continue;
      entry->value[used] = 0;
    } else if (type == 5 || type == 2 || type == 12) {
      const char *target = item->Data.CNAME.pNameHost;
      if (!target || strlen(target) >= sizeof(entry->value)) continue;
      memcpy(entry->value, target, strlen(target) + 1);
    } else if (type == 15) {
      const char *target = item->Data.MX.pNameExchange;
      if (!target || snprintf(entry->value, sizeof(entry->value), "%u %s",
                              item->Data.MX.wPreference, target) >=
                         (int)sizeof(entry->value)) continue;
    } else if (type == 33) {
      const char *target = item->Data.SRV.pNameTarget;
      if (!target || snprintf(entry->value, sizeof(entry->value), "%u %u %u %s",
                              item->Data.SRV.wPriority, item->Data.SRV.wWeight,
                              item->Data.SRV.wPort, target) >=
                         (int)sizeof(entry->value)) continue;
    } else {
      const void *bytes = type == 1 ? (const void *)&item->Data.A.IpAddress
          : (const void *)&item->Data.AAAA.Ip6Address;
      if (!inet_ntop(type == 1 ? AF_INET : AF_INET6, bytes, entry->value,
                     sizeof(entry->value))) continue;
    }
    set->count++;
  }
  DnsRecordListFree(answers, DnsFreeRecordList);
#else
  for (size_t index = 0; index < capacity; index++) {
    ns_rr record;
    if (ns_parserr(&message, ns_s_an, (int)index, &record) < 0) continue;
    int type = ns_rr_type(record);
    if (type != 1 && type != 28 && type != 5 && type != 2 && type != 12 &&
        type != 15 && type != 16 && type != 33) continue;
    DnsEntry *entry = &set->entries[set->count];
    const char *owner = ns_rr_name(record);
    if (strlen(owner) >= sizeof(entry->name)) continue;
    memcpy(entry->name, owner, strlen(owner) + 1);
    strcpy(entry->kind, dns_label(type));
    entry->ttl = (uint32_t)ns_rr_ttl(record);
    if (type == 16) {
      const uint8_t *data = ns_rr_rdata(record);
      size_t length = ns_rr_rdlen(record), cursor = 0, used = 0;
      while (cursor < length) {
        size_t part = data[cursor++];
        if (part > length - cursor || part > sizeof(entry->value) - used - 1) break;
        memcpy(entry->value + used, data + cursor, part);
        cursor += part;
        used += part;
      }
      if (cursor != length) continue;
      entry->value[used] = 0;
    } else if (type == 5 || type == 2 || type == 12) {
      if (dn_expand(answer, answer + length, ns_rr_rdata(record),
                    entry->value, sizeof(entry->value)) < 0) continue;
    } else if (type == 15 || type == 33) {
      int header = type == 15 ? 2 : 6;
      if (ns_rr_rdlen(record) < header) continue;
      const uint8_t *data = ns_rr_rdata(record);
      char target[256];
      if (dn_expand(answer, answer + length, data + header,
                    target, sizeof(target)) < 0) continue;
      if (type == 15) {
        unsigned preference = ((unsigned)data[0] << 8) | data[1];
        if (snprintf(entry->value, sizeof(entry->value), "%u %s",
                     preference, target) >= (int)sizeof(entry->value)) continue;
      } else {
        unsigned priority = ((unsigned)data[0] << 8) | data[1];
        unsigned weight = ((unsigned)data[2] << 8) | data[3];
        unsigned port = ((unsigned)data[4] << 8) | data[5];
        if (snprintf(entry->value, sizeof(entry->value), "%u %u %u %s",
                     priority, weight, port, target) >=
            (int)sizeof(entry->value)) continue;
      }
    } else {
      if (ns_rr_rdlen(record) != (type == 1 ? 4 : 16) ||
          !inet_ntop(type == 1 ? AF_INET : AF_INET6, ns_rr_rdata(record),
                     entry->value, sizeof(entry->value))) continue;
    }
    set->count++;
  }
#endif
  return (FooResult){.pointer = set};
}
FooResult foo_net_amount(void *pointer) {
  return resource(pointer, DNS_SETS)
      ? (FooResult){.number = ((DnsSet *)pointer)->count} : failure(CLOSED);
}
static DnsEntry *dns_entry(void *pointer, uint64_t index) {
  if (!resource(pointer, DNS_SETS)) return NULL;
  DnsSet *set = pointer;
  return index < set->count ? &set->entries[index] : NULL;
}
FooResult foo_net_domain(void *pointer, uint64_t index) {
  DnsEntry *entry = dns_entry(pointer, index);
  return entry ? (FooResult){.text = {(const uint8_t *)entry->name,
                                     strlen(entry->name)}} : failure(BOUNDS);
}
FooResult foo_net_datum(void *pointer, uint64_t index) {
  DnsEntry *entry = dns_entry(pointer, index);
  return entry ? (FooResult){.text = {(const uint8_t *)entry->value,
                                     strlen(entry->value)}} : failure(BOUNDS);
}
FooResult foo_net_classification(void *pointer, uint64_t index) {
  DnsEntry *entry = dns_entry(pointer, index);
  return entry ? (FooResult){.text = {(const uint8_t *)entry->kind,
                                     strlen(entry->kind)}} : failure(BOUNDS);
}
FooResult foo_net_ttl(void *pointer, uint64_t index) {
  DnsEntry *entry = dns_entry(pointer, index);
  return entry ? (FooResult){.number = entry->ttl} : failure(BOUNDS);
}
FooResult foo_net_forget(void *pointer) {
  Resource *entry = resource(pointer, DNS_SETS);
  if (!entry) return failure(CLOSED);
  entry->closed = 1;
  return (FooResult){0};
}
typedef struct {
  char name[256];
  char ip[INET6_ADDRSTRLEN];
  uint32_t index;
  uint32_t mtu;
  int family;
} AdapterEntry;
typedef struct {
  size_t count;
  AdapterEntry entries[];
} AdapterList;
FooResult foo_net_adapters(void) {
  if (!network_init()) return failure(SYSTEM);
#ifdef _WIN32
  ULONG length = 15000;
  IP_ADAPTER_ADDRESSES *head = NULL;
  ULONG status = ERROR_BUFFER_OVERFLOW;
  for (int attempt = 0; attempt < 4 && status == ERROR_BUFFER_OVERFLOW; attempt++) {
    IP_ADAPTER_ADDRESSES *next = realloc(head, length);
    if (!next) { free(head); return failure(MEMORY); }
    head = next;
    status = GetAdaptersAddresses(AF_UNSPEC, GAA_FLAG_INCLUDE_PREFIX,
                                  NULL, head, &length);
    if (length > 1 << 20) { free(head); return failure(BOUNDS); }
  }
  if (status != NO_ERROR && status != ERROR_NO_DATA) {
    free(head);
    return failure(IO);
  }
  size_t capacity = 0;
  if (status == NO_ERROR)
    for (IP_ADAPTER_ADDRESSES *adapter = head; adapter; adapter = adapter->Next)
      for (IP_ADAPTER_UNICAST_ADDRESS *ip = adapter->FirstUnicastAddress;
           ip; ip = ip->Next)
        if (ip->Address.lpSockaddr &&
            (ip->Address.lpSockaddr->sa_family == AF_INET ||
             ip->Address.lpSockaddr->sa_family == AF_INET6)) capacity++;
#else
  struct ifaddrs *head = NULL;
  if (getifaddrs(&head)) return failure(IO);
  size_t capacity = 0;
  for (struct ifaddrs *item = head; item; item = item->ifa_next)
    if (item->ifa_addr && (item->ifa_addr->sa_family == AF_INET ||
                           item->ifa_addr->sa_family == AF_INET6)) capacity++;
#endif
  if (capacity > (SIZE_MAX - sizeof(AdapterList)) / sizeof(AdapterEntry)) {
#ifdef _WIN32
    free(head);
#else
    freeifaddrs(head);
#endif
    return failure(BOUNDS);
  }
  AdapterList *list = owned(sizeof(*list) + capacity * sizeof(AdapterEntry),
                            ADAPTER_LISTS);
  if (!list) {
#ifdef _WIN32
    free(head);
#else
    freeifaddrs(head);
#endif
    return failure(MEMORY);
  }
#ifdef _WIN32
  if (status == NO_ERROR)
    for (IP_ADAPTER_ADDRESSES *adapter = head; adapter; adapter = adapter->Next)
      for (IP_ADAPTER_UNICAST_ADDRESS *ip = adapter->FirstUnicastAddress;
           ip; ip = ip->Next) {
        struct sockaddr *address = ip->Address.lpSockaddr;
        if (!address || (address->sa_family != AF_INET &&
                         address->sa_family != AF_INET6)) continue;
        AdapterEntry *entry = &list->entries[list->count];
        const void *bytes = address->sa_family == AF_INET
            ? (const void *)&((struct sockaddr_in *)address)->sin_addr
            : (const void *)&((struct sockaddr_in6 *)address)->sin6_addr;
        if (!inet_ntop(address->sa_family, bytes, entry->ip,
                       sizeof(entry->ip))) continue;
        snprintf(entry->name, sizeof(entry->name), "%s", adapter->AdapterName);
        entry->family = address->sa_family;
        entry->index = address->sa_family == AF_INET
            ? adapter->IfIndex : adapter->Ipv6IfIndex;
        entry->mtu = adapter->Mtu;
        list->count++;
      }
  free(head);
#else
  Socket probe = socket(AF_INET, SOCK_DGRAM, 0);
  for (struct ifaddrs *item = head; item; item = item->ifa_next) {
    if (!item->ifa_addr || (item->ifa_addr->sa_family != AF_INET &&
                            item->ifa_addr->sa_family != AF_INET6)) continue;
    AdapterEntry *entry = &list->entries[list->count];
    const void *bytes = item->ifa_addr->sa_family == AF_INET
        ? (const void *)&((struct sockaddr_in *)item->ifa_addr)->sin_addr
        : (const void *)&((struct sockaddr_in6 *)item->ifa_addr)->sin6_addr;
    if (!inet_ntop(item->ifa_addr->sa_family, bytes, entry->ip,
                   sizeof(entry->ip))) continue;
    snprintf(entry->name, sizeof(entry->name), "%s", item->ifa_name);
    entry->family = item->ifa_addr->sa_family;
    entry->index = if_nametoindex(item->ifa_name);
    if (probe != INVALID) {
      struct ifreq request = {0};
      strncpy(request.ifr_name, item->ifa_name, sizeof(request.ifr_name) - 1);
      if (!ioctl(probe, SIOCGIFMTU, &request) && request.ifr_mtu > 0)
        entry->mtu = (uint32_t)request.ifr_mtu;
    }
    list->count++;
  }
  if (probe != INVALID) disconnect(probe);
  freeifaddrs(head);
#endif
  return (FooResult){.pointer = list};
}
static AdapterEntry *adapter_entry(void *pointer, uint64_t index) {
  if (!resource(pointer, ADAPTER_LISTS)) return NULL;
  AdapterList *list = pointer;
  return index < list->count ? &list->entries[index] : NULL;
}
FooResult foo_net_census(void *pointer) {
  return resource(pointer, ADAPTER_LISTS)
      ? (FooResult){.number = ((AdapterList *)pointer)->count} : failure(CLOSED);
}
FooResult foo_net_caption(void *pointer, uint64_t index) {
  AdapterEntry *entry = adapter_entry(pointer, index);
  return entry ? (FooResult){.text = {(const uint8_t *)entry->name,
                                     strlen(entry->name)}} : failure(BOUNDS);
}
FooResult foo_net_origin(void *pointer, uint64_t index) {
  AdapterEntry *entry = adapter_entry(pointer, index);
  return entry ? (FooResult){.text = {(const uint8_t *)entry->ip,
                                     strlen(entry->ip)}} : failure(BOUNDS);
}
FooResult foo_net_medium(void *pointer, uint64_t index) {
  AdapterEntry *entry = adapter_entry(pointer, index);
  if (!entry) return failure(BOUNDS);
  const char *kind = entry->family == AF_INET ? "ipv4" : "ipv6";
  return (FooResult){.text = {(const uint8_t *)kind, strlen(kind)}};
}
FooResult foo_net_slot(void *pointer, uint64_t index) {
  AdapterEntry *entry = adapter_entry(pointer, index);
  return entry ? (FooResult){.number = entry->index} : failure(BOUNDS);
}
FooResult foo_net_ceiling(void *pointer, uint64_t index) {
  AdapterEntry *entry = adapter_entry(pointer, index);
  return entry ? (FooResult){.number = entry->mtu} : failure(BOUNDS);
}
FooResult foo_net_retire(void *pointer) {
  Resource *entry = resource(pointer, ADAPTER_LISTS);
  if (!entry) return failure(CLOSED);
  entry->closed = 1;
  return (FooResult){0};
}
typedef struct {
  char destination[INET6_ADDRSTRLEN];
  char gateway[INET6_ADDRSTRLEN];
  uint32_t prefix;
  uint32_t index;
  uint32_t metric;
  int family;
} RouteEntry;
typedef struct {
  size_t count;
  RouteEntry entries[];
} RouteList;
static int route_append(RouteEntry **entries, size_t *count, size_t *capacity,
                        const RouteEntry *entry) {
  if (*count == *capacity) {
    if (*capacity > SIZE_MAX / (2 * sizeof(RouteEntry))) return 0;
    size_t next = *capacity ? *capacity * 2 : 16;
    RouteEntry *grown = realloc(*entries, next * sizeof(RouteEntry));
    if (!grown) return 0;
    *entries = grown;
    *capacity = next;
  }
  (*entries)[(*count)++] = *entry;
  return 1;
}
FooResult foo_net_routes(void) {
  if (!network_init()) return failure(SYSTEM);
  RouteEntry *entries = NULL;
  size_t count = 0, capacity = 0;
#ifdef _WIN32
  PMIB_IPFORWARD_TABLE2 table = NULL;
  if (GetIpForwardTable2(AF_UNSPEC, &table) != NO_ERROR) return failure(IO);
  int failed = 0;
  for (ULONG index = 0; index < table->NumEntries; index++) {
    const MIB_IPFORWARD_ROW2 *row = &table->Table[index];
    int family = row->DestinationPrefix.Prefix.si_family;
    if (family != AF_INET && family != AF_INET6) continue;
    RouteEntry entry = {0};
    const void *destination = family == AF_INET
        ? (const void *)&row->DestinationPrefix.Prefix.Ipv4.sin_addr
        : (const void *)&row->DestinationPrefix.Prefix.Ipv6.sin6_addr;
    if (!inet_ntop(family, destination, entry.destination,
                   sizeof(entry.destination))) continue;
    if (row->NextHop.si_family == family) {
      const void *gateway = family == AF_INET
          ? (const void *)&row->NextHop.Ipv4.sin_addr
          : (const void *)&row->NextHop.Ipv6.sin6_addr;
      if (!inet_ntop(family, gateway, entry.gateway,
                     sizeof(entry.gateway))) continue;
    }
    entry.family = family;
    entry.prefix = row->DestinationPrefix.PrefixLength;
    entry.index = row->InterfaceIndex;
    entry.metric = row->Metric;
    if (!route_append(&entries, &count, &capacity, &entry)) { failed = 1; break; }
  }
  FreeMibTable(table);
  if (failed) { free(entries); return failure(MEMORY); }
#elif defined(__linux__)
  Socket route_socket = socket(AF_NETLINK, SOCK_RAW, NETLINK_ROUTE);
  if (route_socket == INVALID) return failure(IO);
  struct {
    struct nlmsghdr header;
    struct rtmsg route;
  } request = {0};
  request.header.nlmsg_len = NLMSG_LENGTH(sizeof(struct rtmsg));
  request.header.nlmsg_type = RTM_GETROUTE;
  request.header.nlmsg_flags = NLM_F_REQUEST | NLM_F_DUMP;
  request.header.nlmsg_seq = 1;
  request.route.rtm_family = AF_UNSPEC;
  if (send(route_socket, &request, request.header.nlmsg_len, 0) < 0) {
    disconnect(route_socket);
    return failure(IO);
  }
  int done = 0, failed = 0;
  while (!done && !failed) {
    char buffer[32768];
    ssize_t length = recv(route_socket, buffer, sizeof(buffer), 0);
    if (length < 0 && errno == EINTR) continue;
    if (length <= 0) { failed = 1; break; }
    int remaining = (int)length;
    for (struct nlmsghdr *header = (struct nlmsghdr *)buffer;
         NLMSG_OK(header, remaining); header = NLMSG_NEXT(header, remaining)) {
      if (header->nlmsg_type == NLMSG_DONE) { done = 1; break; }
      if (header->nlmsg_type == NLMSG_ERROR) { failed = 1; break; }
      if (header->nlmsg_type != RTM_NEWROUTE) continue;
      struct rtmsg *route = NLMSG_DATA(header);
      if (route->rtm_table != RT_TABLE_MAIN ||
          (route->rtm_family != AF_INET && route->rtm_family != AF_INET6))
        continue;
      RouteEntry entry = {0};
      entry.family = route->rtm_family;
      entry.prefix = route->rtm_dst_len;
      uint8_t destination[16] = {0}, gateway[16] = {0};
      int has_gateway = 0, attrs = RTM_PAYLOAD(header);
      for (struct rtattr *attr = RTM_RTA(route); RTA_OK(attr, attrs);
           attr = RTA_NEXT(attr, attrs)) {
        size_t width = entry.family == AF_INET ? 4 : 16;
        if (attr->rta_type == RTA_DST && RTA_PAYLOAD(attr) <= width)
          memcpy(destination, RTA_DATA(attr), RTA_PAYLOAD(attr));
        if (attr->rta_type == RTA_GATEWAY && RTA_PAYLOAD(attr) == width) {
          memcpy(gateway, RTA_DATA(attr), width);
          has_gateway = 1;
        }
        if (attr->rta_type == RTA_OIF && RTA_PAYLOAD(attr) >= sizeof(uint32_t))
          memcpy(&entry.index, RTA_DATA(attr), sizeof(uint32_t));
        if (attr->rta_type == RTA_PRIORITY &&
            RTA_PAYLOAD(attr) >= sizeof(uint32_t))
          memcpy(&entry.metric, RTA_DATA(attr), sizeof(uint32_t));
      }
      if (!inet_ntop(entry.family, destination, entry.destination,
                     sizeof(entry.destination))) continue;
      if (has_gateway && !inet_ntop(entry.family, gateway, entry.gateway,
                                    sizeof(entry.gateway))) continue;
      if (!route_append(&entries, &count, &capacity, &entry)) {
        failed = 1;
        break;
      }
    }
  }
  disconnect(route_socket);
  if (failed) { free(entries); return failure(IO); }
#elif defined(__APPLE__)
  int query[6] = {CTL_NET, PF_ROUTE, 0, AF_UNSPEC, NET_RT_DUMP, 0};
  size_t length = 0;
  if (sysctl(query, 6, NULL, &length, NULL, 0)) return failure(IO);
  char *buffer = malloc(length ? length : 1);
  if (!buffer) return failure(MEMORY);
  if (sysctl(query, 6, buffer, &length, NULL, 0)) {
    free(buffer);
    return failure(IO);
  }
  int failed = 0;
  char *end = buffer + length;
  for (char *cursor = buffer; cursor + sizeof(struct rt_msghdr) <= end;) {
    struct rt_msghdr *message = (struct rt_msghdr *)cursor;
    if (message->rtm_msglen < sizeof(*message) ||
        cursor + message->rtm_msglen > end) { failed = 1; break; }
    char *message_end = cursor + message->rtm_msglen;
    struct sockaddr *addresses[RTAX_MAX] = {0};
    char *part = (char *)(message + 1);
    for (int index = 0; index < RTAX_MAX; index++) {
      if (!(message->rtm_addrs & (1 << index))) continue;
      if (part + 2 > message_end) { failed = 1; break; }
      struct sockaddr *address = (struct sockaddr *)part;
      size_t width = address->sa_len ? address->sa_len : sizeof(long);
      size_t aligned = (width + sizeof(long) - 1) & ~(sizeof(long) - 1);
      if (part + aligned > message_end) { failed = 1; break; }
      addresses[index] = address;
      part += aligned;
    }
    if (failed) break;
    struct sockaddr *destination = addresses[RTAX_DST];
    if (destination && (destination->sa_family == AF_INET ||
                        destination->sa_family == AF_INET6)) {
      RouteEntry entry = {0};
      entry.family = destination->sa_family;
      size_t offset = entry.family == AF_INET
          ? offsetof(struct sockaddr_in, sin_addr)
          : offsetof(struct sockaddr_in6, sin6_addr);
      size_t width = entry.family == AF_INET ? 4 : 16;
      uint8_t destination_bytes[16] = {0};
      if (destination->sa_len > offset) {
        size_t available = destination->sa_len - offset;
        if (available > width) available = width;
        memcpy(destination_bytes, (char *)destination + offset, available);
      }
      if (inet_ntop(entry.family, destination_bytes, entry.destination,
                    sizeof(entry.destination))) {
        struct sockaddr *gateway = addresses[RTAX_GATEWAY];
        if (gateway && gateway->sa_family == entry.family &&
            gateway->sa_len >= offset + width)
          inet_ntop(entry.family, (char *)gateway + offset, entry.gateway,
                    sizeof(entry.gateway));
        entry.prefix = (message->rtm_flags & RTF_HOST) ? (uint32_t)(width * 8) : 0;
        struct sockaddr *mask = addresses[RTAX_NETMASK];
        if (mask && mask->sa_len > offset) {
          size_t bytes = mask->sa_len - offset;
          if (bytes > width) bytes = width;
          const uint8_t *bits = (const uint8_t *)mask + offset;
          entry.prefix = 0;
          for (size_t index = 0; index < bytes; index++)
            for (int bit = 0; bit < 8; bit++)
              entry.prefix += (bits[index] >> bit) & 1;
        }
        entry.index = message->rtm_index;
        entry.metric = message->rtm_rmx.rmx_hopcount;
        if (!route_append(&entries, &count, &capacity, &entry)) {
          failed = 1;
          break;
        }
      }
    }
    cursor = message_end;
  }
  free(buffer);
  if (failed) { free(entries); return failure(IO); }
#else
  return failure(SYSTEM);
#endif
  if (count > (SIZE_MAX - sizeof(RouteList)) / sizeof(RouteEntry)) {
    free(entries);
    return failure(BOUNDS);
  }
  RouteList *list = owned(sizeof(*list) + count * sizeof(RouteEntry),
                          ROUTE_LISTS);
  if (!list) { free(entries); return failure(MEMORY); }
  list->count = count;
  if (count) memcpy(list->entries, entries, count * sizeof(RouteEntry));
  free(entries);
  return (FooResult){.pointer = list};
}
static RouteEntry *route_entry(void *pointer, uint64_t index) {
  if (!resource(pointer, ROUTE_LISTS)) return NULL;
  RouteList *list = pointer;
  return index < list->count ? &list->entries[index] : NULL;
}
FooResult foo_net_tally(void *pointer) {
  return resource(pointer, ROUTE_LISTS)
      ? (FooResult){.number = ((RouteList *)pointer)->count} : failure(CLOSED);
}
FooResult foo_net_target(void *pointer, uint64_t index) {
  RouteEntry *entry = route_entry(pointer, index);
  return entry ? (FooResult){.text = {(const uint8_t *)entry->destination,
                                     strlen(entry->destination)}} : failure(BOUNDS);
}
FooResult foo_net_via(void *pointer, uint64_t index) {
  RouteEntry *entry = route_entry(pointer, index);
  return entry ? (FooResult){.text = {(const uint8_t *)entry->gateway,
                                     strlen(entry->gateway)}} : failure(BOUNDS);
}
FooResult foo_net_protocol(void *pointer, uint64_t index) {
  RouteEntry *entry = route_entry(pointer, index);
  if (!entry) return failure(BOUNDS);
  const char *kind = entry->family == AF_INET ? "ipv4" : "ipv6";
  return (FooResult){.text = {(const uint8_t *)kind, strlen(kind)}};
}
FooResult foo_net_mask(void *pointer, uint64_t index) {
  RouteEntry *entry = route_entry(pointer, index);
  return entry ? (FooResult){.number = entry->prefix} : failure(BOUNDS);
}
FooResult foo_net_ordinal(void *pointer, uint64_t index) {
  RouteEntry *entry = route_entry(pointer, index);
  return entry ? (FooResult){.number = entry->index} : failure(BOUNDS);
}
FooResult foo_net_cost(void *pointer, uint64_t index) {
  RouteEntry *entry = route_entry(pointer, index);
  return entry ? (FooResult){.number = entry->metric} : failure(BOUNDS);
}
FooResult foo_net_dismiss(void *pointer) {
  Resource *entry = resource(pointer, ROUTE_LISTS);
  if (!entry) return failure(CLOSED);
  entry->closed = 1;
  return (FooResult){0};
}
FooResult foo_net_bind(FooText host, uint64_t port) {
  if (port > 65535) return failure(BOUNDS);
  if (!network_init()) return failure(SYSTEM);
  char *name = string(host), service[6];
  if (!name) return failure(ARGUMENT);
  snprintf(service, sizeof(service), "%u", (unsigned)port);
  struct addrinfo hints = {0}, *addresses = NULL;
  hints.ai_family = AF_UNSPEC;
  hints.ai_socktype = SOCK_DGRAM;
  hints.ai_flags = AI_PASSIVE;
  int problem = getaddrinfo(*name ? name : NULL, service, &hints, &addresses);
  free(name);
  if (problem) return failure(SYSTEM);
  Socket handle = INVALID;
  for (struct addrinfo *address = addresses; address; address = address->ai_next) {
    handle = socket(address->ai_family, address->ai_socktype,
                    address->ai_protocol);
    if (handle != INVALID &&
        !bind(handle, address->ai_addr, (int)address->ai_addrlen)) break;
    if (handle != INVALID) disconnect(handle);
    handle = INVALID;
  }
  freeaddrinfo(addresses);
  return handle == INVALID ? failure(IO) : socket_resource(handle, DATAGRAMS);
}
FooResult foo_net_local(void *pointer) {
  if (!resource(pointer, DATAGRAMS)) return failure(CLOSED);
  struct sockaddr_storage address;
#ifdef _WIN32
  int length = sizeof(address);
#else
  socklen_t length = sizeof(address);
#endif
  if (getsockname(((Connection *)pointer)->socket,
                  (struct sockaddr *)&address, &length)) return failure(IO);
  return (FooResult){.number = ntohs(address.ss_family == AF_INET
      ? ((struct sockaddr_in *)&address)->sin_port
      : ((struct sockaddr_in6 *)&address)->sin6_port)};
}
static int socket_family(void *pointer) {
  struct sockaddr_storage address;
#ifdef _WIN32
  int length = sizeof(address);
#else
  socklen_t length = sizeof(address);
#endif
  return getsockname(((Connection *)pointer)->socket,
                     (struct sockaddr *)&address, &length) ? -1
                                                       : address.ss_family;
}
FooResult foo_net_egress(void *pointer, uint64_t index) {
  if (!resource(pointer, DATAGRAMS)) return failure(CLOSED);
  if (index > UINT32_MAX) return failure(BOUNDS);
  if (socket_family(pointer) != AF_INET) return failure(ARGUMENT);
#ifdef IP_UNICAST_IF
  uint32_t selected = htonl((uint32_t)index);
  return setsockopt(((Connection *)pointer)->socket, IPPROTO_IP,
                    IP_UNICAST_IF, (const char *)&selected, sizeof(selected))
      ? failure(IO) : (FooResult){0};
#elif defined(IP_BOUND_IF)
  int selected = (int)index;
  return setsockopt(((Connection *)pointer)->socket, IPPROTO_IP,
                    IP_BOUND_IF, (const char *)&selected, sizeof(selected))
      ? failure(IO) : (FooResult){0};
#else
  return failure(SYSTEM);
#endif
}
FooResult foo_net_affiliate(void *pointer, FooText host, uint64_t port) {
  if (!resource(pointer, DATAGRAMS)) return failure(CLOSED);
  if (port > 65535) return failure(BOUNDS);
  int family = socket_family(pointer);
  if (family != AF_INET && family != AF_INET6) return failure(IO);
  char *name = string(host), service[6];
  if (!name || !host.len) { free(name); return failure(ARGUMENT); }
  snprintf(service, sizeof(service), "%u", (unsigned)port);
  struct addrinfo hints = {0}, *addresses = NULL;
  hints.ai_family = family;
  hints.ai_socktype = SOCK_DGRAM;
  int problem = getaddrinfo(name, service, &hints, &addresses);
  free(name);
  if (problem) return failure(MISSING);
  int connected = -1;
  for (struct addrinfo *address = addresses; address; address = address->ai_next) {
    connected = connect(((Connection *)pointer)->socket, address->ai_addr,
                        (int)address->ai_addrlen);
    if (!connected) break;
  }
  freeaddrinfo(addresses);
  return connected ? failure(IO) : (FooResult){0};
}
FooResult foo_net_affiliate6(void *pointer, uint64_t high, uint64_t low,
                                 uint64_t port, uint64_t scope) {
  if (!resource(pointer, DATAGRAMS)) return failure(CLOSED);
  if (socket_family(pointer) != AF_INET6 || scope > UINT32_MAX)
    return failure(ARGUMENT);
  if (port > 65535) return failure(BOUNDS);
  struct sockaddr_in6 address = {0};
  address.sin6_family = AF_INET6;
  address.sin6_port = htons((uint16_t)port);
  address.sin6_scope_id = (uint32_t)scope;
  for (int index = 7; index >= 0; index--) {
    address.sin6_addr.s6_addr[index] = (uint8_t)high;
    address.sin6_addr.s6_addr[index + 8] = (uint8_t)low;
    high >>= 8;
    low >>= 8;
  }
  return connect(((Connection *)pointer)->socket, (struct sockaddr *)&address,
                 sizeof(address)) ? failure(IO) : (FooResult){0};
}
FooResult foo_net_submit(void *pointer, FooText content) {
  if (!resource(pointer, DATAGRAMS)) return failure(CLOSED);
  if (content.len > 65507) return failure(BOUNDS);
  if (content.len && !content.data) return failure(ARGUMENT);
  struct sockaddr_storage peer;
#ifdef _WIN32
  int length = sizeof(peer);
#else
  socklen_t length = sizeof(peer);
#endif
  if (getpeername(((Connection *)pointer)->socket,
                  (struct sockaddr *)&peer, &length)) return failure(ARGUMENT);
  int sent;
  do {
    sent = send(((Connection *)pointer)->socket,
                (const char *)(content.data ? content.data : (const uint8_t *)""),
                (int)content.len, 0);
  } while (sent < 0 && interrupted());
  return sent < 0 || (size_t)sent != content.len ? failure(IO)
      : (FooResult){.number = (uint64_t)sent};
}
FooResult foo_net_broadcast(void *pointer, bool enabled) {
  if (!resource(pointer, DATAGRAMS)) return failure(CLOSED);
  if (socket_family(pointer) != AF_INET) return failure(ARGUMENT);
  int value = enabled ? 1 : 0;
  return setsockopt(((Connection *)pointer)->socket, SOL_SOCKET, SO_BROADCAST,
                    (const char *)&value, sizeof(value)) ? failure(IO)
                                                           : (FooResult){0};
}
static FooResult socket_option(void *pointer, int level, int option,
                               int value, bool change) {
  Socket handle = ((Connection *)pointer)->socket;
  if (change && setsockopt(handle, level, option, (const char *)&value,
                           sizeof(value))) return failure(IO);
  int actual = 0;
#ifdef _WIN32
  int length = sizeof(actual);
#else
  socklen_t length = sizeof(actual);
#endif
  if (getsockopt(handle, level, option, (char *)&actual, &length) ||
      length != sizeof(actual) || actual < 0) return failure(IO);
  return (FooResult){.number = (uint64_t)actual};
}
static int socket_buffer_direction(FooText direction) {
  if (direction.data && direction.len == 4 &&
      !memcmp(direction.data, "send", 4)) return SO_SNDBUF;
  if (direction.data && direction.len == 7 &&
      !memcmp(direction.data, "receive", 7)) return SO_RCVBUF;
  return -1;
}
FooResult foo_net_supply(void *pointer, FooText direction, uint64_t size) {
  if (!resource(pointer, SOCKETS)) return failure(CLOSED);
  int option = socket_buffer_direction(direction);
  if (option < 0) return failure(ARGUMENT);
  if (!size || size > INT_MAX) return failure(BOUNDS);
  return socket_option(pointer, SOL_SOCKET, option, (int)size, true);
}
FooResult foo_net_allocated(void *pointer, FooText direction) {
  if (!resource(pointer, SOCKETS)) return failure(CLOSED);
  int option = socket_buffer_direction(direction);
  if (option < 0) return failure(ARGUMENT);
  return socket_option(pointer, SOL_SOCKET, option, 0, false);
}
FooResult foo_net_expire(void *pointer, uint64_t hops) {
  if (!resource(pointer, SOCKETS)) return failure(CLOSED);
  if (!hops || hops > 255) return failure(BOUNDS);
  int family = socket_family(pointer);
  if (family == AF_INET)
    return socket_option(pointer, IPPROTO_IP, IP_TTL, (int)hops, true);
  if (family == AF_INET6)
    return socket_option(pointer, IPPROTO_IPV6, IPV6_UNICAST_HOPS,
                         (int)hops, true);
  return failure(IO);
}
FooResult foo_net_classify(void *pointer, uint64_t value) {
  if (!resource(pointer, SOCKETS)) return failure(CLOSED);
  if (value > 255) return failure(BOUNDS);
  int family = socket_family(pointer);
  if (family == AF_INET)
    return socket_option(pointer, IPPROTO_IP, IP_TOS, (int)value, true);
#ifdef IPV6_TCLASS
  if (family == AF_INET6)
    return socket_option(pointer, IPPROTO_IPV6, IPV6_TCLASS,
                         (int)value, true);
#endif
  return failure(SYSTEM);
}
FooResult foo_net_unicast(void *pointer, uint64_t hops) {
  if (!resource(pointer, DATAGRAMS)) return failure(CLOSED);
  if (!hops || hops > 255) return failure(BOUNDS);
  int family = socket_family(pointer);
  if (family == AF_INET)
    return socket_option(pointer, IPPROTO_IP, IP_TTL, (int)hops, true);
  if (family == AF_INET6)
    return socket_option(pointer, IPPROTO_IPV6, IPV6_UNICAST_HOPS,
                           (int)hops, true);
  return failure(IO);
}
FooResult foo_net_traffic(void *pointer, uint64_t value) {
  if (!resource(pointer, DATAGRAMS)) return failure(CLOSED);
  if (value > 255) return failure(BOUNDS);
  int family = socket_family(pointer);
  if (family == AF_INET)
    return socket_option(pointer, IPPROTO_IP, IP_TOS, (int)value, true);
#ifdef IPV6_TCLASS
  if (family == AF_INET6)
    return socket_option(pointer, IPPROTO_IPV6, IPV6_TCLASS,
                           (int)value, true);
#endif
  return failure(SYSTEM);
}
FooResult foo_net_buffer(void *pointer, FooText direction, uint64_t size) {
  if (!resource(pointer, DATAGRAMS)) return failure(CLOSED);
  int option = socket_buffer_direction(direction);
  if (option < 0) return failure(ARGUMENT);
  if (!size || size > INT_MAX) return failure(BOUNDS);
  return socket_option(pointer, SOL_SOCKET, option, (int)size, true);
}
FooResult foo_net_capacity(void *pointer, FooText direction) {
  if (!resource(pointer, DATAGRAMS)) return failure(CLOSED);
  int option = socket_buffer_direction(direction);
  if (option < 0) return failure(ARGUMENT);
  return socket_option(pointer, SOL_SOCKET, option, 0, false);
}
FooResult foo_net_deadline(void *pointer, FooText direction,
                                  uint64_t milliseconds) {
  if (!resource(pointer, DATAGRAMS)) return failure(CLOSED);
  return socket_timeout(((Connection *)pointer)->socket, direction, milliseconds);
}
FooResult foo_net_choose4(void *pointer, uint32_t adapter) {
  if (!resource(pointer, DATAGRAMS)) return failure(CLOSED);
  if (socket_family(pointer) != AF_INET) return failure(ARGUMENT);
  struct in_addr address = {.s_addr = htonl(adapter)};
  return setsockopt(((Connection *)pointer)->socket, IPPROTO_IP,
                    IP_MULTICAST_IF, (const char *)&address, sizeof(address))
      ? failure(IO) : (FooResult){0};
}
FooResult foo_net_choose6(void *pointer, uint64_t adapter) {
  if (!resource(pointer, DATAGRAMS)) return failure(CLOSED);
  if (socket_family(pointer) != AF_INET6 || adapter > UINT32_MAX)
    return failure(ARGUMENT);
  unsigned value = (unsigned)adapter;
  return setsockopt(((Connection *)pointer)->socket, IPPROTO_IPV6,
                    IPV6_MULTICAST_IF, (const char *)&value, sizeof(value))
      ? failure(IO) : (FooResult){0};
}
FooResult foo_net_radius(void *pointer, uint64_t hops) {
  if (!resource(pointer, DATAGRAMS)) return failure(CLOSED);
  if (hops > 255) return failure(BOUNDS);
  int family = socket_family(pointer);
  if (family != AF_INET && family != AF_INET6) return failure(IO);
  int value = (int)hops;
  return setsockopt(((Connection *)pointer)->socket,
                    family == AF_INET ? IPPROTO_IP : IPPROTO_IPV6,
                    family == AF_INET ? IP_MULTICAST_TTL : IPV6_MULTICAST_HOPS,
                    (const char *)&value, sizeof(value)) ? failure(IO)
                                                        : (FooResult){0};
}
FooResult foo_net_recirculate(void *pointer, bool enabled) {
  if (!resource(pointer, DATAGRAMS)) return failure(CLOSED);
  int family = socket_family(pointer);
  if (family != AF_INET && family != AF_INET6) return failure(IO);
  int value = enabled ? 1 : 0;
  return setsockopt(((Connection *)pointer)->socket,
                    family == AF_INET ? IPPROTO_IP : IPPROTO_IPV6,
                    family == AF_INET ? IP_MULTICAST_LOOP : IPV6_MULTICAST_LOOP,
                    (const char *)&value, sizeof(value)) ? failure(IO)
                                                        : (FooResult){0};
}
FooResult foo_net_membership4(void *pointer, uint32_t group,
                               uint32_t adapter, bool enabled) {
  if (!resource(pointer, DATAGRAMS)) return failure(CLOSED);
  if (socket_family(pointer) != AF_INET || (group >> 28) != 14)
    return failure(ARGUMENT);
  struct ip_mreq membership = {0};
  membership.imr_multiaddr.s_addr = htonl(group);
  membership.imr_interface.s_addr = htonl(adapter);
  return setsockopt(((Connection *)pointer)->socket, IPPROTO_IP,
                    enabled ? IP_ADD_MEMBERSHIP : IP_DROP_MEMBERSHIP,
                    (const char *)&membership, sizeof(membership))
      ? failure(IO) : (FooResult){0};
}
FooResult foo_net_membership6(void *pointer, uint64_t high, uint64_t low,
                               uint64_t adapter, bool enabled) {
  if (!resource(pointer, DATAGRAMS)) return failure(CLOSED);
  if (socket_family(pointer) != AF_INET6 || (high >> 56) != 0xff ||
      adapter > UINT32_MAX) return failure(ARGUMENT);
  struct ipv6_mreq membership = {0};
  for (int index = 7; index >= 0; index--) {
    membership.ipv6mr_multiaddr.s6_addr[index] = (uint8_t)high;
    membership.ipv6mr_multiaddr.s6_addr[index + 8] = (uint8_t)low;
    high >>= 8;
    low >>= 8;
  }
  membership.ipv6mr_interface = (unsigned)adapter;
  return setsockopt(((Connection *)pointer)->socket, IPPROTO_IPV6,
                    enabled ? IPV6_JOIN_GROUP : IPV6_LEAVE_GROUP,
                    (const char *)&membership, sizeof(membership))
      ? failure(IO) : (FooResult){0};
}
FooResult foo_net_transmit(void *pointer, FooText host, uint64_t port,
                           FooText content) {
  if (!resource(pointer, DATAGRAMS)) return failure(CLOSED);
  if (port > 65535 || content.len > 65507) return failure(BOUNDS);
  if (content.len && !content.data) return failure(ARGUMENT);
  char *name = string(host), service[6];
  if (!name || !host.len) { free(name); return failure(ARGUMENT); }
  snprintf(service, sizeof(service), "%u", (unsigned)port);
  struct sockaddr_storage local;
#ifdef _WIN32
  int local_length = sizeof(local);
#else
  socklen_t local_length = sizeof(local);
#endif
  if (getsockname(((Connection *)pointer)->socket,
                  (struct sockaddr *)&local, &local_length)) {
    free(name);
    return failure(IO);
  }
  struct addrinfo hints = {0}, *addresses = NULL;
  hints.ai_family = local.ss_family;
  hints.ai_socktype = SOCK_DGRAM;
  int problem = getaddrinfo(name, service, &hints, &addresses);
  free(name);
  if (problem) return failure(MISSING);
  int sent = -1;
  for (struct addrinfo *address = addresses; address; address = address->ai_next) {
    do {
      sent = sendto(((Connection *)pointer)->socket,
          (const char *)(content.data ? content.data : (const uint8_t *)""),
          (int)content.len, 0, address->ai_addr, (int)address->ai_addrlen);
    } while (sent < 0 && interrupted());
    if (sent >= 0) break;
  }
  freeaddrinfo(addresses);
  return sent < 0 || (size_t)sent != content.len ? failure(IO)
      : (FooResult){.number = (uint64_t)sent};
}
FooResult foo_net_transmit6(void *pointer, uint64_t high, uint64_t low,
                               uint64_t port, uint64_t scope, FooText content) {
  if (!resource(pointer, DATAGRAMS)) return failure(CLOSED);
  if (socket_family(pointer) != AF_INET6 || scope > UINT32_MAX)
    return failure(ARGUMENT);
  if (port > 65535 || content.len > 65507) return failure(BOUNDS);
  if (content.len && !content.data) return failure(ARGUMENT);
  struct sockaddr_in6 address = {0};
  address.sin6_family = AF_INET6;
  address.sin6_port = htons((uint16_t)port);
  address.sin6_scope_id = (uint32_t)scope;
  for (int index = 7; index >= 0; index--) {
    address.sin6_addr.s6_addr[index] = (uint8_t)high;
    address.sin6_addr.s6_addr[index + 8] = (uint8_t)low;
    high >>= 8;
    low >>= 8;
  }
  int sent;
  do {
    sent = sendto(((Connection *)pointer)->socket,
                  (const char *)(content.data ? content.data : (const uint8_t *)""),
                  (int)content.len, 0, (struct sockaddr *)&address,
                  sizeof(address));
  } while (sent < 0 && interrupted());
  return sent < 0 || (size_t)sent != content.len ? failure(IO)
      : (FooResult){.number = (uint64_t)sent};
}
FooResult foo_net_collect(void *pointer, uint64_t size) {
  if (!resource(pointer, DATAGRAMS)) return failure(CLOSED);
  if (size > 65535) return failure(BOUNDS);
  uint8_t *buffer = malloc(65536);
  if (!buffer) return failure(MEMORY);
  struct sockaddr_storage address;
#ifdef _WIN32
  int length = sizeof(address);
#else
  socklen_t length = sizeof(address);
#endif
  int received;
  do {
    received = recvfrom(((Connection *)pointer)->socket, (char *)buffer, 65536,
                        0, (struct sockaddr *)&address, &length);
  } while (received < 0 && interrupted());
  if (received < 0 || (address.ss_family != AF_INET &&
                       address.ss_family != AF_INET6)) {
    free(buffer);
    return failure(IO);
  }
  if ((uint64_t)received > size) { free(buffer); return failure(BOUNDS); }
  const void *ip = address.ss_family == AF_INET
      ? (const void *)&((struct sockaddr_in *)&address)->sin_addr
      : (const void *)&((struct sockaddr_in6 *)&address)->sin6_addr;
  char numeric[INET6_ADDRSTRLEN];
  if (!inet_ntop(address.ss_family, ip, numeric, sizeof(numeric))) {
    free(buffer);
    return failure(IO);
  }
  Packet *packet = owned(sizeof(*packet), PACKETS);
  if (!packet) { free(buffer); return failure(MEMORY); }
  memcpy(packet->host, numeric, strlen(numeric) + 1);
  packet->data = buffer;
  packet->length = (size_t)received;
  packet->address = address;
  packet->port = ntohs(address.ss_family == AF_INET
      ? ((struct sockaddr_in *)&address)->sin_port
      : ((struct sockaddr_in6 *)&address)->sin6_port);
  return (FooResult){.pointer = packet};
}
FooResult foo_net_raw(void *pointer) {
  if (!resource(pointer, PACKETS)) return failure(CLOSED);
  Packet *packet = pointer;
  return (FooResult){.text = {packet->data, packet->length}};
}
FooResult foo_net_peer(void *pointer) {
  if (!resource(pointer, PACKETS)) return failure(CLOSED);
  Packet *packet = pointer;
  return (FooResult){.text = {(const uint8_t *)packet->host,
                             strlen(packet->host)}};
}
FooResult foo_net_peer4(void *pointer) {
  if (!resource(pointer, PACKETS)) return failure(CLOSED);
  Packet *packet = pointer;
  if (packet->address.ss_family != AF_INET) return failure(ARGUMENT);
  return (FooResult){.number = ntohl(
      ((struct sockaddr_in *)&packet->address)->sin_addr.s_addr)};
}
static FooResult peer6part(void *pointer, int offset) {
  if (!resource(pointer, PACKETS)) return failure(CLOSED);
  Packet *packet = pointer;
  if (packet->address.ss_family != AF_INET6) return failure(ARGUMENT);
  const uint8_t *bytes = ((struct sockaddr_in6 *)&packet->address)->sin6_addr.s6_addr;
  uint64_t value = 0;
  for (int index = offset; index < offset + 8; index++)
    value = (value << 8) | bytes[index];
  return (FooResult){.number = value};
}
FooResult foo_net_peer6high(void *pointer) { return peer6part(pointer, 0); }
FooResult foo_net_peer6low(void *pointer) { return peer6part(pointer, 8); }
FooResult foo_net_zone(void *pointer) {
  if (!resource(pointer, PACKETS)) return failure(CLOSED);
  Packet *packet = pointer;
  if (packet->address.ss_family != AF_INET6) return failure(ARGUMENT);
  return (FooResult){.number =
      ((struct sockaddr_in6 *)&packet->address)->sin6_scope_id};
}
FooResult foo_net_source(void *pointer) {
  if (!resource(pointer, PACKETS)) return failure(CLOSED);
  return (FooResult){.number = ((Packet *)pointer)->port};
}
FooResult foo_net_discard(void *pointer) {
  Resource *entry = resource(pointer, PACKETS);
  if (!entry) return failure(CLOSED);
  Packet *packet = pointer;
  free(packet->data);
  packet->data = NULL;
  entry->closed = 1;
  return (FooResult){0};
}
FooResult foo_net_detach(void *pointer) {
  Resource *entry = resource(pointer, DATAGRAMS);
  if (!entry) return failure(CLOSED);
  int problem = disconnect(((Connection *)pointer)->socket);
  entry->closed = 1;
  return problem ? failure(IO) : (FooResult){0};
}

enum { POLL_LIMIT = 128 };
typedef struct {
  void *socket;
  uint64_t token;
  uint64_t deadline;
  int kind;
  short mode;
} PollWatch;
typedef struct {
  PollWatch watches[POLL_LIMIT];
  size_t count;
  size_t cursor;
} Poller;
#ifdef _WIN32
typedef WSAPOLLFD PollDescriptor;
#define FOO_POLL_READ POLLRDNORM
#define FOO_POLL_WRITE POLLWRNORM
#else
typedef struct pollfd PollDescriptor;
#define FOO_POLL_READ POLLIN
#define FOO_POLL_WRITE POLLOUT
#endif

FooResult foo_net_watch(void) {
  Poller *poller = owned(sizeof(*poller), POLLERS);
  return poller ? (FooResult){.pointer = poller} : failure(MEMORY);
}
static FooResult poll_add(void *pointer, void *socket, FooText direction,
                          uint64_t token, int kind) {
  if (!resource(pointer, POLLERS)) return failure(CLOSED);
  if (!resource(socket, kind)) return failure(CLOSED);
  short mode = cpu_named(direction, "receive") ? FOO_POLL_READ :
               cpu_named(direction, "send") ? FOO_POLL_WRITE : 0;
  if (!mode || !token) return failure(ARGUMENT);
  Poller *poller = pointer;
  for (size_t index = 0; index < poller->count; index++)
    if (poller->watches[index].token == token) return failure(ARGUMENT);
  if (poller->count == POLL_LIMIT) return failure(BOUNDS);
  poller->watches[poller->count++] = (PollWatch){
      .socket = socket, .token = token, .kind = kind, .mode = mode};
  return (FooResult){0};
}
FooResult foo_net_stream(void *pointer, void *socket, FooText direction,
                           uint64_t token) {
  return poll_add(pointer, socket, direction, token, SOCKETS);
}
FooResult foo_net_packet(void *pointer, void *socket, FooText direction,
                           uint64_t token) {
  return poll_add(pointer, socket, direction, token, DATAGRAMS);
}
FooResult foo_net_process(void *pointer, void *child, uint64_t token) {
  if (!resource(pointer, POLLERS) || !resource(child, CHILDREN)) return failure(CLOSED);
  if (!token) return failure(ARGUMENT);
  Poller *poller = pointer;
  for (size_t index = 0; index < poller->count; index++)
    if (poller->watches[index].token == token) return failure(ARGUMENT);
  if (poller->count == POLL_LIMIT) return failure(BOUNDS);
  poller->watches[poller->count++] = (PollWatch){
      .socket = child, .token = token, .kind = CHILDREN};
  return (FooResult){0};
}
FooResult foo_net_alarm(void *pointer, uint64_t token,
                             uint64_t milliseconds) {
  if (!resource(pointer, POLLERS)) return failure(CLOSED);
  if (!token) return failure(ARGUMENT);
  if (milliseconds > INT_MAX) return failure(BOUNDS);
  Poller *poller = pointer;
  for (size_t index = 0; index < poller->count; index++)
    if (poller->watches[index].token == token) return failure(ARGUMENT);
  if (poller->count == POLL_LIMIT) return failure(BOUNDS);
  FooResult now = foo_time_current();
  if (now.error) return now;
  uint64_t duration = milliseconds * UINT64_C(1000000);
  if (duration > UINT64_MAX - now.number) return failure(BOUNDS);
  poller->watches[poller->count++] = (PollWatch){
      .token = token, .deadline = now.number + duration};
  return (FooResult){0};
}
FooResult foo_net_unwatch(void *pointer, uint64_t token) {
  if (!resource(pointer, POLLERS)) return failure(CLOSED);
  Poller *poller = pointer;
  for (size_t index = 0; index < poller->count; index++) {
    if (poller->watches[index].token != token) continue;
    memmove(&poller->watches[index], &poller->watches[index + 1],
            (poller->count - index - 1) * sizeof(PollWatch));
    poller->count--;
    if (poller->cursor >= poller->count) poller->cursor = 0;
    return (FooResult){0};
  }
  return failure(MISSING);
}
FooResult foo_net_ready(void *pointer, uint64_t milliseconds) {
  if (!resource(pointer, POLLERS)) return failure(CLOSED);
  if (milliseconds > INT_MAX) return failure(BOUNDS);
  Poller *poller = pointer;
  FooResult now = foo_time_current();
  if (now.error) return now;
  uint64_t duration = milliseconds * UINT64_C(1000000);
  if (duration > UINT64_MAX - now.number) return failure(BOUNDS);
  uint64_t limit = now.number + duration;
  for (;;) {
    now = foo_time_current();
    if (now.error) return now;
    uint64_t nearest = limit;
    bool children = false;
    for (size_t index = 0; index < poller->count; index++) {
      PollWatch *watch = &poller->watches[index];
      if (watch->kind == CHILDREN) {
        FooResult active = foo_process_active(watch->socket);
        if (active.error) return active;
        if (!active.number) return (FooResult){.number = watch->token};
        children = true;
        continue;
      }
      if (watch->kind) continue;
      if (watch->deadline <= now.number) {
        uint64_t token = watch->token;
        memmove(watch, watch + 1,
                (poller->count - index - 1) * sizeof(PollWatch));
        poller->count--;
        if (poller->cursor >= poller->count) poller->cursor = 0;
        return (FooResult){.number = token};
      }
      if (watch->deadline < nearest) nearest = watch->deadline;
    }
    PollDescriptor descriptors[POLL_LIMIT];
    size_t indices[POLL_LIMIT], count = 0;
    for (size_t index = 0; index < poller->count; index++) {
      PollWatch *watch = &poller->watches[index];
      if (!watch->kind || watch->kind == CHILDREN) continue;
      if (!resource(watch->socket, watch->kind)) return failure(CLOSED);
      descriptors[count] = (PollDescriptor){
          .fd = ((Connection *)watch->socket)->socket,
          .events = watch->mode, .revents = 0};
      indices[count++] = index;
    }
    uint64_t remaining = nearest > now.number ? nearest - now.number : 0;
    int delay = (int)(remaining / 1000000 + (remaining % 1000000 != 0));
    if (children && delay > 10) delay = 10;
    if (!count) {
      if (!delay) return (FooResult){0};
      FooResult slept = foo_time_sleep((uint64_t)delay * UINT64_C(1000000));
      if (slept.error) return slept;
    } else {
#ifdef _WIN32
      int ready = WSAPoll(descriptors, (ULONG)count, delay);
#else
      int ready = poll(descriptors, (nfds_t)count, delay);
#endif
      if (ready < 0) {
        if (interrupted()) continue;
        return failure(IO);
      }
      if (ready) {
        for (size_t offset = 0; offset < count; offset++) {
          size_t position = (poller->cursor + offset) % count;
          short flags = descriptors[position].revents;
          if (flags & POLLNVAL) return failure(CLOSED);
          if (flags & (descriptors[position].events | POLLERR | POLLHUP)) {
            poller->cursor = (position + 1) % count;
            return (FooResult){.number = poller->watches[indices[position]].token};
          }
        }
      }
    }
    if (milliseconds == 0) return (FooResult){0};
    now = foo_time_current();
    if (now.error) return now;
    if (now.number >= limit) return (FooResult){0};
  }
}
FooResult foo_net_cease(void *pointer) {
  Resource *entry = resource(pointer, POLLERS);
  if (!entry) return failure(CLOSED);
  entry->closed = 1;
  return (FooResult){0};
}

typedef struct {
#ifdef _WIN32
  HMODULE handle;
#else
  void *handle;
#endif
  atomic_uint active;
} DynamicLibrary;
typedef struct {
  DynamicLibrary *owner;
  void *address;
} DynamicSymbol;
FooResult foo_dylib_open(FooText path) {
  if (!path.len) return failure(ARGUMENT);
  char *name = string(path);
  if (!name) return failure(ARGUMENT);
#ifdef _WIN32
  HMODULE handle = LoadLibraryA(name);
#else
  void *handle = dlopen(name, RTLD_NOW | RTLD_LOCAL);
#endif
  free(name);
  if (!handle) return failure(MISSING);
  DynamicLibrary *library = owned(sizeof(*library), DYNAMIC_LIBRARIES);
  if (!library) {
#ifdef _WIN32
    FreeLibrary(handle);
#else
    dlclose(handle);
#endif
    return failure(MEMORY);
  }
  library->handle = handle;
  atomic_init(&library->active, 0);
  return (FooResult){.pointer = library};
}
FooResult foo_dylib_lookup(void *pointer, FooText name) {
  Resource *entry = resource(pointer, DYNAMIC_LIBRARIES);
  if (!entry || !name.len) return failure(entry ? ARGUMENT : CLOSED);
  char *label = string(name);
  if (!label) return failure(ARGUMENT);
  DynamicLibrary *library = pointer;
  atomic_fetch_add_explicit(&library->active, 1, memory_order_acquire);
  if (atomic_load_explicit(&entry->closed, memory_order_acquire)) {
    atomic_fetch_sub_explicit(&library->active, 1, memory_order_release);
    free(label);
    return failure(CLOSED);
  }
#ifdef _WIN32
  void *address = (void *)GetProcAddress(library->handle, label);
#else
  void *address = dlsym(library->handle, label);
#endif
  atomic_fetch_sub_explicit(&library->active, 1, memory_order_release);
  free(label);
  if (!address) return failure(MISSING);
  DynamicSymbol *symbol = owned(sizeof(*symbol), DYNAMIC_SYMBOLS);
  if (!symbol) return failure(MEMORY);
  symbol->owner = library;
  symbol->address = address;
  return (FooResult){.pointer = symbol};
}
FooResult foo_dylib_call(void *pointer, uint64_t argument) {
  DynamicSymbol *symbol = resource(pointer, DYNAMIC_SYMBOLS) ? pointer : NULL;
  if (!symbol) return failure(CLOSED);
  Resource *entry = resource(symbol->owner, DYNAMIC_LIBRARIES);
  if (!entry) return failure(CLOSED);
  atomic_fetch_add_explicit(&symbol->owner->active, 1, memory_order_acquire);
  if (atomic_load_explicit(&entry->closed, memory_order_acquire)) {
    atomic_fetch_sub_explicit(&symbol->owner->active, 1, memory_order_release);
    return failure(CLOSED);
  }
  uint64_t (*function)(uint64_t);
  memcpy(&function, &symbol->address, sizeof(function));
  uint64_t result = function(argument);
  atomic_fetch_sub_explicit(&symbol->owner->active, 1, memory_order_release);
  return (FooResult){.number = result};
}
FooResult foo_dylib_discard(void *pointer) {
  Resource *entry = resource(pointer, DYNAMIC_SYMBOLS);
  if (!entry) return failure(CLOSED);
  atomic_store_explicit(&entry->closed, 1, memory_order_release);
  return (FooResult){0};
}
FooResult foo_dylib_close(void *pointer) {
  Resource *entry = resource(pointer, DYNAMIC_LIBRARIES);
  if (!entry) return failure(CLOSED);
  DynamicLibrary *library = pointer;
  if (atomic_exchange_explicit(&entry->closed, 1, memory_order_acq_rel))
    return failure(CLOSED);
  while (atomic_load_explicit(&library->active, memory_order_acquire)) { }
#ifdef _WIN32
  return FreeLibrary(library->handle) ? (FooResult){0} : failure(SYSTEM);
#else
  return dlclose(library->handle) == 0 ? (FooResult){0} : failure(SYSTEM);
#endif
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
FooResult foo_process_id(void) {
#ifdef _WIN32
  return (FooResult){.number = GetCurrentProcessId()};
#else
  return (FooResult){.number = (uint64_t)getpid()};
#endif
}
FooResult foo_process_parent(void) {
#ifdef _WIN32
  DWORD current = GetCurrentProcessId();
  HANDLE snapshot = CreateToolhelp32Snapshot(TH32CS_SNAPPROCESS, 0);
  if (snapshot == INVALID_HANDLE_VALUE) return failure(SYSTEM);
  PROCESSENTRY32 entry = {.dwSize = sizeof(entry)};
  uint64_t parent = 0;
  if (Process32First(snapshot, &entry)) {
    do {
      if (entry.th32ProcessID == current) {
        parent = entry.th32ParentProcessID;
        break;
      }
    } while (Process32Next(snapshot, &entry));
  }
  CloseHandle(snapshot);
  return parent ? (FooResult){.number = parent} : failure(SYSTEM);
#else
  return (FooResult){.number = (uint64_t)getppid()};
#endif
}
typedef struct {
#ifdef _WIN32
  HANDLE handle;
  HANDLE input, output, report;
#else
  pid_t pid;
  int input, output, report;
#endif
  uint64_t status;
  int finished;
  int piped;
} Child;
static uint64_t child_status(int status) {
#ifdef _WIN32
  return (uint64_t)(unsigned)status;
#else
  return WIFEXITED(status) ? (uint64_t)WEXITSTATUS(status) :
         WIFSIGNALED(status) ? (uint64_t)(128 + WTERMSIG(status)) : 255;
#endif
}
FooResult foo_process_spawn(FooText program, FooText items) {
  if (!program.len || !program.data ||
      (items.len && !items.data) ||
      items.len > (SIZE_MAX / sizeof(char *)) - 2) return failure(ARGUMENT);
  char *name = string(program);
  if (!name) return failure(ARGUMENT);
  char **vector = calloc(items.len + 2, sizeof(*vector));
  if (!vector) { free(name); return failure(MEMORY); }
  vector[0] = name;
  const FooText *values = (const FooText *)items.data;
  size_t index = 0;
  for (; index < items.len; index++) {
    if (values[index].len && !values[index].data) break;
    vector[index + 1] = string(values[index]);
    if (!vector[index + 1]) break;
  }
  if (index != items.len) {
    for (size_t item = 0; item <= index; item++) free(vector[item]);
    free(vector);
    return failure(ARGUMENT);
  }
#ifdef _WIN32
  intptr_t launched = _spawnvp(_P_NOWAIT, name, (const char *const *)vector);
  int problem = launched < 0 ? errno : 0;
#else
  int channel[2];
  int problem = pipe(channel) ? errno : 0;
  if (!problem && fcntl(channel[1], F_SETFD, FD_CLOEXEC)) {
    problem = errno;
    close(channel[0]); close(channel[1]);
  }
  pid_t launched = -1;
  if (!problem) {
    launched = fork();
    if (!launched) {
      close(channel[0]);
      execvp(name, vector);
      int cause = errno;
      (void)write(channel[1], &cause, sizeof(cause));
      _exit(127);
    }
    if (launched < 0) {
      problem = errno;
      close(channel[0]); close(channel[1]);
    } else {
      close(channel[1]);
      int cause = 0;
      ssize_t amount;
      do { amount = read(channel[0], &cause, sizeof(cause)); }
      while (amount < 0 && errno == EINTR);
      int read_error = errno;
      close(channel[0]);
      if (amount != 0) {
        problem = amount == sizeof(cause) ? cause :
                  amount < 0 ? read_error : EIO;
        if (amount < 0) kill(launched, SIGKILL);
        while (waitpid(launched, NULL, 0) < 0 && errno == EINTR) { }
      }
    }
  }
#endif
  for (size_t item = 0; item <= items.len; item++) free(vector[item]);
  free(vector);
  if (problem) return failure(problem == ENOENT ? MISSING : IO);
  Child *child = owned(sizeof(*child), CHILDREN);
  if (!child) {
#ifdef _WIN32
    TerminateProcess((HANDLE)launched, 137);
    WaitForSingleObject((HANDLE)launched, INFINITE);
    CloseHandle((HANDLE)launched);
#else
    kill(launched, SIGKILL);
    while (waitpid(launched, NULL, 0) < 0 && errno == EINTR) { }
#endif
    return failure(MEMORY);
  }
#ifdef _WIN32
  child->handle = (HANDLE)launched;
#else
  child->pid = launched;
#endif
  return (FooResult){.pointer = child};
}
#ifdef _WIN32
static char *child_command(char *const *args, size_t count) {
  size_t capacity = 1;
  for (size_t index = 0; index < count; index++) {
    size_t length = strlen(args[index]);
    if (capacity > 32764 || length > (32764 - capacity) / 2) return NULL;
    capacity += length * 2 + 3;
  }
  char *command = malloc(capacity);
  if (!command) return NULL;
  char *cursor = command;
  for (size_t index = 0; index < count; index++) {
    if (index) *cursor++ = ' ';
    *cursor++ = '"';
    const char *input = args[index];
    while (*input) {
      size_t slashes = 0;
      while (*input == '\\') { slashes++; input++; }
      if (*input == '"') {
        for (size_t each = 0; each < slashes * 2 + 1; each++) *cursor++ = '\\';
        *cursor++ = *input++;
      } else {
        for (size_t each = 0; each < (*input ? slashes : slashes * 2); each++)
          *cursor++ = '\\';
        if (*input) *cursor++ = *input++;
      }
    }
    *cursor++ = '"';
  }
  *cursor = 0;
  return command;
}
static void child_handle(HANDLE *handle) {
  if (*handle) { CloseHandle(*handle); *handle = NULL; }
}
#else
static int child_pair(int pair[2]) {
  int raw[2];
  if (pipe(raw)) return 0;
  pair[0] = pair[1] = -1;
  for (int side = 0; side < 2; side++) {
    pair[side] = fcntl(raw[side], F_DUPFD, 3);
    if (pair[side] < 0 || fcntl(pair[side], F_SETFD, FD_CLOEXEC)) {
      int problem = errno;
      if (pair[0] >= 0) close(pair[0]);
      if (pair[1] >= 0) close(pair[1]);
      close(raw[0]); close(raw[1]);
      pair[0] = pair[1] = -1;
      errno = problem;
      return 0;
    }
  }
  close(raw[0]); close(raw[1]);
  return 1;
}
#endif
FooResult foo_process_pipe(FooText program, FooText items) {
  if (!program.len || !program.data || (items.len && !items.data) ||
      items.len > (SIZE_MAX / sizeof(char *)) - 2) return failure(ARGUMENT);
  char *name = string(program);
  if (!name) return failure(ARGUMENT);
  char **vector = calloc(items.len + 2, sizeof(*vector));
  if (!vector) { free(name); return failure(MEMORY); }
  vector[0] = name;
  const FooText *values = (const FooText *)items.data;
  size_t index = 0;
  for (; index < items.len; index++) {
    if (values[index].len && !values[index].data) break;
    vector[index + 1] = string(values[index]);
    if (!vector[index + 1]) break;
  }
  if (index != items.len) {
    for (size_t item = 0; item <= index; item++) free(vector[item]);
    free(vector);
    return failure(ARGUMENT);
  }
  int problem = 0;
#ifdef _WIN32
  HANDLE input_read = NULL, input_write = NULL, output_read = NULL,
         output_write = NULL, report_read = NULL, report_write = NULL;
  SECURITY_ATTRIBUTES security = {.nLength = sizeof(security),
                                  .bInheritHandle = TRUE};
  PROCESS_INFORMATION launched = {0};
  char *command = child_command(vector, items.len + 1);
  if (!command) problem = ERROR_INVALID_PARAMETER;
  if (!problem && (!CreatePipe(&input_read, &input_write, &security, 0) ||
      !CreatePipe(&output_read, &output_write, &security, 0) ||
      !CreatePipe(&report_read, &report_write, &security, 0) ||
      !SetHandleInformation(input_write, HANDLE_FLAG_INHERIT, 0) ||
      !SetHandleInformation(output_read, HANDLE_FLAG_INHERIT, 0) ||
      !SetHandleInformation(report_read, HANDLE_FLAG_INHERIT, 0)))
    problem = GetLastError();
  SIZE_T attribute_size = 0;
  LPPROC_THREAD_ATTRIBUTE_LIST attributes = NULL;
  int initialized = 0;
  if (!problem) {
    InitializeProcThreadAttributeList(NULL, 1, 0, &attribute_size);
    attributes = malloc(attribute_size);
    if (!attributes ||
        !InitializeProcThreadAttributeList(attributes, 1, 0, &attribute_size))
      problem = attributes ? GetLastError() : ERROR_NOT_ENOUGH_MEMORY;
    else initialized = 1;
  }
  if (!problem) {
    HANDLE inherited[3] = {input_read, output_write, report_write};
    if (!UpdateProcThreadAttribute(attributes, 0,
          PROC_THREAD_ATTRIBUTE_HANDLE_LIST, inherited, sizeof(inherited),
          NULL, NULL)) problem = GetLastError();
  }
  if (!problem) {
    STARTUPINFOEXA startup = {0};
    startup.StartupInfo.cb = sizeof(startup);
    startup.StartupInfo.dwFlags = STARTF_USESTDHANDLES;
    startup.StartupInfo.hStdInput = input_read;
    startup.StartupInfo.hStdOutput = output_write;
    startup.StartupInfo.hStdError = report_write;
    startup.lpAttributeList = attributes;
    if (!CreateProcessA(NULL, command, NULL, NULL, TRUE,
          EXTENDED_STARTUPINFO_PRESENT | CREATE_NO_WINDOW, NULL, NULL,
          &startup.StartupInfo, &launched)) problem = GetLastError();
  }
  if (initialized) DeleteProcThreadAttributeList(attributes);
  free(attributes);
  free(command);
  child_handle(&input_read); child_handle(&output_write);
  child_handle(&report_write);
  if (launched.hThread) CloseHandle(launched.hThread);
  if (problem) {
    child_handle(&input_write); child_handle(&output_read);
    child_handle(&report_read);
  }
#else
  int pipes[4][2] = {{-1, -1}, {-1, -1}, {-1, -1}, {-1, -1}};
  for (int part = 0; part < 4; part++)
    if (!child_pair(pipes[part])) { problem = errno; break; }
  pid_t launched = -1;
  if (!problem) {
    launched = fork();
    if (!launched) {
      int cause = 0;
      if (dup2(pipes[0][0], STDIN_FILENO) < 0 ||
          dup2(pipes[1][1], STDOUT_FILENO) < 0 ||
          dup2(pipes[2][1], STDERR_FILENO) < 0) cause = errno;
      for (int part = 0; part < 4; part++)
        for (int side = 0; side < 2; side++)
          if (part != 3 || side != 1) close(pipes[part][side]);
      if (!cause) { execvp(name, vector); cause = errno; }
      (void)write(pipes[3][1], &cause, sizeof(cause));
      _exit(127);
    }
    if (launched < 0) problem = errno;
    else {
      close(pipes[0][0]); pipes[0][0] = -1;
      close(pipes[1][1]); pipes[1][1] = -1;
      close(pipes[2][1]); pipes[2][1] = -1;
      close(pipes[3][1]); pipes[3][1] = -1;
      int cause = 0;
      ssize_t amount;
      do { amount = read(pipes[3][0], &cause, sizeof(cause)); }
      while (amount < 0 && errno == EINTR);
      int read_error = errno;
      close(pipes[3][0]); pipes[3][0] = -1;
      if (amount != 0) {
        problem = amount == sizeof(cause) ? cause :
                  amount < 0 ? read_error : EIO;
        if (amount < 0) kill(launched, SIGKILL);
        while (waitpid(launched, NULL, 0) < 0 && errno == EINTR) { }
      }
    }
  }
  if (problem)
    for (int part = 0; part < 4; part++)
      for (int side = 0; side < 2; side++)
        if (pipes[part][side] >= 0) close(pipes[part][side]);
#endif
  for (size_t item = 0; item <= items.len; item++) free(vector[item]);
  free(vector);
  if (problem) {
#ifdef _WIN32
    return failure(problem == ERROR_FILE_NOT_FOUND ||
                   problem == ERROR_PATH_NOT_FOUND ? MISSING : IO);
#else
    return failure(problem == ENOENT ? MISSING : IO);
#endif
  }
  Child *child = owned(sizeof(*child), CHILDREN);
  if (!child) {
#ifdef _WIN32
    TerminateProcess(launched.hProcess, 137);
    WaitForSingleObject(launched.hProcess, INFINITE);
    CloseHandle(launched.hProcess);
    child_handle(&input_write); child_handle(&output_read);
    child_handle(&report_read);
#else
    kill(launched, SIGKILL);
    while (waitpid(launched, NULL, 0) < 0 && errno == EINTR) { }
    close(pipes[0][1]); close(pipes[1][0]); close(pipes[2][0]);
#endif
    return failure(MEMORY);
  }
  child->piped = 1;
#ifdef _WIN32
  child->handle = launched.hProcess;
  child->input = input_write;
  child->output = output_read;
  child->report = report_read;
#else
  child->pid = launched;
  child->input = pipes[0][1];
  child->output = pipes[1][0];
  child->report = pipes[2][0];
#endif
  return (FooResult){.pointer = child};
}
FooResult foo_process_write(void *pointer, FooText content) {
  if (!resource(pointer, CHILDREN)) return failure(CLOSED);
  Child *child = pointer;
  if (!child->piped) return failure(ARGUMENT);
  if (content.len && !content.data) return failure(ARGUMENT);
  if (content.len > INT_MAX) return failure(BOUNDS);
  if (!content.len) return (FooResult){0};
#ifdef _WIN32
  if (!child->input) return failure(CLOSED);
  DWORD written = 0;
  if (!WriteFile(child->input, content.data, (DWORD)content.len,
                 &written, NULL)) return failure(IO);
  return (FooResult){.number = written};
#else
  if (child->input < 0) return failure(CLOSED);
  sigset_t blocked, previous, pending;
  sigemptyset(&blocked);
  sigaddset(&blocked, SIGPIPE);
  if (pthread_sigmask(SIG_BLOCK, &blocked, &previous)) return failure(SYSTEM);
  int prior = !sigpending(&pending) && sigismember(&pending, SIGPIPE);
  ssize_t written;
  do { written = write(child->input, content.data, content.len); }
  while (written < 0 && errno == EINTR);
  int problem = errno;
  if (written < 0 && problem == EPIPE && !prior &&
      !sigpending(&pending) && sigismember(&pending, SIGPIPE)) {
    int received;
    sigwait(&blocked, &received);
  }
  pthread_sigmask(SIG_SETMASK, &previous, NULL);
  return written < 0 ? failure(IO) :
      (FooResult){.number = (uint64_t)written};
#endif
}
FooResult foo_process_seal(void *pointer) {
  if (!resource(pointer, CHILDREN)) return failure(CLOSED);
  Child *child = pointer;
  if (!child->piped) return failure(ARGUMENT);
#ifdef _WIN32
  if (!child->input) return failure(CLOSED);
  HANDLE input = child->input;
  child->input = NULL;
  return CloseHandle(input) ? (FooResult){0} : failure(IO);
#else
  if (child->input < 0) return failure(CLOSED);
  int input = child->input;
  child->input = -1;
  return close(input) ? failure(IO) : (FooResult){0};
#endif
}
FooResult foo_process_read(void *pointer, FooText stream, uint64_t size) {
  if (!resource(pointer, CHILDREN)) return failure(CLOSED);
  Child *child = pointer;
  if (!child->piped) return failure(ARGUMENT);
  int output = cpu_named(stream, "output");
  if (!output && !cpu_named(stream, "error")) return failure(ARGUMENT);
  if (size > 16 * 1024 * 1024) return failure(BOUNDS);
  if (!size) return (FooResult){0};
  uint8_t *buffer = malloc((size_t)size);
  if (!buffer) return failure(MEMORY);
#ifdef _WIN32
  HANDLE handle = output ? child->output : child->report;
  if (!handle) { free(buffer); return failure(CLOSED); }
  DWORD received = 0;
  int ok = ReadFile(handle, buffer, (DWORD)size, &received, NULL);
  int problem = ok || GetLastError() == ERROR_BROKEN_PIPE ? 0 : IO;
#else
  int handle = output ? child->output : child->report;
  if (handle < 0) { free(buffer); return failure(CLOSED); }
  ssize_t received;
  do { received = read(handle, buffer, (size_t)size); }
  while (received < 0 && errno == EINTR);
  int problem = received < 0 ? IO : 0;
#endif
  FooResult result = problem ? failure(problem) : text(buffer, (size_t)received);
  free(buffer);
  return result;
}
FooResult foo_process_release(FooText content) {
  return foo_text_release(content);
}
FooResult foo_process_identity(void *pointer) {
  if (!resource(pointer, CHILDREN)) return failure(CLOSED);
  Child *child = pointer;
#ifdef _WIN32
  DWORD id = GetProcessId(child->handle);
  return id ? (FooResult){.number = id} : failure(SYSTEM);
#else
  return (FooResult){.number = (uint64_t)child->pid};
#endif
}
static FooResult child_check(Child *child, bool block) {
  if (child->finished) return (FooResult){.number = 0};
#ifdef _WIN32
  DWORD ready = WaitForSingleObject(child->handle, block ? INFINITE : 0);
  if (ready == WAIT_TIMEOUT) return (FooResult){.number = 1};
  if (ready != WAIT_OBJECT_0) return failure(SYSTEM);
  DWORD status = 0;
  if (!GetExitCodeProcess(child->handle, &status)) return failure(SYSTEM);
  child->status = child_status((int)status);
#else
  int status = 0;
  pid_t result;
  do { result = waitpid(child->pid, &status, block ? 0 : WNOHANG); }
  while (result < 0 && errno == EINTR);
  if (!result) return (FooResult){.number = 1};
  if (result < 0) return failure(SYSTEM);
  child->status = child_status(status);
#endif
  child->finished = 1;
  return (FooResult){0};
}
FooResult foo_process_active(void *pointer) {
  if (!resource(pointer, CHILDREN)) return failure(CLOSED);
  return child_check(pointer, false);
}
FooResult foo_process_wait(void *pointer) {
  if (!resource(pointer, CHILDREN)) return failure(CLOSED);
  Child *child = pointer;
  FooResult checked = child_check(child, true);
  return checked.error ? checked : (FooResult){.number = child->status};
}
FooResult foo_process_observe(void *pointer, uint64_t milliseconds) {
  if (!resource(pointer, CHILDREN)) return failure(CLOSED);
  if (milliseconds >= UINT32_MAX) return failure(BOUNDS);
  Child *child = pointer;
#ifdef _WIN32
  if (child->finished) return (FooResult){.number = 1};
  DWORD ready = WaitForSingleObject(child->handle, (DWORD)milliseconds);
  if (ready == WAIT_TIMEOUT) return (FooResult){0};
  if (ready != WAIT_OBJECT_0) return failure(SYSTEM);
  FooResult checked = child_check(child, false);
  return checked.error ? checked : (FooResult){.number = !checked.number};
#else
  FooResult now = foo_time_current();
  if (now.error) return now;
  uint64_t duration = milliseconds * UINT64_C(1000000);
  if (duration > UINT64_MAX - now.number) return failure(BOUNDS);
  uint64_t deadline = now.number + duration;
  for (;;) {
    FooResult checked = child_check(child, false);
    if (checked.error || !checked.number)
      return checked.error ? checked : (FooResult){.number = 1};
    now = foo_time_current();
    if (now.error) return now;
    if (now.number >= deadline) return (FooResult){0};
    uint64_t remaining = deadline - now.number;
    FooResult slept = foo_time_sleep(remaining < 1000000 ? remaining : 1000000);
    if (slept.error) return slept;
  }
#endif
}
FooResult foo_process_kill(void *pointer) {
  if (!resource(pointer, CHILDREN)) return failure(CLOSED);
  Child *child = pointer;
  FooResult checked = child_check(child, false);
  if (checked.error || !checked.number) return checked;
#ifdef _WIN32
  return TerminateProcess(child->handle, 137) ? (FooResult){0} : failure(SYSTEM);
#else
  return !kill(child->pid, SIGKILL) || errno == ESRCH
      ? (FooResult){0} : failure(SYSTEM);
#endif
}
FooResult foo_process_signal(void *pointer, FooText name) {
  if (!resource(pointer, CHILDREN)) return failure(CLOSED);
  int selected = cpu_named(name, "kill") ? 1 :
                 cpu_named(name, "terminate") ? 2 :
                 cpu_named(name, "interrupt") ? 3 :
                 cpu_named(name, "hangup") ? 4 : 0;
  if (!selected) return failure(ARGUMENT);
  Child *child = pointer;
  FooResult checked = child_check(child, false);
  if (checked.error || !checked.number) return checked;
#ifdef _WIN32
  if (selected > 2) return failure(MISSING);
  return TerminateProcess(child->handle, selected == 1 ? 137 : 143)
      ? (FooResult){0} : failure(SYSTEM);
#else
  int signal = selected == 1 ? SIGKILL : selected == 2 ? SIGTERM :
               selected == 3 ? SIGINT : SIGHUP;
  return !kill(child->pid, signal) || errno == ESRCH
      ? (FooResult){0} : failure(SYSTEM);
#endif
}
FooResult foo_process_close(void *pointer) {
  Resource *entry = resource(pointer, CHILDREN);
  if (!entry) return failure(CLOSED);
  FooResult stopped = foo_process_kill(pointer);
  if (stopped.error) return stopped;
  FooResult waited = foo_process_wait(pointer);
  if (waited.error) return waited;
  Child *child = pointer;
  int failed = 0;
  if (child->piped) {
#ifdef _WIN32
    if (child->input && !CloseHandle(child->input)) failed = 1;
    if (child->output && !CloseHandle(child->output)) failed = 1;
    if (child->report && !CloseHandle(child->report)) failed = 1;
#else
    if (child->input >= 0 && close(child->input)) failed = 1;
    if (child->output >= 0 && close(child->output)) failed = 1;
    if (child->report >= 0 && close(child->report)) failed = 1;
#endif
  }
#ifdef _WIN32
  if (!CloseHandle(child->handle)) failed = 1;
#endif
  atomic_store_explicit(&entry->closed, 1, memory_order_release);
  return failed ? failure(IO) : (FooResult){0};
}
FooResult foo_process_exit(uint8_t code) {
  exit(code);
}
FooResult foo_process_abort(void) {
  abort();
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
FooResult foo_time_wall(void) {
#ifdef _WIN32
  FILETIME instant;
  GetSystemTimePreciseAsFileTime(&instant);
  uint64_t ticks = ((uint64_t)instant.dwHighDateTime << 32) |
                   instant.dwLowDateTime;
  if (ticks < UINT64_C(116444736000000000))
    return failure(BOUNDS);
  ticks -= UINT64_C(116444736000000000);
  if (ticks > UINT64_MAX / UINT64_C(100))
    return failure(BOUNDS);
  return (FooResult){.number = ticks * UINT64_C(100)};
#else
  struct timespec instant;
  if (clock_gettime(CLOCK_REALTIME, &instant))
    return failure(SYSTEM);
  if (instant.tv_sec < 0 || (uint64_t)instant.tv_sec >
          (UINT64_MAX - (uint64_t)instant.tv_nsec) / UINT64_C(1000000000))
    return failure(BOUNDS);
  return (FooResult){.number = (uint64_t)instant.tv_sec * UINT64_C(1000000000) +
                               (uint64_t)instant.tv_nsec};
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
  uint64_t deadline;
  int armed;
  int waiters;
#ifdef _WIN32
  CRITICAL_SECTION mutex;
  CONDITION_VARIABLE condition;
#else
  pthread_mutex_t mutex;
  pthread_cond_t condition;
#endif
} Timer;
static void timer_lock(Timer *timer) {
#ifdef _WIN32
  EnterCriticalSection(&timer->mutex);
#else
  pthread_mutex_lock(&timer->mutex);
#endif
}
static void timer_unlock(Timer *timer) {
#ifdef _WIN32
  LeaveCriticalSection(&timer->mutex);
#else
  pthread_mutex_unlock(&timer->mutex);
#endif
}
static void timer_signal(Timer *timer) {
#ifdef _WIN32
  WakeAllConditionVariable(&timer->condition);
#else
  pthread_cond_broadcast(&timer->condition);
#endif
}
FooResult foo_timer_create(void) {
  Timer *timer = owned(sizeof(*timer), TIMERS);
  if (!timer) return failure(MEMORY);
#ifdef _WIN32
  InitializeCriticalSection(&timer->mutex);
  InitializeConditionVariable(&timer->condition);
#else
  if (pthread_mutex_init(&timer->mutex, NULL)) {
    resource(timer, TIMERS)->closed = 1;
    return failure(SYSTEM);
  }
#ifdef __linux__
  pthread_condattr_t attributes;
  if (pthread_condattr_init(&attributes)) {
    pthread_mutex_destroy(&timer->mutex);
    resource(timer, TIMERS)->closed = 1;
    return failure(SYSTEM);
  }
  int failed = pthread_condattr_setclock(&attributes, CLOCK_MONOTONIC) ||
               pthread_cond_init(&timer->condition, &attributes);
  pthread_condattr_destroy(&attributes);
#else
  int failed = pthread_cond_init(&timer->condition, NULL);
#endif
  if (failed) {
    pthread_mutex_destroy(&timer->mutex);
    resource(timer, TIMERS)->closed = 1;
    return failure(SYSTEM);
  }
#endif
  return (FooResult){.pointer = timer};
}
FooResult foo_timer_arm(void *pointer, uint64_t nanos) {
  if (!resource(pointer, TIMERS)) return failure(CLOSED);
  FooResult now = foo_time_current();
  if (now.error) return now;
  if (nanos > UINT64_MAX - now.number) return failure(BOUNDS);
  Timer *timer = pointer;
  timer_lock(timer);
  timer->deadline = now.number + nanos;
  timer->armed = 1;
  timer_signal(timer);
  timer_unlock(timer);
  return (FooResult){0};
}
FooResult foo_timer_wait(void *pointer) {
  if (!resource(pointer, TIMERS)) return failure(CLOSED);
  Timer *timer = pointer;
  timer_lock(timer);
  if (timer->waiters) { timer_unlock(timer); return failure(ARGUMENT); }
  timer->waiters = 1;
  int problem = 0, fired = 0;
  while (timer->armed) {
    FooResult now = foo_time_current();
    if (now.error) { problem = SYSTEM; break; }
    if (now.number >= timer->deadline) {
      timer->armed = 0;
      fired = 1;
      break;
    }
    uint64_t remaining = timer->deadline - now.number;
#ifdef _WIN32
    uint64_t millis = remaining / 1000000 + (remaining % 1000000 != 0);
    DWORD delay = millis >= INFINITE ? INFINITE - 1 : (DWORD)millis;
    if (!SleepConditionVariableCS(&timer->condition, &timer->mutex, delay) &&
        GetLastError() != ERROR_TIMEOUT) { problem = SYSTEM; break; }
#else
    struct timespec limit;
#ifdef __linux__
    uint64_t target = timer->deadline;
    limit.tv_sec = (time_t)(target / 1000000000);
    limit.tv_nsec = (long)(target % 1000000000);
#else
    if (clock_gettime(CLOCK_REALTIME, &limit)) { problem = SYSTEM; break; }
    if (remaining > 1000000000) remaining = 1000000000;
    limit.tv_sec += (time_t)(remaining / 1000000000);
    limit.tv_nsec += (long)(remaining % 1000000000);
    if (limit.tv_nsec >= 1000000000) {
      limit.tv_sec++;
      limit.tv_nsec -= 1000000000;
    }
#endif
    int waited = pthread_cond_timedwait(&timer->condition, &timer->mutex, &limit);
    if (waited && waited != ETIMEDOUT) { problem = SYSTEM; break; }
#endif
  }
  timer->waiters = 0;
  timer_signal(timer);
  timer_unlock(timer);
  return problem ? failure(problem) : (FooResult){.number = fired};
}
FooResult foo_timer_cancel(void *pointer) {
  if (!resource(pointer, TIMERS)) return failure(CLOSED);
  Timer *timer = pointer;
  timer_lock(timer);
  timer->armed = 0;
  timer_signal(timer);
  timer_unlock(timer);
  return (FooResult){0};
}
FooResult foo_timer_close(void *pointer) {
  Resource *entry = resource(pointer, TIMERS);
  if (!entry) return failure(CLOSED);
  Timer *timer = pointer;
  timer_lock(timer);
  timer->armed = 0;
  timer_signal(timer);
  while (timer->waiters) {
#ifdef _WIN32
    if (!SleepConditionVariableCS(&timer->condition, &timer->mutex, INFINITE)) {
      timer_unlock(timer);
      return failure(SYSTEM);
    }
#else
    if (pthread_cond_wait(&timer->condition, &timer->mutex)) {
      timer_unlock(timer);
      return failure(SYSTEM);
    }
#endif
  }
  timer_unlock(timer);
#ifdef _WIN32
  DeleteCriticalSection(&timer->mutex);
#else
  if (pthread_cond_destroy(&timer->condition) ||
      pthread_mutex_destroy(&timer->mutex)) return failure(SYSTEM);
#endif
  atomic_store_explicit(&entry->closed, 1, memory_order_release);
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
typedef struct CancelToken {
  atomic_uint references;
  atomic_int cancelled;
  struct CancelToken *parent;
} CancelToken;
static _Thread_local CancelToken *current_cancel;
static CancelToken *cancel_token(void) {
  CancelToken *token = malloc(sizeof(*token));
  if (!token) return NULL;
  atomic_init(&token->references, 1);
  atomic_init(&token->cancelled, 0);
  token->parent = current_cancel;
  if (token->parent)
    atomic_fetch_add_explicit(&token->parent->references, 1, memory_order_relaxed);
  return token;
}
static void cancel_release(CancelToken *token) {
  if (!token || atomic_fetch_sub_explicit(&token->references, 1,
                                           memory_order_acq_rel) != 1) return;
  CancelToken *parent = token->parent;
  free(token);
  cancel_release(parent);
}
static int cancel_requested(CancelToken *token) {
  for (; token; token = token->parent)
    if (atomic_load_explicit(&token->cancelled, memory_order_acquire))
      return 1;
  return 0;
}
typedef struct {
  void *threads[128];
  size_t count;
  CancelToken *cancel;
} TaskScope;
typedef struct ScopedCall {
  void (*callback)(int64_t);
  int64_t argument;
  CancelToken *cancel;
  struct ScopedCall *next;
} ScopedCall;
#if defined(_WIN32) || defined(__linux__)
typedef struct {
  atomic_size_t pending;
  size_t count;
  atomic_int stopping;
  CancelToken *cancel;
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
    atomic_fetch_sub_explicit(&task_queued, 1, memory_order_acq_rel);
    CancelToken *previous = current_cancel;
    current_cancel = pool->cancel;
    if (!cancel_requested(current_cancel)) call->callback(call->argument);
    current_cancel = previous;
    free(call);
    atomic_fetch_sub_explicit(&task_work, 1, memory_order_acq_rel);
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
    atomic_fetch_sub_explicit(&task_queued, 1, memory_order_acq_rel);
    CancelToken *previous = current_cancel;
    current_cancel = pool->cancel;
    if (!cancel_requested(current_cancel)) call->callback(call->argument);
    current_cancel = previous;
    free(call);
    atomic_fetch_sub_explicit(&task_work, 1, memory_order_acq_rel);
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
  cancel_release(pool->cancel);
  pool->cancel = NULL;
}
#endif

static void scoped_work(void *pointer) {
  ScopedCall *call = pointer;
  CancelToken *previous = current_cancel;
  current_cancel = call->cancel;
  if (!cancel_requested(current_cancel)) call->callback(call->argument);
  current_cancel = previous;
  free(call);
  atomic_fetch_sub_explicit(&task_work, 1, memory_order_acq_rel);
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
  if (!scope) return failure(MEMORY);
  scope->cancel = cancel_token();
  if (!scope->cancel) {
    resource(scope, TASK_SCOPE)->closed = 1;
    return failure(MEMORY);
  }
  return (FooResult){.pointer = scope};
}
FooResult foo_task_scope(void) { return task_scope(); }
FooResult foo_task_pool(void) {
#if defined(_WIN32) || defined(__linux__)
  TaskPool *pool = owned(sizeof(*pool), TASK_POOL);
  if (!pool)
    return failure(MEMORY);
  pool->cancel = cancel_token();
  if (!pool->cancel) {
    resource(pool, TASK_POOL)->closed = 1;
    return failure(MEMORY);
  }
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
  if (!scope || !callback) return failure(CLOSED);
  enter();
  if (scope->count == 128 || cancel_requested(scope->cancel)) {
    leave(); return (FooResult){.number = 0};
  }
  leave();
  ScopedCall *call = malloc(sizeof(*call));
  if (!call) return failure(MEMORY);
  *call = (ScopedCall){callback, argument, scope->cancel, NULL};
  atomic_fetch_add_explicit(&task_work, 1, memory_order_release);
  FooResult spawned = foo_thread_spawn(scoped_work, call);
  if (spawned.error) {
    atomic_fetch_sub_explicit(&task_work, 1, memory_order_acq_rel);
    free(call);
    return spawned;
  }
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
  if (cancel_requested(queue->cancel)) return (FooResult){.number = 0};
  ScopedCall *call = calloc(1, sizeof(*call));
  if (!call)
    return failure(MEMORY);
  call->callback = callback;
  call->argument = argument;
#ifdef _WIN32
  if (atomic_load_explicit(&queue->stopping, memory_order_acquire) ||
      cancel_requested(queue->cancel)) {
    free(call);
    return failure(CLOSED);
  }
  ResetEvent(queue->done);
  atomic_fetch_add_explicit(&queue->pending, 1, memory_order_release);
  atomic_fetch_add_explicit(&task_work, 1, memory_order_release);
  atomic_fetch_add_explicit(&task_queued, 1, memory_order_release);
  if (!PostQueuedCompletionStatus(queue->poll, 0, (ULONG_PTR)call, NULL)) {
    free(call);
    atomic_fetch_sub_explicit(&task_work, 1, memory_order_acq_rel);
    atomic_fetch_sub_explicit(&task_queued, 1, memory_order_acq_rel);
    if (atomic_fetch_sub_explicit(&queue->pending, 1, memory_order_acq_rel) == 1)
      SetEvent(queue->done);
    return failure(SYSTEM);
  }
#else
  pthread_mutex_lock(&queue->lock);
  if (atomic_load_explicit(&queue->stopping, memory_order_acquire) ||
      cancel_requested(queue->cancel)) {
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
  atomic_fetch_add_explicit(&task_work, 1, memory_order_release);
  atomic_fetch_add_explicit(&task_queued, 1, memory_order_release);
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
FooResult foo_task_cancel(void *pointer) {
  TaskScope *scope = resource(pointer, TASK_SCOPE) ? pointer : NULL;
  if (!scope) return failure(CLOSED);
  atomic_store_explicit(&scope->cancel->cancelled, 1, memory_order_release);
  return (FooResult){0};
}
FooResult foo_task_interrupt(void *pointer) {
#if defined(_WIN32) || defined(__linux__)
  TaskPool *pool = resource(pointer, TASK_POOL) ? pointer : NULL;
  if (!pool) return failure(CLOSED);
  atomic_store_explicit(&pool->cancel->cancelled, 1, memory_order_release);
  return (FooResult){0};
#else
  return foo_task_cancel(pointer);
#endif
}
FooResult foo_task_cancelled(void) {
  return (FooResult){.number = cancel_requested(current_cancel)};
}
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
typedef struct {
#ifdef _WIN32
  DWORD thread;
  GROUP_AFFINITY previous;
#elif defined(__linux__)
  pthread_t thread;
  cpu_set_t previous;
#else
  uint8_t unavailable;
#endif
} Placement;

FooResult foo_topology_count(void) {
#ifdef _WIN32
  DWORD count = GetActiveProcessorCount(ALL_PROCESSOR_GROUPS);
  return count ? (FooResult){.number = count} : failure(SYSTEM);
#else
  long count = sysconf(_SC_NPROCESSORS_ONLN);
  return count > 0 ? (FooResult){.number = (uint64_t)count} : failure(SYSTEM);
#endif
}
FooResult foo_topology_allowed(void) {
#ifdef _WIN32
  GROUP_AFFINITY affinity = {0};
  if (!GetThreadGroupAffinity(GetCurrentThread(), &affinity)) return failure(SYSTEM);
  KAFFINITY mask = affinity.Mask;
  uint64_t count = 0;
  while (mask) { count += mask & 1; mask >>= 1; }
  return count ? (FooResult){.number = count} : failure(SYSTEM);
#elif defined(__linux__)
  cpu_set_t affinity;
  if (pthread_getaffinity_np(pthread_self(), sizeof(affinity), &affinity))
    return failure(SYSTEM);
  return (FooResult){.number = (uint64_t)CPU_COUNT(&affinity)};
#else
  return failure(MISSING);
#endif
}
FooResult foo_platform_page(void) {
#ifdef _WIN32
  SYSTEM_INFO system;
  GetSystemInfo(&system);
  return system.dwPageSize ? (FooResult){.number = system.dwPageSize}
                           : failure(SYSTEM);
#else
  long size = sysconf(_SC_PAGESIZE);
  return size > 0 ? (FooResult){.number = (uint64_t)size} : failure(SYSTEM);
#endif
}
FooResult foo_platform_width(void) {
  return (FooResult){.number = sizeof(void *)};
}
FooResult foo_platform_alignment(void) {
  return (FooResult){.number = _Alignof(max_align_t)};
}
FooResult foo_platform_little(void) {
  const uint16_t marker = 1;
  return (FooResult){.number = *(const uint8_t *)&marker == 1};
}
FooResult foo_platform_supports(FooText feature) {
  if (cpu_named(feature, "mapping") || cpu_named(feature, "position") ||
      cpu_named(feature, "locking"))
    return (FooResult){.number = 1};
#ifdef _WIN32
  if (cpu_named(feature, "affinity") || cpu_named(feature, "numa"))
    return (FooResult){.number = 1};
#elif defined(__linux__)
  if (cpu_named(feature, "affinity") || cpu_named(feature, "numa") ||
      cpu_named(feature, "limits"))
    return (FooResult){.number = 1};
#else
  if (cpu_named(feature, "limits")) return (FooResult){.number = 1};
#endif
  return (FooResult){0};
}
FooResult foo_topology_current(void) {
#ifdef _WIN32
  PROCESSOR_NUMBER number;
  GetCurrentProcessorNumberEx(&number);
  return (FooResult){.number = (uint64_t)number.Group * 64 + number.Number};
#elif defined(__linux__)
  int cpu = sched_getcpu();
  return cpu >= 0 ? (FooResult){.number = (uint64_t)cpu} : failure(SYSTEM);
#else
  return failure(MISSING);
#endif
}
FooResult foo_topology_nodes(void) {
#ifdef _WIN32
  ULONG highest = 0;
  return GetNumaHighestNodeNumber(&highest)
      ? (FooResult){.number = (uint64_t)highest + 1} : failure(SYSTEM);
#elif defined(__linux__)
  DIR *directory = opendir("/sys/devices/system/node");
  if (!directory) return failure(MISSING);
  uint64_t count = 0;
  struct dirent *item;
  while ((item = readdir(directory))) {
    unsigned index;
    char extra;
    if (sscanf(item->d_name, "node%u%c", &index, &extra) == 1) count++;
  }
  closedir(directory);
  return count ? (FooResult){.number = count} : failure(MISSING);
#else
  return failure(MISSING);
#endif
}
FooResult foo_topology_node(uint64_t cpu) {
#ifdef _WIN32
  if (cpu / 64 >= GetActiveProcessorGroupCount()) return failure(BOUNDS);
  PROCESSOR_NUMBER number = {.Group = (WORD)(cpu / 64), .Number = (BYTE)(cpu % 64)};
  USHORT node = 0;
  return GetNumaProcessorNodeEx(&number, &node)
      ? (FooResult){.number = node} : failure(BOUNDS);
#elif defined(__linux__)
  if (cpu >= CPU_SETSIZE) return failure(BOUNDS);
  char path[96];
  snprintf(path, sizeof(path), "/sys/devices/system/cpu/cpu%llu",
           (unsigned long long)cpu);
  DIR *directory = opendir(path);
  if (!directory) return failure(BOUNDS);
  FooResult result = failure(MISSING);
  struct dirent *item;
  while ((item = readdir(directory))) {
    unsigned index;
    char extra;
    if (sscanf(item->d_name, "node%u%c", &index, &extra) == 1) {
      result = (FooResult){.number = index};
      break;
    }
  }
  closedir(directory);
  return result;
#else
  (void)cpu;
  return failure(MISSING);
#endif
}
FooResult foo_topology_place(uint64_t node) {
#if defined(_WIN32) || defined(__linux__)
#ifdef _WIN32
  uint64_t limit = (uint64_t)GetActiveProcessorGroupCount() * 64;
#else
  uint64_t limit = CPU_SETSIZE;
#endif
  for (uint64_t cpu = 0; cpu < limit; cpu++) {
    FooResult mapped = foo_topology_node(cpu);
    if (!mapped.error && mapped.number == node) {
      FooResult placement = foo_topology_pin(cpu);
      if (!placement.error) return placement;
    }
  }
  return failure(BOUNDS);
#else
  (void)node;
  return failure(MISSING);
#endif
}
FooResult foo_topology_pin(uint64_t cpu) {
#if defined(_WIN32) || defined(__linux__)
  Placement *placement = calloc(1, sizeof(*placement));
  if (!placement) return failure(MEMORY);
#ifdef _WIN32
  uint64_t group = cpu / 64;
  if (group >= GetActiveProcessorGroupCount()) {
    free(placement);
    return failure(BOUNDS);
  }
  GROUP_AFFINITY selected = {0};
  selected.Group = (WORD)group;
  selected.Mask = ((KAFFINITY)1) << (cpu % 64);
  placement->thread = GetCurrentThreadId();
  if (!SetThreadGroupAffinity(GetCurrentThread(), &selected, &placement->previous)) {
    free(placement);
    return failure(SYSTEM);
  }
#else
  if (cpu >= CPU_SETSIZE) {
    free(placement);
    return failure(BOUNDS);
  }
  placement->thread = pthread_self();
  if (pthread_getaffinity_np(placement->thread, sizeof(placement->previous),
                            &placement->previous)) {
    free(placement);
    return failure(SYSTEM);
  }
  cpu_set_t selected;
  CPU_ZERO(&selected);
  CPU_SET((int)cpu, &selected);
  if (pthread_setaffinity_np(placement->thread, sizeof(selected), &selected)) {
    free(placement);
    return failure(SYSTEM);
  }
#endif
  if (!adopt(placement, sizeof(*placement), PLACEMENTS)) {
#ifdef _WIN32
    SetThreadGroupAffinity(GetCurrentThread(), &placement->previous, NULL);
#else
    pthread_setaffinity_np(placement->thread, sizeof(placement->previous),
                           &placement->previous);
#endif
    free(placement);
    return failure(MEMORY);
  }
  return (FooResult){.pointer = placement};
#else
  (void)cpu;
  return failure(MISSING);
#endif
}
FooResult foo_topology_restore(void *pointer) {
  Resource *entry = resource(pointer, PLACEMENTS);
  if (!entry) return failure(CLOSED);
#ifdef _WIN32
  Placement *placement = pointer;
  if (placement->thread != GetCurrentThreadId()) return failure(ARGUMENT);
  if (!SetThreadGroupAffinity(GetCurrentThread(), &placement->previous, NULL))
    return failure(SYSTEM);
#elif defined(__linux__)
  Placement *placement = pointer;
  if (!pthread_equal(placement->thread, pthread_self())) return failure(ARGUMENT);
  if (pthread_setaffinity_np(placement->thread, sizeof(placement->previous),
                             &placement->previous)) return failure(SYSTEM);
#else
  return failure(MISSING);
#endif
  atomic_store_explicit(&entry->closed, 1, memory_order_release);
  return (FooResult){0};
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
        FileMapping *mapping = entry->data;
        unmap_file(mapping);
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
        for (size_t index = 0; index < ((TaskScope *)entry->data)->count; index++)
          foo_thread_wait(((TaskScope *)entry->data)->threads[index]);
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
      cancel_release(((TaskScope *)entry->data)->cancel);
#if defined(_WIN32) || defined(__linux__)
    if (entry->kind == TASK_POOL)
      cancel_release(((TaskPool *)entry->data)->cancel);
#endif
#endif
    free(entry->data);
    free(entry);
  }
  count = 0;
  arguments = NULL;
  active_span = NULL;
#ifdef _WIN32
#ifdef FOO_SERVICE_NET
  if (winsock) {
    WSACleanup();
    winsock = 0;
  }
#endif
#endif
}
