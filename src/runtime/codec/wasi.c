static FooResult copied(const uint8_t *data, size_t size) {
  if (!size) return (FooResult){0};
  uint8_t *copy = owned(size, TEXT);
  if (!copy) return failure(MEMORY);
  memcpy(copy, data, size);
  return (FooResult){.text = {copy, size}};
}

FooResult foo_text_release(FooText value) {
  if (!value.len) return (FooResult){0};
  pthread_mutex_lock(&registry);
  Entry *item = entries;
  while (item && (item->data != value.data || item->kind != TEXT || item->closed))
    item = item->next;
  if (!item || item->size != value.len) {
    pthread_mutex_unlock(&registry);
    return failure(ARGUMENT);
  }
  item->closed = 1;
  item->data = NULL;
  pthread_mutex_unlock(&registry);
  free((void *)value.data);
  return (FooResult){0};
}

FooResult foo_text_concatenate(FooText left, FooText right) {
  if (left.len > SIZE_MAX || right.len > SIZE_MAX - left.len)
    return failure(BOUNDS);
  if ((left.len && !left.data) || (right.len && !right.data))
    return failure(ARGUMENT);
  size_t size = (size_t)(left.len + right.len);
  if (!size) return (FooResult){0};
  uint8_t *copy = owned(size, TEXT);
  if (!copy) return failure(MEMORY);
  if (left.len) memcpy(copy, left.data, (size_t)left.len);
  if (right.len) memcpy(copy + left.len, right.data, (size_t)right.len);
  return (FooResult){.text = {copy, size}};
}

FooResult foo_text_slice(FooText value, uint64_t first, uint64_t last) {
  if (first > last || last > value.len || last > SIZE_MAX) return failure(BOUNDS);
  if (last > first && !value.data) return failure(ARGUMENT);
  return copied(value.data ? value.data + first : NULL, (size_t)(last - first));
}

FooResult foo_text_find(FooText value, FooText needle) {
  if (!needle.len) return (FooResult){.pointer = (void *)1};
  if (!value.data || !needle.data || needle.len > value.len) return (FooResult){0};
  for (uint64_t index = 0; index <= value.len - needle.len; index++)
    if (!memcmp(value.data + index, needle.data, (size_t)needle.len))
      return (FooResult){.pointer = (void *)1, .number = index};
  return (FooResult){0};
}
