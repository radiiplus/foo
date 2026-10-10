#if defined(FOO_ARCH) && defined(_MSC_VER) && \
    (defined(_M_X64) || defined(_M_AMD64))
#include <intrin.h>
#endif
#if defined(FOO_ARCH) && !defined(_MSC_VER) && \
    (defined(__x86_64__) || defined(__i386__))
#include <cpuid.h>
#endif
#if defined(FOO_ARCH) && defined(_MSC_VER)
#include <string.h>
#endif

#if defined(__GNUC__) || defined(__clang__)
#define FOO_ARCH_COPY __builtin_memcpy
#else
#define FOO_ARCH_COPY memcpy
#endif

#ifdef FOO_ARCH
static uint32_t foo_arch_count(uint64_t value) {
#if defined(__GNUC__) || defined(__clang__)
  return (uint32_t)__builtin_popcountll(value);
#elif defined(_MSC_VER) && defined(__POPCNT__)
  return (uint32_t)__popcnt64(value);
#else
  value -= (value >> 1) & UINT64_C(0x5555555555555555);
  value = (value & UINT64_C(0x3333333333333333)) +
          ((value >> 2) & UINT64_C(0x3333333333333333));
  value = (value + (value >> 4)) & UINT64_C(0x0f0f0f0f0f0f0f0f);
  return (uint32_t)((value * UINT64_C(0x0101010101010101)) >> 56);
#endif
}

#if (defined(__GNUC__) || defined(__clang__)) && \
    (defined(__x86_64__) || defined(__i386__))
static bool foo_arch_popcnt_available(void) {
#if defined(_MSC_VER)
  int registers[4];
  __cpuid(registers, 1);
  return (registers[2] & (1 << 23)) != 0;
#else
  unsigned int eax, ebx, ecx, edx;
  return __get_cpuid(1, &eax, &ebx, &ecx, &edx) &&
         (ecx & bit_POPCNT) != 0;
#endif
}

__attribute__((target("popcnt")))
static uint64_t foo_arch_tally_popcnt(FOOText values) {
  uint64_t total = 0;
  for (size_t index = 0; index < values.len; index++) {
    uint64_t word;
    FOO_ARCH_COPY(&word, values.data + index * sizeof(word), sizeof(word));
    total += __builtin_popcountll(word);
  }
  return total;
}
#endif

static uint64_t foo_arch_tally(FOOText values) {
#if (defined(__GNUC__) || defined(__clang__)) && \
    (defined(__x86_64__) || defined(__i386__))
  if (foo_arch_popcnt_available())
    return foo_arch_tally_popcnt(values);
#endif
  uint64_t total = 0;
  for (size_t index = 0; index < values.len; index++) {
    uint64_t word;
    FOO_ARCH_COPY(&word, values.data + index * sizeof(word), sizeof(word));
    total += foo_arch_count(word);
  }
  return total;
}

static bool foo_arch_combine(FOOText left, FOOText right, FOOText output,
                             uint64_t operation) {
  if (operation > 3 || left.len != right.len || left.len != output.len ||
      left.len > SIZE_MAX / sizeof(uint64_t)) return false;
  for (size_t index = 0; index < left.len; index++) {
    uint64_t a, b, value;
    FOO_ARCH_COPY(&a, left.data + index * sizeof(a), sizeof(a));
    FOO_ARCH_COPY(&b, right.data + index * sizeof(b), sizeof(b));
    switch (operation) {
      case 0: value = a | b; break;
      case 1: value = a & b; break;
      case 2: value = a & ~b; break;
      default: value = a ^ b; break;
    }
    FOO_ARCH_COPY((uint8_t *)output.data + index * sizeof(value), &value,
                  sizeof(value));
  }
  return true;
}

static void foo_arch_pause(void) {
#if defined(_MSC_VER) && (defined(_M_X64) || defined(_M_AMD64))
  _mm_pause();
#elif defined(__x86_64__) || defined(__i386__)
  __asm__ volatile("pause" ::: "memory");
#elif defined(__aarch64__) || defined(__arm__)
  __asm__ volatile("yield" ::: "memory");
#elif defined(__riscv)
  __asm__ volatile("nop" ::: "memory");
#else
#error "FOO arch intrinsics require x86, ARM, or RISC-V"
#endif
}

static uint64_t foo_arch_ticks(void) {
#if defined(_MSC_VER) && (defined(_M_X64) || defined(_M_AMD64))
  _ReadWriteBarrier();
  uint64_t value = __rdtsc();
  _ReadWriteBarrier();
  return value;
#elif defined(__x86_64__) || defined(__i386__)
  uint32_t low, high;
  __asm__ volatile("lfence; rdtsc" : "=a"(low), "=d"(high) :: "memory");
  return ((uint64_t)high << 32) | low;
#elif defined(__aarch64__)
  uint64_t value;
  __asm__ volatile("mrs %0, cntvct_el0" : "=r"(value));
  return value;
#elif defined(__riscv)
  uint64_t value;
  __asm__ volatile("rdcycle %0" : "=r"(value));
  return value;
#else
#error "FOO tick counters require x86-64, AArch64, or RISC-V"
#endif
}
static bool foo_arch_same(FOOText feature, const char *label, size_t length) {
  for (size_t index = 0; index < length; index++) {
    if (feature.data[index] != (uint8_t)label[index]) return false;
  }
  return true;
}
static bool foo_arch_target(FOOText feature) {
#define FOO_FEATURE(label) (feature.len == sizeof(label) - 1 && \
                            foo_arch_same(feature, label, sizeof(label) - 1))
  if (FOO_FEATURE("sse2")) {
#if defined(__SSE2__) || defined(_M_X64) || defined(_M_AMD64)
    return true;
#else
    return false;
#endif
  }
  if (FOO_FEATURE("avx2")) {
#if defined(__AVX2__)
    return true;
#else
    return false;
#endif
  }
  if (FOO_FEATURE("avx512f")) {
#if defined(__AVX512F__)
    return true;
#else
    return false;
#endif
  }
  if (FOO_FEATURE("fma")) {
#if defined(__FMA__)
    return true;
#else
    return false;
#endif
  }
  if (FOO_FEATURE("neon")) {
#if defined(__ARM_NEON) || defined(__ARM_NEON__)
    return true;
#else
    return false;
#endif
  }
  if (FOO_FEATURE("sve")) {
#if defined(__ARM_FEATURE_SVE)
    return true;
#else
    return false;
#endif
  }
#undef FOO_FEATURE
  return false;
}
static void foo_arch_prefetch(FOOText bytes, uint64_t offset) {
  if (offset >= bytes.len) return;
#if defined(_MSC_VER) && (defined(_M_X64) || defined(_M_AMD64) || defined(_M_IX86))
  _mm_prefetch((const char *)bytes.data + offset, _MM_HINT_T0);
#elif defined(__GNUC__) || defined(__clang__)
  __builtin_prefetch(bytes.data + offset, 0, 3);
#endif
}
static void foo_arch_stage(FOOText bytes, uint64_t offset) {
  if (offset >= bytes.len) return;
#if defined(_MSC_VER) && (defined(_M_X64) || defined(_M_AMD64) || defined(_M_IX86))
  _mm_prefetch((const char *)bytes.data + offset, _MM_HINT_T0);
#elif defined(__GNUC__) || defined(__clang__)
  __builtin_prefetch(bytes.data + offset, 1, 3);
#endif
}
#endif
