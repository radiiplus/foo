import std/[os, strutils]
import "../../src/interop/bind.nim" as binding
import ../../src/diag/engine
import ../../src/lex/lexer
import ../../src/ast/parser

let root = getTempDir() / "foo-interop-bind-test"
if dirExists(root): removeDir(root)
createDir(root)
let header = root / "foreign.h"
writeFile(header, "#define ANSWER 42\nint increment(int value);\nlong accumulate(long value);\nunsigned long read_size(size_t count);\n")
let options = Binding(cacheDir: root / "cache", target: "windows-x64")
let first = binding.`bind`(header, options)
doAssert not first.cached
doAssert first.source.contains("constant ANSWER is 42.")
doAssert first.source.contains("extern \"C\" function increment(value integer 32) giving integer 32")
doAssert first.source.contains("function accumulate(value integer 32) giving integer 32")
doAssert first.source.contains("function read_size(count unsigned) giving unsigned 32")
let diagnostics = engine()
diagnostics.source(first.source, first.bindingPath)
discard parser(lexer(first.source, diagnostics).lex(), diagnostics).parse()
doAssert not diagnostics.failed,
  if diagnostics.messages.len > 0: diagnostics.messages[0].text
  else: "generated binding did not parse"
let second = binding.`bind`(header, options)
doAssert second.cached
doAssert second.source == first.source
let linux = binding.`bind`(header,
  Binding(cacheDir: root / "cache", target: "linux-x64"))
doAssert not linux.cached and linux.bindingPath != first.bindingPath
doAssert linux.source.contains("function accumulate(value integer) giving integer")
doAssert linux.source.contains("function read_size(count unsigned) giving unsigned.")
let narrow = binding.`bind`(header,
  Binding(cacheDir: root / "cache", target: "wasm32-wasi"))
doAssert narrow.source.contains("function read_size(count unsigned 32) giving unsigned 32")
let sized = root / "sized.h"
writeFile(sized, "typedef size_t (*size_callback)(size_t count);\nsize_t length(size_t *values, size_t count);\nssize_t measure(ssize_t value);\nvoid apply(size_callback callback);\n")
let sized32 = binding.`bind`(sized,
  Binding(cacheDir: root / "cache", target: "wasm32-wasi"))
doAssert sized32.diagnostics.len == 0
doAssert sized32.source.contains("function length(values pointer to unsigned 32, count unsigned 32) giving unsigned 32")
doAssert sized32.source.contains("function measure(value integer 32) giving integer 32")
doAssert sized32.source.contains("function apply(callback function taking (unsigned 32) giving unsigned 32) giving nothing")
let sized64 = binding.`bind`(sized, options)
doAssert sized64.diagnostics.len == 0 and sized64.bindingPath != sized32.bindingPath
doAssert sized64.source.contains("function measure(value integer) giving integer")
let types = root / "types.h"
writeFile(types, "typedef uint32_t count_type;\ncount_type consume(int32_t values[4], intptr_t offset, uintptr_t limit, ptrdiff_t distance);\nint8_t widths(uint8_t a, int16_t b, uint16_t c, int64_t d, uint64_t e);\n")
let mapped = binding.`bind`(types, options)
doAssert mapped.diagnostics.len == 0
doAssert mapped.source.contains("function consume(values pointer to integer 32, offset integer, limit unsigned, distance integer) giving unsigned 32")
doAssert mapped.source.contains("function widths(a byte, b integer 16, c_c unsigned 16, d integer, e unsigned) giving integer 8")
let mapped32 = binding.`bind`(types,
  Binding(cacheDir: root / "cache", target: "wasm32-wasi"))
doAssert mapped32.source.contains("offset integer 32, limit unsigned 32, distance integer 32")
let preset32 = binding.`bind`(types,
  Binding(cacheDir: root / "cache", target: "wasm-freestanding"))
doAssert preset32.source.contains("offset integer 32, limit unsigned 32, distance integer 32")
createDir(root / "other")
let duplicate = root / "other" / "types.h"
writeFile(duplicate, readFile(types))
doAssert binding.`bind`(duplicate, options).bindingPath != mapped.bindingPath
let includes = root / "includes"
createDir(includes)
let nested = includes / "nested.h"
writeFile(nested, "#define EXTRA 7\ntypedef uint32_t extra_count;\n")
let outer = root / "outer.h"
writeFile(outer, "#include \"nested.h\"\nextra_count total(void);\n")
let includeOptions = Binding(cacheDir: root / "cache", target: "windows-x64",
  includes: @[includes])
let included = binding.`bind`(outer, includeOptions)
doAssert included.diagnostics.len == 0
doAssert included.source.contains("constant EXTRA is 7.")
doAssert included.source.contains("function total giving unsigned 32")
doAssert binding.`bind`(outer, includeOptions).cached
writeFile(nested, "#define EXTRA 8\ntypedef uint32_t extra_count;\n")
let refreshed = binding.`bind`(outer, includeOptions)
doAssert not refreshed.cached and refreshed.bindingPath != included.bindingPath
doAssert refreshed.source.contains("constant EXTRA is 8.")
writeFile(nested, "#include \"outer.h\"\n#define EXTRA 8\ntypedef uint32_t extra_count;\n")
doAssert binding.`bind`(outer, includeOptions).source.contains("function total giving unsigned 32")
let missing = root / "missing.h"
writeFile(missing, "#include \"arriving.h\"\n")
let absent = binding.`bind`(missing, includeOptions)
doAssert absent.diagnostics.len == 1 and absent.diagnostics[0].code == "C_HEADER"
writeFile(includes / "arriving.h", "#define ARRIVED 1\n")
let present = binding.`bind`(missing, includeOptions)
doAssert not present.cached and present.diagnostics.len == 0
doAssert present.source.contains("constant ARRIVED is 1.")
let unsupportedCall = root / "variadic.h"
writeFile(unsupportedCall, "int writef(const char *format, ...);\nint invoke(int (*callback)(int), int value);\n")
let unsupportedResult = binding.`bind`(unsupportedCall, options)
doAssert unsupportedResult.diagnostics.len == 1
doAssert not unsupportedResult.source.contains("function writef(")
doAssert unsupportedResult.source.contains("function invoke(callback function taking (integer 32) giving integer 32, value integer 32) giving integer 32")
let directIssues = engine()
directIssues.source(unsupportedResult.source, unsupportedResult.bindingPath)
discard parser(lexer(unsupportedResult.source, directIssues).lex(), directIssues).parse()
doAssert not directIssues.failed
let callbacks = root / "callbacks.h"
writeFile(callbacks, "typedef int (*native_callback)(int value);\nnative_callback obtain(void);\nvoid accept(native_callback callback);\n")
let callbackBinding = binding.`bind`(callbacks, options)
doAssert callbackBinding.diagnostics.len == 0
doAssert callbackBinding.source.contains("function obtain giving function taking (integer 32) giving integer 32")
doAssert callbackBinding.source.contains("function accept(callback function taking (integer 32) giving integer 32) giving nothing")
let callbackIssues = engine()
callbackIssues.source(callbackBinding.source, callbackBinding.bindingPath)
discard parser(lexer(callbackBinding.source, callbackIssues).lex(),
  callbackIssues).parse()
doAssert not callbackIssues.failed,
  if callbackIssues.messages.len > 0: callbackIssues.messages[0].text
  else: "callback binding did not parse"
let unsupported = root / "unsupported.h"
writeFile(unsupported, "struct Strange[4] unsupported(void);\n")
let initial = binding.`bind`(unsupported, options)
doAssert initial.diagnostics.len == 1 and
  initial.diagnostics[0].code == "C_UNBINDABLE"
let repeated = binding.`bind`(unsupported, options)
doAssert repeated.cached and repeated.diagnostics == initial.diagnostics
let cpp = root / "foreign.hpp"
writeFile(cpp, "extern \"C\" {\nlong boxed(long value);\n}\nextern \"C\" int direct(int value);\nint implicit(int value);\nextern \"C++\" int cpp(int value);\n")
let linked = binding.`bind`(cpp, options)
doAssert linked.source.contains("function boxed(value integer 32) giving integer 32")
doAssert linked.source.contains("function direct(value integer 32) giving integer 32")
doAssert not linked.source.contains("function cpp(")
doAssert not linked.source.contains("function implicit(")
doAssert linked.diagnostics.len == 2 and
  linked.diagnostics[0].message.contains("requires C linkage") and
  linked.diagnostics[1].message.contains("requires a C wrapper")

let conditionalInclude = root / "selected.h"
writeFile(conditionalInclude, "int selected(int value);\n")
let conditionalHeader = root / "conditional.h"
writeFile(conditionalHeader, """
#define ENABLED 1
#if 0
int inactive_zero(void);
#include "absent.h"
#endif
#if 1
int active_one(void);
#endif
#ifdef ENABLED
int defined_macro(void);
#endif
#ifndef MISSING
int undefined_macro(void);
#endif
#if 0
int inactive_first(void);
#elif ENABLED
int active_elif(void);
#endif
#if 0
int inactive_else(void);
#else
int active_else(void);
#endif
#if defined(ENABLED) && !defined(MISSING)
int combined_condition(void);
#endif
#undef ENABLED
#ifdef ENABLED
int inactive_undef(void);
#else
int active_undef(void);
#endif
#if __SIZEOF_POINTER__ == 8
long pointer64(long value);
#else
int pointer32(int value);
#endif
#if __SIZEOF_POINTER__ == 8
#include "selected.h"
#endif
""")
let selected = binding.`bind`(conditionalHeader, options)
doAssert selected.diagnostics.len == 0, $selected.diagnostics
for name in ["active_one", "defined_macro", "undefined_macro", "active_elif",
    "active_else", "combined_condition", "active_undef", "selected"]:
  doAssert selected.source.contains("function " & name), name
for name in ["inactive_zero", "inactive_first", "inactive_else", "inactive_undef"]:
  doAssert not selected.source.contains("function " & name), name
doAssert selected.source.contains("function pointer64(value integer 32) giving integer 32")
doAssert not selected.source.contains("function pointer32")
doAssert binding.`bind`(conditionalHeader, options).cached
let selectedWasm = binding.`bind`(conditionalHeader,
  Binding(cacheDir: root / "cache", target: "wasm-freestanding"))
doAssert selectedWasm.diagnostics.len == 0, $selectedWasm.diagnostics
doAssert selectedWasm.source.contains("function pointer32(value integer 32) giving integer 32")
doAssert not selectedWasm.source.contains("function pointer64")
doAssert not selectedWasm.source.contains("function selected")
writeFile(conditionalInclude, "int selected_again(int value);\n")
let changed = binding.`bind`(conditionalHeader, options)
doAssert not changed.cached and changed.bindingPath != selected.bindingPath
doAssert changed.source.contains("function selected_again")
doAssert not changed.source.contains("function selected(")
let conditionalIssues = engine()
conditionalIssues.source(changed.source, changed.bindingPath)
discard parser(lexer(changed.source, conditionalIssues).lex(),
  conditionalIssues).parse()
doAssert not conditionalIssues.failed
let conditionalCpp = root / "conditional.hpp"
writeFile(conditionalCpp, """
#ifdef SELECT_CPP
extern "C" int selected_cpp(int value);
#else
int inactive_cpp(int value);
#endif
""")
let selectedCpp = binding.`bind`(conditionalCpp,
  Binding(cacheDir: root / "cache", target: "windows-x64",
    flags: @["-DSELECT_CPP=1"]))
doAssert selectedCpp.diagnostics.len == 0, $selectedCpp.diagnostics
doAssert selectedCpp.source.contains("function selected_cpp(value integer 32) giving integer 32")
doAssert not selectedCpp.source.contains("function inactive_cpp")
let defaultCpp = binding.`bind`(conditionalCpp, options)
doAssert defaultCpp.bindingPath != selectedCpp.bindingPath
doAssert defaultCpp.diagnostics.len == 1
doAssert not defaultCpp.source.contains("function selected_cpp")

let sysroot = root / "target-sysroot"
createDir(sysroot)
createDir(sysroot / "usr")
createDir(sysroot / "usr" / "include")
let systemHeader = sysroot / "usr" / "include" / "target_api.h"
writeFile(systemHeader, "int target_api(int value);\n")
let sysrootHeader = root / "sysroot.h"
writeFile(sysrootHeader, "#include <target_api.h>\n")
let sysrootOptions = Binding(cacheDir: root / "cache", target: "linux-x64",
  sysroot: sysroot)
let boundSysroot = binding.`bind`(sysrootHeader, sysrootOptions)
doAssert boundSysroot.diagnostics.len == 0, $boundSysroot.diagnostics
doAssert boundSysroot.source.contains("function target_api(value integer 32) giving integer 32")
doAssert binding.`bind`(sysrootHeader, sysrootOptions).cached
writeFile(systemHeader, "int updated_api(int value);\n")
let changedSysroot = binding.`bind`(sysrootHeader, sysrootOptions)
doAssert not changedSysroot.cached and changedSysroot.bindingPath != boundSysroot.bindingPath
doAssert changedSysroot.source.contains("function updated_api(value integer 32) giving integer 32")
var missingTarget = false
try: discard binding.`bind`(sysrootHeader,
  Binding(cacheDir: root / "cache", sysroot: sysroot))
except ValueError as error: missingTarget = error.msg.contains("explicit target")
doAssert missingTarget
removeDir(root)
echo "interop bind parity: ok"
