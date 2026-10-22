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
    releases*: seq[int]
    generics*: seq[string]
    constraints*: seq[tuple[subject: string, trait: string]]
    labels*: seq[string]
    defaults*: seq[bool]
    variadic*: bool

proc label*(value: Type): string =
  if value == nil: return "unknown"
  case value.kind
  of "primitive":
    return if value.width > 0 and value.width != 64:
      value.name & " " & $value.width else: value.name
  of "array": return "array of " & label(value.elem)
  of "sequence": return "sequence of " & (if value.constant: "constant " else: "") & label(value.elem)
  of "optional": return "optional " & label(value.elem)
  of "error": return "failable " & label(value.elem)
  of "pointer": return "pointer to " & label(value.elem)
  of "named", "record", "choice", "union", "opaque": return value.name
  of "vector": return "vector[" & $value.length & ", " & label(value.elem) & "]"
  of "function":
    var params: seq[string]
    for parameter in value.params: params.add(label(parameter))
    return "function(" & params.join(", ") & ") -> " & label(value.ret) & (if value.abi.len > 0: " for " & provider(value.abi) else: "")
  of "literal": return "literal " & value.value
  else: return "unknown"

proc equal*(left, right: Type): bool =
  if left == nil or right == nil: return left == right
  if left.kind != right.kind: return false
  case left.kind
  of "primitive": left.name == right.name and (if left.width > 0: left.width else: 64) == (if right.width > 0: right.width else: 64)
  of "array", "optional", "error", "pointer": equal(left.elem, right.elem)
  of "sequence": left.constant == right.constant and equal(left.elem, right.elem)
  of "named", "record", "choice", "union", "opaque": left.name == right.name
  of "vector": left.length == right.length and equal(left.elem, right.elem)
  of "function":
    if left.params.len != right.params.len or left.abi != right.abi or
        left.borrows != right.borrows or left.releases != right.releases or
        not equal(left.ret, right.ret): false
    else:
      for index in 0 ..< left.params.len:
        if not equal(left.params[index], right.params[index]): return false
      true
  of "literal": left.value == right.value
  of "unknown": true
  else: false
