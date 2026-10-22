#include <assert.h>
#include <stdint.h>
#include <string.h>

typedef struct { uint64_t low, high; } Wide;
extern int foo_qbe_integer64(uint64_t, uint64_t, unsigned, int, unsigned,
    uint64_t *);
extern int foo_qbe_integer128(const void *, const void *, unsigned, int,
    unsigned, void *);
extern int foo_qbe_integer_compare64(uint64_t, uint64_t, unsigned, int);
extern int foo_qbe_integer_compare128(const void *, const void *, unsigned, int);
extern int foo_qbe_integer_bit64(uint64_t, uint64_t, unsigned, int,
    unsigned, uint64_t, uint64_t *);
extern int foo_qbe_integer_bit128(const void *, const void *, unsigned,
    int, unsigned, uint64_t, void *);
extern int foo_qbe_packed_compare(const void *, const void *, uint64_t,
    uint64_t, int);

int main(void) {
    uint64_t out = 0;
    assert(foo_qbe_integer64(7, 1, 4, 1, 0, &out) == 1);
    assert(foo_qbe_integer64(15, 1, 4, 0, 0, &out) == 1);
    assert(foo_qbe_integer64(8, 1, 4, 1, 1, &out) == 1);
    assert(foo_qbe_integer64(0, 0, 4, 0, 3, &out) == 2);
    assert(foo_qbe_integer64(0xf9, 3, 8, 1, 3, &out) == 0 &&
        (int64_t)out == -2);
    assert(foo_qbe_integer64(0xf9, 3, 8, 1, 4, &out) == 0 &&
        (int64_t)out == -1);
    assert(foo_qbe_integer64(0x8000000000000000ULL, UINT64_MAX,
        64, 1, 3, &out) == 1);
    assert(foo_qbe_integer64(0x8000000000000000ULL, UINT64_MAX,
        64, 1, 4, &out) == 0 && out == 0);
    assert(foo_qbe_integer64(UINT64_MAX, 1, 64, 0, 0, &out) == 1);
    assert(foo_qbe_integer64(2, 3, 3, 0, 2, &out) == 0 && out == 6);
    assert(foo_qbe_integer64(3, 3, 3, 0, 2, &out) == 1);
    assert(foo_qbe_integer_compare64(0x80, 0x7f, 8, 1) < 0);
    assert(foo_qbe_integer_compare64(0x80, 0x7f, 8, 0) > 0);
    assert(foo_qbe_integer_bit64(1, 0, 3, 0, 4, 1, &out) == 0 && out == 2);
    assert(foo_qbe_integer_bit64(1, 0, 3, 0, 4, 3, &out) == 1);
    assert(foo_qbe_integer_bit64((uint64_t)-4, 0, 17, 1, 6, 1,
        &out) == 0 && (int64_t)out == -2);

    Wide a = {UINT64_MAX, 0}, b = {1, 0}, result = {0, 0};
    assert(foo_qbe_integer128(&a, &b, 128, 0, 0, &result) == 0 &&
        result.low == 0 && result.high == 1);
    a = (Wide){0, 1};
    b = (Wide){2, 0};
    assert(foo_qbe_integer128(&a, &b, 128, 0, 3, &result) == 0 &&
        result.low == 0x8000000000000000ULL && result.high == 0);
    assert(foo_qbe_integer128(&a, &b, 128, 0, 2, &result) == 0 &&
        result.low == 0 && result.high == 2);
    a = (Wide){0, 0x8000000000000000ULL};
    b = (Wide){UINT64_MAX, UINT64_MAX};
    assert(foo_qbe_integer128(&a, &b, 128, 1, 3, &result) == 1);
    assert(foo_qbe_integer_compare128(&a, &b, 128, 1) < 0);
    assert(foo_qbe_integer_compare128(&a, &b, 128, 0) < 0);
    a = (Wide){0, 1};
    assert(foo_qbe_integer_bit128(&a, &a, 128, 0, 7, 1,
        &result) == 0 && result.low == 2 && result.high == 1);
    unsigned char packed_a[17] = {0}, packed_b[17] = {0};
    packed_a[16] = 0x80;
    assert(foo_qbe_packed_compare(packed_a, packed_b, 0, 128, 1) == 0);
    assert(foo_qbe_packed_compare(packed_a, packed_b, 8, 128, 1) < 0);
    assert(foo_qbe_packed_compare(packed_a, packed_b, 8, 128, 0) > 0);
    return 0;
}
