## Public boundary version. Aggregate ABI is always pointer-marshalled.
import std/[strutils, tables, algorithm]
import ../../ir/[node, kind]
import ../../pkg/hash

const runtimeAbi* = "foo.runtime.pointer.v1"

proc convention*(abi: string): string =
  case abi.toLowerAscii()
  of "", "c", "runtime": ""
  of "system", "stdcall": "FOO_STDCALL "
  of "fastcall": "FOO_FASTCALL "
  of "vectorcall": "FOO_VECTORCALL "
  of "thiscall": "FOO_THISCALL "
  else: raise newException(ValueError, "Unqualified foreign calling convention: " & abi)

proc gateName*(name: string): string = "foo_llvm_gate_" & name.toHex()
proc callbackName*(name: string): string = "foo_llvm_callback_" & name.toHex()

proc signature(t: node.Type, ancestors: seq[node.Type] = @[]): string =
  if t == nil: return "void"
  for index, ancestor in ancestors:
    if cast[pointer](ancestor) == cast[pointer](t): return "recursive:" & $index
  let path = ancestors & @[t]
  result = $t.kind & ":" & $t.width & ":" & $t.constant & ":" & $t.volatile & ":" & t.abi.toHex()
  let attributes = t.attributes.sorted()
  for attribute in attributes: result.add("attr:" & attribute.toHex() & ";")
  if t.elem != nil: result.add("[" & signature(t.elem, path) & "]")
  for field, member in t.fields:
    result.add("field:" & field.toHex() & "=" & signature(member, path) & ";")
    let attrs = t.fieldAttrs.getOrDefault(field).sorted()
    for attribute in attrs: result.add("fieldattr:" & attribute.toHex() & ";")
  for variant, member in t.variants:
    result.add("variant:" & variant.toHex() & "=" & signature(member, path) & ";")
  for parameter in t.params: result.add("(" & signature(parameter, path) & ")")
  if t.ret != nil: result.add("->" & signature(t.ret, path))

proc indirectName*(t: node.Type): string =
  if t == nil or t.kind != TypeKind.Function:
    raise newException(ValueError, "Indirect foreign call requires a function type")
  "foo_llvm_indirect_" & sha256Hex(signature(t))[0..<24]
