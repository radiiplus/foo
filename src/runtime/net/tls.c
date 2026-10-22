typedef struct {
#ifdef _WIN32
  HMODULE library;
#else
  void *library;
#endif
  const void *(*TLS_client_method)(void);
  void *(*SSL_CTX_new)(const void *);
  void (*SSL_CTX_free)(void *);
  int (*SSL_CTX_set_default_verify_paths)(void *);
  void (*SSL_CTX_set_verify)(void *, int, void *);
  void *(*SSL_new)(void *);
  void (*SSL_free)(void *);
  int (*SSL_set1_host)(void *, const char *);
  long (*SSL_ctrl)(void *, int, long, void *);
  int (*SSL_set_fd)(void *, int);
  int (*SSL_connect)(void *);
  int (*SSL_get_error)(const void *, int);
  long (*SSL_get_verify_result)(const void *);
  int (*SSL_write)(void *, const void *, int);
  int (*SSL_read)(void *, void *, int);
  int (*SSL_shutdown)(void *);
} Api;
typedef struct {
  void *context;
  void *session;
  void *socket;
} Session;
static Api tls_api;
static int tls_state;
static void *resolve(const char *name) {
#ifdef _WIN32
  return (void *)GetProcAddress(tls_api.library, name);
#else
  return dlsym(tls_api.library, name);
#endif
}
static int load(void) {
  enter();
  if (tls_state) { int ready = tls_state > 0; leave(); return ready; }
  const char *configured = getenv("FOO_TLS_LIBRARY");
#ifdef _WIN32
  const char *names[] = {"libssl-3-x64.dll", "libssl-3.dll", "libssl.dll"};
#elif defined(__APPLE__)
  const char *names[] = {"libssl.3.dylib", "libssl.dylib"};
#else
  const char *names[] = {"libssl.so.3", "libssl.so.1.1", "libssl.so"};
#endif
  size_t count = sizeof(names) / sizeof(names[0]);
  for (size_t index = 0; index < (configured ? 1 : count); index++) {
    const char *name = configured ? configured : names[index];
#ifdef _WIN32
    tls_api.library = configured
        ? LoadLibraryExA(name, NULL, LOAD_WITH_ALTERED_SEARCH_PATH)
        : LoadLibraryExA(name, NULL, LOAD_LIBRARY_SEARCH_DEFAULT_DIRS);
#else
    tls_api.library = dlopen(name, RTLD_NOW | RTLD_LOCAL);
#endif
    if (tls_api.library) break;
  }
  if (!tls_api.library) { tls_state = -1; leave(); return 0; }
  int ready = 1;
#define TLS_ASSIGN(name) do { void *symbol = resolve(#name); \
  memcpy(&tls_api.name, &symbol, sizeof(symbol)); if (!symbol) ready = 0; } while (0)
  TLS_ASSIGN(TLS_client_method);
  TLS_ASSIGN(SSL_CTX_new);
  TLS_ASSIGN(SSL_CTX_free);
  TLS_ASSIGN(SSL_CTX_set_default_verify_paths);
  TLS_ASSIGN(SSL_CTX_set_verify);
  TLS_ASSIGN(SSL_new);
  TLS_ASSIGN(SSL_free);
  TLS_ASSIGN(SSL_set1_host);
  TLS_ASSIGN(SSL_ctrl);
  TLS_ASSIGN(SSL_set_fd);
  TLS_ASSIGN(SSL_connect);
  TLS_ASSIGN(SSL_get_error);
  TLS_ASSIGN(SSL_get_verify_result);
  TLS_ASSIGN(SSL_write);
  TLS_ASSIGN(SSL_read);
  TLS_ASSIGN(SSL_shutdown);
#undef TLS_ASSIGN
  if (!ready) {
#ifdef _WIN32
    FreeLibrary(tls_api.library);
#else
    dlclose(tls_api.library);
#endif
    memset(&tls_api, 0, sizeof(tls_api));
  }
  tls_state = ready ? 1 : -1;
  leave();
  return ready;
}
FooResult foo_tls_available(void) {
  return (FooResult){.number = (uint64_t)load()};
}
FooResult foo_tls_connect(FooText host, uint64_t port) {
  if (!host.data || !host.len || !port || port > 65535) return failure(ARGUMENT);
  if (!load()) return failure(SYSTEM);
  char *name = string(host);
  if (!name) return failure(ARGUMENT);
  FooResult socket = network(host, port, 0);
  if (socket.error) { free(name); return socket; }
  Socket handle = ((Connection *)socket.pointer)->socket;
  FooText receive = {(const uint8_t *)"receive", 7};
  FooText send = {(const uint8_t *)"send", 4};
  if (timeout(handle, receive, 30000).error ||
      timeout(handle, send, 30000).error) {
    free(name);
    foo_net_close(socket.pointer);
    return failure(IO);
  }
  void *context = tls_api.SSL_CTX_new(tls_api.TLS_client_method());
  void *session = NULL;
  if (context && tls_api.SSL_CTX_set_default_verify_paths(context)) {
    tls_api.SSL_CTX_set_verify(context, 1, NULL);
    session = tls_api.SSL_new(context);
  }
  int valid = session && handle <= INT_MAX &&
    tls_api.SSL_set1_host(session, name) == 1 &&
    tls_api.SSL_ctrl(session, 55, 0, name) == 1 &&
    tls_api.SSL_set_fd(session, (int)handle) == 1 &&
    tls_api.SSL_connect(session) == 1 &&
    tls_api.SSL_get_verify_result(session) == 0;
  free(name);
  if (!valid) {
    if (session) tls_api.SSL_free(session);
    if (context) tls_api.SSL_CTX_free(context);
    foo_net_close(socket.pointer);
    return failure(IO);
  }
  Session *result = owned(sizeof(*result), TLS_CONNECTIONS);
  if (!result) {
    tls_api.SSL_free(session);
    tls_api.SSL_CTX_free(context);
    foo_net_close(socket.pointer);
    return failure(MEMORY);
  }
  result->context = context;
  result->session = session;
  result->socket = socket.pointer;
  return (FooResult){.pointer = result};
}
FooResult foo_tls_send(void *pointer, FooText content) {
  if (!resource(pointer, TLS_CONNECTIONS)) return failure(CLOSED);
  if (!content.data && content.len) return failure(ARGUMENT);
  Session *connection = pointer;
  size_t sent = 0;
  while (sent < content.len) {
    size_t size = content.len - sent;
    if (size > INT_MAX) size = INT_MAX;
    int count = tls_api.SSL_write(connection->session, content.data + sent,
                                  (int)size);
    if (count <= 0) return failure(IO);
    sent += (size_t)count;
  }
  return (FooResult){.number = sent};
}
FooResult foo_tls_receive(void *pointer, uint64_t size) {
  if (!resource(pointer, TLS_CONNECTIONS)) return failure(CLOSED);
  if (size > INT_MAX) return failure(BOUNDS);
  if (!size) return (FooResult){0};
  void *buffer = malloc((size_t)size);
  if (!buffer) return failure(MEMORY);
  void *session = ((Session *)pointer)->session;
  int count = tls_api.SSL_read(session, buffer, (int)size);
  int problem = count <= 0 ? tls_api.SSL_get_error(session, count) : 0;
  FooResult result = count > 0 ? text(buffer, (size_t)count) :
      problem == 6 ? (FooResult){0} : failure(IO);
  free(buffer);
  return result;
}
FooResult foo_tls_timeout(void *pointer, FooText direction,
                          uint64_t milliseconds) {
  if (!resource(pointer, TLS_CONNECTIONS)) return failure(CLOSED);
  Connection *socket = ((Session *)pointer)->socket;
  return timeout(socket->socket, direction, milliseconds);
}
FooResult foo_tls_close(void *pointer) {
  Resource *entry = resource(pointer, TLS_CONNECTIONS);
  if (!entry) return failure(CLOSED);
  Session *connection = pointer;
  tls_api.SSL_shutdown(connection->session);
  tls_api.SSL_free(connection->session);
  tls_api.SSL_CTX_free(connection->context);
  FooResult closed = foo_net_close(connection->socket);
  entry->closed = 1;
  return closed;
}
