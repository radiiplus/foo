#include <stdint.h>

typedef struct { int32_t first, second; } Pair;

Pair qbe_foreign_pair(Pair input) {
    input.second += 2;
    return input;
}
