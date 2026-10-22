import std/tables
import std/strutils
import ./kind

type
  `Type`* = ref object
    kind*: Shape
    name*: string
    elem*: `Type`
    width*: int
    fields*: OrderedTable[string, `Type`]
    annotations*: Table[string, seq[string]]
    variants*: OrderedTable[string, `Type`]
    params*: seq[`Type`]
    ret*: `Type`
    abi*: string
    attributes*: seq[string]
    volatile*: bool
    constant*: bool

  Value* = object
    kind*: Flavor
    name*: string
    `type`*: `Type`
    bits*: string

  Memory* = object
    input*: string
    output*: string

  Location* = object
    file*: string
    start*: int
    `end`*: int

  Instruction* = ref object
    memory*: Memory
    positive*: seq[Value]
    negative*: seq[Value]
    op*: string
    field*: string
    panic*: string
    trace*: string
    effects*: seq[string]
    span*: Location
    error*: bool
    fallback*: Block
    fallbackBlocks*: seq[Block]
    symbol*: string
    kind*: Opcode
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
    yes*: string
    no*: string
    value*: Value
    blocks*: seq[tuple[label: string, value: Value]]
    msg*: string
    expr*: Value
    handler*: string
    path*: string
    argument*: `Type`
    evaluation*: string
    arguments*: seq[`Type`]
    mask*: seq[int]
    reduction*: string
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
    generics*: seq[string]
    params*: seq[Value]
    ret*: `Type`
    blocks*: seq[Block]
    derives*: seq[string]

  Extern* = object
    generics*: seq[string]
    symbol*: string
    name*: string
    params*: seq[`Type`]
    ret*: `Type`
    abi*: string

  Definition* = object
    name*: string
    `type`*: `Type`

  Storage* = object
    name*: string
    value*: Value
    public*: bool
    thread*: bool
    alignment*: int
    section*: string

  Region* = object
    id*: string
    kind*: string
    parent*: string
    owner*: string

  Trace* = object
    id*: string
    `function`*: string

  Contract* = object
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

  Optimization* = object
    generics*: int
    expressions*: int
    functions*: int
    dead*: int
    inlined*: int
    callbacks*: int
    boundaries*: int
    allocations*: int
    pipelines*: int
    continuations*: int
    serializations*: int
    vectors*: int
    bounds*: int

  Module* = ref object
    inputs*: seq[tuple[path, sha256: string]]
    storage*: seq[Storage]
    version*: int
    stage*: string
    package*: string
    path*: string
    target*: Table[string, string]
    requires*: string
    regions*: seq[Region]
    traces*: seq[Trace]
    native*: seq[Contract]
    residue*: seq[Residue]
    optimization*: Optimization
    name*: string
    funcs*: seq[Function]
    externs*: seq[Extern]
    types*: seq[Definition]

proc label*(value: `Type`): string =
  if value == nil: return "type"
  if value.name.len > 0: return value.name
  case value.kind
  of Shape.Slice:
    if value.constant and value.elem != nil and value.elem.kind == Shape.Uint and value.elem.width == 8: return "text"
    return "sequence of " & label(value.elem)
  of Shape.Ptr: return "pointer to " & label(value.elem)
  of Shape.Optional: return "optional " & label(value.elem)
  of Shape.Failable: return "failable " & label(value.elem)
  else: discard
  let name = case value.kind
    of Shape.Int: "integer"
    of Shape.Uint: "unsigned"
    of Shape.Float: "decimal"
    of Shape.Bool: "boolean"
    of Shape.Void: "nothing"
    of Shape.Struct: "record"
    of Shape.TaggedUnion: "choice"
    of Shape.Error: "Error"
    of Shape.Function: "function"
    of Shape.Vector: "vector"
    of Shape.PackedStruct: "packed"
    of Shape.ExternUnion: "union"
    of Shape.Opaque: "opaque"
    of Shape.Array: "sequence"
    else: "type"
  if value.width > 0 and value.width != 64 and
      value.kind in {Shape.Int, Shape.Uint, Shape.Float}:
    name & " " & $value.width
  else:
    name

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
