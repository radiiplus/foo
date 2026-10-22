#if !defined(FOO_SERVICE_SELECTIVE) || defined(FOO_SERVICE_CPU)
#if defined(_M_X64) || defined(_M_IX86) || defined(__x86_64__) || defined(__i386__)
static void probe(unsigned leaf, unsigned subleaf, unsigned *a,
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
static uint64_t xcr(void) {
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
  probe(0, 0, &a, &b, &c, &d);
  unsigned maximum = a;
  if (maximum < 1) return (FooResult){0};
  probe(1, 0, &a, &b, &c, &d);
  if (supports(feature, "sse2")) return (FooResult){.number = !!(d & (1u << 26))};
  int avx = (c & (1u << 27)) && (c & (1u << 28)) &&
            (xcr() & 0x6) == 0x6;
  if (supports(feature, "fma"))
    return (FooResult){.number = avx && !!(c & (1u << 12))};
  if (maximum < 7) return (FooResult){0};
  probe(7, 0, &a, &b, &c, &d);
  if (supports(feature, "avx2"))
    return (FooResult){.number = avx && !!(b & (1u << 5))};
  if (supports(feature, "avx512f"))
    return (FooResult){.number = avx && (xcr() & 0xe6) == 0xe6 &&
                                  !!(b & (1u << 16))};
#elif defined(__aarch64__) || defined(_M_ARM64)
  if (supports(feature, "neon")) return (FooResult){.number = 1};
#if defined(__linux__)
  if (supports(feature, "sve"))
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
static CPU_SSE size_t sse(const uint8_t *left, const uint8_t *right,
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
static CPU_AVX size_t avx(const uint8_t *left, const uint8_t *right,
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
static int overlap(const uint8_t *a, const uint8_t *b, size_t length) {
  uintptr_t left = (uintptr_t)a, right = (uintptr_t)b;
  return left != right && (left < right ? right - left : left - right) < length;
}
static unsigned capabilities(void) {
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
      overlap(output.data, left.data, output.len) ||
      overlap(output.data, right.data, output.len)) return failure(ARGUMENT);
  if (!output.len) return (FooResult){0};
  uint8_t *destination = (uint8_t *)output.data;
  size_t index = 0;
#if (defined(__clang__) || defined(__GNUC__)) && \
    (defined(_M_X64) || defined(_M_IX86) || defined(__x86_64__) || defined(__i386__))
  if (foo_cpu_runtime((FooText){(const uint8_t *)"avx2", 4}).number)
    index = avx(left.data, right.data, destination, output.len);
#endif
#if defined(_M_X64) || defined(_M_IX86) || defined(__x86_64__) || defined(__i386__)
#if defined(__clang__) || defined(__GNUC__) || defined(_M_X64) || defined(__x86_64__)
  if (foo_cpu_runtime((FooText){(const uint8_t *)"sse2", 4}).number)
    index += sse(left.data + index, right.data + index,
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
static CPU_AVX512 size_t avx512f32(const float *left,
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
static CPU_AVX512 size_t avx512f64(const double *left,
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
static CPU_AVX size_t avxf32(const float *left, const float *right,
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
static CPU_AVX size_t avxf64(const double *left, const double *right,
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
static CPU_SSE size_t ssef32(const float *left, const float *right,
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
static CPU_SSE size_t ssef64(const double *left, const double *right,
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
        overlap(output.data + offset, left.data + offset, length))) ||
      (!(flags & 2) && operation != 4 && (!right.data ||
        overlap(output.data + offset, right.data + offset, length))))
    return (FooResult){0};
  size_t cursor = (size_t)start;
  int direct = flags == 0 && operation < 4 && post_operation == 4;
  unsigned features = capabilities();
#if (defined(__clang__) || defined(__GNUC__)) && \
    (defined(_M_X64) || defined(_M_IX86) || defined(__x86_64__) || defined(__i386__))
#if !defined(FOO_DISABLE_AVX512)
  if (count - cursor >= 256 && (features & 8))
    cursor += width == 32
        ? (direct ? avx512f32((const float *)left.data + cursor,
                       (const float *)right.data + cursor,
                       (float *)output.data + cursor, (size_t)count - cursor,
                       operation)
            : cpu_map_avx512f32((const float *)left.data + cursor,
                       (const float *)right.data + cursor,
                       (float *)output.data + cursor, (size_t)count - cursor,
                       operation, flags, (float)first, (float)second,
                       post_operation, (float)post))
        : (direct ? avx512f64((const double *)left.data + cursor,
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
        ? (direct ? avxf32((const float *)left.data + cursor,
                     (const float *)right.data + cursor,
                     (float *)output.data + cursor, (size_t)count - cursor,
                     operation)
            : cpu_map_avxf32((const float *)left.data + cursor,
                     (const float *)right.data + cursor,
                     (float *)output.data + cursor, (size_t)count - cursor,
                     operation, flags, (float)first, (float)second,
                     post_operation, (float)post))
        : (direct ? avxf64((const double *)left.data + cursor,
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
        ? (direct ? ssef32((const float *)left.data + cursor,
                     (const float *)right.data + cursor,
                     (float *)output.data + cursor, (size_t)count - cursor,
                     operation)
            : cpu_map_ssef32((const float *)left.data + cursor,
                     (const float *)right.data + cursor,
                     (float *)output.data + cursor, (size_t)count - cursor,
                     operation, flags, (float)first, (float)second,
                     post_operation, (float)post))
        : (direct ? ssef64((const double *)left.data + cursor,
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
