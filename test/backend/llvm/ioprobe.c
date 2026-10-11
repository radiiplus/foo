#define _GNU_SOURCE
#include <assert.h>
#include <errno.h>
#include <stdio.h>
#if defined(__linux__)
#include <unistd.h>
#include <sys/syscall.h>
static int injected;
static int closed;
static long fake_setup(long operation, ...) {
  assert(operation == __NR_io_uring_setup);
  if (injected < 0) { errno = -injected; return -1; }
  return injected;
}
static int fake_close(int descriptor) { assert(descriptor == injected); closed++; return 0; }
#define syscall fake_setup
#define close fake_close
#endif
#include "../../../src/backend/llvm/io.c"
int main(void) {
#if defined(__linux__)
  const int failures[] = {EPERM, EACCES, ENOSYS, EMFILE, ENOMEM};
  for (unsigned index = 0; index < sizeof(failures) / sizeof(failures[0]); index++) {
    injected = -failures[index]; errno = EDOM;
    foo_llvm_io_probe();
    assert(!foo_llvm_io_ring_available()); assert(errno == EDOM); assert(!closed);
  }
  injected = 7; errno = EDOM;
  foo_llvm_io_probe();
  assert(foo_llvm_io_ring_available()); assert(closed == 1); assert(errno == EDOM);
#else
  foo_llvm_io_probe(); assert(!foo_llvm_io_ring_available());
#endif
  puts("LLVM I/O capability probe preserves errors and falls back safely");
}
