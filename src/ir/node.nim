import std/tables
import std/strutils
import std/sets
import ./kind

type
  `Type`* = ref object
    kind*: TypeKind
    name*: string
    elem*: `Type`
    width*: int
    fields*: OrderedTable[string, `Type`]
    fieldAttrs*: Table[string, seq[string]]
    variants*: OrderedTable[string, `Type`]
    params*: seq[`Type`]
    ret*: `Type`
    abi*: string
    attributes*: seq[string]
    volatile*: bool
    constant*: bool

  Value* = object
    kind*: ValueKind
    name*: string
    `type`*: `Type`
    bits*: string

  Memory* = object
    input*: string
    output*: string

  SourceSpan* = object
    file*: string
    start*: int
    `end`*: int

  Instruction* = ref object
    memory*: Memory
    trueArgs*: seq[Value]
    falseArgs*: seq[Value]
    op*: string
    field*: string
    panic*: string
    trace*: string
    effects*: seq[string]
    span*: SourceSpan
    error*: bool
    fallback*: Block
    symbol*: string
    kind*: InstrKind
    dest*: Value
    region*: string
    target*: Value
    `ptr`*: Value
    val*: Value
    val2*: Value
    `func`*: string
    callee*: Value
    abi*: string
    attributes*: seq[string]
    args*: seq[Value]
    label*: string
    cond*: Value
    trueLabel*: string
    falseLabel*: string
    value*: Value
    blocks*: seq[tuple[label: string, value: Value]]
    msg*: string
    expr*: Value
    handler*: string
    path*: string
    typeArg*: `Type`
    evalBody*: string
    typeArgs*: seq[`Type`]
    mask*: seq[int]
    reduceOp*: string
    code*: string

  Block* = ref object
    params*: seq[Value]
    label*: string
    instrs*: seq[Instruction]
    term*: Instruction

  Function* = ref object
    public*: bool
    line*: int
    name*: string
    abi*: string
    attributes*: seq[string]
    typeParams*: seq[string]
    params*: seq[Value]
    ret*: `Type`
    blocks*: seq[Block]
    derives*: seq[string]

  Extern* = object
    typeParams*: seq[string]
    symbol*: string
    name*: string
    params*: seq[`Type`]
    ret*: `Type`
    abi*: string

  TypeDecl* = object
    name*: string
    `type`*: `Type`

  Storage* = object
    name*: string
    value*: Value
    public*: bool

  Region* = object
    id*: string
    kind*: string
    parent*: string
    owner*: string

  Trace* = object
    id*: string
    `function`*: string

  NativeContract* = object
    id*: string
    stage*: string
    code*: string
    abi*: string
    effects*: seq[string]

  Residue* = object
    id*: string
    operation*: string
    state*: string
    payload*: string

  Module* = ref object
    storage*: seq[Storage]
    version*: int
    stage*: string
    unitPackage*: string
    unitPath*: string
    target*: Table[string, string]
    requires*: string
    regions*: seq[Region]
    traces*: seq[Trace]
    native*: seq[NativeContract]
    residue*: seq[Residue]
    name*: string
    funcs*: seq[Function]
    externs*: seq[Extern]
    types*: seq[TypeDecl]

proc label*(value: `Type`): string =
  if value == nil: return "type"
  if value.name.len > 0: return value.name
  case value.kind
  of TypeKind.Slice:
    if value.constant and value.elem != nil and value.elem.kind == TypeKind.Uint and value.elem.width == 8: return "text"
    return "sequence of " & label(value.elem)
  of TypeKind.Ptr: return "pointer to " & label(value.elem)
  of TypeKind.Optional: return "optional " & label(value.elem)
  of TypeKind.Fallible: return "fallible " & label(value.elem)
  else: discard
  let name = case value.kind
    of TypeKind.Int: "integer"
    of TypeKind.Uint: "unsigned"
    of TypeKind.Float: "decimal"
    of TypeKind.Bool: "boolean"
    of TypeKind.Void: "nothing"
    of TypeKind.Struct: "record"
    of TypeKind.TaggedUnion: "choice"
    of TypeKind.Error: "Error"
    of TypeKind.Function: "function"
    of TypeKind.Vector: "vector"
    of TypeKind.PackedStruct: "packed"
    of TypeKind.ExternUnion: "union"
    of TypeKind.Opaque: "opaque"
    of TypeKind.Array: "sequence"
    else: "type"
  if value.width > 0 and value.kind in {TypeKind.Int, TypeKind.Uint, TypeKind.Float}: name & " " & $value.width else: name

proc bytes*(value: string): seq[byte] =
  if value.len < 2 or value[0] != '"' or value[^1] != '"': raise newException(ValueError, "Malformed IR text constant")
  var index = 1
  while index < value.len - 1:
    if value[index] != '\\': result.add(byte(value[index].ord)); inc index; continue
    inc index
    if value[index] == 'x' and index + 2 < value.len - 1:
      result.add(byte(parseHexInt(value[index + 1 .. index + 2]))); index += 3
    else:
      let escaped = value[index]
      case escaped
      of 'n': result.add(10'u8)
      of 'r': result.add(13'u8)
      of 't': result.add(9'u8)
      of '"': result.add(34'u8)
      of '\\': result.add(92'u8)
      of '0': result.add(0'u8)
      else: raise newException(ValueError, "Unsupported IR escape")
      inc index

proc quoted*(data: openArray[byte]): string =
  result = "\""
  for value in data:
    if value >= 32 and value <= 126 and value != 34 and value != 92: result.add(char(value))
    else: result.add("\\x" & toHex(value, 2).toLowerAscii)
  result.add('"')
