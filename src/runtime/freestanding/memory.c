#include <stddef.h>

void *memset(void *destination, int value, size_t count) {
  unsigned char *bytes = destination;
  for (size_t index = 0; index < count; index++) bytes[index] = (unsigned char)value;
  return destination;
}
