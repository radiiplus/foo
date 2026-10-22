#ifdef FOO_QBE_INTEGER_ONLY
typedef unsigned long long uint64_t;
typedef unsigned long size_t;
#define UINT64_MAX (~(uint64_t)0)
#define UINT64_C(value) value##ULL
#else
#include <stdint.h>
#include <stddef.h>
#endif
#include <stdbool.h>
#ifndef FOO_QBE_INTEGER_ONLY
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <errno.h>
#include <sys/stat.h>
#if defined(__TINYC__) && defined(__x86_64__)
#include <stdatomic.h>
#endif

typedef struct { const unsigned char *data; uint64_t length; } foo_qbe_slice;
#if defined(__FOO_TCC_INLINE_MEMCPY__) && defined(__linux__)
#define foo_qbe_fixed_copy __builtin_memcpy
#else
#define foo_qbe_fixed_copy memcpy
#endif
static void foo_qbe_text_enter(void);
static void foo_qbe_text_leave(void);

#define FOO_QBE_HASHMAP_ONLY
#define FOO_QBE_UNICODE_ONLY
typedef struct { const uint8_t *data; uint64_t len; } FOOText;
typedef struct {
    const char *error;
    void *pointer;
    uint64_t number;
    _Bool boolean;
} FOOResult;
static FOOResult foo_error(const char *message) {
    FOOResult result = {0};
    result.error = message;
    return result;
}
static void foo_enter(void) { foo_qbe_text_enter(); }
static void foo_leave(void) { foo_qbe_text_leave(); }
#define foo_transfer(destination, source, size) memcpy(destination, source, size)
#include "qbe-hashmap.h"
#define FOO_QBE_JSON_CORE_ONLY
#include "qbe-json.h"
#undef foo_transfer

static int foo_qbe_table_registered;
static int foo_qbe_table_key(const void *source, FOOText *key) {
    if (!source) return 0;
    foo_qbe_slice slice;
    memcpy(&slice, source, sizeof(slice));
    if (slice.length > SIZE_MAX || (slice.length && !slice.data)) return 0;
    *key = (FOOText){slice.data, (size_t)slice.length};
    return 1;
}
static void foo_qbe_table_error(void *output, const char *message) {
    memcpy(output, &message, sizeof(message));
}
void foo_qbe_table_create(void *output) {
    foo_enter();
    if (!foo_qbe_table_registered && atexit(foo_hashmap_shutdown) != 0) {
        foo_leave();
        foo_qbe_table_error(output, "OutOfMemory");
        return;
    }
    foo_qbe_table_registered = 1;
    FOOResult result = foo_hashmap_create();
    foo_leave();
    if (result.error) foo_qbe_table_error(output, result.error);
    else memcpy((unsigned char *)output + 8, &result.pointer, sizeof(result.pointer));
}
void foo_qbe_table_put(void *output, void *handle, const void *key_source,
    const void *value, uint64_t value_size) {
    FOOText key;
    if (!foo_qbe_table_key(key_source, &key) || !value || value_size > SIZE_MAX) {
        foo_qbe_table_error(output, "InvalidInput");
        return;
    }
    foo_enter();
    FOOResult result = foo_hashmap_put(handle, key, value, (size_t)value_size);
    foo_leave();
    if (result.error) foo_qbe_table_error(output, result.error);
}
void foo_qbe_table_get(void *output, void *handle, const void *key_source,
    uint64_t value_size, uint64_t value_offset) {
    FOOText key;
    if (!foo_qbe_table_key(key_source, &key) || value_size > SIZE_MAX ||
        value_offset > SIZE_MAX - value_size) {
        foo_qbe_table_error(output, "InvalidInput");
        return;
    }
    foo_enter();
    FOOResult result = foo_hashmap_get(handle, key);
    FOOHashMap *map = foo_hashmap_value(handle);
    if (!result.error && (!map || map->value_size != (size_t)value_size))
        result.error = "InvalidValue";
    if (!result.error && value_size)
        memcpy((unsigned char *)output + value_offset, result.pointer,
            (size_t)value_size);
    foo_leave();
    if (result.error) foo_qbe_table_error(output, result.error);
}
void foo_qbe_table_query(void *output, void *handle, const void *key_source,
    int operation) {
    FOOText key;
    if (!foo_qbe_table_key(key_source, &key)) {
        foo_qbe_table_error(output, "InvalidInput");
        return;
    }
    foo_enter();
    FOOResult result = operation == 0 ? foo_hashmap_contains(handle, key) :
        foo_hashmap_remove(handle, key);
    foo_leave();
    if (result.error) foo_qbe_table_error(output, result.error);
    else *(unsigned char *)((unsigned char *)output + 8) = result.boolean;
}
void foo_qbe_table_length(void *output, void *handle) {
    foo_enter();
    FOOResult result = foo_hashmap_length(handle);
    foo_leave();
    if (result.error) foo_qbe_table_error(output, result.error);
    else memcpy((unsigned char *)output + 8, &result.number, sizeof(result.number));
}
void foo_qbe_table_close(void *output, void *handle) {
    foo_enter();
    FOOResult result = foo_hashmap_close(handle);
    foo_leave();
    if (result.error) foo_qbe_table_error(output, result.error);
}
#if !defined(_WIN32)
#include <unistd.h>
#endif

#if defined(_WIN32)
#include <windows.h>
#if defined(__TINYC__)
typedef struct { void *Ptr; } SRWLOCK;
#define SRWLOCK_INIT { 0 }
__declspec(dllimport) void WINAPI AcquireSRWLockExclusive(SRWLOCK *lock);
__declspec(dllimport) void WINAPI ReleaseSRWLockExclusive(SRWLOCK *lock);
typedef struct { void *Ptr; } CONDITION_VARIABLE;
__declspec(dllimport) void WINAPI InitializeConditionVariable(CONDITION_VARIABLE *condition);
__declspec(dllimport) void WINAPI WakeConditionVariable(CONDITION_VARIABLE *condition);
__declspec(dllimport) BOOL WINAPI SleepConditionVariableCS(
    CONDITION_VARIABLE *condition, CRITICAL_SECTION *lock, DWORD milliseconds);
#endif
static SRWLOCK foo_qbe_text_lock = SRWLOCK_INIT;
static void foo_qbe_text_enter(void) { AcquireSRWLockExclusive(&foo_qbe_text_lock); }
static void foo_qbe_text_leave(void) { ReleaseSRWLockExclusive(&foo_qbe_text_lock); }
#else
#include <pthread.h>
static pthread_mutex_t foo_qbe_text_lock = PTHREAD_MUTEX_INITIALIZER;
static void foo_qbe_text_enter(void) { pthread_mutex_lock(&foo_qbe_text_lock); }
static void foo_qbe_text_leave(void) { pthread_mutex_unlock(&foo_qbe_text_lock); }
#endif

typedef struct {
    const char *error;
    void *pointer;
    uint64_t number;
    FOOText text;
    _Bool boolean;
} FooMemoryResult;
static FooMemoryResult foo_qbe_memory_failure(const char *message) {
    FooMemoryResult result = {0};
    result.error = message;
    return result;
}
#define FOOResult FooMemoryResult
#define foo_error foo_qbe_memory_failure
#define foo_transfer(destination, source, size) memmove(destination, source, size)
#include "qbe-memory.h"
#undef foo_transfer
#undef foo_error
#undef FOOResult

static int foo_qbe_memory_registered;
static void foo_qbe_memory_cleanup(void) {
    foo_clear(&foo_system);
    while (foo_arenas) {
        FOOAllocator *arena = foo_arenas;
        foo_arenas = arena->next;
        foo_clear(arena);
        free(arena);
    }
}
static const char *foo_qbe_memory_prepare(void) {
    if (foo_qbe_memory_registered) return NULL;
    if (atexit(foo_qbe_memory_cleanup) != 0) return "OutOfMemory";
    foo_qbe_memory_registered = 1;
    return NULL;
}
static void foo_qbe_memory_result(void *output, FooMemoryResult value,
    int payload) {
    if (value.error) memcpy(output, &value.error, sizeof(value.error));
    else if (payload == 1)
        memcpy((unsigned char *)output + 8, &value.pointer,
            sizeof(value.pointer));
    else if (payload == 2)
        memcpy((unsigned char *)output + 8, &value.text, sizeof(value.text));
}
void *foo_qbe_memory_system(void) { return foo_memory_system(); }
void foo_qbe_memory_arena(void *output) {
    foo_qbe_text_enter();
    const char *issue = foo_qbe_memory_prepare();
    FooMemoryResult value = issue ? foo_qbe_memory_failure(issue) :
        foo_memory_arena();
    foo_qbe_text_leave();
    foo_qbe_memory_result(output, value, 1);
}
void foo_qbe_memory_allocate(void *output, void *owner, uint64_t size) {
    foo_qbe_text_enter();
    const char *issue = foo_qbe_memory_prepare();
    FooMemoryResult value = issue ? foo_qbe_memory_failure(issue) :
        foo_memory_allocate(owner, size);
    foo_qbe_text_leave();
    foo_qbe_memory_result(output, value, 1);
}
void foo_qbe_memory_allocate_slice(void *output, void *owner, uint64_t size) {
    foo_qbe_memory_allocate(output, owner, size);
    if (!*(const char **)output)
        memcpy((unsigned char *)output + 16, &size, sizeof(size));
}
void foo_qbe_memory_reserve(void *output, void *owner, uint64_t size,
    uint64_t alignment) {
    foo_qbe_text_enter();
    const char *issue = foo_qbe_memory_prepare();
    FooMemoryResult value = issue ? foo_qbe_memory_failure(issue) :
        foo_memory_reserve(owner, size, alignment);
    foo_qbe_text_leave();
    foo_qbe_memory_result(output, value, 1);
}
void foo_qbe_memory_expand(void *output, void *owner, void *buffer,
    uint64_t size) {
    foo_qbe_text_enter();
    FooMemoryResult value = foo_memory_expand(owner, buffer, size);
    foo_qbe_text_leave();
    foo_qbe_memory_result(output, value, 1);
}
void foo_qbe_memory_view(void *output, void *owner, void *buffer,
    uint64_t size) {
    foo_qbe_text_enter();
    FooMemoryResult value = foo_memory_view(owner, buffer, size);
    foo_qbe_text_leave();
    foo_qbe_memory_result(output, value, 2);
}
void foo_qbe_memory_bytes(void *output, void *owner, void *buffer,
    uint64_t size) {
    foo_qbe_memory_view(output, owner, buffer, size);
}
static int foo_qbe_memory_slice(const void *source, FOOText *value) {
    if (!source) return 0;
    memcpy(value, source, sizeof(*value));
    return value->len <= SIZE_MAX && (!value->len || value->data);
}
void foo_qbe_memory_copy(void *output, void *owner, void *buffer,
    const void *source) {
    FOOText content;
    if (!foo_qbe_memory_slice(source, &content)) {
        foo_qbe_table_error(output, "InvalidBuffer");
        return;
    }
    foo_qbe_text_enter();
    FooMemoryResult value = foo_memory_copy(owner, buffer, content);
    foo_qbe_text_leave();
    foo_qbe_memory_result(output, value, 0);
}
void foo_qbe_memory_transfer(void *output, const void *source,
    const void *destination) {
    FOOText input, target;
    if (!foo_qbe_memory_slice(source, &input) ||
        !foo_qbe_memory_slice(destination, &target)) {
        foo_qbe_table_error(output, "InvalidBuffer");
        return;
    }
    foo_qbe_memory_result(output, foo_memory_transfer(input, target), 0);
}
void foo_qbe_memory_clear(const void *source) {
    FOOText value;
    if (foo_qbe_memory_slice(source, &value)) foo_memory_clear(value);
}
int64_t foo_qbe_memory_compare(const void *left, const void *right) {
    FOOText first, second;
    if (!foo_qbe_memory_slice(left, &first) ||
        !foo_qbe_memory_slice(right, &second)) return 0;
    return foo_memory_compare(first, second);
}
int foo_qbe_memory_aligned(void *buffer, uint64_t alignment) {
    return foo_memory_aligned(buffer, alignment);
}
void foo_qbe_memory_release(void *output, void *owner, void *buffer) {
    foo_qbe_text_enter();
    FooMemoryResult value = foo_memory_release(owner, buffer);
    foo_qbe_text_leave();
    foo_qbe_memory_result(output, value, 0);
}
void foo_qbe_memory_close(void *output, void *owner) {
    foo_qbe_text_enter();
    FooMemoryResult value = foo_memory_close(owner);
    foo_qbe_text_leave();
    foo_qbe_memory_result(output, value, 0);
}
void foo_qbe_memory_reinterpret(void *output, void *owner, void *buffer,
    uint64_t offset, uint64_t size, uint64_t alignment) {
    foo_qbe_text_enter();
    FooMemoryResult value = foo_memory_reinterpret(owner, buffer, offset,
        (size_t)size, (size_t)alignment);
    foo_qbe_text_leave();
    foo_qbe_memory_result(output, value, 1);
}
int foo_qbe_memory_identical(void *left, void *right) {
    return foo_memory_identical(left, right);
}

#ifndef FOO_QBE_EXTERNAL_HOOKS
#if defined(__TINYC__) && defined(_WIN32)
#define _Thread_local __declspec(thread)
#endif
#include "trace.c"
#else
extern void foo_qbe_panic(const char *message);
#endif

typedef struct foo_qbe_allocation {
    void *backing;
    void *data;
    size_t size;
    struct foo_qbe_allocation *next;
} foo_qbe_allocation;

#ifndef FOO_QBE_EXTERNAL_HOOKS
void foo_qbe_trace(const char *slot, const char *file, uint64_t offset) {
    foo_trace(slot, file, (size_t)offset);
}

void foo_qbe_trace_reset(void) {
    foo_trace_reset();
}

void foo_qbe_panic(const char *message) {
    fprintf(stderr, "%s\n", message ? message : "UnknownError");
    foo_trace_report();
    exit(1);
}

void foo_qbe_expect(int value) {
    if (!value) foo_qbe_panic("TestExpectationFailed");
}

void foo_qbe_test_number(uint64_t actual, uint64_t expected) {
    if (actual != expected) foo_qbe_panic("TestExpectationFailed");
}

void foo_qbe_test_positive(uint64_t value) {
    if (!value) foo_qbe_panic("TestExpectationFailed");
}

void foo_qbe_test_real(double actual, double expected) {
    if (actual != expected) foo_qbe_panic("TestExpectationFailed");
}

void foo_qbe_test_point(const void *actual, uint32_t expected) {
    const unsigned char *bytes = actual;
    uint32_t value;
    if (!bytes || !bytes[0]) foo_qbe_panic("TestExpectationFailed");
    memcpy(&value, bytes + 4, sizeof(value));
    if (value != expected) foo_qbe_panic("TestExpectationFailed");
}
#endif

void foo_qbe_system_cores(void *output) {
    static const char error[] = "SystemError";
    uint32_t count = 0;
#if defined(_WIN32)
    SYSTEM_INFO info;
    GetSystemInfo(&info);
    count = info.dwNumberOfProcessors;
#else
    long online = sysconf(_SC_NPROCESSORS_ONLN);
    if (online > 0 && (uint64_t)online <= UINT32_MAX) count = (uint32_t)online;
#endif
    if (!output) foo_qbe_panic("InvalidResult");
    if (count) memcpy((unsigned char *)output + 8, &count, sizeof(count));
    else {
        const char *message = error;
        memcpy(output, &message, sizeof(message));
    }
}

static int foo_qbe_valid_size(void *scope, uint64_t size, uint64_t alignment) {
    if (!scope || alignment == 0 || (alignment & (alignment - 1)) != 0 ||
        alignment > SIZE_MAX || size > SIZE_MAX)
        return 0;
    size_t bytes = size ? (size_t)size : 1;
    size_t padding = (size_t)alignment - 1;
    if (bytes > SIZE_MAX - padding)
        return 0;
    return 1;
}

void *foo_qbe_reserve(void *scope, uint64_t size, uint64_t alignment) {
    if (!foo_qbe_valid_size(scope, size, alignment)) return NULL;
    size_t bytes = size ? (size_t)size : 1;
    size_t padding = (size_t)alignment - 1;
    foo_qbe_allocation *entry = malloc(sizeof(*entry));
    if (!entry) return NULL;
    entry->backing = malloc(bytes + padding);
    if (!entry->backing) {
        free(entry);
        return NULL;
    }
    uintptr_t address = ((uintptr_t)entry->backing + padding) & ~(uintptr_t)padding;
    void *data = (void *)address;
    memset(data, 0, bytes);
    entry->data = data;
    entry->size = size;
    entry->next = *(foo_qbe_allocation **)scope;
    *(foo_qbe_allocation **)scope = entry;
    return data;
}

void *foo_qbe_alloc(void *scope, uint64_t size, uint64_t alignment) {
    if (!foo_qbe_valid_size(scope, size, alignment))
        foo_qbe_panic("InvalidSize");
    void *data = foo_qbe_reserve(scope, size, alignment);
    if (!data) foo_qbe_panic("OutOfMemory");
    return data;
}

void foo_qbe_free(void *scope) {
    if (!scope) return;
    foo_qbe_allocation **head = scope;
    while (*head) {
        foo_qbe_allocation *entry = *head;
        *head = entry->next;
        free(entry->backing);
        free(entry);
    }
}

static foo_qbe_allocation *foo_qbe_text_allocations;
static int foo_qbe_text_registered;

static void foo_qbe_text_cleanup(void) {
    foo_qbe_free(&foo_qbe_text_allocations);
}

static void foo_qbe_text_error(void *output, const char *message) {
    memcpy(output, &message, sizeof(message));
}

void foo_qbe_text_concatenate(void *output, const void *left,
    const void *right) {
    static const char invalid[] = "InvalidSlice";
    static const char overflow[] = "IntegerOverflow";
    static const char memory[] = "OutOfMemory";
    foo_qbe_slice a, b, joined;
    memcpy(&a, left, sizeof(a));
    memcpy(&b, right, sizeof(b));
    if ((a.length && !a.data) || (b.length && !b.data)) {
        foo_qbe_text_error(output, invalid);
        return;
    }
    if (a.length > SIZE_MAX || b.length > SIZE_MAX ||
        b.length > SIZE_MAX - a.length) {
        foo_qbe_text_error(output, overflow);
        return;
    }
    if (!a.length && !b.length) return;
    foo_qbe_text_enter();
    if (!foo_qbe_text_registered && atexit(foo_qbe_text_cleanup) != 0) {
        foo_qbe_text_leave();
        foo_qbe_text_error(output, memory);
        return;
    }
    foo_qbe_text_registered = 1;
    unsigned char *bytes = foo_qbe_reserve(&foo_qbe_text_allocations,
        a.length + b.length, 1);
    foo_qbe_text_leave();
    if (!bytes) {
        foo_qbe_text_error(output, memory);
        return;
    }
    if (a.length) memcpy(bytes, a.data, (size_t)a.length);
    if (b.length) memcpy(bytes + a.length, b.data, (size_t)b.length);
    joined = (foo_qbe_slice){bytes, a.length + b.length};
    memcpy((unsigned char *)output + 8, &joined, sizeof(joined));
}

void foo_qbe_text_find(void *output, const void *content,
    const void *needle) {
    foo_qbe_slice value, match;
    foo_qbe_fixed_copy(&value, content, sizeof(value));
    foo_qbe_fixed_copy(&match, needle, sizeof(match));
    if (value.length > SIZE_MAX || match.length > SIZE_MAX ||
        (value.length && !value.data) || (match.length && !match.data))
        return;
    if (!match.length) {
        *(unsigned char *)output = 1;
        return;
    }
    if (match.length > value.length) return;
    const unsigned char *cursor = value.data;
    const unsigned char *last = value.data + value.length - match.length;
    while (cursor <= last) {
        const unsigned char *found = memchr(cursor, match.data[0],
            (size_t)(last - cursor) + 1);
        if (!found) break;
        if (match.length == 1 ||
            memcmp(found + 1, match.data + 1, (size_t)match.length - 1) == 0) {
            uint64_t position = (uint64_t)(found - value.data);
            *(unsigned char *)output = 1;
            foo_qbe_fixed_copy((unsigned char *)output + 8, &position,
                sizeof(position));
            return;
        }
        cursor = found + 1;
    }
}

int foo_qbe_text_equal(const void *left, const void *right) {
    foo_qbe_slice a, b;
    if (!left || !right) return 0;
    memcpy(&a, left, sizeof(a));
    memcpy(&b, right, sizeof(b));
    if (a.length != b.length || a.length > SIZE_MAX ||
        (a.length && (!a.data || !b.data))) return 0;
    return !a.length || memcmp(a.data, b.data, (size_t)a.length) == 0;
}

void foo_qbe_text_release(void *output, const void *content) {
    static const char invalid[] = "InvalidText";
    foo_qbe_slice value;
    memcpy(&value, content, sizeof(value));
    if (!value.length && !value.data) return;
    foo_qbe_text_enter();
    foo_qbe_allocation **cursor = &foo_qbe_text_allocations;
    while (*cursor && ((*cursor)->data != value.data ||
        (*cursor)->size != value.length)) cursor = &(*cursor)->next;
    foo_qbe_allocation *entry = *cursor;
    if (entry) *cursor = entry->next;
    foo_qbe_text_leave();
    if (!entry) {
        foo_qbe_text_error(output, invalid);
        return;
    }
    free(entry->backing);
    free(entry);
}

typedef struct foo_qbe_file {
    FILE *stream;
    struct foo_qbe_file *next;
} foo_qbe_file;

static foo_qbe_file *foo_qbe_files;
static int foo_qbe_files_registered;
#ifdef _WIN32
static SRWLOCK foo_qbe_file_lock = SRWLOCK_INIT;
static void foo_qbe_file_enter(void) { AcquireSRWLockExclusive(&foo_qbe_file_lock); }
static void foo_qbe_file_leave(void) { ReleaseSRWLockExclusive(&foo_qbe_file_lock); }
#else
static pthread_mutex_t foo_qbe_file_lock = PTHREAD_MUTEX_INITIALIZER;
static void foo_qbe_file_enter(void) { pthread_mutex_lock(&foo_qbe_file_lock); }
static void foo_qbe_file_leave(void) { pthread_mutex_unlock(&foo_qbe_file_lock); }
#endif

static void foo_qbe_files_cleanup(void) {
    foo_qbe_file_enter();
    while (foo_qbe_files) {
        foo_qbe_file *file = foo_qbe_files;
        foo_qbe_files = file->next;
        fclose(file->stream);
        free(file);
    }
    foo_qbe_file_leave();
}

static char *foo_qbe_path(const void *source) {
    foo_qbe_slice path;
    if (!source) return NULL;
    memcpy(&path, source, sizeof(path));
    if (!path.data || !path.length || path.length >= SIZE_MAX ||
        memchr(path.data, 0, (size_t)path.length)) return NULL;
    char *name = malloc((size_t)path.length + 1);
    if (!name) return NULL;
    memcpy(name, path.data, (size_t)path.length);
    name[path.length] = 0;
    return name;
}

static void foo_qbe_file_error(void *output, const char *message) {
    memcpy(output, &message, sizeof(message));
}

static int foo_qbe_text_adopt(void *output, unsigned char *bytes, size_t length) {
    if (!length) { free(bytes); return 1; }
    foo_qbe_allocation *entry = malloc(sizeof(*entry));
    if (!entry) { free(bytes); return 0; }
    entry->backing = bytes;
    entry->data = bytes;
    entry->size = length;
    foo_qbe_text_enter();
    if (!foo_qbe_text_registered && atexit(foo_qbe_text_cleanup) != 0) {
        foo_qbe_text_leave();
        free(entry);
        free(bytes);
        return 0;
    }
    foo_qbe_text_registered = 1;
    entry->next = foo_qbe_text_allocations;
    foo_qbe_text_allocations = entry;
    foo_qbe_text_leave();
    foo_qbe_slice result = {bytes, (uint64_t)length};
    memcpy((unsigned char *)output + 8, &result, sizeof(result));
    return 1;
}

static void foo_qbe_read_stream(void *output, FILE *stream, uint64_t limit,
    int line) {
    static const char memory[] = "OutOfMemory";
    static const char io[] = "IOError";
    unsigned char *bytes = NULL;
    size_t length = 0, capacity = 0;
    while ((uint64_t)length < limit) {
        int next = fgetc(stream);
        if (next == EOF) break;
        if (length == capacity) {
            size_t grown = capacity ? capacity * 2 : 256;
            if (grown < capacity || grown > SIZE_MAX / 2) grown = SIZE_MAX;
            if ((uint64_t)grown > limit) grown = (size_t)limit;
            unsigned char *larger = realloc(bytes, grown);
            if (!larger) {
                free(bytes);
                foo_qbe_file_error(output, memory);
                return;
            }
            bytes = larger;
            capacity = grown;
        }
        bytes[length++] = (unsigned char)next;
        if (line && next == '\n') break;
    }
    if (ferror(stream)) {
        free(bytes);
        foo_qbe_file_error(output, io);
    } else if (!foo_qbe_text_adopt(output, bytes, length)) {
        foo_qbe_file_error(output, memory);
    }
}

void foo_qbe_fs_exists(void *output, const void *path) {
    static const char invalid[] = "InvalidPath";
    static const char io[] = "IOError";
    char *name = foo_qbe_path(path);
    if (!name) { foo_qbe_file_error(output, invalid); return; }
    struct stat info;
    int present = stat(name, &info) == 0;
    int issue = errno;
    free(name);
    if (!present && issue != ENOENT) { foo_qbe_file_error(output, io); return; }
    ((unsigned char *)output)[8] = (unsigned char)present;
}

void foo_qbe_fs_read(void *output, const void *path) {
    static const char invalid[] = "InvalidPath";
    static const char io[] = "IOError";
    char *name = foo_qbe_path(path);
    if (!name) { foo_qbe_file_error(output, invalid); return; }
    FILE *stream = fopen(name, "rb");
    free(name);
    if (!stream) { foo_qbe_file_error(output, io); return; }
    foo_qbe_read_stream(output, stream, UINT64_MAX, 0);
    if (fclose(stream) != 0 && !*(const char **)output)
        foo_qbe_file_error(output, io);
}

void foo_qbe_fs_write(void *output, const void *path, const void *content) {
    static const char invalid[] = "InvalidInput";
    static const char io[] = "IOError";
    char *name = foo_qbe_path(path);
    foo_qbe_slice value;
    if (!name || !content) { free(name); foo_qbe_file_error(output, invalid); return; }
    memcpy(&value, content, sizeof(value));
    if ((value.length && !value.data) || value.length > SIZE_MAX) {
        free(name);
        foo_qbe_file_error(output, invalid);
        return;
    }
    FILE *stream = fopen(name, "wb");
    free(name);
    if (!stream) { foo_qbe_file_error(output, io); return; }
    size_t written = value.length ? fwrite(value.data, 1, (size_t)value.length, stream) : 0;
    int close_failed = fclose(stream) != 0;
    if (written != (size_t)value.length || close_failed)
        foo_qbe_file_error(output, io);
}

void foo_qbe_fs_remove(void *output, const void *path) {
    static const char invalid[] = "InvalidPath";
    static const char io[] = "IOError";
    char *name = foo_qbe_path(path);
    if (!name) { foo_qbe_file_error(output, invalid); return; }
    int failed = remove(name);
    free(name);
    if (failed) foo_qbe_file_error(output, io);
}

void foo_qbe_fs_open(void *output, const void *path, const void *mode) {
    static const char invalid[] = "InvalidInput";
    static const char io[] = "IOError";
    static const char memory[] = "OutOfMemory";
    char *name = foo_qbe_path(path);
    foo_qbe_slice requested;
    if (!name || !mode) { free(name); foo_qbe_file_error(output, invalid); return; }
    memcpy(&requested, mode, sizeof(requested));
    if (requested.length && !requested.data) {
        free(name);
        foo_qbe_file_error(output, invalid);
        return;
    }
    const char *native = requested.length == 4 &&
        !memcmp(requested.data, "read", 4) ? "rb" :
        requested.length == 5 && !memcmp(requested.data, "write", 5) ? "wb" :
        requested.length == 6 && !memcmp(requested.data, "append", 6) ? "ab" : NULL;
    if (!native) { free(name); foo_qbe_file_error(output, invalid); return; }
    FILE *stream = fopen(name, native);
    free(name);
    if (!stream) { foo_qbe_file_error(output, io); return; }
    foo_qbe_file *file = malloc(sizeof(*file));
    if (!file) { fclose(stream); foo_qbe_file_error(output, memory); return; }
    file->stream = stream;
    foo_qbe_file_enter();
    if (!foo_qbe_files_registered && atexit(foo_qbe_files_cleanup) != 0) {
        foo_qbe_file_leave();
        fclose(stream);
        free(file);
        foo_qbe_file_error(output, memory);
        return;
    }
    foo_qbe_files_registered = 1;
    file->next = foo_qbe_files;
    foo_qbe_files = file;
    foo_qbe_file_leave();
    memcpy((unsigned char *)output + 8, &file, sizeof(file));
}

static foo_qbe_file *foo_qbe_file_find(const void *handle) {
    for (foo_qbe_file *file = foo_qbe_files; file; file = file->next)
        if (file == handle) return file;
    return NULL;
}

void *foo_qbe_io_input(void) { return stdin; }
void *foo_qbe_io_output(void) { return stdout; }
void *foo_qbe_io_report(void) { return stderr; }

static FILE *foo_qbe_io_stream(const void *handle) {
    if (handle == stdin) return stdin;
    if (handle == stdout) return stdout;
    if (handle == stderr) return stderr;
    foo_qbe_file *file = foo_qbe_file_find(handle);
    return file ? file->stream : NULL;
}

void foo_qbe_io_read(void *output, const void *handle, uint64_t size) {
    static const char closed[] = "ClosedStream";
    foo_qbe_file_enter();
    FILE *stream = foo_qbe_io_stream(handle);
    if (!stream) foo_qbe_file_error(output, closed);
    else foo_qbe_read_stream(output, stream, size, 0);
    foo_qbe_file_leave();
}

void foo_qbe_io_line(void *output, const void *handle) {
    static const char closed[] = "ClosedStream";
    foo_qbe_file_enter();
    FILE *stream = foo_qbe_io_stream(handle);
    if (!stream) foo_qbe_file_error(output, closed);
    else foo_qbe_read_stream(output, stream, UINT64_MAX, 1);
    foo_qbe_file_leave();
}

void foo_qbe_io_write(void *output, const void *handle, const void *content) {
    static const char closed[] = "ClosedStream";
    static const char invalid[] = "InvalidInput";
    static const char io[] = "IOError";
    foo_qbe_slice value;
    if (!content) { foo_qbe_file_error(output, invalid); return; }
    memcpy(&value, content, sizeof(value));
    if (value.length > SIZE_MAX || (value.length && !value.data)) {
        foo_qbe_file_error(output, invalid);
        return;
    }
    foo_qbe_file_enter();
    FILE *stream = foo_qbe_io_stream(handle);
    if (!stream) foo_qbe_file_error(output, closed);
    else if (value.length && fwrite(value.data, 1, (size_t)value.length,
            stream) != (size_t)value.length)
        foo_qbe_file_error(output, io);
    foo_qbe_file_leave();
}

void foo_qbe_io_close(void *output, const void *handle) {
    static const char closed[] = "ClosedStream";
    static const char io[] = "IOError";
    foo_qbe_file_enter();
    foo_qbe_file **cursor = &foo_qbe_files;
    while (*cursor && *cursor != handle) cursor = &(*cursor)->next;
    foo_qbe_file *file = *cursor;
    if (file) *cursor = file->next;
    foo_qbe_file_leave();
    if (!file) { foo_qbe_file_error(output, closed); return; }
    if (fclose(file->stream) != 0) foo_qbe_file_error(output, io);
    free(file);
}

uint64_t foo_qbe_resource_files(void) {
    uint64_t count = 0;
    foo_qbe_file_enter();
    for (foo_qbe_file *file = foo_qbe_files; file; file = file->next) ++count;
    foo_qbe_file_leave();
    return count;
}

static foo_qbe_allocation *foo_qbe_detach(foo_qbe_allocation **head,
    const void *pointer, size_t size) {
    foo_qbe_allocation **cursor = head;
    while (*cursor && ((*cursor)->data != pointer || (*cursor)->size != size))
        cursor = &(*cursor)->next;
    foo_qbe_allocation *entry = *cursor;
    if (entry) *cursor = entry->next;
    return entry;
}

static foo_qbe_allocation *foo_qbe_sequence_allocations;
static int foo_qbe_sequence_registered;
static void foo_qbe_sequence_cleanup(void);

void foo_qbe_sequence_sized(void *output, uint64_t count,
    uint64_t element_size, uint64_t alignment) {
    if (!element_size || count > SIZE_MAX / element_size ||
        !alignment || (alignment & (alignment - 1)) != 0) {
        foo_qbe_table_error(output, "Overflow");
        return;
    }
    if (!count) return;
    foo_qbe_text_enter();
    if (!foo_qbe_sequence_registered &&
        atexit(foo_qbe_sequence_cleanup) != 0) {
        foo_qbe_text_leave();
        foo_qbe_table_error(output, "OutOfMemory");
        return;
    }
    foo_qbe_sequence_registered = 1;
    void *data = foo_qbe_reserve(&foo_qbe_sequence_allocations,
        count * element_size, alignment);
    foo_qbe_text_leave();
    if (!data) {
        foo_qbe_table_error(output, "OutOfMemory");
        return;
    }
    memcpy((unsigned char *)output + 8, &data, sizeof(data));
    memcpy((unsigned char *)output + 16, &count, sizeof(count));
}

void foo_qbe_sequence_copy(void *output, const void *source,
    uint64_t element_size, uint64_t alignment) {
    foo_qbe_slice slice;
    if (!source || !element_size) {
        foo_qbe_table_error(output, "InvalidBuffer");
        return;
    }
    memcpy(&slice, source, sizeof(slice));
    if ((slice.length && !slice.data) || (!slice.length && slice.data) ||
        slice.length > SIZE_MAX / element_size) {
        foo_qbe_table_error(output, "InvalidBuffer");
        return;
    }
    foo_qbe_sequence_sized(output, slice.length, element_size, alignment);
    if (*(const char **)output || !slice.length) return;
    void *data;
    memcpy(&data, (const unsigned char *)output + 8, sizeof(data));
    memcpy(data, slice.data, (size_t)(slice.length * element_size));
}

int foo_qbe_sequence_compare(const void *left_source, const void *right_source,
    int width, int signed_values) {
    foo_qbe_slice left, right;
    memcpy(&left, left_source, sizeof(left));
    memcpy(&right, right_source, sizeof(right));
    size_t stride = (size_t)width / 8;
    uint64_t count = left.length < right.length ? left.length : right.length;
    for (uint64_t index = 0; index < count; ++index) {
        uint64_t lhs = 0, rhs = 0;
        memcpy(&lhs, left.data + index * stride, stride);
        memcpy(&rhs, right.data + index * stride, stride);
        if (signed_values) {
            uint64_t sign = UINT64_C(1) << (width - 1);
            lhs ^= sign;
            rhs ^= sign;
        }
        if (lhs < rhs) return -1;
        if (lhs > rhs) return 1;
    }
    return left.length < right.length ? -1 : left.length > right.length ? 1 : 0;
}

void foo_qbe_sequence_release(void *output, const void *source,
    uint64_t element_size) {
    foo_qbe_slice slice;
    if (!source || !element_size) {
        foo_qbe_table_error(output, "InvalidBuffer");
        return;
    }
    memcpy(&slice, source, sizeof(slice));
    if (!slice.length && !slice.data) return;
    if (!slice.data || slice.length > SIZE_MAX / element_size) {
        foo_qbe_table_error(output, "InvalidBuffer");
        return;
    }
    foo_qbe_text_enter();
    foo_qbe_allocation *entry = foo_qbe_detach(&foo_qbe_sequence_allocations,
        slice.data, (size_t)(slice.length * element_size));
    foo_qbe_text_leave();
    if (!entry) {
        foo_qbe_table_error(output, "UnknownBuffer");
        return;
    }
    free(entry->backing);
    free(entry);
}

static void foo_qbe_sequence_cleanup(void) {
    foo_qbe_free(&foo_qbe_sequence_allocations);
}

#include "qbe-codec.h"

void foo_qbe_join(void *output, const void *left, const void *right) {
    foo_qbe_slice a, b, joined;
    memcpy(&a, left, sizeof(a));
    memcpy(&b, right, sizeof(b));
    if (a.length > SIZE_MAX || b.length > SIZE_MAX ||
        b.length > SIZE_MAX - a.length)
        foo_qbe_panic("IntegerOverflow");
    if ((a.length && !a.data) || (b.length && !b.data))
        foo_qbe_panic("InvalidSlice");
    foo_qbe_text_enter();
    if (!foo_qbe_text_registered) {
        if (atexit(foo_qbe_text_cleanup) != 0) {
            foo_qbe_text_leave();
            foo_qbe_panic("OutOfMemory");
        }
        foo_qbe_text_registered = 1;
    }
    unsigned char *bytes = foo_qbe_reserve(&foo_qbe_text_allocations,
        a.length + b.length, 1);
    foo_qbe_text_leave();
    if (!bytes) foo_qbe_panic("OutOfMemory");
    if (a.length) memcpy(bytes, a.data, (size_t)a.length);
    if (b.length) memcpy(bytes + a.length, b.data, (size_t)b.length);
    joined = (foo_qbe_slice){bytes, a.length + b.length};
    memcpy(output, &joined, sizeof(joined));
}

void foo_qbe_packed_write(void *destination, uint64_t offset,
    uint64_t width, uint64_t value) {
    if (!destination || width > 64) foo_qbe_panic("InvalidPackedField");
    unsigned char *bytes = destination;
    for (uint64_t bit = 0; bit < width; ++bit) {
        uint64_t position = offset + bit;
        unsigned char mask = (unsigned char)(1u << (position & 7));
        if ((value >> bit) & 1) bytes[position >> 3] |= mask;
        else bytes[position >> 3] &= (unsigned char)~mask;
    }
}

uint64_t foo_qbe_packed_read(const void *source, uint64_t offset,
    uint64_t width) {
    if (!source || width > 64) foo_qbe_panic("InvalidPackedField");
    const unsigned char *bytes = source;
    uint64_t value = 0;
    for (uint64_t bit = 0; bit < width; ++bit) {
        uint64_t position = offset + bit;
        value |= (uint64_t)((bytes[position >> 3] >> (position & 7)) & 1)
            << bit;
    }
    return value;
}

void foo_qbe_packed_copy(void *destination, uint64_t offset,
    const void *source, uint64_t width) {
    if (!destination || !source || width > 128)
        foo_qbe_panic("InvalidPackedField");
    unsigned char *to = destination;
    const unsigned char *from = source;
    for (uint64_t bit = 0; bit < width; ++bit) {
        uint64_t position = offset + bit;
        unsigned char mask = (unsigned char)(1u << (position & 7));
        if ((from[bit >> 3] >> (bit & 7)) & 1) to[position >> 3] |= mask;
        else to[position >> 3] &= (unsigned char)~mask;
    }
}

void foo_qbe_packed_extract(void *destination, const void *source,
    uint64_t offset, uint64_t width) {
    if (!destination || !source || width > 128)
        foo_qbe_panic("InvalidPackedField");
    unsigned char *to = destination;
    const unsigned char *from = source;
    memset(to, 0, (size_t)((width + 7) / 8));
    for (uint64_t bit = 0; bit < width; ++bit) {
        uint64_t position = offset + bit;
        to[bit >> 3] |= (unsigned char)(((from[position >> 3] >>
            (position & 7)) & 1u) << (bit & 7));
    }
}

void foo_qbe_packed_extract_integer(void *destination, const void *source,
    uint64_t offset, uint64_t width, int signed_field) {
    if (!destination || width <= 64 || width > 128)
        foo_qbe_panic("InvalidPackedField");
    foo_qbe_packed_extract(destination, source, offset, width);
    unsigned char *bytes = destination;
    unsigned sign = signed_field &&
        ((bytes[(width - 1) >> 3] >> ((width - 1) & 7)) & 1u);
    for (uint64_t bit = width; bit < 128; ++bit) {
        unsigned char mask = (unsigned char)(1u << (bit & 7));
        if (sign) bytes[bit >> 3] |= mask;
        else bytes[bit >> 3] &= (unsigned char)~mask;
    }
}

int foo_qbe_packed_compare(const void *left, const void *right,
    uint64_t offset, uint64_t width, int signed_field) {
    if (!left || !right || width == 0 || width > 128 ||
        offset > UINT64_MAX - width)
        foo_qbe_panic("InvalidPackedField");
    const unsigned char *a = left;
    const unsigned char *b = right;
    for (uint64_t bit = width; bit > 0; --bit) {
        uint64_t position = offset + bit - 1;
        unsigned av = (a[position >> 3] >> (position & 7)) & 1u;
        unsigned bv = (b[position >> 3] >> (position & 7)) & 1u;
        if (av != bv) {
            int order = av < bv ? -1 : 1;
            return signed_field && bit == width ? -order : order;
        }
    }
    return 0;
}

#endif

#ifdef FOO_QBE_INTEGER_ONLY
void *memset(void *destination, int value, size_t size) {
    unsigned char *to = destination;
    for (size_t index = 0; index < size; ++index)
        to[index] = (unsigned char)value;
    return destination;
}
void *memmove(void *destination, const void *source, size_t size) {
    unsigned char *to = destination;
    const unsigned char *from = source;
    if ((size_t)to < (size_t)from) {
        for (size_t index = 0; index < size; ++index) to[index] = from[index];
    } else if ((size_t)to > (size_t)from) {
        for (size_t index = size; index > 0; --index)
            to[index - 1] = from[index - 1];
    }
    return destination;
}
static void *foo_qbe_integer_copy(void *destination, const void *source,
    size_t size) {
    unsigned char *to = destination;
    const unsigned char *from = source;
    for (size_t index = 0; index < size; ++index) to[index] = from[index];
    return destination;
}
#define memcpy foo_qbe_integer_copy
static void foo_qbe_panic(const char *message) {
    (void)message;
    for (;;) { }
}
#endif

typedef struct { uint64_t low, high; } foo_qbe_u128;

static foo_qbe_u128 foo_qbe_mask(unsigned width) {
    foo_qbe_u128 mask;
    mask.low = width >= 64 ? UINT64_MAX : (UINT64_C(1) << width) - 1;
    mask.high = width <= 64 ? 0 : width == 128 ? UINT64_MAX :
        (UINT64_C(1) << (width - 64)) - 1;
    return mask;
}

static foo_qbe_u128 foo_qbe_trim(foo_qbe_u128 value, unsigned width) {
    foo_qbe_u128 mask = foo_qbe_mask(width);
    value.low &= mask.low;
    value.high &= mask.high;
    return value;
}

static int foo_qbe_bit(foo_qbe_u128 value, unsigned bit) {
    return bit < 64 ? (int)((value.low >> bit) & 1) :
        (int)((value.high >> (bit - 64)) & 1);
}

static foo_qbe_u128 foo_qbe_add128(foo_qbe_u128 a, foo_qbe_u128 b,
    int *carry) {
    foo_qbe_u128 out;
    out.low = a.low + b.low;
    out.high = a.high + b.high + (out.low < a.low);
    if (carry) *carry = out.high < a.high ||
        (out.low < a.low && out.high == a.high);
    return out;
}

static foo_qbe_u128 foo_qbe_sub128(foo_qbe_u128 a, foo_qbe_u128 b) {
    foo_qbe_u128 out;
    out.low = a.low - b.low;
    out.high = a.high - b.high - (a.low < b.low);
    return out;
}

static int foo_qbe_cmp128(foo_qbe_u128 a, foo_qbe_u128 b) {
    if (a.high != b.high) return a.high < b.high ? -1 : 1;
    if (a.low != b.low) return a.low < b.low ? -1 : 1;
    return 0;
}

static foo_qbe_u128 foo_qbe_neg128(foo_qbe_u128 value) {
    foo_qbe_u128 zero = {0, 0};
    return foo_qbe_sub128(zero, value);
}

static foo_qbe_u128 foo_qbe_canonical(foo_qbe_u128 value,
    unsigned width, int signed_value) {
    value = foo_qbe_trim(value, width);
    if (signed_value && foo_qbe_bit(value, width - 1)) {
        foo_qbe_u128 mask = foo_qbe_mask(width);
        value.low |= ~mask.low;
        value.high |= ~mask.high;
    }
    return value;
}

static foo_qbe_u128 foo_qbe_mul128(foo_qbe_u128 a, foo_qbe_u128 b,
    int *overflow) {
    foo_qbe_u128 out = {0, 0};
    *overflow = 0;
    for (unsigned bit = 0; bit < 128; ++bit) {
        if (foo_qbe_bit(b, bit)) {
            foo_qbe_u128 shifted;
            if (bit == 0) shifted = a;
            else if (bit < 64) {
                shifted.low = a.low << bit;
                shifted.high = (a.high << bit) | (a.low >> (64 - bit));
                if (a.high >> (64 - bit)) *overflow = 1;
            } else if (bit == 64) {
                shifted.low = 0;
                shifted.high = a.low;
                if (a.high) *overflow = 1;
            } else {
                shifted.low = 0;
                shifted.high = a.low << (bit - 64);
                if (a.high || a.low >> (128 - bit)) *overflow = 1;
            }
            int carry = 0;
            out = foo_qbe_add128(out, shifted, &carry);
            if (carry) *overflow = 1;
        }
    }
    return out;
}

static void foo_qbe_div128(foo_qbe_u128 a, foo_qbe_u128 b,
    foo_qbe_u128 *quotient, foo_qbe_u128 *remainder) {
    foo_qbe_u128 q = {0, 0}, r = {0, 0};
    for (unsigned bit = 128; bit > 0; --bit) {
        int carry = (int)(r.high >> 63);
        r.high = (r.high << 1) | (r.low >> 63);
        r.low = (r.low << 1) | (unsigned)foo_qbe_bit(a, bit - 1);
        if (carry || foo_qbe_cmp128(r, b) >= 0) {
            r = foo_qbe_sub128(r, b);
            if (bit > 64) q.high |= UINT64_C(1) << (bit - 65);
            else q.low |= UINT64_C(1) << (bit - 1);
        }
    }
    *quotient = q;
    *remainder = r;
}

/* Operations: 0 add, 1 subtract, 2 multiply, 3 divide, 4 remainder. */
static int foo_qbe_integer_core(foo_qbe_u128 a, foo_qbe_u128 b,
    unsigned width, int signed_value, unsigned operation,
    foo_qbe_u128 *output) {
    if (!output || width < 1 || width > 128 || operation > 4)
        foo_qbe_panic("InvalidIntegerOperation");
    a = foo_qbe_trim(a, width);
    b = foo_qbe_trim(b, width);
    int negative_a = signed_value && foo_qbe_bit(a, width - 1);
    int negative_b = signed_value && foo_qbe_bit(b, width - 1);
    foo_qbe_u128 mask = foo_qbe_mask(width);
    foo_qbe_u128 raw = {0, 0};
    int overflow = 0;
    if (operation == 0 || operation == 1) {
        int carry = 0;
        raw = operation == 0 ? foo_qbe_add128(a, b, &carry) :
            foo_qbe_sub128(a, b);
        foo_qbe_u128 trimmed = foo_qbe_trim(raw, width);
        if (signed_value) {
            int sign = foo_qbe_bit(trimmed, width - 1);
            overflow = operation == 0 ?
                (negative_a == negative_b && sign != negative_a) :
                (negative_a != negative_b && sign != negative_a);
        } else {
            overflow = operation == 0 ?
                (carry || foo_qbe_cmp128(raw, trimmed) != 0) :
                foo_qbe_cmp128(a, b) < 0;
        }
    } else if (operation == 2) {
        foo_qbe_u128 magnitude_a = negative_a ?
            foo_qbe_trim(foo_qbe_neg128(a), width) : a;
        foo_qbe_u128 magnitude_b = negative_b ?
            foo_qbe_trim(foo_qbe_neg128(b), width) : b;
        raw = foo_qbe_mul128(magnitude_a, magnitude_b, &overflow);
        foo_qbe_u128 limit = mask;
        if (signed_value) {
            limit = width <= 64 ?
                (foo_qbe_u128){UINT64_C(1) << (width - 1), 0} :
                (foo_qbe_u128){0, UINT64_C(1) << (width - 65)};
            if (negative_a == negative_b) {
                limit = foo_qbe_sub128(limit, (foo_qbe_u128){1, 0});
            }
        }
        if (foo_qbe_cmp128(raw, limit) > 0) overflow = 1;
        if (negative_a != negative_b) raw = foo_qbe_neg128(raw);
    } else {
        if (!b.low && !b.high) return 2;
        foo_qbe_u128 magnitude_a = negative_a ?
            foo_qbe_trim(foo_qbe_neg128(a), width) : a;
        foo_qbe_u128 magnitude_b = negative_b ?
            foo_qbe_trim(foo_qbe_neg128(b), width) : b;
        foo_qbe_u128 quotient, remainder;
        foo_qbe_div128(magnitude_a, magnitude_b, &quotient, &remainder);
        if (operation == 3) {
            raw = negative_a != negative_b ?
                foo_qbe_neg128(quotient) : quotient;
            overflow = signed_value && negative_a &&
                foo_qbe_bit(a, width - 1) &&
                a.low == (width <= 64 ? UINT64_C(1) << (width - 1) : 0) &&
                a.high == (width > 64 ? UINT64_C(1) << (width - 65) : 0) &&
                b.low == mask.low && b.high == mask.high;
        } else {
            raw = negative_a ? foo_qbe_neg128(remainder) : remainder;
        }
    }
    if (overflow) return 1;
    *output = foo_qbe_canonical(raw, width, signed_value);
    return 0;
}

int foo_qbe_integer64(uint64_t a, uint64_t b, unsigned width,
    int signed_value, unsigned operation, uint64_t *output) {
    foo_qbe_u128 result;
    int error = foo_qbe_integer_core((foo_qbe_u128){a, 0},
        (foo_qbe_u128){b, 0}, width, signed_value, operation, &result);
    if (!error && output) *output = result.low;
    return error;
}

int foo_qbe_integer128(const void *left, const void *right,
    unsigned width, int signed_value, unsigned operation, void *output) {
    foo_qbe_u128 a, b, result;
    if (!left || !right || !output || width <= 64 || width > 128)
        foo_qbe_panic("InvalidIntegerOperation");
    memcpy(&a, left, sizeof(a));
    memcpy(&b, right, sizeof(b));
    int error = foo_qbe_integer_core(a, b, width, signed_value,
        operation, &result);
    if (!error) memcpy(output, &result, sizeof(result));
    return error;
}

int foo_qbe_integer_compare64(uint64_t a, uint64_t b,
    unsigned width, int signed_value) {
    if (width < 1 || width > 64) foo_qbe_panic("InvalidIntegerOperation");
    foo_qbe_u128 left = foo_qbe_trim((foo_qbe_u128){a, 0}, width);
    foo_qbe_u128 right = foo_qbe_trim((foo_qbe_u128){b, 0}, width);
    int order = foo_qbe_cmp128(left, right);
    if (signed_value && foo_qbe_bit(left, width - 1) !=
        foo_qbe_bit(right, width - 1)) order = -order;
    return order;
}

int foo_qbe_integer_compare128(const void *left, const void *right,
    unsigned width, int signed_value) {
    if (!left || !right || width <= 64 || width > 128)
        foo_qbe_panic("InvalidIntegerOperation");
    foo_qbe_u128 a, b;
    memcpy(&a, left, sizeof(a));
    memcpy(&b, right, sizeof(b));
    a = foo_qbe_trim(a, width);
    b = foo_qbe_trim(b, width);
    int order = foo_qbe_cmp128(a, b);
    if (signed_value && foo_qbe_bit(a, width - 1) !=
        foo_qbe_bit(b, width - 1)) order = -order;
    return order;
}

uint64_t foo_qbe_integer_extend64(uint64_t input, unsigned source_width,
    int signed_source, unsigned target_width) {
    if (source_width < 1 || source_width > 64 ||
        target_width < source_width || target_width > 64)
        foo_qbe_panic("InvalidIntegerConversion");
    foo_qbe_u128 value = foo_qbe_canonical((foo_qbe_u128){input, 0},
        source_width, signed_source);
    return value.low;
}

void foo_qbe_integer_extend128(void *output, uint64_t input,
    unsigned source_width, int signed_source) {
    if (!output || source_width < 1 || source_width > 64)
        foo_qbe_panic("InvalidIntegerConversion");
    foo_qbe_u128 value = foo_qbe_canonical((foo_qbe_u128){input, 0},
        source_width, signed_source);
    memcpy(output, &value, sizeof(value));
}

/* Operations: and, or, xor, not, shl, lshr, ashr, set, clear, toggle. */
static int foo_qbe_integer_bit_core(foo_qbe_u128 a, foo_qbe_u128 b,
    unsigned width, int signed_value, unsigned operation, uint64_t count,
    foo_qbe_u128 *output) {
    if (!output || width < 1 || width > 128 || operation > 9)
        foo_qbe_panic("InvalidBitOperation");
    a = foo_qbe_trim(a, width);
    b = foo_qbe_trim(b, width);
    foo_qbe_u128 raw = {0, 0};
    if (operation == 0 || operation == 1 || operation == 2) {
        raw.low = operation == 0 ? a.low & b.low :
            operation == 1 ? a.low | b.low : a.low ^ b.low;
        raw.high = operation == 0 ? a.high & b.high :
            operation == 1 ? a.high | b.high : a.high ^ b.high;
    } else if (operation == 3) {
        raw.low = ~a.low;
        raw.high = ~a.high;
    } else {
        if (count >= width) return 1;
        if (operation >= 7) {
            raw = a;
            foo_qbe_u128 mask = count < 64 ?
                (foo_qbe_u128){UINT64_C(1) << count, 0} :
                (foo_qbe_u128){0, UINT64_C(1) << (count - 64)};
            if (operation == 7) {
                raw.low |= mask.low;
                raw.high |= mask.high;
            } else if (operation == 8) {
                raw.low &= ~mask.low;
                raw.high &= ~mask.high;
            } else {
                raw.low ^= mask.low;
                raw.high ^= mask.high;
            }
        } else {
            int sign = operation == 6 && foo_qbe_bit(a, width - 1);
            for (unsigned bit = 0; bit < width; ++bit) {
                int source = operation == 4 ?
                    (bit >= count && foo_qbe_bit(a, bit - (unsigned)count)) :
                    (bit + count < width ? foo_qbe_bit(a, bit + (unsigned)count) :
                        sign);
                if (source) {
                    if (bit < 64) raw.low |= UINT64_C(1) << bit;
                    else raw.high |= UINT64_C(1) << (bit - 64);
                }
            }
        }
    }
    *output = foo_qbe_canonical(raw, width, signed_value);
    return 0;
}

int foo_qbe_integer_bit64(uint64_t a, uint64_t b, unsigned width,
    int signed_value, unsigned operation, uint64_t count, uint64_t *output) {
    foo_qbe_u128 value;
    int error = foo_qbe_integer_bit_core((foo_qbe_u128){a, 0},
        (foo_qbe_u128){b, 0}, width, signed_value, operation, count, &value);
    if (!error && output) *output = value.low;
    return error;
}

int foo_qbe_integer_bit128(const void *left, const void *right,
    unsigned width, int signed_value, unsigned operation,
    uint64_t count, void *output) {
    foo_qbe_u128 a, b, value;
    if (!left || !right || !output || width <= 64 || width > 128)
        foo_qbe_panic("InvalidBitOperation");
    memcpy(&a, left, sizeof(a));
    memcpy(&b, right, sizeof(b));
    int error = foo_qbe_integer_bit_core(a, b, width, signed_value, operation,
        count, &value);
    if (!error) memcpy(output, &value, sizeof(value));
    return error;
}

#ifndef FOO_QBE_INTEGER_ONLY
#define FOO_QBE_VOLATILE_WIDTH(bits, unsigned_type) \
uint64_t foo_qbe_volatile_load##bits(const volatile void *address) { \
    return *(const volatile unsigned_type *)address; \
} \
void foo_qbe_volatile_store##bits(volatile void *address, uint64_t value) { \
    *(volatile unsigned_type *)address = (unsigned_type)value; \
}

FOO_QBE_VOLATILE_WIDTH(8, uint8_t)
FOO_QBE_VOLATILE_WIDTH(16, uint16_t)
FOO_QBE_VOLATILE_WIDTH(32, uint32_t)
FOO_QBE_VOLATILE_WIDTH(64, uint64_t)

void foo_qbe_volatile_read(void *destination, const volatile void *source,
    uint64_t size) {
    unsigned char *to = destination;
    const volatile unsigned char *from = source;
    for (uint64_t index = 0; index < size; ++index) to[index] = from[index];
}

void foo_qbe_volatile_write(volatile void *destination, const void *source,
    uint64_t size) {
    volatile unsigned char *to = destination;
    const unsigned char *from = source;
    for (uint64_t index = 0; index < size; ++index) to[index] = from[index];
}

typedef struct { const char *error; void *value; } foo_qbe_result_ptr;
typedef struct { const char *error; unsigned char value; } foo_qbe_result_void;
typedef struct { void (*task)(void); } foo_qbe_thread_start;
typedef struct {
#if defined(_WIN32)
    HANDLE handle;
#else
    pthread_t handle;
#endif
    int joined;
} foo_qbe_thread_handle;
typedef struct {
#if defined(_WIN32)
    CRITICAL_SECTION value;
#else
    pthread_mutex_t value;
#endif
} foo_qbe_mutex_handle;
typedef struct {
#if defined(_WIN32)
    CONDITION_VARIABLE value;
#else
    pthread_cond_t value;
#endif
} foo_qbe_condition_handle;

#if defined(_WIN32)
static DWORD WINAPI foo_qbe_thread_entry(LPVOID context) {
#else
static void *foo_qbe_thread_entry(void *context) {
#endif
    foo_qbe_thread_start *start = context;
    void (*task)(void) = start->task;
    free(start);
    task();
#if defined(_WIN32)
    return 0;
#else
    return NULL;
#endif
}

foo_qbe_result_ptr foo_qbe_thread_spawn(void (*task)(void)) {
    if (!task) return (foo_qbe_result_ptr){"InvalidThreadTask", NULL};
    foo_qbe_thread_handle *handle = calloc(1, sizeof(*handle));
    foo_qbe_thread_start *start = malloc(sizeof(*start));
    if (!handle || !start) {
        free(handle); free(start);
        return (foo_qbe_result_ptr){"OutOfMemory", NULL};
    }
    start->task = task;
#if defined(_WIN32)
    handle->handle = CreateThread(NULL, 0, foo_qbe_thread_entry,
        start, 0, NULL);
    if (!handle->handle) {
#else
    if (pthread_create(&handle->handle, NULL, foo_qbe_thread_entry,
        start) != 0) {
#endif
        free(start); free(handle);
        return (foo_qbe_result_ptr){"ThreadSpawnFailed", NULL};
    }
    return (foo_qbe_result_ptr){NULL, handle};
}

foo_qbe_result_void foo_qbe_thread_wait(void *resource) {
    foo_qbe_thread_handle *handle = resource;
    if (!handle || handle->joined)
        return (foo_qbe_result_void){"InvalidThreadHandle", 0};
#if defined(_WIN32)
    if (WaitForSingleObject(handle->handle, INFINITE) != WAIT_OBJECT_0)
#else
    if (pthread_join(handle->handle, NULL) != 0)
#endif
        return (foo_qbe_result_void){"ThreadWaitFailed", 0};
    handle->joined = 1;
    return (foo_qbe_result_void){NULL, 0};
}

foo_qbe_result_ptr foo_qbe_thread_mutex(void) {
    foo_qbe_mutex_handle *handle = malloc(sizeof(*handle));
    if (!handle) return (foo_qbe_result_ptr){"OutOfMemory", NULL};
#if defined(_WIN32)
    InitializeCriticalSection(&handle->value);
#else
    if (pthread_mutex_init(&handle->value, NULL) != 0) {
        free(handle);
        return (foo_qbe_result_ptr){"MutexInitFailed", NULL};
    }
#endif
    return (foo_qbe_result_ptr){NULL, handle};
}

foo_qbe_result_void foo_qbe_thread_lock(void *resource) {
    if (!resource) return (foo_qbe_result_void){"InvalidMutex", 0};
    foo_qbe_mutex_handle *handle = resource;
#if defined(_WIN32)
    EnterCriticalSection(&handle->value);
#else
    if (pthread_mutex_lock(&handle->value) != 0)
        return (foo_qbe_result_void){"MutexLockFailed", 0};
#endif
    return (foo_qbe_result_void){NULL, 0};
}

foo_qbe_result_void foo_qbe_thread_unlock(void *resource) {
    if (!resource) return (foo_qbe_result_void){"InvalidMutex", 0};
    foo_qbe_mutex_handle *handle = resource;
#if defined(_WIN32)
    LeaveCriticalSection(&handle->value);
#else
    if (pthread_mutex_unlock(&handle->value) != 0)
        return (foo_qbe_result_void){"MutexUnlockFailed", 0};
#endif
    return (foo_qbe_result_void){NULL, 0};
}

foo_qbe_result_ptr foo_qbe_thread_condition(void) {
    foo_qbe_condition_handle *handle = malloc(sizeof(*handle));
    if (!handle) return (foo_qbe_result_ptr){"OutOfMemory", NULL};
#if defined(_WIN32)
    InitializeConditionVariable(&handle->value);
#else
    if (pthread_cond_init(&handle->value, NULL) != 0) {
        free(handle);
        return (foo_qbe_result_ptr){"ConditionInitFailed", NULL};
    }
#endif
    return (foo_qbe_result_ptr){NULL, handle};
}

foo_qbe_result_void foo_qbe_thread_signal(void *resource) {
    if (!resource) return (foo_qbe_result_void){"InvalidCondition", 0};
    foo_qbe_condition_handle *handle = resource;
#if defined(_WIN32)
    WakeConditionVariable(&handle->value);
#else
    if (pthread_cond_signal(&handle->value) != 0)
        return (foo_qbe_result_void){"ConditionSignalFailed", 0};
#endif
    return (foo_qbe_result_void){NULL, 0};
}

foo_qbe_result_void foo_qbe_thread_pause(void *condition, void *mutex) {
    if (!condition || !mutex)
        return (foo_qbe_result_void){"InvalidCondition", 0};
    foo_qbe_condition_handle *event = condition;
    foo_qbe_mutex_handle *guard = mutex;
#if defined(_WIN32)
    if (!SleepConditionVariableCS(&event->value, &guard->value, INFINITE))
#else
    if (pthread_cond_wait(&event->value, &guard->value) != 0)
#endif
        return (foo_qbe_result_void){"ConditionWaitFailed", 0};
    return (foo_qbe_result_void){NULL, 0};
}

foo_qbe_result_void foo_qbe_thread_close_thread(void *resource) {
    foo_qbe_thread_handle *handle = resource;
    if (!handle) return (foo_qbe_result_void){"InvalidThreadHandle", 0};
#if defined(_WIN32)
    CloseHandle(handle->handle);
#else
    if (!handle->joined && pthread_detach(handle->handle) != 0)
        return (foo_qbe_result_void){"ThreadCloseFailed", 0};
#endif
    free(handle);
    return (foo_qbe_result_void){NULL, 0};
}

foo_qbe_result_void foo_qbe_thread_close_guard(void *resource) {
    foo_qbe_mutex_handle *handle = resource;
    if (!handle) return (foo_qbe_result_void){"InvalidMutex", 0};
#if defined(_WIN32)
    DeleteCriticalSection(&handle->value);
#else
    if (pthread_mutex_destroy(&handle->value) != 0)
        return (foo_qbe_result_void){"MutexCloseFailed", 0};
#endif
    free(handle);
    return (foo_qbe_result_void){NULL, 0};
}

foo_qbe_result_void foo_qbe_thread_close_event(void *resource) {
    foo_qbe_condition_handle *handle = resource;
    if (!handle) return (foo_qbe_result_void){"InvalidCondition", 0};
#if !defined(_WIN32)
    if (pthread_cond_destroy(&handle->value) != 0)
        return (foo_qbe_result_void){"ConditionCloseFailed", 0};
#endif
    free(handle);
    return (foo_qbe_result_void){NULL, 0};
}

void foo_qbe_thread_spawn_out(foo_qbe_result_ptr *out, void (*task)(void)) {
    *out = foo_qbe_thread_spawn(task);
}

void foo_qbe_thread_mutex_out(foo_qbe_result_ptr *out) {
    *out = foo_qbe_thread_mutex();
}

void foo_qbe_thread_condition_out(foo_qbe_result_ptr *out) {
    *out = foo_qbe_thread_condition();
}

#define FOO_QBE_THREAD_OUT1(name) \
    void foo_qbe_thread_##name##_out(foo_qbe_result_void *out, void *resource) { \
        *out = foo_qbe_thread_##name(resource); \
    }

FOO_QBE_THREAD_OUT1(wait)
FOO_QBE_THREAD_OUT1(lock)
FOO_QBE_THREAD_OUT1(unlock)
FOO_QBE_THREAD_OUT1(signal)
FOO_QBE_THREAD_OUT1(close_thread)
FOO_QBE_THREAD_OUT1(close_guard)
FOO_QBE_THREAD_OUT1(close_event)

void foo_qbe_thread_pause_out(foo_qbe_result_void *out, void *condition,
    void *mutex) {
    *out = foo_qbe_thread_pause(condition, mutex);
}

#undef FOO_QBE_THREAD_OUT1

#if defined(__TINYC__) && !defined(__x86_64__)
static pthread_mutex_t foo_qbe_atomic_lock = PTHREAD_MUTEX_INITIALIZER;

static void foo_qbe_atomic_enter(int order) {
    if (order < 0 || order > 4) foo_qbe_panic("InvalidAtomicOrder");
    if (pthread_mutex_lock(&foo_qbe_atomic_lock) != 0)
        foo_qbe_panic("AtomicLockFailed");
}

static void foo_qbe_atomic_leave(void) {
    if (pthread_mutex_unlock(&foo_qbe_atomic_lock) != 0)
        foo_qbe_panic("AtomicUnlockFailed");
}

void foo_qbe_atomic_fence(int order) {
    foo_qbe_atomic_enter(order);
    foo_qbe_atomic_leave();
}

#define FOO_QBE_ATOMIC_WIDTH(bits, unsigned_type) \
uint64_t foo_qbe_atomic_load##bits(void *address, int order) { \
    foo_qbe_atomic_enter(order); \
    unsigned_type value = *(volatile unsigned_type *)address; \
    foo_qbe_atomic_leave(); \
    return value; \
} \
void foo_qbe_atomic_store##bits(void *address, uint64_t value, int order) { \
    foo_qbe_atomic_enter(order); \
    *(volatile unsigned_type *)address = (unsigned_type)value; \
    foo_qbe_atomic_leave(); \
} \
uint64_t foo_qbe_atomic_add##bits(void *address, uint64_t value, int order) { \
    foo_qbe_atomic_enter(order); \
    unsigned_type previous = *(volatile unsigned_type *)address; \
    *(volatile unsigned_type *)address = previous + (unsigned_type)value; \
    foo_qbe_atomic_leave(); \
    return previous; \
} \
uint64_t foo_qbe_atomic_sub##bits(void *address, uint64_t value, int order) { \
    foo_qbe_atomic_enter(order); \
    unsigned_type previous = *(volatile unsigned_type *)address; \
    *(volatile unsigned_type *)address = previous - (unsigned_type)value; \
    foo_qbe_atomic_leave(); \
    return previous; \
} \
uint64_t foo_qbe_atomic_swap##bits(void *address, uint64_t value, int order) { \
    foo_qbe_atomic_enter(order); \
    unsigned_type previous = *(volatile unsigned_type *)address; \
    *(volatile unsigned_type *)address = (unsigned_type)value; \
    foo_qbe_atomic_leave(); \
    return previous; \
}
#else
static int foo_qbe_order(int order) {
    switch (order) {
    case 0: return __ATOMIC_RELAXED;
    case 1: return __ATOMIC_ACQUIRE;
    case 2: return __ATOMIC_RELEASE;
    case 3: return __ATOMIC_ACQ_REL;
    case 4: return __ATOMIC_SEQ_CST;
    default: foo_qbe_panic("InvalidAtomicOrder");
    }
    return __ATOMIC_SEQ_CST;
}

void foo_qbe_atomic_fence(int order) {
    __atomic_thread_fence(foo_qbe_order(order));
}

#define FOO_QBE_ATOMIC_WIDTH(bits, unsigned_type) \
uint64_t foo_qbe_atomic_load##bits(void *address, int order) { \
    return __atomic_load_n((unsigned_type *)address, foo_qbe_order(order)); \
} \
void foo_qbe_atomic_store##bits(void *address, uint64_t value, int order) { \
    __atomic_store_n((unsigned_type *)address, (unsigned_type)value, \
        foo_qbe_order(order)); \
} \
uint64_t foo_qbe_atomic_add##bits(void *address, uint64_t value, int order) { \
    return __atomic_fetch_add((unsigned_type *)address, (unsigned_type)value, \
        foo_qbe_order(order)); \
} \
uint64_t foo_qbe_atomic_sub##bits(void *address, uint64_t value, int order) { \
    return __atomic_fetch_sub((unsigned_type *)address, (unsigned_type)value, \
        foo_qbe_order(order)); \
} \
uint64_t foo_qbe_atomic_swap##bits(void *address, uint64_t value, int order) { \
    unsigned_type desired = (unsigned_type)value, previous = 0; \
    __atomic_exchange((unsigned_type *)address, &desired, &previous, \
        foo_qbe_order(order)); \
    return previous; \
}
#endif

FOO_QBE_ATOMIC_WIDTH(8, uint8_t)
FOO_QBE_ATOMIC_WIDTH(16, uint16_t)
FOO_QBE_ATOMIC_WIDTH(32, uint32_t)
FOO_QBE_ATOMIC_WIDTH(64, uint64_t)

static int foo_qbe_atomic_mode(const void *source) {
    foo_qbe_slice text;
    if (!source) return -1;
    memcpy(&text, source, sizeof(text));
    if (text.length && !text.data) return -1;
    static const char *names[] = {
        "relaxed", "acquire", "release", "both", "sequential"
    };
    static const size_t lengths[] = {7, 7, 7, 4, 10};
    for (int index = 0; index < 5; ++index)
        if (text.length == lengths[index] &&
            memcmp(text.data, names[index], lengths[index]) == 0)
            return index;
    return -1;
}

static int foo_qbe_atomic_cas64(void *address, uint64_t expected,
    uint64_t desired, int success, int failure) {
#if defined(__TINYC__) && !defined(__x86_64__)
    foo_qbe_atomic_enter(success);
    int matched = *(volatile uint64_t *)address == expected;
    if (matched) *(volatile uint64_t *)address = desired;
    foo_qbe_atomic_leave();
    (void)failure;
    return matched;
#else
    return __atomic_compare_exchange_n((uint64_t *)address, &expected,
        desired, 0, foo_qbe_order(success), foo_qbe_order(failure));
#endif
}

void foo_qbe_atomic_create_out(foo_qbe_result_ptr *out, uint64_t value) {
    uint64_t *atom = malloc(sizeof(*atom));
    if (!atom) { out->error = "OutOfMemory"; return; }
    foo_qbe_atomic_store64(atom, value, 0);
    out->value = atom;
}

void foo_qbe_atomic_release(void *value) { free(value); }

void foo_qbe_atomic_load_out(void *out, void *value, const void *mode) {
    int order = foo_qbe_atomic_mode(mode);
    if (order < 0) { foo_qbe_text_error(out, "InvalidAtomicOrder"); return; }
    if (order == 2 || order == 3) {
        foo_qbe_text_error(out, "InvalidLoadOrder"); return;
    }
    if (!value) { foo_qbe_text_error(out, "InvalidAtom"); return; }
    uint64_t result = foo_qbe_atomic_load64(value, order);
    memcpy((unsigned char *)out + 8, &result, sizeof(result));
}

void foo_qbe_atomic_store_out(void *out, void *value, uint64_t number,
    const void *mode) {
    int order = foo_qbe_atomic_mode(mode);
    if (order < 0) { foo_qbe_text_error(out, "InvalidAtomicOrder"); return; }
    if (order == 1 || order == 3) {
        foo_qbe_text_error(out, "InvalidStoreOrder"); return;
    }
    if (!value) { foo_qbe_text_error(out, "InvalidAtom"); return; }
    foo_qbe_atomic_store64(value, number, order);
}

#define FOO_QBE_ATOMIC_FETCH(name, primitive) \
void foo_qbe_atomic_##name##_out(void *out, void *value, uint64_t number, \
    const void *mode) { \
    int order = foo_qbe_atomic_mode(mode); \
    if (order < 0) { foo_qbe_text_error(out, "InvalidAtomicOrder"); return; } \
    if (!value) { foo_qbe_text_error(out, "InvalidAtom"); return; } \
    uint64_t result = foo_qbe_atomic_##primitive##64(value, number, order); \
    memcpy((unsigned char *)out + 8, &result, sizeof(result)); \
}
FOO_QBE_ATOMIC_FETCH(add, add)
FOO_QBE_ATOMIC_FETCH(deduct, sub)
FOO_QBE_ATOMIC_FETCH(swap, swap)
#undef FOO_QBE_ATOMIC_FETCH

void foo_qbe_atomic_replace_out(void *out, void *value, uint64_t expected,
    uint64_t number, const void *mode) {
    int order = foo_qbe_atomic_mode(mode);
    if (order < 0) { foo_qbe_text_error(out, "InvalidAtomicOrder"); return; }
    if (!value) { foo_qbe_text_error(out, "InvalidAtom"); return; }
    int failure = order == 2 ? 0 : order == 3 ? 1 : order;
    *((unsigned char *)out + 8) =
        foo_qbe_atomic_cas64(value, expected, number, order, failure);
}

void foo_qbe_atomic_compare_out(void *out, void *value, uint64_t expected,
    uint64_t number, const void *success_source, const void *failure_source) {
    int success = foo_qbe_atomic_mode(success_source);
    int failure = foo_qbe_atomic_mode(failure_source);
    if (success < 0 || failure < 0 || failure == 2 || failure == 3 ||
        (failure == 1 && success != 1 && success != 3 && success != 4) ||
        (failure == 4 && success != 4)) {
        foo_qbe_text_error(out, "InvalidAtomicOrder"); return;
    }
    if (!value) { foo_qbe_text_error(out, "InvalidAtom"); return; }
    *((unsigned char *)out + 8) =
        foo_qbe_atomic_cas64(value, expected, number, success, failure);
}

#if !defined(__linux__)
int64_t foo_qbe_syscall6(uint64_t number, uint64_t a1, uint64_t a2,
    uint64_t a3, uint64_t a4, uint64_t a5, uint64_t a6) {
    (void)number; (void)a1; (void)a2; (void)a3;
    (void)a4; (void)a5; (void)a6;
    foo_qbe_panic("UnsupportedSyscallTarget");
    return -1;
}
#endif

#endif /* FOO_QBE_INTEGER_ONLY */
