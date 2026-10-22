#include <stdint.h>
#include <stdio.h>

typedef struct { const char *error; void *value; } ResultPtr;
typedef struct { const char *error; unsigned char value; } ResultVoid;

extern uint64_t foo_qbe_atomic_load32(void *, int);
extern void foo_qbe_atomic_store32(void *, uint64_t, int);
extern uint64_t foo_qbe_atomic_add32(void *, uint64_t, int);
extern uint64_t foo_qbe_atomic_swap32(void *, uint64_t, int);
extern void foo_qbe_atomic_fence(int);
extern ResultPtr foo_qbe_thread_spawn(void (*)(void));
extern ResultVoid foo_qbe_thread_wait(void *);
extern ResultVoid foo_qbe_thread_close_thread(void *);
extern ResultPtr foo_qbe_thread_mutex(void);
extern ResultVoid foo_qbe_thread_lock(void *);
extern ResultVoid foo_qbe_thread_unlock(void *);
extern ResultVoid foo_qbe_thread_close_guard(void *);

static uint32_t cell = 7;
static void increment(void) {
    (void)foo_qbe_atomic_add32(&cell, 1, 4);
}

int main(void) {
    if (foo_qbe_atomic_load32(&cell, 4) != 7) return 1;
    if (foo_qbe_atomic_add32(&cell, 3, 4) != 7) return 2;
    if (foo_qbe_atomic_swap32(&cell, 2, 4) != 10) return 3;
    foo_qbe_atomic_store32(&cell, 0, 4);
    foo_qbe_atomic_fence(4);
    ResultPtr guard = foo_qbe_thread_mutex();
    if (guard.error || !guard.value) return 4;
    if (foo_qbe_thread_lock(guard.value).error) return 5;
    if (foo_qbe_thread_unlock(guard.value).error) return 6;
    ResultPtr worker = foo_qbe_thread_spawn(increment);
    if (worker.error || !worker.value) return 7;
    if (foo_qbe_thread_wait(worker.value).error) return 8;
    if (foo_qbe_atomic_load32(&cell, 4) != 1) return 9;
    if (foo_qbe_thread_close_thread(worker.value).error) return 10;
    if (foo_qbe_thread_close_guard(guard.value).error) return 11;
    puts("QBE TinyCC runtime probe: ok");
    return 0;
}
