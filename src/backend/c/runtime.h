/* Backend-independent hosted runtime. Compiles as ISO C11; OS APIs are isolated
 * here. */
#include <stdatomic.h>
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
  struct FOOAllocation *next;
} FOOAllocation;
static FOOAllocation *foo_allocations;
static atomic_flag foo_lock = ATOMIC_FLAG_INIT;
static void foo_enter(void) {
  while (atomic_flag_test_and_set_explicit(&foo_lock, memory_order_acquire)) {
  }
}
static void foo_leave(void) {
  atomic_flag_clear_explicit(&foo_lock, memory_order_release);
}
static void *foo_owned(size_t size) {
  void *pointer = malloc(size ? size : 1);
  FOOAllocation *item = malloc(sizeof(*item));
  if (!pointer || !item) {
    free(pointer);
    free(item);
    return NULL;
  }
  item->pointer = pointer;
  item->size = size;
  foo_enter();
  item->next = foo_allocations;
  foo_allocations = item;
  foo_leave();
  return pointer;
}
static FOOResult foo_error(const char *error);
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
  if (!map->capacity) return foo_error("MissingKey");
  FOOHashEntry *entry = foo_hash_slot(map, foo_hash_bytes(key.data, key.len), key, false);
  return entry->state == 1 ? (FOOResult){.pointer = entry->value} :
                            foo_error("MissingKey");
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

#ifdef FOO_CRYPTO
#include <sodium.h>
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
static FOOResult foo_crypto_random(uint32_t size) {
  foo_crypto_init();
  uint8_t *data = foo_owned(size);
  if (!data)
    return foo_error("OutOfMemory");
  randombytes_buf(data, size);
  return (FOOResult){.text = {data, size}};
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
