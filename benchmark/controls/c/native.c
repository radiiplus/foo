#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

typedef struct { const char *error; uint64_t value; } Result;
typedef struct {
  uint64_t allocations, allocated, reallocations, copied;
  uint64_t growths, transferred, capacity, maximum;
  uint64_t requested, live, peak, retained, slow, branches, branched;
} Metrics;

static Metrics metrics;
static volatile uint64_t sink;
#if defined(_WIN32)
#define NOINLINE __declspec(noinline)
#else
#define NOINLINE __attribute__((noinline))
#endif

static void *reserve(size_t size) {
  void *result = calloc(1, size ? size : 1);
  if (result) {
    metrics.allocations++;
    metrics.allocated += size;
    metrics.live += size;
    if (metrics.live > metrics.peak) metrics.peak = metrics.live;
  }
  return result;
}
static void dispose(void *pointer, size_t size) {
  if (!pointer) return;
  free(pointer);
  metrics.live -= size;
}

typedef struct Buffer {
  uint64_t *data;
  size_t used, capacity;
  int retired;
  struct Buffer *next;
} Buffer;
typedef struct { Buffer *buffer; size_t length; } View;
static Buffer *buffers;

static size_t capacity(size_t count) {
  size_t result = 8;
  while (result < count) result *= 2;
  return result;
}
static View append(View source, uint64_t value) {
  size_t count = source.length + 1;
  size_t available = capacity(count);
  metrics.growths++;
  metrics.requested += count;
  if (source.buffer && source.length == source.buffer->used &&
      source.buffer->used < source.buffer->capacity) {
    source.buffer->data[source.length] = value;
    source.buffer->used = count;
    metrics.capacity += source.buffer->capacity;
    if (source.buffer->capacity > metrics.maximum)
      metrics.maximum = source.buffer->capacity;
    return (View){source.buffer, count};
  }
  int branch = source.buffer && source.length < source.buffer->used;
  if (source.buffer && !branch) {
    available = source.buffer->capacity * 2;
    if (!source.buffer->retired) {
      source.buffer->retired = 1;
      metrics.retained += source.buffer->capacity * sizeof(uint64_t);
    }
  }
  Buffer *buffer = (Buffer *)malloc(sizeof(*buffer));
  if (!buffer) return (View){0};
  buffer->data = (uint64_t *)reserve(available * sizeof(uint64_t));
  if (!buffer->data) { free(buffer); return (View){0}; }
  buffer->used = count;
  buffer->capacity = available;
  buffer->retired = 0;
  buffer->next = buffers;
  buffers = buffer;
  if (source.length) {
    size_t bytes = source.length * sizeof(uint64_t);
    memcpy(buffer->data, source.buffer->data, bytes);
    metrics.copied += bytes;
    metrics.transferred += bytes;
    if (branch) {
      metrics.branches++;
      metrics.branched += bytes;
    }
  }
  buffer->data[source.length] = value;
  metrics.slow++;
  metrics.capacity += available;
  if (available > metrics.maximum) metrics.maximum = available;
  return (View){buffer, count};
}
static void discard(View value) {
  if (!value.buffer) return;
  Buffer **cursor = &buffers;
  while (*cursor && *cursor != value.buffer) cursor = &(*cursor)->next;
  if (!*cursor) return;
  *cursor = value.buffer->next;
  size_t size = value.buffer->capacity * sizeof(uint64_t);
  if (value.buffer->retired) metrics.retained -= size;
  dispose(value.buffer->data, size);
  free(value.buffer);
}

static uint64_t checked(uint64_t left, uint64_t right) {
  if (UINT64_MAX - left < right) abort();
  return left + right;
}
static NOINLINE uint64_t next(uint64_t value) { return checked(value, 1); }
static NOINLINE Result failable(uint64_t value) { return (Result){NULL, checked(value, 1)}; }
#define identity(value) (value)

static int arithmetic(uint64_t limit) {
  uint64_t total = 0;
  for (uint64_t index = 0; index < limit; index++) total = checked(total, index);
  sink = total;
  return total != UINT64_C(50000005000000);
}
static uint64_t position, total, bound;
static int shared(uint64_t limit) {
  position = 0;
  total = 0;
  bound = limit;
  while (position < bound) {
    total = checked(total, position);
    position = checked(position, 1);
  }
  sink = total;
  return total != UINT64_C(50000005000000);
}

static int calls(uint64_t limit) {
  uint64_t total = 0;
  for (uint64_t index = 0; index < limit; index++) total = checked(total, next(index));
  sink = total;
  return total != UINT64_C(50000015000001);
}

static int failure(uint64_t limit) {
  uint64_t total = 0;
  for (uint64_t index = 0; index < limit; index++) {
    Result value = failable(index);
    if (value.error) return 1;
    total = checked(total, value.value);
  }
  sink = total;
  return total != UINT64_C(50000015000001);
}

static int generic(uint64_t limit) {
  uint64_t total = 0;
  for (uint64_t index = 0; index < limit; index++) total = checked(total, identity(index));
  sink = total;
  return total != UINT64_C(50000005000000);
}

static int allocation(void) {
  const size_t count = 10000;
  uint64_t *values = (uint64_t *)reserve(count * sizeof(*values));
  uint64_t *doubled = (uint64_t *)reserve(count * sizeof(*doubled));
  if (!values || !doubled) { free(values); free(doubled); return 1; }
  for (size_t index = 0; index < count; index++) values[index] = index;
  for (size_t index = 0; index < count; index++) doubled[index] = values[index] * 2;
  int failed = doubled[count - 1] != 19998;
  sink = doubled[count - 1];
  dispose(doubled, count * sizeof(*doubled));
  dispose(values, count * sizeof(*values));
  return failed;
}

static int growth(void) {
  View values = {0}, older = {0};
  for (size_t index = 0; index < 10000; index++) {
    values = append(values, index);
    if (!values.buffer) return 1;
    if (index + 1 == 5000) older = values;
  }
  View branched = append(older, 50000);
  if (!branched.buffer) return 1;
  sink = values.buffer->data[9999] + branched.buffer->data[5000];
  int failed = older.length != 5000 || older.buffer->data[4999] != 4999 ||
      values.buffer->data[5000] != 5000 || branched.buffer->data[5000] != 50000;
  discard(branched);
  return failed;
}

static int branching(void) {
  View values = {0}, older = {0};
  for (size_t index = 0; index < 10000; index++) {
    values = append(values, index);
    if (!values.buffer) return 1;
    if (index + 1 == 5000) older = values;
  }
  uint64_t checksum = 0;
  for (size_t index = 0; index < 1000; index++) {
    View result = append(older, index);
    if (!result.buffer) return 1;
    checksum += result.buffer->data[5000];
    discard(result);
  }
  sink = checksum;
  return checksum != 499500 || older.buffer->data[4999] != 4999 ||
      values.buffer->data[5000] != 5000;
}

static int lookup(void) {
  const size_t count = 10000;
  uint64_t *values = (uint64_t *)reserve(count * sizeof(*values));
  if (!values) return 1;
  for (size_t index = 0; index < count; index++) values[index] = index;
  uint64_t checksum = 0;
  for (size_t index = 0; index < 1000000; index++) checksum += values[index % count];
  sink = checksum;
  dispose(values, count * sizeof(*values));
  return checksum != UINT64_C(4999500000);
}

static int iteration(void) {
  const size_t count = 1000000;
  uint64_t *values = (uint64_t *)reserve(count * sizeof(*values));
  if (!values) return 1;
  for (size_t index = 0; index < count; index++) values[index] = index;
  uint64_t checksum = 0;
  for (size_t index = 0; index < count; index++) checksum += values[index];
  sink = checksum;
  dispose(values, count * sizeof(*values));
  return checksum != UINT64_C(499999500000);
}

static NOINLINE uint64_t *generate(uint64_t seed) {
  uint64_t *values = (uint64_t *)reserve(10000 * sizeof(*values));
  if (!values) return NULL;
  for (size_t index = 0; index < 10000; index++) values[index] = index + seed;
  return values;
}

static int returned(void) {
  uint64_t checksum = 0;
  for (uint64_t seed = 0; seed < 128; seed++) {
    uint64_t *values = generate(seed);
    if (!values) return 1;
    for (size_t index = 0; index < 10000; index++) checksum += values[index];
    dispose(values, 10000 * sizeof(*values));
  }
  sink = checksum;
  return checksum != UINT64_C(6480640000);
}

static void report(void) {
  double average = metrics.growths ?
      (double)metrics.capacity / (double)metrics.growths : 0.0;
  double factor = metrics.requested ?
      (double)metrics.capacity / (double)metrics.requested : 0.0;
  fprintf(stderr,
      "FOO_METRICS {\"allocations\":%llu,\"allocatedBytes\":%llu,"
      "\"reallocations\":%llu,\"bytesCopied\":%llu,"
      "\"growthOperations\":%llu,\"growthBytesCopied\":%llu,"
      "\"averageCapacity\":%.3f,\"maximumCapacity\":%llu,"
      "\"growthFactor\":%.3f,\"liveBytes\":%llu,"
      "\"peakBytes\":%llu,\"olderVersionBytes\":%llu,"
      "\"slowPathHits\":%llu,\"branchOperations\":%llu,"
      "\"branchBytesCopied\":%llu}\n",
      (unsigned long long)metrics.allocations,
      (unsigned long long)metrics.allocated,
      (unsigned long long)metrics.reallocations,
      (unsigned long long)metrics.copied,
      (unsigned long long)metrics.growths,
      (unsigned long long)metrics.transferred, average,
      (unsigned long long)metrics.maximum, factor,
      (unsigned long long)metrics.live, (unsigned long long)metrics.peak,
      (unsigned long long)metrics.retained, (unsigned long long)metrics.slow,
      (unsigned long long)metrics.branches,
      (unsigned long long)metrics.branched);
}

int main(int argc, char **argv) {
  if (argc != 3) return 2;
  uint64_t cores = strtoull(argv[2], NULL, 10);
  if (!cores) return 2;
  uint64_t limit = UINT64_C(10000000) + (cores > 0);
  int failed = 0;
  if (!strcmp(argv[1], "startup")) failed = 0;
  else if (!strcmp(argv[1], "known")) failed = UINT64_C(499999500000) == 0;
  else if (!strcmp(argv[1], "runtime")) failed = cores == 0;
  else if (!strcmp(argv[1], "arithmetic")) failed = arithmetic(limit);
  else if (!strcmp(argv[1], "global")) failed = shared(limit);
  else if (!strcmp(argv[1], "calls")) failed = calls(limit);
  else if (!strcmp(argv[1], "failure")) failed = failure(limit);
  else if (!strcmp(argv[1], "generic")) failed = generic(limit);
  else if (!strcmp(argv[1], "allocation")) failed = allocation();
  else if (!strcmp(argv[1], "branch")) failed = branching();
  else if (!strcmp(argv[1], "growth")) failed = growth();
  else if (!strcmp(argv[1], "iteration")) failed = iteration();
  else if (!strcmp(argv[1], "returned")) failed = returned();
  else if (!strcmp(argv[1], "lookup")) failed = lookup();
  else return 2;
  report();
  return failed;
}
