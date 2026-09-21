#if defined(FOO_COPY_AVX)
#include <immintrin.h>
#endif
static void foo_transfer(void *destination, const void *source, size_t size) {
  if (!size || destination == source) return;
#if defined(FOO_COPY_AVX)
  if (size < 128 || size > 256) { memmove(destination, source, size); return; }
  /* Read the entire range before writing, including overlapping copies.
     Head/tail vectors stay within the range for every size from 128 to 256. */
  uint8_t *out = destination;
  const uint8_t *in = source;
  __m256i a = _mm256_loadu_si256((const __m256i *)(in));
  __m256i b = _mm256_loadu_si256((const __m256i *)(in + 32));
  __m256i c = _mm256_loadu_si256((const __m256i *)(in + 64));
  __m256i d = _mm256_loadu_si256((const __m256i *)(in + 96));
  __m256i e = _mm256_loadu_si256((const __m256i *)(in + size - 128));
  __m256i f = _mm256_loadu_si256((const __m256i *)(in + size - 96));
  __m256i g = _mm256_loadu_si256((const __m256i *)(in + size - 64));
  __m256i h = _mm256_loadu_si256((const __m256i *)(in + size - 32));
  _mm256_storeu_si256((__m256i *)(out), a);
  _mm256_storeu_si256((__m256i *)(out + 32), b);
  _mm256_storeu_si256((__m256i *)(out + 64), c);
  _mm256_storeu_si256((__m256i *)(out + 96), d);
  _mm256_storeu_si256((__m256i *)(out + size - 128), e);
  _mm256_storeu_si256((__m256i *)(out + size - 96), f);
  _mm256_storeu_si256((__m256i *)(out + size - 64), g);
  _mm256_storeu_si256((__m256i *)(out + size - 32), h);
  _mm256_zeroupper();
#elif defined(FOO_COPY_X86)
  if (size < 1024 || size > 8192) { memmove(destination, source, size); return; }
  /* Preserve memmove overlap semantics and the ABI's clear direction flag. */
  uintptr_t left = (uintptr_t)destination, right = (uintptr_t)source;
  if ((left > right ? left - right : right - left) >= size) {
    __asm__ __volatile__("rep movsb" : "+D"(destination), "+S"(source), "+c"(size) : : "memory");
    return;
  }
  memmove(destination, source, size);
#elif defined(FOO_COPY_ARM)
  __builtin_memmove(destination, source, size);
#else
  memmove(destination, source, size);
#endif
}
