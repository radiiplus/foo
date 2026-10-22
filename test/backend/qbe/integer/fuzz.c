#include <assert.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>

typedef unsigned __int128 U128;
typedef __int128 I128;
typedef struct { uint64_t low, high; } Wide;

extern int foo_qbe_integer64(uint64_t, uint64_t, unsigned, int, unsigned,
    uint64_t *);
extern int foo_qbe_integer128(const void *, const void *, unsigned, int,
    unsigned, void *);
extern int foo_qbe_integer_compare64(uint64_t, uint64_t, unsigned, int);
extern int foo_qbe_integer_compare128(const void *, const void *, unsigned, int);

static uint64_t state = UINT64_C(0x5eed1234abcdef89);

static uint64_t random64(void) {
    state ^= state << 13;
    state ^= state >> 7;
    state ^= state << 17;
    return state;
}

static U128 bits(Wide value) {
    return ((U128)value.high << 64) | value.low;
}

static Wide limbs(U128 value) {
    return (Wide){(uint64_t)value, (uint64_t)(value >> 64)};
}

static int reference(U128 a, U128 b, unsigned width, int signedness,
    unsigned operation, U128 *output) {
    U128 mask = width == 128 ? ~(U128)0 : ((U128)1 << width) - 1;
    a &= mask;
    b &= mask;
    if (operation >= 3 && b == 0) return 2;
    if (signedness) {
        U128 sign = (U128)1 << (width - 1);
        I128 x = (I128)(a & sign ? a | ~mask : a);
        I128 y = (I128)(b & sign ? b | ~mask : b);
        I128 value = 0;
        int overflow = 0;
        if (operation == 0) overflow = __builtin_add_overflow(x, y, &value);
        if (operation == 1) overflow = __builtin_sub_overflow(x, y, &value);
        if (operation == 2) overflow = __builtin_mul_overflow(x, y, &value);
        I128 minimum = (I128)((U128)1 << (width - 1));
        minimum = width == 128 ? minimum : -minimum;
        I128 maximum = (I128)(((U128)1 << (width - 1)) - 1);
        if (operation == 3 || operation == 4) {
            if (x == minimum && y == -1) {
                if (operation == 3) return 1;
                value = 0;
            } else value = operation == 3 ? x / y : x % y;
        }
        if (overflow || value < minimum || value > maximum) return 1;
        *output = (U128)value & mask;
    } else {
        U128 value = 0;
        int overflow = 0;
        if (operation == 0) overflow = __builtin_add_overflow(a, b, &value);
        if (operation == 1) overflow = __builtin_sub_overflow(a, b, &value);
        if (operation == 2) overflow = __builtin_mul_overflow(a, b, &value);
        if (operation == 3) value = a / b;
        if (operation == 4) value = a % b;
        if (overflow || value > mask) return 1;
        *output = value;
    }
    return 0;
}

int main(void) {
    unsigned count = 0;
    for (unsigned width = 1; width <= 128; ++width) {
        U128 mask = width == 128 ? ~(U128)0 : ((U128)1 << width) - 1;
        for (unsigned sample = 0; sample < 80; ++sample) {
            U128 a = (((U128)random64() << 64) | random64()) & mask;
            U128 b = (((U128)random64() << 64) | random64()) & mask;
            if (sample % 8 == 0) a = (U128)1 << (width - 1);
            if (sample % 8 == 1) a = mask;
            if (sample % 8 == 2) b = 0;
            if (sample % 8 == 3) b = mask;
            Wide left = limbs(a), right = limbs(b), actual = {0, 0};
            for (int signedness = 0; signedness <= 1; ++signedness) {
                int comparison = signedness ?
                    ((I128)(a & ((U128)1 << (width - 1)) ? a | ~mask : a) <
                     (I128)(b & ((U128)1 << (width - 1)) ? b | ~mask : b) ?
                      -1 :
                     (I128)(a & ((U128)1 << (width - 1)) ? a | ~mask : a) >
                     (I128)(b & ((U128)1 << (width - 1)) ? b | ~mask : b) ?
                      1 : 0) : (a < b ? -1 : a > b ? 1 : 0);
                int order = width <= 64 ?
                    foo_qbe_integer_compare64(left.low, right.low,
                        width, signedness) :
                    foo_qbe_integer_compare128(&left, &right,
                        width, signedness);
                assert(order == comparison);
                for (unsigned operation = 0; operation <= 4; ++operation) {
                    U128 expected = 0;
                    int failure = reference(a, b, width,
                        signedness, operation, &expected);
                    int error;
                    if (width <= 64) {
                        error = foo_qbe_integer64(left.low, right.low,
                            width, signedness, operation, &actual.low);
                        actual.high = 0;
                    } else {
                        error = foo_qbe_integer128(&left, &right,
                            width, signedness, operation, &actual);
                    }
                    if (error != failure ||
                        (!error && (bits(actual) & mask) != expected)) {
                        fprintf(stderr, "width=%u sample=%u signed=%d op=%u\n",
                            width, sample, signedness, operation);
                        return 1;
                    }
                    ++count;
                }
            }
        }
    }
    printf("QBE integer fuzz: %u cases passed\n", count);
    return 0;
}
