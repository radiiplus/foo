/* Backend-independent hosted runtime. Compiles as ISO C11; OS APIs are isolated
 * here. */
#include <stdatomic.h>
#include "arch.h"
#if defined(_WIN32)
#ifndef WIN32_LEAN_AND_MEAN
#define WIN32_LEAN_AND_MEAN
#endif
#include <windows.h>
#else
#include <unistd.h>
#endif
typedef struct {
  const char *error;
  void *pointer;
  uint64_t number;
  bool boolean;
  uint8_t unit;
  FOOText text;
  FOOWide wide;
  FOOPoints points;
} FOOResult;
typedef struct {
  bool present;
  uint32_t value;
} FOONext;
typedef struct FOOAllocation {
  void *pointer;
  size_t size;
  size_t used;
  size_t capacity;
  size_t element;
  size_t references;
  bool sequence;
  bool retired;
  struct FOOAllocation *sequence_next;
  struct FOOAllocation *next;
} FOOAllocation;
static FOOAllocation *foo_allocations;
static FOOAllocation **foo_sequence_slots;
static size_t foo_sequence_slots_count;
static size_t foo_sequence_count;
static atomic_flag foo_lock = ATOMIC_FLAG_INIT;
static void foo_enter(void) {
  while (atomic_flag_test_and_set_explicit(&foo_lock, memory_order_acquire)) {
  }
}
static void foo_leave(void) {
  atomic_flag_clear_explicit(&foo_lock, memory_order_release);
}
static uint64_t foo_heap_bytes(void) {
  uint64_t total = 0;
  foo_enter();
  for (FOOAllocation *item = foo_allocations; item; item = item->next)
    total = item->size > UINT64_MAX - total ? UINT64_MAX : total + item->size;
  foo_leave();
  return total;
}
static size_t foo_sequence_bucket(const void *pointer, size_t count) {
  uintptr_t value = (uintptr_t)pointer;
  value ^= value >> 17;
  value *= (uintptr_t)UINT64_C(0xed5ad4bb);
  value ^= value >> 11;
  return (size_t)value & (count - 1);
}
static bool foo_sequence_grow(void) {
  size_t count = foo_sequence_slots_count ? foo_sequence_slots_count * 2 : 16;
  if (count < foo_sequence_slots_count || count > SIZE_MAX / sizeof(*foo_sequence_slots))
    return false;
  FOOAllocation **slots = calloc(count, sizeof(*slots));
  if (!slots) return false;
  for (FOOAllocation *item = foo_allocations; item; item = item->next) {
    if (!item->sequence) continue;
    size_t bucket = foo_sequence_bucket(item->pointer, count);
    item->sequence_next = slots[bucket];
    slots[bucket] = item;
  }
  free(foo_sequence_slots);
  foo_sequence_slots = slots;
  foo_sequence_slots_count = count;
  return true;
}
static FOOAllocation *foo_sequence_find(const void *pointer) {
  if (!foo_sequence_slots_count) return NULL;
  size_t bucket = foo_sequence_bucket(pointer, foo_sequence_slots_count);
  for (FOOAllocation *item = foo_sequence_slots[bucket]; item;
       item = item->sequence_next)
    if (item->pointer == pointer) return item;
  return NULL;
}
static void foo_sequence_unlink(FOOAllocation *item) {
  size_t bucket = foo_sequence_bucket(item->pointer, foo_sequence_slots_count);
  FOOAllocation **cursor = &foo_sequence_slots[bucket];
  while (*cursor && *cursor != item) cursor = &(*cursor)->sequence_next;
  if (*cursor) {
    *cursor = item->sequence_next;
    foo_sequence_count--;
  }
}
static bool foo_track(void *pointer, size_t size, size_t used,
                      size_t capacity, size_t element, bool sequence) {
  if (!pointer)
    return false;
  FOOAllocation *item = malloc(sizeof(*item));
  if (!item)
    return false;
  item->pointer = pointer;
  item->size = size;
  item->used = used;
  item->capacity = capacity;
  item->element = element;
  item->references = sequence ? 1 : 0;
  item->sequence = sequence;
  item->retired = false;
  item->sequence_next = NULL;
  foo_enter();
  if (sequence && (!foo_sequence_slots_count || foo_sequence_count + 1 >
      foo_sequence_slots_count - foo_sequence_slots_count / 4)) {
    if (!foo_sequence_grow()) {
      foo_leave();
      free(item);
      return false;
    }
  }
  if (sequence) {
    size_t bucket = foo_sequence_bucket(pointer, foo_sequence_slots_count);
    item->sequence_next = foo_sequence_slots[bucket];
    foo_sequence_slots[bucket] = item;
    foo_sequence_count++;
  }
  item->next = foo_allocations;
  foo_allocations = item;
  foo_leave();
  foo_metric_allocate(size);
  return true;
}
static bool foo_adopt(void *pointer, size_t size) {
  return foo_track(pointer, size, 0, 0, 0, false);
}
static void foo_benchmark_report(void) {
  double average = foo_metric_capacity_samples ?
      (double)foo_metric_capacity_total / (double)foo_metric_capacity_samples : 0.0;
  double factor = foo_metric_requested_total ?
      (double)foo_metric_capacity_total / (double)foo_metric_requested_total : 0.0;
  fprintf(stderr,
      "FOO_METRICS {\"allocations\":%llu,\"allocatedBytes\":%llu,"
      "\"reallocations\":%llu,\"bytesCopied\":%llu,"
      "\"growthOperations\":%llu,\"growthBytesCopied\":%llu,"
      "\"averageCapacity\":%.3f,\"maximumCapacity\":%llu,"
      "\"growthFactor\":%.3f,\"liveBytes\":%llu,"
      "\"peakBytes\":%llu,\"olderVersionBytes\":%llu,"
      "\"slowPathHits\":%llu,\"branchOperations\":%llu,"
      "\"branchBytesCopied\":%llu}\n",
      (unsigned long long)foo_metric_allocations,
      (unsigned long long)foo_metric_allocated_bytes,
      (unsigned long long)foo_metric_reallocations,
      (unsigned long long)foo_metric_copied_bytes,
      (unsigned long long)foo_metric_growths,
      (unsigned long long)foo_metric_growth_bytes, average,
      (unsigned long long)foo_metric_capacity_max, factor,
      (unsigned long long)foo_metric_live_bytes,
      (unsigned long long)foo_metric_peak_bytes,
      (unsigned long long)foo_metric_retained_bytes,
      (unsigned long long)foo_metric_slow_paths,
      (unsigned long long)foo_metric_branches,
      (unsigned long long)foo_metric_branch_bytes);
}
static void *foo_owned(size_t size) {
  void *pointer = malloc(size ? size : 1);
  if (!pointer || !foo_adopt(pointer, size)) {
    free(pointer);
    return NULL;
  }
  return pointer;
}
static FOOResult foo_error(const char *error);
static void *foo_sequence_owned(size_t element, size_t capacity, size_t used) {
  if (!element || used > capacity || capacity > SIZE_MAX / element)
    return NULL;
  size_t size = capacity * element;
  void *pointer = malloc(size ? size : 1);
  if (!pointer || !foo_track(pointer, size, used, capacity, element, true)) {
    free(pointer);
    return NULL;
  }
  return pointer;
}
static size_t foo_sequence_capacity(size_t count) {
  size_t capacity = 8;
  while (capacity < count) {
    if (capacity > SIZE_MAX / 2)
      return count;
    capacity *= 2;
  }
  return capacity;
}
static FOOResult foo_sequence_append(const void *source, size_t length,
                                     size_t element, const void *value) {
  if (!element || length == SIZE_MAX || length + 1 > SIZE_MAX / element)
    return foo_error("Overflow");
  size_t count = length + 1, capacity = foo_sequence_capacity(count);
  bool branch = false;
  const void *retire = NULL;
  foo_benchmark_accumulate(&foo_metric_growths, 1);
  foo_benchmark_accumulate(&foo_metric_requested_total, count);
  foo_enter();
  FOOAllocation *allocation = foo_sequence_find(source);
  if (allocation && allocation->sequence && allocation->element == element) {
    if (length > allocation->used) {
      foo_leave();
      return foo_error("InvalidBuffer");
    }
    if (length == allocation->used && allocation->used < allocation->capacity) {
      if (allocation->references == SIZE_MAX) {
        foo_leave();
        return foo_error("Overflow");
      }
      uint8_t *items = allocation->pointer;
      memcpy(items + length * element, value, element);
      allocation->used = count;
      allocation->references++;
      capacity = allocation->capacity;
      foo_leave();
      foo_metric_capacity(capacity);
      return (FOOResult){.text = {(const uint8_t *)items, count}};
    }
    branch = length < allocation->used;
    if (!branch && allocation->capacity <= SIZE_MAX / 2)
      capacity = allocation->capacity * 2;
    if (!branch && !allocation->retired) retire = allocation->pointer;
  }
  foo_leave();
  if (capacity < count || capacity > SIZE_MAX / element)
    return foo_error("Overflow");
  uint8_t *items = foo_sequence_owned(element, capacity, count);
  if (!items) return foo_error("OutOfMemory");
  if (retire) {
    foo_enter();
    FOOAllocation *previous = foo_sequence_find(retire);
    if (previous && !previous->retired) {
      previous->retired = true;
      foo_benchmark_accumulate(&foo_metric_retained_bytes, previous->size);
    }
    foo_leave();
  }
  size_t copied = length * element;
  if (copied) foo_transfer(items, source, copied);
  memcpy(items + copied, value, element);
  foo_benchmark_accumulate(&foo_metric_slow_paths, 1);
  foo_benchmark_accumulate(&foo_metric_growth_bytes, copied);
  if (branch) {
    foo_benchmark_accumulate(&foo_metric_branches, 1);
    foo_benchmark_accumulate(&foo_metric_branch_bytes, copied);
  }
  foo_metric_capacity(capacity);
  return (FOOResult){.text = {items, count}};
}
typedef struct {
  uint64_t hash;
  uint8_t state;
  uint8_t *key;
  size_t key_size;
  uint8_t *value;
  size_t value_size;
} FOOHashEntry;
typedef struct FOOHashMap {
  FOOHashEntry *entries;
  size_t capacity, length, value_size;
  bool alive;
  struct FOOHashMap *next;
} FOOHashMap;
static FOOHashMap *foo_hashmaps;
static uint64_t foo_hash_bytes(const uint8_t *data, size_t size) {
  uint64_t hash = UINT64_C(14695981039346656037);
  for (size_t index = 0; index < size; index++) {
    hash ^= data[index];
    hash *= UINT64_C(1099511628211);
  }
  return hash ? hash : 1;
}
static bool foo_hash_key(FOOHashEntry *entry, uint64_t hash, FOOText key) {
  return entry->state == 1 && entry->hash == hash &&
         entry->key_size == key.len &&
         (!key.len || !memcmp(entry->key, key.data, key.len));
}
static FOOHashEntry *foo_hash_slot(FOOHashMap *map, uint64_t hash,
                                   FOOText key, bool insert) {
  size_t index = (size_t)hash & (map->capacity - 1), first_removed = SIZE_MAX;
  for (;;) {
    FOOHashEntry *entry = &map->entries[index];
    if (!entry->state)
      return insert && first_removed != SIZE_MAX ?
          &map->entries[first_removed] : entry;
    if (foo_hash_key(entry, hash, key)) return entry;
    if (insert && entry->state == 2 && first_removed == SIZE_MAX)
      first_removed = index;
    index = (index + 1) & (map->capacity - 1);
  }
}
static bool foo_hash_grow(FOOHashMap *map) {
  size_t capacity = map->capacity ? map->capacity * 2 : 16;
  if (capacity < map->capacity || capacity > SIZE_MAX / sizeof(FOOHashEntry))
    return false;
  FOOHashEntry *entries = calloc(capacity, sizeof(*entries));
  if (!entries) return false;
  FOOHashEntry *previous = map->entries;
  size_t previous_capacity = map->capacity;
  map->entries = entries;
  map->capacity = capacity;
  for (size_t index = 0; index < previous_capacity; index++) {
    FOOHashEntry *entry = &previous[index];
    if (entry->state != 1) continue;
    FOOText key = {entry->key, entry->key_size};
    *foo_hash_slot(map, entry->hash, key, true) = *entry;
  }
  free(previous);
  return true;
}
static FOOHashMap *foo_hashmap_value(void *handle) {
  for (FOOHashMap *map = foo_hashmaps; map; map = map->next)
    if (map == handle) return map->alive ? map : NULL;
  return NULL;
}
static FOOResult foo_hashmap_create(void) {
  FOOHashMap *map = calloc(1, sizeof(*map));
  if (!map) return foo_error("OutOfMemory");
  map->alive = true;
  map->next = foo_hashmaps;
  foo_hashmaps = map;
  return (FOOResult){.pointer = map};
}
static FOOResult foo_hashmap_put(void *handle, FOOText key,
                                 const void *value, size_t value_size) {
  FOOHashMap *map = foo_hashmap_value(handle);
  if (!map) return foo_error("Closed");
  if (map->value_size && map->value_size != value_size)
    return foo_error("InvalidValue");
  if (!map->capacity || (map->length + 1) * 4 >= map->capacity * 3)
    if (!foo_hash_grow(map)) return foo_error("OutOfMemory");
  uint64_t hash = foo_hash_bytes(key.data, key.len);
  FOOHashEntry *entry = foo_hash_slot(map, hash, key, true);
  uint8_t *copy = malloc(value_size ? value_size : 1);
  if (!copy) return foo_error("OutOfMemory");
  if (value_size) foo_transfer(copy, value, value_size);
  if (entry->state == 1) {
    free(entry->value);
    entry->value = copy;
    entry->value_size = value_size;
    return (FOOResult){0};
  }
  uint8_t *name = malloc(key.len ? key.len : 1);
  if (!name) { free(copy); return foo_error("OutOfMemory"); }
  if (key.len) foo_transfer(name, key.data, key.len);
  *entry = (FOOHashEntry){hash, 1, name, key.len, copy, value_size};
  map->value_size = value_size;
  map->length++;
  return (FOOResult){0};
}
static FOOResult foo_hashmap_get(void *handle, FOOText key) {
  FOOHashMap *map = foo_hashmap_value(handle);
  if (!map) return foo_error("Closed");
  if (!map->capacity) return foo_error("Missing");
  FOOHashEntry *entry = foo_hash_slot(map, foo_hash_bytes(key.data, key.len), key, false);
  return entry->state == 1 ? (FOOResult){.pointer = entry->value} :
                            foo_error("Missing");
}
static FOOResult foo_hashmap_contains(void *handle, FOOText key) {
  FOOHashMap *map = foo_hashmap_value(handle);
  if (!map) return foo_error("Closed");
  if (!map->capacity) return (FOOResult){.boolean = false};
  FOOHashEntry *entry = foo_hash_slot(map, foo_hash_bytes(key.data, key.len), key, false);
  return (FOOResult){.boolean = entry->state == 1};
}
static FOOResult foo_hashmap_remove(void *handle, FOOText key) {
  FOOHashMap *map = foo_hashmap_value(handle);
  if (!map) return foo_error("Closed");
  if (!map->capacity) return (FOOResult){.boolean = false};
  FOOHashEntry *entry = foo_hash_slot(map, foo_hash_bytes(key.data, key.len), key, false);
  if (entry->state != 1) return (FOOResult){.boolean = false};
  free(entry->key);
  free(entry->value);
  entry->key = entry->value = NULL;
  entry->state = 2;
  map->length--;
  return (FOOResult){.boolean = true};
}
static FOOResult foo_hashmap_length(void *handle) {
  FOOHashMap *map = foo_hashmap_value(handle);
  return map ? (FOOResult){.number = map->length} : foo_error("Closed");
}
static void foo_hashmap_clear(FOOHashMap *map) {
  for (size_t index = 0; index < map->capacity; index++)
    if (map->entries[index].state == 1) {
      free(map->entries[index].key);
      free(map->entries[index].value);
    }
  free(map->entries);
  map->entries = NULL;
  map->capacity = map->length = 0;
}
static FOOResult foo_hashmap_close(void *handle) {
  FOOHashMap *map = foo_hashmap_value(handle);
  if (!map) return foo_error("Closed");
  foo_hashmap_clear(map);
  map->alive = false;
  return (FOOResult){0};
}
static void foo_hashmap_shutdown(void) {
  while (foo_hashmaps) {
    FOOHashMap *map = foo_hashmaps;
    foo_hashmaps = map->next;
    if (map->alive) foo_hashmap_clear(map);
    free(map);
  }
}
#if defined(FOO_MEMORY) || defined(FOO_LIST) || defined(FOO_STREAM)
static void foo_storage_shutdown(void);
#endif
static void foo_shutdown(void) {
#ifdef FOO_SERVICE
  foo_service_close();
#endif
  foo_hashmap_shutdown();
  foo_enter();
#if defined(FOO_MEMORY) || defined(FOO_LIST) || defined(FOO_STREAM)
  foo_storage_shutdown();
#endif
  while (foo_allocations) {
    FOOAllocation *item = foo_allocations;
    foo_allocations = item->next;
    free(item->pointer);
    free(item);
  }
  free(foo_sequence_slots);
  foo_sequence_slots = NULL;
  foo_sequence_slots_count = foo_sequence_count = 0;
  foo_leave();
}
static FOOResult foo_error(const char *error) {
  return (FOOResult){.error = error};
}
static FOOText foo_text(const char *value) {
  return (FOOText){(const uint8_t *)value, strlen(value)};
}
static FOOText foo_join(FOOText a, FOOText b) {
  if (b.len > SIZE_MAX - a.len) foo_panic("Overflow");
  uint8_t *bytes = foo_owned(a.len + b.len);
  if (!bytes) foo_panic("OutOfMemory");
  if (a.len) foo_transfer(bytes, a.data, a.len);
  if (b.len) foo_transfer(bytes + a.len, b.data, b.len);
  return (FOOText){bytes, a.len + b.len};
}
static bool foo_equal(FOOText a, const char *b) {
  return a.len == strlen(b) && !memcmp(a.data, b, a.len);
}
static void foo_testing_expect(bool value) {
  if (!value)
    foo_panic("AssertionFailed");
}
static void foo_testing_same(FOOText actual, FOOText expected) {
  if (actual.len != expected.len ||
      memcmp(actual.data, expected.data, actual.len))
    foo_panic("TextMismatch");
}
static void foo_testing_number(uint64_t actual, uint64_t expected) {
  if (actual != expected)
    foo_panic("NumberMismatch");
}
static void foo_testing_positive(uint64_t value) {
  if (!value)
    foo_panic("ExpectedPositive");
}
static void foo_testing_real(double actual, double expected) {
  if (actual != expected)
    foo_panic("NumberMismatch");
}
static void foo_testing_point(FOONext actual, uint32_t expected) {
  if (!actual.present || actual.value != expected)
    foo_panic("PointMismatch");
}
static FOOResult foo_copy(const void *value, size_t length) {
  uint8_t *copy = foo_owned(length);
  if (!copy)
    return foo_error("OutOfMemory");
  if (length)
    foo_transfer(copy, value, length);
  return (FOOResult){.text = {copy, length}};
}
static FOOResult foo_free(const void *pointer, size_t size) {
  if (!size)
    return (FOOResult){0};
  foo_enter();
  FOOAllocation **cursor = &foo_allocations;
  while (*cursor && (*cursor)->pointer != pointer)
    cursor = &(*cursor)->next;
  if (!*cursor) {
    foo_leave();
    return foo_error("UnknownBuffer");
  }
  FOOAllocation *item = *cursor;
  if (item->size != size) {
    foo_leave();
    return foo_error("InvalidBuffer");
  }
  *cursor = item->next;
  if (item->sequence) foo_sequence_unlink(item);
  foo_metric_release(item->size, item->retired);
  foo_leave();
  free(item->pointer);
  free(item);
  return (FOOResult){0};
}
static FOOResult foo_sequence_free(const void *pointer, size_t length,
                                   size_t element) {
  if (!length) return (FOOResult){0};
  foo_enter();
  FOOAllocation **cursor = &foo_allocations;
  while (*cursor && (*cursor)->pointer != pointer)
    cursor = &(*cursor)->next;
  if (!*cursor) {
    foo_leave();
    return foo_error("UnknownBuffer");
  }
  FOOAllocation *item = *cursor;
  if (!item->sequence || item->element != element || length > item->used) {
    foo_leave();
    return foo_error("InvalidBuffer");
  }
  if (item->references > 1) {
    item->references--;
    foo_leave();
    return (FOOResult){0};
  }
  *cursor = item->next;
  foo_sequence_unlink(item);
  foo_metric_release(item->size, item->retired);
  foo_leave();
  free(item->pointer);
  free(item);
  return (FOOResult){0};
}
static FOOResult foo_buffer_free(FOOText value) {
  return foo_free(value.data, value.len);
}
static FOOResult foo_buffer_words(FOOWide value) {
  return foo_free(value.data, value.len * sizeof(uint16_t));
}
static FOOResult foo_buffer_points(FOOPoints value) {
  return foo_free(value.data, value.len * sizeof(uint32_t));
}

static FOOResult foo_system_cores(void) {
#if defined(_WIN32)
  SYSTEM_INFO info;
  GetSystemInfo(&info);
  return (FOOResult){.number = info.dwNumberOfProcessors};
#else
  long count = sysconf(_SC_NPROCESSORS_ONLN);
  return count < 1 ? foo_error("SystemResources")
                   : (FOOResult){.number = (uint64_t)count};
#endif
}
static uint64_t foo_system_page(void) {
#if defined(_WIN32)
  SYSTEM_INFO info;
  GetSystemInfo(&info);
  return info.dwPageSize;
#else
  long size = sysconf(_SC_PAGESIZE);
  if (size < 1)
    foo_panic("SystemResources");
  return (uint64_t)size;
#endif
}

/* Strict scalar decoder: rejects overlong encodings, surrogates and values >
 * U+10FFFF. */
static bool foo_decode(FOOText text, size_t *index, uint32_t *result) {
  if (*index >= text.len)
    return false;
  uint32_t first = text.data[(*index)++], value;
  unsigned count;
  if (first < 128) {
    *result = first;
    return true;
  }
  if (first >= 0xc2 && first <= 0xdf) {
    count = 1;
    value = first & 31;
  } else if (first >= 0xe0 && first <= 0xef) {
    count = 2;
    value = first & 15;
  } else if (first >= 0xf0 && first <= 0xf4) {
    count = 3;
    value = first & 7;
  } else
    return false;
  if (text.len - *index < count)
    return false;
  for (unsigned k = 0; k < count; k++) {
    uint32_t byte = text.data[(*index)++];
    if ((byte & 0xc0) != 0x80)
      return false;
    value = value * 64 + (byte & 63);
  }
  if ((count == 1 && value < 128) || (count == 2 && value < 0x800) ||
      (count == 3 && value < 0x10000) || value > 0x10ffff ||
      (value >= 0xd800 && value <= 0xdfff))
    return false;
  *result = value;
  return true;
}
static bool foo_unicode_valid(FOOText value) {
  size_t index = 0;
  uint32_t point;
  while (index < value.len)
    if (!foo_decode(value, &index, &point))
      return false;
  return true;
}
typedef struct {
  FOOText text;
  size_t index;
} FOOCursor;
static FOOResult foo_unicode_scan(FOOText value) {
  if (!foo_unicode_valid(value))
    return foo_error("InvalidUtf8");
  FOOCursor *cursor = calloc(1, sizeof(*cursor));
  uint8_t *data = malloc(value.len ? value.len : 1);
  if (!cursor || !data) {
    free(cursor);
    free(data);
    return foo_error("OutOfMemory");
  }
  foo_transfer(data, value.data, value.len);
  cursor->text = (FOOText){data, value.len};
  return (FOOResult){.pointer = cursor};
}
static FOONext foo_unicode_next(void *value) {
  FOOCursor *cursor = value;
  uint32_t point = 0;
  bool present = foo_decode(cursor->text, &cursor->index, &point);
  return (FOONext){present, point};
}
static void foo_unicode_release(void *value) {
  FOOCursor *cursor = value;
  free((void *)cursor->text.data);
  free(cursor);
}
static FOOResult foo_unicode_points(FOOText value) {
  if (!foo_unicode_valid(value))
    return foo_error("InvalidUtf8");
  if (value.len > SIZE_MAX / sizeof(uint32_t))
    return foo_error("OutOfMemory");
  size_t index = 0, count = 0;
  uint32_t point;
  while (index < value.len) {
    foo_decode(value, &index, &point);
    count++;
  }
  uint32_t *data = foo_owned(count * sizeof(*data));
  if (!data)
    return foo_error("OutOfMemory");
  index = 0;
  count = 0;
  while (index < value.len) {
    foo_decode(value, &index, &point);
    data[count++] = point;
  }
  return (FOOResult){.points = {data, count}};
}
static FOOResult foo_unicode_wide(FOOText value) {
  if (!foo_unicode_valid(value))
    return foo_error("InvalidUtf8");
  size_t index = 0, count = 0;
  uint32_t point;
  while (index < value.len) {
    foo_decode(value, &index, &point);
    count += point >= 0x10000 ? 2 : 1;
  }
  if (count > SIZE_MAX / sizeof(uint16_t))
    return foo_error("OutOfMemory");
  uint16_t *data = foo_owned(count * sizeof(*data));
  if (!data)
    return foo_error("OutOfMemory");
  index = 0;
  count = 0;
  while (index < value.len) {
    foo_decode(value, &index, &point);
    if (point < 0x10000)
      data[count++] = (uint16_t)point;
    else {
      point -= 0x10000;
      data[count++] = (uint16_t)(0xd800 + (point >> 10));
      data[count++] = (uint16_t)(0xdc00 + (point & 1023));
    }
  }
  return (FOOResult){.wide = {data, count}};
}
static size_t foo_encode(uint8_t *data, uint32_t point) {
  if (point < 128) {
    data[0] = (uint8_t)point;
    return 1;
  }
  if (point < 0x800) {
    data[0] = (uint8_t)(0xc0 | (point >> 6));
    data[1] = (uint8_t)(0x80 | (point & 63));
    return 2;
  }
  if (point < 0x10000) {
    data[0] = (uint8_t)(0xe0 | (point >> 12));
    data[1] = (uint8_t)(0x80 | ((point >> 6) & 63));
    data[2] = (uint8_t)(0x80 | (point & 63));
    return 3;
  }
  data[0] = (uint8_t)(0xf0 | (point >> 18));
  data[1] = (uint8_t)(0x80 | ((point >> 12) & 63));
  data[2] = (uint8_t)(0x80 | ((point >> 6) & 63));
  data[3] = (uint8_t)(0x80 | (point & 63));
  return 4;
}
static FOOResult foo_unicode_narrow(FOOWide value) {
  if (value.len > SIZE_MAX / 3)
    return foo_error("OutOfMemory");
  uint8_t *data = malloc(value.len * 3 + 1);
  if (!data)
    return foo_error("OutOfMemory");
  size_t count = 0;
  for (size_t k = 0; k < value.len; k++) {
    uint32_t point = value.data[k];
    if (point >= 0xd800 && point <= 0xdbff) {
      if (++k == value.len || value.data[k] < 0xdc00 ||
          value.data[k] > 0xdfff) {
        free(data);
        return foo_error("InvalidUtf16");
      }
      point = 0x10000 + ((point - 0xd800) << 10) + value.data[k] - 0xdc00;
    } else if (point >= 0xdc00 && point <= 0xdfff) {
      free(data);
      return foo_error("InvalidUtf16");
    }
    count += foo_encode(data + count, point);
  }
  FOOResult result = foo_copy(data, count);
  free(data);
  return result;
}
static FOOResult foo_system_host(void) {
#if defined(_WIN32)
  WCHAR data[256];
  DWORD length = 256;
  if (!GetComputerNameW(data, &length))
    return foo_error("SystemResources");
  return foo_unicode_narrow((FOOWide){(uint16_t *)data, length});
#else
  char data[256];
  if (gethostname(data, sizeof(data)))
    return foo_error("SystemResources");
  data[255] = 0;
  return foo_copy(data, strlen(data));
#endif
}

typedef struct {
  _Atomic uint64_t value;
} FOOAtom;
static FOOResult foo_atomic_create(uint64_t value) {
  FOOAtom *atom = malloc(sizeof(*atom));
  if (!atom)
    return foo_error("OutOfMemory");
  atomic_init(&atom->value, value);
  return (FOOResult){.pointer = atom};
}
static void foo_atomic_release(void *value) { free(value); }
static bool foo_order(FOOText text, memory_order *order) {
  if (foo_equal(text, "relaxed"))
    *order = memory_order_relaxed;
  else if (foo_equal(text, "acquire"))
    *order = memory_order_acquire;
  else if (foo_equal(text, "release"))
    *order = memory_order_release;
  else if (foo_equal(text, "both"))
    *order = memory_order_acq_rel;
  else if (foo_equal(text, "sequential"))
    *order = memory_order_seq_cst;
  else
    return false;
  return true;
}
static FOOResult foo_atomic_load(void *value, FOOText text) {
  memory_order order;
  if (!foo_order(text, &order) || order == memory_order_release ||
      order == memory_order_acq_rel)
    return foo_error("InvalidOrder");
  return (FOOResult){
      .number = atomic_load_explicit(&((FOOAtom *)value)->value, order)};
}
static FOOResult foo_atomic_store(void *value, uint64_t number, FOOText text) {
  memory_order order;
  if (!foo_order(text, &order) || order == memory_order_acquire ||
      order == memory_order_acq_rel)
    return foo_error("InvalidOrder");
  atomic_store_explicit(&((FOOAtom *)value)->value, number, order);
  return (FOOResult){0};
}
static FOOResult foo_atomic_add(void *value, uint64_t number, FOOText text) {
  memory_order order;
  if (!foo_order(text, &order))
    return foo_error("InvalidOrder");
  return (FOOResult){.number = atomic_fetch_add_explicit(
                         &((FOOAtom *)value)->value, number, order)};
}
static FOOResult foo_atomic_deduct(void *value, uint64_t number,
                                     FOOText text) {
  memory_order order;
  if (!foo_order(text, &order))
    return foo_error("InvalidOrder");
  return (FOOResult){.number = atomic_fetch_sub_explicit(
                         &((FOOAtom *)value)->value, number, order)};
}
static FOOResult foo_atomic_swap(void *value, uint64_t number, FOOText text) {
  memory_order order;
  if (!foo_order(text, &order))
    return foo_error("InvalidOrder");
  return (FOOResult){.number = atomic_exchange_explicit(
                         &((FOOAtom *)value)->value, number, order)};
}
static FOOResult foo_atomic_replace(void *value, uint64_t expected,
                                    uint64_t number, FOOText text) {
  memory_order order;
  if (!foo_order(text, &order))
    return foo_error("InvalidOrder");
  return (FOOResult){.boolean = atomic_compare_exchange_strong_explicit(
                         &((FOOAtom *)value)->value, &expected, number, order,
                         memory_order_relaxed)};
}
static FOOResult foo_atomic_compare(void *value, uint64_t expected,
                                    uint64_t number, FOOText success_text,
                                    FOOText failure_text) {
  memory_order success, failure;
  if (!foo_order(success_text, &success) ||
      !foo_order(failure_text, &failure) ||
      failure == memory_order_release || failure == memory_order_acq_rel ||
      (failure == memory_order_acquire &&
       success != memory_order_acquire && success != memory_order_acq_rel &&
       success != memory_order_seq_cst) ||
      (failure == memory_order_seq_cst && success != memory_order_seq_cst))
    return foo_error("InvalidOrder");
  return (FOOResult){.boolean = atomic_compare_exchange_strong_explicit(
                         &((FOOAtom *)value)->value, &expected, number,
                         success, failure)};
}

#ifdef FOO_BINARY
static FOOResult foo_binary_octet(uint64_t value) {
  return value <= UINT8_MAX ? (FOOResult){.number = value}
                            : foo_error("Bounds");
}
static uint64_t foo_binary_widen(uint8_t value) { return value; }
static FOOResult foo_binary_encode(uint64_t value) {
  uint64_t rest = value;
  size_t count = 1;
  while (rest >= 128) { rest >>= 7; count++; }
  uint8_t *bytes = foo_sequence_owned(1, count, count);
  if (!bytes) return foo_error("OutOfMemory");
  for (size_t index = 0; index < count; index++) {
    bytes[index] = (uint8_t)(value & 127u);
    value >>= 7;
    if (index + 1 < count) bytes[index] |= 128u;
  }
  return (FOOResult){.text = {bytes, count}};
}
static FOOResult foo_binary_read(FOOText source, uint64_t offset,
                                 uint64_t *value, uint64_t *next) {
  if (offset > source.len || (source.len && !source.data))
    return foo_error("Bounds");
  uint64_t number = 0;
  for (size_t index = 0; index < 10 && index < source.len - (size_t)offset;
       index++) {
    uint8_t byte = source.data[(size_t)offset + index];
    uint8_t part = byte & 127u;
    if (index == 9 && part > 1) return foo_error("InvalidEncoding");
    number |= (uint64_t)part << (7 * index);
    if (!(byte & 128u)) {
      if (index && !part) return foo_error("InvalidEncoding");
      *value = number;
      *next = offset + index + 1;
      return (FOOResult){0};
    }
  }
  return foo_error("InvalidEncoding");
}
static FOOResult foo_binary_scan(FOOText source, uint64_t offset) {
  uint64_t value = 0, next = 0;
  FOOResult result = foo_binary_read(source, offset, &value, &next);
  if (result.error) return result;
  return (FOOResult){.number = value};
}
static FOOResult foo_binary_next(FOOText source, uint64_t offset) {
  uint64_t value = 0, next = 0;
  FOOResult result = foo_binary_read(source, offset, &value, &next);
  if (result.error) return result;
  return (FOOResult){.number = next};
}
static FOOResult foo_binary_zigzag(int64_t value) {
  uint64_t bits = (uint64_t)value;
  return foo_binary_encode((bits << 1) ^ (value < 0 ? UINT64_MAX : 0));
}
static FOOResult foo_binary_unfold(FOOText source, uint64_t offset) {
  uint64_t value = 0, next = 0;
  FOOResult result = foo_binary_read(source, offset, &value, &next);
  if (result.error) return result;
  return (FOOResult){.number = (value >> 1) ^ (UINT64_C(0) - (value & 1))};
}
static int foo_binary_nibble(uint8_t value) {
  if (value >= '0' && value <= '9') return value - '0';
  if (value >= 'a' && value <= 'f') return value - 'a' + 10;
  return -1;
}
static FOOResult foo_binary_hex(FOOText value) {
  if (value.len && !value.data) return foo_error("InvalidInput");
  if (value.len > SIZE_MAX / 2) return foo_error("OutOfMemory");
  if (!value.len) return (FOOResult){0};
  static const char digits[] = "0123456789abcdef";
  uint8_t *output = foo_owned(value.len * 2);
  if (!output) return foo_error("OutOfMemory");
  for (size_t index = 0; index < value.len; index++) {
    output[index * 2] = digits[value.data[index] >> 4];
    output[index * 2 + 1] = digits[value.data[index] & 15];
  }
  return (FOOResult){.text = {output, value.len * 2}};
}
static FOOResult foo_binary_unpack(FOOText value) {
  if (value.len % 2 || (value.len && !value.data))
    return foo_error("InvalidEncoding");
  for (size_t index = 0; index < value.len; index++)
    if (foo_binary_nibble(value.data[index]) < 0)
      return foo_error("InvalidEncoding");
  if (!value.len) return (FOOResult){0};
  size_t count = value.len / 2;
  uint8_t *output = foo_sequence_owned(1, count, count);
  if (!output) return foo_error("OutOfMemory");
  for (size_t index = 0; index < count; index++)
    output[index] = (uint8_t)((foo_binary_nibble(value.data[index * 2]) << 4) |
                              foo_binary_nibble(value.data[index * 2 + 1]));
  return (FOOResult){.text = {output, count}};
}
static int foo_binary_sextet(uint8_t value) {
  if (value >= 'A' && value <= 'Z') return value - 'A';
  if (value >= 'a' && value <= 'z') return value - 'a' + 26;
  if (value >= '0' && value <= '9') return value - '0' + 52;
  return value == '-' ? 62 : value == '_' ? 63 : -1;
}
static FOOResult foo_binary_base64(FOOText value) {
  if (value.len && !value.data) return foo_error("InvalidInput");
  size_t groups = value.len / 3, remainder = value.len % 3;
  size_t extra = remainder ? remainder + 1 : 0;
  if (groups > (SIZE_MAX - extra) / 4) return foo_error("OutOfMemory");
  size_t count = groups * 4 + extra;
  if (!count) return (FOOResult){0};
  static const char alphabet[] =
      "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_";
  uint8_t *output = foo_owned(count);
  if (!output) return foo_error("OutOfMemory");
  size_t input = 0, written = 0;
  while (input + 3 <= value.len) {
    uint32_t block = ((uint32_t)value.data[input] << 16) |
        ((uint32_t)value.data[input + 1] << 8) | value.data[input + 2];
    output[written++] = alphabet[(block >> 18) & 63];
    output[written++] = alphabet[(block >> 12) & 63];
    output[written++] = alphabet[(block >> 6) & 63];
    output[written++] = alphabet[block & 63];
    input += 3;
  }
  if (remainder) {
    uint32_t block = (uint32_t)value.data[input] << 16;
    if (remainder == 2) block |= (uint32_t)value.data[input + 1] << 8;
    output[written++] = alphabet[(block >> 18) & 63];
    output[written++] = alphabet[(block >> 12) & 63];
    if (remainder == 2) output[written++] = alphabet[(block >> 6) & 63];
  }
  return (FOOResult){.text = {output, count}};
}
static FOOResult foo_binary_restore(FOOText value) {
  if (value.len % 4 == 1 || (value.len && !value.data))
    return foo_error("InvalidEncoding");
  for (size_t index = 0; index < value.len; index++)
    if (foo_binary_sextet(value.data[index]) < 0)
      return foo_error("InvalidEncoding");
  size_t remainder = value.len % 4;
  if (remainder && (foo_binary_sextet(value.data[value.len - 1]) &
      (remainder == 2 ? 15 : 3))) return foo_error("InvalidEncoding");
  size_t groups = value.len / 4, extra = remainder ? remainder - 1 : 0;
  if (groups > (SIZE_MAX - extra) / 3) return foo_error("OutOfMemory");
  size_t count = groups * 3 + extra;
  if (!count) return (FOOResult){0};
  uint8_t *output = foo_sequence_owned(1, count, count);
  if (!output) return foo_error("OutOfMemory");
  uint32_t accumulator = 0;
  unsigned bits = 0;
  size_t written = 0;
  for (size_t index = 0; index < value.len; index++) {
    accumulator = (accumulator << 6) | (uint32_t)foo_binary_sextet(value.data[index]);
    bits += 6;
    if (bits >= 8) {
      bits -= 8;
      output[written++] = (uint8_t)(accumulator >> bits);
    }
  }
  return (FOOResult){.text = {output, count}};
}
static int foo_binary_order(FOOText order) {
  if (order.len == 6 && !memcmp(order.data, "little", 6)) return 1;
  if (order.len == 3 && !memcmp(order.data, "big", 3)) return 2;
  return 0;
}
static FOOResult foo_binary_fixed(uint64_t value, uint64_t width,
                                  FOOText order) {
  int kind = foo_binary_order(order);
  if (!kind || width < 1 || width > 8 ||
      (width < 8 && value >= (UINT64_C(1) << (width * 8))))
    return foo_error("InvalidInput");
  uint8_t *bytes = foo_sequence_owned(1, (size_t)width, (size_t)width);
  if (!bytes) return foo_error("OutOfMemory");
  for (size_t index = 0; index < (size_t)width; index++) {
    size_t slot = kind == 1 ? index : (size_t)width - index - 1;
    bytes[slot] = (uint8_t)value;
    value >>= 8;
  }
  return (FOOResult){.text = {bytes, (size_t)width}};
}
static FOOResult foo_binary_parse(FOOText source, uint64_t offset,
                                  uint64_t width, FOOText order) {
  int kind = foo_binary_order(order);
  if (!kind || width < 1 || width > 8) return foo_error("InvalidInput");
  if (offset > source.len || width > source.len - (size_t)offset ||
      (source.len && !source.data)) return foo_error("Bounds");
  uint64_t value = 0;
  for (size_t index = 0; index < (size_t)width; index++) {
    size_t slot = kind == 1 ? (size_t)width - index - 1 : index;
    value = (value << 8) | source.data[(size_t)offset + slot];
  }
  return (FOOResult){.number = value};
}
#endif

#ifdef FOO_CHECKSUM
typedef struct {
  uint32_t value;
} FOOChecksum;
static void foo_checksum_update(void *handle, FOOText bytes) {
  FOOChecksum *state = handle;
  for (size_t index = 0; index < bytes.len; index++) {
    state->value ^= bytes.data[index];
    for (unsigned bit = 0; bit < 8; bit++)
      state->value = (state->value >> 1) ^
                     (0x82f63b78u & (0u - (state->value & 1u)));
  }
}
static uint32_t foo_checksum_compute(FOOText bytes) {
  FOOChecksum state = {UINT32_MAX};
  foo_checksum_update(&state, bytes);
  return ~state.value;
}
static FOOResult foo_checksum_begin(void) {
  FOOChecksum *state = malloc(sizeof(*state));
  if (!state) return foo_error("OutOfMemory");
  state->value = UINT32_MAX;
  return (FOOResult){.pointer = state};
}
static uint32_t foo_checksum_result(void *handle) {
  return ~((FOOChecksum *)handle)->value;
}
static void foo_checksum_close(void *handle) { free(handle); }
#endif

#ifdef FOO_CRYPTO
#include <sodium.h>
#include <blake3.h>
static void foo_crypto_init(void) {
  if (sodium_init() < 0)
    foo_panic("RandomUnavailable");
}
static FOOResult foo_crypto_hash(FOOText value) {
  uint8_t digest[32];
  char encoded[65];
  crypto_hash_sha256(digest, value.data, value.len);
  sodium_bin2hex(encoded, sizeof(encoded), digest, sizeof(digest));
  return foo_copy(encoded, 64);
}
typedef struct {
  crypto_hash_sha256_state state;
  uint8_t digest[crypto_hash_sha256_BYTES];
  bool finalized;
} FOOHasher;
static FOOResult foo_crypto_digest(FOOText value) {
  uint8_t *digest = foo_sequence_owned(1, crypto_hash_sha256_BYTES,
                                       crypto_hash_sha256_BYTES);
  if (!digest) return foo_error("OutOfMemory");
  crypto_hash_sha256(digest, value.data, value.len);
  return (FOOResult){.text = {digest, crypto_hash_sha256_BYTES}};
}
static FOOResult foo_crypto_hex(FOOText value) {
  return foo_crypto_hash(value);
}
static FOOResult foo_crypto_begin(void) {
  FOOHasher *hasher = malloc(sizeof(*hasher));
  if (!hasher) return foo_error("OutOfMemory");
  crypto_hash_sha256_init(&hasher->state);
  hasher->finalized = false;
  return (FOOResult){.pointer = hasher};
}
static FOOResult foo_crypto_update(void *handle, FOOText value) {
  FOOHasher *hasher = handle;
  if (hasher->finalized) return foo_error("AlreadyFinalized");
  crypto_hash_sha256_update(&hasher->state, value.data, value.len);
  return (FOOResult){0};
}
static void foo_crypto_finish(FOOHasher *hasher) {
  if (!hasher->finalized) {
    crypto_hash_sha256_final(&hasher->state, hasher->digest);
    hasher->finalized = true;
  }
}
static FOOResult foo_crypto_finalize(void *handle) {
  FOOHasher *hasher = handle;
  foo_crypto_finish(hasher);
  char encoded[crypto_hash_sha256_BYTES * 2 + 1];
  sodium_bin2hex(encoded, sizeof(encoded), hasher->digest,
                 crypto_hash_sha256_BYTES);
  return foo_copy(encoded, crypto_hash_sha256_BYTES * 2);
}
static FOOResult foo_crypto_result(void *handle) {
  FOOHasher *hasher = handle;
  foo_crypto_finish(hasher);
  uint8_t *digest = foo_sequence_owned(1, crypto_hash_sha256_BYTES,
                                       crypto_hash_sha256_BYTES);
  if (!digest) return foo_error("OutOfMemory");
  memcpy(digest, hasher->digest, crypto_hash_sha256_BYTES);
  return (FOOResult){.text = {digest, crypto_hash_sha256_BYTES}};
}
static void foo_crypto_close(void *handle) { free(handle); }
typedef struct {
  blake3_hasher state;
} FOOBlakeHasher;
static FOOResult foo_crypto_blake(FOOText value) {
  uint8_t *digest = foo_sequence_owned(1, BLAKE3_OUT_LEN, BLAKE3_OUT_LEN);
  if (!digest) return foo_error("OutOfMemory");
  blake3_hasher state;
  blake3_hasher_init(&state);
  blake3_hasher_update(&state, value.data, value.len);
  blake3_hasher_finalize(&state, digest, BLAKE3_OUT_LEN);
  return (FOOResult){.text = {digest, BLAKE3_OUT_LEN}};
}
static FOOResult foo_crypto_fingerprint(FOOText value) {
  uint8_t digest[BLAKE3_OUT_LEN];
  char encoded[BLAKE3_OUT_LEN * 2 + 1];
  blake3_hasher state;
  blake3_hasher_init(&state);
  blake3_hasher_update(&state, value.data, value.len);
  blake3_hasher_finalize(&state, digest, sizeof(digest));
  sodium_bin2hex(encoded, sizeof(encoded), digest, sizeof(digest));
  return foo_copy(encoded, BLAKE3_OUT_LEN * 2);
}
static FOOResult foo_crypto_initiate(void) {
  FOOBlakeHasher *state = malloc(sizeof(*state));
  if (!state) return foo_error("OutOfMemory");
  blake3_hasher_init(&state->state);
  return (FOOResult){.pointer = state};
}
static FOOResult foo_crypto_append(void *handle, FOOText value) {
  blake3_hasher_update(&((FOOBlakeHasher *)handle)->state, value.data, value.len);
  return (FOOResult){0};
}
static FOOResult foo_crypto_extract(void *handle) {
  uint8_t *digest = foo_sequence_owned(1, BLAKE3_OUT_LEN, BLAKE3_OUT_LEN);
  if (!digest) return foo_error("OutOfMemory");
  blake3_hasher_finalize(&((FOOBlakeHasher *)handle)->state, digest, BLAKE3_OUT_LEN);
  return (FOOResult){.text = {digest, BLAKE3_OUT_LEN}};
}
static FOOResult foo_crypto_render(void *handle) {
  uint8_t digest[BLAKE3_OUT_LEN];
  char encoded[BLAKE3_OUT_LEN * 2 + 1];
  blake3_hasher_finalize(&((FOOBlakeHasher *)handle)->state, digest, sizeof(digest));
  sodium_bin2hex(encoded, sizeof(encoded), digest, sizeof(digest));
  return foo_copy(encoded, BLAKE3_OUT_LEN * 2);
}
static void foo_crypto_retire(void *handle) {
  FOOBlakeHasher *state = handle;
  sodium_memzero(state, sizeof(*state));
  free(state);
}
typedef struct {
  crypto_auth_hmacsha256_state state;
  uint8_t digest[crypto_auth_hmacsha256_BYTES];
  bool finalized;
} FOOAuthenticator;
static FOOResult foo_crypto_auth(FOOText secret) {
  FOOAuthenticator *value = malloc(sizeof(*value));
  if (!value) return foo_error("OutOfMemory");
  const uint8_t empty = 0;
  if (crypto_auth_hmacsha256_init(&value->state,
        secret.data ? secret.data : &empty, secret.len)) {
    sodium_memzero(value, sizeof(*value));
    free(value);
    return foo_error("InvalidLength");
  }
  value->finalized = false;
  return (FOOResult){.pointer = value};
}
static FOOResult foo_crypto_absorb(void *handle, FOOText bytes) {
  FOOAuthenticator *value = handle;
  if (value->finalized) return foo_error("AlreadyFinalized");
  const uint8_t empty = 0;
  crypto_auth_hmacsha256_update(&value->state,
      bytes.data ? bytes.data : &empty, bytes.len);
  return (FOOResult){0};
}
static void foo_crypto_authfinish(FOOAuthenticator *value) {
  if (!value->finalized) {
    crypto_auth_hmacsha256_final(&value->state, value->digest);
    value->finalized = true;
  }
}
static FOOResult foo_crypto_tag(void *handle) {
  FOOAuthenticator *value = handle;
  foo_crypto_authfinish(value);
  uint8_t *digest = foo_sequence_owned(1, crypto_auth_hmacsha256_BYTES,
                                       crypto_auth_hmacsha256_BYTES);
  if (!digest) return foo_error("OutOfMemory");
  memcpy(digest, value->digest, crypto_auth_hmacsha256_BYTES);
  return (FOOResult){.text = {digest, crypto_auth_hmacsha256_BYTES}};
}
static FOOResult foo_crypto_check(void *handle, FOOText expected) {
  FOOAuthenticator *value = handle;
  foo_crypto_authfinish(value);
  return (FOOResult){.boolean = expected.len == crypto_auth_hmacsha256_BYTES &&
      expected.data && sodium_memcmp(value->digest, expected.data,
                                     crypto_auth_hmacsha256_BYTES) == 0};
}
static void foo_crypto_discard(void *handle) {
  FOOAuthenticator *value = handle;
  sodium_memzero(value, sizeof(*value));
  free(value);
}
static FOOResult foo_crypto_derive(FOOText secret, FOOText salt,
                                    FOOText context, uint64_t size) {
  if (size > 255 * crypto_auth_hmacsha256_BYTES)
    return foo_error("InvalidLength");
  if (!size) return (FOOResult){0};
  uint8_t zero[crypto_auth_hmacsha256_BYTES] = {0};
  uint8_t prk[crypto_auth_hmacsha256_BYTES];
  uint8_t previous[crypto_auth_hmacsha256_BYTES] = {0};
  crypto_auth_hmacsha256_state state;
  if (crypto_auth_hmacsha256_init(&state,
        salt.len ? salt.data : zero,
        salt.len ? salt.len : sizeof(zero)))
    return foo_error("InvalidLength");
  crypto_auth_hmacsha256_update(&state,
      secret.data ? secret.data : zero, secret.len);
  crypto_auth_hmacsha256_final(&state, prk);
  uint8_t *output = foo_sequence_owned(1, (size_t)size, (size_t)size);
  if (!output) {
    sodium_memzero(prk, sizeof(prk));
    return foo_error("OutOfMemory");
  }
  size_t used = 0;
  uint8_t counter = 1;
  while (used < (size_t)size) {
    crypto_auth_hmacsha256_init(&state, prk, sizeof(prk));
    if (used) crypto_auth_hmacsha256_update(&state, previous, sizeof(previous));
    crypto_auth_hmacsha256_update(&state,
        context.data ? context.data : zero, context.len);
    crypto_auth_hmacsha256_update(&state, &counter, 1);
    crypto_auth_hmacsha256_final(&state, previous);
    size_t count = (size_t)size - used;
    if (count > sizeof(previous)) count = sizeof(previous);
    memcpy(output + used, previous, count);
    used += count;
    counter++;
  }
  sodium_memzero(&state, sizeof(state));
  sodium_memzero(prk, sizeof(prk));
  sodium_memzero(previous, sizeof(previous));
  return (FOOResult){.text = {output, (size_t)size}};
}
static bool foo_crypto_compare(FOOText left, FOOText right) {
  if (left.len != right.len) return false;
  return !left.len || sodium_memcmp(left.data, right.data, left.len) == 0;
}
static FOOResult foo_crypto_random(uint32_t size) {
  foo_crypto_init();
  uint8_t *data = foo_owned(size);
  if (!data)
    return foo_error("OutOfMemory");
  randombytes_buf(data, size);
  return (FOOResult){.text = {data, size}};
}
static FOOResult foo_crypto_reproduce(FOOText seed, FOOText label,
                                       uint32_t size) {
  if (seed.len != BLAKE3_KEY_LEN || size > 1048576)
    return foo_error("InvalidLength");
  uint8_t *bytes = foo_sequence_owned(1, size, size);
  if (!bytes) return foo_error("OutOfMemory");
  blake3_hasher state;
  blake3_hasher_init_keyed(&state, seed.data);
  static const char domain[] = "FOO deterministic test stream v1";
  blake3_hasher_update(&state, domain, sizeof(domain));
  blake3_hasher_update(&state, label.data, label.len);
  blake3_hasher_finalize(&state, bytes, size);
  sodium_memzero(&state, sizeof(state));
  return (FOOResult){.text = {bytes, size}};
}
static bool foo_crypto_aead_valid(FOOText algorithm, FOOText secret,
                                   FOOText nonce, bool *aes) {
  *aes = foo_equal(algorithm, "aes256gcm");
  if (!*aes && !foo_equal(algorithm, "xchacha20poly1305")) return false;
  return secret.len == 32 && nonce.len == (*aes ? 12 : 24);
}
static bool foo_crypto_available(FOOText algorithm) {
  if (foo_equal(algorithm, "xchacha20poly1305")) return true;
  return foo_equal(algorithm, "aes256gcm") &&
      crypto_aead_aes256gcm_is_available();
}
static FOOResult foo_crypto_wrap(FOOText algorithm, FOOText value,
    FOOText secret, FOOText nonce, FOOText extra) {
  bool aes;
  if (!foo_crypto_aead_valid(algorithm, secret, nonce, &aes))
    return foo_error("InvalidAlgorithmOrLength");
  if (aes && !crypto_aead_aes256gcm_is_available())
    return foo_error("AlgorithmUnavailable");
  if (value.len > SIZE_MAX - 16) return foo_error("InvalidLength");
  uint8_t *bytes = foo_sequence_owned(1, value.len + 16, value.len + 16);
  if (!bytes) return foo_error("OutOfMemory");
  unsigned long long written = 0;
  int status = aes ? crypto_aead_aes256gcm_encrypt(bytes, &written,
      value.data, value.len, extra.data, extra.len, NULL, nonce.data,
      secret.data) : crypto_aead_xchacha20poly1305_ietf_encrypt(bytes,
      &written, value.data, value.len, extra.data, extra.len, NULL,
      nonce.data, secret.data);
  if (status || written != value.len + 16) {
    sodium_memzero(bytes, value.len + 16);
    (void)foo_sequence_free(bytes, value.len + 16, 1);
    return foo_error("EncryptionFailed");
  }
  return (FOOResult){.text = {bytes, (size_t)written}};
}
static FOOResult foo_crypto_unwrap(FOOText algorithm, FOOText value,
    FOOText secret, FOOText nonce, FOOText extra) {
  bool aes;
  if (!foo_crypto_aead_valid(algorithm, secret, nonce, &aes) || value.len < 16)
    return foo_error("InvalidAlgorithmOrLength");
  if (aes && !crypto_aead_aes256gcm_is_available())
    return foo_error("AlgorithmUnavailable");
  uint8_t *plain = malloc(value.len ? value.len : 1);
  if (!plain) return foo_error("OutOfMemory");
  unsigned long long written = 0;
  int status = aes ? crypto_aead_aes256gcm_decrypt(plain, &written, NULL,
      value.data, value.len, extra.data, extra.len, nonce.data, secret.data)
      : crypto_aead_xchacha20poly1305_ietf_decrypt(plain, &written, NULL,
      value.data, value.len, extra.data, extra.len, nonce.data, secret.data);
  if (status) {
    sodium_memzero(plain, value.len);
    free(plain);
    return foo_error("AuthenticationFailed");
  }
  uint8_t *bytes = foo_sequence_owned(1, (size_t)written, (size_t)written);
  if (bytes) memcpy(bytes, plain, (size_t)written);
  sodium_memzero(plain, value.len);
  free(plain);
  if (!bytes) return foo_error("OutOfMemory");
  return (FOOResult){.text = {bytes, (size_t)written}};
}
typedef struct { uint8_t bytes[32]; } FOOSecureKey;
static FOOResult foo_crypto_protect(FOOText secret) {
  if (secret.len != 32) return foo_error("InvalidLength");
  foo_crypto_init();
  FOOSecureKey *key = sodium_malloc(sizeof(*key));
  if (!key) return foo_error("OutOfMemory");
  if (sodium_mlock(key, sizeof(*key))) {
    sodium_free(key);
    return foo_error("SecureMemoryUnavailable");
  }
  memcpy(key->bytes, secret.data, 32);
  return (FOOResult){.pointer = key};
}
static FOOResult foo_crypto_shield(FOOText algorithm, FOOText value,
    void *handle, FOOText nonce, FOOText extra) {
  FOOSecureKey *key = handle;
  return foo_crypto_wrap(algorithm, value,
      (FOOText){key->bytes, 32}, nonce, extra);
}
static FOOResult foo_crypto_reveal(FOOText algorithm, FOOText value,
    void *handle, FOOText nonce, FOOText extra) {
  FOOSecureKey *key = handle;
  return foo_crypto_unwrap(algorithm, value,
      (FOOText){key->bytes, 32}, nonce, extra);
}
static void foo_crypto_forget(void *handle) {
  FOOSecureKey *key = handle;
  sodium_memzero(key, sizeof(*key));
  sodium_free(key);
}
static FOOResult foo_crypto_seal(FOOText value, FOOText secret, FOOText nonce,
                                 FOOText extra) {
  if (secret.len != 32 || nonce.len != 24)
    return foo_error("InvalidLength");
  if (value.len > SIZE_MAX - 16)
    return foo_error("OutOfMemory");
  uint8_t *data = foo_owned(value.len + 16);
  if (!data)
    return foo_error("OutOfMemory");
  unsigned long long length;
  crypto_aead_xchacha20poly1305_ietf_encrypt(data, &length, value.data,
                                             value.len, extra.data, extra.len,
                                             NULL, nonce.data, secret.data);
  return (FOOResult){.text = {data, (size_t)length}};
}
static FOOResult foo_crypto_open(FOOText value, FOOText secret, FOOText nonce,
                                 FOOText extra) {
  if (secret.len != 32 || nonce.len != 24 || value.len < 16)
    return foo_error("InvalidLength");
  uint8_t *data = malloc(value.len);
  if (!data)
    return foo_error("OutOfMemory");
  unsigned long long length;
  if (crypto_aead_xchacha20poly1305_ietf_decrypt(
          data, &length, NULL, value.data, value.len, extra.data, extra.len,
          nonce.data, secret.data)) {
    sodium_memzero(data, value.len);
    free(data);
    return foo_error("AuthenticationFailed");
  }
  FOOResult result = foo_copy(data, (size_t)length);
  sodium_memzero(data, value.len);
  free(data);
  return result;
}
static FOOResult foo_crypto_key(FOOText seed) {
  if (seed.len != 32)
    return foo_error("InvalidLength");
  uint8_t public[32], secret[64];
  crypto_sign_seed_keypair(public, secret, seed.data);
  sodium_memzero(secret, sizeof(secret));
  return foo_copy(public, sizeof(public));
}
static FOOResult foo_crypto_sign(FOOText value, FOOText seed) {
  if (seed.len != 32)
    return foo_error("InvalidLength");
  uint8_t public[32], secret[64], signature[64];
  crypto_sign_seed_keypair(public, secret, seed.data);
  crypto_sign_detached(signature, NULL, value.data, value.len, secret);
  sodium_memzero(secret, sizeof(secret));
  return foo_copy(signature, sizeof(signature));
}
static bool foo_crypto_verify(FOOText value, FOOText signature,
                              FOOText signer) {
  return signature.len == 64 && signer.len == 32 &&
         crypto_sign_verify_detached(signature.data, value.data, value.len,
                                     signer.data) == 0;
}
static FOOResult foo_crypto_password(FOOText value) {
  foo_crypto_init();
  char encoded[crypto_pwhash_STRBYTES];
  if (crypto_pwhash_str_alg(encoded, (const char *)value.data, value.len, 3,
                            65536 * 1024, crypto_pwhash_ALG_ARGON2ID13))
    return foo_error("OutOfMemory");
  return foo_copy(encoded, strlen(encoded));
}
static FOOResult foo_crypto_confirm(FOOText value, FOOText encoded) {
  const char *prefix = "$argon2id$v=19$m=65536,t=3,p=1$";
  if (encoded.len >= crypto_pwhash_STRBYTES || encoded.len < strlen(prefix) ||
      memcmp(encoded.data, prefix, strlen(prefix)) ||
      memchr(encoded.data, 0, encoded.len))
    return foo_error("InvalidEncoding");
  char copy[crypto_pwhash_STRBYTES];
  foo_transfer(copy, encoded.data, encoded.len);
  copy[encoded.len] = 0;
  return (FOOResult){
      .boolean = crypto_pwhash_str_verify(copy, (const char *)value.data,
                                          value.len) == 0};
}
#endif

#ifdef FOO_COMPRESS
#include <zlib.h>
static FOOResult foo_compress_header(uint64_t size) {
  if (!size || size > UINT32_MAX)
    return foo_error("StreamTooLong");
  uint8_t bytes[4] = {(uint8_t)size, (uint8_t)(size >> 8),
                      (uint8_t)(size >> 16), (uint8_t)(size >> 24)};
  return foo_copy(bytes, sizeof(bytes));
}
static FOOResult foo_compress_extent(FOOText header) {
  if (header.len != 4 || !header.data)
    return foo_error("InvalidCompressedData");
  uint32_t size = (uint32_t)header.data[0] |
                  ((uint32_t)header.data[1] << 8) |
                  ((uint32_t)header.data[2] << 16) |
                  ((uint32_t)header.data[3] << 24);
  return size ? (FOOResult){.number = size} : foo_error("InvalidCompressedData");
}
static int foo_format(FOOText value) {
  return foo_equal(value, "gzip") ? 31 : foo_equal(value, "zlib") ? 15 : 0;
}
static FOOResult foo_compress_pack(FOOText value, FOOText format) {
  int window = foo_format(format);
  if (!window)
    return foo_error("InvalidFormat");
  if (value.len > UINT_MAX)
    return foo_error("StreamTooLong");
  z_stream stream = {0};
  if (deflateInit2(&stream, Z_DEFAULT_COMPRESSION, Z_DEFLATED, window, 8,
                   Z_DEFAULT_STRATEGY) != Z_OK)
    return foo_error("OutOfMemory");
  uLong bound = deflateBound(&stream, (uLong)value.len);
  if (bound > UINT_MAX) {
    deflateEnd(&stream);
    return foo_error("StreamTooLong");
  }
  uint8_t *data = malloc(bound);
  if (!data) {
    deflateEnd(&stream);
    return foo_error("OutOfMemory");
  }
  stream.next_in = (Bytef *)value.data;
  stream.avail_in = (uInt)value.len;
  stream.next_out = data;
  stream.avail_out = (uInt)bound;
  int status = deflate(&stream, Z_FINISH);
  size_t length = stream.total_out;
  deflateEnd(&stream);
  FOOResult result = status == Z_STREAM_END ? foo_copy(data, length)
                                            : foo_error("CompressionFailed");
  free(data);
  return result;
}
static FOOResult foo_compress_unpack(FOOText value, FOOText format,
                                     uint32_t limit) {
  int window = foo_format(format);
  if (!window)
    return foo_error("InvalidFormat");
  if (value.len > UINT_MAX || limit == UINT_MAX)
    return foo_error("StreamTooLong");
  z_stream stream = {0};
  if (inflateInit2(&stream, window) != Z_OK)
    return foo_error("OutOfMemory");
  uint8_t *data = malloc((size_t)limit + 1);
  if (!data) {
    inflateEnd(&stream);
    return foo_error("OutOfMemory");
  }
  stream.next_in = (Bytef *)value.data;
  stream.avail_in = (uInt)value.len;
  stream.next_out = data;
  stream.avail_out = limit + 1;
  int status = inflate(&stream, Z_FINISH);
  size_t length = stream.total_out;
  FOOResult result = length > limit ? foo_error("WriteFailed")
                     : status != Z_STREAM_END || stream.avail_in
                         ? foo_error("InvalidCompressedData")
                         : foo_copy(data, length);
  inflateEnd(&stream);
  free(data);
  return result;
}
#endif

#ifdef FOO_JSON
#include "json.h"
#endif
#if defined(FOO_MEMORY) || defined(FOO_LIST) || defined(FOO_STREAM)
#include "storage.h"
#endif
#ifdef FOO_STREAM
#include "stream.h"
#endif
#ifdef FOO_HTTP
#include "http.h"
#endif
