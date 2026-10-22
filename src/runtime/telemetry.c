typedef struct {
  char *name;
  size_t length, size;
  uint64_t *bounds, *buckets;
  uint64_t value, count, sum;
  int kind;
} Meter;
FooResult foo_metric_create(FooText name, FooText kind, FooText bounds) {
  int type = supports(kind, "counter") ? 1 : supports(kind, "gauge") ? 2 :
             supports(kind, "histogram") ? 3 : 0;
  if (!type || !name.data || !name.len || name.len > 255 ||
      (bounds.len && !bounds.data) || bounds.len > 64 ||
      (type != 3 && bounds.len)) return failure(ARGUMENT);
  for (size_t index = 1; index < bounds.len; index++) {
    uint64_t current, previous;
    memcpy(&current, bounds.data + index * sizeof(current), sizeof(current));
    memcpy(&previous, bounds.data + (index - 1) * sizeof(previous),
           sizeof(previous));
    if (current <= previous) return failure(ARGUMENT);
  }
  char *label = malloc(name.len + 1);
  uint64_t *values = type == 3 ? calloc(bounds.len + 1, sizeof(*values)) : NULL;
  uint64_t *edges = type == 3 && bounds.len
      ? malloc(bounds.len * sizeof(*edges)) : NULL;
  if (!label || (type == 3 && !values) || (type == 3 && bounds.len && !edges)) {
    free(label); free(values); free(edges);
    return failure(MEMORY);
  }
  memcpy(label, name.data, name.len);
  label[name.len] = 0;
  if (edges) memcpy(edges, bounds.data, bounds.len * sizeof(*edges));
  Meter *meter = owned(sizeof(*meter), METERS);
  if (!meter) { free(label); free(values); free(edges); return failure(MEMORY); }
  meter->name = label;
  meter->length = name.len;
  meter->kind = type;
  meter->size = bounds.len;
  meter->bounds = edges;
  meter->buckets = values;
  return (FooResult){.pointer = meter};
}
static FooResult update(void *pointer, uint64_t amount, int action) {
  Resource *entry = resource(pointer, METERS);
  if (!entry) return failure(CLOSED);
  enter();
  if (entry->closed) { leave(); return failure(CLOSED); }
  Meter *meter = pointer;
  if ((action == 1 && meter->kind == 3) ||
      (action == 2 && meter->kind != 2) ||
      (action == 3 && meter->kind != 3)) { leave(); return failure(ARGUMENT); }
  if (action == 1) {
    if (amount > UINT64_MAX - meter->value) { leave(); return failure(BOUNDS); }
    meter->value += amount;
  } else if (action == 2) meter->value = amount;
  else {
    if (meter->count == UINT64_MAX || amount > UINT64_MAX - meter->sum) {
      leave(); return failure(BOUNDS);
    }
    size_t index = 0;
    while (index < meter->size && amount > meter->bounds[index]) index++;
    meter->buckets[index]++;
    meter->count++;
    meter->sum += amount;
  }
  leave();
  return (FooResult){0};
}
FooResult foo_metric_add(void *pointer, uint64_t amount) {
  return update(pointer, amount, 1);
}
FooResult foo_metric_set(void *pointer, uint64_t amount) {
  return update(pointer, amount, 2);
}
FooResult foo_metric_observe(void *pointer, uint64_t amount) {
  return update(pointer, amount, 3);
}
static FooResult inspect(void *pointer, uint64_t index, int field) {
  Resource *entry = resource(pointer, METERS);
  if (!entry) return failure(CLOSED);
  enter();
  if (entry->closed) { leave(); return failure(CLOSED); }
  Meter *meter = pointer;
  if ((field == 1 && meter->kind == 3) ||
      (field != 1 && meter->kind != 3) ||
      (field == 4 && index > meter->size)) {
    leave(); return failure(field == 4 && meter->kind == 3 ? BOUNDS : ARGUMENT);
  }
  uint64_t result = field == 1 ? meter->value : field == 2 ? meter->count :
                    field == 3 ? meter->sum : meter->buckets[index];
  leave();
  return (FooResult){.number = result};
}
FooResult foo_metric_value(void *pointer) { return inspect(pointer, 0, 1); }
FooResult foo_metric_count(void *pointer) { return inspect(pointer, 0, 2); }
FooResult foo_metric_sum(void *pointer) { return inspect(pointer, 0, 3); }
FooResult foo_metric_bucket(void *pointer, uint64_t index) {
  return inspect(pointer, index, 4);
}
FooResult foo_metric_name(void *pointer) {
  Resource *entry = resource(pointer, METERS);
  if (!entry) return failure(CLOSED);
  char label[256];
  enter();
  if (entry->closed) { leave(); return failure(CLOSED); }
  Meter *meter = pointer;
  size_t length = meter->length;
  memcpy(label, meter->name, length);
  leave();
  return text(label, length);
}
static bool append(char *output, size_t *used, const char *part) {
  size_t length = strlen(part);
  if (length >= 8192 - *used) return false;
  memcpy(output + *used, part, length);
  *used += length;
  return true;
}
static bool number(char *output, size_t *used, uint64_t value) {
  int length = snprintf(output + *used, 8192 - *used, "%llu",
                        (unsigned long long)value);
  if (length < 0 || (size_t)length >= 8192 - *used) return false;
  *used += (size_t)length;
  return true;
}
FooResult foo_metric_export(void *pointer) {
  Resource *entry = resource(pointer, METERS);
  if (!entry) return failure(CLOSED);
  char output[8192];
  size_t used = 0;
  static const char hex[] = "0123456789abcdef";
  bool valid = true;
  enter();
  if (entry->closed) { leave(); return failure(CLOSED); }
  Meter *meter = pointer;
  valid = append(output, &used, "{\"name\":\"");
  for (size_t index = 0; valid && index < meter->length; index++) {
    unsigned char letter = (unsigned char)meter->name[index];
    if (letter == '"' || letter == '\\') {
      if (used > sizeof(output) - 2) { valid = false; break; }
      output[used++] = '\\';
      output[used++] = (char)letter;
    } else if (letter < 32) {
      if (used > sizeof(output) - 6) { valid = false; break; }
      output[used++] = '\\'; output[used++] = 'u';
      output[used++] = '0'; output[used++] = '0';
      output[used++] = hex[letter >> 4];
      output[used++] = hex[letter & 15];
    } else {
      if (used == sizeof(output)) { valid = false; break; }
      output[used++] = (char)letter;
    }
  }
  if (valid) valid = append(output, &used,
      meter->kind == 1 ? "\",\"kind\":\"counter\",\"value\":" :
      meter->kind == 2 ? "\",\"kind\":\"gauge\",\"value\":" :
                         "\",\"kind\":\"histogram\",\"count\":");
  if (valid) valid = number(output, &used,
      meter->kind == 3 ? meter->count : meter->value);
  if (valid && meter->kind == 3)
    valid = append(output, &used, ",\"sum\":") &&
            number(output, &used, meter->sum) &&
            append(output, &used, ",\"bounds\":[");
  for (size_t index = 0; valid && meter->kind == 3 && index < meter->size; index++)
    valid = (index == 0 || append(output, &used, ",")) &&
            number(output, &used, meter->bounds[index]);
  if (valid && meter->kind == 3)
    valid = append(output, &used, "],\"buckets\":[");
  for (size_t index = 0; valid && meter->kind == 3 && index <= meter->size; index++)
    valid = (index == 0 || append(output, &used, ",")) &&
            number(output, &used, meter->buckets[index]);
  if (valid && meter->kind == 3) valid = append(output, &used, "]");
  if (valid) valid = append(output, &used, "}");
  leave();
  return valid ? text(output, used) : failure(BOUNDS);
}
FooResult foo_metric_close(void *pointer) {
  Resource *entry = resource(pointer, METERS);
  if (!entry) return failure(CLOSED);
  enter();
  if (entry->closed) { leave(); return failure(CLOSED); }
  Meter *meter = pointer;
  free(meter->name); free(meter->bounds); free(meter->buckets);
  meter->name = NULL; meter->bounds = meter->buckets = NULL;
  atomic_store_explicit(&entry->closed, 1, memory_order_release);
  leave();
  return (FooResult){0};
}

typedef struct Span {
  char *name;
  size_t length;
  uint64_t id, parent, start, elapsed;
  struct Span *previous;
#ifdef _WIN32
  DWORD thread;
#else
  pthread_t thread;
#endif
  int finished;
} Span;
static _Thread_local Span *active;
static atomic_uint_fast64_t serial;
static int belongs(Span *span) {
#ifdef _WIN32
  return span->thread == GetCurrentThreadId();
#else
  return pthread_equal(span->thread, pthread_self());
#endif
}
FooResult foo_trace_begin(FooText name) {
  if (!name.data || !name.len || name.len > 255) return failure(ARGUMENT);
  FooResult now = foo_time_current();
  if (now.error) return now;
  char *label = malloc(name.len + 1);
  if (!label) return failure(MEMORY);
  memcpy(label, name.data, name.len);
  label[name.len] = 0;
  Span *span = owned(sizeof(*span), SPANS);
  if (!span) { free(label); return failure(MEMORY); }
  span->name = label;
  span->length = name.len;
  span->start = now.number;
#ifdef _WIN32
  span->thread = GetCurrentThreadId();
#else
  span->thread = pthread_self();
#endif
  span->previous = active;
  span->parent = active ? active->id : 0;
  span->id = atomic_fetch_add_explicit(&serial, 1, memory_order_relaxed) + 1;
  active = span;
  return (FooResult){.pointer = span};
}
FooResult foo_trace_current(void) {
  return (FooResult){.number = active ? active->id : 0};
}
FooResult foo_trace_identity(void *pointer) {
  if (!resource(pointer, SPANS)) return failure(CLOSED);
  Span *span = pointer;
  return belongs(span) ? (FooResult){.number = span->id} : failure(ARGUMENT);
}
FooResult foo_trace_parent(void *pointer) {
  if (!resource(pointer, SPANS)) return failure(CLOSED);
  Span *span = pointer;
  return belongs(span) ? (FooResult){.number = span->parent} : failure(ARGUMENT);
}
FooResult foo_trace_name(void *pointer) {
  if (!resource(pointer, SPANS)) return failure(CLOSED);
  Span *span = pointer;
  if (!belongs(span)) return failure(ARGUMENT);
  return text(span->name, span->length);
}
FooResult foo_trace_finish(void *pointer) {
  if (!resource(pointer, SPANS)) return failure(CLOSED);
  Span *span = pointer;
  if (!belongs(span) || active != span || span->finished)
    return failure(ARGUMENT);
  FooResult now = foo_time_current();
  if (now.error) return now;
  if (now.number < span->start) return failure(SYSTEM);
  span->elapsed = now.number - span->start;
  span->finished = 1;
  active = span->previous;
  return (FooResult){.number = span->elapsed};
}
FooResult foo_trace_elapsed(void *pointer) {
  if (!resource(pointer, SPANS)) return failure(CLOSED);
  Span *span = pointer;
  if (!belongs(span)) return failure(ARGUMENT);
  if (!span->finished) return failure(ARGUMENT);
  return (FooResult){.number = span->elapsed};
}
FooResult foo_trace_close(void *pointer) {
  Resource *entry = resource(pointer, SPANS);
  if (!entry) return failure(CLOSED);
  Span *span = pointer;
  if (!belongs(span) || !span->finished) return failure(ARGUMENT);
  free(span->name);
  span->name = NULL;
  atomic_store_explicit(&entry->closed, 1, memory_order_release);
  return (FooResult){0};
}
