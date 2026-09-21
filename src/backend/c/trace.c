typedef struct { const char *slot; const char *file; size_t offset; } foo_frame;
static _Thread_local foo_frame foo_frames[64];
static _Thread_local size_t foo_depth;
static void foo_trace(const char *slot, const char *file, size_t offset) {
  /* Trace storage is bounded and must not allocate while propagating an error. */
  if (foo_depth < 64) foo_frames[foo_depth++] = (foo_frame){slot, file, offset};
}
