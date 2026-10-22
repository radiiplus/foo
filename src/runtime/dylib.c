typedef struct {
#ifdef _WIN32
  HMODULE handle;
#else
  void *handle;
#endif
  atomic_uint active;
} Library;
typedef struct {
  Library *owner;
  void *address;
} Symbol;
FooResult foo_dylib_open(FooText path) {
  if (!path.len) return failure(ARGUMENT);
  char *name = string(path);
  if (!name) return failure(ARGUMENT);
#ifdef _WIN32
  HMODULE handle = LoadLibraryA(name);
#else
  void *handle = dlopen(name, RTLD_NOW | RTLD_LOCAL);
#endif
  free(name);
  if (!handle) return failure(MISSING);
  Library *library = owned(sizeof(*library), DYNAMIC_LIBRARIES);
  if (!library) {
#ifdef _WIN32
    FreeLibrary(handle);
#else
    dlclose(handle);
#endif
    return failure(MEMORY);
  }
  library->handle = handle;
  atomic_init(&library->active, 0);
  return (FooResult){.pointer = library};
}
FooResult foo_dylib_lookup(void *pointer, FooText name) {
  Resource *entry = resource(pointer, DYNAMIC_LIBRARIES);
  if (!entry || !name.len) return failure(entry ? ARGUMENT : CLOSED);
  char *label = string(name);
  if (!label) return failure(ARGUMENT);
  Library *library = pointer;
  atomic_fetch_add_explicit(&library->active, 1, memory_order_acquire);
  if (atomic_load_explicit(&entry->closed, memory_order_acquire)) {
    atomic_fetch_sub_explicit(&library->active, 1, memory_order_release);
    free(label);
    return failure(CLOSED);
  }
#ifdef _WIN32
  void *address = (void *)GetProcAddress(library->handle, label);
#else
  void *address = dlsym(library->handle, label);
#endif
  atomic_fetch_sub_explicit(&library->active, 1, memory_order_release);
  free(label);
  if (!address) return failure(MISSING);
  Symbol *symbol = owned(sizeof(*symbol), DYNAMIC_SYMBOLS);
  if (!symbol) return failure(MEMORY);
  symbol->owner = library;
  symbol->address = address;
  return (FooResult){.pointer = symbol};
}
FooResult foo_dylib_call(void *pointer, uint64_t argument) {
  Symbol *symbol = resource(pointer, DYNAMIC_SYMBOLS) ? pointer : NULL;
  if (!symbol) return failure(CLOSED);
  Resource *entry = resource(symbol->owner, DYNAMIC_LIBRARIES);
  if (!entry) return failure(CLOSED);
  atomic_fetch_add_explicit(&symbol->owner->active, 1, memory_order_acquire);
  if (atomic_load_explicit(&entry->closed, memory_order_acquire)) {
    atomic_fetch_sub_explicit(&symbol->owner->active, 1, memory_order_release);
    return failure(CLOSED);
  }
  uint64_t (*function)(uint64_t);
  memcpy(&function, &symbol->address, sizeof(function));
  uint64_t result = function(argument);
  atomic_fetch_sub_explicit(&symbol->owner->active, 1, memory_order_release);
  return (FooResult){.number = result};
}
FooResult foo_dylib_discard(void *pointer) {
  Resource *entry = resource(pointer, DYNAMIC_SYMBOLS);
  if (!entry) return failure(CLOSED);
  atomic_store_explicit(&entry->closed, 1, memory_order_release);
  return (FooResult){0};
}
FooResult foo_dylib_close(void *pointer) {
  Resource *entry = resource(pointer, DYNAMIC_LIBRARIES);
  if (!entry) return failure(CLOSED);
  Library *library = pointer;
  if (atomic_exchange_explicit(&entry->closed, 1, memory_order_acq_rel))
    return failure(CLOSED);
  while (atomic_load_explicit(&library->active, memory_order_acquire)) { }
#ifdef _WIN32
  return FreeLibrary(library->handle) ? (FooResult){0} : failure(SYSTEM);
#else
  return dlclose(library->handle) == 0 ? (FooResult){0} : failure(SYSTEM);
#endif
}
