#include <stdatomic.h>
#include <stdint.h>

static unsigned int shared_cell;
static uint8_t shared_byte;
static uint16_t shared_half;
static uint64_t shared_wide;

void *foreign_atomic_cell(void) { return &shared_cell; }

unsigned int foreign_atomic_add(unsigned int value) {
    return __atomic_fetch_add(&shared_cell, value, __ATOMIC_SEQ_CST);
}

unsigned int foreign_atomic_load(void) {
    return __atomic_load_n(&shared_cell, __ATOMIC_SEQ_CST);
}

void *foreign_atomic_cell8(void) { return &shared_byte; }
void *foreign_atomic_cell16(void) { return &shared_half; }
void *foreign_atomic_cell64(void) { return &shared_wide; }

uint8_t foreign_atomic_add8(uint8_t value) {
    return __atomic_fetch_add(&shared_byte, value, __ATOMIC_SEQ_CST);
}

uint16_t foreign_atomic_add16(uint16_t value) {
    return __atomic_fetch_add(&shared_half, value, __ATOMIC_SEQ_CST);
}

uint64_t foreign_atomic_add64(uint64_t value) {
    return __atomic_fetch_add(&shared_wide, value, __ATOMIC_SEQ_CST);
}

uint8_t foreign_atomic_load8(void) {
    return __atomic_load_n(&shared_byte, __ATOMIC_SEQ_CST);
}

uint16_t foreign_atomic_load16(void) {
    return __atomic_load_n(&shared_half, __ATOMIC_SEQ_CST);
}

uint64_t foreign_atomic_load64(void) {
    return __atomic_load_n(&shared_wide, __ATOMIC_SEQ_CST);
}
