## Public boundary version. Aggregate ABI is always pointer-marshalled.
import std/[strutils, tables]
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

proc signature(t: node.Type): string =
  if t == nil: return "void"
  result = $t.kind & ":" & $t.width & ":" & $t.constant & ":" & t.abi
  if t.elem != nil: result.add("[" & signature(t.elem) & "]")
  for field, member in t.fields: result.add(field & "=" & signature(member) & ";")
  for parameter in t.params: result.add("(" & signature(parameter) & ")")
  if t.ret != nil: result.add("->" & signature(t.ret))

proc indirectName*(t: node.Type): string =
  if t == nil or t.kind != TypeKind.Function:
    raise newException(ValueError, "Indirect foreign call requires a function type")
  "foo_llvm_indirect_" & sha256Hex(signature(t))[0..<24]
