#include <stdint.h>

extern int32_t qbe_call_stdcall(int32_t);
extern int32_t qbe_call_fastcall(int32_t);
extern int32_t qbe_call_vectorcall(int32_t);
extern int32_t qbe_call_thiscall(int32_t);
extern int32_t qbe_call_vector_callback(int32_t (__vectorcall *)(int32_t),
    int32_t);
extern int32_t __vectorcall qbe_export_vectorcall(int32_t);
typedef struct { int32_t first, second; } Pair;
typedef struct { uint64_t low, high; } Wide __attribute__((aligned(16)));
extern Pair qbe_call_pair(Pair);
extern Pair qbe_export_pair(Pair);
extern Wide qbe_call_wide(Wide);
extern Wide qbe_export_wide(Wide);

int32_t __stdcall qbe_foreign_stdcall(int32_t input) { return input + 1; }
int32_t __fastcall qbe_foreign_fastcall(int32_t input) { return input + 2; }
int32_t __vectorcall qbe_foreign_vectorcall(int32_t input) { return input + 3; }
int32_t __thiscall qbe_foreign_thiscall(int32_t input) { return input + 4; }
static int32_t __vectorcall twice(int32_t input) { return input * 2; }
Pair qbe_foreign_pair(Pair input) {
    input.first += 1;
    input.second += 2;
    return input;
}
Wide qbe_foreign_wide(Wide input) {
    input.low += 3;
    input.high += 4;
    return input;
}

int main(void) {
    Pair pair = qbe_call_pair((Pair){10, 20});
    Pair exported_pair = qbe_export_pair((Pair){30, 40});
    Wide wide = qbe_call_wide((Wide){50, 60});
    Wide exported_wide = qbe_export_wide((Wide){70, 80});
    return qbe_call_stdcall(10) != 11 ||
        qbe_call_fastcall(10) != 12 ||
        qbe_call_vectorcall(10) != 13 ||
        qbe_call_thiscall(10) != 14 ||
        qbe_call_vector_callback(twice, 9) != 18 ||
        qbe_export_vectorcall(42) != 42 ||
        pair.first != 11 || pair.second != 22 ||
        exported_pair.first != 30 || exported_pair.second != 40 ||
        wide.low != 53 || wide.high != 64 ||
        exported_wide.low != 70 || exported_wide.high != 80;
}
