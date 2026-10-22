typedef struct {
  uint8_t *data;
  size_t length;
  char host[INET6_ADDRSTRLEN];
  uint16_t port;
  struct sockaddr_storage address;
} Packet;
FooResult foo_net_bind(FooText host, uint64_t port) {
  if (port > 65535) return failure(BOUNDS);
  if (!initialize()) return failure(SYSTEM);
  char *name = string(host), service[6];
  if (!name) return failure(ARGUMENT);
  snprintf(service, sizeof(service), "%u", (unsigned)port);
  struct addrinfo hints = {0}, *addresses = NULL;
  hints.ai_family = AF_UNSPEC;
  hints.ai_socktype = SOCK_DGRAM;
  hints.ai_flags = AI_PASSIVE;
  int problem = getaddrinfo(*name ? name : NULL, service, &hints, &addresses);
  free(name);
  if (problem) return failure(SYSTEM);
  Socket handle = INVALID;
  for (struct addrinfo *address = addresses; address; address = address->ai_next) {
    handle = socket(address->ai_family, address->ai_socktype,
                    address->ai_protocol);
    if (handle != INVALID &&
        !bind(handle, address->ai_addr, (int)address->ai_addrlen)) break;
    if (handle != INVALID) disconnect(handle);
    handle = INVALID;
  }
  freeaddrinfo(addresses);
  return handle == INVALID ? failure(IO) : endpoint(handle, DATAGRAMS);
}
FooResult foo_net_local(void *pointer) {
  if (!resource(pointer, DATAGRAMS)) return failure(CLOSED);
  struct sockaddr_storage address;
#ifdef _WIN32
  int length = sizeof(address);
#else
  socklen_t length = sizeof(address);
#endif
  if (getsockname(((Connection *)pointer)->socket,
                  (struct sockaddr *)&address, &length)) return failure(IO);
  return (FooResult){.number = ntohs(address.ss_family == AF_INET
      ? ((struct sockaddr_in *)&address)->sin_port
      : ((struct sockaddr_in6 *)&address)->sin6_port)};
}
static int protocol(void *pointer) {
  struct sockaddr_storage address;
#ifdef _WIN32
  int length = sizeof(address);
#else
  socklen_t length = sizeof(address);
#endif
  return getsockname(((Connection *)pointer)->socket,
                     (struct sockaddr *)&address, &length) ? -1
                                                       : address.ss_family;
}
FooResult foo_net_egress(void *pointer, uint64_t index) {
  if (!resource(pointer, DATAGRAMS)) return failure(CLOSED);
  if (index > UINT32_MAX) return failure(BOUNDS);
  if (protocol(pointer) != AF_INET) return failure(ARGUMENT);
#ifdef IP_UNICAST_IF
  uint32_t selected = htonl((uint32_t)index);
  return setsockopt(((Connection *)pointer)->socket, IPPROTO_IP,
                    IP_UNICAST_IF, (const char *)&selected, sizeof(selected))
      ? failure(IO) : (FooResult){0};
#elif defined(IP_BOUND_IF)
  int selected = (int)index;
  return setsockopt(((Connection *)pointer)->socket, IPPROTO_IP,
                    IP_BOUND_IF, (const char *)&selected, sizeof(selected))
      ? failure(IO) : (FooResult){0};
#else
  return failure(SYSTEM);
#endif
}
FooResult foo_net_affiliate(void *pointer, FooText host, uint64_t port) {
  if (!resource(pointer, DATAGRAMS)) return failure(CLOSED);
  if (port > 65535) return failure(BOUNDS);
  int family = protocol(pointer);
  if (family != AF_INET && family != AF_INET6) return failure(IO);
  char *name = string(host), service[6];
  if (!name || !host.len) { free(name); return failure(ARGUMENT); }
  snprintf(service, sizeof(service), "%u", (unsigned)port);
  struct addrinfo hints = {0}, *addresses = NULL;
  hints.ai_family = family;
  hints.ai_socktype = SOCK_DGRAM;
  int problem = getaddrinfo(name, service, &hints, &addresses);
  free(name);
  if (problem) return failure(MISSING);
  int connected = -1;
  for (struct addrinfo *address = addresses; address; address = address->ai_next) {
    connected = connect(((Connection *)pointer)->socket, address->ai_addr,
                        (int)address->ai_addrlen);
    if (!connected) break;
  }
  freeaddrinfo(addresses);
  return connected ? failure(IO) : (FooResult){0};
}
FooResult foo_net_affiliate6(void *pointer, uint64_t high, uint64_t low,
                                 uint64_t port, uint64_t scope) {
  if (!resource(pointer, DATAGRAMS)) return failure(CLOSED);
  if (protocol(pointer) != AF_INET6 || scope > UINT32_MAX)
    return failure(ARGUMENT);
  if (port > 65535) return failure(BOUNDS);
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
  return connect(((Connection *)pointer)->socket, (struct sockaddr *)&address,
                 sizeof(address)) ? failure(IO) : (FooResult){0};
}
FooResult foo_net_submit(void *pointer, FooText content) {
  if (!resource(pointer, DATAGRAMS)) return failure(CLOSED);
  if (content.len > 65507) return failure(BOUNDS);
  if (content.len && !content.data) return failure(ARGUMENT);
  struct sockaddr_storage peer;
#ifdef _WIN32
  int length = sizeof(peer);
#else
  socklen_t length = sizeof(peer);
#endif
  if (getpeername(((Connection *)pointer)->socket,
                  (struct sockaddr *)&peer, &length)) return failure(ARGUMENT);
  int sent;
  do {
    sent = send(((Connection *)pointer)->socket,
                (const char *)(content.data ? content.data : (const uint8_t *)""),
                (int)content.len, 0);
  } while (sent < 0 && interrupted());
  return sent < 0 || (size_t)sent != content.len ? failure(IO)
      : (FooResult){.number = (uint64_t)sent};
}
FooResult foo_net_broadcast(void *pointer, bool enabled) {
  if (!resource(pointer, DATAGRAMS)) return failure(CLOSED);
  if (protocol(pointer) != AF_INET) return failure(ARGUMENT);
  int value = enabled ? 1 : 0;
  return setsockopt(((Connection *)pointer)->socket, SOL_SOCKET, SO_BROADCAST,
                    (const char *)&value, sizeof(value)) ? failure(IO)
                                                           : (FooResult){0};
}
static FooResult configure(void *pointer, int level, int option,
                               int value, bool change) {
  Socket handle = ((Connection *)pointer)->socket;
  if (change && setsockopt(handle, level, option, (const char *)&value,
                           sizeof(value))) return failure(IO);
  int actual = 0;
#ifdef _WIN32
  int length = sizeof(actual);
#else
  socklen_t length = sizeof(actual);
#endif
  if (getsockopt(handle, level, option, (char *)&actual, &length) ||
      length != sizeof(actual) || actual < 0) return failure(IO);
  return (FooResult){.number = (uint64_t)actual};
}
static int decode(FooText direction) {
  if (direction.data && direction.len == 4 &&
      !memcmp(direction.data, "send", 4)) return SO_SNDBUF;
  if (direction.data && direction.len == 7 &&
      !memcmp(direction.data, "receive", 7)) return SO_RCVBUF;
  return -1;
}
FooResult foo_net_supply(void *pointer, FooText direction, uint64_t size) {
  if (!resource(pointer, SOCKETS)) return failure(CLOSED);
  int option = decode(direction);
  if (option < 0) return failure(ARGUMENT);
  if (!size || size > INT_MAX) return failure(BOUNDS);
  return configure(pointer, SOL_SOCKET, option, (int)size, true);
}
FooResult foo_net_allocated(void *pointer, FooText direction) {
  if (!resource(pointer, SOCKETS)) return failure(CLOSED);
  int option = decode(direction);
  if (option < 0) return failure(ARGUMENT);
  return configure(pointer, SOL_SOCKET, option, 0, false);
}
FooResult foo_net_expire(void *pointer, uint64_t hops) {
  if (!resource(pointer, SOCKETS)) return failure(CLOSED);
  if (!hops || hops > 255) return failure(BOUNDS);
  int family = protocol(pointer);
  if (family == AF_INET)
    return configure(pointer, IPPROTO_IP, IP_TTL, (int)hops, true);
  if (family == AF_INET6)
    return configure(pointer, IPPROTO_IPV6, IPV6_UNICAST_HOPS,
                         (int)hops, true);
  return failure(IO);
}
FooResult foo_net_classify(void *pointer, uint64_t value) {
  if (!resource(pointer, SOCKETS)) return failure(CLOSED);
  if (value > 255) return failure(BOUNDS);
  int family = protocol(pointer);
  if (family == AF_INET)
    return configure(pointer, IPPROTO_IP, IP_TOS, (int)value, true);
#ifdef IPV6_TCLASS
  if (family == AF_INET6)
    return configure(pointer, IPPROTO_IPV6, IPV6_TCLASS,
                         (int)value, true);
#endif
  return failure(SYSTEM);
}
FooResult foo_net_unicast(void *pointer, uint64_t hops) {
  if (!resource(pointer, DATAGRAMS)) return failure(CLOSED);
  if (!hops || hops > 255) return failure(BOUNDS);
  int family = protocol(pointer);
  if (family == AF_INET)
    return configure(pointer, IPPROTO_IP, IP_TTL, (int)hops, true);
  if (family == AF_INET6)
    return configure(pointer, IPPROTO_IPV6, IPV6_UNICAST_HOPS,
                           (int)hops, true);
  return failure(IO);
}
FooResult foo_net_traffic(void *pointer, uint64_t value) {
  if (!resource(pointer, DATAGRAMS)) return failure(CLOSED);
  if (value > 255) return failure(BOUNDS);
  int family = protocol(pointer);
  if (family == AF_INET)
    return configure(pointer, IPPROTO_IP, IP_TOS, (int)value, true);
#ifdef IPV6_TCLASS
  if (family == AF_INET6)
    return configure(pointer, IPPROTO_IPV6, IPV6_TCLASS,
                           (int)value, true);
#endif
  return failure(SYSTEM);
}
FooResult foo_net_buffer(void *pointer, FooText direction, uint64_t size) {
  if (!resource(pointer, DATAGRAMS)) return failure(CLOSED);
  int option = decode(direction);
  if (option < 0) return failure(ARGUMENT);
  if (!size || size > INT_MAX) return failure(BOUNDS);
  return configure(pointer, SOL_SOCKET, option, (int)size, true);
}
FooResult foo_net_capacity(void *pointer, FooText direction) {
  if (!resource(pointer, DATAGRAMS)) return failure(CLOSED);
  int option = decode(direction);
  if (option < 0) return failure(ARGUMENT);
  return configure(pointer, SOL_SOCKET, option, 0, false);
}
FooResult foo_net_deadline(void *pointer, FooText direction,
                                  uint64_t milliseconds) {
  if (!resource(pointer, DATAGRAMS)) return failure(CLOSED);
  return timeout(((Connection *)pointer)->socket, direction, milliseconds);
}
FooResult foo_net_choose4(void *pointer, uint32_t adapter) {
  if (!resource(pointer, DATAGRAMS)) return failure(CLOSED);
  if (protocol(pointer) != AF_INET) return failure(ARGUMENT);
  struct in_addr address = {.s_addr = htonl(adapter)};
  return setsockopt(((Connection *)pointer)->socket, IPPROTO_IP,
                    IP_MULTICAST_IF, (const char *)&address, sizeof(address))
      ? failure(IO) : (FooResult){0};
}
FooResult foo_net_choose6(void *pointer, uint64_t adapter) {
  if (!resource(pointer, DATAGRAMS)) return failure(CLOSED);
  if (protocol(pointer) != AF_INET6 || adapter > UINT32_MAX)
    return failure(ARGUMENT);
  unsigned value = (unsigned)adapter;
  return setsockopt(((Connection *)pointer)->socket, IPPROTO_IPV6,
                    IPV6_MULTICAST_IF, (const char *)&value, sizeof(value))
      ? failure(IO) : (FooResult){0};
}
FooResult foo_net_radius(void *pointer, uint64_t hops) {
  if (!resource(pointer, DATAGRAMS)) return failure(CLOSED);
  if (hops > 255) return failure(BOUNDS);
  int family = protocol(pointer);
  if (family != AF_INET && family != AF_INET6) return failure(IO);
  int value = (int)hops;
  return setsockopt(((Connection *)pointer)->socket,
                    family == AF_INET ? IPPROTO_IP : IPPROTO_IPV6,
                    family == AF_INET ? IP_MULTICAST_TTL : IPV6_MULTICAST_HOPS,
                    (const char *)&value, sizeof(value)) ? failure(IO)
                                                        : (FooResult){0};
}
FooResult foo_net_recirculate(void *pointer, bool enabled) {
  if (!resource(pointer, DATAGRAMS)) return failure(CLOSED);
  int family = protocol(pointer);
  if (family != AF_INET && family != AF_INET6) return failure(IO);
  int value = enabled ? 1 : 0;
  return setsockopt(((Connection *)pointer)->socket,
                    family == AF_INET ? IPPROTO_IP : IPPROTO_IPV6,
                    family == AF_INET ? IP_MULTICAST_LOOP : IPV6_MULTICAST_LOOP,
                    (const char *)&value, sizeof(value)) ? failure(IO)
                                                        : (FooResult){0};
}
FooResult foo_net_membership4(void *pointer, uint32_t group,
                               uint32_t adapter, bool enabled) {
  if (!resource(pointer, DATAGRAMS)) return failure(CLOSED);
  if (protocol(pointer) != AF_INET || (group >> 28) != 14)
    return failure(ARGUMENT);
  struct ip_mreq membership = {0};
  membership.imr_multiaddr.s_addr = htonl(group);
  membership.imr_interface.s_addr = htonl(adapter);
  return setsockopt(((Connection *)pointer)->socket, IPPROTO_IP,
                    enabled ? IP_ADD_MEMBERSHIP : IP_DROP_MEMBERSHIP,
                    (const char *)&membership, sizeof(membership))
      ? failure(IO) : (FooResult){0};
}
FooResult foo_net_membership6(void *pointer, uint64_t high, uint64_t low,
                               uint64_t adapter, bool enabled) {
  if (!resource(pointer, DATAGRAMS)) return failure(CLOSED);
  if (protocol(pointer) != AF_INET6 || (high >> 56) != 0xff ||
      adapter > UINT32_MAX) return failure(ARGUMENT);
  struct ipv6_mreq membership = {0};
  for (int index = 7; index >= 0; index--) {
    membership.ipv6mr_multiaddr.s6_addr[index] = (uint8_t)high;
    membership.ipv6mr_multiaddr.s6_addr[index + 8] = (uint8_t)low;
    high >>= 8;
    low >>= 8;
  }
  membership.ipv6mr_interface = (unsigned)adapter;
  return setsockopt(((Connection *)pointer)->socket, IPPROTO_IPV6,
                    enabled ? IPV6_JOIN_GROUP : IPV6_LEAVE_GROUP,
                    (const char *)&membership, sizeof(membership))
      ? failure(IO) : (FooResult){0};
}
FooResult foo_net_transmit(void *pointer, FooText host, uint64_t port,
                           FooText content) {
  if (!resource(pointer, DATAGRAMS)) return failure(CLOSED);
  if (port > 65535 || content.len > 65507) return failure(BOUNDS);
  if (content.len && !content.data) return failure(ARGUMENT);
  char *name = string(host), service[6];
  if (!name || !host.len) { free(name); return failure(ARGUMENT); }
  snprintf(service, sizeof(service), "%u", (unsigned)port);
  struct sockaddr_storage local;
#ifdef _WIN32
  int extent = sizeof(local);
#else
  socklen_t extent = sizeof(local);
#endif
  if (getsockname(((Connection *)pointer)->socket,
                  (struct sockaddr *)&local, &extent)) {
    free(name);
    return failure(IO);
  }
  struct addrinfo hints = {0}, *addresses = NULL;
  hints.ai_family = local.ss_family;
  hints.ai_socktype = SOCK_DGRAM;
  int problem = getaddrinfo(name, service, &hints, &addresses);
  free(name);
  if (problem) return failure(MISSING);
  int sent = -1;
  for (struct addrinfo *address = addresses; address; address = address->ai_next) {
    do {
      sent = sendto(((Connection *)pointer)->socket,
          (const char *)(content.data ? content.data : (const uint8_t *)""),
          (int)content.len, 0, address->ai_addr, (int)address->ai_addrlen);
    } while (sent < 0 && interrupted());
    if (sent >= 0) break;
  }
  freeaddrinfo(addresses);
  return sent < 0 || (size_t)sent != content.len ? failure(IO)
      : (FooResult){.number = (uint64_t)sent};
}
FooResult foo_net_transmit6(void *pointer, uint64_t high, uint64_t low,
                               uint64_t port, uint64_t scope, FooText content) {
  if (!resource(pointer, DATAGRAMS)) return failure(CLOSED);
  if (protocol(pointer) != AF_INET6 || scope > UINT32_MAX)
    return failure(ARGUMENT);
  if (port > 65535 || content.len > 65507) return failure(BOUNDS);
  if (content.len && !content.data) return failure(ARGUMENT);
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
  int sent;
  do {
    sent = sendto(((Connection *)pointer)->socket,
                  (const char *)(content.data ? content.data : (const uint8_t *)""),
                  (int)content.len, 0, (struct sockaddr *)&address,
                  sizeof(address));
  } while (sent < 0 && interrupted());
  return sent < 0 || (size_t)sent != content.len ? failure(IO)
      : (FooResult){.number = (uint64_t)sent};
}
FooResult foo_net_collect(void *pointer, uint64_t size) {
  if (!resource(pointer, DATAGRAMS)) return failure(CLOSED);
  if (size > 65535) return failure(BOUNDS);
  uint8_t *buffer = malloc(65536);
  if (!buffer) return failure(MEMORY);
  struct sockaddr_storage address;
#ifdef _WIN32
  int length = sizeof(address);
#else
  socklen_t length = sizeof(address);
#endif
  int received;
  do {
    received = recvfrom(((Connection *)pointer)->socket, (char *)buffer, 65536,
                        0, (struct sockaddr *)&address, &length);
  } while (received < 0 && interrupted());
  if (received < 0 || (address.ss_family != AF_INET &&
                       address.ss_family != AF_INET6)) {
    free(buffer);
    return failure(IO);
  }
  if ((uint64_t)received > size) { free(buffer); return failure(BOUNDS); }
  const void *ip = address.ss_family == AF_INET
      ? (const void *)&((struct sockaddr_in *)&address)->sin_addr
      : (const void *)&((struct sockaddr_in6 *)&address)->sin6_addr;
  char numeric[INET6_ADDRSTRLEN];
  if (!inet_ntop(address.ss_family, ip, numeric, sizeof(numeric))) {
    free(buffer);
    return failure(IO);
  }
  Packet *packet = owned(sizeof(*packet), PACKETS);
  if (!packet) { free(buffer); return failure(MEMORY); }
  memcpy(packet->host, numeric, strlen(numeric) + 1);
  packet->data = buffer;
  packet->length = (size_t)received;
  packet->address = address;
  packet->port = ntohs(address.ss_family == AF_INET
      ? ((struct sockaddr_in *)&address)->sin_port
      : ((struct sockaddr_in6 *)&address)->sin6_port);
  return (FooResult){.pointer = packet};
}
FooResult foo_net_raw(void *pointer) {
  if (!resource(pointer, PACKETS)) return failure(CLOSED);
  Packet *packet = pointer;
  return (FooResult){.text = {packet->data, packet->length}};
}
FooResult foo_net_peer(void *pointer) {
  if (!resource(pointer, PACKETS)) return failure(CLOSED);
  Packet *packet = pointer;
  return (FooResult){.text = {(const uint8_t *)packet->host,
                             strlen(packet->host)}};
}
FooResult foo_net_peer4(void *pointer) {
  if (!resource(pointer, PACKETS)) return failure(CLOSED);
  Packet *packet = pointer;
  if (packet->address.ss_family != AF_INET) return failure(ARGUMENT);
  return (FooResult){.number = ntohl(
      ((struct sockaddr_in *)&packet->address)->sin_addr.s_addr)};
}
static FooResult peer6part(void *pointer, int offset) {
  if (!resource(pointer, PACKETS)) return failure(CLOSED);
  Packet *packet = pointer;
  if (packet->address.ss_family != AF_INET6) return failure(ARGUMENT);
  const uint8_t *bytes = ((struct sockaddr_in6 *)&packet->address)->sin6_addr.s6_addr;
  uint64_t value = 0;
  for (int index = offset; index < offset + 8; index++)
    value = (value << 8) | bytes[index];
  return (FooResult){.number = value};
}
FooResult foo_net_peer6high(void *pointer) { return peer6part(pointer, 0); }
FooResult foo_net_peer6low(void *pointer) { return peer6part(pointer, 8); }
FooResult foo_net_zone(void *pointer) {
  if (!resource(pointer, PACKETS)) return failure(CLOSED);
  Packet *packet = pointer;
  if (packet->address.ss_family != AF_INET6) return failure(ARGUMENT);
  return (FooResult){.number =
      ((struct sockaddr_in6 *)&packet->address)->sin6_scope_id};
}
FooResult foo_net_source(void *pointer) {
  if (!resource(pointer, PACKETS)) return failure(CLOSED);
  return (FooResult){.number = ((Packet *)pointer)->port};
}
FooResult foo_net_discard(void *pointer) {
  Resource *entry = resource(pointer, PACKETS);
  if (!entry) return failure(CLOSED);
  Packet *packet = pointer;
  free(packet->data);
  packet->data = NULL;
  entry->closed = 1;
  return (FooResult){0};
}
FooResult foo_net_detach(void *pointer) {
  Resource *entry = resource(pointer, DATAGRAMS);
  if (!entry) return failure(CLOSED);
  int problem = disconnect(((Connection *)pointer)->socket);
  entry->closed = 1;
  return problem ? failure(IO) : (FooResult){0};
}

enum { POLL_LIMIT = 128 };
typedef struct {
  void *socket;
  uint64_t token;
  uint64_t deadline;
  int kind;
  short mode;
} Watch;
typedef struct {
  Watch watches[POLL_LIMIT];
  size_t count;
  size_t cursor;
} Poller;
#ifdef _WIN32
typedef WSAPOLLFD PollDescriptor;
#define FOO_POLL_READ POLLRDNORM
#define FOO_POLL_WRITE POLLWRNORM
#else
typedef struct pollfd PollDescriptor;
#define FOO_POLL_READ POLLIN
#define FOO_POLL_WRITE POLLOUT
#endif

FooResult foo_net_watch(void) {
  Poller *poller = owned(sizeof(*poller), POLLERS);
  return poller ? (FooResult){.pointer = poller} : failure(MEMORY);
}
static FooResult watch(void *pointer, void *socket, FooText direction,
                          uint64_t token, int kind) {
  if (!resource(pointer, POLLERS)) return failure(CLOSED);
  if (!resource(socket, kind)) return failure(CLOSED);
  short mode = supports(direction, "receive") ? FOO_POLL_READ :
               supports(direction, "send") ? FOO_POLL_WRITE : 0;
  if (!mode || !token) return failure(ARGUMENT);
  Poller *poller = pointer;
  for (size_t index = 0; index < poller->count; index++)
    if (poller->watches[index].token == token) return failure(ARGUMENT);
  if (poller->count == POLL_LIMIT) return failure(BOUNDS);
  poller->watches[poller->count++] = (Watch){
      .socket = socket, .token = token, .kind = kind, .mode = mode};
  return (FooResult){0};
}
FooResult foo_net_stream(void *pointer, void *socket, FooText direction,
                           uint64_t token) {
  return watch(pointer, socket, direction, token, SOCKETS);
}
FooResult foo_net_packet(void *pointer, void *socket, FooText direction,
                           uint64_t token) {
  return watch(pointer, socket, direction, token, DATAGRAMS);
}
FooResult foo_net_process(void *pointer, void *child, uint64_t token) {
  if (!resource(pointer, POLLERS) || !resource(child, CHILDREN)) return failure(CLOSED);
  if (!token) return failure(ARGUMENT);
  Poller *poller = pointer;
  for (size_t index = 0; index < poller->count; index++)
    if (poller->watches[index].token == token) return failure(ARGUMENT);
  if (poller->count == POLL_LIMIT) return failure(BOUNDS);
  poller->watches[poller->count++] = (Watch){
      .socket = child, .token = token, .kind = CHILDREN};
  return (FooResult){0};
}
FooResult foo_net_alarm(void *pointer, uint64_t token,
                             uint64_t milliseconds) {
  if (!resource(pointer, POLLERS)) return failure(CLOSED);
  if (!token) return failure(ARGUMENT);
  if (milliseconds > INT_MAX) return failure(BOUNDS);
  Poller *poller = pointer;
  for (size_t index = 0; index < poller->count; index++)
    if (poller->watches[index].token == token) return failure(ARGUMENT);
  if (poller->count == POLL_LIMIT) return failure(BOUNDS);
  FooResult now = foo_time_current();
  if (now.error) return now;
  uint64_t duration = milliseconds * UINT64_C(1000000);
  if (duration > UINT64_MAX - now.number) return failure(BOUNDS);
  poller->watches[poller->count++] = (Watch){
      .token = token, .deadline = now.number + duration};
  return (FooResult){0};
}
FooResult foo_net_unwatch(void *pointer, uint64_t token) {
  if (!resource(pointer, POLLERS)) return failure(CLOSED);
  Poller *poller = pointer;
  for (size_t index = 0; index < poller->count; index++) {
    if (poller->watches[index].token != token) continue;
    memmove(&poller->watches[index], &poller->watches[index + 1],
            (poller->count - index - 1) * sizeof(Watch));
    poller->count--;
    if (poller->cursor >= poller->count) poller->cursor = 0;
    return (FooResult){0};
  }
  return failure(MISSING);
}
FooResult foo_net_ready(void *pointer, uint64_t milliseconds) {
  if (!resource(pointer, POLLERS)) return failure(CLOSED);
  if (milliseconds > INT_MAX) return failure(BOUNDS);
  Poller *poller = pointer;
  FooResult now = foo_time_current();
  if (now.error) return now;
  uint64_t duration = milliseconds * UINT64_C(1000000);
  if (duration > UINT64_MAX - now.number) return failure(BOUNDS);
  uint64_t limit = now.number + duration;
  for (;;) {
    now = foo_time_current();
    if (now.error) return now;
    uint64_t nearest = limit;
    bool children = false;
    for (size_t index = 0; index < poller->count; index++) {
      Watch *watch = &poller->watches[index];
      if (watch->kind == CHILDREN) {
        FooResult active = foo_process_active(watch->socket);
        if (active.error) return active;
        if (!active.number) return (FooResult){.number = watch->token};
        children = true;
        continue;
      }
      if (watch->kind) continue;
      if (watch->deadline <= now.number) {
        uint64_t token = watch->token;
        memmove(watch, watch + 1,
                (poller->count - index - 1) * sizeof(Watch));
        poller->count--;
        if (poller->cursor >= poller->count) poller->cursor = 0;
        return (FooResult){.number = token};
      }
      if (watch->deadline < nearest) nearest = watch->deadline;
    }
    PollDescriptor descriptors[POLL_LIMIT];
    size_t indices[POLL_LIMIT], count = 0;
    for (size_t index = 0; index < poller->count; index++) {
      Watch *watch = &poller->watches[index];
      if (!watch->kind || watch->kind == CHILDREN) continue;
      if (!resource(watch->socket, watch->kind)) return failure(CLOSED);
      descriptors[count] = (PollDescriptor){
          .fd = ((Connection *)watch->socket)->socket,
          .events = watch->mode, .revents = 0};
      indices[count++] = index;
    }
    uint64_t remaining = nearest > now.number ? nearest - now.number : 0;
    int delay = (int)(remaining / 1000000 + (remaining % 1000000 != 0));
    if (children && delay > 10) delay = 10;
    if (!count) {
      if (!delay) return (FooResult){0};
      FooResult slept = foo_time_sleep((uint64_t)delay * UINT64_C(1000000));
      if (slept.error) return slept;
    } else {
#ifdef _WIN32
      int ready = WSAPoll(descriptors, (ULONG)count, delay);
#else
      int ready = poll(descriptors, (nfds_t)count, delay);
#endif
      if (ready < 0) {
        if (interrupted()) continue;
        return failure(IO);
      }
      if (ready) {
        for (size_t offset = 0; offset < count; offset++) {
          size_t position = (poller->cursor + offset) % count;
          short flags = descriptors[position].revents;
          if (flags & POLLNVAL) return failure(CLOSED);
          if (flags & (descriptors[position].events | POLLERR | POLLHUP)) {
            poller->cursor = (position + 1) % count;
            return (FooResult){.number = poller->watches[indices[position]].token};
          }
        }
      }
    }
    if (milliseconds == 0) return (FooResult){0};
    now = foo_time_current();
    if (now.error) return now;
    if (now.number >= limit) return (FooResult){0};
  }
}
FooResult foo_net_cease(void *pointer) {
  Resource *entry = resource(pointer, POLLERS);
  if (!entry) return failure(CLOSED);
  entry->closed = 1;
  return (FooResult){0};
}
