## Runtime-only C adapters. No FOO function or control flow is emitted as C.
## Pointer arguments avoid importing Clang's aggregate procedure-call ABI.
import std/[strutils, tables]
import ../../ir/[node, kind]
import ../../pkg/hash
import ../c/emitter as cTypes
import ../c/runtime as cRuntime
import ./layout
import ./abi

type Support* = object
  code*: string
  libraries*: seq[string]

const
  memoryCode = staticRead("../c/memory.c")
  traceCode = staticRead("../c/trace.c")
  copyCode = staticRead("../c/copy.c")
  ioCode = staticRead("io.c")

proc bridgeName*(name: string): string = "llvm_" & cTypes.name(name)

proc typeIdentity(t: node.Type; active: var seq[pointer]): string =
  if t == nil: return "void"
  if cast[pointer](t) in active: return t.name
  active.add(cast[pointer](t))
  result = $t.kind & ":" & t.name & ":" & $t.width & ":" & $t.constant & ":" & t.abi
  result.add("(" & typeIdentity(t.elem, active) & ")")
  for name, field in t.fields: result.add(name & "=" & typeIdentity(field, active) & ";")
  for name, field in t.variants: result.add(name & "=" & typeIdentity(field, active) & ";")
  discard active.pop()

proc comparisonName*(t: node.Type; relation: string): string =
  var active: seq[pointer]
  "foo_llvm_compare_" & sha256Hex(typeIdentity(t, active) & relation)[0..<24]

proc support*(module: Module; target: string; hosted = true): Support =
  let types = cTypes.newTypes()
  var checks, adapters: seq[string]
  proc ctype(t: node.Type): string =
    let printed = types.get(t)
    if t != nil and t.kind notin {TypeKind.Void, TypeKind.Opaque}:
      let measured = measure(t)
      let check = "_Static_assert(sizeof(" & printed & ") == " & $measured.size &
        " && _Alignof(" & printed & ") == " & $measured.alignment &
        ", \"FOO LLVM runtime layout mismatch\");"
      if check notin checks: checks.add(check)
      if t.kind in {TypeKind.Struct, TypeKind.ExternStruct}:
        var index = 0
        for field in t.fields.keys:
          checks.add("_Static_assert(offsetof(" & printed & ", " & cTypes.name(field) &
            ") == " & $measured.offsets[index] & ", \"FOO LLVM field offset mismatch\");")
          inc index
    printed
  for declaration in module.types: discard ctype(declaration.type)
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
  result.libraries = generated.libraries
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
    adapters.add("void " & bridgeName(external.name) & "(" & params.join(", ") & ") { " &
      (if external.ret == nil or external.ret.kind == TypeKind.Void:
        "(void)out; " & call & ";" else: "*(" & ctype(external.ret) & " *)out = " & call & ";") & " }")
  # C owns the native calling convention; language bodies remain LLVM IR.
  # The reciprocal gate avoids guessing Clang's aggregate return convention.
  for fn in module.funcs:
    if "naked" in fn.attributes or "interrupt" in fn.attributes or "start" in fn.attributes: continue
    var pointers = @["void *out"]
    var parameters, args: seq[string]
    for index, parameter in fn.params:
      pointers.add("const void *p" & $index)
      parameters.add(ctype(parameter.type) & " p" & $index)
      args.add("&p" & $index)
    foreignDeclarations.add("extern void " & gateName(fn.name) & "(" & pointers.join(", ") & ");")
    let returns = fn.ret != nil and fn.ret.kind != TypeKind.Void
    let call = gateName(fn.name) & "(" & (if returns: "&result" else: "NULL") &
      (if args.len > 0: ", " & args.join(", ") else: "") & ");"
    let body = (if returns: ctype(fn.ret) & " result; " else: "") & call &
      (if returns: " return result;" else: "")
    let params = if parameters.len == 0: "void" else: parameters.join(", ")
    adapters.add(ctype(fn.ret) & " " & convention(fn.abi) & callbackName(fn.name) & "(" & params & ") { " & body & " }")
    if fn.abi.len > 0:
      adapters.add((if fn.public: "__declspec(dllexport) " else: "") & ctype(fn.ret) & " " &
        convention(fn.abi) & cTypes.symbol(fn.name) & "(" & params & ") { " & body & " }")
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
  var comparisons: Table[string, string]
  proc comparator(t: node.Type; relation: string): string =
    result = comparisonName(t, relation)
    if comparisons.hasKey(result): return
    comparisons[result] = "" # recursive type guard
    let typ = ctype(t)
    proc call(field: node.Type; left, right, op: string): string =
      let helper = comparator(field, op)
      helper & "(&(" & left & "), &(" & right & "))"
    var expression: string
    let equal = relation in ["equals", "does not equal"]
    if not aggregate(t):
      let ops = {"equals": "==", "does not equal": "!=", "is less than": "<",
        "is greater than": ">", "is at most": "<=", "is at least": ">="}.toTable
      expression = "*a " & ops[relation] & " *b"
    elif t.kind == TypeKind.Optional:
      if equal: expression = "a->present == b->present && (!a->present || " & call(t.elem, "a->value", "b->value", "equals") & ")"
      else:
        let tagOp = if relation in ["is less than", "is at most"]: "<" else: ">"
        expression = "a->present != b->present ? a->present " & tagOp & " b->present : (!a->present ? " &
          (if relation in ["is at most", "is at least"]: "1" else: "0") & " : " & call(t.elem, "a->value", "b->value", relation) & ")"
    elif t.kind == TypeKind.TaggedUnion:
      var cases: seq[string]
      var index = 0
      for field, member in t.variants:
        cases.add("case " & $index & ": return " & (if member == nil or member.kind == TypeKind.Void:
          (if equal or relation in ["is at most", "is at least"]: "1" else: "0") else:
          call(member, "a->payload." & cTypes.name(field), "b->payload." & cTypes.name(field), if equal: "equals" else: relation)) & ";")
        inc index
      let tagOp = if equal: "==" elif relation in ["is less than", "is at most"]: "<" else: ">"
      let prefix = "if (a->tag != b->tag) return " & (if equal: "0" else: "a->tag " & tagOp & " b->tag") & "; switch (a->tag) { " & cases.join(" ") & " default: return 0; }"
      comparisons[result] = "static uint8_t " & result & "(const " & typ & " *a, const " & typ & " *b) { " & prefix & " }"
      return
    elif t.kind in {TypeKind.Array, TypeKind.Vector, TypeKind.Slice}:
      let countA = if t.kind == TypeKind.Slice: "a->len" else: $t.width
      let countB = if t.kind == TypeKind.Slice: "b->len" else: $t.width
      let data = if t.kind == TypeKind.Slice: "data" else: "lane"
      let left = "a->" & data & "[k]"; let right = "b->" & data & "[k]"
      var body = "for (size_t k = 0; k < " & countA & " && k < " & countB & "; k++) { if (!" & call(t.elem, left, right, "equals") & ") return " &
        (if equal: "0" else: call(t.elem, left, right, relation)) & "; } return "
      let op = if equal: "==" elif relation == "is less than": "<" elif relation == "is greater than": ">" elif relation == "is at most": "<=" else: ">="
      body.add(countA & " " & op & " " & countB & ";")
      comparisons[result] = "static uint8_t " & result & "(const " & typ & " *a, const " & typ & " *b) { " & body & " }"
      return
    elif t.kind in {TypeKind.Struct, TypeKind.ExternStruct}:
      var body: string
      for field, member in t.fields:
        let left = "a->" & cTypes.name(field); let right = "b->" & cTypes.name(field)
        body.add("if (!" & call(member, left, right, "equals") & ") return " & (if equal: "0" else: call(member, left, right, relation)) & "; ")
      body.add("return " & (if equal or relation in ["is at most", "is at least"]: "1" else: "0") & ";")
      comparisons[result] = "static uint8_t " & result & "(const " & typ & " *a, const " & typ & " *b) { " & body & " }"
      return
    else: raise newException(ValueError, "runtime comparison unsupported for " & t.label)
    comparisons[result] = "static uint8_t " & result & "(const " & typ & " *a, const " & typ & " *b) { return " & expression & "; }"
  var exports: seq[string]
  proc inspect(i: Instruction) =
    if i == nil: return
    if i.kind == InstrKind.Compare:
      let t = if i.val2.type.kind == TypeKind.Optional: i.val2.type else: i.val.type
      if aggregate(t):
        # Build ne by negating equality; absent/active payloads are inspected only.
        let relation = if i.op == "does not equal": "equals" else: i.op
        let helper = comparator(t, relation)
        let name = comparisonName(t, i.op)
        let exported = "uint8_t " & name & "(const void *a, const void *b) { return " &
          (if i.op == "does not equal": "!" else: "") & helper & "_impl(a, b); }"
        if exported notin exports: exports.add(exported)
    if i.fallback != nil:
      for child in i.fallback.instrs: inspect(child)
  for fn in module.funcs:
    for basicBlock in fn.blocks:
      for i in basicBlock.instrs: inspect(i)
      inspect(basicBlock.term)
  var comparisonCode, prototypes: seq[string]
  for name, body in comparisons:
    let implementation = body.replace(name & "(", name & "_impl(")
    comparisonCode.add(implementation)
    prototypes.add(implementation[0..<implementation.find(" {")] & ";")
  # Calls between comparator helpers refer to their private implementations.
  for index in 0..<comparisonCode.len:
    for name in comparisons.keys: comparisonCode[index] = comparisonCode[index].replace(name & "(", name & "_impl(")
  if not hosted:
    if comparisons.len > 0: raise newException(ValueError, "runtime none aggregate comparison is not qualified")
    result.code = """
#include <stdint.h>
#include <stddef.h>
#include <stdbool.h>
#define FOO_SYSTEM __stdcall
#define FOO_STDCALL __stdcall
#define FOO_FASTCALL __fastcall
#define FOO_VECTORCALL __vectorcall
#define FOO_THISCALL __thiscall
typedef unsigned __int128 foo_u128;
typedef __int128 foo_i128;
""" & types.declarations.join("\n") & "\n" & checks.join("\n") & "\n" &
      foreignDeclarations.join("\n") & "\n" & adapters.join("\n") & "\n"
    return
  result.code = """
#ifndef _GNU_SOURCE
#define _GNU_SOURCE
#endif
#include <stdint.h>
#include <stddef.h>
#include <stdbool.h>
#include <stdatomic.h>
#include <limits.h>
#include <stdlib.h>
#include <stdio.h>
#include <string.h>
#define FOO_STDCALL __stdcall
#define FOO_SYSTEM __stdcall
#define FOO_FASTCALL __fastcall
#define FOO_VECTORCALL __vectorcall
#define FOO_THISCALL __thiscall
typedef unsigned __int128 foo_u128;
typedef __int128 foo_i128;
static _Noreturn void foo_panic(const char *message) { fprintf(stderr, "%s\n", message); exit(1); }
""" & memoryCode & "\n" & traceCode & "\n" & copyCode & "\n" & ioCode & "\n" & types.declarations.join("\n") & "\n" &
    checks.join("\n") & "\n" & generated.code & "\n" & foreignDeclarations.join("\n") & "\n" & adapters.join("\n") & "\n" &
    prototypes.join("\n") & "\n" & comparisonCode.join("\n") & "\n" & exports.join("\n") & "\n" & """
void foo_llvm_panic(const char *message) { foo_panic(message); }
void foo_llvm_init(int argc, char **argv) {
  foo_llvm_io_probe();
#ifdef FOO_SERVICE
  foo_service_init(argc, argv);
#else
  (void)argc; (void)argv;
#endif
}
void foo_llvm_trace(const char *slot, const char *file, uint64_t offset) { foo_trace(slot, file, (size_t)offset); }
void foo_llvm_finish(const char *error) { if (error) fprintf(stderr, "%s\n", error); foo_shutdown(); }
void foo_llvm_close(void *region) { foo_close(region); }
void *foo_llvm_reserve(void *region, uint64_t size) { return foo_reserve(region, (size_t)size); }
void *foo_llvm_alloc(uint64_t size) { void *p = calloc(size ? size : 1, 1); if (!p) foo_panic("OutOfMemory"); return p; }
void foo_llvm_join(void *out, const void *left, const void *right) { *(FOOText *)out = foo_join(*(const FOOText *)left, *(const FOOText *)right); }
int foo_llvm_text_compare(const void *left, const void *right) {
  const FOOText *a = left, *b = right;
  size_t count = a->len < b->len ? a->len : b->len;
  int order = count ? memcmp(a->data, b->data, count) : 0;
  return order ? (order < 0 ? -1 : 1) : (a->len > b->len) - (a->len < b->len);
}
"""
