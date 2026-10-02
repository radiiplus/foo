#if defined(FOO_ARCH) && defined(_MSC_VER) && \
    (defined(_M_X64) || defined(_M_AMD64))
#include <intrin.h>
#endif

#ifdef FOO_ARCH
static uint32_t foo_arch_count(uint64_t value) {
  uint32_t count = 0;
  while (value) {
    value &= value - 1;
    count++;
  }
  return count;
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
#endif
