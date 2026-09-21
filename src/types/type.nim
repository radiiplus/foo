import std/tables
import std/strutils
import ../sema/bindings

type
  Type* = ref object
    kind*: string
    name*: string
    width*: int
    elem*: Type
    constant*: bool
    fields*: OrderedTable[string, Type]
    variants*: OrderedTable[string, Type]
    params*: seq[Type]
    ret*: Type
    abi*: string
    arguments*: seq[Type]
    length*: int
    layout*: string
    value*: string
    borrows*: seq[int]
    generics*: seq[string]
    constraints*: seq[tuple[subject: string, trait: string]]

proc typeToString*(value: Type): string =
  if value == nil: return "unknown"
  case value.kind
  of "primitive": return if value.width > 0: value.name & " " & $value.width else: value.name
  of "array": return "array of " & typeToString(value.elem)
  of "sequence": return "sequence of " & (if value.constant: "constant " else: "") & typeToString(value.elem)
  of "optional": return "optional " & typeToString(value.elem)
  of "error": return "fallible " & typeToString(value.elem)
  of "pointer": return "pointer to " & typeToString(value.elem)
  of "named", "record", "choice", "union", "opaque": return value.name
  of "vector": return "vector[" & $value.length & ", " & typeToString(value.elem) & "]"
  of "function":
    var params: seq[string]
    for parameter in value.params: params.add(typeToString(parameter))
    return "function(" & params.join(", ") & ") -> " & typeToString(value.ret) & (if value.abi.len > 0: " for " & provider(value.abi) else: "")
  of "literal": return "literal " & value.value
  else: return "unknown"

proc typesEqual*(left, right: Type): bool =
  if left == nil or right == nil: return left == right
  if left.kind != right.kind: return false
  case left.kind
  of "primitive": left.name == right.name and (if left.width > 0: left.width else: 64) == (if right.width > 0: right.width else: 64)
  of "array", "optional", "error", "pointer": typesEqual(left.elem, right.elem)
  of "sequence": left.constant == right.constant and typesEqual(left.elem, right.elem)
  of "named", "record", "choice", "union", "opaque": left.name == right.name
  of "vector": left.length == right.length and typesEqual(left.elem, right.elem)
  of "function":
    if left.params.len != right.params.len or left.abi != right.abi or not typesEqual(left.ret, right.ret): false
    else:
      for index in 0 ..< left.params.len:
        if not typesEqual(left.params[index], right.params[index]): return false
      true
  of "literal": left.value == right.value
  of "unknown": true
  else: false
