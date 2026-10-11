## Hosted support only. FOO functions and control flow are emitted by emitter.nim.
import std/[strutils, sets, tables]
import ../../ir/[node, kind]
import ../c/emitter as cTypes
import ../c/runtime as cRuntime
import ./layout

type Support* = ref object
  types: cTypes.Types
  comparisons: cTypes.ComparisonSupport
  assertions: seq[string]
  checked: HashSet[string]
  libraries*: seq[string]

const
  memoryCode = staticRead("../c/memory.c")
  traceCode = staticRead("../c/trace.c")
  copyCode = staticRead("../c/copy.c")
  wideCode = staticRead("../native/wide.c")

proc bridgeName*(external: Extern): string = "llvm_" & cTypes.name(external.name)
proc newSupport*(): Support =
  result = Support(types: cTypes.newTypes())
  result.comparisons = cTypes.newComparisonSupport(result.types)

proc ctype(s: Support; t: node.Type): string =
  result = s.types.get(t)
  if t == nil or t.kind in {TypeKind.Void, TypeKind.Opaque} or result in s.checked: return
  s.checked.incl(result)
  let m = measure(t)
  s.assertions.add("_Static_assert(sizeof(" & result & ") == " & $m.size & " && _Alignof(" & result & ") == " & $m.alignment & ", \"FOO LLVM runtime layout mismatch\");")
  if t.kind in {TypeKind.Struct, TypeKind.ExternStruct}:
    for key, value in t.fields:
      discard s.ctype(value)
      s.assertions.add("_Static_assert(offsetof(" & result & ", " & cTypes.name(key) & ") == " & $m.offsets[fieldIndex(t,key)] & ", \"FOO LLVM field offset mismatch\");")

proc comparison*(s: Support; t: node.Type; operation: string): string =
  discard s.ctype(t)
  s.comparisons.comparison(t,operation)

proc code*(s: Support; module: Module): string =
  var externs = module.externs
  externs.add(Extern(name: "$llvm_anchor", abi: "runtime.testing", symbol: "expect",
    params: @[node.Type(kind: TypeKind.Bool)], ret: node.Type(kind: TypeKind.Void)))
  for external in externs:
    if not external.abi.startsWith("runtime"):
      raise newException(ValueError, "LLVM foreign ABI needs an ABI classifier: " & external.name)
    for parameter in external.params:
      if parameter.kind == TypeKind.Function:
        for argument in parameter.params & @[parameter.ret]:
          if aggregate(argument) or (argument != nil and argument.kind in {TypeKind.Int,TypeKind.Uint} and width(argument) > 64):
            raise newException(ValueError,"LLVM aggregate/wide runtime callback needs a foreign ABI thunk: " & external.name)
  let runtime = cRuntime.runtime(externs,
    proc(t: node.Type): string = s.ctype(t), cTypes.name)
  s.libraries = runtime.libraries
  var wrappers: seq[string]
  for external in module.externs:
    var parameters = @["void *out"]
    var arguments: seq[string]
    for index, typ in external.params:
      parameters.add("const void *p" & $index)
      arguments.add("*(const " & s.ctype(typ) & " *)p" & $index)
    let ret = s.ctype(external.ret)
    wrappers.add("void " & bridgeName(external) & "(" & parameters.join(", ") & ") { " &
      (if ret == "void": "(void)out; " else: "*(" & ret & " *)out = ") &
      cTypes.name(external.name) & "(" & arguments.join(", ") & "); }")
  result = "#include <stdint.h>\n#include <stddef.h>\n#include <stdbool.h>\n#include <stdatomic.h>\n#include <limits.h>\n#include <stdlib.h>\n#include <stdio.h>\n#include <string.h>\n" &
    "#include <malloc.h>\ntypedef __int128 foo_i128; typedef unsigned __int128 foo_u128;\n" &
    "#define FOO_SYSTEM\n#define FOO_STDCALL\n#define FOO_FASTCALL\n#define FOO_VECTORCALL\n#define FOO_THISCALL\n" &
    "static _Noreturn void foo_panic(const char *message) { fprintf(stderr, \"%s\\n\",message); exit(1); }\n" &
    memoryCode & "\n" & traceCode & "\n" & copyCode & "\n" &
    wideCode & "\n" & s.types.declarations.join("\n") & "\n" & s.assertions.join("\n") & "\n" & runtime.code & "\n" &
    s.comparisons.code() & "\n" & wrappers.join("\n") & "\n" & """
void foo_llvm_panic(const char *message) { foo_panic(message); }
void foo_llvm_trace(const char *slot, const char *file, uint64_t offset) { foo_trace(slot,file,(size_t)offset); }
void foo_llvm_init(int count, char **arguments) {
#ifdef FOO_SERVICE
foo_service_init(count,arguments);
#else
(void)count; (void)arguments;
#endif
}
void foo_llvm_finish(void) { foo_shutdown(); }
void foo_llvm_entry_error(const char *error) { fprintf(stderr,"%s\n",error); foo_shutdown(); exit(1); }
typedef struct llvm_scoped { void *data; struct llvm_scoped *next; } llvm_scoped;
void *foo_llvm_alloc(void *scope, uint64_t size, uint64_t alignment) {
  llvm_scoped **head = scope;
  llvm_scoped *entry = malloc(sizeof(*entry));
  if (!entry) foo_panic("OutOfMemory");
  void *p = _aligned_malloc(size ? (size_t)size : 1, (size_t)alignment);
  if (!p) { free(entry); foo_panic("OutOfMemory"); }
  entry->data = p; entry->next = *head; *head = entry;
  memset(p,0,size ? (size_t)size : 1); return p;
}
void foo_llvm_free(void *scope) {
  llvm_scoped **head = scope;
  while (*head) { llvm_scoped *entry = *head; *head = entry->next; _aligned_free(entry->data); free(entry); }
}
void *foo_llvm_reserve(void *region, uint64_t size) { return foo_reserve(region,(size_t)size); }
void foo_llvm_close(void *region) { foo_close(region); }
void foo_llvm_join(void *out, const void *left, const void *right) {
FOOText a,b; memcpy(&a,left,sizeof(a)); memcpy(&b,right,sizeof(b));
FOOText joined = foo_join(a,b); memcpy(out,&joined,sizeof(joined));
}
"""
