#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#include <string.h>

typedef struct {
  const uint8_t *data;
  size_t len;
} FOOText;

#define FOO_ARCH 1
#include "../../src/backend/c/arch.h"

int main(void) {
  const uint64_t words[] = {0, UINT64_MAX, UINT64_C(0x8000000000000001)};
  const FOOText input = {(const uint8_t *)words, 3};
  if (foo_arch_count(words[0]) != 0 || foo_arch_count(words[1]) != 64 ||
      foo_arch_count(words[2]) != 2)
    return 1;
  if (foo_arch_tally(input) != 66 ||
      foo_arch_tally((FOOText){NULL, 0}) != 0)
    return 2;
  const uint64_t other[] = {UINT64_C(12), 1, 1};
  uint8_t unaligned[sizeof(words) + 1] = {0};
  const FOOText right = {(const uint8_t *)other, 3};
  const FOOText output = {unaligned + 1, 3};
  const uint64_t expected[4][3] = {
      {UINT64_C(12), UINT64_MAX, UINT64_C(0x8000000000000001)},
      {0, 1, 1},
      {0, UINT64_MAX - 1, UINT64_C(0x8000000000000000)},
      {UINT64_C(12), UINT64_MAX - 1, UINT64_C(0x8000000000000000)},
  };
  for (uint64_t operation = 0; operation < 4; operation++) {
    if (!foo_arch_combine(input, right, output, operation) ||
        memcmp(unaligned + 1, expected[operation], sizeof(words)) != 0)
      return 3;
  }
  if (foo_arch_combine(input, right, (FOOText){unaligned + 1, 2}, 0) ||
      foo_arch_combine(input, right, output, 4) ||
      !foo_arch_combine((FOOText){NULL, 0}, (FOOText){NULL, 0},
                        (FOOText){NULL, 0}, 0))
    return 4;
  return 0;
}
