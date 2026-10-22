typedef struct {
  uint8_t *base;
  size_t length;
  int mode;
  int committed;
} Region;
FooResult foo_vm_reserve(uint64_t size) {
  if (!size) return failure(ARGUMENT);
#ifdef _WIN32
  SYSTEM_INFO system;
  GetSystemInfo(&system);
  size_t page = system.dwPageSize;
#else
  long measured = sysconf(_SC_PAGESIZE);
  if (measured <= 0) return failure(SYSTEM);
  size_t page = (size_t)measured;
#endif
  if (size > SIZE_MAX - (page - 1)) return failure(BOUNDS);
  size_t length = ((size_t)size + page - 1) / page * page;
#ifdef _WIN32
  uint8_t *base = VirtualAlloc(NULL, length, MEM_RESERVE, PAGE_NOACCESS);
#else
  uint8_t *base = mmap(NULL, length, PROT_NONE,
                       MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
  if (base == MAP_FAILED) base = NULL;
#endif
  if (!base) return failure(MEMORY);
  Region *region = calloc(1, sizeof(*region));
  if (!region) {
#ifdef _WIN32
    VirtualFree(base, 0, MEM_RELEASE);
#else
    munmap(base, length);
#endif
    return failure(MEMORY);
  }
  *region = (Region){base, length, 0, 0};
  if (!adopt(region, length, VIRTUAL_REGIONS)) {
#ifdef _WIN32
    VirtualFree(base, 0, MEM_RELEASE);
#else
    munmap(base, length);
#endif
    free(region);
    return failure(MEMORY);
  }
  return (FooResult){.pointer = region};
}
FooResult foo_vm_size(void *pointer) {
  if (!resource(pointer, VIRTUAL_REGIONS)) return failure(CLOSED);
  return (FooResult){.number = ((Region *)pointer)->length};
}
FooResult foo_vm_commit(void *pointer) {
  if (!resource(pointer, VIRTUAL_REGIONS)) return failure(CLOSED);
  Region *region = pointer;
#ifdef _WIN32
  if (region->committed) {
    DWORD previous;
    if (!VirtualProtect(region->base, region->length, PAGE_READWRITE,
                        &previous)) return failure(SYSTEM);
  } else if (!VirtualAlloc(region->base, region->length, MEM_COMMIT,
                           PAGE_READWRITE)) return failure(MEMORY);
#else
  if (mprotect(region->base, region->length, PROT_READ | PROT_WRITE))
    return failure(SYSTEM);
#endif
  region->mode = 2;
  region->committed = 1;
  return (FooResult){0};
}
FooResult foo_vm_protect(void *pointer, FooText mode) {
  if (!resource(pointer, VIRTUAL_REGIONS)) return failure(CLOSED);
  Region *region = pointer;
  if (!region->committed) return failure(ARGUMENT);
  int selected = supports(mode, "none") ? 0 :
      supports(mode, "read") ? 1 : supports(mode, "write") ? 2 :
      supports(mode, "execute") ? 3 : -1;
  if (selected < 0) return failure(ARGUMENT);
#ifdef _WIN32
  DWORD protection = selected == 0 ? PAGE_NOACCESS :
                     selected == 1 ? PAGE_READONLY :
                     selected == 2 ? PAGE_READWRITE : PAGE_EXECUTE_READ;
  DWORD previous;
  if (!VirtualProtect(region->base, region->length, protection, &previous))
    return failure(SYSTEM);
#else
  int protection = selected == 0 ? PROT_NONE :
                   selected == 1 ? PROT_READ :
                   selected == 2 ? PROT_READ | PROT_WRITE :
                   PROT_READ | PROT_EXEC;
  if (mprotect(region->base, region->length, protection))
    return failure(SYSTEM);
#endif
  region->mode = selected;
  return (FooResult){0};
}
FooResult foo_vm_decommit(void *pointer) {
  if (!resource(pointer, VIRTUAL_REGIONS)) return failure(CLOSED);
  Region *region = pointer;
  if (!region->committed) return (FooResult){0};
#ifdef _WIN32
  if (!VirtualFree(region->base, region->length, MEM_DECOMMIT))
    return failure(SYSTEM);
#else
  if (mprotect(region->base, region->length, PROT_NONE))
    return failure(SYSTEM);
  region->mode = 0;
  if (madvise(region->base, region->length, MADV_DONTNEED))
    return failure(SYSTEM);
#endif
  region->mode = 0;
  region->committed = 0;
  return (FooResult){0};
}
FooResult foo_vm_load(void *pointer, uint64_t offset) {
  if (!resource(pointer, VIRTUAL_REGIONS)) return failure(CLOSED);
  Region *region = pointer;
  if (offset >= region->length) return failure(BOUNDS);
  if (!region->mode) return failure(ARGUMENT);
  return (FooResult){.number = region->base[offset]};
}
FooResult foo_vm_store(void *pointer, uint64_t offset, uint8_t data) {
  if (!resource(pointer, VIRTUAL_REGIONS)) return failure(CLOSED);
  Region *region = pointer;
  if (offset >= region->length) return failure(BOUNDS);
  if (region->mode != 2) return failure(ARGUMENT);
  region->base[offset] = data;
  return (FooResult){0};
}
FooResult foo_vm_release(void *pointer) {
  Resource *entry = resource(pointer, VIRTUAL_REGIONS);
  if (!entry) return failure(CLOSED);
  Region *region = pointer;
#ifdef _WIN32
  if (!VirtualFree(region->base, 0, MEM_RELEASE)) return failure(SYSTEM);
#else
  if (munmap(region->base, region->length)) return failure(SYSTEM);
#endif
  region->base = NULL;
  region->mode = 0;
  region->committed = 0;
  entry->closed = 1;
  return (FooResult){0};
}
