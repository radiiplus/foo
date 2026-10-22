#ifdef FOO_WASI_HOST_BRIDGE
__attribute__((import_module("foo_host"), import_name("dial")))
extern int32_t foo_host_net_open(uint32_t host, uint32_t length,
  uint32_t port, uint32_t listener);
__attribute__((import_module("foo_host"), import_name("net_accept")))
extern int32_t foo_host_net_accept(int32_t socket);
__attribute__((import_module("foo_host"), import_name("net_port")))
extern int32_t foo_host_net_port(int32_t socket);
__attribute__((import_module("foo_host"), import_name("transmit")))
extern int32_t foo_host_net_write(int32_t socket, uint32_t content,
  uint32_t length);
__attribute__((import_module("foo_host"), import_name("net_read")))
extern int32_t foo_host_net_read(int32_t socket, uint32_t destination,
  uint32_t length);
__attribute__((import_module("foo_host"), import_name("net_shutdown")))
extern int32_t foo_host_net_shutdown(int32_t socket, int32_t direction);
__attribute__((import_module("foo_host"), import_name("net_latency")))
extern int32_t foo_host_net_latency(int32_t socket, int32_t enabled);
__attribute__((import_module("foo_host"), import_name("net_probe")))
extern int32_t foo_host_net_probe(int32_t socket, int32_t enabled);
__attribute__((import_module("foo_host"), import_name("net_close")))
extern int32_t foo_host_net_close(int32_t socket);

typedef struct { int32_t id; int listener; } Socket;

static FooResult dial(FooText host, uint64_t port, int listener) {
  if (port > 65535) return failure(BOUNDS);
  if ((host.len && !host.data) || host.len > UINT32_MAX ||
      (host.len && memchr(host.data, 0, (size_t)host.len)))
    return failure(ARGUMENT);
  int32_t id = foo_host_net_open((uint32_t)(uintptr_t)host.data,
    (uint32_t)host.len, (uint32_t)port, (uint32_t)listener);
  if (id < 0) return failure(-id);
  Socket *socket = owned(sizeof(*socket), SOCKET_RESOURCE);
  if (!socket) { foo_host_net_close(id); return failure(MEMORY); }
  *socket = (Socket){id, listener};
  return (FooResult){.pointer = socket};
}
FooResult foo_net_connect(FooText host, uint64_t port) {
  return dial(host, port, 0);
}
FooResult foo_net_listen(FooText host, uint64_t port) {
  return dial(host, port, 1);
}
FooResult foo_net_accept(void *pointer) {
  if (!entry(pointer, SOCKET_RESOURCE)) return failure(CLOSED);
  Socket *listener = pointer;
  if (!listener->listener) return failure(ARGUMENT);
  int32_t id = foo_host_net_accept(listener->id);
  if (id < 0) return failure(-id);
  Socket *socket = owned(sizeof(*socket), SOCKET_RESOURCE);
  if (!socket) { foo_host_net_close(id); return failure(MEMORY); }
  *socket = (Socket){id, 0};
  return (FooResult){.pointer = socket};
}
FooResult foo_net_port(void *pointer) {
  if (!entry(pointer, SOCKET_RESOURCE)) return failure(CLOSED);
  int32_t value = foo_host_net_port(((Socket *)pointer)->id);
  return value < 0 ? failure(-value) :
    (FooResult){.number = (uint32_t)value};
}
static FooResult transmit(void *pointer, FooText content, int complete) {
  if (!entry(pointer, SOCKET_RESOURCE)) return failure(CLOSED);
  Socket *socket = pointer;
  if (socket->listener || (content.len && !content.data))
    return failure(ARGUMENT);
  uint64_t sent = 0;
  while (sent < content.len) {
    uint32_t size = content.len - sent > 1048576 ? 1048576 :
      (uint32_t)(content.len - sent);
    int32_t count = foo_host_net_write(socket->id,
      (uint32_t)(uintptr_t)(content.data + sent), size);
    if (count <= 0) return failure(IO);
    sent += (uint32_t)count;
    if (!complete) break;
  }
  return (FooResult){.number = sent};
}
FooResult foo_net_send(void *pointer, FooText content) {
  return transmit(pointer, content, 1);
}
FooResult foo_net_push(void *pointer, FooText content) {
  return transmit(pointer, content, 0);
}
FooResult foo_net_receive(void *pointer, uint64_t size) {
  if (!entry(pointer, SOCKET_RESOURCE)) return failure(CLOSED);
  Socket *socket = pointer;
  if (socket->listener) return failure(ARGUMENT);
  if (!size) return (FooResult){0};
  uint32_t count = size > 1048576 ? 1048576 : (uint32_t)size;
  uint8_t *bytes = malloc(count);
  if (!bytes) return failure(MEMORY);
  int32_t read = foo_host_net_read(socket->id, (uint32_t)(uintptr_t)bytes,
    count);
  FooResult result = read < 0 ? failure(-read) :
    copied(bytes, (size_t)read);
  free(bytes);
  return result;
}
FooResult foo_net_shutdown(void *pointer, FooText direction) {
  if (!entry(pointer, SOCKET_RESOURCE)) return failure(CLOSED);
  Socket *socket = pointer;
  if (socket->listener || (direction.len && !direction.data))
    return failure(ARGUMENT);
  int mode = direction.len == 5 && !memcmp(direction.data, "write", 5) ? 1 :
    direction.len == 4 && !memcmp(direction.data, "both", 4) ? 2 : -1;
  if (mode < 0) return failure(ARGUMENT);
  int32_t status = foo_host_net_shutdown(socket->id, mode);
  return status < 0 ? failure(-status) : (FooResult){0};
}
FooResult foo_net_latency(void *pointer, bool enabled) {
  if (!entry(pointer, SOCKET_RESOURCE)) return failure(CLOSED);
  int32_t status = foo_host_net_latency(((Socket *)pointer)->id,
    enabled ? 1 : 0);
  return status < 0 ? failure(-status) : (FooResult){0};
}
FooResult foo_net_probe(void *pointer, bool enabled) {
  if (!entry(pointer, SOCKET_RESOURCE)) return failure(CLOSED);
  int32_t status = foo_host_net_probe(((Socket *)pointer)->id,
    enabled ? 1 : 0);
  return status < 0 ? failure(-status) : (FooResult){0};
}
FooResult foo_net_close(void *pointer) {
  Entry *item = entry(pointer, SOCKET_RESOURCE);
  if (!item) return failure(CLOSED);
  int32_t status = foo_host_net_close(((Socket *)pointer)->id);
  if (status >= 0) retire(item);
  return status < 0 ? failure(-status) : (FooResult){0};
}
#endif
