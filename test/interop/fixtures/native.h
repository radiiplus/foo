#ifndef FOO_NATIVE_H
#define FOO_NATIVE_H

#define NATIVE_SCALE 3
#define NATIVE_NAME "native-gate"
#define NATIVE_APPLY(value) ((value) * NATIVE_SCALE)

typedef int (*native_callback)(int value);

typedef struct NativePair {
  int left;
  int right;
} NativePair;

native_callback get_c_callback(void);
void verify_callbacks(native_callback foo_callback, int from_c);

#endif
