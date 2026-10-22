#include <stdio.h>

extern double qbe_sse_probe(double first, double second);

int main(void) {
    if (qbe_sse_probe(3.25, 2.5) != 5.0) return 1;
    puts("QBE TinyCC SSE probe: ok");
    return 0;
}
