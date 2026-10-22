#include <math.h>
#include <pthread.h>
#include <stdatomic.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>

extern double negative_zero __asm__("storage.negative_zero");
typedef struct { const unsigned char *data; uint64_t length; } Slice;
extern Slice text __asm__("storage.text");
typedef struct { unsigned char present; unsigned char padding[3]; int32_t value; } Optional;
extern Optional present __asm__("storage.present");
typedef struct { void *error; int32_t value; } Failable;
extern Failable failure_free __asm__("storage.failure_free");
extern int32_t qbe_tls_get(void);
extern void qbe_tls_set(int32_t);
extern int32_t qbe_vector_add(void);
typedef struct { int32_t count; double amount; } Record;
extern Record static_record __asm__("storage.static_record");
extern _Bool qbe_record_equal(Record, Record);
extern _Bool qbe_record_less(Record, Record);
typedef union { int64_t number; double decimal; } NumberUnion;
extern int64_t qbe_union_read(NumberUnion);
extern uint32_t qbe_tagged_tag(void);
extern int32_t qbe_packed_high(void);
extern int32_t qbe_volatile_roundtrip(volatile int32_t *);
extern uint8_t qbe_join_byte(void);
typedef struct { const char *error; void *value; } ThreadResult;
typedef struct { const char *error; unsigned char value; } CompletionResult;
extern ThreadResult qbe_thread_spawn_task(void (*)(void));
extern CompletionResult qbe_thread_wait_task(void *);
extern CompletionResult qbe_thread_close_task(void *);
static _Atomic int completed;
static void finish_task(void) { atomic_fetch_add(&completed, 1); }

static void *worker(void *unused) {
    (void)unused;
    if (qbe_tls_get() != 5) return (void *)1;
    qbe_tls_set(17);
    return qbe_tls_get() == 17 ? NULL : (void *)2;
}

int main(void) {
    Record left, right;
    memset(&left, 0xaa, sizeof(left));
    memset(&right, 0x55, sizeof(right));
    left.count = right.count = 7;
    left.amount = right.amount = 2.5;
    if (!signbit(negative_zero) || negative_zero != 0.0 ||
        text.length != 3 || text.data[0] != 'a' || text.data[2] != 'c' ||
        present.present != 1 || present.value != 7 ||
        failure_free.error != NULL || failure_free.value != 9 ||
        static_record.count != 7 || static_record.amount != 2.5 ||
        qbe_tls_get() != 5 || qbe_vector_add() != 66 ||
        !qbe_record_equal(left, right)) return 1;
    right.count = 8;
    NumberUnion mixed = {.number = 391};
    volatile int32_t observed = -29;
    if (!qbe_record_less(left, right) || qbe_record_equal(left, right) ||
        qbe_union_read(mixed) != 391 || qbe_tagged_tag() != 1 ||
        qbe_packed_high() != -7 ||
        qbe_volatile_roundtrip(&observed) != -29 || observed != -29 ||
        qbe_join_byte() != 'd')
        return 4;
    qbe_tls_set(23);
    pthread_t thread;
    if (pthread_create(&thread, NULL, worker, NULL)) return 2;
    void *outcome = NULL;
    if (pthread_join(thread, &outcome) || outcome || qbe_tls_get() != 23)
        return 3;
    ThreadResult spawned = qbe_thread_spawn_task(finish_task);
    if (spawned.error || !spawned.value) return 5;
    CompletionResult waited = qbe_thread_wait_task(spawned.value);
    if (waited.error || atomic_load(&completed) != 1) return 6;
    CompletionResult closed = qbe_thread_close_task(spawned.value);
    if (closed.error) return 7;
    puts("QBE storage probe: ok");
    return 0;
}
