FooResult foo_time_current(void) {
#ifdef _WIN32
  LARGE_INTEGER counter, frequency;
  if (!QueryPerformanceCounter(&counter) ||
      !QueryPerformanceFrequency(&frequency))
    return failure(SYSTEM);
  return (FooResult){
      .number = (uint64_t)(counter.QuadPart / frequency.QuadPart) * 1000000000 +
                (uint64_t)(counter.QuadPart % frequency.QuadPart) * 1000000000 /
                    (uint64_t)frequency.QuadPart};
#else
  struct timespec stamp;
  if (clock_gettime(CLOCK_MONOTONIC, &stamp))
    return failure(SYSTEM);
  return (FooResult){.number = (uint64_t)stamp.tv_sec * 1000000000 +
                               (uint64_t)stamp.tv_nsec};
#endif
}
FooResult foo_time_wall(void) {
#ifdef _WIN32
  FILETIME instant;
  GetSystemTimePreciseAsFileTime(&instant);
  uint64_t ticks = ((uint64_t)instant.dwHighDateTime << 32) |
                   instant.dwLowDateTime;
  if (ticks < UINT64_C(116444736000000000))
    return failure(BOUNDS);
  ticks -= UINT64_C(116444736000000000);
  if (ticks > UINT64_MAX / UINT64_C(100))
    return failure(BOUNDS);
  return (FooResult){.number = ticks * UINT64_C(100)};
#else
  struct timespec instant;
  if (clock_gettime(CLOCK_REALTIME, &instant))
    return failure(SYSTEM);
  if (instant.tv_sec < 0 || (uint64_t)instant.tv_sec >
          (UINT64_MAX - (uint64_t)instant.tv_nsec) / UINT64_C(1000000000))
    return failure(BOUNDS);
  return (FooResult){.number = (uint64_t)instant.tv_sec * UINT64_C(1000000000) +
                               (uint64_t)instant.tv_nsec};
#endif
}
FooResult foo_time_sleep(uint64_t nanos) {
#ifdef _WIN32
  uint64_t milliseconds = nanos / 1000000 + (nanos % 1000000 != 0);
  while (milliseconds) {
    DWORD chunk = milliseconds >= INFINITE ? INFINITE - 1 : (DWORD)milliseconds;
    Sleep(chunk);
    milliseconds -= chunk;
  }
#else
  struct timespec duration = {(time_t)(nanos / 1000000000),
                              (long)(nanos % 1000000000)};
  while (nanosleep(&duration, &duration))
    if (errno != EINTR)
      return failure(SYSTEM);
#endif
  return (FooResult){0};
}
typedef struct {
  uint64_t deadline;
  int armed;
  int waiters;
#ifdef _WIN32
  CRITICAL_SECTION mutex;
  CONDITION_VARIABLE condition;
#else
  pthread_mutex_t mutex;
  pthread_cond_t condition;
#endif
} Timer;
static void acquire(Timer *timer) {
#ifdef _WIN32
  EnterCriticalSection(&timer->mutex);
#else
  pthread_mutex_lock(&timer->mutex);
#endif
}
static void release(Timer *timer) {
#ifdef _WIN32
  LeaveCriticalSection(&timer->mutex);
#else
  pthread_mutex_unlock(&timer->mutex);
#endif
}
static void notify(Timer *timer) {
#ifdef _WIN32
  WakeAllConditionVariable(&timer->condition);
#else
  pthread_cond_broadcast(&timer->condition);
#endif
}
FooResult foo_timer_create(void) {
  Timer *timer = owned(sizeof(*timer), TIMERS);
  if (!timer) return failure(MEMORY);
#ifdef _WIN32
  InitializeCriticalSection(&timer->mutex);
  InitializeConditionVariable(&timer->condition);
#else
  if (pthread_mutex_init(&timer->mutex, NULL)) {
    resource(timer, TIMERS)->closed = 1;
    return failure(SYSTEM);
  }
#ifdef __linux__
  pthread_condattr_t attributes;
  if (pthread_condattr_init(&attributes)) {
    pthread_mutex_destroy(&timer->mutex);
    resource(timer, TIMERS)->closed = 1;
    return failure(SYSTEM);
  }
  int failed = pthread_condattr_setclock(&attributes, CLOCK_MONOTONIC) ||
               pthread_cond_init(&timer->condition, &attributes);
  pthread_condattr_destroy(&attributes);
#else
  int failed = pthread_cond_init(&timer->condition, NULL);
#endif
  if (failed) {
    pthread_mutex_destroy(&timer->mutex);
    resource(timer, TIMERS)->closed = 1;
    return failure(SYSTEM);
  }
#endif
  return (FooResult){.pointer = timer};
}
FooResult foo_timer_arm(void *pointer, uint64_t nanos) {
  if (!resource(pointer, TIMERS)) return failure(CLOSED);
  FooResult now = foo_time_current();
  if (now.error) return now;
  if (nanos > UINT64_MAX - now.number) return failure(BOUNDS);
  Timer *timer = pointer;
  acquire(timer);
  timer->deadline = now.number + nanos;
  timer->armed = 1;
  notify(timer);
  release(timer);
  return (FooResult){0};
}
FooResult foo_timer_wait(void *pointer) {
  if (!resource(pointer, TIMERS)) return failure(CLOSED);
  Timer *timer = pointer;
  acquire(timer);
  if (timer->waiters) { release(timer); return failure(ARGUMENT); }
  timer->waiters = 1;
  int problem = 0, fired = 0;
  while (timer->armed) {
    FooResult now = foo_time_current();
    if (now.error) { problem = SYSTEM; break; }
    if (now.number >= timer->deadline) {
      timer->armed = 0;
      fired = 1;
      break;
    }
    uint64_t remaining = timer->deadline - now.number;
#ifdef _WIN32
    uint64_t millis = remaining / 1000000 + (remaining % 1000000 != 0);
    DWORD delay = millis >= INFINITE ? INFINITE - 1 : (DWORD)millis;
    if (!SleepConditionVariableCS(&timer->condition, &timer->mutex, delay) &&
        GetLastError() != ERROR_TIMEOUT) { problem = SYSTEM; break; }
#else
    struct timespec limit;
#ifdef __linux__
    uint64_t target = timer->deadline;
    limit.tv_sec = (time_t)(target / 1000000000);
    limit.tv_nsec = (long)(target % 1000000000);
#else
    if (clock_gettime(CLOCK_REALTIME, &limit)) { problem = SYSTEM; break; }
    if (remaining > 1000000000) remaining = 1000000000;
    limit.tv_sec += (time_t)(remaining / 1000000000);
    limit.tv_nsec += (long)(remaining % 1000000000);
    if (limit.tv_nsec >= 1000000000) {
      limit.tv_sec++;
      limit.tv_nsec -= 1000000000;
    }
#endif
    int waited = pthread_cond_timedwait(&timer->condition, &timer->mutex, &limit);
    if (waited && waited != ETIMEDOUT) { problem = SYSTEM; break; }
#endif
  }
  timer->waiters = 0;
  notify(timer);
  release(timer);
  return problem ? failure(problem) : (FooResult){.number = fired};
}
FooResult foo_timer_cancel(void *pointer) {
  if (!resource(pointer, TIMERS)) return failure(CLOSED);
  Timer *timer = pointer;
  acquire(timer);
  timer->armed = 0;
  notify(timer);
  release(timer);
  return (FooResult){0};
}
FooResult foo_timer_close(void *pointer) {
  Resource *entry = resource(pointer, TIMERS);
  if (!entry) return failure(CLOSED);
  Timer *timer = pointer;
  acquire(timer);
  timer->armed = 0;
  notify(timer);
  while (timer->waiters) {
#ifdef _WIN32
    if (!SleepConditionVariableCS(&timer->condition, &timer->mutex, INFINITE)) {
      release(timer);
      return failure(SYSTEM);
    }
#else
    if (pthread_cond_wait(&timer->condition, &timer->mutex)) {
      release(timer);
      return failure(SYSTEM);
    }
#endif
  }
  release(timer);
#ifdef _WIN32
  DeleteCriticalSection(&timer->mutex);
#else
  if (pthread_cond_destroy(&timer->condition) ||
      pthread_mutex_destroy(&timer->mutex)) return failure(SYSTEM);
#endif
  atomic_store_explicit(&entry->closed, 1, memory_order_release);
  return (FooResult){0};
}
