## Hosted support only. FOO functions and control flow are emitted by emitter.nim.
import std/[strutils, sets, tables]
import ../../ir/[node, kind]
import ../c/emitter as cTypes
import ../c/runtime as cRuntime
import ./layout
import ./abi

type Support* = ref object
  types: cTypes.Types
  comparisons: cTypes.ComparisonSupport
  assertions: seq[string]
  checked: HashSet[string]
  hasComparisons: bool
  libraries*: seq[string]

const
  memoryCode = staticRead("../c/memory.c")
  traceCode = staticRead("../c/trace.c")
  copyCode = staticRead("../c/copy.c")
  ioCode = staticRead("io.c")
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
  s.hasComparisons = true
  discard s.ctype(t)
  s.comparisons.comparison(t,operation)

proc code*(s: Support; module: Module; target = ""; hosted = true): string =
  var adapters: seq[string]
  if target.contains("linux"):
    for external in module.externs:
      if external.abi notin ["", "c", "system"] and not external.abi.startsWith("runtime"):
        raise newException(ValueError, "Linux foreign convention is qualified only for c/system: " & external.name & " uses " & external.abi)
    for fn in module.funcs:
      if fn.abi notin ["", "foo", "foo:1", "c", "system"]:
        raise newException(ValueError, "Linux export convention is qualified only for c/system: " & fn.name & " uses " & fn.abi)
  proc ctype(t: node.Type): string = s.ctype(t)
  var runtimeExterns: seq[Extern]
  # Force the common allocation/text runtime even for an otherwise pure module.
  if hosted:
    runtimeExterns.add(Extern(name: "$llvm_anchor", abi: "runtime.testing", symbol: "expect",
      params: @[node.Type(kind: TypeKind.Bool)], ret: node.Type(kind: TypeKind.Void)))
  var foreignDeclarations: seq[string]
  for external in module.externs:
    if external.abi.startsWith("runtime"):
      if not hosted: raise newException(ValueError, "runtime none cannot call hosted provider " & external.abi & " at " & external.name)
      runtimeExterns.add(external)
    else:
      var parameters: seq[string]
      for t in external.params: parameters.add(ctype(t))
      foreignDeclarations.add("extern " & ctype(external.ret) & " " & convention(external.abi) &
        cTypes.symbol(if external.symbol.len > 0: external.symbol else: external.name) &
        "(" & (if parameters.len == 0: "void" else: parameters.join(", ")) & ");")
  let generated = cRuntime.runtime(runtimeExterns, ctype, cTypes.name, target)
  s.libraries = generated.libraries
  var boundaries = module.externs
  if hosted: boundaries.add(runtimeExterns[0])
  for external in boundaries:
    var params = @["void *out"]
    var args: seq[string]
    for index, t in external.params:
      params.add("const void *p" & $index)
      args.add("*(const " & ctype(t) & " *)p" & $index)
    let target = if external.abi.startsWith("runtime"): cTypes.name(external.name)
      else: cTypes.symbol(if external.symbol.len > 0: external.symbol else: external.name)
    let call = target & "(" & args.join(", ") & ")"
    adapters.add("void " & bridgeName(external) & "(" & params.join(", ") & ") { " &
      (if external.ret == nil or external.ret.kind == TypeKind.Void:
        "(void)out; " & call & ";" else: "*(" & ctype(external.ret) & " *)out = " & call & ";") & " }")
    if external.name != "$llvm_anchor":
      var typedParameters, typedArguments: seq[string]
      for index, parameter in external.params:
        typedParameters.add(ctype(parameter) & " p" & $index)
        typedArguments.add("p" & $index)
      let nativeCall = target & "(" & typedArguments.join(", ") & ")"
      adapters.add(ctype(external.ret) & " " & (if external.abi.startsWith("runtime"): "" else: convention(external.abi)) &
        callbackName(external.name) & "(" & (if typedParameters.len == 0: "void" else: typedParameters.join(", ")) & ") { " &
        (if external.ret == nil or external.ret.kind == TypeKind.Void: nativeCall & ";" else: "return " & nativeCall & ";") & " }")
  # C owns the native calling convention; language bodies remain LLVM IR.
  # The reciprocal gate avoids guessing Clang's aggregate return convention.
  for fn in module.funcs:
    if "naked" in fn.attributes or "interrupt" in fn.attributes or "start" in fn.attributes: continue
    var pointers = @["void *out"]
    var parameters, args: seq[string]
    for index, parameter in fn.params:
      pointers.add("const void *p" & $index)
      if parameter.type.kind == TypeKind.Void:
        args.add("NULL")
        continue
      parameters.add(ctype(parameter.type) & " p" & $index)
      args.add("&p" & $index)
    foreignDeclarations.add("extern void " & gateName(fn.name) & "(" & pointers.join(", ") & ");")
    let returns = fn.ret != nil and fn.ret.kind != TypeKind.Void
    let call = gateName(fn.name) & "(" & (if returns: "&result" else: "NULL") &
      (if args.len > 0: ", " & args.join(", ") else: "") & ");"
    let body = (if returns: ctype(fn.ret) & " result; " else: "") & call &
      (if returns: " return result;" else: "")
    let params = if parameters.len == 0: "void" else: parameters.join(", ")
    adapters.add(ctype(fn.ret) & " " & convention(if fn.abi in ["foo", "foo:1"]: "" else: fn.abi) & callbackName(fn.name) & "(" & params & ") { " & body & " }")
    if fn.abi notin ["", "foo", "foo:1"]:
      adapters.add((if fn.public: "FOO_LLVM_EXPORT " else: "") & ctype(fn.ret) & " " &
        convention(if fn.abi in ["foo", "foo:1"]: "" else: fn.abi) & cTypes.symbol(fn.name) & "(" & params & ") { " & body & " }")
  var indirects = initTable[string, bool]()
  proc indirect(i: Instruction) =
    if i == nil: return
    if i.kind in {InstrKind.Call, InstrKind.Thread} and i.callee.type != nil:
      let t = i.callee.type
      let name = indirectName(t)
      if not indirects.hasKey(name):
        indirects[name] = true
        var params = @["void *out", "void *callee"]
        var args: seq[string]
        for index, parameter in t.params:
          params.add("const void *p" & $index)
          args.add("*(const " & ctype(parameter) & " *)p" & $index)
        let call = "((" & ctype(t) & ")callee)(" & args.join(", ") & ")"
        adapters.add("void " & name & "(" & params.join(", ") & ") { " &
          (if t.ret == nil or t.ret.kind == TypeKind.Void: "(void)out; " & call & ";"
           else: "*(" & ctype(t.ret) & " *)out = " & call & ";") & " }")
    if i.fallback != nil:
      for child in i.fallback.instrs: indirect(child)
      indirect(i.fallback.term)
  for fn in module.funcs:
    for b in fn.blocks:
      for i in b.instrs: indirect(i)
      indirect(b.term)
  if not hosted:
    if s.hasComparisons:
      raise newException(ValueError, "runtime none aggregate comparison needs hosted comparison support")
    return "#include <stdint.h>\n#include <stddef.h>\n#include <stdbool.h>\n" &
      "#if defined(_WIN32)\n#define FOO_SYSTEM __stdcall\n#else\n#define FOO_SYSTEM\n#endif\n#define FOO_STDCALL __stdcall\n#define FOO_FASTCALL __fastcall\n#define FOO_VECTORCALL __vectorcall\n#define FOO_THISCALL __thiscall\n" &
      "typedef __int128 foo_i128; typedef unsigned __int128 foo_u128;\n" &
      s.types.declarations.join("\n") & "\n" & s.assertions.join("\n") & "\n" &
      foreignDeclarations.join("\n") & "\n" & adapters.join("\n")
  let platform = "#if defined(_WIN32)\n#define FOO_LLVM_EXPORT __declspec(dllexport)\n#else\n#define FOO_LLVM_EXPORT __attribute__((visibility(\"default\")))\n#define _aligned_malloc(size, alignment) aligned_alloc(alignment, ((size) + (alignment) - 1) / (alignment) * (alignment))\n#define _aligned_free free\n#endif\n"
  result = "#define _GNU_SOURCE\n#include <stdint.h>\n#include <stddef.h>\n#include <stdbool.h>\n#include <stdatomic.h>\n#include <limits.h>\n#include <stdlib.h>\n#include <stdio.h>\n#include <string.h>\n" & platform &
    "#include <malloc.h>\ntypedef __int128 foo_i128; typedef unsigned __int128 foo_u128;\n" &
    "#if defined(_WIN32)\n#define FOO_SYSTEM __stdcall\n#else\n#define FOO_SYSTEM\n#endif\n#define FOO_STDCALL __stdcall\n#define FOO_FASTCALL __fastcall\n#define FOO_VECTORCALL __vectorcall\n#define FOO_THISCALL __thiscall\n" &
    "static _Noreturn void foo_panic(const char *message) { fprintf(stderr, \"%s\\n\",message); exit(1); }\n" &
    memoryCode & "\n" & traceCode & "\n" & copyCode & "\n" &
    ioCode & "\n" & wideCode & "\n" & s.types.declarations.join("\n") & "\n" & s.assertions.join("\n") & "\n" & generated.code & "\n" &
    s.comparisons.code() & "\n" & foreignDeclarations.join("\n") & "\n" & adapters.join("\n") & "\n" & """
void foo_llvm_panic(const char *message) { foo_panic(message); }
void foo_llvm_trace(const char *slot, const char *file, uint64_t offset) { foo_trace(slot,file,(size_t)offset); }
void foo_llvm_init(int count, char **arguments) {
foo_llvm_io_probe();
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
