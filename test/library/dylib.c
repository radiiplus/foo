#include <stdint.h>
#ifdef _WIN32
#define EXPORTED __declspec(dllexport)
#else
#define EXPORTED __attribute__((visibility("default")))
#endif
EXPORTED uint64_t increment(uint64_t value) { return value + 1; }
