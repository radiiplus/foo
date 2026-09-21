#ifndef CPP_FILE_FLAG
#error "per-file C++ flags were not applied"
#endif

extern "C" int foo_cpp_gate(void) {
  return 13;
}
