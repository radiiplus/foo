typedef struct {
  void (*function)(void *);
  void *context;
#ifdef _WIN32
  HANDLE handle;
  CRITICAL_SECTION mutex;
  CONDITION_VARIABLE condition;
#else
  pthread_t handle;
  pthread_mutex_t mutex;
  pthread_cond_t condition;
#endif
} Task;
#ifdef _WIN32
static DWORD WINAPI work(void *pointer) {
  Task *task = pointer;
  task->function(task->context);
  return 0;
}
#else
static void *work(void *pointer) {
  Task *task = pointer;
  task->function(task->context);
  return NULL;
}
#endif
FooResult foo_thread_spawn(void (*function)(void *), void *context) {
  Task *task = owned(sizeof(*task), THREADS);
  if (!task)
    return failure(MEMORY);
  task->function = function;
  task->context = context;
#ifdef _WIN32
  task->handle = CreateThread(NULL, 0, work, task, 0, NULL);
  int failed = !task->handle;
#else
  int failed = pthread_create(&task->handle, NULL, work, task);
#endif
  if (failed) {
    resource(task, THREADS)->closed = 1;
    return failure(SYSTEM);
  }
  return (FooResult){.pointer = task};
}
FooResult foo_thread_wait(void *pointer) {
  Resource *entry = resource(pointer, THREADS);
  if (!entry)
    return failure(CLOSED);
  Task *task = pointer;
#ifdef _WIN32
  int failed = WaitForSingleObject(task->handle, INFINITE) != WAIT_OBJECT_0;
  if (!failed)
    CloseHandle(task->handle);
#else
  int failed = pthread_join(task->handle, NULL);
#endif
  if (failed)
    return failure(SYSTEM);
  entry->closed = 1;
  return (FooResult){0};
}
FooResult foo_thread_mutex(void) {
  Task *task = owned(sizeof(*task), MUTEX);
  if (!task)
    return failure(MEMORY);
#ifdef _WIN32
  InitializeCriticalSection(&task->mutex);
#else
  if (pthread_mutex_init(&task->mutex, NULL)) {
    resource(task, MUTEX)->closed = 1;
    return failure(SYSTEM);
  }
#endif
  return (FooResult){.pointer = task};
}
FooResult foo_thread_condition(void) {
  Task *task = owned(sizeof(*task), CONDITION);
  if (!task)
    return failure(MEMORY);
#ifdef _WIN32
  InitializeConditionVariable(&task->condition);
#else
  if (pthread_cond_init(&task->condition, NULL)) {
    resource(task, CONDITION)->closed = 1;
    return failure(SYSTEM);
  }
#endif
  return (FooResult){.pointer = task};
}
FooResult foo_thread_lock(void *pointer) {
  if (!resource(pointer, MUTEX))
    return failure(CLOSED);
  Task *task = pointer;
#ifdef _WIN32
  EnterCriticalSection(&task->mutex);
#else
  if (pthread_mutex_lock(&task->mutex))
    return failure(SYSTEM);
#endif
  return (FooResult){0};
}
FooResult foo_thread_unlock(void *pointer) {
  if (!resource(pointer, MUTEX))
    return failure(CLOSED);
  Task *task = pointer;
#ifdef _WIN32
  LeaveCriticalSection(&task->mutex);
#else
  if (pthread_mutex_unlock(&task->mutex))
    return failure(SYSTEM);
#endif
  return (FooResult){0};
}
FooResult foo_thread_signal(void *pointer) {
  if (!resource(pointer, CONDITION))
    return failure(CLOSED);
  Task *task = pointer;
#ifdef _WIN32
  WakeConditionVariable(&task->condition);
#else
  if (pthread_cond_signal(&task->condition))
    return failure(SYSTEM);
#endif
  return (FooResult){0};
}
FooResult foo_thread_await(void *condition, void *mutex) {
  if (!resource(condition, CONDITION) || !resource(mutex, MUTEX))
    return failure(CLOSED);
  Task *c = condition, *m = mutex;
#ifdef _WIN32
  if (!SleepConditionVariableCS(&c->condition, &m->mutex, INFINITE))
    return failure(SYSTEM);
#else
  if (pthread_cond_wait(&c->condition, &m->mutex))
    return failure(SYSTEM);
#endif
  return (FooResult){0};
}
FooResult foo_thread_close(void *pointer) {
  Resource *entry = resource(pointer, MUTEX);
  if (!entry)
    entry = resource(pointer, CONDITION);
  if (!entry)
    return failure(CLOSED);
  Task *task = pointer;
#ifdef _WIN32
  if (entry->kind == MUTEX)
    DeleteCriticalSection(&task->mutex);
#else
  int failed = entry->kind == MUTEX ? pthread_mutex_destroy(&task->mutex)
                                    : pthread_cond_destroy(&task->condition);
  if (failed)
    return failure(SYSTEM);
#endif
  entry->closed = 1;
  return (FooResult){0};
}

typedef struct {
  int64_t slots[256];
  size_t head, tail, count;
} Channel;
typedef struct Cancel {
  atomic_uint references;
  atomic_int cancelled;
  struct Cancel *parent;
} Cancel;
static _Thread_local Cancel *cancellation;
static Cancel *fresh(void) {
  Cancel *token = malloc(sizeof(*token));
  if (!token) return NULL;
  atomic_init(&token->references, 1);
  atomic_init(&token->cancelled, 0);
  token->parent = cancellation;
  if (token->parent)
    atomic_fetch_add_explicit(&token->parent->references, 1, memory_order_relaxed);
  return token;
}
static void foo_cancel_revoke(Cancel *token) {
  if (!token || atomic_fetch_sub_explicit(&token->references, 1,
                                           memory_order_acq_rel) != 1) return;
  Cancel *parent = token->parent;
  free(token);
  foo_cancel_revoke(parent);
}
static int canceled(Cancel *token) {
  for (; token; token = token->parent)
    if (atomic_load_explicit(&token->cancelled, memory_order_acquire))
      return 1;
  return 0;
}
typedef struct {
  void *threads[128];
  size_t count;
  Cancel *cancel;
} Scope;
typedef struct Call {
  void (*callback)(int64_t);
  int64_t argument;
  Cancel *cancel;
  struct Call *next;
} Call;
#if defined(_WIN32) || defined(__linux__)
typedef struct {
  atomic_size_t pending;
  size_t count;
  atomic_int stopping;
  Cancel *cancel;
#ifdef _WIN32
  HANDLE poll, done, workers[32];
#else
  int poll, wake;
  pthread_t workers[32];
  pthread_mutex_t lock;
  pthread_cond_t done;
  Call *head, *tail;
#endif
} Pool;

static size_t workers(void) {
#ifdef _WIN32
  DWORD available = GetActiveProcessorCount(ALL_PROCESSOR_GROUPS);
#else
  long available = sysconf(_SC_NPROCESSORS_ONLN);
#endif
  if (available < 2)
    return 1;
  return (size_t)(available > 33 ? 32 : available - 1);
}

#ifdef _WIN32
static DWORD WINAPI dispatch(void *pointer) {
  Pool *pool = pointer;
  for (;;) {
    DWORD bytes;
    ULONG_PTR key = 0;
    OVERLAPPED *overlap = NULL;
    BOOL ok = GetQueuedCompletionStatus(pool->poll, &bytes, &key, &overlap,
                                        INFINITE);
    (void)bytes;
    (void)overlap;
    if (!ok && !key)
      continue;
    Call *call = (Call *)key;
    if (!call)
      break;
    atomic_fetch_sub_explicit(&task_queued, 1, memory_order_acq_rel);
    Cancel *previous = cancellation;
    cancellation = pool->cancel;
    if (!canceled(cancellation)) call->callback(call->argument);
    cancellation = previous;
    free(call);
    atomic_fetch_sub_explicit(&task_work, 1, memory_order_acq_rel);
    if (atomic_fetch_sub_explicit(&pool->pending, 1, memory_order_acq_rel) == 1)
      SetEvent(pool->done);
  }
  return 0;
}
#else
static void *dispatch(void *pointer) {
  Pool *pool = pointer;
  struct epoll_event event;
  for (;;) {
    if (epoll_wait(pool->poll, &event, 1, -1) < 0) {
      if (errno == EINTR)
        continue;
      break;
    }
    uint64_t signal;
    if (read(pool->wake, &signal, sizeof(signal)) != sizeof(signal))
      continue;
    pthread_mutex_lock(&pool->lock);
    Call *call = pool->head;
    if (call) {
      pool->head = call->next;
      if (!pool->head)
        pool->tail = NULL;
    }
    int stopping = atomic_load_explicit(&pool->stopping, memory_order_acquire);
    pthread_mutex_unlock(&pool->lock);
    if (!call) {
      if (stopping)
        break;
      continue;
    }
    atomic_fetch_sub_explicit(&task_queued, 1, memory_order_acq_rel);
    Cancel *previous = cancellation;
    cancellation = pool->cancel;
    if (!canceled(cancellation)) call->callback(call->argument);
    cancellation = previous;
    free(call);
    atomic_fetch_sub_explicit(&task_work, 1, memory_order_acq_rel);
    if (atomic_fetch_sub_explicit(&pool->pending, 1, memory_order_acq_rel) == 1) {
      pthread_mutex_lock(&pool->lock);
      pthread_cond_broadcast(&pool->done);
      pthread_mutex_unlock(&pool->lock);
    }
  }
  return NULL;
}
#endif

static void dispose(Pool *pool) {
  if (!pool)
    return;
#ifdef _WIN32
  atomic_store_explicit(&pool->stopping, 1, memory_order_release);
  while (atomic_load_explicit(&pool->pending, memory_order_acquire)) {
    ResetEvent(pool->done);
    if (atomic_load_explicit(&pool->pending, memory_order_acquire) &&
        WaitForSingleObject(pool->done, INFINITE) != WAIT_OBJECT_0)
      break;
  }
  for (size_t index = 0; index < pool->count; index++)
    PostQueuedCompletionStatus(pool->poll, 0, 0, NULL);
  for (size_t index = 0; index < pool->count; index++) {
    WaitForSingleObject(pool->workers[index], INFINITE);
    CloseHandle(pool->workers[index]);
  }
  if (pool->done)
    CloseHandle(pool->done);
  if (pool->poll)
    CloseHandle(pool->poll);
#else
  pthread_mutex_lock(&pool->lock);
  atomic_store_explicit(&pool->stopping, 1, memory_order_release);
  while (atomic_load_explicit(&pool->pending, memory_order_acquire))
    pthread_cond_wait(&pool->done, &pool->lock);
  pthread_mutex_unlock(&pool->lock);
  uint64_t signal = pool->count;
  if (pool->wake >= 0)
    (void)write(pool->wake, &signal, sizeof(signal));
  for (size_t index = 0; index < pool->count; index++)
    pthread_join(pool->workers[index], NULL);
  if (pool->wake >= 0)
    close(pool->wake);
  if (pool->poll >= 0)
    close(pool->poll);
  pthread_cond_destroy(&pool->done);
  pthread_mutex_destroy(&pool->lock);
#endif
}

static void abandon(Pool *pool) {
  Resource *entry = resource(pool, TASK_POOL);
  if (entry)
    entry->closed = 1;
  foo_cancel_revoke(pool->cancel);
  pool->cancel = NULL;
}
#endif

static void execute(void *pointer) {
  Call *call = pointer;
  Cancel *previous = cancellation;
  cancellation = call->cancel;
  if (!canceled(cancellation)) call->callback(call->argument);
  cancellation = previous;
  free(call);
  atomic_fetch_sub_explicit(&task_work, 1, memory_order_acq_rel);
}
static uint64_t engine(void) {
#ifdef _WIN32
  return 3;
#elif defined(__linux__)
  return 1;
#else
  return 0;
#endif
}
FooResult foo_task_backend(void) { return (FooResult){.number = engine()}; }
FooResult foo_task_which(void) {
  static const char *names[] = {"threaded", "epoll", "kqueue", "iocp"};
  return (FooResult){.pointer = (void *)names[engine()]};
}
FooResult foo_task_executor(void) {
  uint64_t *executor = owned(sizeof(*executor), TASK_EXECUTOR);
  if (!executor) return failure(MEMORY);
  *executor = engine();
  return (FooResult){.pointer = executor};
}
FooResult foo_task_block(void (*callback)(void)) {
  callback();
  return (FooResult){0};
}
FooResult foo_task_channel(void) {
  Channel *channel = owned(sizeof(*channel), TASK_CHANNEL);
  return channel ? (FooResult){.pointer = channel} : failure(MEMORY);
}
FooResult foo_task_send(void *pointer, int64_t value) {
  Channel *channel = resource(pointer, TASK_CHANNEL) ? pointer : NULL;
  if (!channel) return failure(CLOSED);
  enter();
  if (channel->count == 256) { leave(); return (FooResult){.number = 0}; }
  channel->slots[channel->tail] = value;
  channel->tail = (channel->tail + 1) % 256;
  channel->count++;
  leave();
  return (FooResult){.number = 1};
}
FooResult foo_task_receive(void *pointer, int64_t *output) {
  Channel *channel = resource(pointer, TASK_CHANNEL) ? pointer : NULL;
  if (!channel || !output) return failure(CLOSED);
  enter();
  if (!channel->count) { leave(); return (FooResult){.number = 0}; }
  *output = channel->slots[channel->head];
  channel->head = (channel->head + 1) % 256;
  channel->count--;
  leave();
  return (FooResult){.number = 1};
}
static FooResult scope(void) {
  Scope *scope = owned(sizeof(*scope), TASK_SCOPE);
  if (!scope) return failure(MEMORY);
  scope->cancel = fresh();
  if (!scope->cancel) {
    resource(scope, TASK_SCOPE)->closed = 1;
    return failure(MEMORY);
  }
  return (FooResult){.pointer = scope};
}
FooResult foo_task_scope(void) { return scope(); }
FooResult foo_task_pool(void) {
#if defined(_WIN32) || defined(__linux__)
  Pool *pool = owned(sizeof(*pool), TASK_POOL);
  if (!pool)
    return failure(MEMORY);
  pool->cancel = fresh();
  if (!pool->cancel) {
    resource(pool, TASK_POOL)->closed = 1;
    return failure(MEMORY);
  }
  atomic_init(&pool->pending, 0);
  atomic_init(&pool->stopping, 0);
  size_t desired = workers();
#ifdef _WIN32
  pool->poll = CreateIoCompletionPort(INVALID_HANDLE_VALUE, NULL, 0, 0);
  pool->done = CreateEventW(NULL, TRUE, TRUE, NULL);
  if (!pool->poll || !pool->done) {
    if (pool->done) CloseHandle(pool->done);
    if (pool->poll) CloseHandle(pool->poll);
    abandon(pool);
    return failure(SYSTEM);
  }
  for (size_t index = 0; index < desired; index++) {
    pool->workers[index] = CreateThread(NULL, 0, dispatch, pool, 0, NULL);
    if (!pool->workers[index]) {
      dispose(pool);
      abandon(pool);
      return failure(SYSTEM);
    }
    pool->count++;
  }
#else
  pool->poll = -1;
  pool->wake = -1;
  pool->poll = epoll_create1(EPOLL_CLOEXEC);
  pool->wake = eventfd(0, EFD_CLOEXEC | EFD_SEMAPHORE);
  if (pool->poll < 0 || pool->wake < 0) {
    if (pool->wake >= 0) close(pool->wake);
    if (pool->poll >= 0) close(pool->poll);
    abandon(pool);
    return failure(SYSTEM);
  }
  if (pthread_mutex_init(&pool->lock, NULL)) {
    close(pool->wake); close(pool->poll); abandon(pool);
    return failure(SYSTEM);
  }
  if (pthread_cond_init(&pool->done, NULL)) {
    pthread_mutex_destroy(&pool->lock);
    close(pool->wake); close(pool->poll); abandon(pool);
    return failure(SYSTEM);
  }
  struct epoll_event event = {.events = EPOLLIN, .data.fd = pool->wake};
  if (epoll_ctl(pool->poll, EPOLL_CTL_ADD, pool->wake, &event)) {
    dispose(pool);
    abandon(pool);
    return failure(SYSTEM);
  }
  for (size_t index = 0; index < desired; index++)
    if (pthread_create(&pool->workers[index], NULL, dispatch, pool)) {
      dispose(pool);
      abandon(pool);
      return failure(SYSTEM);
    } else
      pool->count++;
#endif
  return (FooResult){.pointer = pool};
#else
  return scope();
#endif
}
static FooResult launch(void *pointer, void (*callback)(int64_t),
                             int64_t argument) {
  Scope *scope = resource(pointer, TASK_SCOPE) ? pointer : NULL;
  if (!scope || !callback) return failure(CLOSED);
  enter();
  if (scope->count == 128 || canceled(scope->cancel)) {
    leave(); return (FooResult){.number = 0};
  }
  leave();
  Call *call = malloc(sizeof(*call));
  if (!call) return failure(MEMORY);
  *call = (Call){callback, argument, scope->cancel, NULL};
  atomic_fetch_add_explicit(&task_work, 1, memory_order_release);
  FooResult spawned = foo_thread_spawn(execute, call);
  if (spawned.error) {
    atomic_fetch_sub_explicit(&task_work, 1, memory_order_acq_rel);
    free(call);
    return spawned;
  }
  enter();
  scope->threads[scope->count++] = spawned.pointer;
  leave();
  return (FooResult){.number = 1};
}
FooResult foo_task_launch(void *scope, void (*callback)(int64_t), int64_t argument) {
  return launch(scope, callback, argument);
}
FooResult foo_task_submit(void *pool, void (*callback)(int64_t), int64_t argument) {
#if defined(_WIN32) || defined(__linux__)
  Pool *queue = resource(pool, TASK_POOL) ? pool : NULL;
  if (!queue || !callback)
    return failure(CLOSED);
  if (canceled(queue->cancel)) return (FooResult){.number = 0};
  Call *call = calloc(1, sizeof(*call));
  if (!call)
    return failure(MEMORY);
  call->callback = callback;
  call->argument = argument;
#ifdef _WIN32
  if (atomic_load_explicit(&queue->stopping, memory_order_acquire) ||
      canceled(queue->cancel)) {
    free(call);
    return failure(CLOSED);
  }
  ResetEvent(queue->done);
  atomic_fetch_add_explicit(&queue->pending, 1, memory_order_release);
  atomic_fetch_add_explicit(&task_work, 1, memory_order_release);
  atomic_fetch_add_explicit(&task_queued, 1, memory_order_release);
  if (!PostQueuedCompletionStatus(queue->poll, 0, (ULONG_PTR)call, NULL)) {
    free(call);
    atomic_fetch_sub_explicit(&task_work, 1, memory_order_acq_rel);
    atomic_fetch_sub_explicit(&task_queued, 1, memory_order_acq_rel);
    if (atomic_fetch_sub_explicit(&queue->pending, 1, memory_order_acq_rel) == 1)
      SetEvent(queue->done);
    return failure(SYSTEM);
  }
#else
  pthread_mutex_lock(&queue->lock);
  if (atomic_load_explicit(&queue->stopping, memory_order_acquire) ||
      canceled(queue->cancel)) {
    pthread_mutex_unlock(&queue->lock);
    free(call);
    return failure(CLOSED);
  }
  Call *previous = queue->tail;
  if (previous)
    previous->next = call;
  else
    queue->head = call;
  queue->tail = call;
  uint64_t signal = 1;
  ssize_t written;
  do {
    written = write(queue->wake, &signal, sizeof(signal));
  } while (written < 0 && errno == EINTR);
  if (written != sizeof(signal)) {
    if (previous)
      previous->next = NULL;
    else
      queue->head = NULL;
    queue->tail = previous;
    pthread_mutex_unlock(&queue->lock);
    free(call);
    return failure(SYSTEM);
  }
  atomic_fetch_add_explicit(&task_work, 1, memory_order_release);
  atomic_fetch_add_explicit(&task_queued, 1, memory_order_release);
  atomic_fetch_add_explicit(&queue->pending, 1, memory_order_release);
  pthread_mutex_unlock(&queue->lock);
#endif
  return (FooResult){.number = 1};
#else
  return launch(pool, callback, argument);
#endif
}
static FooResult join(void *pointer) {
  Scope *scope = resource(pointer, TASK_SCOPE) ? pointer : NULL;
  if (!scope) return failure(CLOSED);
  for (size_t index = 0; index < scope->count; index++) {
    FooResult joined = foo_thread_wait(scope->threads[index]);
    if (joined.error) return joined;
  }
  scope->count = 0;
  return (FooResult){0};
}
FooResult foo_task_join(void *scope) { return join(scope); }
FooResult foo_task_cancel(void *pointer) {
  Scope *scope = resource(pointer, TASK_SCOPE) ? pointer : NULL;
  if (!scope) return failure(CLOSED);
  atomic_store_explicit(&scope->cancel->cancelled, 1, memory_order_release);
  return (FooResult){0};
}
FooResult foo_task_interrupt(void *pointer) {
#if defined(_WIN32) || defined(__linux__)
  Pool *pool = resource(pointer, TASK_POOL) ? pointer : NULL;
  if (!pool) return failure(CLOSED);
  atomic_store_explicit(&pool->cancel->cancelled, 1, memory_order_release);
  return (FooResult){0};
#else
  return foo_task_cancel(pointer);
#endif
}
FooResult foo_task_cancelled(void) {
  return (FooResult){.number = canceled(cancellation)};
}
FooResult foo_task_wait(void *pool) {
#if defined(_WIN32) || defined(__linux__)
  Pool *queue = resource(pool, TASK_POOL) ? pool : NULL;
  if (!queue)
    return failure(CLOSED);
#ifdef _WIN32
  while (atomic_load_explicit(&queue->pending, memory_order_acquire)) {
    ResetEvent(queue->done);
    if (atomic_load_explicit(&queue->pending, memory_order_acquire) &&
        WaitForSingleObject(queue->done, INFINITE) != WAIT_OBJECT_0)
      return failure(SYSTEM);
  }
#else
  pthread_mutex_lock(&queue->lock);
  while (atomic_load_explicit(&queue->pending, memory_order_acquire))
    pthread_cond_wait(&queue->done, &queue->lock);
  pthread_mutex_unlock(&queue->lock);
#endif
  return (FooResult){0};
#else
  return join(pool);
#endif
}
FooResult foo_task_affinity(uint64_t cpu) {
#ifdef _WIN32
  if (cpu >= sizeof(DWORD_PTR) * CHAR_BIT) return (FooResult){.number = 0};
  return (FooResult){.number = SetThreadAffinityMask(GetCurrentThread(),
      ((DWORD_PTR)1) << cpu) != 0};
#elif defined(__linux__)
  if (cpu >= CPU_SETSIZE) return (FooResult){.number = 0};
  cpu_set_t set;
  CPU_ZERO(&set);
  CPU_SET((int)cpu, &set);
  return (FooResult){.number = sched_setaffinity(0, sizeof(set), &set) == 0};
#else
  return (FooResult){.number = 0};
#endif
}
FooResult foo_task_label(FooText name) {
  char *value = string(name);
  if (!value) return failure(ARGUMENT);
#ifdef _WIN32
  int ok = 1;
#elif defined(__APPLE__)
  int ok = pthread_setname_np(value) == 0;
#else
  int ok = pthread_setname_np(pthread_self(), value) == 0;
#endif
  free(value);
  return (FooResult){.number = (uint64_t)ok};
}
typedef struct {
#ifdef _WIN32
  DWORD thread;
  GROUP_AFFINITY previous;
#elif defined(__linux__)
  pthread_t thread;
  cpu_set_t previous;
#else
  uint8_t unavailable;
#endif
} Placement;

FooResult foo_topology_count(void) {
#ifdef _WIN32
  DWORD count = GetActiveProcessorCount(ALL_PROCESSOR_GROUPS);
  return count ? (FooResult){.number = count} : failure(SYSTEM);
#else
  long count = sysconf(_SC_NPROCESSORS_ONLN);
  return count > 0 ? (FooResult){.number = (uint64_t)count} : failure(SYSTEM);
#endif
}
FooResult foo_topology_allowed(void) {
#ifdef _WIN32
  GROUP_AFFINITY affinity = {0};
  if (!GetThreadGroupAffinity(GetCurrentThread(), &affinity)) return failure(SYSTEM);
  KAFFINITY mask = affinity.Mask;
  uint64_t count = 0;
  while (mask) { count += mask & 1; mask >>= 1; }
  return count ? (FooResult){.number = count} : failure(SYSTEM);
#elif defined(__linux__)
  cpu_set_t affinity;
  if (pthread_getaffinity_np(pthread_self(), sizeof(affinity), &affinity))
    return failure(SYSTEM);
  return (FooResult){.number = (uint64_t)CPU_COUNT(&affinity)};
#else
  return failure(MISSING);
#endif
}
FooResult foo_platform_page(void) {
#ifdef _WIN32
  SYSTEM_INFO system;
  GetSystemInfo(&system);
  return system.dwPageSize ? (FooResult){.number = system.dwPageSize}
                           : failure(SYSTEM);
#else
  long size = sysconf(_SC_PAGESIZE);
  return size > 0 ? (FooResult){.number = (uint64_t)size} : failure(SYSTEM);
#endif
}
FooResult foo_platform_width(void) {
  return (FooResult){.number = sizeof(void *)};
}
FooResult foo_platform_alignment(void) {
  return (FooResult){.number = _Alignof(max_align_t)};
}
FooResult foo_platform_little(void) {
  const uint16_t marker = 1;
  return (FooResult){.number = *(const uint8_t *)&marker == 1};
}
FooResult foo_platform_supports(FooText feature) {
  if (supports(feature, "mapping") || supports(feature, "position") ||
      supports(feature, "locking"))
    return (FooResult){.number = 1};
#ifdef _WIN32
  if (supports(feature, "affinity") || supports(feature, "numa"))
    return (FooResult){.number = 1};
#elif defined(__linux__)
  if (supports(feature, "affinity") || supports(feature, "numa") ||
      supports(feature, "limits"))
    return (FooResult){.number = 1};
#else
  if (supports(feature, "limits")) return (FooResult){.number = 1};
#endif
  return (FooResult){0};
}
FooResult foo_topology_current(void) {
#ifdef _WIN32
  PROCESSOR_NUMBER number;
  GetCurrentProcessorNumberEx(&number);
  return (FooResult){.number = (uint64_t)number.Group * 64 + number.Number};
#elif defined(__linux__)
  int cpu = sched_getcpu();
  return cpu >= 0 ? (FooResult){.number = (uint64_t)cpu} : failure(SYSTEM);
#else
  return failure(MISSING);
#endif
}
FooResult foo_topology_nodes(void) {
#ifdef _WIN32
  ULONG highest = 0;
  return GetNumaHighestNodeNumber(&highest)
      ? (FooResult){.number = (uint64_t)highest + 1} : failure(SYSTEM);
#elif defined(__linux__)
  DIR *directory = opendir("/sys/devices/system/node");
  if (!directory) return failure(MISSING);
  uint64_t count = 0;
  struct dirent *item;
  while ((item = readdir(directory))) {
    unsigned index;
    char extra;
    if (sscanf(item->d_name, "node%u%c", &index, &extra) == 1) count++;
  }
  closedir(directory);
  return count ? (FooResult){.number = count} : failure(MISSING);
#else
  return failure(MISSING);
#endif
}
FooResult foo_topology_node(uint64_t cpu) {
#ifdef _WIN32
  if (cpu / 64 >= GetActiveProcessorGroupCount()) return failure(BOUNDS);
  PROCESSOR_NUMBER number = {.Group = (WORD)(cpu / 64), .Number = (BYTE)(cpu % 64)};
  USHORT node = 0;
  return GetNumaProcessorNodeEx(&number, &node)
      ? (FooResult){.number = node} : failure(BOUNDS);
#elif defined(__linux__)
  if (cpu >= CPU_SETSIZE) return failure(BOUNDS);
  char path[96];
  snprintf(path, sizeof(path), "/sys/devices/system/cpu/cpu%llu",
           (unsigned long long)cpu);
  DIR *directory = opendir(path);
  if (!directory) return failure(BOUNDS);
  FooResult result = failure(MISSING);
  struct dirent *item;
  while ((item = readdir(directory))) {
    unsigned index;
    char extra;
    if (sscanf(item->d_name, "node%u%c", &index, &extra) == 1) {
      result = (FooResult){.number = index};
      break;
    }
  }
  closedir(directory);
  return result;
#else
  (void)cpu;
  return failure(MISSING);
#endif
}
FooResult foo_topology_place(uint64_t node) {
#if defined(_WIN32) || defined(__linux__)
#ifdef _WIN32
  uint64_t limit = (uint64_t)GetActiveProcessorGroupCount() * 64;
#else
  uint64_t limit = CPU_SETSIZE;
#endif
  for (uint64_t cpu = 0; cpu < limit; cpu++) {
    FooResult mapped = foo_topology_node(cpu);
    if (!mapped.error && mapped.number == node) {
      FooResult placement = foo_topology_pin(cpu);
      if (!placement.error) return placement;
    }
  }
  return failure(BOUNDS);
#else
  (void)node;
  return failure(MISSING);
#endif
}
FooResult foo_topology_pin(uint64_t cpu) {
#if defined(_WIN32) || defined(__linux__)
  Placement *placement = calloc(1, sizeof(*placement));
  if (!placement) return failure(MEMORY);
#ifdef _WIN32
  uint64_t group = cpu / 64;
  if (group >= GetActiveProcessorGroupCount()) {
    free(placement);
    return failure(BOUNDS);
  }
  GROUP_AFFINITY selected = {0};
  selected.Group = (WORD)group;
  selected.Mask = ((KAFFINITY)1) << (cpu % 64);
  placement->thread = GetCurrentThreadId();
  if (!SetThreadGroupAffinity(GetCurrentThread(), &selected, &placement->previous)) {
    free(placement);
    return failure(SYSTEM);
  }
#else
  if (cpu >= CPU_SETSIZE) {
    free(placement);
    return failure(BOUNDS);
  }
  placement->thread = pthread_self();
  if (pthread_getaffinity_np(placement->thread, sizeof(placement->previous),
                            &placement->previous)) {
    free(placement);
    return failure(SYSTEM);
  }
  cpu_set_t selected;
  CPU_ZERO(&selected);
  CPU_SET((int)cpu, &selected);
  if (pthread_setaffinity_np(placement->thread, sizeof(selected), &selected)) {
    free(placement);
    return failure(SYSTEM);
  }
#endif
  if (!adopt(placement, sizeof(*placement), PLACEMENTS)) {
#ifdef _WIN32
    SetThreadGroupAffinity(GetCurrentThread(), &placement->previous, NULL);
#else
    pthread_setaffinity_np(placement->thread, sizeof(placement->previous),
                           &placement->previous);
#endif
    free(placement);
    return failure(MEMORY);
  }
  return (FooResult){.pointer = placement};
#else
  (void)cpu;
  return failure(MISSING);
#endif
}
FooResult foo_topology_restore(void *pointer) {
  Resource *entry = resource(pointer, PLACEMENTS);
  if (!entry) return failure(CLOSED);
#ifdef _WIN32
  Placement *placement = pointer;
  if (placement->thread != GetCurrentThreadId()) return failure(ARGUMENT);
  if (!SetThreadGroupAffinity(GetCurrentThread(), &placement->previous, NULL))
    return failure(SYSTEM);
#elif defined(__linux__)
  Placement *placement = pointer;
  if (!pthread_equal(placement->thread, pthread_self())) return failure(ARGUMENT);
  if (pthread_setaffinity_np(placement->thread, sizeof(placement->previous),
                             &placement->previous)) return failure(SYSTEM);
#else
  return failure(MISSING);
#endif
  atomic_store_explicit(&entry->closed, 1, memory_order_release);
  return (FooResult){0};
}
