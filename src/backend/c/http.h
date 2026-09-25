#include <errno.h>
#ifdef _WIN32
#include <winsock2.h>
#include <ws2tcpip.h>
#include <winhttp.h>
typedef SOCKET FOOHttpSocket;
typedef int FOOHttpSocklen;
#define FOO_HTTP_INVALID INVALID_SOCKET
#define FOO_HTTP_CLOSE closesocket
#define FOO_HTTP_SHUT_WRITE SD_SEND
#define strcasecmp _stricmp
#define strncasecmp _strnicmp
#else
#include <arpa/inet.h>
#include <strings.h>
#include <sys/socket.h>
typedef int FOOHttpSocket;
typedef socklen_t FOOHttpSocklen;
#define FOO_HTTP_INVALID (-1)
#define FOO_HTTP_CLOSE close
#define FOO_HTTP_SHUT_WRITE SHUT_WR
#include <curl/curl.h>
#endif
typedef struct {
#ifdef _WIN32
  HINTERNET session;
  wchar_t *headers;
  size_t header_length;
#else
  CURL *handle;
  char *certificate;
  struct curl_slist *headers;
#endif
  uint16_t redirects;
  bool reuse;
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
  foo_transfer(copy, value.data, value.len);
  copy[value.len] = 0;
  return copy;
}
static FOOResult foo_http_client(void) {
#ifdef _WIN32
  FOOClient *value = calloc(1, sizeof(*value));
  if (!value)
    return foo_error("OutOfMemory");
  value->session = WinHttpOpen(L"FOO/1", WINHTTP_ACCESS_TYPE_DEFAULT_PROXY,
                               WINHTTP_NO_PROXY_NAME,
                               WINHTTP_NO_PROXY_BYPASS, 0);
  if (!value->session) {
    free(value);
    return foo_error("HttpUnavailable");
  }
#else
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
#endif
  value->redirects = 10;
  value->reuse = true;
  return (FOOResult){.pointer = value};
}
static FOOResult foo_http_trust(void *pointer, FOOText certificate) {
#ifdef _WIN32
  (void)pointer;
  (void)certificate;
  return foo_error("CustomTrustUnavailable");
#else
  FOOClient *value = pointer;
  char *path = foo_cstring(certificate);
  if (!path)
    return foo_error("InvalidPath");
  FILE *input = fopen(path, "rb");
  if (!input) {
    free(path);
    return foo_error("InvalidCertificate");
  }
  fclose(input);
  free(value->certificate);
  value->certificate = path;
  return (FOOResult){0};
#endif
}
static bool foo_http_header_name(FOOText name) {
  if (!name.len)
    return false;
  for (size_t index = 0; index < name.len; index++) {
    uint8_t byte = name.data[index];
    if (!((byte >= 'A' && byte <= 'Z') || (byte >= 'a' && byte <= 'z') ||
          (byte >= '0' && byte <= '9') ||
          strchr("!#$%&'*+-.^_`|~", byte)))
      return false;
  }
  return true;
}
static FOOResult foo_http_addHeader(void *pointer, FOOText name,
                                     FOOText content) {
  FOOClient *value = pointer;
  if (!foo_http_header_name(name) || memchr(content.data, '\r', content.len) ||
      memchr(content.data, '\n', content.len) ||
      name.len > SIZE_MAX - content.len - 3)
    return foo_error("InvalidHeader");
  size_t length = name.len + content.len + 3;
  if (length - 1 > INT_MAX)
    return foo_error("Overflow");
  char *line = malloc(length);
  if (!line)
    return foo_error("OutOfMemory");
  foo_transfer(line, name.data, name.len);
  line[name.len] = ':';
  line[name.len + 1] = ' ';
  foo_transfer(line + name.len + 2, content.data, content.len);
  line[length - 1] = 0;
#ifdef _WIN32
  int wide_length = MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, line,
                                        (int)(length - 1), NULL, 0);
  if (!wide_length) {
    free(line);
    return foo_error("InvalidHeader");
  }
  size_t total = value->header_length + (size_t)wide_length + 2;
  if (total > SIZE_MAX / sizeof(wchar_t)) {
    free(line);
    return foo_error("Overflow");
  }
  wchar_t *headers = realloc(value->headers, (total + 1) * sizeof(wchar_t));
  if (!headers) {
    free(line);
    return foo_error("OutOfMemory");
  }
  value->headers = headers;
  if (!MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, line,
                           (int)(length - 1), headers + value->header_length,
                           wide_length)) {
    free(line);
    return foo_error("InvalidHeader");
  }
  value->header_length += (size_t)wide_length;
  headers[value->header_length++] = L'\r';
  headers[value->header_length++] = L'\n';
  headers[value->header_length] = 0;
  free(line);
#else
  struct curl_slist *headers = curl_slist_append(value->headers, line);
  free(line);
  if (!headers)
    return foo_error("OutOfMemory");
  value->headers = headers;
#endif
  return (FOOResult){0};
}
static void foo_http_clearHeaders(void *pointer) {
  FOOClient *value = pointer;
#ifdef _WIN32
  free(value->headers);
  value->headers = NULL;
  value->header_length = 0;
#else
  curl_slist_free_all(value->headers);
  value->headers = NULL;
#endif
}
static FOOResult foo_http_redirects(void *pointer, uint16_t limit) {
  if (limit > 100)
    return foo_error("InvalidRedirectLimit");
  ((FOOClient *)pointer)->redirects = limit;
  return (FOOResult){0};
}
static void foo_http_reuse(void *pointer, bool enabled) {
  ((FOOClient *)pointer)->reuse = enabled;
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
    foo_transfer(response->bytes + response->length, data, length);
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
#ifdef _WIN32
static wchar_t *foo_wstring(FOOText value) {
  if (value.len > INT_MAX)
    return NULL;
  int length = MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS,
                                   (const char *)value.data, (int)value.len,
                                   NULL, 0);
  if (!length && value.len)
    return NULL;
  wchar_t *result = malloc(((size_t)length + 1) * sizeof(*result));
  if (!result)
    return NULL;
  if (length && !MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS,
                                     (const char *)value.data, (int)value.len,
                                     result, length)) {
    free(result);
    return NULL;
  }
  result[length] = 0;
  return result;
}
#endif
static FOOResult foo_http_request(void *pointer, FOOText url, FOOText method,
                                  FOOText content, uint32_t limit) {
  FOOClient *value = pointer;
  if (!foo_method(method))
    return foo_error("InvalidMethod");
#ifdef _WIN32
  if (content.len > UINT32_MAX)
    return foo_error("Overflow");
  wchar_t *address = foo_wstring(url), *verb = foo_wstring(method);
  if (!address || !verb) {
    free(address);
    free(verb);
    return foo_error("InvalidUrl");
  }
  URL_COMPONENTS parts = {0};
  parts.dwStructSize = sizeof(parts);
  parts.dwSchemeLength = (DWORD)-1;
  parts.dwHostNameLength = (DWORD)-1;
  parts.dwUrlPathLength = (DWORD)-1;
  parts.dwExtraInfoLength = (DWORD)-1;
  if (!WinHttpCrackUrl(address, 0, 0, &parts) ||
      (parts.nScheme != INTERNET_SCHEME_HTTP &&
       parts.nScheme != INTERNET_SCHEME_HTTPS)) {
    free(address);
    free(verb);
    return foo_error("InvalidUrl");
  }
  wchar_t *host = malloc(((size_t)parts.dwHostNameLength + 1) * sizeof(*host));
  size_t path_length = (size_t)parts.dwUrlPathLength + parts.dwExtraInfoLength;
  wchar_t *path = malloc((path_length + 2) * sizeof(*path));
  if (!host || !path) {
    free(address);
    free(verb);
    free(host);
    free(path);
    return foo_error("OutOfMemory");
  }
  memcpy(host, parts.lpszHostName, parts.dwHostNameLength * sizeof(*host));
  host[parts.dwHostNameLength] = 0;
  size_t offset = 0;
  if (parts.dwUrlPathLength) {
    memcpy(path, parts.lpszUrlPath, parts.dwUrlPathLength * sizeof(*path));
    offset = parts.dwUrlPathLength;
  } else {
    path[offset++] = L'/';
  }
  if (parts.dwExtraInfoLength) {
    memcpy(path + offset, parts.lpszExtraInfo,
           parts.dwExtraInfoLength * sizeof(*path));
    offset += parts.dwExtraInfoLength;
  }
  path[offset] = 0;
  HINTERNET connection = WinHttpConnect(value->session, host,
                                         parts.nPort, 0);
  HINTERNET request = connection
                          ? WinHttpOpenRequest(
                                connection, verb, path, NULL,
                                WINHTTP_NO_REFERER, WINHTTP_DEFAULT_ACCEPT_TYPES,
                                parts.nScheme == INTERNET_SCHEME_HTTPS
                                    ? WINHTTP_FLAG_SECURE
                                    : 0)
                          : NULL;
  free(address);
  free(verb);
  free(host);
  free(path);
  if (!request) {
    if (connection)
      WinHttpCloseHandle(connection);
    return foo_error("HttpFailed");
  }
  DWORD redirects = value->redirects;
  if (redirects) {
    WinHttpSetOption(request, WINHTTP_OPTION_MAX_HTTP_AUTOMATIC_REDIRECTS,
                     &redirects, sizeof(redirects));
  } else {
    DWORD disabled = WINHTTP_DISABLE_REDIRECTS;
    WinHttpSetOption(request, WINHTTP_OPTION_DISABLE_FEATURE,
                     &disabled, sizeof(disabled));
  }
  if (value->headers &&
      !WinHttpAddRequestHeaders(request, value->headers, (DWORD)-1,
                                WINHTTP_ADDREQ_FLAG_ADD)) {
    WinHttpCloseHandle(request);
    WinHttpCloseHandle(connection);
    return foo_error("InvalidHeader");
  }
  if (!value->reuse)
    WinHttpAddRequestHeaders(request, L"Connection: close\r\n", (DWORD)-1,
                             WINHTTP_ADDREQ_FLAG_ADD | WINHTTP_ADDREQ_FLAG_REPLACE);
  bool sent = WinHttpSendRequest(
                  request, WINHTTP_NO_ADDITIONAL_HEADERS, 0,
                  content.len ? (void *)content.data : WINHTTP_NO_REQUEST_DATA,
                  (DWORD)content.len, (DWORD)content.len, 0) &&
              WinHttpReceiveResponse(request, NULL);
  DWORD status = 0, status_size = sizeof(status);
  if (sent)
    sent = WinHttpQueryHeaders(request,
                               WINHTTP_QUERY_STATUS_CODE | WINHTTP_QUERY_FLAG_NUMBER,
                               WINHTTP_HEADER_NAME_BY_INDEX, &status,
                               &status_size, WINHTTP_NO_HEADER_INDEX);
  FOOResponse *response = sent ? calloc(1, sizeof(*response)) : NULL;
  if (sent && !response)
    sent = false;
  if (response) {
    response->bytes = malloc(limit ? limit : 1);
    response->limit = limit;
    response->code = (uint16_t)status;
    if (!response->bytes)
      sent = false;
  }
  while (sent) {
    DWORD available = 0;
    if (!WinHttpQueryDataAvailable(request, &available)) {
      sent = false;
      break;
    }
    if (!available)
      break;
    if (available > limit - response->length) {
      sent = false;
      break;
    }
    DWORD received = 0;
    if (!WinHttpReadData(request, response->bytes + response->length,
                         available, &received)) {
      sent = false;
      break;
    }
    response->length += received;
  }
  WinHttpCloseHandle(request);
  WinHttpCloseHandle(connection);
  if (!sent || !response) {
    if (response) {
      free(response->bytes);
      free(response);
    }
    return foo_error("HttpFailed");
  }
  return (FOOResult){.pointer = response};
#else
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
  curl_easy_setopt(curl, CURLOPT_FOLLOWLOCATION,
                   value->redirects ? 1L : 0L);
  curl_easy_setopt(curl, CURLOPT_MAXREDIRS, (long)value->redirects);
  curl_easy_setopt(curl, CURLOPT_FORBID_REUSE, value->reuse ? 0L : 1L);
  if (value->headers)
    curl_easy_setopt(curl, CURLOPT_HTTPHEADER, value->headers);
  curl_easy_setopt(curl, CURLOPT_NOSIGNAL, 1L);
  curl_easy_setopt(curl, CURLOPT_SSL_VERIFYPEER, 1L);
  curl_easy_setopt(curl, CURLOPT_SSL_VERIFYHOST, 2L);
  curl_easy_setopt(curl, CURLOPT_HTTP_VERSION, (long)CURL_HTTP_VERSION_1_1);
  if (value->certificate)
    curl_easy_setopt(curl, CURLOPT_CAINFO, value->certificate);
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
#endif
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
#ifdef _WIN32
  WinHttpCloseHandle(value->session);
  free(value->headers);
#else
  curl_easy_cleanup(value->handle);
  curl_slist_free_all(value->headers);
  free(value->certificate);
#endif
  free(value);
}

typedef struct {
  FOOHttpSocket socket;
  uint16_t port;
} FOOServer;
typedef struct {
  FOOHttpSocket socket;
  char head[16385];
  char *method, *target;
  char *names[128], *values[128];
  size_t headers;
  uint64_t remaining;
  bool request, consumed, chunked, reuse, expect;
} FOOPeer;
static bool foo_http_interrupted(void) {
#ifdef _WIN32
  return WSAGetLastError() == WSAEINTR;
#else
  return errno == EINTR;
#endif
}
static bool foo_send(FOOHttpSocket socket, const void *data, size_t length) {
  const uint8_t *bytes = data;
  while (length) {
    int chunk = length > INT_MAX ? INT_MAX : (int)length;
#ifdef MSG_NOSIGNAL
    int flags = MSG_NOSIGNAL;
#else
    int flags = 0;
#endif
    int count = (int)send(socket, (const char *)bytes, chunk, flags);
    if (count < 0 && foo_http_interrupted())
      continue;
    if (count <= 0)
      return false;
    bytes += count;
    length -= (size_t)count;
  }
  return true;
}
static bool foo_receive(FOOHttpSocket socket, void *data, size_t length) {
  uint8_t *bytes = data;
  while (length) {
    int chunk = length > INT_MAX ? INT_MAX : (int)length;
    int count = (int)recv(socket, (char *)bytes, chunk, 0);
    if (count < 0 && foo_http_interrupted())
      continue;
    if (count <= 0)
      return false;
    bytes += count;
    length -= (size_t)count;
  }
  return true;
}
static FOOResult foo_http_listen(FOOText host, uint16_t port) {
#ifdef _WIN32
  static bool sockets;
  foo_enter();
  if (!sockets) {
    WSADATA data;
    if (WSAStartup(MAKEWORD(2, 2), &data)) {
      foo_leave();
      return foo_error("SocketFailed");
    }
    sockets = true;
  }
  foo_leave();
#endif
  char *address = foo_cstring(host);
  if (!address)
    return foo_error("InvalidAddress");
  struct sockaddr_storage storage = {0};
  FOOHttpSocklen length;
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
  FOOHttpSocket fd = socket(family, SOCK_STREAM, 0);
  if (fd == FOO_HTTP_INVALID)
    return foo_error("SocketFailed");
  int yes = 1;
  setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, (const char *)&yes, sizeof(yes));
  if (bind(fd, (struct sockaddr *)&storage, length) || listen(fd, 128) ||
      getsockname(fd, (struct sockaddr *)&storage, &length)) {
    FOO_HTTP_CLOSE(fd);
    return foo_error("ListenFailed");
  }
  FOOServer *server = malloc(sizeof(*server));
  if (!server) {
    FOO_HTTP_CLOSE(fd);
    return foo_error("OutOfMemory");
  }
  *server =
      (FOOServer){fd, ntohs(family == AF_INET ? v4->sin_port : v6->sin6_port)};
  return (FOOResult){.pointer = server};
}
static uint16_t foo_http_port(void *value) {
  return ((FOOServer *)value)->port;
}
static void foo_http_closeServer(void *value) {
  FOO_HTTP_CLOSE(((FOOServer *)value)->socket);
  free(value);
}
static FOOResult foo_http_accept(void *value) {
  FOOHttpSocket fd;
  do {
    fd = accept(((FOOServer *)value)->socket, NULL, NULL);
  } while (fd == FOO_HTTP_INVALID && foo_http_interrupted());
  if (fd == FOO_HTTP_INVALID)
    return foo_error("AcceptFailed");
  FOOPeer *peer = calloc(1, sizeof(*peer));
  if (!peer) {
    FOO_HTTP_CLOSE(fd);
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
    shutdown(peer->socket, FOO_HTTP_SHUT_WRITE);
  return sent ? (FOOResult){0} : foo_error("WriteFailed");
}
static void foo_http_disconnect(void *value) {
  FOO_HTTP_CLOSE(((FOOPeer *)value)->socket);
  free(value);
}
