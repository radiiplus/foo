#include <stdint.h>
#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdatomic.h>
#include <pthread.h>

extern int32_t foo_probe_choose(bool, int32_t, int32_t);
extern double foo_probe_add_float(double, double);
extern int64_t foo_probe_stack(int64_t);
extern int32_t foo_probe_call(int32_t);
extern int32_t foo_probe_indirect(int32_t (*)(int32_t), int32_t);
extern int32_t (*foo_probe_global_callback(void))(int32_t);
extern int32_t foo_probe_traced(int32_t);
extern void foo_probe_panic(void);
extern int32_t foo_probe_record_read(int32_t, int32_t);
extern int32_t foo_probe_record_address(int32_t, int32_t);
typedef struct { int32_t count; double amount; } Mixed;
typedef struct { int64_t first, second, third; } Large;
extern Mixed foo_probe_mixed_identity(Mixed);
extern Mixed foo_probe_mixed_external(Mixed);
extern Large foo_probe_large_identity(Large);
extern int32_t foo_probe_array_index(uint32_t);
extern uint32_t foo_probe_array_length(void);
extern int32_t foo_probe_optional_some(int32_t);
extern bool foo_probe_optional_none(void);
extern bool foo_probe_failable_error(void);
extern bool foo_probe_failable_success(int32_t);
typedef struct { const char *error; int32_t value; } FailableInt;
extern FailableInt foo_probe_try_success(int32_t);
extern FailableInt foo_probe_try_failure(void);
extern int32_t foo_probe_catch_failure(void);
extern int32_t foo_probe_catch_success(int32_t);
extern int32_t foo_probe_slice_index(uint32_t);
extern uint64_t foo_probe_slice_length(void);
extern uint8_t foo_probe_text_index(void);
extern uint64_t foo_probe_embedded_length(void);
extern bool foo_probe_reserve_failed(int32_t);
extern uint64_t foo_probe_reserve_length(uint32_t);
extern uint64_t foo_probe_reflect(void);
extern int32_t foo_probe_splat(int32_t);
extern int32_t foo_probe_shuffle(void);
extern int32_t foo_probe_select_vector(void);
extern int32_t foo_probe_gather_vector(void);
extern int32_t foo_probe_checked_gather(uint32_t);
extern int32_t foo_probe_scatter_vector(void);
extern bool foo_probe_compare_vector(void);
extern int32_t foo_probe_reduce_add(void);
extern int32_t foo_probe_reduce_mul(void);
extern int32_t foo_probe_reduce_min(void);
extern int32_t foo_probe_reduce_max(void);
extern int32_t foo_probe_reduce_and(void);
extern int32_t foo_probe_reduce_or(void);
extern int32_t foo_probe_reduce_xor(void);
extern uint64_t foo_probe_reduce_overflow(void);
extern double foo_probe_reduce_float(void);
extern int32_t foo_probe_atomic_add32(_Atomic int32_t *, int32_t);
extern uint8_t foo_probe_atomic_swap8(_Atomic uint8_t *, uint8_t);
extern uint64_t foo_probe_atomic_roundtrip64(_Atomic uint64_t *, uint64_t);
extern bool foo_probe_less(int32_t, int32_t);
extern int64_t foo_probe_read_counter(void);
extern void foo_probe_write_counter(int64_t);
extern bool foo_probe_read_flag(void);
extern double foo_probe_read_ratio(void);
extern uint32_t foo_probe_bit_and(uint32_t, uint32_t);
extern uint32_t foo_probe_bit_or(uint32_t, uint32_t);
extern uint64_t foo_probe_bit_xor(uint64_t, uint64_t);
extern uint64_t foo_probe_bit_not(uint64_t);
extern double foo_probe_signed_float(int32_t);
extern double foo_probe_unsigned_float(uint32_t);
extern double foo_probe_float_widen(float);
extern int64_t foo_probe_signed_widen(int32_t);
extern uint64_t foo_probe_unsigned_widen(uint32_t);
extern int64_t foo_probe_unsigned_to_signed(uint32_t);
extern int32_t foo_probe_explicit_phi(bool, int32_t, int32_t);
extern uint32_t foo_probe_loop_phi(void);
extern int32_t foo_probe_guarded_phi(bool, int32_t);
extern int64_t foo_probe_pointer_read(int64_t *, int32_t);
extern int64_t *foo_probe_pointer_address(int64_t *, int32_t);
extern bool foo_probe_align(int64_t **, uint64_t);
extern uint32_t foo_probe_shift_left(uint32_t, uint32_t);
extern uint64_t foo_probe_shift_right(uint64_t, uint64_t);
extern int64_t foo_probe_shift_arithmetic(int64_t, int64_t);
extern uint32_t foo_probe_bit_set(uint32_t, uint32_t);
extern uint32_t foo_probe_bit_clear(uint32_t, uint32_t);
extern uint32_t foo_probe_bit_toggle(uint32_t, uint32_t);
extern int32_t foo_probe_signed_add(int32_t, int32_t);
extern uint64_t foo_probe_unsigned_add(uint64_t, uint64_t);
extern int64_t foo_probe_signed_sub(int64_t, int64_t);
extern uint32_t foo_probe_unsigned_sub(uint32_t, uint32_t);
extern int32_t foo_probe_signed_mul(int32_t, int32_t);
extern uint32_t foo_probe_unsigned_mul(uint32_t, uint32_t);
extern int64_t foo_probe_signed_mul64(int64_t, int64_t);
extern uint64_t foo_probe_unsigned_mul64(uint64_t, uint64_t);
extern int64_t foo_probe_signed_div(int64_t, int64_t);
extern uint64_t foo_probe_unsigned_div(uint64_t, uint64_t);
extern int64_t foo_probe_signed_rem(int64_t, int64_t);
extern uint32_t foo_probe_unsigned_rem(uint32_t, uint32_t);

static int trace_count;
static int cleanup_count;
void foo_qbe_trace(const char *slot, const char *file, uint64_t offset) {
  if (strcmp(slot, "qbe-verified") == 0 && strcmp(file, "probe.iv") == 0 && offset == 23)
    ++trace_count;
  if (strcmp(slot, "qbe-cleanup") == 0) ++cleanup_count;
}

void foo_qbe_trace_reset(void) { }

void foo_qbe_panic(const char *message) {
  fputs(message, stderr);
  fputc('\n', stderr);
  exit(71);
}
extern int64_t foo_probe_counter __asm__("storage.counter");
extern int32_t foo_probe_signed32 __asm__("storage.signed32");
extern uint32_t foo_probe_unsigned32 __asm__("storage.unsigned32");
extern uint64_t foo_probe_unsigned64 __asm__("storage.unsigned64");
extern bool foo_probe_flag __asm__("storage.flag");
extern float foo_probe_single __asm__("storage.single");
extern double foo_probe_ratio __asm__("storage.ratio");

int32_t foo_probe_twice(int32_t value) { return value * 2; }
Mixed foo_probe_advance_mixed(Mixed value) {
  value.count += 3;
  value.amount *= 2;
  return value;
}

static void *increment_atomic(void *cell) {
  for (int index = 0; index < 10000; ++index)
    (void)foo_probe_atomic_add32((_Atomic int32_t *)cell, 1);
  return NULL;
}

int main(int argc, char **argv) {
  if (argc > 1) {
    if (strcmp(argv[1], "overflow") == 0) {
      (void)foo_probe_signed_add(INT32_MAX, 1);
    } else if (strcmp(argv[1], "underflow") == 0) {
      (void)foo_probe_unsigned_sub(0, 1);
    } else if (strcmp(argv[1], "signed-underflow") == 0) {
      (void)foo_probe_signed_sub(INT64_MIN, 1);
    } else if (strcmp(argv[1], "unsigned-overflow") == 0) {
      (void)foo_probe_unsigned_add(UINT64_MAX, 1);
    } else if (strcmp(argv[1], "shift") == 0) {
      (void)foo_probe_shift_left(1, 32);
    } else if (strcmp(argv[1], "negative-shift") == 0) {
      (void)foo_probe_shift_arithmetic(-8, -1);
    } else if (strcmp(argv[1], "mul-overflow") == 0) {
      (void)foo_probe_signed_mul(INT32_MAX, 2);
    } else if (strcmp(argv[1], "unsigned-mul-overflow") == 0) {
      (void)foo_probe_unsigned_mul(UINT32_MAX, 2);
    } else if (strcmp(argv[1], "mul64-overflow") == 0) {
      (void)foo_probe_signed_mul64(INT64_MAX, 2);
    } else if (strcmp(argv[1], "mul64-minimum") == 0) {
      (void)foo_probe_signed_mul64(INT64_MIN, -1);
    } else if (strcmp(argv[1], "unsigned-mul64-overflow") == 0) {
      (void)foo_probe_unsigned_mul64(UINT64_MAX, 2);
    } else if (strcmp(argv[1], "divide-zero") == 0) {
      (void)foo_probe_unsigned_div(1, 0);
    } else if (strcmp(argv[1], "divide-overflow") == 0) {
      (void)foo_probe_signed_div(INT64_MIN, -1);
    } else if (strcmp(argv[1], "remainder-zero") == 0) {
      (void)foo_probe_signed_rem(1, 0);
    } else if (strcmp(argv[1], "panic") == 0) {
      foo_probe_panic();
    } else if (strcmp(argv[1], "array-bounds") == 0) {
      (void)foo_probe_array_index(3);
    } else if (strcmp(argv[1], "slice-bounds") == 0) {
      (void)foo_probe_slice_index(3);
    } else if (strcmp(argv[1], "gather-bounds") == 0) {
      (void)foo_probe_checked_gather(4);
    } else if (strcmp(argv[1], "reduce-overflow") == 0) {
      (void)foo_probe_reduce_overflow();
    } else if (strcmp(argv[1], "alignment") == 0) {
      char bytes[32];
      int64_t *misaligned = (int64_t *)(void *)(bytes + 1);
      (void)foo_probe_align(&misaligned, 8);
    } else if (strcmp(argv[1], "guarded-overflow") == 0) {
      (void)foo_probe_guarded_phi(true, INT32_MAX);
    }
    return 90;
  }
  Mixed mixed = foo_probe_mixed_identity((Mixed){7, 1.25});
  Mixed advanced = foo_probe_mixed_external((Mixed){7, 1.25});
  Large large = foo_probe_large_identity((Large){11, 22, 33});
  if (mixed.count != 7 || mixed.amount != 1.25 ||
      advanced.count != 10 || advanced.amount != 2.5 ||
      large.first != 11 || large.second != 22 || large.third != 33) return 6;
  FailableInt succeeded = foo_probe_try_success(31);
  FailableInt failed = foo_probe_try_failure();
  if (succeeded.error != NULL || succeeded.value != 31 ||
      failed.error == NULL || strcmp(failed.error, "SampleError") != 0 ||
      cleanup_count != 2 || foo_probe_catch_failure() != 7 ||
      foo_probe_catch_success(31) != 31) return 11;
  _Atomic int32_t atomic_cell = 11;
  _Atomic uint8_t atomic_byte = 250;
  _Atomic uint64_t atomic_wide = 0;
  if (foo_probe_atomic_add32(&atomic_cell, 3) != 11 ||
      atomic_load(&atomic_cell) != 14 ||
      foo_probe_atomic_swap8(&atomic_byte, 3) != 250 ||
      atomic_load(&atomic_byte) != 3 ||
      foo_probe_atomic_roundtrip64(&atomic_wide, UINT64_MAX) != UINT64_MAX ||
      atomic_load(&atomic_wide) != UINT64_MAX) return 7;
  pthread_t workers[4];
  for (int index = 0; index < 4; ++index)
    if (pthread_create(&workers[index], NULL, increment_atomic,
          &atomic_cell) != 0) return 8;
  for (int index = 0; index < 4; ++index)
    if (pthread_join(workers[index], NULL) != 0) return 9;
  if (atomic_load(&atomic_cell) != 40014) return 10;
  if (foo_probe_choose(true, 11, 29) != 11 ||
      foo_probe_choose(false, 11, 29) != 29 ||
      foo_probe_add_float(1.25, 2.5) != 3.75 ||
      foo_probe_stack(INT64_C(0x123456789)) != INT64_C(0x123456789) ||
      foo_probe_call(21) != 42 ||
      foo_probe_indirect(foo_probe_twice, 21) != 42 ||
      foo_probe_global_callback()(21) != 42 ||
      foo_probe_traced(7) != 7 || trace_count != 1 ||
      foo_probe_record_read(-7, 19) != 19 ||
      foo_probe_record_address(-7, 19) != 19 ||
      foo_probe_array_index(0) != 11 ||
      foo_probe_array_index(2) != 33 ||
      foo_probe_array_length() != 3 ||
      foo_probe_optional_some(-17) != -17 ||
      foo_probe_optional_none() ||
      !foo_probe_failable_error() ||
      foo_probe_failable_success(17) ||
      foo_probe_slice_index(1) != 22 ||
      foo_probe_slice_length() != 3 ||
      foo_probe_text_index() != 66 ||
      foo_probe_embedded_length() != 13 ||
      !foo_probe_reserve_failed(-1) ||
      foo_probe_reserve_failed(5) ||
      foo_probe_reserve_length(5) != 5 ||
      foo_probe_reserve_length(0) != 0 ||
      foo_probe_reflect() != 8 ||
      foo_probe_splat(37) != 37 ||
      foo_probe_shuffle() != 66 ||
      foo_probe_select_vector() != 66 ||
      foo_probe_gather_vector() != 11 ||
      foo_probe_checked_gather(3) != 44 ||
      foo_probe_scatter_vector() != 66 ||
      !foo_probe_compare_vector() ||
      foo_probe_reduce_add() != 110 ||
      foo_probe_reduce_mul() != 351384 ||
      foo_probe_reduce_min() != 11 ||
      foo_probe_reduce_max() != 44 ||
      foo_probe_reduce_and() != (11 & 22 & 33 & 44) ||
      foo_probe_reduce_or() != (11 | 22 | 33 | 44) ||
      foo_probe_reduce_xor() != (11 ^ 22 ^ 33 ^ 44) ||
      foo_probe_reduce_float() != 3.75 ||
      !foo_probe_less(-3, 2) || foo_probe_less(2, -3) ||
      foo_probe_counter != 17 || foo_probe_read_counter() != 17 ||
      foo_probe_signed32 != -123 || foo_probe_unsigned32 != UINT32_MAX ||
      foo_probe_unsigned64 != UINT64_MAX ||
      !foo_probe_flag || !foo_probe_read_flag() ||
      foo_probe_single != 1.5f ||
      foo_probe_ratio != 1.25 || foo_probe_read_ratio() != 1.25 ||
      foo_probe_bit_and(UINT32_C(0xf0f0f0f0), UINT32_C(0x0ff00ff0)) != UINT32_C(0x00f000f0) ||
      foo_probe_bit_or(UINT32_C(0xf0f0f0f0), UINT32_C(0x0ff00ff0)) != UINT32_C(0xfff0fff0) ||
      foo_probe_bit_xor(UINT64_C(0x8000000000000001), UINT64_C(0x0000000000000003)) != UINT64_C(0x8000000000000002) ||
      foo_probe_bit_not(UINT64_C(0x8000000000000001)) != UINT64_C(0x7ffffffffffffffe) ||
      foo_probe_signed_float(INT32_MIN) != -2147483648.0 ||
      foo_probe_unsigned_float(UINT32_MAX) != 4294967295.0 ||
      foo_probe_float_widen(1.25f) != 1.25 ||
      foo_probe_signed_widen(INT32_MIN) != INT64_C(-2147483648) ||
      foo_probe_unsigned_widen(UINT32_MAX) != UINT64_C(4294967295) ||
      foo_probe_unsigned_to_signed(UINT32_MAX) != INT64_C(4294967295) ||
      foo_probe_explicit_phi(true, -7, 19) != -7 ||
      foo_probe_explicit_phi(false, -7, 19) != 19 ||
      foo_probe_loop_phi() != 1 ||
      foo_probe_shift_left(3, 4) != 48 ||
      foo_probe_shift_right(UINT64_MAX, 63) != 1 ||
      foo_probe_shift_arithmetic(-8, 2) != -2 ||
      foo_probe_bit_set(0, 31) != UINT32_C(0x80000000) ||
      foo_probe_bit_clear(UINT32_MAX, 31) != UINT32_C(0x7fffffff) ||
      foo_probe_bit_toggle(3, 0) != 2 ||
      foo_probe_signed_add(INT32_MAX, 0) != INT32_MAX ||
      foo_probe_unsigned_add(UINT64_MAX - 1, 1) != UINT64_MAX ||
      foo_probe_signed_sub(INT64_MIN + 1, 1) != INT64_MIN ||
      foo_probe_unsigned_sub(1, 1) != 0 ||
      foo_probe_signed_mul(-17, 3) != -51 ||
      foo_probe_unsigned_mul(UINT32_MAX, 1) != UINT32_MAX ||
      foo_probe_signed_mul64(INT64_MIN, 1) != INT64_MIN ||
      foo_probe_signed_mul64(-7, -9) != 63 ||
      foo_probe_signed_mul64(INT64_MAX, 0) != 0 ||
      foo_probe_unsigned_mul64(UINT64_MAX, 1) != UINT64_MAX ||
      foo_probe_unsigned_mul64(UINT64_MAX, 0) != 0 ||
      foo_probe_signed_div(INT64_MIN, 2) != INT64_MIN / 2 ||
      foo_probe_unsigned_div(UINT64_MAX, 3) != UINT64_MAX / 3 ||
      foo_probe_signed_rem(INT64_MIN, -1) != 0 ||
      foo_probe_signed_rem(-17, 3) != -2 ||
      foo_probe_unsigned_rem(UINT32_MAX, 7) != UINT32_MAX % 7) {
    fputs("QBE ABI probe failed\n", stderr);
    return 1;
  }
  foo_probe_write_counter(99);
  if (foo_probe_counter != 99 || foo_probe_read_counter() != 99) return 2;
  foo_probe_counter = -8;
  foo_probe_flag = false;
  foo_probe_ratio = 2.5;
  if (foo_probe_read_counter() != -8 || foo_probe_read_flag() ||
      foo_probe_read_ratio() != 2.5) return 3;
  int64_t cells[] = {11, 29, 47};
  int64_t *aligned = cells;
  if (!foo_probe_align(&aligned, 8)) return 12;
  if (foo_probe_guarded_phi(true, 41) != 42 ||
      foo_probe_guarded_phi(false, INT32_MAX) != INT32_MAX ||
      foo_probe_pointer_read(cells + 2, -1) != 29 ||
      foo_probe_pointer_address(cells, 2) != &cells[2]) return 4;
  *foo_probe_pointer_address(cells, 1) = 31;
  if (cells[1] != 31) return 5;
  puts("QBE ABI probe: ok");
  return 0;
}
