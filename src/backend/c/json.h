/* Lossless JSON tree. Numbers retain their source spelling; keys are compared
 * decoded. Limit nesting to 256, matching an explicit runtime resource bound.
 */
typedef struct FOOJson {
  char kind;
  FOOText raw, key;
  struct FOOJson *child, *next;
} FOOJson;
typedef struct {
  FOOText source;
  size_t index;
  unsigned depth;
  const char *error;
} FOOParser;
static void foo_json_release(void *value) {
  FOOJson *node = value;
  if (!node)
    return;
  FOOJson *child = node->child;
  while (child) {
    FOOJson *next = child->next;
    foo_json_release(child);
    child = next;
  }
  free((void *)node->raw.data);
  free((void *)node->key.data);
  free(node);
}
static void foo_space(FOOParser *p) {
  while (p->index < p->source.len &&
         strchr(" \t\r\n", p->source.data[p->index]) &&
         p->source.data[p->index])
    p->index++;
}
static int foo_hex(uint8_t c) {
  return c >= '0' && c <= '9'   ? c - '0'
         : c >= 'a' && c <= 'f' ? c - 'a' + 10
         : c >= 'A' && c <= 'F' ? c - 'A' + 10
                                : -1;
}
static bool foo_quad(FOOParser *p, uint32_t *point) {
  *point = 0;
  for (unsigned k = 0; k < 4; k++) {
    if (p->index == p->source.len)
      return false;
    int h = foo_hex(p->source.data[p->index++]);
    if (h < 0)
      return false;
    *point = *point * 16 + (unsigned)h;
  }
  return true;
}
static bool foo_string(FOOParser *p, FOOText *decoded) {
  if (p->index == p->source.len || p->source.data[p->index++] != '"')
    return false;
  uint8_t *data = malloc(p->source.len - p->index + 1);
  if (!data) {
    p->error = "OutOfMemory";
    return false;
  }
  size_t length = 0;
  while (p->index < p->source.len) {
    uint8_t c = p->source.data[p->index++];
    if (c == '"') {
      *decoded = (FOOText){data, length};
      return true;
    }
    if (c < 32)
      break;
    if (c != '\\') {
      data[length++] = c;
      continue;
    }
    if (p->index == p->source.len)
      break;
    c = p->source.data[p->index++];
    if (c == '"' || c == '\\' || c == '/')
      data[length++] = c;
    else if (c == 'b')
      data[length++] = 8;
    else if (c == 'f')
      data[length++] = 12;
    else if (c == 'n')
      data[length++] = 10;
    else if (c == 'r')
      data[length++] = 13;
    else if (c == 't')
      data[length++] = 9;
    else if (c == 'u') {
      uint32_t point;
      if (!foo_quad(p, &point))
        break;
      if (point >= 0xd800 && point <= 0xdbff) {
        if (p->source.len - p->index < 6 ||
            p->source.data[p->index++] != '\\' ||
            p->source.data[p->index++] != 'u')
          break;
        uint32_t low;
        if (!foo_quad(p, &low) || low < 0xdc00 || low > 0xdfff)
          break;
        point = 0x10000 + (point - 0xd800) * 1024 + low - 0xdc00;
      } else if (point >= 0xdc00 && point <= 0xdfff)
        break;
      length += foo_encode(data + length, point);
    } else
      break;
  }
  free(data);
  return false;
}
static FOOJson *foo_node(FOOParser *p) {
  foo_space(p);
  if (p->index == p->source.len || ++p->depth > 256) {
    p->error = "InvalidJson";
    return NULL;
  }
  FOOJson *node = calloc(1, sizeof(*node));
  if (!node) {
    p->error = "OutOfMemory";
    return NULL;
  }
  size_t start = p->index;
  uint8_t c = p->source.data[p->index];
  if (c == '[' || c == '{') {
    node->kind = (char)c;
    p->index++;
    foo_space(p);
    uint8_t end = c == '[' ? ']' : '}';
    FOOJson **tail = &node->child;
    if (p->index < p->source.len && p->source.data[p->index] == end)
      p->index++;
    else
      for (;;) {
        FOOText key = {0};
        if (c == '{') {
          if (!foo_string(p, &key))
            goto failed;
          for (FOOJson *child = node->child; child; child = child->next)
            if (child->key.len == key.len &&
                !memcmp(child->key.data, key.data, key.len)) {
              free((void *)key.data);
              p->error = "DuplicateField";
              goto failed;
            }
          foo_space(p);
          if (p->index == p->source.len || p->source.data[p->index++] != ':') {
            free((void *)key.data);
            goto failed;
          }
        }
        FOOJson *child = foo_node(p);
        if (!child) {
          free((void *)key.data);
          goto failed;
        }
        child->key = key;
        *tail = child;
        tail = &child->next;
        foo_space(p);
        if (p->index == p->source.len)
          goto failed;
        uint8_t separator = p->source.data[p->index++];
        if (separator == end)
          break;
        if (separator != ',')
          goto failed;
        foo_space(p);
      }
  } else if (c == '"') {
    node->kind = 's';
    if (!foo_string(p, &node->raw))
      goto failed;
  } else if (c == 't' || c == 'f' || c == 'n') {
    const char *word = c == 't' ? "true" : c == 'f' ? "false" : "null";
    size_t length = strlen(word);
    if (p->source.len - p->index < length ||
        memcmp(p->source.data + p->index, word, length))
      goto failed;
    node->kind = (char)c;
    p->index += length;
  } else {
    node->kind = 'd';
    if (c == '-')
      p->index++;
    if (p->index == p->source.len)
      goto failed;
    c = p->source.data[p->index++];
    if (c >= '1' && c <= '9') {
      while (p->index < p->source.len && p->source.data[p->index] >= '0' &&
             p->source.data[p->index] <= '9')
        p->index++;
    } else if (c != '0')
      goto failed;
    if (p->index < p->source.len && p->source.data[p->index] == '.') {
      p->index++;
      size_t digits = p->index;
      while (p->index < p->source.len && p->source.data[p->index] >= '0' &&
             p->source.data[p->index] <= '9')
        p->index++;
      if (p->index == digits)
        goto failed;
    }
    if (p->index < p->source.len &&
        (p->source.data[p->index] == 'e' || p->source.data[p->index] == 'E')) {
      p->index++;
      if (p->index < p->source.len &&
          (p->source.data[p->index] == '+' || p->source.data[p->index] == '-'))
        p->index++;
      size_t digits = p->index;
      while (p->index < p->source.len && p->source.data[p->index] >= '0' &&
             p->source.data[p->index] <= '9')
        p->index++;
      if (p->index == digits)
        goto failed;
    }
  }
  if (node->kind != 's' && node->kind != '[' && node->kind != '{') {
    size_t length = p->index - start;
    uint8_t *data = malloc(length ? length : 1);
    if (!data) {
      p->error = "OutOfMemory";
      goto failed;
    }
    memcpy(data, p->source.data + start, length);
    node->raw = (FOOText){data, length};
  }
  p->depth--;
  return node;
failed:
  if (!p->error)
    p->error = "InvalidJson";
  foo_json_release(node);
  return NULL;
}
static FOOResult foo_json_parse(FOOText source) {
  if (!foo_unicode_valid(source))
    return foo_error("InvalidUtf8");
  FOOParser parser = {.source = source};
  FOOJson *node = foo_node(&parser);
  foo_space(&parser);
  if (!node || parser.index != source.len) {
    foo_json_release(node);
    return foo_error(parser.error ? parser.error : "InvalidJson");
  }
  return (FOOResult){.pointer = node};
}
typedef struct {
  uint8_t *data;
  size_t length, capacity;
  bool failed;
} FOOWriter;
static void foo_put(FOOWriter *w, const void *data, size_t length) {
  if (w->failed)
    return;
  if (length > SIZE_MAX - w->length) {
    w->failed = true;
    return;
  }
  size_t need = w->length + length;
  if (need > w->capacity) {
    size_t capacity = need > SIZE_MAX / 2 ? need : need * 2;
    void *buffer = realloc(w->data, capacity);
    if (!buffer) {
      w->failed = true;
      return;
    }
    w->data = buffer;
    w->capacity = capacity;
  }
  if (length)
    memcpy(w->data + w->length, data, length);
  w->length = need;
}
static void foo_quote(FOOWriter *w, FOOText value) {
  foo_put(w, "\"", 1);
  for (size_t k = 0; k < value.len; k++) {
    uint8_t c = value.data[k];
    if (c == '"' || c == '\\') {
      foo_put(w, "\\", 1);
      foo_put(w, &c, 1);
    } else if (c == '\n' || c == '\r' || c == '\t' || c == '\b' || c == '\f') {
      const char escaped[] = {'\\', c == '\n'   ? 'n'
                                    : c == '\r' ? 'r'
                                    : c == '\t' ? 't'
                                    : c == '\b' ? 'b'
                                                : 'f'};
      foo_put(w, escaped, 2);
    } else if (c < 32) {
      char escaped[7];
      snprintf(escaped, sizeof(escaped), "\\u%04x", c);
      foo_put(w, escaped, 6);
    } else
      foo_put(w, &c, 1);
  }
  foo_put(w, "\"", 1);
}
static void foo_serialize(FOOWriter *w, FOOJson *node) {
  if (node->kind == 's')
    foo_quote(w, node->raw);
  else if (node->kind == '[' || node->kind == '{') {
    foo_put(w, &node->kind, 1);
    bool first = true;
    for (FOOJson *child = node->child; child; child = child->next) {
      if (!first)
        foo_put(w, ",", 1);
      first = false;
      if (node->kind == '{') {
        foo_quote(w, child->key);
        foo_put(w, ":", 1);
      }
      foo_serialize(w, child);
    }
    foo_put(w, node->kind == '[' ? "]" : "}", 1);
  } else
    foo_put(w, node->raw.data, node->raw.len);
}
static FOOResult foo_json_write(void *value) {
  FOOWriter writer = {0};
  foo_serialize(&writer, value);
  FOOResult result = writer.failed ? foo_error("OutOfMemory")
                                   : foo_copy(writer.data, writer.length);
  free(writer.data);
  return result;
}
static FOOResult foo_json_quote(FOOText value) {
  if (!foo_unicode_valid(value))
    return foo_error("InvalidUtf8");
  FOOWriter writer = {0};
  foo_quote(&writer, value);
  FOOResult result = writer.failed ? foo_error("OutOfMemory")
                                   : foo_copy(writer.data, writer.length);
  free(writer.data);
  return result;
}
static FOOResult foo_json_field(void *value, FOOText name) {
  FOOJson *node = value;
  if (node->kind != '{')
    return foo_error("ExpectedObject");
  for (FOOJson *child = node->child; child; child = child->next)
    if (child->key.len == name.len &&
        !memcmp(child->key.data, name.data, name.len))
      return foo_json_write(child);
  return foo_error("MissingField");
}
static FOOResult foo_json_item(void *value, uint32_t index) {
  FOOJson *node = value;
  if (node->kind != '[')
    return foo_error("ExpectedArray");
  for (FOOJson *child = node->child; child; child = child->next)
    if (index-- == 0)
      return foo_json_write(child);
  return foo_error("IndexOutOfBounds");
}
static FOOText foo_json_kind(void *value) {
  switch (((FOOJson *)value)->kind) {
  case '{':
    return foo_text("object");
  case '[':
    return foo_text("array");
  case 's':
    return foo_text("string");
  case 'd':
    return foo_text("number");
  case 'n':
    return foo_text("null");
  default:
    return foo_text("bool");
  }
}
static FOOResult foo_json_size(void *value) {
  FOOJson *node = value;
  if (node->kind == 's')
    return (FOOResult){.number = node->raw.len};
  if (node->kind != '{' && node->kind != '[')
    return foo_error("ExpectedContainer");
  uint64_t count = 0;
  for (FOOJson *child = node->child; child; child = child->next)
    count++;
  if (count > UINT32_MAX)
    return foo_error("Overflow");
  return (FOOResult){.number = count};
}
static FOOResult foo_json_set(void *value, FOOText name, FOOText source) {
  FOOJson *node = value;
  if (node->kind != '{')
    return foo_error("ExpectedObject");
  if (!foo_unicode_valid(name))
    return foo_error("InvalidUtf8");
  FOOResult parsed = foo_json_parse(source);
  if (parsed.error)
    return parsed;
  FOOJson *replacement = parsed.pointer;
  uint8_t *key = malloc(name.len ? name.len : 1);
  if (!key) {
    foo_json_release(replacement);
    return foo_error("OutOfMemory");
  }
  memcpy(key, name.data, name.len);
  replacement->key = (FOOText){key, name.len};
  FOOJson **cursor = &node->child;
  while (*cursor && ((*cursor)->key.len != name.len ||
                     memcmp((*cursor)->key.data, name.data, name.len)))
    cursor = &(*cursor)->next;
  FOOJson *old = *cursor;
  if (old)
    replacement->next = old->next;
  *cursor = replacement;
  foo_json_release(old);
  return (FOOResult){0};
}
static FOOResult foo_json_append(void *value, FOOText source) {
  FOOJson *node = value;
  if (node->kind != '[')
    return foo_error("ExpectedArray");
  FOOResult parsed = foo_json_parse(source);
  if (parsed.error)
    return parsed;
  FOOJson **tail = &node->child;
  while (*tail)
    tail = &(*tail)->next;
  *tail = parsed.pointer;
  return (FOOResult){0};
}

/* Incremental scanner. Container state is bounded; at most one incomplete
 * scalar is retained between feeds. Fragment boundaries are not a cross-backend
 * ABI. */
typedef struct {
  uint8_t *bytes;
  size_t length, index;
  FOOText token;
  unsigned states[257], depth;
  bool ready, ended, failed;
} FOOStream;
static FOOResult foo_json_stream(void) {
  FOOStream *stream = calloc(1, sizeof(*stream));
  if (!stream)
    return foo_error("OutOfMemory");
  stream->ready = true;
  return (FOOResult){.pointer = stream};
}
static void foo_json_close(void *value) {
  FOOStream *stream = value;
  free(stream->bytes);
  free((void *)stream->token.data);
  free(stream);
}
static FOOResult foo_json_feed(void *value, FOOText chunk, bool final) {
  FOOStream *stream = value;
  if (!stream->ready || stream->ended || stream->failed)
    return foo_error("InvalidState");
  size_t remaining = stream->length - stream->index;
  if (chunk.len > SIZE_MAX - remaining)
    return foo_error("OutOfMemory");
  uint8_t *bytes = malloc(remaining + chunk.len + (remaining + chunk.len == 0));
  if (!bytes)
    return foo_error("OutOfMemory");
  if (remaining)
    memcpy(bytes, stream->bytes + stream->index, remaining);
  if (chunk.len)
    memcpy(bytes + remaining, chunk.data, chunk.len);
  free(stream->bytes);
  free((void *)stream->token.data);
  stream->token = (FOOText){0};
  stream->bytes = bytes;
  stream->length = remaining + chunk.len;
  stream->index = 0;
  stream->ready = false;
  stream->ended = final;
  return (FOOResult){0};
}
static FOOResult foo_stream_error(FOOStream *stream, const char *error) {
  stream->failed = true;
  free((void *)stream->token.data);
  stream->token = (FOOText){0};
  return foo_error(error);
}
static FOOResult foo_more(FOOStream *stream) {
  if (stream->ended)
    return foo_stream_error(stream, "UnexpectedEndOfInput");
  stream->ready = true;
  return (FOOResult){.text = foo_text("more")};
}
static FOOResult foo_json_next(void *value) {
  FOOStream *stream = value;
  if (stream->failed)
    return foo_error("InvalidState");
  free((void *)stream->token.data);
  stream->token = (FOOText){0};
  for (;;) {
    while (stream->index < stream->length && stream->bytes[stream->index] &&
           strchr(" \t\r\n", stream->bytes[stream->index]))
      stream->index++;
    unsigned state = stream->states[stream->depth];
    if (stream->index == stream->length) {
      if (state == 7 && stream->ended)
        return (FOOResult){.text = foo_text("end_of_document")};
      return foo_more(stream);
    }
    uint8_t c = stream->bytes[stream->index];
    if (state == 7)
      return foo_stream_error(stream, "SyntaxError");
    if (state == 2 || state == 6) {
      if (c == ',') {
        stream->index++;
        stream->states[stream->depth] = state == 2 ? 8 : 9;
        continue;
      }
      if ((state == 2 && c == ']') || (state == 6 && c == '}')) {
        stream->index++;
        stream->depth--;
        return (FOOResult){.text =
                               foo_text(c == ']' ? "array_end" : "object_end")};
      }
      return foo_stream_error(stream, "SyntaxError");
    }
    if (state == 4) {
      if (c != ':')
        return foo_stream_error(stream, "SyntaxError");
      stream->index++;
      stream->states[stream->depth] = 5;
      continue;
    }
    if ((state == 1 && c == ']') || (state == 3 && c == '}')) {
      stream->index++;
      stream->depth--;
      return (FOOResult){.text =
                             foo_text(c == ']' ? "array_end" : "object_end")};
    }
    bool key = state == 3 || state == 9;
    if (key && c != '"')
      return foo_stream_error(stream, "SyntaxError");
    if (c == '[' || c == '{') {
      if (key || stream->depth == 256)
        return foo_stream_error(stream, "SyntaxError");
      stream->states[stream->depth] = state == 0 ? 7 : state == 5 ? 6 : 2;
      stream->states[++stream->depth] = c == '[' ? 1 : 3;
      stream->index++;
      return (FOOResult){
          .text = foo_text(c == '[' ? "array_begin" : "object_begin")};
    }
    size_t start = stream->index, end = start;
    const char *token;
    if (c == '"') {
      end++;
      bool escaped = false, closed = false;
      for (; end < stream->length; end++) {
        uint8_t byte = stream->bytes[end];
        if (escaped) {
          escaped = false;
          continue;
        }
        if (byte == '\\')
          escaped = true;
        else if (byte == '"') {
          end++;
          closed = true;
          break;
        }
      }
      if (!closed)
        return foo_more(stream);
      token = "string";
    } else if (c == 't' || c == 'f' || c == 'n') {
      token = c == 't' ? "true" : c == 'f' ? "false" : "null";
      size_t length = strlen(token);
      if (stream->length - start < length)
        return foo_more(stream);
      end = start + length;
    } else if (c == '-' || (c >= '0' && c <= '9')) {
      while (end < stream->length && stream->bytes[end] &&
             strchr("-+0123456789.eE", stream->bytes[end]))
        end++;
      if (end == stream->length && !stream->ended)
        return foo_more(stream);
      token = "number";
    } else
      return foo_stream_error(stream, "SyntaxError");
    FOOResult parsed =
        foo_json_parse((FOOText){stream->bytes + start, end - start});
    if (parsed.error)
      return foo_stream_error(stream, "SyntaxError");
    FOOJson *node = parsed.pointer;
    if (node->kind == 's' || node->kind == 'd') {
      stream->token = node->raw;
      node->raw = (FOOText){0};
    }
    foo_json_release(node);
    stream->index = end;
    stream->states[stream->depth] = key          ? 4
                                    : state == 0 ? 7
                                    : state == 5 ? 6
                                                 : 2;
    return (FOOResult){.text = foo_text(token)};
  }
}
static FOOResult foo_json_data(void *value) {
  FOOStream *stream = value;
  return foo_copy(stream->token.data, stream->token.len);
}
