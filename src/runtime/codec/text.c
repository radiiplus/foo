FooResult foo_text_release(FooText value) {
  if (!value.len)
    return (FooResult){0};
  enter();
  Resource *entry = bins[bucket((void *)value.data)];
  while (entry && (entry->data != value.data || entry->kind != TEXT))
    entry = entry->chain;
  if (!entry || entry->size != value.len) {
    leave();
    return failure(ARGUMENT);
  }
  if (entry->prev)
    entry->prev->next = entry->next;
  else
    resources = entry->next;
  if (entry->next)
    entry->next->prev = entry->prev;
  forget(entry);
  leave();
  free(entry->data);
  free(entry);
  return (FooResult){0};
}
FooResult foo_text_concatenate(FooText left, FooText right) {
  if (right.len > SIZE_MAX - left.len)
    return failure(BOUNDS);
  size_t size = left.len + right.len;
  if (!size)
    return (FooResult){0};
  uint8_t *data = owned(size, TEXT);
  if (!data)
    return failure(MEMORY);
  if (left.len)
    memcpy(data, left.data, left.len);
  if (right.len)
    memcpy(data + left.len, right.data, right.len);
  return (FooResult){.text = {data, size}};
}
FooResult foo_text_slice(FooText value, uint64_t first, uint64_t last) {
  if (first > last || last > value.len)
    return failure(BOUNDS);
  return text(value.data ? value.data + first : NULL, (size_t)(last - first));
}
FooResult foo_text_find(FooText value, FooText needle) {
  if (!needle.len)
    return (FooResult){.pointer = (void *)1};
  if (!value.data || !needle.data || needle.len > value.len)
    return (FooResult){0};
  if (needle.len == 1) {
    const uint8_t *found = memchr(value.data, needle.data[0], value.len);
    return found ? (FooResult){.pointer = (void *)1,
                               .number = (uint64_t)(found - value.data)}
                 : (FooResult){0};
  }
  if (value.len < 64 || needle.len < 4) {
    for (size_t index = 0; index <= value.len - needle.len; index++)
      if (!memcmp(value.data + index, needle.data, needle.len))
        return (FooResult){.pointer = (void *)1, .number = index};
    return (FooResult){0};
  }
  size_t skip[256];
  for (size_t index = 0; index < 256; index++)
    skip[index] = needle.len;
  for (size_t index = 0; index + 1 < needle.len; index++)
    skip[needle.data[index]] = needle.len - index - 1;
  size_t index = 0;
  while (index <= value.len - needle.len) {
    if (needle.data[needle.len - 1] == value.data[index + needle.len - 1] &&
        !memcmp(value.data + index, needle.data, needle.len - 1))
      return (FooResult){.pointer = (void *)1, .number = index};
    index += skip[value.data[index + needle.len - 1]];
  }
  return (FooResult){0};
}
