typedef struct FOOBlock {
  uint8_t *data;
  size_t size;
  struct FOOBlock *next;
} FOOBlock;
typedef struct FOOAllocator {
  FOOBlock *blocks;
  bool alive;
  struct FOOAllocator *next;
} FOOAllocator;
typedef struct FOOList {
  uint8_t **items;
  size_t length, capacity;
  bool alive;
  struct FOOList *next;
} FOOList;
static FOOAllocator foo_system = {NULL, true, NULL};
static FOOAllocator *foo_arenas;
static FOOList *foo_lists;
static const char *foo_owner(FOOAllocator *value) {
  if (value == &foo_system)
    return NULL;
  for (FOOAllocator *entry = foo_arenas; entry; entry = entry->next)
    if (entry == value)
      return entry->alive ? NULL : "ClosedAllocator";
  return "UnknownAllocator";
}
static FOOBlock *foo_block(FOOAllocator *value, uint8_t *pointer) {
  for (FOOBlock *entry = value->blocks; entry; entry = entry->next)
    if (entry->data == pointer)
      return entry;
  return NULL;
}
static void foo_clear(FOOAllocator *value) {
  while (value->blocks) {
    FOOBlock *entry = value->blocks;
    value->blocks = entry->next;
    free(entry->data);
    free(entry);
  }
}
static void *foo_memory_system(void) { return &foo_system; }
static FOOResult foo_memory_arena(void) {
  FOOAllocator *value = calloc(1, sizeof(*value));
  if (!value)
    return foo_error("OutOfMemory");
  value->alive = true;
  value->next = foo_arenas;
  foo_arenas = value;
  return (FOOResult){.pointer = value};
}
static FOOResult foo_memory_allocate(void *handle, uint64_t size) {
  FOOAllocator *value = handle;
  const char *error = foo_owner(value);
  if (error)
    return foo_error(error);
  if (size > PTRDIFF_MAX)
    return foo_error("InvalidSize");
  FOOBlock *entry = malloc(sizeof(*entry));
  if (!entry)
    return foo_error("OutOfMemory");
  uint8_t *data = calloc(size ? (size_t)size : 1, 1);
  if (!data) {
    free(entry);
    return foo_error("OutOfMemory");
  }
  *entry = (FOOBlock){data, (size_t)size, value->blocks};
  value->blocks = entry;
  return (FOOResult){.pointer = data};
}
static FOOResult foo_memory_release(void *handle, uint8_t *pointer) {
  FOOAllocator *value = handle;
  const char *error = foo_owner(value);
  if (error)
    return foo_error(error);
  FOOBlock **cursor = &value->blocks;
  while (*cursor && (*cursor)->data != pointer)
    cursor = &(*cursor)->next;
  if (!*cursor)
    return foo_error("UnknownBuffer");
  FOOBlock *entry = *cursor;
  *cursor = entry->next;
  free(entry->data);
  free(entry);
  return (FOOResult){0};
}
static FOOResult foo_memory_expand(void *handle, uint8_t *pointer,
                                   uint64_t size) {
  FOOAllocator *value = handle;
  const char *error = foo_owner(value);
  if (error)
    return foo_error(error);
  FOOBlock *entry = foo_block(value, pointer);
  if (!entry)
    return foo_error("UnknownBuffer");
  if (size > PTRDIFF_MAX)
    return foo_error("InvalidSize");
  /* Failure leaves the old pointer, contents and ownership intact. */
  uint8_t *data = calloc(size ? (size_t)size : 1, 1);
  if (!data)
    return foo_error("OutOfMemory");
  size_t kept = size < entry->size ? (size_t)size : entry->size;
  if (kept)
    memcpy(data, pointer, kept);
  free(entry->data);
  entry->data = data;
  entry->size = (size_t)size;
  return (FOOResult){.pointer = data};
}
static FOOResult foo_memory_view(void *handle, uint8_t *pointer,
                                 uint64_t size) {
  FOOAllocator *value = handle;
  const char *error = foo_owner(value);
  if (error)
    return foo_error(error);
  FOOBlock *entry = foo_block(value, pointer);
  if (!entry)
    return foo_error("UnknownBuffer");
  if (size > entry->size)
    return foo_error("Bounds");
  return (FOOResult){.text = {pointer, (size_t)size}};
}
static FOOResult foo_memory_transfer(FOOText source, FOOText destination) {
  if (source.len > destination.len) return foo_error("Bounds");
  if (source.len) foo_transfer((void*)destination.data, source.data, source.len);
  return (FOOResult){0};
}
static void foo_memory_clear(FOOText buffer) { if (buffer.len) memset((void*)buffer.data, 0, buffer.len); }
static int64_t foo_memory_compare(FOOText left, FOOText right) {
  size_t size = left.len < right.len ? left.len : right.len;
  int order = size ? memcmp(left.data, right.data, size) : 0;
  return order ? (order > 0 ? 1 : -1) : (left.len > right.len) - (left.len < right.len);
}
static FOOResult foo_memory_copy(void *handle, uint8_t *pointer,
                                 FOOText content) {
  FOOResult result = foo_memory_view(handle, pointer, content.len);
  if (result.error)
    return result;
  if (content.len)
    foo_transfer(pointer, content.data, content.len);
  return (FOOResult){0};
}
static FOOResult foo_memory_close(void *handle) {
  FOOAllocator *value = handle;
  const char *error = foo_owner(value);
  if (error)
    return foo_error(error);
  if (value == &foo_system)
    return foo_error("SystemAllocator");
  foo_clear(value);
  value->alive = false;
  return (FOOResult){0};
}
static const char *foo_collection(FOOList *value) {
  for (FOOList *entry = foo_lists; entry; entry = entry->next)
    if (entry == value)
      return entry->alive ? NULL : "ClosedList";
  return "UnknownList";
}
static FOOResult foo_list_create(void) {
  FOOList *value = calloc(1, sizeof(*value));
  if (!value)
    return foo_error("OutOfMemory");
  value->alive = true;
  value->next = foo_lists;
  foo_lists = value;
  return (FOOResult){.pointer = value};
}
static FOOResult foo_list_push(void *handle, uint8_t *item) {
  FOOList *value = handle;
  const char *error = foo_collection(value);
  if (error)
    return foo_error(error);
  if (value->length == value->capacity) {
    size_t capacity = value->capacity ? value->capacity * 2 : 8;
    if (capacity < value->capacity ||
        capacity > SIZE_MAX / sizeof(*value->items))
      return foo_error("OutOfMemory");
    uint8_t **items = realloc(value->items, capacity * sizeof(*items));
    if (!items)
      return foo_error("OutOfMemory");
    value->items = items;
    value->capacity = capacity;
  }
  value->items[value->length++] = item;
  return (FOOResult){0};
}
static FOOResult foo_list_get(void *handle, uint64_t index) {
  FOOList *value = handle;
  const char *error = foo_collection(value);
  if (error)
    return foo_error(error);
  if (index >= value->length)
    return foo_error("Bounds");
  return (FOOResult){.pointer = value->items[index]};
}
static FOOResult foo_list_length(void *handle) {
  FOOList *value = handle;
  const char *error = foo_collection(value);
  return error ? foo_error(error) : (FOOResult){.number = value->length};
}
static FOOResult foo_list_close(void *handle) {
  FOOList *value = handle;
  const char *error = foo_collection(value);
  if (error)
    return foo_error(error);
  free(value->items);
  value->items = NULL;
  value->alive = false;
  return (FOOResult){0};
}
static FOOResult foo_bytes(uint8_t *pointer, uint64_t size) {
  for (FOOAllocator *value = &foo_system; value;
       value = value == &foo_system ? foo_arenas : value->next) {
    if (!value->alive)
      continue;
    FOOBlock *entry = foo_block(value, pointer);
    if (entry)
      return size > entry->size ? foo_error("Bounds")
                                : (FOOResult){.text = {pointer, (size_t)size}};
  }
  return foo_error("UnknownBuffer");
}
static void foo_storage_shutdown(void) {
  foo_clear(&foo_system);
  while (foo_arenas) {
    FOOAllocator *entry = foo_arenas;
    foo_arenas = entry->next;
    foo_clear(entry);
    free(entry);
  }
  /* Keep closed handles until shutdown so their addresses cannot be reused. */
  while (foo_lists) {
    FOOList *entry = foo_lists;
    foo_lists = entry->next;
    free(entry->items);
    free(entry);
  }
}
