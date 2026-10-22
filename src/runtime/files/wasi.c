typedef struct {
  FILE *handle;
  int borrowed;
  int mode;
} File;

static File standard[3];

static FooResult stream(FILE *handle, int index) {
  standard[index] = (File){handle, 1, 0};
  return (FooResult){.pointer = &standard[index]};
}

static File *file(void *pointer) {
  for (int index = 0; index < 3; index++)
    if (pointer == &standard[index]) return &standard[index];
  return entry(pointer, FILE_RESOURCE) ? pointer : NULL;
}

static char *pathname(FooText value) {
  if (!value.data || !value.len || value.len >= SIZE_MAX ||
      memchr(value.data, 0, (size_t)value.len)) return NULL;
  char *copy = malloc((size_t)value.len + 1);
  if (!copy) return NULL;
  memcpy(copy, value.data, (size_t)value.len);
  copy[value.len] = 0;
  return copy;
}

FooResult foo_io_input(void) { return stream(stdin, 0); }
FooResult foo_io_output(void) { return stream(stdout, 1); }
FooResult foo_io_report(void) { return stream(stderr, 2); }

FooResult foo_io_write(void *pointer, FooText value) {
  File *opened = file(pointer);
  if (!opened || !opened->handle) return failure(CLOSED);
  if (value.len > SIZE_MAX || (value.len && !value.data)) return failure(ARGUMENT);
  if (value.len && fwrite(value.data, 1, (size_t)value.len, opened->handle) != value.len)
    return failure(IO);
  return fflush(opened->handle) ? failure(IO) : (FooResult){0};
}

FooResult foo_io_read(void *pointer, uint64_t size) {
  File *opened = file(pointer);
  if (!opened || !opened->handle) return failure(CLOSED);
  if (size > SIZE_MAX) return failure(BOUNDS);
  if (!size) return (FooResult){0};
  uint8_t *buffer = malloc((size_t)size);
  if (!buffer) return failure(MEMORY);
  size_t count = fread(buffer, 1, (size_t)size, opened->handle);
  FooResult result = ferror(opened->handle) ? failure(IO) : copied(buffer, count);
  free(buffer);
  return result;
}

FooResult foo_io_line(void *pointer) {
  File *opened = file(pointer);
  if (!opened || !opened->handle) return failure(CLOSED);
  size_t size = 0, capacity = 128;
  uint8_t *buffer = malloc(capacity);
  if (!buffer) return failure(MEMORY);
  int byte;
  while ((byte = fgetc(opened->handle)) != EOF && byte != '\n') {
    if (size == capacity) {
      if (capacity > SIZE_MAX / 2) { free(buffer); return failure(BOUNDS); }
      uint8_t *next = realloc(buffer, capacity * 2);
      if (!next) { free(buffer); return failure(MEMORY); }
      buffer = next;
      capacity *= 2;
    }
    buffer[size++] = (uint8_t)byte;
  }
  if (size && buffer[size - 1] == '\r') size--;
  FooResult result = ferror(opened->handle) ? failure(IO) : copied(buffer, size);
  free(buffer);
  return result;
}

FooResult foo_io_close(void *pointer) {
  File *opened = file(pointer);
  if (!opened || !opened->handle) return failure(CLOSED);
  if (opened->borrowed) return failure(ARGUMENT);
  int status = fclose(opened->handle);
  opened->handle = NULL;
  retire(entry(pointer, FILE_RESOURCE));
  return status ? failure(IO) : (FooResult){0};
}

FooResult foo_fs_open(FooText path, FooText mode) {
  char *name = pathname(path);
  char *access = pathname(mode);
  if (!name || !access) { free(name); free(access); return failure(ARGUMENT); }
  const char *flags = !strcmp(access, "read") ? "rb" :
    !strcmp(access, "write") ? "wb" :
    !strcmp(access, "append") ? "ab" :
    !strcmp(access, "update") ? "r+b" :
    !strcmp(access, "create") ? "wx+b" : NULL;
  if (!flags) { free(name); free(access); return failure(ARGUMENT); }
  FILE *handle = fopen(name, flags);
  int reason = errno;
  free(name);
  free(access);
  if (!handle) return failure(reason == ENOENT ? MISSING : IO);
  File *opened = owned(sizeof(*opened), FILE_RESOURCE);
  if (!opened) { fclose(handle); return failure(MEMORY); }
  opened->handle = handle;
  opened->mode = !strcmp(flags, "rb") ? 1 :
    !strcmp(flags, "wb") ? 2 : !strcmp(flags, "ab") ? 3 : 4;
  return (FooResult){.pointer = opened};
}

FooResult foo_fs_read(FooText path) {
  FooResult opened = foo_fs_open(path, (FooText){(const uint8_t *)"read", 4});
  if (opened.error) return opened;
  File *stream = opened.pointer;
  size_t size = 0, capacity = 4096;
  uint8_t *buffer = malloc(capacity);
  if (!buffer) { foo_io_close(stream); return failure(MEMORY); }
  for (;;) {
    size_t count = fread(buffer + size, 1, capacity - size, stream->handle);
    size += count;
    if (size < capacity) break;
    if (capacity > SIZE_MAX / 2) { free(buffer); foo_io_close(stream); return failure(BOUNDS); }
    uint8_t *next = realloc(buffer, capacity * 2);
    if (!next) { free(buffer); foo_io_close(stream); return failure(MEMORY); }
    buffer = next;
    capacity *= 2;
  }
  FooResult result = ferror(stream->handle) ? failure(IO) : copied(buffer, size);
  free(buffer);
  FooResult closed = foo_io_close(stream);
  return result.error ? result : closed.error ? closed : result;
}

FooResult foo_fs_write(FooText path, FooText value) {
  FooResult opened = foo_fs_open(path, (FooText){(const uint8_t *)"write", 5});
  if (opened.error) return opened;
  FooResult result = foo_io_write(opened.pointer, value);
  FooResult closed = foo_io_close(opened.pointer);
  return result.error ? result : closed;
}

FooResult foo_fs_load(FooText path) { return foo_fs_read(path); }
FooResult foo_fs_save(FooText path, FooText value) { return foo_fs_write(path, value); }
FooResult foo_fs_release(FooText value) { return foo_text_release(value); }

FooResult foo_fs_directory(FooText path) {
  char *name = pathname(path);
  if (!name) return failure(ARGUMENT);
  int created = mkdir(name, 0777);
  int reason = errno;
  struct stat status;
  int existing = created && reason == EEXIST && !stat(name, &status) &&
    S_ISDIR(status.st_mode);
  free(name);
  return !created || existing ? (FooResult){0} : failure(IO);
}

typedef struct { DIR *handle; } Directory;

FooResult foo_fs_scan(FooText path) {
  char *name = pathname(path);
  if (!name) return failure(ARGUMENT);
  DIR *handle = opendir(name);
  free(name);
  if (!handle) return failure(IO);
  Directory *cursor = owned(sizeof(*cursor), DIRECTORY_RESOURCE);
  if (!cursor) { closedir(handle); return failure(MEMORY); }
  cursor->handle = handle;
  return (FooResult){.pointer = cursor};
}

FooResult foo_fs_next(void *pointer) {
  Entry *item = entry(pointer, DIRECTORY_RESOURCE);
  if (!item) return failure(CLOSED);
  Directory *cursor = pointer;
  for (;;) {
    errno = 0;
    struct dirent *found = readdir(cursor->handle);
    if (!found) return errno ? failure(IO) : (FooResult){0};
    if (!strcmp(found->d_name, ".") || !strcmp(found->d_name, "..")) continue;
    return copied((const uint8_t *)found->d_name, strlen(found->d_name));
  }
}

FooResult foo_fs_finish(void *pointer) {
  Entry *item = entry(pointer, DIRECTORY_RESOURCE);
  if (!item) return failure(CLOSED);
  Directory *cursor = pointer;
  int failed = closedir(cursor->handle);
  cursor->handle = NULL;
  retire(item);
  return failed ? failure(IO) : (FooResult){0};
}

typedef struct { DIR *handle; char *relative; } Frame;
typedef struct {
  char *root;
  Frame *frames;
  size_t count, capacity;
} Walk;

static char *compose(const char *left, const char *right) {
  size_t first = strlen(left), second = strlen(right);
  int separator = first && left[first - 1] != '/';
  if (first > SIZE_MAX - second - (size_t)separator - 1) return NULL;
  char *path = malloc(first + second + (size_t)separator + 1);
  if (!path) return NULL;
  memcpy(path, left, first);
  if (separator) path[first++] = '/';
  memcpy(path + first, right, second + 1);
  return path;
}

static int enqueue(Walk *walk, DIR *handle, char *relative) {
  if (walk->count == walk->capacity) {
    size_t capacity = walk->capacity ? walk->capacity * 2 : 4;
    if (capacity < walk->capacity || capacity > SIZE_MAX / sizeof(Frame))
      return 0;
    Frame *frames = realloc(walk->frames, capacity * sizeof(*frames));
    if (!frames) return 0;
    walk->frames = frames;
    walk->capacity = capacity;
  }
  walk->frames[walk->count++] = (Frame){handle, relative};
  return 1;
}

FooResult foo_fs_walk(FooText path) {
  char *root = pathname(path);
  if (!root) return failure(ARGUMENT);
  DIR *handle = opendir(root);
  if (!handle) { free(root); return failure(IO); }
  Walk *walk = owned(sizeof(*walk), WALK_RESOURCE);
  char *relative = calloc(1, 1);
  if (!walk || !relative || !enqueue(walk, handle, relative)) {
    closedir(handle);
    free(root);
    free(relative);
    if (walk) retire(entry(walk, WALK_RESOURCE));
    return failure(MEMORY);
  }
  walk->root = root;
  return (FooResult){.pointer = walk};
}

FooResult foo_fs_traverse(void *pointer) {
  if (!entry(pointer, WALK_RESOURCE)) return failure(CLOSED);
  Walk *walk = pointer;
  while (walk->count) {
    Frame *frame = &walk->frames[walk->count - 1];
    errno = 0;
    struct dirent *found = readdir(frame->handle);
    if (!found) {
      if (errno) return failure(IO);
      int failed = closedir(frame->handle);
      free(frame->relative);
      walk->count--;
      if (failed) return failure(IO);
      continue;
    }
    if (!strcmp(found->d_name, ".") || !strcmp(found->d_name, "..")) continue;
    char *relative = compose(frame->relative, found->d_name);
    char *full = relative ? compose(walk->root, relative) : NULL;
    if (!full) { free(relative); return failure(MEMORY); }
    struct stat status;
    int failed = lstat(full, &status);
    int descend = !failed && S_ISDIR(status.st_mode);
    if (!failed && descend) {
      DIR *child = opendir(full);
      if (!child) failed = 1;
      else if (!enqueue(walk, child, relative)) {
        closedir(child);
        free(full);
        free(relative);
        return failure(MEMORY);
      }
    }
    free(full);
    if (failed) { free(relative); return failure(IO); }
    FooResult result = copied((const uint8_t *)relative, strlen(relative));
    if (!descend) free(relative);
    return result;
  }
  return (FooResult){0};
}

FooResult foo_fs_cease(void *pointer) {
  Entry *item = entry(pointer, WALK_RESOURCE);
  if (!item) return failure(CLOSED);
  Walk *walk = pointer;
  int failed = 0;
  while (walk->count) {
    Frame *frame = &walk->frames[--walk->count];
    if (closedir(frame->handle)) failed = 1;
    free(frame->relative);
  }
  free(walk->frames);
  free(walk->root);
  walk->frames = NULL;
  walk->root = NULL;
  retire(item);
  return failed ? failure(IO) : (FooResult){0};
}

FooResult foo_fs_join(FooText left, FooText right) {
  if ((left.len && !left.data) || (right.len && !right.data)) return failure(ARGUMENT);
  if (left.len > SIZE_MAX || right.len > SIZE_MAX) return failure(BOUNDS);
  if (!left.len || (right.len && right.data[0] == '/'))
    return copied(right.data, (size_t)right.len);
  if (!right.len) return copied(left.data, (size_t)left.len);
  int separator = left.data[left.len - 1] != '/';
  if (right.len > SIZE_MAX - separator ||
      left.len > SIZE_MAX - right.len - separator) return failure(BOUNDS);
  size_t size = (size_t)(left.len + right.len + separator);
  uint8_t *copy = owned(size, TEXT);
  if (!copy) return failure(MEMORY);
  memcpy(copy, left.data, (size_t)left.len);
  if (separator) copy[left.len] = '/';
  memcpy(copy + left.len + separator, right.data, (size_t)right.len);
  return (FooResult){.text = {copy, size}};
}

FooResult foo_fs_kind(FooText path) {
  char *name = pathname(path);
  if (!name) return failure(ARGUMENT);
  struct stat status;
  int failed = lstat(name, &status);
  int reason = errno;
  free(name);
  if (failed) return failure(reason == ENOENT ? MISSING : IO);
  const char *kind = S_ISLNK(status.st_mode) ? "link" :
    S_ISDIR(status.st_mode) ? "directory" :
    S_ISREG(status.st_mode) ? "file" : "other";
  return copied((const uint8_t *)kind, strlen(kind));
}

typedef struct {
  uint64_t size, modified, accessed, changed;
  int readonly;
  char kind[10];
} Metadata;

static uint64_t epoch(time_t seconds, long nanos) {
  if (seconds < 0 || (uint64_t)seconds > UINT64_MAX / 1000000000)
    return 0;
  return (uint64_t)seconds * 1000000000 + (uint64_t)nanos;
}

FooResult foo_fs_metadata(FooText path) {
  char *name = pathname(path);
  if (!name) return failure(ARGUMENT);
  struct stat status;
  int failed = lstat(name, &status);
  int reason = errno;
  if (failed) { free(name); return failure(reason == ENOENT ? MISSING : IO); }
  int readonly = access(name, W_OK) != 0;
  free(name);
  Metadata *value = owned(sizeof(*value), METADATA_RESOURCE);
  if (!value) return failure(MEMORY);
  value->size = status.st_size < 0 ? 0 : (uint64_t)status.st_size;
  value->modified = epoch(status.st_mtim.tv_sec, status.st_mtim.tv_nsec);
  value->accessed = epoch(status.st_atim.tv_sec, status.st_atim.tv_nsec);
  value->changed = epoch(status.st_ctim.tv_sec, status.st_ctim.tv_nsec);
  value->readonly = readonly;
  const char *kind = S_ISLNK(status.st_mode) ? "link" :
    S_ISDIR(status.st_mode) ? "directory" :
    S_ISREG(status.st_mode) ? "file" : "other";
  strcpy(value->kind, kind);
  return (FooResult){.pointer = value};
}

FooResult foo_fs_measure(void *pointer) {
  return entry(pointer, METADATA_RESOURCE) ?
    (FooResult){.number = ((Metadata *)pointer)->size} : failure(CLOSED);
}

FooResult foo_fs_timestamp(void *pointer, FooText field) {
  if (!entry(pointer, METADATA_RESOURCE)) return failure(CLOSED);
  if (field.len && !field.data) return failure(ARGUMENT);
  Metadata *value = pointer;
  uint64_t selected = field.len == 8 && !memcmp(field.data, "modified", 8) ?
    value->modified : field.len == 8 && !memcmp(field.data, "accessed", 8) ?
    value->accessed : field.len == 7 && !memcmp(field.data, "changed", 7) ?
    value->changed : UINT64_MAX;
  return selected == UINT64_MAX ? failure(ARGUMENT) :
    (FooResult){.number = selected};
}

FooResult foo_fs_classify(void *pointer) {
  if (!entry(pointer, METADATA_RESOURCE)) return failure(CLOSED);
  Metadata *value = pointer;
  return (FooResult){.text = {(const uint8_t *)value->kind, strlen(value->kind)}};
}

FooResult foo_fs_restricted(void *pointer) {
  return entry(pointer, METADATA_RESOURCE) ?
    (FooResult){.number = (uint64_t)((Metadata *)pointer)->readonly} :
    failure(CLOSED);
}

FooResult foo_fs_retire(void *pointer) {
  Entry *item = entry(pointer, METADATA_RESOURCE);
  if (!item) return failure(CLOSED);
  retire(item);
  return (FooResult){0};
}

FooResult foo_fs_flush(void *pointer) {
  File *opened = file(pointer);
  return !opened || !opened->handle ? failure(CLOSED) :
    fflush(opened->handle) ? failure(IO) : (FooResult){0};
}

FooResult foo_fs_sync(void *pointer) {
  File *opened = file(pointer);
  if (!opened || !opened->handle) return failure(CLOSED);
  if (fflush(opened->handle)) return failure(IO);
  return fsync(fileno(opened->handle)) ? failure(IO) : (FooResult){0};
}

FooResult foo_fs_seek(void *pointer, int64_t offset, FooText origin) {
  File *opened = file(pointer);
  if (!opened || !opened->handle) return failure(CLOSED);
  if (origin.len && !origin.data) return failure(ARGUMENT);
  int base = origin.len == 5 && !memcmp(origin.data, "start", 5) ? SEEK_SET :
    origin.len == 7 && !memcmp(origin.data, "current", 7) ? SEEK_CUR :
    origin.len == 3 && !memcmp(origin.data, "end", 3) ? SEEK_END : -1;
  return base < 0 ? failure(ARGUMENT) :
    fseeko(opened->handle, (off_t)offset, base) ? failure(IO) : (FooResult){0};
}

FooResult foo_fs_position(void *pointer) {
  File *opened = file(pointer);
  if (!opened || !opened->handle) return failure(CLOSED);
  off_t position = ftello(opened->handle);
  return position < 0 ? failure(IO) : (FooResult){.number = (uint64_t)position};
}

FooResult foo_fs_size(void *pointer) {
  File *opened = file(pointer);
  if (!opened || !opened->handle) return failure(CLOSED);
  off_t position = ftello(opened->handle);
  if (position < 0 || fseeko(opened->handle, 0, SEEK_END)) return failure(IO);
  off_t size = ftello(opened->handle);
  if (fseeko(opened->handle, position, SEEK_SET)) return failure(IO);
  return size < 0 ? failure(IO) : (FooResult){.number = (uint64_t)size};
}

FooResult foo_fs_truncate(void *pointer, uint64_t size) {
  File *opened = file(pointer);
  if (!opened || !opened->handle) return failure(CLOSED);
  if (opened->mode == 1) return failure(ARGUMENT);
  if (size > INT64_MAX) return failure(BOUNDS);
  if (fflush(opened->handle)) return failure(IO);
  return ftruncate(fileno(opened->handle), (off_t)size) ? failure(IO) :
    (FooResult){0};
}

static FooResult transfer(void *pointer, uint64_t offset, FooText bytes,
                             int writing) {
  File *opened = file(pointer);
  if (!opened || !opened->handle) return failure(CLOSED);
  if ((opened->mode != 4 && opened->mode != (writing ? 2 : 1)) ||
      (bytes.len && !bytes.data)) return failure(ARGUMENT);
  if (offset > INT64_MAX || (bytes.len && offset == INT64_MAX) ||
      bytes.len > SIZE_MAX) return failure(BOUNDS);
  if (!bytes.len) return (FooResult){0};
  if (opened->mode == 4 && fseeko(opened->handle, 0, SEEK_CUR)) return failure(IO);
  if (writing && fflush(opened->handle)) return failure(IO);
  size_t length = (size_t)bytes.len;
  if (length > INT32_MAX) length = INT32_MAX;
  ssize_t count;
  do {
    count = writing ?
      pwrite(fileno(opened->handle), bytes.data, length, (off_t)offset) :
      pread(fileno(opened->handle), (void *)bytes.data, length, (off_t)offset);
  } while (count < 0 && errno == EINTR);
  if (opened->mode == 4 && fseeko(opened->handle, 0, SEEK_CUR)) return failure(IO);
  return count < 0 ? failure(IO) : (FooResult){.number = (uint64_t)count};
}

FooResult foo_fs_readat(void *pointer, uint64_t offset, FooText destination) {
  return transfer(pointer, offset, destination, 0);
}
FooResult foo_fs_writeat(void *pointer, uint64_t offset, FooText source) {
  return transfer(pointer, offset, source, 1);
}
FooResult foo_fs_fetch(void *pointer, uint64_t offset, FooText destination) {
  return foo_fs_readat(pointer, offset, destination);
}
FooResult foo_fs_store(void *pointer, uint64_t offset, FooText source) {
  return foo_fs_writeat(pointer, offset, source);
}
FooResult foo_fs_handle(void *pointer) {
  File *opened = file(pointer);
  if (!opened || !opened->handle) return failure(CLOSED);
  int descriptor = fileno(opened->handle);
  return descriptor < 0 ? failure(IO) :
    (FooResult){.number = (uint64_t)descriptor};
}

typedef struct {
  uint8_t *bytes;
  size_t length;
  uint64_t offset;
  FILE *stream;
  int writable;
} Mapping;

static FooResult mapping(FooText path, uint64_t offset, uint64_t length,
                          int writable) {
  char *name = pathname(path);
  if (!name) return failure(ARGUMENT);
  FILE *stream = fopen(name, writable ? "r+b" : "rb");
  int reason = errno;
  free(name);
  if (!stream) return failure(reason == ENOENT ? MISSING : IO);
  if (fseeko(stream, 0, SEEK_END)) { fclose(stream); return failure(IO); }
  off_t end = ftello(stream);
  if (end < 0) { fclose(stream); return failure(IO); }
  if (offset > (uint64_t)end || (length && length > (uint64_t)end - offset)) {
    fclose(stream);
    return failure(BOUNDS);
  }
  uint64_t count = length ? length : (uint64_t)end - offset;
  if (!count || count > SIZE_MAX || offset > INT64_MAX) {
    fclose(stream);
    return failure(BOUNDS);
  }
  uint8_t *bytes = malloc((size_t)count);
  if (!bytes) { fclose(stream); return failure(MEMORY); }
  if (fseeko(stream, (off_t)offset, SEEK_SET) ||
      fread(bytes, 1, (size_t)count, stream) != count) {
    free(bytes);
    fclose(stream);
    return failure(IO);
  }
  Mapping *mapping = owned(sizeof(*mapping), MAP_RESOURCE);
  if (!mapping) { free(bytes); fclose(stream); return failure(MEMORY); }
  *mapping = (Mapping){bytes, (size_t)count, offset, stream, writable};
  return (FooResult){.pointer = mapping};
}

FooResult foo_fs_map(FooText path, uint64_t offset, uint64_t length) {
  return mapping(path, offset, length, 0);
}
FooResult foo_fs_edit(FooText path, uint64_t offset, uint64_t length) {
  return mapping(path, offset, length, 1);
}
FooResult foo_fs_mapped(void *pointer) {
  Mapping *mapping = pointer;
  return entry(pointer, MAP_RESOURCE) ?
    (FooResult){.text = {mapping->bytes, mapping->length}} : failure(CLOSED);
}
FooResult foo_fs_borrow(void *pointer) {
  Mapping *mapping = pointer;
  if (!entry(pointer, MAP_RESOURCE)) return failure(CLOSED);
  return mapping->writable ?
    (FooResult){.text = {mapping->bytes, mapping->length}} : failure(ARGUMENT);
}

static FooResult publish(Mapping *mapping, size_t start, size_t length) {
  size_t written = 0;
  while (written < length) {
    size_t chunk = length - written;
    if (chunk > INT32_MAX) chunk = INT32_MAX;
    if ((uint64_t)start > INT64_MAX - mapping->offset ||
        (uint64_t)written > INT64_MAX - mapping->offset - start)
      return failure(BOUNDS);
    ssize_t count;
    do {
      count = pwrite(fileno(mapping->stream), mapping->bytes + start + written,
        chunk, (off_t)(mapping->offset + start + written));
    } while (count < 0 && errno == EINTR);
    if (count <= 0) return failure(IO);
    written += (size_t)count;
  }
  return fsync(fileno(mapping->stream)) ? failure(IO) : (FooResult){0};
}

FooResult foo_fs_publish(void *pointer) {
  if (!entry(pointer, MAP_RESOURCE)) return failure(CLOSED);
  Mapping *mapping = pointer;
  return mapping->writable ? publish(mapping, 0, mapping->length) :
    failure(ARGUMENT);
}
FooResult foo_fs_portion(void *pointer, uint64_t offset, uint64_t length) {
  if (!entry(pointer, MAP_RESOURCE)) return failure(CLOSED);
  Mapping *mapping = pointer;
  if (!mapping->writable) return failure(ARGUMENT);
  if (offset > mapping->length || length > mapping->length - offset)
    return failure(BOUNDS);
  return length ? publish(mapping, (size_t)offset, (size_t)length) :
    (FooResult){0};
}
FooResult foo_fs_unmap(void *pointer) {
  Entry *item = entry(pointer, MAP_RESOURCE);
  if (!item) return failure(CLOSED);
  Mapping *mapping = pointer;
  if (mapping->writable) {
    FooResult published = foo_fs_publish(pointer);
    if (published.error) return published;
  }
  int failed = fclose(mapping->stream);
  free(mapping->bytes);
  mapping->stream = NULL;
  mapping->bytes = NULL;
  retire(item);
  return failed ? failure(IO) : (FooResult){0};
}

FooResult foo_fs_copy(FooText source, FooText destination) {
  FooResult content = foo_fs_load(source);
  if (content.error) return content;
  FooResult written = foo_fs_save(destination, content.text);
  FooResult released = foo_fs_release(content.text);
  return written.error ? written : released;
}

FooResult foo_fs_temporary(FooText directory, FooText prefix) {
  if (!directory.len || prefix.len > 64 || (prefix.len && !prefix.data))
    return failure(ARGUMENT);
  for (size_t index = 0; index < prefix.len; index++) {
    uint8_t byte = prefix.data[index];
    if (!((byte >= 'a' && byte <= 'z') || (byte >= 'A' && byte <= 'Z') ||
          (byte >= '0' && byte <= '9') || byte == '-' || byte == '_'))
      return failure(ARGUMENT);
  }
  char *folder = pathname(directory);
  if (!folder) return failure(ARGUMENT);
  size_t length = strlen(folder);
  int separator = folder[length - 1] != '/';
  if (length > SIZE_MAX - prefix.len - separator - 37) {
    free(folder);
    return failure(BOUNDS);
  }
  char *name = malloc(length + prefix.len + separator + 37);
  if (!name) { free(folder); return failure(MEMORY); }
  memcpy(name, folder, length);
  free(folder);
  if (separator) name[length++] = '/';
  memcpy(name + length, prefix.data, (size_t)prefix.len);
  length += (size_t)prefix.len;
  static const char digits[] = "0123456789abcdef";
  FooResult result = failure(IO);
  for (int attempt = 0; attempt < 32; attempt++) {
    uint8_t random[16];
    if (__wasi_random_get(random, sizeof(random))) {
      result = failure(SYSTEM);
      break;
    }
    for (size_t index = 0; index < sizeof(random); index++) {
      name[length + index * 2] = digits[random[index] >> 4];
      name[length + index * 2 + 1] = digits[random[index] & 15];
    }
    memcpy(name + length + 32, ".tmp", 5);
    int descriptor = open(name, O_CREAT | O_EXCL | O_RDWR, 0600);
    if (descriptor < 0 && errno == EEXIST) continue;
    if (descriptor < 0) break;
    if (close(descriptor)) { remove(name); break; }
    result = copied((const uint8_t *)name, strlen(name));
    if (result.error) remove(name);
    break;
  }
  free(name);
  return result;
}

FooResult foo_fs_replace(FooText source, FooText destination) {
  char *from = pathname(source), *to = pathname(destination);
  if (!from || !to) { free(from); free(to); return failure(ARGUMENT); }
  int failed = rename(from, to);
  free(from);
  free(to);
  return failed ? failure(IO) : (FooResult){0};
}

FooResult foo_fs_exists(FooText path) {
  char *name = pathname(path);
  if (!name) return failure(ARGUMENT);
  struct stat status;
  int found = stat(name, &status);
  int reason = errno;
  free(name);
  return !found ? (FooResult){.number = 1} :
    reason == ENOENT ? (FooResult){0} : failure(IO);
}

FooResult foo_fs_remove(FooText path) {
  char *name = pathname(path);
  if (!name) return failure(ARGUMENT);
  int removed = remove(name);
  free(name);
  return removed ? failure(IO) : (FooResult){0};
}

FooResult foo_fs_working(void) {
  char buffer[4096];
  if (!getcwd(buffer, sizeof(buffer))) return failure(IO);
  return copied((const uint8_t *)buffer, strlen(buffer));
}

FooResult foo_resource_files(void) {
  uint64_t count = 0;
  pthread_mutex_lock(&registry);
  for (Entry *item = entries; item; item = item->next)
    if (item->kind == FILE_RESOURCE && !item->closed) count++;
  pthread_mutex_unlock(&registry);
  return (FooResult){.number = count};
}

FooResult foo_resource_mapped(void) {
  uint64_t count = 0;
  pthread_mutex_lock(&registry);
  for (Entry *item = entries; item; item = item->next)
    if (item->kind == MAP_RESOURCE && !item->closed) {
      uint64_t size = ((Mapping *)item->data)->length;
      count = UINT64_MAX - count < size ? UINT64_MAX : count + size;
    }
  pthread_mutex_unlock(&registry);
  return (FooResult){.number = count};
}
