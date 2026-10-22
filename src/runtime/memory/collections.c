typedef struct {
  size_t capacity, head, tail, count;
  uint8_t *bytes;
} Ring;
FooResult foo_ring_create(uint64_t capacity) {
  if (!capacity || capacity > SIZE_MAX) return failure(ARGUMENT);
  uint8_t *bytes = malloc((size_t)capacity);
  if (!bytes) return failure(MEMORY);
  Ring *ring = owned(sizeof(*ring), RINGS);
  if (!ring) { free(bytes); return failure(MEMORY); }
  ring->capacity = (size_t)capacity;
  ring->bytes = bytes;
  return (FooResult){.pointer = ring};
}
FooResult foo_ring_push(void *pointer, uint8_t item) {
  Resource *entry = resource(pointer, RINGS);
  if (!entry) return failure(CLOSED);
  enter();
  if (entry->closed) { leave(); return failure(CLOSED); }
  Ring *ring = pointer;
  if (ring->count == ring->capacity) { leave(); return (FooResult){0}; }
  ring->bytes[ring->tail] = item;
  if (++ring->tail == ring->capacity) ring->tail = 0;
  ring->count++;
  leave();
  return (FooResult){.number = 1};
}
FooResult foo_ring_prepend(void *pointer, uint8_t item) {
  Resource *entry = resource(pointer, RINGS);
  if (!entry) return failure(CLOSED);
  enter();
  if (entry->closed) { leave(); return failure(CLOSED); }
  Ring *ring = pointer;
  if (ring->count == ring->capacity) { leave(); return (FooResult){0}; }
  ring->head = ring->head ? ring->head - 1 : ring->capacity - 1;
  ring->bytes[ring->head] = item;
  ring->count++;
  leave();
  return (FooResult){.number = 1};
}
FooResult foo_ring_pop(void *pointer) {
  Resource *entry = resource(pointer, RINGS);
  if (!entry) return failure(CLOSED);
  enter();
  if (entry->closed) { leave(); return failure(CLOSED); }
  Ring *ring = pointer;
  if (!ring->count) { leave(); return failure(MISSING); }
  uint8_t value = ring->bytes[ring->head];
  if (++ring->head == ring->capacity) ring->head = 0;
  ring->count--;
  leave();
  return (FooResult){.number = value};
}
FooResult foo_ring_remove(void *pointer) {
  Resource *entry = resource(pointer, RINGS);
  if (!entry) return failure(CLOSED);
  enter();
  if (entry->closed) { leave(); return failure(CLOSED); }
  Ring *ring = pointer;
  if (!ring->count) { leave(); return failure(MISSING); }
  ring->tail = ring->tail ? ring->tail - 1 : ring->capacity - 1;
  uint8_t value = ring->bytes[ring->tail];
  ring->count--;
  leave();
  return (FooResult){.number = value};
}
FooResult foo_ring_first(void *pointer) {
  Resource *entry = resource(pointer, RINGS);
  if (!entry) return failure(CLOSED);
  enter();
  if (entry->closed) { leave(); return failure(CLOSED); }
  Ring *ring = pointer;
  if (!ring->count) { leave(); return failure(MISSING); }
  uint8_t value = ring->bytes[ring->head];
  leave();
  return (FooResult){.number = value};
}
FooResult foo_ring_last(void *pointer) {
  Resource *entry = resource(pointer, RINGS);
  if (!entry) return failure(CLOSED);
  enter();
  if (entry->closed) { leave(); return failure(CLOSED); }
  Ring *ring = pointer;
  if (!ring->count) { leave(); return failure(MISSING); }
  size_t index = ring->tail ? ring->tail - 1 : ring->capacity - 1;
  uint8_t value = ring->bytes[index];
  leave();
  return (FooResult){.number = value};
}
FooResult foo_ring_length(void *pointer) {
  Resource *entry = resource(pointer, RINGS);
  if (!entry) return failure(CLOSED);
  enter();
  if (entry->closed) { leave(); return failure(CLOSED); }
  uint64_t count = ((Ring *)pointer)->count;
  leave();
  return (FooResult){.number = count};
}
FooResult foo_ring_capacity(void *pointer) {
  Resource *entry = resource(pointer, RINGS);
  if (!entry) return failure(CLOSED);
  enter();
  if (entry->closed) { leave(); return failure(CLOSED); }
  uint64_t capacity = ((Ring *)pointer)->capacity;
  leave();
  return (FooResult){.number = capacity};
}
FooResult foo_ring_close(void *pointer) {
  Resource *entry = resource(pointer, RINGS);
  if (!entry) return failure(CLOSED);
  enter();
  if (entry->closed) { leave(); return failure(CLOSED); }
  Ring *ring = pointer;
  free(ring->bytes);
  ring->bytes = NULL;
  entry->closed = 1;
  leave();
  return (FooResult){0};
}
typedef struct {
  uint64_t bits, rounds;
  uint8_t *bytes;
} Bloom;
FooResult foo_bloom_create(uint64_t bits, uint64_t rounds) {
  if (!bits || !rounds || rounds > 16) return failure(ARGUMENT);
  uint64_t size = bits / 8 + (bits % 8 != 0);
  if (size > SIZE_MAX) return failure(ARGUMENT);
  uint8_t *bytes = calloc((size_t)size, 1);
  if (!bytes) return failure(MEMORY);
  Bloom *filter = owned(sizeof(*filter), BLOOMS);
  if (!filter) { free(bytes); return failure(MEMORY); }
  filter->bits = bits;
  filter->rounds = rounds;
  filter->bytes = bytes;
  return (FooResult){.pointer = filter};
}
static void bloom(FooText key, uint64_t *first, uint64_t *step) {
  uint64_t a = UINT64_C(14695981039346656037);
  uint64_t b = UINT64_C(7809847782465536322);
  for (size_t index = 0; index < key.len; index++) {
    a = (a ^ key.data[index]) * UINT64_C(1099511628211);
    b = (b ^ key.data[index]) * UINT64_C(14029467366897019727);
  }
  *first = a;
  *step = b | 1;
}
FooResult foo_bloom_add(void *pointer, FooText key) {
  if (key.len && !key.data) return failure(ARGUMENT);
  Resource *entry = resource(pointer, BLOOMS);
  if (!entry) return failure(CLOSED);
  uint64_t first, step;
  bloom(key, &first, &step);
  enter();
  if (entry->closed) { leave(); return failure(CLOSED); }
  Bloom *filter = pointer;
  for (uint64_t round = 0; round < filter->rounds; round++) {
    uint64_t bit = (first + round * step) % filter->bits;
    filter->bytes[bit / 8] |= (uint8_t)(1u << (bit % 8));
  }
  leave();
  return (FooResult){0};
}
FooResult foo_bloom_contains(void *pointer, FooText key) {
  if (key.len && !key.data) return failure(ARGUMENT);
  Resource *entry = resource(pointer, BLOOMS);
  if (!entry) return failure(CLOSED);
  uint64_t first, step;
  bloom(key, &first, &step);
  enter();
  if (entry->closed) { leave(); return failure(CLOSED); }
  Bloom *filter = pointer;
  for (uint64_t round = 0; round < filter->rounds; round++) {
    uint64_t bit = (first + round * step) % filter->bits;
    if (!(filter->bytes[bit / 8] & (uint8_t)(1u << (bit % 8)))) {
      leave();
      return (FooResult){0};
    }
  }
  leave();
  return (FooResult){.number = 1};
}
FooResult foo_bloom_bits(void *pointer) {
  Resource *entry = resource(pointer, BLOOMS);
  if (!entry) return failure(CLOSED);
  enter();
  if (entry->closed) { leave(); return failure(CLOSED); }
  uint64_t bits = ((Bloom *)pointer)->bits;
  leave();
  return (FooResult){.number = bits};
}
FooResult foo_bloom_rounds(void *pointer) {
  Resource *entry = resource(pointer, BLOOMS);
  if (!entry) return failure(CLOSED);
  enter();
  if (entry->closed) { leave(); return failure(CLOSED); }
  uint64_t rounds = ((Bloom *)pointer)->rounds;
  leave();
  return (FooResult){.number = rounds};
}
FooResult foo_bloom_close(void *pointer) {
  Resource *entry = resource(pointer, BLOOMS);
  if (!entry) return failure(CLOSED);
  enter();
  if (entry->closed) { leave(); return failure(CLOSED); }
  Bloom *filter = pointer;
  free(filter->bytes);
  filter->bytes = NULL;
  entry->closed = 1;
  leave();
  return (FooResult){0};
}
