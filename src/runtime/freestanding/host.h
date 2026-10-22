#ifndef FOO_FREESTANDING_HOST_H
#define FOO_FREESTANDING_HOST_H

#include <stdint.h>

#define FOO_FREESTANDING_ABI_VERSION 1u

/* Successful calls return bytes transferred (zero for control operations). */
enum foo_freestanding_operation {
  FOO_HOST_QUERY = 0,
  FOO_HOST_CONSOLE_READ = 1,
  FOO_HOST_CONSOLE_WRITE = 2,
  FOO_HOST_CLOCK_MONOTONIC = 3,
  FOO_HOST_CLOCK_WALL = 4,
  FOO_HOST_RANDOM = 5,
  FOO_HOST_FILE_OPEN = 6,
  FOO_HOST_FILE_READ = 7,
  FOO_HOST_FILE_WRITE = 8,
  FOO_HOST_FILE_CLOSE = 9,
  FOO_HOST_NET_CONNECT = 10,
  FOO_HOST_NET_SEND = 11,
  FOO_HOST_NET_RECEIVE = 12,
  FOO_HOST_NET_CLOSE = 13,
  FOO_HOST_YIELD = 14,
  FOO_HOST_SLEEP = 15
};

enum foo_freestanding_status {
  FOO_HOST_UNAVAILABLE = -1,
  FOO_HOST_INVALID = -2,
  FOO_HOST_IO = -3,
  FOO_HOST_AGAIN = -4
};

/* All byte sequences belong to the caller and are valid only for the call.
 * A null pointer is permitted only with a zero length/capacity. The callback
 * may retain context, but not request or response pointers. Multibyte values
 * in payloads are little-endian. See docs/freestanding.md for each payload.
 */
typedef int32_t (*foo_freestanding_call)(void *context, uint32_t operation,
    const uint8_t *request, uint32_t request_length,
    uint8_t *response, uint32_t response_capacity);

#endif
