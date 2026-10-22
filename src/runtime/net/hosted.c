typedef struct {
  Socket socket;
} Connection;
static int interrupted(void) {
#ifdef _WIN32
  return WSAGetLastError() == WSAEINTR;
#else
  return errno == EINTR;
#endif
}
static FooResult endpoint(Socket socket, int kind) {
  Connection *result = owned(sizeof(*result), kind);
  if (!result) {
    disconnect(socket);
    return failure(MEMORY);
  }
  result->socket = socket;
  return (FooResult){.pointer = result};
}
static FooResult connection(Socket socket) {
  return endpoint(socket, SOCKETS);
}
static int initialize(void) {
#ifdef _WIN32
  enter();
  if (!winsock) {
    WSADATA data;
    if (WSAStartup(MAKEWORD(2, 2), &data)) {
      leave();
      return 0;
    }
    winsock = 1;
  }
  leave();
#endif
  return 1;
}
#include "tcp.c"

#include "tls.c"

#include "discovery.c"

#include "datagram.c"
