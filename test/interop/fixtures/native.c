#include "native.h"

#ifndef NATIVE_FILE_FLAG
#error "per-file C flags were not applied"
#endif

static int c_callback(int value) {
  return value + 20;
}

native_callback get_c_callback(void) {
  return c_callback;
}

void verify_callbacks(native_callback foo_callback, int from_c) {
  if (from_c != 25 || foo_callback(5) != 12) {
    __builtin_trap();
  }
}
