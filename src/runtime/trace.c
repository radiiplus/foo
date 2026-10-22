typedef struct { const char *slot; const char *file; size_t offset; } Frame;
typedef struct { Frame frames[64]; size_t depth; } Trace;
static _Thread_local Trace trace;
static void foo_trace(const char *slot, const char *file, size_t offset) {
  /* Trace storage is bounded and must not allocate while propagating an error. */
  if (trace.depth < 64) trace.frames[trace.depth++] = (Frame){slot, file, offset};
}
static void foo_trace_reset(void) { trace.depth = 0; }
static void foo_trace_report(void) {
#if defined(_WIN32) && defined(_MSC_VER)
  char enabled[2];
  size_t length = 0;
  if (getenv_s(&length, enabled, sizeof(enabled), "FOO_TRACE_ERRORS") != 0 ||
      length != 2 || enabled[0] != '1') return;
#else
  const char *enabled = getenv("FOO_TRACE_ERRORS");
  if (!enabled || enabled[0] != '1' || enabled[1] != '\0') return;
#endif
  for (size_t index = 0; index < trace.depth; index++) {
    const Frame *frame = &trace.frames[index];
    fprintf(stderr, "FOO_ISSUE %s:%zu %s\n",
      frame->file ? frame->file : "<unknown>", frame->offset,
      frame->slot ? frame->slot : "<unknown>");
  }
}
