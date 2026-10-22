FooResult foo_process_run(FooText command) {
  char *value = string(command);
  if (!value)
    return failure(ARGUMENT);
  int status = system(value);
  free(value);
  if (status == -1)
    return failure(SYSTEM);
#ifndef _WIN32
  status = WIFEXITED(status)     ? WEXITSTATUS(status)
           : WIFSIGNALED(status) ? 128 + WTERMSIG(status)
                                 : status;
#endif
  return (FooResult){.number = (uint64_t)status};
}
FooResult foo_process_execute(FooText program, FooText items) {
  if (items.len > (SIZE_MAX / sizeof(char *)) - 2)
    return failure(BOUNDS);
  char *name = string(program);
  if (!name)
    return failure(ARGUMENT);
  const FooText *values = (const FooText *)items.data;
  char **vector = calloc(items.len + 2, sizeof(*vector));
  if (!vector) {
    free(name);
    return failure(MEMORY);
  }
  vector[0] = name;
  size_t index = 0;
  for (; index < items.len; index++) {
    vector[index + 1] = string(values[index]);
    if (!vector[index + 1])
      break;
  }
  if (index != items.len) {
    for (size_t item = 0; item <= index; item++)
      free(vector[item]);
    free(vector);
    return failure(ARGUMENT);
  }
#ifdef _WIN32
  intptr_t spawned = _spawnvp(_P_WAIT, name, (const char *const *)vector);
  int status = (int)spawned;
  int problem = spawned < 0 ? errno : 0;
#else
  int channel[2];
  if (pipe(channel) || fcntl(channel[1], F_SETFD, FD_CLOEXEC)) {
    int problem = errno;
    for (size_t item = 0; item <= items.len; item++)
      free(vector[item]);
    free(vector);
    errno = problem;
    return failure(IO);
  }
  pid_t child = fork();
  if (!child) {
    close(channel[0]);
    execvp(name, vector);
    int problem = errno;
    (void)write(channel[1], &problem, sizeof(problem));
    _exit(127);
  }
  close(channel[1]);
  int problem = 0;
  ssize_t reported;
  do {
    reported = read(channel[0], &problem, sizeof(problem));
  } while (reported < 0 && errno == EINTR);
  close(channel[0]);
  int state = 0;
  while (child > 0 && waitpid(child, &state, 0) < 0) {
    if (errno != EINTR) {
      child = -1;
      break;
    }
  }
  int status = child < 0 ? -1 : WIFEXITED(state) ? WEXITSTATUS(state) :
               WIFSIGNALED(state) ? 128 + WTERMSIG(state) : -1;
  if (reported < 0)
    status = -1;
#endif
  for (size_t item = 0; item <= items.len; item++)
    free(vector[item]);
  free(vector);
  return problem ? failure(problem == ENOENT ? MISSING : IO) :
         status < 0 ? failure(IO) :
                      (FooResult){.number = (uint64_t)status};
}
FooResult foo_process_count(void) {
  return (FooResult){.number = (uint64_t)count};
}
FooResult foo_process_argument(uint64_t index) {
  return index >= (uint64_t)count
             ? failure(BOUNDS)
             : text(arguments[index], strlen(arguments[index]));
}
FooResult foo_process_environment(FooText name) {
  char *key = string(name);
  if (!key)
    return failure(ARGUMENT);
  const char *value = getenv(key);
  free(key);
  return value ? text(value, strlen(value)) : failure(MISSING);
}
FooResult foo_process_id(void) {
#ifdef _WIN32
  return (FooResult){.number = GetCurrentProcessId()};
#else
  return (FooResult){.number = (uint64_t)getpid()};
#endif
}
FooResult foo_process_parent(void) {
#ifdef _WIN32
  DWORD current = GetCurrentProcessId();
  HANDLE snapshot = CreateToolhelp32Snapshot(TH32CS_SNAPPROCESS, 0);
  if (snapshot == INVALID_HANDLE_VALUE) return failure(SYSTEM);
  PROCESSENTRY32 entry = {.dwSize = sizeof(entry)};
  uint64_t parent = 0;
  if (Process32First(snapshot, &entry)) {
    do {
      if (entry.th32ProcessID == current) {
        parent = entry.th32ParentProcessID;
        break;
      }
    } while (Process32Next(snapshot, &entry));
  }
  CloseHandle(snapshot);
  return parent ? (FooResult){.number = parent} : failure(SYSTEM);
#else
  return (FooResult){.number = (uint64_t)getppid()};
#endif
}
typedef struct {
#ifdef _WIN32
  HANDLE handle;
  HANDLE input, output, report;
#else
  pid_t pid;
  int input, output, report;
#endif
  uint64_t status;
  int finished;
  int piped;
} Child;
static uint64_t outcome(int status) {
#ifdef _WIN32
  return (uint64_t)(unsigned)status;
#else
  return WIFEXITED(status) ? (uint64_t)WEXITSTATUS(status) :
         WIFSIGNALED(status) ? (uint64_t)(128 + WTERMSIG(status)) : 255;
#endif
}
FooResult foo_process_spawn(FooText program, FooText items) {
  if (!program.len || !program.data ||
      (items.len && !items.data) ||
      items.len > (SIZE_MAX / sizeof(char *)) - 2) return failure(ARGUMENT);
  char *name = string(program);
  if (!name) return failure(ARGUMENT);
  char **vector = calloc(items.len + 2, sizeof(*vector));
  if (!vector) { free(name); return failure(MEMORY); }
  vector[0] = name;
  const FooText *values = (const FooText *)items.data;
  size_t index = 0;
  for (; index < items.len; index++) {
    if (values[index].len && !values[index].data) break;
    vector[index + 1] = string(values[index]);
    if (!vector[index + 1]) break;
  }
  if (index != items.len) {
    for (size_t item = 0; item <= index; item++) free(vector[item]);
    free(vector);
    return failure(ARGUMENT);
  }
#ifdef _WIN32
  intptr_t launched = _spawnvp(_P_NOWAIT, name, (const char *const *)vector);
  int problem = launched < 0 ? errno : 0;
#else
  int channel[2];
  int problem = pipe(channel) ? errno : 0;
  if (!problem && fcntl(channel[1], F_SETFD, FD_CLOEXEC)) {
    problem = errno;
    close(channel[0]); close(channel[1]);
  }
  pid_t launched = -1;
  if (!problem) {
    launched = fork();
    if (!launched) {
      close(channel[0]);
      execvp(name, vector);
      int cause = errno;
      (void)write(channel[1], &cause, sizeof(cause));
      _exit(127);
    }
    if (launched < 0) {
      problem = errno;
      close(channel[0]); close(channel[1]);
    } else {
      close(channel[1]);
      int cause = 0;
      ssize_t amount;
      do { amount = read(channel[0], &cause, sizeof(cause)); }
      while (amount < 0 && errno == EINTR);
      int saved = errno;
      close(channel[0]);
      if (amount != 0) {
        problem = amount == sizeof(cause) ? cause :
                  amount < 0 ? saved : EIO;
        if (amount < 0) kill(launched, SIGKILL);
        while (waitpid(launched, NULL, 0) < 0 && errno == EINTR) { }
      }
    }
  }
#endif
  for (size_t item = 0; item <= items.len; item++) free(vector[item]);
  free(vector);
  if (problem) return failure(problem == ENOENT ? MISSING : IO);
  Child *child = owned(sizeof(*child), CHILDREN);
  if (!child) {
#ifdef _WIN32
    TerminateProcess((HANDLE)launched, 137);
    WaitForSingleObject((HANDLE)launched, INFINITE);
    CloseHandle((HANDLE)launched);
#else
    kill(launched, SIGKILL);
    while (waitpid(launched, NULL, 0) < 0 && errno == EINTR) { }
#endif
    return failure(MEMORY);
  }
#ifdef _WIN32
  child->handle = (HANDLE)launched;
#else
  child->pid = launched;
#endif
  return (FooResult){.pointer = child};
}
#ifdef _WIN32
static char *assemble(char *const *args, size_t count) {
  size_t capacity = 1;
  for (size_t index = 0; index < count; index++) {
    size_t length = strlen(args[index]);
    if (capacity > 32764 || length > (32764 - capacity) / 2) return NULL;
    capacity += length * 2 + 3;
  }
  char *command = malloc(capacity);
  if (!command) return NULL;
  char *cursor = command;
  for (size_t index = 0; index < count; index++) {
    if (index) *cursor++ = ' ';
    *cursor++ = '"';
    const char *input = args[index];
    while (*input) {
      size_t slashes = 0;
      while (*input == '\\') { slashes++; input++; }
      if (*input == '"') {
        for (size_t each = 0; each < slashes * 2 + 1; each++) *cursor++ = '\\';
        *cursor++ = *input++;
      } else {
        for (size_t each = 0; each < (*input ? slashes : slashes * 2); each++)
          *cursor++ = '\\';
        if (*input) *cursor++ = *input++;
      }
    }
    *cursor++ = '"';
  }
  *cursor = 0;
  return command;
}
static void handle(HANDLE *handle) {
  if (*handle) { CloseHandle(*handle); *handle = NULL; }
}
#else
static int pair(int pair[2]) {
  int raw[2];
  if (pipe(raw)) return 0;
  pair[0] = pair[1] = -1;
  for (int side = 0; side < 2; side++) {
    pair[side] = fcntl(raw[side], F_DUPFD, 3);
    if (pair[side] < 0 || fcntl(pair[side], F_SETFD, FD_CLOEXEC)) {
      int problem = errno;
      if (pair[0] >= 0) close(pair[0]);
      if (pair[1] >= 0) close(pair[1]);
      close(raw[0]); close(raw[1]);
      pair[0] = pair[1] = -1;
      errno = problem;
      return 0;
    }
  }
  close(raw[0]); close(raw[1]);
  return 1;
}
#endif
FooResult foo_process_pipe(FooText program, FooText items) {
  if (!program.len || !program.data || (items.len && !items.data) ||
      items.len > (SIZE_MAX / sizeof(char *)) - 2) return failure(ARGUMENT);
  char *name = string(program);
  if (!name) return failure(ARGUMENT);
  char **vector = calloc(items.len + 2, sizeof(*vector));
  if (!vector) { free(name); return failure(MEMORY); }
  vector[0] = name;
  const FooText *values = (const FooText *)items.data;
  size_t index = 0;
  for (; index < items.len; index++) {
    if (values[index].len && !values[index].data) break;
    vector[index + 1] = string(values[index]);
    if (!vector[index + 1]) break;
  }
  if (index != items.len) {
    for (size_t item = 0; item <= index; item++) free(vector[item]);
    free(vector);
    return failure(ARGUMENT);
  }
  int problem = 0;
#ifdef _WIN32
  HANDLE input_read = NULL, input_write = NULL, output_read = NULL,
         output_write = NULL, report_read = NULL, report_write = NULL;
  SECURITY_ATTRIBUTES security = {.nLength = sizeof(security),
                                  .bInheritHandle = TRUE};
  PROCESS_INFORMATION launched = {0};
  char *command = assemble(vector, items.len + 1);
  if (!command) problem = ERROR_INVALID_PARAMETER;
  if (!problem && (!CreatePipe(&input_read, &input_write, &security, 0) ||
      !CreatePipe(&output_read, &output_write, &security, 0) ||
      !CreatePipe(&report_read, &report_write, &security, 0) ||
      !SetHandleInformation(input_write, HANDLE_FLAG_INHERIT, 0) ||
      !SetHandleInformation(output_read, HANDLE_FLAG_INHERIT, 0) ||
      !SetHandleInformation(report_read, HANDLE_FLAG_INHERIT, 0)))
    problem = GetLastError();
  SIZE_T capacity = 0;
  LPPROC_THREAD_ATTRIBUTE_LIST attributes = NULL;
  int initialized = 0;
  /* UpdateProcThreadAttribute borrows this array until the list is destroyed. */
  HANDLE inherited[3] = {input_read, output_write, report_write};
  if (!problem) {
    InitializeProcThreadAttributeList(NULL, 1, 0, &capacity);
    attributes = malloc(capacity);
    if (!attributes ||
        !InitializeProcThreadAttributeList(attributes, 1, 0, &capacity))
      problem = attributes ? GetLastError() : ERROR_NOT_ENOUGH_MEMORY;
    else initialized = 1;
  }
  if (!problem) {
    if (!UpdateProcThreadAttribute(attributes, 0,
          PROC_THREAD_ATTRIBUTE_HANDLE_LIST, inherited, sizeof(inherited),
          NULL, NULL)) problem = GetLastError();
  }
  if (!problem) {
    STARTUPINFOEXA startup = {0};
    startup.StartupInfo.cb = sizeof(startup);
    startup.StartupInfo.dwFlags = STARTF_USESTDHANDLES;
    startup.StartupInfo.hStdInput = input_read;
    startup.StartupInfo.hStdOutput = output_write;
    startup.StartupInfo.hStdError = report_write;
    startup.lpAttributeList = attributes;
    if (!CreateProcessA(NULL, command, NULL, NULL, TRUE,
          EXTENDED_STARTUPINFO_PRESENT | CREATE_NO_WINDOW, NULL, NULL,
          &startup.StartupInfo, &launched)) problem = GetLastError();
  }
  if (initialized) DeleteProcThreadAttributeList(attributes);
  free(attributes);
  free(command);
  handle(&input_read); handle(&output_write);
  handle(&report_write);
  if (launched.hThread) CloseHandle(launched.hThread);
  if (problem) {
    handle(&input_write); handle(&output_read);
    handle(&report_read);
  }
#else
  int pipes[4][2] = {{-1, -1}, {-1, -1}, {-1, -1}, {-1, -1}};
  for (int part = 0; part < 4; part++)
    if (!pair(pipes[part])) { problem = errno; break; }
  pid_t launched = -1;
  if (!problem) {
    launched = fork();
    if (!launched) {
      int cause = 0;
      if (dup2(pipes[0][0], STDIN_FILENO) < 0 ||
          dup2(pipes[1][1], STDOUT_FILENO) < 0 ||
          dup2(pipes[2][1], STDERR_FILENO) < 0) cause = errno;
      for (int part = 0; part < 4; part++)
        for (int side = 0; side < 2; side++)
          if (part != 3 || side != 1) close(pipes[part][side]);
      if (!cause) { execvp(name, vector); cause = errno; }
      (void)write(pipes[3][1], &cause, sizeof(cause));
      _exit(127);
    }
    if (launched < 0) problem = errno;
    else {
      close(pipes[0][0]); pipes[0][0] = -1;
      close(pipes[1][1]); pipes[1][1] = -1;
      close(pipes[2][1]); pipes[2][1] = -1;
      close(pipes[3][1]); pipes[3][1] = -1;
      int cause = 0;
      ssize_t amount;
      do { amount = read(pipes[3][0], &cause, sizeof(cause)); }
      while (amount < 0 && errno == EINTR);
      int saved = errno;
      close(pipes[3][0]); pipes[3][0] = -1;
      if (amount != 0) {
        problem = amount == sizeof(cause) ? cause :
                  amount < 0 ? saved : EIO;
        if (amount < 0) kill(launched, SIGKILL);
        while (waitpid(launched, NULL, 0) < 0 && errno == EINTR) { }
      }
    }
  }
  if (problem)
    for (int part = 0; part < 4; part++)
      for (int side = 0; side < 2; side++)
        if (pipes[part][side] >= 0) close(pipes[part][side]);
#endif
  for (size_t item = 0; item <= items.len; item++) free(vector[item]);
  free(vector);
  if (problem) {
#ifdef _WIN32
    return failure(problem == ERROR_FILE_NOT_FOUND ||
                   problem == ERROR_PATH_NOT_FOUND ? MISSING : IO);
#else
    return failure(problem == ENOENT ? MISSING : IO);
#endif
  }
  Child *child = owned(sizeof(*child), CHILDREN);
  if (!child) {
#ifdef _WIN32
    TerminateProcess(launched.hProcess, 137);
    WaitForSingleObject(launched.hProcess, INFINITE);
    CloseHandle(launched.hProcess);
    handle(&input_write); handle(&output_read);
    handle(&report_read);
#else
    kill(launched, SIGKILL);
    while (waitpid(launched, NULL, 0) < 0 && errno == EINTR) { }
    close(pipes[0][1]); close(pipes[1][0]); close(pipes[2][0]);
#endif
    return failure(MEMORY);
  }
  child->piped = 1;
#ifdef _WIN32
  child->handle = launched.hProcess;
  child->input = input_write;
  child->output = output_read;
  child->report = report_read;
#else
  child->pid = launched;
  child->input = pipes[0][1];
  child->output = pipes[1][0];
  child->report = pipes[2][0];
#endif
  return (FooResult){.pointer = child};
}
FooResult foo_process_write(void *pointer, FooText content) {
  if (!resource(pointer, CHILDREN)) return failure(CLOSED);
  Child *child = pointer;
  if (!child->piped) return failure(ARGUMENT);
  if (content.len && !content.data) return failure(ARGUMENT);
  if (content.len > INT_MAX) return failure(BOUNDS);
  if (!content.len) return (FooResult){0};
#ifdef _WIN32
  if (!child->input) return failure(CLOSED);
  DWORD written = 0;
  if (!WriteFile(child->input, content.data, (DWORD)content.len,
                 &written, NULL)) return failure(IO);
  return (FooResult){.number = written};
#else
  if (child->input < 0) return failure(CLOSED);
  sigset_t blocked, previous, pending;
  sigemptyset(&blocked);
  sigaddset(&blocked, SIGPIPE);
  if (pthread_sigmask(SIG_BLOCK, &blocked, &previous)) return failure(SYSTEM);
  int prior = !sigpending(&pending) && sigismember(&pending, SIGPIPE);
  ssize_t written;
  do { written = write(child->input, content.data, content.len); }
  while (written < 0 && errno == EINTR);
  int problem = errno;
  if (written < 0 && problem == EPIPE && !prior &&
      !sigpending(&pending) && sigismember(&pending, SIGPIPE)) {
    int received;
    sigwait(&blocked, &received);
  }
  pthread_sigmask(SIG_SETMASK, &previous, NULL);
  return written < 0 ? failure(IO) :
      (FooResult){.number = (uint64_t)written};
#endif
}
FooResult foo_process_seal(void *pointer) {
  if (!resource(pointer, CHILDREN)) return failure(CLOSED);
  Child *child = pointer;
  if (!child->piped) return failure(ARGUMENT);
#ifdef _WIN32
  if (!child->input) return failure(CLOSED);
  HANDLE input = child->input;
  child->input = NULL;
  return CloseHandle(input) ? (FooResult){0} : failure(IO);
#else
  if (child->input < 0) return failure(CLOSED);
  int input = child->input;
  child->input = -1;
  return close(input) ? failure(IO) : (FooResult){0};
#endif
}
FooResult foo_process_read(void *pointer, FooText stream, uint64_t size) {
  if (!resource(pointer, CHILDREN)) return failure(CLOSED);
  Child *child = pointer;
  if (!child->piped) return failure(ARGUMENT);
  int output = supports(stream, "output");
  if (!output && !supports(stream, "error")) return failure(ARGUMENT);
  if (size > 16 * 1024 * 1024) return failure(BOUNDS);
  if (!size) return (FooResult){0};
  uint8_t *buffer = malloc((size_t)size);
  if (!buffer) return failure(MEMORY);
#ifdef _WIN32
  HANDLE handle = output ? child->output : child->report;
  if (!handle) { free(buffer); return failure(CLOSED); }
  DWORD received = 0;
  int ok = ReadFile(handle, buffer, (DWORD)size, &received, NULL);
  int problem = ok || GetLastError() == ERROR_BROKEN_PIPE ? 0 : IO;
#else
  int handle = output ? child->output : child->report;
  if (handle < 0) { free(buffer); return failure(CLOSED); }
  ssize_t received;
  do { received = read(handle, buffer, (size_t)size); }
  while (received < 0 && errno == EINTR);
  int problem = received < 0 ? IO : 0;
#endif
  FooResult result = problem ? failure(problem) : text(buffer, (size_t)received);
  free(buffer);
  return result;
}
FooResult foo_process_release(FooText content) {
  return foo_text_release(content);
}
FooResult foo_process_identity(void *pointer) {
  if (!resource(pointer, CHILDREN)) return failure(CLOSED);
  Child *child = pointer;
#ifdef _WIN32
  DWORD id = GetProcessId(child->handle);
  return id ? (FooResult){.number = id} : failure(SYSTEM);
#else
  return (FooResult){.number = (uint64_t)child->pid};
#endif
}
static FooResult check(Child *child, bool block) {
  if (child->finished) return (FooResult){.number = 0};
#ifdef _WIN32
  DWORD ready = WaitForSingleObject(child->handle, block ? INFINITE : 0);
  if (ready == WAIT_TIMEOUT) return (FooResult){.number = 1};
  if (ready != WAIT_OBJECT_0) return failure(SYSTEM);
  DWORD status = 0;
  if (!GetExitCodeProcess(child->handle, &status)) return failure(SYSTEM);
  child->status = outcome((int)status);
#else
  int status = 0;
  pid_t result;
  do { result = waitpid(child->pid, &status, block ? 0 : WNOHANG); }
  while (result < 0 && errno == EINTR);
  if (!result) return (FooResult){.number = 1};
  if (result < 0) return failure(SYSTEM);
  child->status = outcome(status);
#endif
  child->finished = 1;
  return (FooResult){0};
}
FooResult foo_process_active(void *pointer) {
  if (!resource(pointer, CHILDREN)) return failure(CLOSED);
  return check(pointer, false);
}
FooResult foo_process_wait(void *pointer) {
  if (!resource(pointer, CHILDREN)) return failure(CLOSED);
  Child *child = pointer;
  FooResult checked = check(child, true);
  return checked.error ? checked : (FooResult){.number = child->status};
}
FooResult foo_process_observe(void *pointer, uint64_t milliseconds) {
  if (!resource(pointer, CHILDREN)) return failure(CLOSED);
  if (milliseconds >= UINT32_MAX) return failure(BOUNDS);
  Child *child = pointer;
#ifdef _WIN32
  if (child->finished) return (FooResult){.number = 1};
  DWORD ready = WaitForSingleObject(child->handle, (DWORD)milliseconds);
  if (ready == WAIT_TIMEOUT) return (FooResult){0};
  if (ready != WAIT_OBJECT_0) return failure(SYSTEM);
  FooResult checked = check(child, false);
  return checked.error ? checked : (FooResult){.number = !checked.number};
#else
  FooResult now = foo_time_current();
  if (now.error) return now;
  uint64_t duration = milliseconds * UINT64_C(1000000);
  if (duration > UINT64_MAX - now.number) return failure(BOUNDS);
  uint64_t deadline = now.number + duration;
  for (;;) {
    FooResult checked = check(child, false);
    if (checked.error || !checked.number)
      return checked.error ? checked : (FooResult){.number = 1};
    now = foo_time_current();
    if (now.error) return now;
    if (now.number >= deadline) return (FooResult){0};
    uint64_t remaining = deadline - now.number;
    FooResult slept = foo_time_sleep(remaining < 1000000 ? remaining : 1000000);
    if (slept.error) return slept;
  }
#endif
}
FooResult foo_process_kill(void *pointer) {
  if (!resource(pointer, CHILDREN)) return failure(CLOSED);
  Child *child = pointer;
  FooResult checked = check(child, false);
  if (checked.error || !checked.number) return checked;
#ifdef _WIN32
  return TerminateProcess(child->handle, 137) ? (FooResult){0} : failure(SYSTEM);
#else
  return !kill(child->pid, SIGKILL) || errno == ESRCH
      ? (FooResult){0} : failure(SYSTEM);
#endif
}
FooResult foo_process_signal(void *pointer, FooText name) {
  if (!resource(pointer, CHILDREN)) return failure(CLOSED);
  int selected = supports(name, "kill") ? 1 :
                 supports(name, "terminate") ? 2 :
                 supports(name, "interrupt") ? 3 :
                 supports(name, "hangup") ? 4 : 0;
  if (!selected) return failure(ARGUMENT);
  Child *child = pointer;
  FooResult checked = check(child, false);
  if (checked.error || !checked.number) return checked;
#ifdef _WIN32
  if (selected > 2) return failure(MISSING);
  return TerminateProcess(child->handle, selected == 1 ? 137 : 143)
      ? (FooResult){0} : failure(SYSTEM);
#else
  int signal = selected == 1 ? SIGKILL : selected == 2 ? SIGTERM :
               selected == 3 ? SIGINT : SIGHUP;
  return !kill(child->pid, signal) || errno == ESRCH
      ? (FooResult){0} : failure(SYSTEM);
#endif
}
FooResult foo_process_close(void *pointer) {
  Resource *entry = resource(pointer, CHILDREN);
  if (!entry) return failure(CLOSED);
  FooResult stopped = foo_process_kill(pointer);
  if (stopped.error) return stopped;
  FooResult waited = foo_process_wait(pointer);
  if (waited.error) return waited;
  Child *child = pointer;
  int failed = 0;
  if (child->piped) {
#ifdef _WIN32
    if (child->input && !CloseHandle(child->input)) failed = 1;
    if (child->output && !CloseHandle(child->output)) failed = 1;
    if (child->report && !CloseHandle(child->report)) failed = 1;
#else
    if (child->input >= 0 && close(child->input)) failed = 1;
    if (child->output >= 0 && close(child->output)) failed = 1;
    if (child->report >= 0 && close(child->report)) failed = 1;
#endif
  }
#ifdef _WIN32
  if (!CloseHandle(child->handle)) failed = 1;
#endif
  atomic_store_explicit(&entry->closed, 1, memory_order_release);
  return failed ? failure(IO) : (FooResult){0};
}
FooResult foo_process_exit(uint8_t code) {
  exit(code);
}
FooResult foo_process_abort(void) {
  abort();
}
