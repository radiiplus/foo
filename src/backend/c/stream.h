#include <errno.h>
#include <limits.h>
#if defined(_WIN32)
#include <fcntl.h>
#include <io.h>
#endif
typedef struct {
  int channel;
} FOOStream;
static FOOStream foo_incoming = {0}, foo_outgoing = {1}, foo_diagnostic = {2};
static bool foo_stream_valid(void *value) {
  return value == &foo_incoming || value == &foo_outgoing ||
         value == &foo_diagnostic;
}
static void *foo_stream_input(void) { return &foo_incoming; }
static void *foo_stream_output(void) { return &foo_outgoing; }
static void *foo_stream_report(void) { return &foo_diagnostic; }
static FOOResult foo_stream_write(void *handle, FOOText content) {
  if (!foo_stream_valid(handle))
    return foo_error("UnknownStream");
  FOOStream *value = handle;
  if (!value->channel)
    return foo_error("ReadOnly");
  FILE *file = value->channel == 1 ? stdout : stderr;
#if defined(_WIN32)
  if (_setmode(_fileno(file), _O_BINARY) == -1)
    return foo_error("WriteFailed");
#endif
  size_t offset = 0;
  while (offset < content.len) {
    size_t count = fwrite(content.data + offset, 1, content.len - offset, file);
    if (!count)
      return foo_error("WriteFailed");
    offset += count;
  }
  return fflush(file) ? foo_error("WriteFailed") : (FOOResult){0};
}
static FOOResult foo_stream_print(void *value, FOOText content) {
  return foo_stream_write(value, content);
}
static FOOResult foo_stream_read(void *handle, uint8_t *pointer,
                                 uint64_t size) {
  if (!foo_stream_valid(handle))
    return foo_error("UnknownStream");
  if (((FOOStream *)handle)->channel)
    return foo_error("WriteOnly");
  FOOResult buffer = foo_bytes(pointer, size);
  if (buffer.error || !size)
    return buffer;
#if defined(_WIN32)
  if (_setmode(_fileno(stdin), _O_BINARY) == -1)
    return foo_error("ReadFailed");
  int count;
  do {
    count = _read(_fileno(stdin), pointer,
                  size > INT_MAX ? INT_MAX : (unsigned)size);
  } while (count < 0 && errno == EINTR);
#else
  ssize_t count;
  do {
    count = read(STDIN_FILENO, pointer, (size_t)size);
  } while (count < 0 && errno == EINTR);
#endif
  return count < 0 ? foo_error("ReadFailed")
                   : (FOOResult){.number = (uint64_t)count};
}
static FOOResult foo_stream_close(void *handle) {
  if (!foo_stream_valid(handle))
    return foo_error("UnknownStream");
  int channel = ((FOOStream *)handle)->channel;
  /* Borrowed standard descriptors remain open for the rest of the process. */
  if (channel && fflush(channel == 1 ? stdout : stderr))
    return foo_error("WriteFailed");
  return (FOOResult){0};
}
