## Runtime-only C adapters. No FOO function or control flow is emitted as C.
## Pointer arguments avoid importing Clang's aggregate procedure-call ABI.
import std/[sequtils, strutils, tables]
import ../../ir/[node, kind]
import ../../pkg/hash
import ../c/emitter as cTypes
import ../c/runtime as cRuntime
import ./layout

type Support* = object
  code*: string
  libraries*: seq[string]

const
  memoryCode = staticRead("../c/memory.c")
  traceCode = staticRead("../c/trace.c")
  copyCode = staticRead("../c/copy.c")

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

proc support*(module: Module; target: string): Support =
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
  runtimeExterns.add(Extern(name: "$llvm_anchor", abi: "runtime.testing", symbol: "expect",
    params: @[node.Type(kind: TypeKind.Bool)], ret: node.Type(kind: TypeKind.Void)))
  for external in module.externs:
    if not external.abi.startsWith("runtime"):
      raise newException(ValueError, "foreign ABI is not yet qualified: " & external.name)
    runtimeExterns.add(external)
  let generated = cRuntime.runtime(runtimeExterns, ctype, cTypes.name, target)
  result.libraries = generated.libraries
  for external in runtimeExterns:
    var params = @["void *out"]
    var args: seq[string]
    for index, t in external.params:
      params.add("const void *p" & $index)
      args.add("*(const " & ctype(t) & " *)p" & $index)
    let call = cTypes.name(external.name) & "(" & args.join(", ") & ")"
    adapters.add("void " & bridgeName(external.name) & "(" & params.join(", ") & ") { " &
      (if external.ret == nil or external.ret.kind == TypeKind.Void:
        "(void)out; " & call & ";" else: "*(" & ctype(external.ret) & " *)out = " & call & ";") & " }")
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
  result.code = """
#include <stdint.h>
#include <stddef.h>
#include <stdbool.h>
#include <stdatomic.h>
#include <limits.h>
#include <stdlib.h>
#include <stdio.h>
#include <string.h>
typedef unsigned __int128 foo_u128;
typedef __int128 foo_i128;
static _Noreturn void foo_panic(const char *message) { fprintf(stderr, "%s\n", message); exit(1); }
""" & memoryCode & "\n" & traceCode & "\n" & copyCode & "\n" & types.declarations.join("\n") & "\n" &
    checks.join("\n") & "\n" & generated.code & "\n" & adapters.join("\n") & "\n" &
    prototypes.join("\n") & "\n" & comparisonCode.join("\n") & "\n" & exports.join("\n") & "\n" & """
void foo_llvm_panic(const char *message) { foo_panic(message); }
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
