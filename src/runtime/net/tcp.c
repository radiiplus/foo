static FooResult network(FooText host, uint64_t port, int server) {
  if (port > 65535)
    return failure(BOUNDS);
  if (!initialize()) return failure(SYSTEM);
  char *name = string(host), service[6];
  if (!name)
    return failure(ARGUMENT);
  snprintf(service, sizeof(service), "%u", (unsigned)port);
  struct addrinfo hints = {0}, *addresses = NULL;
  hints.ai_family = AF_UNSPEC;
  hints.ai_socktype = SOCK_STREAM;
  hints.ai_flags = server ? AI_PASSIVE : 0;
  int error = getaddrinfo(*name ? name : NULL, service, &hints, &addresses);
  free(name);
  if (error)
    return failure(SYSTEM);
  Socket handle = INVALID;
  for (struct addrinfo *address = addresses; address;
       address = address->ai_next) {
    handle =
        socket(address->ai_family, address->ai_socktype, address->ai_protocol);
    if (handle == INVALID)
      continue;
    int enabled = 1;
#ifdef SO_NOSIGPIPE
    setsockopt(handle, SOL_SOCKET, SO_NOSIGPIPE, (const void *)&enabled,
               sizeof(enabled));
#endif
    if (server)
      setsockopt(handle, SOL_SOCKET, SO_REUSEADDR, (const void *)&enabled,
                 sizeof(enabled));
    int result =
        server ? bind(handle, address->ai_addr, (int)address->ai_addrlen)
               : connect(handle, address->ai_addr, (int)address->ai_addrlen);
    if (!result && (!server || !listen(handle, 128)))
      break;
    disconnect(handle);
    handle = INVALID;
  }
  freeaddrinfo(addresses);
  return handle == INVALID ? failure(IO) : connection(handle);
}
FooResult foo_net_connect(FooText host, uint64_t port) {
  return network(host, port, 0);
}
FooResult foo_net_listen(FooText host, uint64_t port) {
  return network(host, port, 1);
}
static FooResult ipv6(uint64_t high, uint64_t low, uint64_t port,
                              uint64_t scope, int server) {
  if (port > 65535 || scope > UINT32_MAX) return failure(BOUNDS);
  if (!initialize()) return failure(SYSTEM);
  Socket handle = socket(AF_INET6, SOCK_STREAM, IPPROTO_TCP);
  if (handle == INVALID) return failure(IO);
  struct sockaddr_in6 address = {0};
  address.sin6_family = AF_INET6;
  address.sin6_port = htons((uint16_t)port);
  address.sin6_scope_id = (uint32_t)scope;
  for (int index = 7; index >= 0; index--) {
    address.sin6_addr.s6_addr[index] = (uint8_t)high;
    address.sin6_addr.s6_addr[index + 8] = (uint8_t)low;
    high >>= 8;
    low >>= 8;
  }
#ifdef SO_NOSIGPIPE
  int no_signal = 1;
  setsockopt(handle, SOL_SOCKET, SO_NOSIGPIPE, (const char *)&no_signal,
             sizeof(no_signal));
#endif
  if (server) {
    int reuse = 1;
    setsockopt(handle, SOL_SOCKET, SO_REUSEADDR, (const char *)&reuse,
               sizeof(reuse));
  }
  int error = server
      ? bind(handle, (struct sockaddr *)&address, sizeof(address))
      : connect(handle, (struct sockaddr *)&address, sizeof(address));
  if (!error && server) error = listen(handle, 128);
  if (error) { disconnect(handle); return failure(IO); }
  return connection(handle);
}
FooResult foo_net_establish(uint64_t high, uint64_t low, uint64_t port,
                              uint64_t scope) {
  return ipv6(high, low, port, scope, 0);
}
FooResult foo_net_host(uint64_t high, uint64_t low, uint64_t port,
                             uint64_t scope) {
  return ipv6(high, low, port, scope, 1);
}
FooResult foo_net_accept(void *pointer) {
  if (!resource(pointer, SOCKETS))
    return failure(CLOSED);
  Socket handle;
  do {
    handle = accept(((Connection *)pointer)->socket, NULL, NULL);
  } while (handle == INVALID && interrupted());
  return handle == INVALID ? failure(IO) : connection(handle);
}
FooResult foo_net_port(void *pointer) {
  if (!resource(pointer, SOCKETS))
    return failure(CLOSED);
  struct sockaddr_storage address;
#ifdef _WIN32
  int size = sizeof(address);
#else
  socklen_t size = sizeof(address);
#endif
  if (getsockname(((Connection *)pointer)->socket, (struct sockaddr *)&address,
                  &size))
    return failure(IO);
  return (FooResult){
      .number = ntohs(address.ss_family == AF_INET
                          ? ((struct sockaddr_in *)&address)->sin_port
                          : ((struct sockaddr_in6 *)&address)->sin6_port)};
}
FooResult foo_net_handle(void *pointer) {
  if (!resource(pointer, SOCKETS))
    return failure(CLOSED);
  return (FooResult){.number = (uint64_t)((Connection *)pointer)->socket};
}
FooResult foo_net_send(void *pointer, FooText value) {
  if (!resource(pointer, SOCKETS))
    return failure(CLOSED);
  size_t sent = 0;
  while (sent < value.len) {
    size_t chunk = value.len - sent;
    if (chunk > INT_MAX)
      chunk = INT_MAX;
#ifdef MSG_NOSIGNAL
    int flags = MSG_NOSIGNAL;
#else
    int flags = 0;
#endif
    int result = (int)send(((Connection *)pointer)->socket,
                           (const char *)value.data + sent, (int)chunk, flags);
    if (result < 0 && interrupted())
      continue;
    if (result <= 0)
      return failure(IO);
    sent += (size_t)result;
  }
  return (FooResult){.number = sent};
}
FooResult foo_net_push(void *pointer, FooText value) {
  if (!resource(pointer, SOCKETS))
    return failure(CLOSED);
  if (!value.len)
    return (FooResult){0};
  size_t size = value.len > INT_MAX ? INT_MAX : value.len;
#ifdef MSG_NOSIGNAL
  int flags = MSG_NOSIGNAL;
#else
  int flags = 0;
#endif
  int sent;
  do {
    sent = (int)send(((Connection *)pointer)->socket,
                     (const char *)value.data, (int)size, flags);
  } while (sent < 0 && interrupted());
  return sent <= 0 ? failure(IO) : (FooResult){.number = (uint64_t)sent};
}
FooResult foo_net_receive(void *pointer, uint64_t size) {
  if (!resource(pointer, SOCKETS))
    return failure(CLOSED);
  if (size > INT_MAX)
    return failure(BOUNDS);
  if (!size)
    return (FooResult){0};
  void *buffer = malloc((size_t)size);
  if (!buffer)
    return failure(MEMORY);
  int received;
  do {
    received = (int)recv(((Connection *)pointer)->socket, buffer, (int)size, 0);
  } while (received < 0 && interrupted());
  FooResult result =
      received < 0 ? failure(IO) : text(buffer, (size_t)received);
  free(buffer);
  return result;
}
FooResult foo_net_shutdown(void *pointer, FooText direction) {
  if (!resource(pointer, SOCKETS))
    return failure(CLOSED);
  int mode = direction.len == 4 && !memcmp(direction.data, "read", 4)    ? FOO_SHUT_READ
             : direction.len == 5 && !memcmp(direction.data, "write", 5) ? FOO_SHUT_WRITE
             : direction.len == 4 && !memcmp(direction.data, "both", 4)  ? FOO_SHUT_BOTH
                                                                           : -1;
  return mode < 0 ? failure(ARGUMENT)
                  : shutdown(((Connection *)pointer)->socket, mode)
                      ? failure(IO)
                      : (FooResult){0};
}
FooResult foo_net_latency(void *pointer, bool enabled) {
  if (!resource(pointer, SOCKETS))
    return failure(CLOSED);
  int value = enabled ? 1 : 0;
  return setsockopt(((Connection *)pointer)->socket, IPPROTO_TCP, TCP_NODELAY,
                    (const char *)&value, sizeof(value))
             ? failure(IO)
             : (FooResult){0};
}
FooResult foo_net_probe(void *pointer, bool enabled) {
  if (!resource(pointer, SOCKETS))
    return failure(CLOSED);
  int value = enabled ? 1 : 0;
  return setsockopt(((Connection *)pointer)->socket, SOL_SOCKET, SO_KEEPALIVE,
                    (const char *)&value, sizeof(value))
             ? failure(IO)
             : (FooResult){0};
}
static FooResult timeout(Socket handle, FooText direction,
                                uint64_t milliseconds) {
  int option = supports(direction, "send") ? SO_SNDTIMEO
      : supports(direction, "receive") ? SO_RCVTIMEO : -1;
  if (option < 0) return failure(ARGUMENT);
  if (milliseconds > INT_MAX) return failure(BOUNDS);
#ifdef _WIN32
  DWORD requested = (DWORD)milliseconds, effective = 0;
  int length = sizeof(effective);
#else
  struct timeval requested = {(time_t)(milliseconds / 1000),
                              (suseconds_t)((milliseconds % 1000) * 1000)};
  struct timeval effective = {0};
  socklen_t length = sizeof(effective);
#endif
  if (setsockopt(handle, SOL_SOCKET, option, (const char *)&requested,
                 sizeof(requested)) ||
      getsockopt(handle, SOL_SOCKET, option, (char *)&effective, &length))
    return failure(IO);
#ifdef _WIN32
  return (FooResult){.number = effective};
#else
  if (effective.tv_sec < 0 || effective.tv_usec < 0 ||
      (uint64_t)effective.tv_sec >
          (UINT64_MAX - ((uint64_t)effective.tv_usec + 999) / 1000) / 1000)
    return failure(SYSTEM);
  return (FooResult){.number = (uint64_t)effective.tv_sec * 1000 +
      ((uint64_t)effective.tv_usec + 999) / 1000};
#endif
}
FooResult foo_net_timeout(void *pointer, FooText direction,
                          uint64_t milliseconds) {
  if (!resource(pointer, SOCKETS)) return failure(CLOSED);
  return timeout(((Connection *)pointer)->socket, direction, milliseconds);
}
FooResult foo_net_close(void *pointer) {
  Resource *entry = resource(pointer, SOCKETS);
  if (!entry)
    return failure(CLOSED);
  int result = disconnect(((Connection *)pointer)->socket);
  entry->closed = 1;
  return result ? failure(IO) : (FooResult){0};
}
