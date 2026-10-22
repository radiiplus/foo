#include <stdint.h>
#include <stdio.h>
#include <string.h>

extern void *foo_qbe_alloc(void *scope, uint64_t size, uint64_t alignment);
extern void foo_qbe_free(void *scope);

int main(void) {
    void *scope = NULL;
    unsigned char *first = foo_qbe_alloc(&scope, 0, 16);
    unsigned char *second = foo_qbe_alloc(&scope, 37, 8);
    if (!first || !second || ((uintptr_t)first & 15) ||
        ((uintptr_t)second & 7)) return 1;
    for (size_t index = 0; index < 37; ++index)
        if (second[index] != 0) return 2;
    memset(second, 0xa5, 37);
    foo_qbe_free(&scope);
    if (scope != NULL) return 3;
    foo_qbe_free(&scope);
    first = foo_qbe_alloc(&scope, 1, 32);
    if (!first || ((uintptr_t)first & 31) || first[0] != 0) return 4;
    foo_qbe_free(&scope);
    puts("QBE ownership probe: ok");
    return 0;
}
