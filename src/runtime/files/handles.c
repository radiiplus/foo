typedef struct {
  FILE *file;
  int borrowed;
  int mode;
#ifdef _WIN32
  atomic_flag positional;
#endif
} File;
static File standard[3];
static FooResult stream(FILE *file, int index) {
  enter();
  if (!standard[index].file) {
    standard[index].file = file;
    standard[index].borrowed = 1;
  }
  leave();
  return (FooResult){.pointer = &standard[index]};
}
FooResult foo_io_input(void) { return stream(stdin, 0); }
FooResult foo_io_output(void) { return stream(stdout, 1); }
FooResult foo_io_report(void) { return stream(stderr, 2); }
static File *file(void *pointer) {
  for (int index = 0; index < 3; index++)
    if (pointer == &standard[index])
      return standard[index].file ? pointer : NULL;
  return resource(pointer, FILES) ? pointer : NULL;
}
FooResult foo_fs_handle(void *pointer) {
  File *stream = file(pointer);
  if (!stream || !stream->file)
    return failure(CLOSED);
#ifdef _WIN32
  int descriptor = _fileno(stream->file);
  if (descriptor < 0)
    return failure(IO);
  intptr_t handle = _get_osfhandle(descriptor);
  return handle == -1 ? failure(IO)
                      : (FooResult){.number = (uint64_t)(uintptr_t)handle};
#else
  int descriptor = fileno(stream->file);
  return descriptor < 0 ? failure(IO)
                        : (FooResult){.number = (uint64_t)descriptor};
#endif
}
FooResult foo_io_write(void *pointer, FooText value) {
  File *stream = file(pointer);
  if (!stream || !stream->file)
    return failure(CLOSED);
  uint64_t partial;
  if (fault(FAULT_WRITE, &partial)) {
    size_t length = partial < value.len ? (size_t)partial : value.len;
    if (length && fwrite(value.data, 1, length, stream->file) != length)
      return failure(IO);
    fflush(stream->file);
    return failure(IO);
  }
  if (value.len && fwrite(value.data, 1, value.len, stream->file) != value.len)
    return failure(IO);
  return fflush(stream->file) ? failure(IO) : (FooResult){0};
}
FooResult foo_io_read(void *pointer, uint64_t size) {
  File *stream = file(pointer);
  if (!stream || !stream->file)
    return failure(CLOSED);
  if (size > SIZE_MAX)
    return failure(BOUNDS);
  if (!size)
    return (FooResult){0};
  void *buffer = malloc((size_t)size);
  if (!buffer)
    return failure(MEMORY);
  size_t received = fread(buffer, 1, (size_t)size, stream->file);
  FooResult result =
      ferror(stream->file) ? failure(IO) : text(buffer, received);
  free(buffer);
  return result;
}
FooResult foo_io_line(void *pointer) {
  File *stream = file(pointer);
  if (!stream || !stream->file)
    return failure(CLOSED);
  size_t length = 0, capacity = 128;
  char *buffer = malloc(capacity);
  if (!buffer)
    return failure(MEMORY);
  int byte;
  while ((byte = fgetc(stream->file)) != EOF && byte != '\n') {
    if (length == capacity) {
      if (capacity > SIZE_MAX / 2) {
        free(buffer);
        return failure(BOUNDS);
      }
      char *next = realloc(buffer, capacity * 2);
      if (!next) {
        free(buffer);
        return failure(MEMORY);
      }
      buffer = next;
      capacity *= 2;
    }
    buffer[length++] = (char)byte;
  }
  if (length && buffer[length - 1] == '\r')
    length--;
  FooResult result = ferror(stream->file) ? failure(IO) : text(buffer, length);
  free(buffer);
  return result;
}
FooResult foo_io_close(void *pointer) {
  File *stream = file(pointer);
  if (!stream || !stream->file)
    return failure(CLOSED);
  if (stream->borrowed)
    return failure(ARGUMENT);
  int result = fclose(stream->file);
  stream->file = NULL;
  resource(pointer, FILES)->closed = 1;
  return result ? failure(IO) : (FooResult){0};
}
FooResult foo_fs_open(FooText path, FooText mode) {
  char *name = string(path), *access = string(mode);
  if (!name || !access) {
    free(name);
    free(access);
    return failure(ARGUMENT);
  }
  if (strcmp(access, "read") && strcmp(access, "write") &&
      strcmp(access, "append") && strcmp(access, "update") &&
      strcmp(access, "create")) {
    free(name);
    free(access);
    return failure(ARGUMENT);
  }
  FILE *handle = NULL;
  int selected = !strcmp(access, "read") ? 1 :
      !strcmp(access, "append") ? 3 :
      !strcmp(access, "write") ? 2 : 4;
  if (!strcmp(access, "create")) {
#ifdef _WIN32
    int descriptor = _open(name, _O_CREAT | _O_EXCL | _O_RDWR | _O_BINARY,
                           _S_IREAD | _S_IWRITE);
    if (descriptor >= 0) {
      handle = _fdopen(descriptor, "w+b");
      if (!handle) _close(descriptor);
    }
#else
    int descriptor = open(name, O_CREAT | O_EXCL | O_RDWR, 0666);
    if (descriptor >= 0) {
      handle = fdopen(descriptor, "w+b");
      if (!handle) close(descriptor);
    }
#endif
  } else {
    handle = fopen(name, !strcmp(access, "read") ? "rb" :
        !strcmp(access, "write") ? "wb" :
        !strcmp(access, "update") ? "r+b" : "ab");
  }
  free(name);
  free(access);
  if (!handle)
    return failure(IO);
  File *result = owned(sizeof(*result), FILES);
  if (!result) {
    fclose(handle);
    return failure(MEMORY);
  }
  result->file = handle;
  result->mode = selected;
#ifdef _WIN32
  atomic_flag_clear(&result->positional);
#endif
  return (FooResult){.pointer = result};
}
FooResult foo_fs_flush(void *pointer) {
  File *stream = file(pointer);
  return !stream || !stream->file ? failure(CLOSED)
                                  : fflush(stream->file) ? failure(IO)
                                                        : (FooResult){0};
}
FooResult foo_fs_sync(void *pointer) {
  File *stream = file(pointer);
  if (!stream || !stream->file)
    return failure(CLOSED);
  if (fflush(stream->file))
    return failure(IO);
  if (fault(FAULT_SYNC, NULL)) return failure(IO);
#ifdef _WIN32
  return _commit(_fileno(stream->file)) ? failure(IO) : (FooResult){0};
#else
  return fsync(fileno(stream->file)) ? failure(IO) : (FooResult){0};
#endif
}
static int seek(FILE *stream, int64_t offset, int origin) {
#ifdef _WIN32
  return _fseeki64(stream, offset, origin);
#else
  return fseeko(stream, (off_t)offset, origin);
#endif
}
static int64_t position(FILE *stream) {
#ifdef _WIN32
  return _ftelli64(stream);
#else
  return (int64_t)ftello(stream);
#endif
}
FooResult foo_fs_seek(void *pointer, int64_t offset, FooText origin) {
  File *stream = file(pointer);
  if (!stream || !stream->file)
    return failure(CLOSED);
  int base = origin.len == 5 && !memcmp(origin.data, "start", 5)     ? SEEK_SET
             : origin.len == 7 && !memcmp(origin.data, "current", 7) ? SEEK_CUR
             : origin.len == 3 && !memcmp(origin.data, "end", 3)     ? SEEK_END
                                                                       : -1;
  return base < 0 ? failure(ARGUMENT)
                  : seek(stream->file, offset, base) ? failure(IO)
                                                          : (FooResult){0};
}
FooResult foo_fs_position(void *pointer) {
  File *stream = file(pointer);
  if (!stream || !stream->file)
    return failure(CLOSED);
  int64_t result = position(stream->file);
  return result < 0 ? failure(IO) : (FooResult){.number = (uint64_t)result};
}
FooResult foo_fs_size(void *pointer) {
  File *stream = file(pointer);
  if (!stream || !stream->file)
    return failure(CLOSED);
  int64_t original = position(stream->file);
  if (original < 0 || seek(stream->file, 0, SEEK_END))
    return failure(IO);
  int64_t result = position(stream->file);
  if (seek(stream->file, original, SEEK_SET))
    return failure(IO);
  return result < 0 ? failure(IO) : (FooResult){.number = (uint64_t)result};
}
FooResult foo_fs_truncate(void *pointer, uint64_t size) {
  File *stream = file(pointer);
  if (!stream || !stream->file) return failure(CLOSED);
  if (stream->mode == 1) return failure(ARGUMENT);
  if (size > INT64_MAX || fflush(stream->file)) return failure(IO);
#ifdef _WIN32
  return _chsize_s(_fileno(stream->file), size) ? failure(IO) : (FooResult){0};
#else
  return ftruncate(fileno(stream->file), (off_t)size) ? failure(IO)
                                                     : (FooResult){0};
#endif
}
FooResult foo_fs_reserve(void *pointer, uint64_t size) {
  File *stream = file(pointer);
  if (!stream || !stream->file) return failure(CLOSED);
  if (stream->mode == 1) return failure(ARGUMENT);
  if (size > INT64_MAX || fflush(stream->file)) return failure(IO);
  FooResult current = foo_fs_size(pointer);
  if (current.error || size <= current.number) return current.error ? current : (FooResult){0};
#ifdef _WIN32
  intptr_t native = _get_osfhandle(_fileno(stream->file));
  if (native == -1) return failure(IO);
  FILE_ALLOCATION_INFO allocation = {.AllocationSize.QuadPart = (LONGLONG)size};
  if (!SetFileInformationByHandle((HANDLE)native, FileAllocationInfo,
                                  &allocation, sizeof(allocation))) return failure(IO);
  return _chsize_s(_fileno(stream->file), size) ? failure(IO) : (FooResult){0};
#else
  return posix_fallocate(fileno(stream->file), 0, (off_t)size) ? failure(IO)
                                                               : (FooResult){0};
#endif
}
FooResult foo_fs_lock(void *pointer, FooText mode) {
  File *stream = file(pointer);
  if (!stream || !stream->file) return failure(CLOSED);
  int exclusive = mode.len == 9 && !memcmp(mode.data, "exclusive", 9);
  int shared = mode.len == 6 && !memcmp(mode.data, "shared", 6);
  if (!exclusive && !shared) return failure(ARGUMENT);
  if (shared && stream->mode == 3) return failure(ARGUMENT);
  if (exclusive && stream->mode == 1) return failure(ARGUMENT);
  if (stream->mode != 1 && fflush(stream->file)) return failure(IO);
#ifdef _WIN32
  intptr_t native = _get_osfhandle(_fileno(stream->file));
  if (native == -1) return failure(IO);
  OVERLAPPED operation = {0};
  return LockFileEx((HANDLE)native, exclusive ? LOCKFILE_EXCLUSIVE_LOCK : 0,
      0, MAXDWORD, MAXDWORD, &operation) ? (FooResult){0} : failure(IO);
#else
  return flock(fileno(stream->file), exclusive ? LOCK_EX : LOCK_SH)
      ? failure(IO) : (FooResult){0};
#endif
}
FooResult foo_fs_unlock(void *pointer) {
  File *stream = file(pointer);
  if (!stream || !stream->file) return failure(CLOSED);
#ifdef _WIN32
  intptr_t native = _get_osfhandle(_fileno(stream->file));
  if (native == -1) return failure(IO);
  OVERLAPPED operation = {0};
  return UnlockFileEx((HANDLE)native, 0, MAXDWORD, MAXDWORD, &operation)
      ? (FooResult){0} : failure(IO);
#else
  return flock(fileno(stream->file), LOCK_UN) ? failure(IO) : (FooResult){0};
#endif
}
static FooResult transferat(void *pointer, uint64_t offset, FooText bytes,
                            int writing) {
  File *stream = file(pointer);
  if (!stream || !stream->file)
    return failure(CLOSED);
  if ((stream->mode != 4 && stream->mode != (writing ? 2 : 1)) ||
      (bytes.len && !bytes.data))
    return failure(ARGUMENT);
  if (offset > INT64_MAX || (bytes.len && offset == INT64_MAX))
    return failure(BOUNDS);
  uint64_t partial;
  if (writing && fault(FAULT_WRITE, &partial) && partial < bytes.len)
    bytes.len = (size_t)partial;
  if (!bytes.len)
    return (FooResult){0};
#ifdef _WIN32
  while (atomic_flag_test_and_set_explicit(&stream->positional,
                                            memory_order_acquire)) {
  }
  if (stream->mode == 4 && seek(stream->file, 0, SEEK_CUR)) {
    atomic_flag_clear_explicit(&stream->positional, memory_order_release);
    return failure(IO);
  }
  fpos_t saved;
  int positioned = fgetpos(stream->file, &saved) == 0;
  int descriptor = positioned ? _fileno(stream->file) : -1;
  intptr_t native = descriptor >= 0 ? _get_osfhandle(descriptor) : -1;
  DWORD count = 0;
  BOOL success = FALSE;
  if (native != -1) {
    OVERLAPPED operation = {0};
    operation.Offset = (DWORD)offset;
    operation.OffsetHigh = (DWORD)(offset >> 32);
    DWORD length = bytes.len > UINT32_MAX ? UINT32_MAX : (DWORD)bytes.len;
    success = writing
        ? WriteFile((HANDLE)native, bytes.data, length, &count, &operation)
        : ReadFile((HANDLE)native, (void *)bytes.data, length, &count,
                   &operation);
    if (!writing && !success && GetLastError() == ERROR_HANDLE_EOF)
      success = TRUE;
  }
  int restored = positioned && fsetpos(stream->file, &saved) == 0;
  atomic_flag_clear_explicit(&stream->positional, memory_order_release);
  return !success || !restored ? failure(IO) : (FooResult){.number = count};
#else
  int descriptor = fileno(stream->file);
  if (descriptor < 0 || (stream->mode == 4 && seek(stream->file, 0, SEEK_CUR)) ||
      (writing && fflush(stream->file)))
    return failure(IO);
  size_t length = bytes.len > SSIZE_MAX ? SSIZE_MAX : bytes.len;
  ssize_t count;
  do {
    count = writing ? pwrite(descriptor, bytes.data, length, (off_t)offset)
                    : pread(descriptor, (void *)bytes.data, length,
                            (off_t)offset);
  } while (count < 0 && errno == EINTR);
  if (stream->mode == 4 && seek(stream->file, 0, SEEK_CUR))
    return failure(IO);
  return count < 0 ? failure(IO) : (FooResult){.number = (uint64_t)count};
#endif
}
FooResult foo_fs_readat(void *pointer, uint64_t offset, FooText destination) {
  return transferat(pointer, offset, destination, 0);
}
FooResult foo_fs_writeat(void *pointer, uint64_t offset, FooText source) {
  return transferat(pointer, offset, source, 1);
}
FooResult foo_fs_fetch(void *pointer, uint64_t offset, FooText destination) {
  return foo_fs_readat(pointer, offset, destination);
}
FooResult foo_fs_store(void *pointer, uint64_t offset, FooText source) {
  return foo_fs_writeat(pointer, offset, source);
}
typedef struct {
  void *base;
  size_t mapped;
  size_t delta;
  size_t length;
  FILE *stream;
  int writable;
} Mapping;
static void unmap(Mapping *mapping) {
#ifdef _WIN32
  UnmapViewOfFile(mapping->base);
#else
  munmap(mapping->base, mapping->mapped);
#endif
  if (mapping->stream) fclose(mapping->stream);
}
static FooResult mapping(FooText path, uint64_t offset, uint64_t length,
                          int writable) {
  char *name = string(path);
  if (!name)
    return failure(ARGUMENT);
  FILE *stream = fopen(name, writable ? "r+b" : "rb");
  free(name);
  if (!stream)
    return failure(IO);
  if (seek(stream, 0, SEEK_END)) {
    fclose(stream);
    return failure(IO);
  }
  int64_t end = position(stream);
  if (end < 0) {
    fclose(stream);
    return failure(IO);
  }
  if (offset > (uint64_t)end ||
      (length && length > (uint64_t)end - offset)) {
    fclose(stream);
    return failure(BOUNDS);
  }
  uint64_t available = (uint64_t)end - offset;
  uint64_t count = length ? length : available;
  if (!count || count > SIZE_MAX) {
    fclose(stream);
    return failure(BOUNDS);
  }
#ifdef _WIN32
  SYSTEM_INFO system;
  GetSystemInfo(&system);
  uint64_t page = system.dwAllocationGranularity;
#else
  long granularity = sysconf(_SC_PAGESIZE);
  if (granularity <= 0) {
    fclose(stream);
    return failure(SYSTEM);
  }
  uint64_t page = (uint64_t)granularity;
#endif
  uint64_t aligned = offset - offset % page;
  uint64_t delta = offset - aligned;
#ifndef _WIN32
  if ((uint64_t)(off_t)aligned != aligned) {
    fclose(stream);
    return failure(BOUNDS);
  }
#endif
  if (count > SIZE_MAX - delta) {
    fclose(stream);
    return failure(BOUNDS);
  }
  size_t mapped = (size_t)(count + delta);
#ifdef _WIN32
  intptr_t descriptor = _get_osfhandle(_fileno(stream));
  HANDLE handle = descriptor == -1 ? NULL :
      CreateFileMappingA((HANDLE)descriptor, NULL,
                         writable ? PAGE_READWRITE : PAGE_READONLY, 0, 0, NULL);
  void *base = handle ? MapViewOfFile(handle,
      writable ? FILE_MAP_WRITE : FILE_MAP_READ,
      (DWORD)(aligned >> 32), (DWORD)aligned, mapped) : NULL;
  if (handle)
    CloseHandle(handle);
#else
  void *base = mmap(NULL, mapped, writable ? PROT_READ | PROT_WRITE : PROT_READ,
      writable ? MAP_SHARED : MAP_PRIVATE, fileno(stream),
      (off_t)aligned);
  if (base == MAP_FAILED)
    base = NULL;
#endif
  if (!base) {
    fclose(stream);
    return failure(IO);
  }
  Mapping *mapping = calloc(1, sizeof(*mapping));
  if (!mapping) {
    Mapping temporary = {.base = base, .mapped = mapped, .stream = stream};
    unmap(&temporary);
    return failure(MEMORY);
  }
  *mapping = (Mapping){base, mapped, (size_t)delta, (size_t)count,
                           stream, writable};
  if (!adopt(mapping, (size_t)count, MAPS)) {
    unmap(mapping);
    free(mapping);
    return failure(MEMORY);
  }
  return (FooResult){.pointer = mapping};
}
FooResult foo_fs_map(FooText path, uint64_t offset, uint64_t length) {
  return mapping(path, offset, length, 0);
}
FooResult foo_fs_edit(FooText path, uint64_t offset, uint64_t length) {
  return mapping(path, offset, length, 1);
}
FooResult foo_fs_mapped(void *pointer) {
  Resource *entry = resource(pointer, MAPS);
  if (!entry)
    return failure(CLOSED);
  Mapping *mapping = pointer;
  return (FooResult){.text = {(const uint8_t *)mapping->base + mapping->delta,
                              mapping->length}};
}
FooResult foo_fs_borrow(void *pointer) {
  Resource *entry = resource(pointer, MAPS);
  if (!entry) return failure(CLOSED);
  Mapping *mapping = pointer;
  if (!mapping->writable) return failure(ARGUMENT);
  return (FooResult){.text = {(uint8_t *)mapping->base + mapping->delta,
                              mapping->length}};
}
FooResult foo_fs_publish(void *pointer) {
  Resource *entry = resource(pointer, MAPS);
  if (!entry) return failure(CLOSED);
  Mapping *mapping = pointer;
  if (!mapping->writable) return failure(ARGUMENT);
#ifdef _WIN32
  if (!FlushViewOfFile(mapping->base, mapping->mapped) ||
      !FlushFileBuffers((HANDLE)_get_osfhandle(_fileno(mapping->stream))))
    return failure(IO);
#else
  if (msync(mapping->base, mapping->mapped, MS_SYNC) ||
      fsync(fileno(mapping->stream))) return failure(IO);
#endif
  return (FooResult){0};
}
FooResult foo_fs_portion(void *pointer, uint64_t offset, uint64_t length) {
  Resource *entry = resource(pointer, MAPS);
  if (!entry) return failure(CLOSED);
  Mapping *mapping = pointer;
  if (!mapping->writable) return failure(ARGUMENT);
  if (offset > mapping->length || length > mapping->length - offset)
    return failure(BOUNDS);
  if (!length) return (FooResult){0};
  uint8_t *first = (uint8_t *)mapping->base + mapping->delta + (size_t)offset;
#ifdef _WIN32
  if (!FlushViewOfFile(first, (SIZE_T)length) ||
      !FlushFileBuffers((HANDLE)_get_osfhandle(_fileno(mapping->stream))))
    return failure(IO);
#else
  long page = sysconf(_SC_PAGESIZE);
  if (page <= 0) return failure(SYSTEM);
  uintptr_t aligned = (uintptr_t)first - (uintptr_t)first % (uintptr_t)page;
  size_t span = (size_t)((uintptr_t)first + (size_t)length - aligned);
  if (msync((void *)aligned, span, MS_SYNC) ||
      fsync(fileno(mapping->stream))) return failure(IO);
#endif
  return (FooResult){0};
}
FooResult foo_fs_unmap(void *pointer) {
  Resource *entry = resource(pointer, MAPS);
  if (!entry)
    return failure(CLOSED);
  Mapping *mapping = pointer;
  if (mapping->writable) {
    FooResult flushed = foo_fs_publish(pointer);
    if (flushed.error) return flushed;
  }
  unmap(mapping);
  mapping->base = NULL;
  mapping->stream = NULL;
  entry->closed = 1;
  return (FooResult){0};
}
