static int category(FooText kind) {
  if (supports(kind, "files")) return 1;
  if (supports(kind, "address")) return 2;
  if (supports(kind, "cpu")) return 3;
  if (supports(kind, "stack")) return 4;
  return 0;
}
#ifndef _WIN32
static int platform(int kind) {
  switch (kind) {
    case 1: return RLIMIT_NOFILE;
#ifdef RLIMIT_AS
    case 2: return RLIMIT_AS;
#endif
    case 3: return RLIMIT_CPU;
    case 4: return RLIMIT_STACK;
    default: return -1;
  }
}
#endif
FooResult foo_limit_available(FooText kind) {
  int selected = category(kind);
  if (!selected) return (FooResult){0};
#ifdef _WIN32
  return (FooResult){0};
#else
  int native = platform(selected);
  struct rlimit bounds;
  return (FooResult){.number = native >= 0 && !getrlimit(native, &bounds)};
#endif
}
static FooResult query(FooText kind, int hard) {
  int selected = category(kind);
  if (!selected) return failure(ARGUMENT);
#ifdef _WIN32
  return failure(MISSING);
#else
  int native = platform(selected);
  struct rlimit bounds;
  if (native < 0) return failure(MISSING);
  if (getrlimit(native, &bounds)) return failure(SYSTEM);
  rlim_t result = hard ? bounds.rlim_max : bounds.rlim_cur;
  return (FooResult){.number = result == RLIM_INFINITY
      ? UINT64_MAX : (uint64_t)result};
#endif
}
FooResult foo_limit_soft(FooText kind) { return query(kind, 0); }
FooResult foo_limit_hard(FooText kind) { return query(kind, 1); }
FooResult foo_limit_set(FooText kind, uint64_t value) {
  int selected = category(kind);
  if (!selected) return failure(ARGUMENT);
#ifdef _WIN32
  return failure(MISSING);
#else
  int native = platform(selected);
  struct rlimit bounds;
  if (native < 0) return failure(MISSING);
  if (getrlimit(native, &bounds)) return failure(SYSTEM);
  rlim_t desired = value == UINT64_MAX ? RLIM_INFINITY : (rlim_t)value;
  if (value != UINT64_MAX && (uint64_t)desired != value)
    return failure(BOUNDS);
  bounds.rlim_cur = desired;
  return setrlimit(native, &bounds) ? failure(SYSTEM) : (FooResult){0};
#endif
}
