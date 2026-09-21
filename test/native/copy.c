#include <time.h>
#include <assert.h>

__attribute__((noinline)) static void reference(void *destination, const void *source, size_t size) {
  memmove(destination, source, size);
}

static double timer(void) {
  struct timespec value;
  timespec_get(&value, TIME_UTC);
  return (double)value.tv_sec + (double)value.tv_nsec / 1e9;
}

static double measure(void (*operation)(void *, const void *, size_t), size_t size, size_t offset) {
  static uint8_t source[65536 + 64], destination[65536 + 64];
  size_t count = 67108864 / size;
  if (count < 20000) count = 20000;
  memset(source, 44, sizeof(source));
  double start = timer();
  for (size_t i = 0; i < count; ++i) operation(destination + offset, source + offset, size);
  double elapsed = timer() - start;
  assert(destination[size - 1 + offset] == 44);
  return elapsed / count * 1e9;
}

static double median(double *values, size_t count) {
  for (size_t i = 1; i < count; ++i) for (size_t j = i; j && values[j] < values[j - 1]; --j) {
    double value = values[j]; values[j] = values[j - 1]; values[j - 1] = value;
  }
  return values[count / 2];
}

int main(int argc, char **argv) {
  (void)argv;
  uint8_t actual[2048], expected[2048];
  for (size_t size = 0; size <= 520; ++size) for (size_t offset = 0; offset < 33; ++offset) {
    for (size_t i = 0; i < sizeof(actual); ++i) actual[i] = expected[i] = (uint8_t)(i * 31);
    candidate(actual + 8 + offset, actual + 8, size);
    reference(expected + 8 + offset, expected + 8, size);
    assert(!memcmp(actual, expected, sizeof(actual)));
    candidate(actual + 8, actual + 8 + offset, size);
    reference(expected + 8, expected + 8 + offset, size);
    assert(!memcmp(actual, expected, sizeof(actual)));
    candidate(actual + 1024 + offset, actual + 8, size);
    reference(expected + 1024 + offset, expected + 8, size);
    assert(!memcmp(actual, expected, sizeof(actual)));
  }
  if (argc == 1) { puts("copy correctness passed"); return 0; }
  const size_t sizes[] = {32, 256, 4096, 65536};
  printf("[");
  for (size_t index = 0; index < 4; ++index) for (size_t alignment = 0; alignment < 2; ++alignment) {
    double selected[9], plain[9];
    size_t size = sizes[index], offset = alignment ? 7 : 0;
    measure(candidate, size, offset); measure(reference, size, offset);
    for (size_t trial = 0; trial < 9; ++trial) {
      if (trial % 2) { plain[trial] = measure(reference, size, offset); selected[trial] = measure(candidate, size, offset); }
      else { selected[trial] = measure(candidate, size, offset); plain[trial] = measure(reference, size, offset); }
    }
    double actual = median(selected, 9), expected = median(plain, 9);
    printf("%s{\"size\":%zu,\"offset\":%zu,\"foo\":%.3f,\"c\":%.3f,\"ratio\":%.4f}", index || alignment ? "," : "", size, offset, actual, expected, actual / expected);
  }
  puts("]"); foo_shutdown(); return 0;
}
