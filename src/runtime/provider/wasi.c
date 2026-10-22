#define _POSIX_C_SOURCE 200809L
#include "service.h"
#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <pthread.h>
#include <stdatomic.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <time.h>
#include <unistd.h>
#include <wasi/wasip1.h>

enum { OK, MEMORY, ARGUMENT, IO, CLOSED, MISSING, SYSTEM, BOUNDS };
enum { THREAD, MUTEX, CONDITION, SCOPE, POOL, CHANNEL, EXECUTOR, TEXT,
  FILE_RESOURCE, DIRECTORY_RESOURCE, METADATA_RESOURCE, WALK_RESOURCE,
  MAP_RESOURCE, CHILD_RESOURCE, SOCKET_RESOURCE };

typedef struct Entry {
  struct Entry *next;
  void *data;
  int kind;
  int closed;
  size_t size;
} Entry;

static pthread_mutex_t registry = PTHREAD_MUTEX_INITIALIZER;
static Entry *entries;
static atomic_uint_fast64_t working;
static atomic_uint_fast64_t waiting;
static int argc;
static char **argv;

static FooResult failure(int error) { return (FooResult){.error = error}; }

static void *owned(size_t size, int kind) {
  void *data = calloc(1, size);
  Entry *entry = calloc(1, sizeof(*entry));
  if (!data || !entry) {
    free(data);
    free(entry);
    return NULL;
  }
  entry->data = data;
  entry->kind = kind;
  entry->size = size;
  pthread_mutex_lock(&registry);
  entry->next = entries;
  entries = entry;
  pthread_mutex_unlock(&registry);
  return data;
}

static Entry *entry(void *data, int kind) {
  pthread_mutex_lock(&registry);
  Entry *found = entries;
  while (found && (found->data != data || found->kind != kind || found->closed))
    found = found->next;
  pthread_mutex_unlock(&registry);
  return found;
}

static void retire(Entry *item) {
  pthread_mutex_lock(&registry);
  item->closed = 1;
  pthread_mutex_unlock(&registry);
}

#include "../codec/wasi.c"


#include "../files/wasi.c"


#include "../net/wasi.c"

#include "../process/wasi.c"


#include "../time/wasi.c"


#include "../tasks/wasi.c"


void foo_service_init(int count, char **arguments) {
  argc = count;
  argv = arguments;
}

void foo_service_close(void) {
  for (Entry *item = entries; item; item = item->next)
    if (!item->closed && item->kind == SCOPE) foo_task_cancel(item->data);
  for (Entry *item = entries; item; item = item->next)
    if (!item->closed && item->kind == POOL) foo_task_interrupt(item->data);
  for (Entry *item = entries; item; item = item->next)
    if (!item->closed && item->kind == SCOPE) foo_task_join(item->data);
  for (Entry *item = entries; item; item = item->next)
    if (!item->closed && item->kind == POOL) {
      Pool *pool = item->data;
      foo_task_wait(pool);
      pthread_mutex_lock(&pool->lock);
      pool->stopping = 1;
      pthread_cond_broadcast(&pool->ready);
      pthread_mutex_unlock(&pool->lock);
      for (size_t index = 0; index < pool->count; index++)
        pthread_join(pool->workers[index], NULL);
      pthread_cond_destroy(&pool->ready);
      pthread_cond_destroy(&pool->done);
      pthread_mutex_destroy(&pool->lock);
      retire(item);
    }
  for (Entry *item = entries; item; item = item->next)
    if (!item->closed && item->kind == THREAD) foo_thread_wait(item->data);
#ifdef FOO_WASI_HOST_BRIDGE
  for (Entry *item = entries; item; item = item->next)
    if (!item->closed && item->kind == CHILD_RESOURCE) foo_process_close(item->data);
  for (Entry *item = entries; item; item = item->next)
    if (!item->closed && item->kind == SOCKET_RESOURCE) foo_net_close(item->data);
#endif
  for (Entry *item = entries; item;) {
    Entry *next = item->next;
    if (!item->closed && item->kind == MUTEX) pthread_mutex_destroy(item->data);
    if (!item->closed && item->kind == CONDITION) pthread_cond_destroy(item->data);
    if (!item->closed && item->kind == FILE_RESOURCE)
      fclose(((File *)item->data)->handle);
    if (!item->closed && item->kind == DIRECTORY_RESOURCE)
      closedir(((Directory *)item->data)->handle);
    if (!item->closed && item->kind == WALK_RESOURCE) {
      Walk *walk = item->data;
      while (walk->count) {
        Frame *frame = &walk->frames[--walk->count];
        closedir(frame->handle);
        free(frame->relative);
      }
      free(walk->frames);
      free(walk->root);
    }
    if (!item->closed && item->kind == MAP_RESOURCE) {
      Mapping *mapping = item->data;
      if (mapping->writable) publish(mapping, 0, mapping->length);
      fclose(mapping->stream);
      free(mapping->bytes);
    }
    free(item->data);
    free(item);
    item = next;
  }
  entries = NULL;
}
