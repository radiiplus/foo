FooResult foo_process_count(void) {
  return (FooResult){.number = (uint64_t)argc};
}

FooResult foo_process_argument(uint64_t index) {
  if (index >= (uint64_t)argc || !argv[index])
    return failure(BOUNDS);
  const char *value = argv[index];
  return copied((const uint8_t *)value, strlen(value));
}

FooResult foo_process_environment(FooText name) {
  char *key = pathname(name);
  if (!key) return failure(ARGUMENT);
  const char *value = getenv(key);
  free(key);
  return value ? copied((const uint8_t *)value, strlen(value)) :
    failure(MISSING);
}

#ifdef FOO_WASI_HOST_BRIDGE
__attribute__((import_module("foo_host"), import_name("process_run")))
extern int32_t foo_host_process_run(uint32_t command, uint32_t length);
__attribute__((import_module("foo_host"), import_name("process_execute")))
extern int32_t foo_host_process_execute(uint32_t program, uint32_t length,
  uint32_t arguments, uint32_t count);
__attribute__((import_module("foo_host"), import_name("process_id")))
extern int32_t foo_host_process_id(void);
__attribute__((import_module("foo_host"), import_name("process_parent")))
extern int32_t foo_host_process_parent(void);
__attribute__((import_module("foo_host"), import_name("process_spawn")))
extern int32_t foo_host_process_spawn(uint32_t program, uint32_t length,
  uint32_t arguments, uint32_t count, uint32_t piped);
__attribute__((import_module("foo_host"), import_name("process_write")))
extern int32_t foo_host_process_write(int32_t child, uint32_t content,
  uint32_t length);
__attribute__((import_module("foo_host"), import_name("process_seal")))
extern int32_t foo_host_process_seal(int32_t child);
__attribute__((import_module("foo_host"), import_name("process_read")))
extern int32_t foo_host_process_read(int32_t child, int32_t stream,
  uint32_t destination, uint32_t length);
__attribute__((import_module("foo_host"), import_name("process_identity")))
extern int32_t foo_host_process_identity(int32_t child);
__attribute__((import_module("foo_host"), import_name("process_active")))
extern int32_t foo_host_process_active(int32_t child);
__attribute__((import_module("foo_host"), import_name("process_wait")))
extern int32_t foo_host_process_wait(int32_t child);
__attribute__((import_module("foo_host"), import_name("process_observe")))
extern int32_t foo_host_process_observe(int32_t child, uint32_t milliseconds);
__attribute__((import_module("foo_host"), import_name("process_signal")))
extern int32_t foo_host_process_signal(int32_t child, int32_t signal);
__attribute__((import_module("foo_host"), import_name("process_close")))
extern int32_t foo_host_process_close(int32_t child);

static FooResult status(int32_t status) {
  return status < 0 ? failure(-status) : (FooResult){.number = (uint32_t)status};
}

FooResult foo_process_run(FooText command) {
  if ((command.len && !command.data) || command.len > UINT32_MAX ||
      (command.len && memchr(command.data, 0, (size_t)command.len)))
    return failure(ARGUMENT);
  if (!command.len) return (FooResult){0};
  return status(foo_host_process_run((uint32_t)(uintptr_t)command.data,
    (uint32_t)command.len));
}

FooResult foo_process_execute(FooText program, FooText arguments) {
  if (!program.data || !program.len || program.len > UINT32_MAX ||
      memchr(program.data, 0, (size_t)program.len) ||
      arguments.len > 65536 ||
      (arguments.len && !arguments.data)) return failure(ARGUMENT);
  const FooText *items = (const FooText *)arguments.data;
  for (uint64_t index = 0; index < arguments.len; index++)
    if ((items[index].len && !items[index].data) ||
        items[index].len > UINT32_MAX ||
        (items[index].len && memchr(items[index].data, 0,
          (size_t)items[index].len))) return failure(ARGUMENT);
  return status(foo_host_process_execute((uint32_t)(uintptr_t)program.data,
    (uint32_t)program.len, (uint32_t)(uintptr_t)arguments.data,
    (uint32_t)arguments.len));
}

FooResult foo_process_id(void) { return status(foo_host_process_id()); }
FooResult foo_process_parent(void) { return status(foo_host_process_parent()); }

typedef struct { int32_t id; int piped; } Child;

static FooResult launch(FooText program, FooText arguments, int piped) {
  if (!program.data || !program.len || program.len > UINT32_MAX ||
      memchr(program.data, 0, (size_t)program.len) ||
      arguments.len > 65536 || (arguments.len && !arguments.data))
    return failure(ARGUMENT);
  const FooText *items = (const FooText *)arguments.data;
  for (uint64_t index = 0; index < arguments.len; index++)
    if ((items[index].len && !items[index].data) ||
        items[index].len > UINT32_MAX ||
        (items[index].len && memchr(items[index].data, 0,
          (size_t)items[index].len))) return failure(ARGUMENT);
  int32_t id = foo_host_process_spawn((uint32_t)(uintptr_t)program.data,
    (uint32_t)program.len, (uint32_t)(uintptr_t)arguments.data,
    (uint32_t)arguments.len, (uint32_t)piped);
  if (id < 0) return failure(-id);
  Child *child = owned(sizeof(*child), CHILD_RESOURCE);
  if (!child) { foo_host_process_close(id); return failure(MEMORY); }
  *child = (Child){id, piped};
  return (FooResult){.pointer = child};
}

FooResult foo_process_spawn(FooText program, FooText arguments) {
  return launch(program, arguments, 0);
}
FooResult foo_process_pipe(FooText program, FooText arguments) {
  return launch(program, arguments, 1);
}
FooResult foo_process_write(void *pointer, FooText content) {
  if (!entry(pointer, CHILD_RESOURCE)) return failure(CLOSED);
  Child *child = pointer;
  if (!child->piped || (content.len && !content.data)) return failure(ARGUMENT);
  uint32_t count = content.len > 1048576 ? 1048576 : (uint32_t)content.len;
  return status(foo_host_process_write(child->id,
    (uint32_t)(uintptr_t)content.data, count));
}
FooResult foo_process_seal(void *pointer) {
  if (!entry(pointer, CHILD_RESOURCE)) return failure(CLOSED);
  Child *child = pointer;
  return child->piped ? status(foo_host_process_seal(child->id)) :
    failure(ARGUMENT);
}
FooResult foo_process_read(void *pointer, FooText stream, uint64_t size) {
  if (!entry(pointer, CHILD_RESOURCE)) return failure(CLOSED);
  Child *child = pointer;
  if (!child->piped || (stream.len && !stream.data)) return failure(ARGUMENT);
  int selected = stream.len == 6 && !memcmp(stream.data, "output", 6) ? 0 :
    stream.len == 5 && !memcmp(stream.data, "error", 5) ? 1 : -1;
  if (selected < 0) return failure(ARGUMENT);
  if (!size) return (FooResult){0};
  uint32_t count = size > 1048576 ? 1048576 : (uint32_t)size;
  uint8_t *bytes = malloc(count);
  if (!bytes) return failure(MEMORY);
  int32_t read = foo_host_process_read(child->id, selected,
    (uint32_t)(uintptr_t)bytes, count);
  FooResult result = read < 0 ? failure(-read) :
    copied(bytes, (size_t)read);
  free(bytes);
  return result;
}
FooResult foo_process_release(FooText content) {
  return foo_text_release(content);
}
FooResult foo_process_identity(void *pointer) {
  if (!entry(pointer, CHILD_RESOURCE)) return failure(CLOSED);
  return status(foo_host_process_identity(((Child *)pointer)->id));
}
FooResult foo_process_active(void *pointer) {
  if (!entry(pointer, CHILD_RESOURCE)) return failure(CLOSED);
  return status(foo_host_process_active(((Child *)pointer)->id));
}
FooResult foo_process_wait(void *pointer) {
  if (!entry(pointer, CHILD_RESOURCE)) return failure(CLOSED);
  return status(foo_host_process_wait(((Child *)pointer)->id));
}
FooResult foo_process_observe(void *pointer, uint64_t milliseconds) {
  if (!entry(pointer, CHILD_RESOURCE)) return failure(CLOSED);
  if (milliseconds >= UINT32_MAX) return failure(BOUNDS);
  return status(foo_host_process_observe(((Child *)pointer)->id,
    (uint32_t)milliseconds));
}
FooResult foo_process_signal(void *pointer, FooText name) {
  if (!entry(pointer, CHILD_RESOURCE)) return failure(CLOSED);
  if (name.len && !name.data) return failure(ARGUMENT);
  int signal = name.len == 4 && !memcmp(name.data, "kill", 4) ? 9 :
    name.len == 9 && !memcmp(name.data, "terminate", 9) ? 15 :
    name.len == 9 && !memcmp(name.data, "interrupt", 9) ? 2 :
    name.len == 6 && !memcmp(name.data, "hangup", 6) ? 1 : -1;
  return signal < 0 ? failure(ARGUMENT) :
    status(foo_host_process_signal(((Child *)pointer)->id, signal));
}
FooResult foo_process_kill(void *pointer) {
  if (!entry(pointer, CHILD_RESOURCE)) return failure(CLOSED);
  return status(foo_host_process_signal(((Child *)pointer)->id, 9));
}
FooResult foo_process_close(void *pointer) {
  Entry *item = entry(pointer, CHILD_RESOURCE);
  if (!item) return failure(CLOSED);
  FooResult result = status(foo_host_process_close(((Child *)pointer)->id));
  if (!result.error) retire(item);
  return result;
}
#endif

FooResult foo_process_exit(uint8_t code) {
  exit(code);
}

FooResult foo_process_abort(void) {
  abort();
}
