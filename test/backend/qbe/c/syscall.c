#include <stdint.h>
#include <stdio.h>
#include <unistd.h>

extern int64_t foo_probe_linux_getpid(void);

int main(void) {
    if (foo_probe_linux_getpid() != (int64_t)getpid()) return 1;
    puts("QBE syscall probe: ok");
    return 0;
}
