FooResult foo_time_current(void) {
  struct timespec stamp;
  if (clock_gettime(CLOCK_MONOTONIC, &stamp)) return failure(SYSTEM);
  return (FooResult){.number = epoch(stamp.tv_sec, stamp.tv_nsec)};
}

FooResult foo_time_wall(void) {
  struct timespec stamp;
  if (clock_gettime(CLOCK_REALTIME, &stamp)) return failure(SYSTEM);
  return (FooResult){.number = epoch(stamp.tv_sec, stamp.tv_nsec)};
}

FooResult foo_time_sleep(uint64_t nanos) {
  if (nanos / 1000000000 > INT64_MAX) return failure(BOUNDS);
  struct timespec remaining = {(time_t)(nanos / 1000000000),
    (long)(nanos % 1000000000)};
  while (nanosleep(&remaining, &remaining))
    if (errno != EINTR) return failure(SYSTEM);
  return (FooResult){0};
}
