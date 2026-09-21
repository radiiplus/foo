#include <curl/curl.h>
#include <errno.h>
#include <openssl/err.h>
#include <openssl/pem.h>
#include <openssl/ssl.h>
#ifndef _WIN32
#include <arpa/inet.h>
#include <strings.h>
#include <sys/socket.h>
#else
#error "C HTTP server support currently requires POSIX"
#endif
typedef struct FOOCert {
  X509 *certificate;
  struct FOOCert *next;
} FOOCert;
typedef struct {
  CURL *handle;
  FOOCert *certificates;
} FOOClient;
typedef struct {
  uint16_t code;
  uint8_t *bytes;
  size_t length, limit;
} FOOResponse;
static char *foo_cstring(FOOText value) {
  if (memchr(value.data, 0, value.len) || value.len == SIZE_MAX)
    return NULL;
  char *copy = malloc(value.len + 1);
  if (!copy)
    return NULL;
  memcpy(copy, value.data, value.len);
  copy[value.len] = 0;
  return copy;
}
static FOOResult foo_http_client(void) {
  static bool initialized;
  foo_enter();
  if (!initialized) {
    if (curl_global_init(CURL_GLOBAL_DEFAULT)) {
      foo_leave();
      return foo_error("HttpUnavailable");
    }
    initialized = true;
  }
  foo_leave();
  FOOClient *value = calloc(1, sizeof(*value));
  if (!value)
    return foo_error("OutOfMemory");
  value->handle = curl_easy_init();
  if (!value->handle) {
    free(value);
    return foo_error("OutOfMemory");
  }
  return (FOOResult){.pointer = value};
}
static CURLcode foo_certificates(CURL *curl, void *context, void *userdata) {
  (void)curl;
  FOOClient *value = userdata;
  X509_STORE *store = SSL_CTX_get_cert_store(context);
  for (FOOCert *item = value->certificates; item; item = item->next) {
    int result = X509_STORE_add_cert(store, item->certificate);
    if (!result && ERR_GET_REASON(ERR_peek_last_error()) !=
                       X509_R_CERT_ALREADY_IN_HASH_TABLE)
      return CURLE_SSL_CACERT_BADFILE;
    ERR_clear_error();
  }
  return CURLE_OK;
}
static FOOResult foo_http_trust(void *pointer, FOOText certificate) {
  FOOClient *value = pointer;
  const char *tls = curl_version_info(CURLVERSION_NOW)->ssl_version;
  if (!tls || strncmp(tls, "OpenSSL/", 8))
    return foo_error("UnsupportedTlsBackend");
  char *path = foo_cstring(certificate);
  if (!path)
    return foo_error("InvalidPath");
  BIO *input = BIO_new_file(path, "r");
  free(path);
  if (!input) {
    ERR_clear_error();
    return foo_error("InvalidCertificate");
  }
  FOOCert *added = NULL;
  for (;;) {
    X509 *cert = PEM_read_bio_X509(input, NULL, NULL, NULL);
    if (!cert)
      break;
    FOOCert *item = malloc(sizeof(*item));
    if (!item) {
      X509_free(cert);
      BIO_free(input);
      while (added) {
        FOOCert *old = added;
        added = old->next;
        X509_free(old->certificate);
        free(old);
      }
      return foo_error("OutOfMemory");
    }
    *item = (FOOCert){cert, added};
    added = item;
  }
  BIO_free(input);
  ERR_clear_error();
  if (!added)
    return foo_error("InvalidCertificate");
  while (added) {
    FOOCert *item = added;
    added = item->next;
    item->next = value->certificates;
    value->certificates = item;
  }
  return (FOOResult){0};
}
static size_t foo_download(char *data, size_t size, size_t count,
                           void *pointer) {
  FOOResponse *response = pointer;
  if (size && count > SIZE_MAX / size)
    return 0;
  size_t length = size * count;
  if (length > response->limit - response->length)
    return 0;
  if (length)
    memcpy(response->bytes + response->length, data, length);
  response->length += length;
  return length;
}
static bool foo_method(FOOText method) {
  const char *methods[] = {"GET",     "HEAD",    "POST",  "PUT",  "DELETE",
                           "CONNECT", "OPTIONS", "TRACE", "PATCH"};
  for (size_t k = 0; k < sizeof(methods) / sizeof(methods[0]); k++)
    if (foo_equal(method, methods[k]))
      return true;
  return false;
}
static FOOResult foo_http_request(void *pointer, FOOText url, FOOText method,
                                  FOOText content, uint32_t limit) {
  FOOClient *value = pointer;
  if (!foo_method(method))
    return foo_error("InvalidMethod");
  char *address = foo_cstring(url), *verb = foo_cstring(method);
  if (!address || !verb) {
    free(address);
    free(verb);
    return foo_error("InvalidUrl");
  }
  FOOResponse *response = calloc(1, sizeof(*response));
  if (!response) {
    free(address);
    free(verb);
    return foo_error("OutOfMemory");
  }
  response->bytes = malloc(limit ? limit : 1);
  response->limit = limit;
  if (!response->bytes) {
    free(address);
    free(verb);
    free(response);
    return foo_error("OutOfMemory");
  }
  CURL *curl = value->handle;
  curl_easy_reset(curl);
  curl_easy_setopt(curl, CURLOPT_URL, address);
  curl_easy_setopt(curl, CURLOPT_CUSTOMREQUEST, verb);
  curl_easy_setopt(curl, CURLOPT_PROTOCOLS,
                   (long)(CURLPROTO_HTTP | CURLPROTO_HTTPS));
  curl_easy_setopt(curl, CURLOPT_REDIR_PROTOCOLS,
                   (long)(CURLPROTO_HTTP | CURLPROTO_HTTPS));
  curl_easy_setopt(curl, CURLOPT_FOLLOWLOCATION, 1L);
  curl_easy_setopt(curl, CURLOPT_MAXREDIRS, 10L);
  curl_easy_setopt(curl, CURLOPT_NOSIGNAL, 1L);
  curl_easy_setopt(curl, CURLOPT_SSL_VERIFYPEER, 1L);
  curl_easy_setopt(curl, CURLOPT_SSL_VERIFYHOST, 2L);
  curl_easy_setopt(curl, CURLOPT_HTTP_VERSION, (long)CURL_HTTP_VERSION_1_1);
  if (value->certificates) {
    curl_easy_setopt(curl, CURLOPT_SSL_CTX_FUNCTION, foo_certificates);
    curl_easy_setopt(curl, CURLOPT_SSL_CTX_DATA, value);
  }
  if (foo_equal(method, "HEAD"))
    curl_easy_setopt(curl, CURLOPT_NOBODY, 1L);
  if (content.len) {
    curl_easy_setopt(curl, CURLOPT_POSTFIELDS, content.data);
    curl_easy_setopt(curl, CURLOPT_POSTFIELDSIZE_LARGE,
                     (curl_off_t)content.len);
  }
  curl_easy_setopt(curl, CURLOPT_WRITEFUNCTION, foo_download);
  curl_easy_setopt(curl, CURLOPT_WRITEDATA, response);
  CURLcode result = curl_easy_perform(curl);
  long code = 0;
  curl_easy_getinfo(curl, CURLINFO_RESPONSE_CODE, &code);
  response->code = (uint16_t)code;
  free(address);
  free(verb);
  if (result != CURLE_OK) {
    free(response->bytes);
    free(response);
    return foo_error(result == CURLE_WRITE_ERROR ? "WriteFailed"
                     : result == CURLE_PEER_FAILED_VERIFICATION ||
                             result == CURLE_SSL_CONNECT_ERROR ||
                             result == CURLE_SSL_CACERT_BADFILE
                         ? "TlsInitializationFailed"
                         : "HttpFailed");
  }
  return (FOOResult){.pointer = response};
}
static uint16_t foo_http_status(void *value) {
  return ((FOOResponse *)value)->code;
}
static FOOResult foo_http_body(void *value) {
  FOOResponse *response = value;
  return foo_copy(response->bytes, response->length);
}
static void foo_http_release(void *value) {
  FOOResponse *response = value;
  free(response->bytes);
  free(response);
}
static void foo_http_close(void *pointer) {
  FOOClient *value = pointer;
  curl_easy_cleanup(value->handle);
  while (value->certificates) {
    FOOCert *item = value->certificates;
    value->certificates = item->next;
    X509_free(item->certificate);
    free(item);
  }
  free(value);
}

typedef struct {
  int socket;
  uint16_t port;
} FOOServer;
typedef struct {
  int socket;
  char head[16385];
  char *method, *target;
  char *names[128], *values[128];
  size_t headers;
  uint64_t remaining;
  bool request, consumed, chunked, reuse, expect;
} FOOPeer;
static bool foo_send(int socket, const void *data, size_t length) {
  const uint8_t *bytes = data;
  while (length) {
    ssize_t count = send(socket, bytes, length, MSG_NOSIGNAL);
    if (count < 0 && errno == EINTR)
      continue;
    if (count <= 0)
      return false;
    bytes += count;
    length -= (size_t)count;
  }
  return true;
}
static bool foo_receive(int socket, void *data, size_t length) {
  uint8_t *bytes = data;
  while (length) {
    ssize_t count = recv(socket, bytes, length, 0);
    if (count < 0 && errno == EINTR)
      continue;
    if (count <= 0)
      return false;
    bytes += count;
    length -= (size_t)count;
  }
  return true;
}
static FOOResult foo_http_listen(FOOText host, uint16_t port) {
  char *address = foo_cstring(host);
  if (!address)
    return foo_error("InvalidAddress");
  struct sockaddr_storage storage = {0};
  socklen_t length;
  int family;
  struct sockaddr_in *v4 = (struct sockaddr_in *)&storage;
  struct sockaddr_in6 *v6 = (struct sockaddr_in6 *)&storage;
  if (inet_pton(AF_INET, address, &v4->sin_addr) == 1) {
    family = AF_INET;
    v4->sin_family = AF_INET;
    v4->sin_port = htons(port);
    length = sizeof(*v4);
  } else if (inet_pton(AF_INET6, address, &v6->sin6_addr) == 1) {
    family = AF_INET6;
    v6->sin6_family = AF_INET6;
    v6->sin6_port = htons(port);
    length = sizeof(*v6);
  } else {
    free(address);
    return foo_error("InvalidAddress");
  }
  free(address);
  int fd = socket(family, SOCK_STREAM, 0);
  if (fd < 0)
    return foo_error("SocketFailed");
  int yes = 1;
  setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, sizeof(yes));
  if (bind(fd, (struct sockaddr *)&storage, length) || listen(fd, 128) ||
      getsockname(fd, (struct sockaddr *)&storage, &length)) {
    close(fd);
    return foo_error("ListenFailed");
  }
  FOOServer *server = malloc(sizeof(*server));
  if (!server) {
    close(fd);
    return foo_error("OutOfMemory");
  }
  *server =
      (FOOServer){fd, ntohs(family == AF_INET ? v4->sin_port : v6->sin6_port)};
  return (FOOResult){.pointer = server};
}
static uint16_t foo_http_port(void *value) {
  return ((FOOServer *)value)->port;
}
static void foo_http_stop(void *value) {
  close(((FOOServer *)value)->socket);
  free(value);
}
static FOOResult foo_http_accept(void *value) {
  int fd;
  do {
    fd = accept(((FOOServer *)value)->socket, NULL, NULL);
  } while (fd < 0 && errno == EINTR);
  if (fd < 0)
    return foo_error("AcceptFailed");
  FOOPeer *peer = calloc(1, sizeof(*peer));
  if (!peer) {
    close(fd);
    return foo_error("OutOfMemory");
  }
  peer->socket = fd;
  return (FOOResult){.pointer = peer};
}
static bool foo_digits(const char *text, unsigned base, uint64_t *result) {
  if (!*text)
    return false;
  *result = 0;
  for (; *text; text++) {
    int digit = *text >= '0' && *text <= '9'                 ? *text - '0'
                : base == 16 && *text >= 'a' && *text <= 'f' ? *text - 'a' + 10
                : base == 16 && *text >= 'A' && *text <= 'F' ? *text - 'A' + 10
                                                             : -1;
    if (digit < 0 || (unsigned)digit >= base ||
        *result > (UINT64_MAX - (unsigned)digit) / base)
      return false;
    *result = *result * base + (unsigned)digit;
  }
  return true;
}
static FOOResult foo_http_receive(void *value) {
  FOOPeer *peer = value;
  if (peer->request)
    return foo_error("ResponseRequired");
  size_t length = 0;
  while (length < sizeof(peer->head) - 1) {
    if (!foo_receive(peer->socket, peer->head + length, 1))
      return foo_error("EndOfStream");
    length++;
    if (length >= 4 && !memcmp(peer->head + length - 4, "\r\n\r\n", 4))
      break;
  }
  if (length < 4 || memcmp(peer->head + length - 4, "\r\n\r\n", 4))
    return foo_error("HttpHeadersOversize");
  if (memchr(peer->head, 0, length))
    return foo_error("InvalidHeaders");
  peer->head[length] = 0;
  char *line = strstr(peer->head, "\r\n");
  *line = 0;
  char *target = strchr(peer->head, ' ');
  if (!target)
    return foo_error("InvalidHeaders");
  *target++ = 0;
  char *version = strchr(target, ' ');
  if (!version)
    return foo_error("InvalidHeaders");
  *version++ = 0;
  if (!foo_method(foo_text(peer->head)) || !*target ||
      (strcmp(version, "HTTP/1.1") && strcmp(version, "HTTP/1.0")))
    return foo_error("InvalidHeaders");
  peer->method = peer->head;
  peer->target = target;
  peer->headers = 0;
  peer->remaining = 0;
  peer->chunked = false;
  peer->reuse = !strcmp(version, "HTTP/1.1");
  peer->expect = false;
  bool sized = false;
  line += 2;
  while (*line != '\r') {
    if (peer->headers == 128)
      return foo_error("HttpHeadersOversize");
    char *end = strstr(line, "\r\n");
    if (!end)
      return foo_error("InvalidHeaders");
    *end = 0;
    char *colon = strchr(line, ':');
    if (!colon || colon == line)
      return foo_error("InvalidHeaders");
    *colon++ = 0;
    for (char *p = line; *p; p++)
      if (!((*p >= 'A' && *p <= 'Z') || (*p >= 'a' && *p <= 'z') ||
            (*p >= '0' && *p <= '9') || strchr("!#$%&'*+-.^_`|~", *p)))
        return foo_error("InvalidHeaders");
    while (*colon == ' ' || *colon == '\t')
      colon++;
    char *tail = end;
    while (tail > colon && (tail[-1] == ' ' || tail[-1] == '\t'))
      *--tail = 0;
    peer->names[peer->headers] = line;
    peer->values[peer->headers++] = colon;
    if (!strcasecmp(line, "Content-Length")) {
      if (sized || !foo_digits(colon, 10, &peer->remaining))
        return foo_error("InvalidHeaders");
      sized = true;
    } else if (!strcasecmp(line, "Transfer-Encoding")) {
      if (peer->chunked || strcasecmp(colon, "chunked"))
        return foo_error("InvalidHeaders");
      peer->chunked = true;
    } else if (!strcasecmp(line, "Connection") && !strcasecmp(colon, "close"))
      peer->reuse = false;
    else if (!strcasecmp(line, "Expect")) {
      if (strcasecmp(colon, "100-continue"))
        return foo_error("InvalidHeaders");
      peer->expect = true;
    }
    line = end + 2;
  }
  if (sized && peer->chunked)
    return foo_error("InvalidHeaders");
  peer->request = true;
  peer->consumed = false;
  return foo_copy(target, strlen(target));
}
static FOOResult foo_http_method(void *value) {
  FOOPeer *peer = value;
  return !peer->request ? foo_error("RequestRequired")
                        : (FOOResult){.text = foo_text(peer->method)};
}
static FOOResult foo_http_header(void *value, FOOText name) {
  FOOPeer *peer = value;
  if (peer->consumed)
    return foo_error("BodyConsumed");
  if (!peer->request)
    return foo_error("RequestRequired");
  for (size_t k = 0; k < peer->headers; k++)
    if (strlen(peer->names[k]) == name.len &&
        !strncasecmp(peer->names[k], (const char *)name.data, name.len))
      return foo_copy(peer->values[k], strlen(peer->values[k]));
  return foo_error("MissingHeader");
}
static FOOResult foo_http_read(void *value, uint32_t limit) {
  FOOPeer *peer = value;
  if (peer->consumed)
    return foo_error("BodyConsumed");
  if (!peer->request)
    return foo_error("RequestRequired");
  peer->consumed = true;
  if (peer->expect &&
      !foo_send(peer->socket, "HTTP/1.1 100 Continue\r\n\r\n", 25))
    return foo_error("WriteFailed");
  uint8_t *data = malloc(limit ? limit : 1);
  if (!data)
    return foo_error("OutOfMemory");
  size_t count = 0;
  const char *error = NULL;
  do {
    uint64_t size = peer->remaining;
    if (peer->chunked) {
      char line[128];
      size_t length = 0;
      do {
        if (length == sizeof(line) - 1 ||
            !foo_receive(peer->socket, line + length, 1)) {
          error = "InvalidChunk";
          goto done;
        }
        length++;
      } while (length < 2 || memcmp(line + length - 2, "\r\n", 2));
      line[length - 2] = 0;
      char *extension = strchr(line, ';');
      if (extension)
        *extension = 0;
      if (!foo_digits(line, 16, &size)) {
        error = "InvalidChunk";
        goto done;
      }
    }
    if (size > limit - count) {
      error = "WriteFailed";
      goto done;
    }
    if (!foo_receive(peer->socket, data + count, (size_t)size)) {
      error = "EndOfStream";
      goto done;
    }
    count += (size_t)size;
    if (peer->chunked) {
      char end[2];
      if (!foo_receive(peer->socket, end, 2) || memcmp(end, "\r\n", 2)) {
        error = "InvalidChunk";
        goto done;
      }
    }
    if (!peer->chunked || !size)
      break;
  } while (true);
  peer->remaining = 0;
done:
  if (error)
    peer->reuse = false;
  FOOResult result = error ? foo_error(error) : foo_copy(data, count);
  free(data);
  return result;
}
static FOOResult foo_http_reply(void *value, uint16_t code, FOOText content,
                                bool reuse) {
  FOOPeer *peer = value;
  if (code < 200 || code > 599)
    return foo_error("InvalidStatus");
  if (!peer->request)
    return foo_error("RequestRequired");
  if (!peer->consumed && (peer->remaining || peer->chunked))
    reuse = false;
  reuse = reuse && peer->reuse;
  char head[256];
  int length = snprintf(
      head, sizeof(head),
      "HTTP/1.1 %u Response\r\nContent-Length: %zu\r\nConnection: %s\r\n\r\n",
      code, content.len, reuse ? "keep-alive" : "close");
  bool sent = length > 0 && (size_t)length < sizeof(head) &&
              foo_send(peer->socket, head, (size_t)length) &&
              (!strcmp(peer->method, "HEAD") ||
               foo_send(peer->socket, content.data, content.len));
  peer->request = false;
  if (!reuse)
    shutdown(peer->socket, SHUT_WR);
  return sent ? (FOOResult){0} : foo_error("WriteFailed");
}
static void foo_http_disconnect(void *value) {
  close(((FOOPeer *)value)->socket);
  free(value);
}
