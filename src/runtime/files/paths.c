FooResult foo_fs_read(FooText path) {
  FooResult opened = foo_fs_open(path, (FooText){(const uint8_t *)"read", 4});
  if (opened.error)
    return opened;
  FILE *handle = ((File *)opened.pointer)->file;
  size_t size = 0, capacity = 4096;
  FooResult measured = foo_fs_size(opened.pointer);
  if (!measured.error && measured.number <= SIZE_MAX)
    capacity = measured.number ? (size_t)measured.number : 1;
  uint8_t *buffer = malloc(capacity);
  if (!buffer) {
    foo_io_close(opened.pointer);
    return failure(MEMORY);
  }
  for (;;) {
    size += fread(buffer + size, 1, capacity - size, handle);
    if (size < capacity)
      break;
    int extra = fgetc(handle);
    if (extra == EOF)
      break;
    if (capacity > SIZE_MAX / 2) {
      free(buffer);
      foo_io_close(opened.pointer);
      return failure(BOUNDS);
    }
    void *next = realloc(buffer, capacity * 2);
    if (!next) {
      free(buffer);
      foo_io_close(opened.pointer);
      return failure(MEMORY);
    }
    buffer = next;
    capacity *= 2;
    buffer[size++] = (uint8_t)extra;
  }
  FooResult result = {0};
  if (ferror(handle)) {
    free(buffer);
    result = failure(IO);
  } else if (!size) {
    free(buffer);
  } else if (!adopt(buffer, size, TEXT)) {
    free(buffer);
    result = failure(MEMORY);
  } else {
    result.text = (FooText){buffer, size};
  }
  FooResult closed = foo_io_close(opened.pointer);
  return result.error ? result : closed.error ? closed : result;
}
FooResult foo_fs_write(FooText path, FooText value) {
  FooResult opened = foo_fs_open(path, (FooText){(const uint8_t *)"write", 5});
  if (opened.error)
    return opened;
  FooResult result = foo_io_write(opened.pointer, value),
            closed = foo_io_close(opened.pointer);
  return result.error ? result : closed;
}
FooResult foo_fs_load(FooText path) { return foo_fs_read(path); }
FooResult foo_fs_save(FooText path, FooText value) {
  return foo_fs_write(path, value);
}
FooResult foo_fs_release(FooText value) {
  return foo_text_release(value);
}
#ifndef _WIN32
static int durable(const char *path) {
  char *copy = strdup(path);
  if (!copy)
    return -1;
  char *separator = strrchr(copy, '/');
  const char *parent = ".";
  if (separator) {
    if (separator == copy)
      separator[1] = 0;
    else
      *separator = 0;
    parent = copy;
  }
  int flags = O_RDONLY;
#ifdef O_DIRECTORY
  flags |= O_DIRECTORY;
#endif
  int descriptor = open(parent, flags);
  int result = descriptor < 0 || fsync(descriptor);
  if (descriptor >= 0 && close(descriptor))
    result = 1;
  free(copy);
  return result;
}
#endif
FooResult foo_fs_replace(FooText source, FooText destination) {
  char *from = string(source), *to = string(destination);
  if (!from || !to) {
    free(from);
    free(to);
    return failure(ARGUMENT);
  }
  if (fault(FAULT_REPLACE, NULL)) {
    free(from);
    free(to);
    return failure(IO);
  }
#ifdef _WIN32
  int result = !MoveFileExA(from, to,
      MOVEFILE_REPLACE_EXISTING | MOVEFILE_WRITE_THROUGH);
#else
  int result = rename(from, to);
  if (!result)
    result = durable(to);
#endif
  free(from);
  free(to);
  return result ? failure(IO) : (FooResult){0};
}
FooResult foo_fs_remove(FooText path) {
  char *name = string(path);
  if (!name)
    return failure(ARGUMENT);
#ifdef _WIN32
  DWORD attributes = GetFileAttributesA(name);
  int result = attributes != INVALID_FILE_ATTRIBUTES &&
      (attributes & FILE_ATTRIBUTE_DIRECTORY) ? !RemoveDirectoryA(name)
                                          : remove(name);
#else
  int result = remove(name);
#endif
  free(name);
  return result ? failure(IO) : (FooResult){0};
}
FooResult foo_fs_directory(FooText path) {
  char *name = string(path);
  if (!name)
    return failure(ARGUMENT);
#ifdef _WIN32
  int result = _mkdir(name);
#else
  int result = mkdir(name, 0777);
#endif
  struct stat status;
#ifdef _WIN32
  int exists = result && errno == EEXIST && !stat(name, &status) &&
               (status.st_mode & _S_IFMT) == _S_IFDIR;
#else
  int exists = result && errno == EEXIST && !stat(name, &status) &&
               S_ISDIR(status.st_mode);
#endif
  free(name);
  return !result || exists ? (FooResult){0} : failure(IO);
}
typedef struct {
#ifdef _WIN32
  HANDLE handle;
  WIN32_FIND_DATAA entry;
  int first;
#else
  DIR *handle;
#endif
} Scan;
FooResult foo_fs_scan(FooText path) {
  char *name = string(path);
  if (!name) return failure(ARGUMENT);
#ifdef _WIN32
  size_t length = strlen(name);
  if (length > SIZE_MAX - 3) { free(name); return failure(BOUNDS); }
  char *pattern = malloc(length + 3);
  if (!pattern) { free(name); return failure(MEMORY); }
  memcpy(pattern, name, length);
  size_t suffix = length && (name[length - 1] == '/' || name[length - 1] == '\\')
      ? 0 : 1;
  if (suffix) pattern[length] = '/';
  pattern[length + suffix] = '*';
  pattern[length + suffix + 1] = 0;
  WIN32_FIND_DATAA entry = {0};
  HANDLE handle = FindFirstFileA(pattern, &entry);
  DWORD problem = handle == INVALID_HANDLE_VALUE ? GetLastError() : 0;
  free(pattern);
  DWORD attributes = GetFileAttributesA(name);
  free(name);
  if (attributes == INVALID_FILE_ATTRIBUTES ||
      !(attributes & FILE_ATTRIBUTE_DIRECTORY) ||
      (handle == INVALID_HANDLE_VALUE && problem != ERROR_FILE_NOT_FOUND)) {
    if (handle != INVALID_HANDLE_VALUE) FindClose(handle);
    return failure(IO);
  }
#else
  DIR *handle = opendir(name);
  free(name);
  if (!handle) return failure(IO);
#endif
  Scan *cursor = owned(sizeof(*cursor), DIRS);
  if (!cursor) {
#ifdef _WIN32
    if (handle != INVALID_HANDLE_VALUE) FindClose(handle);
#else
    closedir(handle);
#endif
    return failure(MEMORY);
  }
  cursor->handle = handle;
#ifdef _WIN32
  cursor->entry = entry;
  cursor->first = handle != INVALID_HANDLE_VALUE;
#endif
  return (FooResult){.pointer = cursor};
}
FooResult foo_fs_next(void *pointer) {
  if (!resource(pointer, DIRS)) return failure(CLOSED);
  Scan *cursor = pointer;
#ifdef _WIN32
  while (cursor->handle != INVALID_HANDLE_VALUE) {
    if (cursor->first) cursor->first = 0;
    else if (!FindNextFileA(cursor->handle, &cursor->entry)) {
      DWORD problem = GetLastError();
      FindClose(cursor->handle);
      cursor->handle = INVALID_HANDLE_VALUE;
      return problem == ERROR_NO_MORE_FILES ? (FooResult){0} : failure(IO);
    }
    const char *name = cursor->entry.cFileName;
    if (!strcmp(name, ".") || !strcmp(name, "..")) continue;
    return text(name, strlen(name));
  }
#else
  for (;;) {
    errno = 0;
    struct dirent *entry = readdir(cursor->handle);
    if (!entry) return errno ? failure(IO) : (FooResult){0};
    const char *name = entry->d_name;
    if (!strcmp(name, ".") || !strcmp(name, "..")) continue;
    return text(name, strlen(name));
  }
#endif
  return (FooResult){0};
}
FooResult foo_fs_finish(void *pointer) {
  Resource *entry = resource(pointer, DIRS);
  if (!entry) return failure(CLOSED);
  Scan *cursor = pointer;
#ifdef _WIN32
  int failed = cursor->handle != INVALID_HANDLE_VALUE &&
      !FindClose(cursor->handle);
  cursor->handle = INVALID_HANDLE_VALUE;
#else
  int failed = closedir(cursor->handle);
  cursor->handle = NULL;
#endif
  entry->closed = 1;
  return failed ? failure(IO) : (FooResult){0};
}
typedef struct {
  void *cursor;
  char *relative;
} Step;
typedef struct {
  char *root;
  Step *frames;
  size_t count;
  size_t capacity;
} Walk;
static char *compose(const char *left, const char *right) {
  size_t first = strlen(left), second = strlen(right);
  int separator = first && left[first - 1] != '/' && left[first - 1] != '\\';
  if (first > SIZE_MAX - second - (size_t)separator - 1) return NULL;
  char *path = malloc(first + second + (size_t)separator + 1);
  if (!path) return NULL;
  memcpy(path, left, first);
  if (separator) path[first++] = '/';
  memcpy(path + first, right, second + 1);
  return path;
}
static int enqueue(Walk *walk, void *cursor, char *relative) {
  if (walk->count == walk->capacity) {
    size_t capacity = walk->capacity ? walk->capacity * 2 : 4;
    if (capacity < walk->capacity || capacity > SIZE_MAX / sizeof(Step))
      return 0;
    Step *frames = realloc(walk->frames, capacity * sizeof(*frames));
    if (!frames) return 0;
    walk->frames = frames;
    walk->capacity = capacity;
  }
  walk->frames[walk->count++] = (Step){cursor, relative};
  return 1;
}
FooResult foo_fs_walk(FooText path) {
  FooResult root = foo_fs_scan(path);
  if (root.error) return root;
  char *name = string(path);
  Walk *walk = name ? owned(sizeof(*walk), WALKS) : NULL;
  if (!walk) {
    foo_fs_finish(root.pointer);
    free(name);
    return failure(MEMORY);
  }
  walk->root = name;
  char *relative = calloc(1, 1);
  if (!relative || !enqueue(walk, root.pointer, relative)) {
    free(relative);
    foo_fs_finish(root.pointer);
    free(walk->root);
    resource(walk, WALKS)->closed = 1;
    return failure(MEMORY);
  }
  return (FooResult){.pointer = walk};
}
FooResult foo_fs_traverse(void *pointer) {
  if (!resource(pointer, WALKS)) return failure(CLOSED);
  Walk *walk = pointer;
  while (walk->count) {
    Step *frame = &walk->frames[walk->count - 1];
    FooResult entry = foo_fs_next(frame->cursor);
    if (entry.error) return entry;
    if (!entry.text.len) {
      FooResult finished = foo_fs_finish(frame->cursor);
      free(frame->relative);
      walk->count--;
      if (finished.error) return finished;
      continue;
    }
    char *name = string(entry.text);
    foo_text_release(entry.text);
    char *relative = name ? compose(frame->relative, name) : NULL;
    free(name);
    char *full = relative ? compose(walk->root, relative) : NULL;
    if (!full) { free(relative); return failure(MEMORY); }
#ifdef _WIN32
    DWORD attributes = GetFileAttributesA(full);
    int failed = attributes == INVALID_FILE_ATTRIBUTES;
    int descend = !failed && (attributes & FILE_ATTRIBUTE_DIRECTORY) &&
                  !(attributes & FILE_ATTRIBUTE_REPARSE_POINT);
#else
    struct stat status;
    int failed = lstat(full, &status);
    int descend = !failed && S_ISDIR(status.st_mode);
#endif
    free(full);
    if (failed) { free(relative); return failure(IO); }
    if (descend) {
      char *childpath = compose(walk->root, relative);
      if (!childpath) { free(relative); return failure(MEMORY); }
      FooResult child = foo_fs_scan((FooText){(const uint8_t *)childpath,
                                               strlen(childpath)});
      free(childpath);
      if (child.error) { free(relative); return child; }
      if (!enqueue(walk, child.pointer, relative)) {
        foo_fs_finish(child.pointer);
        free(relative);
        return failure(MEMORY);
      }
    }
    FooResult value = text(relative, strlen(relative));
    if (!descend) free(relative);
    return value;
  }
  return (FooResult){0};
}
FooResult foo_fs_cease(void *pointer) {
  Resource *entry = resource(pointer, WALKS);
  if (!entry) return failure(CLOSED);
  Walk *walk = pointer;
  int failed = 0;
  while (walk->count) {
    Step *frame = &walk->frames[--walk->count];
    if (resource(frame->cursor, DIRS) && foo_fs_finish(frame->cursor).error)
      failed = 1;
    free(frame->relative);
  }
  free(walk->frames);
  free(walk->root);
  walk->frames = NULL;
  walk->root = NULL;
  entry->closed = 1;
  return failed ? failure(IO) : (FooResult){0};
}
FooResult foo_fs_join(FooText left, FooText right) {
  if (!left.len ||
      (right.len && (right.data[0] == '/' || right.data[0] == '\\' ||
                     (right.len > 1 && right.data[1] == ':'))))
    return text(right.data, right.len);
  if (!right.len)
    return text(left.data, left.len);
  int separator =
      left.data[left.len - 1] != '/' && left.data[left.len - 1] != '\\';
  if (right.len > SIZE_MAX - left.len - (size_t)separator)
    return failure(BOUNDS);
  size_t length = left.len + right.len + separator;
  uint8_t *result = owned(length, TEXT);
  if (!result)
    return failure(MEMORY);
  memcpy(result, left.data, left.len);
  if (separator)
    result[left.len] = '/';
  memcpy(result + left.len + separator, right.data, right.len);
  return (FooResult){.text = {result, length}};
}
FooResult foo_fs_exists(FooText path) {
  char *name = string(path);
  if (!name)
    return failure(ARGUMENT);
  struct stat status;
  int result = stat(name, &status);
  int problem = errno;
  free(name);
  if (!result)
    return (FooResult){.number = 1};
  return problem == ENOENT ? (FooResult){0} : failure(IO);
}
FooResult foo_fs_kind(FooText path) {
  char *name = string(path);
  if (!name)
    return failure(ARGUMENT);
  struct stat status;
  int result = stat(name, &status);
  int problem = errno;
  free(name);
  if (result)
    return problem == ENOENT ? failure(MISSING) : failure(IO);
#ifdef _WIN32
  const char *value = (status.st_mode & _S_IFMT) == _S_IFREG ? "file" :
                      (status.st_mode & _S_IFMT) == _S_IFDIR ? "directory" :
                                                               "other";
#else
  const char *value = S_ISREG(status.st_mode) ? "file" :
                      S_ISDIR(status.st_mode) ? "directory" : "other";
#endif
  return text(value, strlen(value));
}
typedef struct {
  uint64_t size;
  uint64_t modified;
  uint64_t accessed;
  uint64_t changed;
  int readonly;
  char kind[10];
} Metadata;
#ifdef _WIN32
static uint64_t ticks(LARGE_INTEGER value) {
  const uint64_t epoch = UINT64_C(116444736000000000);
  return (uint64_t)value.QuadPart < epoch ? 0 :
      ((uint64_t)value.QuadPart - epoch) * 100;
}
#else
static uint64_t epoch(time_t seconds, long nanos) {
  if (seconds < 0 || (uint64_t)seconds > UINT64_MAX / 1000000000)
    return 0;
  return (uint64_t)seconds * 1000000000 + (uint64_t)nanos;
}
#endif
FooResult foo_fs_metadata(FooText path) {
  char *name = string(path);
  if (!name) return failure(ARGUMENT);
  Metadata snapshot = {0};
#ifdef _WIN32
  WIN32_FILE_ATTRIBUTE_DATA data;
  if (!GetFileAttributesExA(name, GetFileExInfoStandard, &data)) {
    DWORD problem = GetLastError();
    free(name);
    return failure(problem == ERROR_FILE_NOT_FOUND || problem == ERROR_PATH_NOT_FOUND
        ? MISSING : IO);
  }
  HANDLE handle = CreateFileA(name, FILE_READ_ATTRIBUTES,
      FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE, NULL,
      OPEN_EXISTING, FILE_FLAG_BACKUP_SEMANTICS | FILE_FLAG_OPEN_REPARSE_POINT,
      NULL);
  free(name);
  FILE_BASIC_INFO basic;
  if (handle == INVALID_HANDLE_VALUE ||
      !GetFileInformationByHandleEx(handle, FileBasicInfo, &basic, sizeof(basic))) {
    if (handle != INVALID_HANDLE_VALUE) CloseHandle(handle);
    return failure(IO);
  }
  CloseHandle(handle);
  snapshot.size = ((uint64_t)data.nFileSizeHigh << 32) | data.nFileSizeLow;
  snapshot.modified = ticks(basic.LastWriteTime);
  snapshot.accessed = ticks(basic.LastAccessTime);
  snapshot.changed = ticks(basic.ChangeTime);
  snapshot.readonly = !!(data.dwFileAttributes & FILE_ATTRIBUTE_READONLY);
  const char *kind = data.dwFileAttributes & FILE_ATTRIBUTE_REPARSE_POINT ? "link"
      : data.dwFileAttributes & FILE_ATTRIBUTE_DIRECTORY ? "directory" : "file";
#else
  struct stat status;
  int failed = lstat(name, &status);
  int problem = errno;
  free(name);
  if (failed) return failure(problem == ENOENT ? MISSING : IO);
  snapshot.size = status.st_size < 0 ? 0 : (uint64_t)status.st_size;
#ifdef __APPLE__
  snapshot.modified = epoch(status.st_mtimespec.tv_sec, status.st_mtimespec.tv_nsec);
  snapshot.accessed = epoch(status.st_atimespec.tv_sec, status.st_atimespec.tv_nsec);
  snapshot.changed = epoch(status.st_ctimespec.tv_sec, status.st_ctimespec.tv_nsec);
#else
  snapshot.modified = epoch(status.st_mtim.tv_sec, status.st_mtim.tv_nsec);
  snapshot.accessed = epoch(status.st_atim.tv_sec, status.st_atim.tv_nsec);
  snapshot.changed = epoch(status.st_ctim.tv_sec, status.st_ctim.tv_nsec);
#endif
  snapshot.readonly = !(status.st_mode & 0222);
  const char *kind = S_ISLNK(status.st_mode) ? "link" :
      S_ISDIR(status.st_mode) ? "directory" :
      S_ISREG(status.st_mode) ? "file" : "other";
#endif
  strcpy(snapshot.kind, kind);
  Metadata *result = owned(sizeof(*result), METADATA);
  if (!result) return failure(MEMORY);
  *result = snapshot;
  return (FooResult){.pointer = result};
}
FooResult foo_fs_measure(void *pointer) {
  if (!resource(pointer, METADATA)) return failure(CLOSED);
  return (FooResult){.number = ((Metadata *)pointer)->size};
}
FooResult foo_fs_timestamp(void *pointer, FooText field) {
  if (!resource(pointer, METADATA)) return failure(CLOSED);
  if (field.len && !field.data) return failure(ARGUMENT);
  Metadata *value = pointer;
  uint64_t selected = field.len == 8 && !memcmp(field.data, "modified", 8)
      ? value->modified : field.len == 8 && !memcmp(field.data, "accessed", 8)
      ? value->accessed : field.len == 7 && !memcmp(field.data, "changed", 7)
      ? value->changed : UINT64_MAX;
  return selected == UINT64_MAX ? failure(ARGUMENT)
      : (FooResult){.number = selected};
}
FooResult foo_fs_classify(void *pointer) {
  if (!resource(pointer, METADATA)) return failure(CLOSED);
  Metadata *value = pointer;
  return (FooResult){.text = {(const uint8_t *)value->kind, strlen(value->kind)}};
}
FooResult foo_fs_restricted(void *pointer) {
  if (!resource(pointer, METADATA)) return failure(CLOSED);
  return (FooResult){.number = (uint64_t)((Metadata *)pointer)->readonly};
}
FooResult foo_fs_retire(void *pointer) {
  Resource *entry = resource(pointer, METADATA);
  if (!entry) return failure(CLOSED);
  entry->closed = 1;
  return (FooResult){0};
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
  char *folder = string(directory);
  if (!folder || directory.len > SIZE_MAX - prefix.len - 40) {
    free(folder);
    return failure(ARGUMENT);
  }
  size_t length = strlen(folder);
  char *name = malloc(length + prefix.len + 40);
  if (!name) { free(folder); return failure(MEMORY); }
  int separator = length && folder[length - 1] != '/' && folder[length - 1] != '\\';
  memcpy(name, folder, length);
  free(folder);
  if (separator) name[length++] = '/';
  memcpy(name + length, prefix.data, prefix.len);
  length += prefix.len;
#ifdef _WIN32
  for (int attempt = 0; attempt < 32; attempt++) {
    unsigned first, second, third, fourth;
    if (rand_s(&first) || rand_s(&second) || rand_s(&third) || rand_s(&fourth)) {
      free(name);
      return failure(SYSTEM);
    }
    snprintf(name + length, 40, "%08x%08x%08x%08x.tmp",
             first, second, third, fourth);
    int descriptor = _open(name, _O_CREAT | _O_EXCL | _O_RDWR | _O_BINARY,
                           _S_IREAD | _S_IWRITE);
    if (descriptor < 0 && errno == EEXIST) continue;
    if (descriptor < 0) { free(name); return failure(IO); }
    int failed = _close(descriptor);
    if (failed) { remove(name); free(name); return failure(IO); }
    FooResult result = text(name, strlen(name));
    if (result.error) remove(name);
    free(name);
    return result;
  }
#else
  memcpy(name + length, "XXXXXX", 7);
  int descriptor = mkstemp(name);
  if (descriptor >= 0) {
    int failed = close(descriptor);
    if (failed) { remove(name); free(name); return failure(IO); }
    FooResult result = text(name, strlen(name));
    if (result.error) remove(name);
    free(name);
    return result;
  }
#endif
  free(name);
  return failure(IO);
}
FooResult foo_fs_free(FooText path) {
  char *name = string(path);
  if (!name) return failure(ARGUMENT);
#ifdef _WIN32
  ULARGE_INTEGER available;
  int failed = !GetDiskFreeSpaceExA(name, &available, NULL, NULL);
  free(name);
  return failed ? failure(IO) : (FooResult){.number = available.QuadPart};
#else
  struct statvfs status;
  int failed = statvfs(name, &status);
  free(name);
  if (failed) return failure(IO);
  uint64_t unit = status.f_frsize ? status.f_frsize : status.f_bsize;
  if (unit && status.f_bavail > UINT64_MAX / unit) return failure(BOUNDS);
  return (FooResult){.number = status.f_bavail * unit};
#endif
}
FooResult foo_fs_block(FooText path) {
  char *name = string(path);
  if (!name) return failure(ARGUMENT);
#ifdef _WIN32
  char root[MAX_PATH];
  DWORD sectors, bytes, clusters, total;
  int failed = !GetVolumePathNameA(name, root, MAX_PATH) ||
      !GetDiskFreeSpaceA(root, &sectors, &bytes, &clusters, &total);
  free(name);
  return failed ? failure(IO) :
      (FooResult){.number = (uint64_t)sectors * bytes};
#else
  struct statvfs status;
  int failed = statvfs(name, &status);
  free(name);
  return failed ? failure(IO) :
      (FooResult){.number = status.f_frsize ? status.f_frsize : status.f_bsize};
#endif
}
FooResult foo_fs_copy(FooText source, FooText destination) {
  FooResult content = foo_fs_load(source);
  if (content.error)
    return content;
  FooResult written = foo_fs_save(destination, content.text);
  FooResult released = foo_fs_release(content.text);
  return written.error ? written : released;
}
FooResult foo_fs_working(void) {
  size_t capacity = 256;
  for (;;) {
    char *buffer = malloc(capacity);
    if (!buffer)
      return failure(MEMORY);
#ifdef _WIN32
    char *result = _getcwd(buffer, (int)capacity);
#else
    char *result = getcwd(buffer, capacity);
#endif
    if (result) {
      FooResult value = text(buffer, strlen(buffer));
      free(buffer);
      return value;
    }
    int problem = errno;
    free(buffer);
    if (problem != ERANGE || capacity > SIZE_MAX / 2)
      return failure(problem == ERANGE ? BOUNDS : IO);
    capacity *= 2;
  }
}
