typedef struct {
  pthread_t handle;
  void (*function)(void *);
  void *context;
} Thread;

static void *run(void *pointer) {
  Thread *thread = pointer;
  thread->function(thread->context);
  return NULL;
}

FooResult foo_thread_spawn(void (*function)(void *), void *context) {
  if (!function) return failure(ARGUMENT);
  Thread *thread = owned(sizeof(*thread), THREAD);
  if (!thread) return failure(MEMORY);
  thread->function = function;
  thread->context = context;
  if (pthread_create(&thread->handle, NULL, run, thread)) {
    retire(entry(thread, THREAD));
    return failure(SYSTEM);
  }
  return (FooResult){.pointer = thread};
}

FooResult foo_thread_wait(void *pointer) {
  Entry *item = entry(pointer, THREAD);
  if (!item) return failure(CLOSED);
  Thread *thread = pointer;
  if (pthread_join(thread->handle, NULL)) return failure(SYSTEM);
  retire(item);
  return (FooResult){0};
}

FooResult foo_thread_mutex(void) {
  pthread_mutex_t *mutex = owned(sizeof(*mutex), MUTEX);
  if (!mutex) return failure(MEMORY);
  if (pthread_mutex_init(mutex, NULL)) {
    retire(entry(mutex, MUTEX));
    return failure(SYSTEM);
  }
  return (FooResult){.pointer = mutex};
}

FooResult foo_thread_condition(void) {
  pthread_cond_t *condition = owned(sizeof(*condition), CONDITION);
  if (!condition) return failure(MEMORY);
  if (pthread_cond_init(condition, NULL)) {
    retire(entry(condition, CONDITION));
    return failure(SYSTEM);
  }
  return (FooResult){.pointer = condition};
}

FooResult foo_thread_lock(void *pointer) {
  if (!entry(pointer, MUTEX)) return failure(CLOSED);
  return pthread_mutex_lock(pointer) ? failure(SYSTEM) : (FooResult){0};
}

FooResult foo_thread_unlock(void *pointer) {
  if (!entry(pointer, MUTEX)) return failure(CLOSED);
  return pthread_mutex_unlock(pointer) ? failure(SYSTEM) : (FooResult){0};
}

FooResult foo_thread_signal(void *pointer) {
  if (!entry(pointer, CONDITION)) return failure(CLOSED);
  return pthread_cond_signal(pointer) ? failure(SYSTEM) : (FooResult){0};
}

FooResult foo_thread_await(void *condition, void *mutex) {
  if (!entry(condition, CONDITION) || !entry(mutex, MUTEX)) return failure(CLOSED);
  return pthread_cond_wait(condition, mutex) ? failure(SYSTEM) : (FooResult){0};
}

FooResult foo_thread_close(void *pointer) {
  Entry *item = entry(pointer, MUTEX);
  if (!item) item = entry(pointer, CONDITION);
  if (!item) return failure(CLOSED);
  int failed = item->kind == MUTEX ? pthread_mutex_destroy(pointer) :
    pthread_cond_destroy(pointer);
  if (failed) return failure(SYSTEM);
  retire(item);
  return (FooResult){0};
}

typedef struct Cancel {
  atomic_int cancelled;
  struct Cancel *parent;
} Cancel;

static _Thread_local Cancel *cancellation;

static int cancelled(Cancel *token) {
  for (; token; token = token->parent)
    if (atomic_load_explicit(&token->cancelled, memory_order_acquire)) return 1;
  return 0;
}

typedef struct Call {
  void (*callback)(int64_t);
  int64_t argument;
  Cancel *cancel;
  struct Call *next;
} Call;

typedef struct {
  void *threads[128];
  size_t count;
  Cancel token;
} Scope;

static void dispatch(void *pointer) {
  Call *call = pointer;
  Cancel *previous = cancellation;
  cancellation = call->cancel;
  if (!cancelled(cancellation)) call->callback(call->argument);
  cancellation = previous;
  free(call);
  atomic_fetch_sub_explicit(&working, 1, memory_order_acq_rel);
}

FooResult foo_task_scope(void) {
  Scope *scope = owned(sizeof(*scope), SCOPE);
  if (!scope) return failure(MEMORY);
  scope->token.parent = cancellation;
  return (FooResult){.pointer = scope};
}

FooResult foo_task_launch(void *pointer, void (*callback)(int64_t), int64_t argument) {
  Scope *scope = pointer;
  if (!entry(pointer, SCOPE) || !callback) return failure(CLOSED);
  if (scope->count == 128 || cancelled(&scope->token)) return (FooResult){0};
  Call *call = calloc(1, sizeof(*call));
  if (!call) return failure(MEMORY);
  call->callback = callback;
  call->argument = argument;
  call->cancel = &scope->token;
  atomic_fetch_add_explicit(&working, 1, memory_order_release);
  FooResult spawned = foo_thread_spawn(dispatch, call);
  if (spawned.error) {
    atomic_fetch_sub_explicit(&working, 1, memory_order_acq_rel);
    free(call);
    return spawned;
  }
  scope->threads[scope->count++] = spawned.pointer;
  return (FooResult){.number = 1};
}

FooResult foo_task_join(void *pointer) {
  Scope *scope = pointer;
  if (!entry(pointer, SCOPE)) return failure(CLOSED);
  for (size_t index = 0; index < scope->count; index++) {
    FooResult joined = foo_thread_wait(scope->threads[index]);
    if (joined.error) return joined;
  }
  scope->count = 0;
  return (FooResult){0};
}

FooResult foo_task_cancel(void *pointer) {
  if (!entry(pointer, SCOPE)) return failure(CLOSED);
  Scope *scope = pointer;
  atomic_store_explicit(&scope->token.cancelled, 1, memory_order_release);
  return (FooResult){0};
}

typedef struct Pool {
  pthread_t workers[2];
  size_t count;
  pthread_mutex_t lock;
  pthread_cond_t ready, done;
  Call *head, *tail;
  size_t pending;
  int stopping;
  Cancel token;
} Pool;

static void *worker(void *pointer) {
  Pool *pool = pointer;
  for (;;) {
    pthread_mutex_lock(&pool->lock);
    while (!pool->head && !pool->stopping)
      pthread_cond_wait(&pool->ready, &pool->lock);
    if (!pool->head && pool->stopping) {
      pthread_mutex_unlock(&pool->lock);
      break;
    }
    Call *call = pool->head;
    pool->head = call->next;
    if (!pool->head) pool->tail = NULL;
    pthread_mutex_unlock(&pool->lock);
    atomic_fetch_sub_explicit(&waiting, 1, memory_order_acq_rel);
    Cancel *previous = cancellation;
    cancellation = &pool->token;
    if (!cancelled(cancellation)) call->callback(call->argument);
    cancellation = previous;
    free(call);
    atomic_fetch_sub_explicit(&working, 1, memory_order_acq_rel);
    pthread_mutex_lock(&pool->lock);
    if (--pool->pending == 0) pthread_cond_broadcast(&pool->done);
    pthread_mutex_unlock(&pool->lock);
  }
  return NULL;
}

FooResult foo_task_pool(void) {
  Pool *pool = owned(sizeof(*pool), POOL);
  if (!pool) return failure(MEMORY);
  pool->token.parent = cancellation;
  if (pthread_mutex_init(&pool->lock, NULL)) {
    retire(entry(pool, POOL));
    return failure(SYSTEM);
  }
  if (pthread_cond_init(&pool->ready, NULL)) {
    pthread_mutex_destroy(&pool->lock);
    retire(entry(pool, POOL));
    return failure(SYSTEM);
  }
  if (pthread_cond_init(&pool->done, NULL)) {
    pthread_cond_destroy(&pool->ready);
    pthread_mutex_destroy(&pool->lock);
    retire(entry(pool, POOL));
    return failure(SYSTEM);
  }
  for (size_t index = 0; index < 2; index++) {
    if (pthread_create(&pool->workers[index], NULL, worker, pool)) {
      pthread_mutex_lock(&pool->lock);
      pool->stopping = 1;
      pthread_cond_broadcast(&pool->ready);
      pthread_mutex_unlock(&pool->lock);
      for (size_t done = 0; done < pool->count; done++)
        pthread_join(pool->workers[done], NULL);
      pthread_cond_destroy(&pool->ready);
      pthread_cond_destroy(&pool->done);
      pthread_mutex_destroy(&pool->lock);
      retire(entry(pool, POOL));
      return failure(SYSTEM);
    }
    pool->count++;
  }
  return (FooResult){.pointer = pool};
}

FooResult foo_task_submit(void *pointer, void (*callback)(int64_t), int64_t argument) {
  Pool *pool = pointer;
  if (!entry(pointer, POOL) || !callback) return failure(CLOSED);
  if (cancelled(&pool->token)) return (FooResult){0};
  Call *call = calloc(1, sizeof(*call));
  if (!call) return failure(MEMORY);
  call->callback = callback;
  call->argument = argument;
  pthread_mutex_lock(&pool->lock);
  if (pool->stopping || cancelled(&pool->token)) {
    pthread_mutex_unlock(&pool->lock);
    free(call);
    return (FooResult){0};
  }
  if (pool->tail) pool->tail->next = call;
  else pool->head = call;
  pool->tail = call;
  pool->pending++;
  atomic_fetch_add_explicit(&working, 1, memory_order_release);
  atomic_fetch_add_explicit(&waiting, 1, memory_order_release);
  pthread_cond_signal(&pool->ready);
  pthread_mutex_unlock(&pool->lock);
  return (FooResult){.number = 1};
}

FooResult foo_task_wait(void *pointer) {
  Pool *pool = pointer;
  if (!entry(pointer, POOL)) return failure(CLOSED);
  pthread_mutex_lock(&pool->lock);
  while (pool->pending) pthread_cond_wait(&pool->done, &pool->lock);
  pthread_mutex_unlock(&pool->lock);
  return (FooResult){0};
}

FooResult foo_task_interrupt(void *pointer) {
  Pool *pool = pointer;
  if (!entry(pointer, POOL)) return failure(CLOSED);
  atomic_store_explicit(&pool->token.cancelled, 1, memory_order_release);
  return (FooResult){0};
}

FooResult foo_task_cancelled(void) {
  return (FooResult){.number = cancelled(cancellation)};
}

FooResult foo_task_backend(void) { return (FooResult){0}; }
FooResult foo_task_which(void) {
  return (FooResult){.pointer = (void *)"threaded"};
}
FooResult foo_task_executor(void) {
  uint64_t *executor = owned(sizeof(*executor), EXECUTOR);
  return executor ? (FooResult){.pointer = executor} : failure(MEMORY);
}
FooResult foo_task_block(void (*callback)(void)) {
  if (!callback) return failure(ARGUMENT);
  callback();
  return (FooResult){0};
}

typedef struct {
  int64_t slots[256];
  size_t head, tail, count;
} Channel;

FooResult foo_task_channel(void) {
  Channel *channel = owned(sizeof(*channel), CHANNEL);
  return channel ? (FooResult){.pointer = channel} : failure(MEMORY);
}
FooResult foo_task_send(void *pointer, int64_t value) {
  Channel *channel = pointer;
  if (!entry(pointer, CHANNEL)) return failure(CLOSED);
  pthread_mutex_lock(&registry);
  int sent = channel->count < 256;
  if (sent) {
    channel->slots[channel->tail] = value;
    channel->tail = (channel->tail + 1) % 256;
    channel->count++;
  }
  pthread_mutex_unlock(&registry);
  return (FooResult){.number = sent};
}
FooResult foo_task_receive(void *pointer, int64_t *output) {
  Channel *channel = pointer;
  if (!entry(pointer, CHANNEL) || !output) return failure(CLOSED);
  pthread_mutex_lock(&registry);
  int received = channel->count > 0;
  if (received) {
    *output = channel->slots[channel->head];
    channel->head = (channel->head + 1) % 256;
    channel->count--;
  }
  pthread_mutex_unlock(&registry);
  return (FooResult){.number = received};
}

FooResult foo_task_affinity(uint64_t cpu) {
  (void)cpu;
  return (FooResult){0};
}
FooResult foo_task_label(FooText name) {
  (void)name;
  return (FooResult){0};
}
FooResult foo_resource_threads(void) {
  uint64_t count = 0;
  pthread_mutex_lock(&registry);
  for (Entry *item = entries; item; item = item->next)
    if (item->kind == THREAD && !item->closed) count++;
  pthread_mutex_unlock(&registry);
  return (FooResult){.number = count};
}
FooResult foo_resource_tasks(void) {
  return (FooResult){.number = atomic_load_explicit(&working, memory_order_acquire)};
}
FooResult foo_resource_pending(void) {
  return (FooResult){.number = atomic_load_explicit(&waiting, memory_order_acquire)};
}
