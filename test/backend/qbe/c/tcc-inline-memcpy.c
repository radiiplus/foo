#include <stdint.h>
#include <stdio.h>
#include <string.h>

#ifndef __FOO_TCC_INLINE_MEMCPY__
#error Patched TinyCC x64 is required
#endif

static int calls;
static unsigned char *destination(unsigned char *data) {
    calls++;
    return data;
}

int main(void) {
    unsigned char source[40], target[40];
    for (int index = 0; index < 40; ++index) source[index] = index + 1;
    memset(target, 0xa5, sizeof(target));
    calls = 0;
    void *fixed = __builtin_memcpy(destination(target), source, 16);
    if (fixed != target || calls != 1 || memcmp(target, source, 16))
        return 4;
    for (int index = 16; index < 40; ++index)
        if (target[index] != 0xa5) return 5;
    for (int size = 0; size <= 32; ++size) {
        memset(target, 0xa5, sizeof(target));
        calls = 0;
        void *returned = __builtin_memcpy(destination(target), source,
            (size_t)size);
        if (returned != target || calls != 1) return 1;
        if (memcmp(target, source, (size_t)size)) return 2;
        for (int index = size; index < 40; ++index)
            if (target[index] != 0xa5) return 3;
    }
    puts("TinyCC inline memcpy: ok");
    return 0;
}
