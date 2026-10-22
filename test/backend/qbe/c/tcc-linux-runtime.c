#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <unistd.h>

extern int64_t foo_qbe_syscall6(uint64_t number, uint64_t a1, uint64_t a2,
    uint64_t a3, uint64_t a4, uint64_t a5, uint64_t a6);
extern void foo_qbe_system_cores(void *output);
extern void foo_qbe_text_concatenate(void *output, const void *left,
    const void *right);
extern void foo_qbe_text_find(void *output, const void *content,
    const void *needle);
extern void foo_qbe_text_release(void *output, const void *content);

typedef struct { const unsigned char *data; uint64_t length; } Slice;
typedef struct { const char *error; Slice value; } FailableText;
typedef struct { const char *error; uint32_t value; } FailableU32;
typedef struct { unsigned char present; unsigned char pad[7]; uint64_t value; } OptionalU64;
typedef struct { const char *error; unsigned char unused; } FailableVoid;

int main(void) {
#if defined(__aarch64__)
    const uint64_t getpid_number = 172;
#elif defined(__x86_64__)
    const uint64_t getpid_number = 39;
#else
#error Unsupported Linux probe target
#endif
    if (foo_qbe_syscall6(getpid_number, 0, 0, 0, 0, 0, 0) != getpid())
        return 1;
    FailableU32 cores = {0};
    foo_qbe_system_cores(&cores);
    if (cores.error || !cores.value) return 2;
    Slice first = {(const unsigned char *)"abcdefghijklmnop", 16};
    Slice second = {(const unsigned char *)"abcdefghijklmnop", 16};
    Slice needle = {(const unsigned char *)"mnop", 4};
    FailableText combined = {0};
    foo_qbe_text_concatenate(&combined, &first, &second);
    if (combined.error || combined.value.length != 32 ||
        memcmp(combined.value.data, first.data, 16) ||
        memcmp(combined.value.data + 16, second.data, 16)) return 3;
    OptionalU64 found = {0};
    foo_qbe_text_find(&found, &combined.value, &needle);
    if (!found.present || found.value != 12) return 4;
    FailableVoid released = {0};
    foo_qbe_text_release(&released, &combined.value);
    if (released.error) return 5;
    released.error = 0;
    foo_qbe_text_release(&released, &combined.value);
    if (!released.error) return 6;
    released.error = 0;
    foo_qbe_text_release(&released, &first);
    if (!released.error) return 7;
    puts("QBE Linux syscall probe: ok");
    return 0;
}
