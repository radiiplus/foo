/* Capability probing never changes the synchronous provider's error state. */
#if defined(__linux__)
#include <errno.h>
#include <string.h>
#include <unistd.h>
#include <sys/syscall.h>
#include <linux/io_uring.h>
#endif

static int foo_llvm_ring_available;
static void foo_llvm_io_probe(void) {
#if defined(__linux__) && defined(__NR_io_uring_setup)
  int saved = errno;
  struct io_uring_params parameters;
  memset(&parameters, 0, sizeof(parameters));
  /* EPERM/EACCES, ENOSYS and resource limits all select the portable path. */
  int descriptor = (int)syscall(__NR_io_uring_setup, 2u, &parameters);
  foo_llvm_ring_available = descriptor >= 0;
  if (descriptor >= 0) close(descriptor);
  errno = saved;
#else
  foo_llvm_ring_available = 0;
#endif
}

/* A successful probe is capability evidence, not permission to batch I/O. */
int foo_llvm_io_ring_available(void) { return foo_llvm_ring_available; }
