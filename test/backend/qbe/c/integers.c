#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>

extern bool qbe_u3_add(void);
extern bool qbe_i17_div(void);
extern bool qbe_u128_add(void);
extern bool qbe_u128_mul(void);
extern bool qbe_u128_div(void);
extern bool qbe_i65_add(void);
extern bool qbe_u3_shift(void);
extern bool qbe_i17_shift(void);
extern bool qbe_u128_set(void);
extern bool qbe_packed_order(void);
extern bool qbe_defer_arithmetic(void);
extern bool qbe_nested_defer(void);
extern bool qbe_catch_arithmetic(void);
extern bool qbe_defer_graph(void);
extern bool qbe_catch_graph(void);
typedef struct { const char *error; int32_t value; } failable_i32;
extern failable_i32 qbe_defer_try(void);
extern int32_t cleanup_cell __asm__("storage.cleanup_cell");

int main(void) {
    if (!qbe_u3_add() || !qbe_i17_div() || !qbe_u128_add() ||
        !qbe_u128_mul() || !qbe_u128_div() || !qbe_i65_add() ||
        !qbe_u3_shift() || !qbe_i17_shift() || !qbe_u128_set() ||
        !qbe_packed_order() || !qbe_catch_arithmetic() ||
        !qbe_defer_arithmetic() || cleanup_cell != 42) return 1;
    failable_i32 deferred = qbe_defer_try();
    if (!deferred.error || cleanup_cell != 7) return 2;
    if (!qbe_nested_defer() || cleanup_cell != 2) return 3;
    if (!qbe_catch_graph()) return 4;
    if (!qbe_defer_graph() || cleanup_cell != 3) return 5;
    puts("QBE integer probe: ok");
    return 0;
}
