#include <stdint.h>
#include <stdio.h>

typedef struct { const char *error; void *value; } ResultPtr;
typedef struct { const char *error; unsigned char value; } ResultVoid;

extern void *foreign_atomic_cell(void);
extern unsigned int foreign_atomic_add(unsigned int);
extern unsigned int foreign_atomic_load(void);
extern void *foreign_atomic_cell8(void);
extern void *foreign_atomic_cell16(void);
extern void *foreign_atomic_cell64(void);
extern uint8_t foreign_atomic_add8(uint8_t);
extern uint16_t foreign_atomic_add16(uint16_t);
extern uint64_t foreign_atomic_add64(uint64_t);
extern uint8_t foreign_atomic_load8(void);
extern uint16_t foreign_atomic_load16(void);
extern uint64_t foreign_atomic_load64(void);
extern uint64_t foo_qbe_atomic_add8(void *, uint64_t, int);
extern uint64_t foo_qbe_atomic_add16(void *, uint64_t, int);
extern uint64_t foo_qbe_atomic_add32(void *, uint64_t, int);
extern uint64_t foo_qbe_atomic_add64(void *, uint64_t, int);
extern ResultPtr foo_qbe_thread_spawn(void (*)(void));
extern ResultVoid foo_qbe_thread_wait(void *);
extern ResultVoid foo_qbe_thread_close_thread(void *);

static void increment(void) {
    for (int index = 0; index < 10000; ++index) {
        foreign_atomic_add(1);
        foo_qbe_atomic_add32(foreign_atomic_cell(), 1, 4);
        foreign_atomic_add8(1);
        foo_qbe_atomic_add8(foreign_atomic_cell8(), 1, 4);
        foreign_atomic_add16(1);
        foo_qbe_atomic_add16(foreign_atomic_cell16(), 1, 4);
        foreign_atomic_add64(1);
        foo_qbe_atomic_add64(foreign_atomic_cell64(), 1, 4);
    }
}

int main(void) {
    void *workers[4];
    for (int index = 0; index < 4; ++index) {
        ResultPtr worker = foo_qbe_thread_spawn(increment);
        if (worker.error || !worker.value) return 1;
        workers[index] = worker.value;
    }
    for (int index = 0; index < 4; ++index) {
        if (foo_qbe_thread_wait(workers[index]).error) return 2;
        if (foo_qbe_thread_close_thread(workers[index]).error) return 3;
    }
    if (foreign_atomic_load() != 80000 ||
        foreign_atomic_load8() != (uint8_t)80000 ||
        foreign_atomic_load16() != (uint16_t)80000 ||
        foreign_atomic_load64() != 80000) return 4;
    puts("QBE foreign atomic interoperability: ok");
    return 0;
}
