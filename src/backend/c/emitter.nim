import std/[json, os, sequtils, sets, strutils, tables]
import ../../ir/[kind, monomorph, node]
import ../substrate
import ./runtime

type
  Options* = object
    target*, cpu*, level*, mode*, substrate*, source*, runtime*, coverage*: string
    library*: bool

  Types* = ref object
    declarations*: seq[string]
    cache: Table[pointer, string]
    roots: seq[`Type`]
    shapes: Table[string, string]
    named: HashSet[string]

  EmitState = ref object
    types: Types
    options: Options
    selection: Selection
    strings, functions, prototypes: seq[string]
    comparisons, orders: Table[string, string]
    externs: Table[string, Extern]
    contracts: Table[string, NativeContract]
    called, referenced, storage, exported: HashSet[string]

  Cleanup = object
    bodyBlock: Block
    flag: string
    onError: bool

  FunctionState = ref object
    emitter: EmitState
    fn: Function
    resultType: `Type`
    returnType: string
    declarations, body, allocations, regions: seq[string]
    defined: HashSet[string]
    cleanups: seq[Cleanup]
    labels: Table[string, int]
    current: string
    counter: int

const
  memoryCode = staticRead("memory.c")
  traceCode = staticRead("trace.c")
  copyCode = staticRead("copy.c")

proc name*(value: string): string =
  result = "foo_symbol_"
  for character in value:
    if character.isAlphaNumeric: result.add(character)
    else: result.add("_" & toHex(ord(character), 1).toLowerAscii & "_")

proc symbol*(value: string): string =
  if value.len == 0 or not (value[0].isAlphaAscii or value[0] == '_') or
      value.anyIt(not (it.isAlphaNumeric or it == '_')):
    raise newException(ValueError, "C cannot bind symbol '" & value & "'")
  value

proc newTypes*(): Types =
  Types(cache: initTable[pointer, string](), shapes: initTable[string, string](),
    named: initHashSet[string]())

proc getImpl(types: Types; value: `Type`; ignoreAtomic: bool): string
proc get*(types: Types; value: `Type`): string = types.getImpl(value, false)

proc getImpl(types: Types; value: `Type`; ignoreAtomic: bool): string =
  if value == nil: return "void"
  if not ignoreAtomic and "atomic" in value.attributes:
    return "_Atomic(" & types.getImpl(value, true) & ")"
  let identity = cast[pointer](value)
  if not ignoreAtomic and types.cache.hasKey(identity): return types.cache[identity]
  case value.kind
  of TypeKind.Void: return "void"
  of TypeKind.Bool: return "bool"
  of TypeKind.Error: return "const char *"
  of TypeKind.Int, TypeKind.Uint:
    let width = if value.width > 0: value.width else: 32
    if width notin [8, 16, 32, 64]:
      raise newException(ValueError, "C backend needs a packed field for " & $width & "-bit integers")
    return (if value.kind == TypeKind.Uint: "u" else: "") & "int" & $width & "_t"
  of TypeKind.Float:
    let width = if value.width > 0: value.width else: 64
    if width notin [32, 64]:
      raise newException(ValueError, "C backend does not support f" & $width)
    return if width == 32: "float" else: "double"
  of TypeKind.Ptr:
    return (if value.volatile: "volatile " else: "") & types.get(value.elem) & " *"
  else: discard

  if value.name.len > 0 and value.kind in {TypeKind.Struct, TypeKind.ExternStruct,
      TypeKind.ExternUnion, TypeKind.PackedStruct, TypeKind.TaggedUnion, TypeKind.Opaque}:
    let id = name(value.name)
    types.cache[identity] = id
    types.roots.add(value)
    if id in types.named: return id
    types.named.incl(id)
    let tag = if value.kind == TypeKind.ExternUnion: "union" else: "struct"
    types.declarations.add("typedef " & tag & " " & id & " " & id & ";")
    if value.kind == TypeKind.Opaque: return id
    var body = ""
    if value.kind == TypeKind.PackedStruct:
      var bits = value.width
      if bits <= 0:
        for field in value.fields.values:
          if field.kind notin {TypeKind.Int, TypeKind.Uint, TypeKind.Bool}:
            raise newException(ValueError, "C packed fields must be integers or booleans")
          bits += (if field.kind == TypeKind.Bool: 1 else: (if field.width > 0: field.width else: 32))
      if bits < 1 or bits > 64:
        raise newException(ValueError, "C packed records currently support backing widths from 1 through 64 bits")
      let width = if bits <= 8: 8 elif bits <= 16: 16 elif bits <= 32: 32 else: 64
      body = "_Alignas(uint" & $width & "_t) uint8_t bytes[" & $(width div 8) & "];"
    elif value.kind == TypeKind.TaggedUnion:
      var fields: seq[string]
      for fieldName, fieldType in value.variants:
        if fieldType != nil and fieldType.kind != TypeKind.Void:
          fields.add(types.get(fieldType) & " " & name(fieldName) & ";")
      body = "uint32_t tag; union { " &
        (if fields.len > 0: fields.join(" ") else: "uint8_t empty;") & " } payload;"
    else:
      var fields: seq[string]
      for fieldName, fieldType in value.fields:
        fields.add(types.get(fieldType) & " " & name(fieldName) & ";")
      body = if fields.len > 0: fields.join(" ") else: "uint8_t empty;"
    types.declarations.add(tag & " " & id & " { " & body & " };")
    return id

  let elem = if value.elem != nil: types.get(value.elem) else: "void"
  var params: seq[string]
  for parameter in value.params: params.add(types.get(parameter))
  let ret = if value.ret != nil: types.get(value.ret) else: "void"
  let key = $value.kind & ":" & elem & ":" & $value.width & ":" & $value.constant &
    ":" & params.join(",") & ":" & ret & ":" & value.abi
  if types.shapes.hasKey(key): return types.shapes[key]
  let id = "foo_type_" & $types.shapes.len
  types.shapes[key] = id
  types.cache[identity] = id
  types.roots.add(value)
  case value.kind
  of TypeKind.Slice:
    types.declarations.add("typedef struct { " & (if value.constant: "const " else: "") &
      elem & " *data; size_t len; } " & id & ";")
  of TypeKind.Optional:
    types.declarations.add("typedef struct { bool present; " &
      (if elem == "void": "uint8_t" else: elem) & " value; } " & id & ";")
  of TypeKind.Fallible:
    types.declarations.add("typedef struct { const char *error; " &
      (if elem == "void": "uint8_t" else: elem) & " value; } " & id & ";")
  of TypeKind.Array, TypeKind.Vector:
    if value.width < 1:
      raise newException(ValueError, "C arrays and vectors need a positive constant size")
    types.declarations.add("typedef struct { " & elem & " lane[" & $value.width & "]; } " & id & ";")
  of TypeKind.Function:
    if value.abi.len > 0 and value.abi != "c" and value.abi != "runtime" and
        not value.abi.startsWith("runtime."):
      raise newException(ValueError, "Unsupported C calling convention '" & value.abi & "'")
    types.declarations.add("typedef " & ret & " (*" & id & ")(" &
      (if params.len > 0: params.join(", ") else: "void") & ");")
  else: raise newException(ValueError, "C backend cannot represent " & $value.kind)
  id

proc literal(data: openArray[byte]): string =
  result = "\""
  for value in data: result.add("\\" & toOct(int(value), 3))
  result.add('"')

proc literal(value: string): string =
  if value.len == 0: return "\"\""
  literal(value.toOpenArrayByte(0, value.high))

proc functionName(state: EmitState; value: string): string =
  if value in state.exported: symbol(value) else: name(value)

proc value(state: EmitState; item: Value): string =
  discard state.types.get(item.type)
  case item.kind
  of ValueKind.Reg: return name(item.name)
  of ValueKind.Global:
    if item.name in state.storage: return "&" & name(item.name)
    state.called.incl(item.name)
    if state.externs.hasKey(item.name):
      let external = state.externs[item.name]
      if not external.abi.startsWith("runtime"):
        return symbol(if external.symbol.len > 0: external.symbol else: external.name)
    return state.functionName(item.name)
  of ValueKind.Const: discard
  if item.type != nil and item.type.kind == TypeKind.Float and item.bits.len > 0:
    let width = if item.type.width > 0: item.type.width else: 64
    return "foo_f" & $width & "(UINT" & $width & "_C(0x" & item.bits & "))"
  if item.type != nil and item.type.kind == TypeKind.Error: return literal(item.name)
  if item.type != nil and item.type.kind == TypeKind.Slice:
    let data = bytes(item.name)
    let id = "foo_string_" & $state.strings.len
    state.strings.add("static const uint8_t " & id & "[] = " & literal(data) & ";")
    return "(" & state.types.get(item.type) & "){" & id & ", " & $data.len & "}"
  if item.type != nil and item.type.kind == TypeKind.Optional and item.name == "null":
    return "(" & state.types.get(item.type) & "){0}"
  if item.type != nil and item.type.kind == TypeKind.Void: return "0"
  if item.name notin ["true", "false", "null"] and
      item.name.anyIt(not (it.isDigit or it in {'-', '+', '.', 'x', 'X', 'e', 'E', 'a'..'f', 'A'..'F'})):
    raise newException(ValueError, "Unsupported C constant '" & item.name & "'")
  if item.type != nil and item.type.kind == TypeKind.Uint and
      (if item.type.width > 0: item.type.width else: 32) == 64:
    return "UINT64_C(" & item.name & ")"
  if item.type != nil and item.type.kind == TypeKind.Int and item.type.width == 64:
    return if item.name == "-9223372036854775808": "INT64_MIN" else: "INT64_C(" & item.name & ")"
  if item.name == "null": "NULL" else: item.name

proc equality(state: EmitState; typ: `Type`; left, right: string): string =
  if typ.kind == TypeKind.Void: return "true"
  if typ.kind in {TypeKind.Int, TypeKind.Uint, TypeKind.Bool, TypeKind.Float,
      TypeKind.Ptr, TypeKind.Function}:
    return "((" & left & ") == (" & right & "))"
  let signature = state.types.get(typ)
  if state.comparisons.hasKey(signature):
    return state.comparisons[signature] & "(" & left & ", " & right & ")"
  let id = "foo_equality_" & $state.comparisons.len
  state.comparisons[signature] = id
  state.prototypes.add("static bool " & id & "(" & signature & " a, " & signature & " b);")
  var body: string
  case typ.kind
  of TypeKind.Slice:
    body = "if (a.len != b.len) return false; for (size_t i = 0; i < a.len; i++) if (!" &
      state.equality(typ.elem, "a.data[i]", "b.data[i]") & ") return false; return true;"
  of TypeKind.Optional:
    body = "return a.present == b.present && (!a.present || " &
      state.equality(typ.elem, "a.value", "b.value") & ");"
  of TypeKind.Struct, TypeKind.ExternStruct:
    var expressions: seq[string]
    for fieldName, fieldType in typ.fields:
      expressions.add(state.equality(fieldType, "a." & name(fieldName), "b." & name(fieldName)))
    body = "return " & (if expressions.len > 0: expressions.join(" && ") else: "true") & ";"
  of TypeKind.TaggedUnion:
    var cases: seq[string]
    var index = 0
    for fieldName, fieldType in typ.variants:
      cases.add("case " & $index & ": return " &
        (if fieldType == nil or fieldType.kind == TypeKind.Void: "true"
         else: state.equality(fieldType, "a.payload." & name(fieldName),
           "b.payload." & name(fieldName))) & ";")
      inc index
    body = "if (a.tag != b.tag) return false; switch (a.tag) { " &
      cases.join(" ") & " default: return false; }"
  else: raise newException(ValueError, "Equality is not implemented for this aggregate layout")
  state.functions.add("static bool " & id & "(" & signature & " a, " & signature &
    " b) { " & body & " }")
  id & "(" & left & ", " & right & ")"

proc ordering(state: EmitState; typ: `Type`; left, right: string): string =
  if typ.kind == TypeKind.Void: return "0"
  if typ.kind in {TypeKind.Int, TypeKind.Uint, TypeKind.Bool}:
    return "(((" & left & ") > (" & right & ")) - ((" & left & ") < (" & right & ")))"
  let signature = state.types.get(typ)
  if state.orders.hasKey(signature):
    return state.orders[signature] & "(" & left & ", " & right & ")"
  let id = "foo_ordering_" & $state.orders.len
  state.orders[signature] = id
  state.prototypes.add("static int " & id & "(" & signature & " a, " & signature & " b);")
  var body: string
  case typ.kind
  of TypeKind.Slice:
    body = "for (size_t i = 0; i < a.len && i < b.len; i++) { int result = " &
      state.ordering(typ.elem, "a.data[i]", "b.data[i]") &
      "; if (result) return result; } return (a.len > b.len) - (a.len < b.len);"
  of TypeKind.Optional:
    body = "if (a.present != b.present) return a.present ? 1 : -1; return a.present ? " &
      state.ordering(typ.elem, "a.value", "b.value") & " : 0;"
  of TypeKind.Struct, TypeKind.ExternStruct:
    var statements: seq[string]
    for fieldName, fieldType in typ.fields:
      statements.add("{ int result = " & state.ordering(fieldType,
        "a." & name(fieldName), "b." & name(fieldName)) & "; if (result) return result; }")
    body = statements.join(" ") & " return 0;"
  of TypeKind.TaggedUnion:
    var cases: seq[string]
    var index = 0
    for fieldName, fieldType in typ.variants:
      cases.add("case " & $index & ": return " &
        (if fieldType == nil or fieldType.kind == TypeKind.Void: "0"
         else: state.ordering(fieldType, "a.payload." & name(fieldName),
           "b.payload." & name(fieldName))) & ";")
      inc index
    body = "if (a.tag != b.tag) return a.tag > b.tag ? 1 : -1; switch (a.tag) { " &
      cases.join(" ") & " default: return 0; }"
  else: raise newException(ValueError, "Ordering is not implemented for this aggregate layout")
  state.functions.add("static int " & id & "(" & signature & " a, " & signature &
    " b) { " & body & " }")
  id & "(" & left & ", " & right & ")"

proc instr(ctx: FunctionState; instruction: Instruction): string

proc destination(ctx: FunctionState; instruction: Instruction): string =
  if instruction == nil or instruction.dest.type == nil or
      instruction.dest.type.kind == TypeKind.Void: return ""
  if instruction.dest.name notin ctx.defined:
    ctx.declarations.add(ctx.emitter.types.get(instruction.dest.type) & " " &
      ctx.emitter.value(instruction.dest) & ";")
    ctx.defined.incl(instruction.dest.name)
  ctx.emitter.value(instruction.dest) & " = "

proc cleanup(ctx: FunctionState; error = "false"): string =
  if ctx.cleanups.len > 0:
    for index in countdown(ctx.cleanups.high, 0):
      let item = ctx.cleanups[index]
      var children: seq[string]
      for child in item.bodyBlock.instrs: children.add(ctx.instr(child))
      result.add("if (" & item.flag &
        (if item.onError: " && (" & error & ")" else: "") & ") { " &
        item.flag & " = false; " & children.join("\n") & " }\n")
  for allocation in ctx.allocations: result.add("free(" & allocation & ");\n")
  for regionId in ctx.regions: result.add("foo_close(&" & regionId & ");\n")

proc returned(ctx: FunctionState; item: Value): string =
  let hasValue = item.type != nil
  if ctx.fn.ret.kind == TypeKind.Void:
    return ctx.cleanup() & (if ctx.fn.name == "main":
      "return (" & ctx.returnType & "){0};" else: "return;")
  if not hasValue and ctx.fn.ret.kind == TypeKind.Fallible and
      ctx.fn.ret.elem != nil and ctx.fn.ret.elem.kind == TypeKind.Void:
    return ctx.cleanup() & "return (" & ctx.returnType & "){0};"
  if not hasValue:
    raise newException(ValueError, "Function '" & ctx.fn.name & "' is missing a return value")
  let temporary = "foo_return_" & $ctx.counter
  inc ctx.counter
  var expression = ctx.emitter.value(item)
  if ctx.fn.ret.kind == TypeKind.Fallible and item.type.kind != TypeKind.Fallible:
    expression = "(" & ctx.returnType & "){NULL, " & expression & "}"
  elif ctx.fn.ret.kind == TypeKind.Optional and item.type.kind != TypeKind.Optional:
    expression = "(" & ctx.returnType & "){true, " & expression & "}"
  ctx.returnType & " " & temporary & " = " & expression & ";\n" &
    ctx.cleanup(if ctx.fn.ret.kind == TypeKind.Fallible:
      temporary & ".error != NULL" else: "false") &
    "return " & temporary & ";"

proc arithmetic(ctx: FunctionState; instruction: Instruction;
    left, right: string; typ: `Type`): string =
  let operation = case instruction.kind
    of InstrKind.Add: "+"
    of InstrKind.Sub: "-"
    of InstrKind.Mul: "*"
    of InstrKind.Div: "/"
    else: ""
  if typ.kind in {TypeKind.Int, TypeKind.Uint}:
    let width = if typ.width > 0: typ.width else: 32
    return "foo_" & ($instruction.kind).toLowerAscii & "_" &
      (if typ.kind == TypeKind.Uint: "u" else: "i") & $width &
      "(" & left & ", " & right & ")"
  "(" & left & " " & operation & " " & right & ")"

proc transfer(ctx: FunctionState; target: string): string =
  if not ctx.labels.hasKey(target):
    raise newException(ValueError, "Unknown IR block '" & target & "'")
  var before, after: seq[string]
  for phi in ctx.fn.blocks[ctx.labels[target]].instrs:
    if phi.kind != InstrKind.Phi: continue
    discard ctx.destination(phi)
    var found = false
    var source: Value
    for incoming in phi.blocks:
      if incoming.label == ctx.current: source = incoming.value; found = true
    if not found:
      raise newException(ValueError, "Phi has no edge from '" & ctx.current & "'")
    let temporary = "foo_phi_" & $ctx.counter
    inc ctx.counter
    before.add(ctx.emitter.types.get(phi.dest.type) & " " & temporary & " = " &
      ctx.emitter.value(source) & ";")
    after.add(ctx.emitter.value(phi.dest) & " = " & temporary & ";")
  "{ " & before.join(" ") & " " & after.join(" ") & " goto " & name(target) & "; }"

proc instr(ctx: FunctionState; instruction: Instruction): string =
  if instruction == nil: return ""
  let state = ctx.emitter
  let d = ctx.destination(instruction)
  case instruction.kind
  of InstrKind.Region:
    let id = name("arena_" & instruction.region)
    if id notin ctx.defined:
      ctx.declarations.add("foo_region " & id & ";")
      ctx.defined.incl(id)
    return if instruction.op == "open": id & ".head = NULL;" else: "foo_close(&" & id & ");"
  of InstrKind.Allocate:
    let size = state.value(instruction.val)
    let output = state.value(instruction.dest)
    if instruction.target.type != nil:
      let id = "allocation" & $ctx.counter
      inc ctx.counter
      let allocationType = `Type`(kind: TypeKind.Fallible,
        elem: `Type`(kind: TypeKind.Ptr, elem: `Type`(kind: TypeKind.Uint, width: 8)))
      let helper = "$allocation" & $ctx.counter
      state.externs[helper] = Extern(name: helper, abi: "runtime.memory",
        symbol: "allocate", params: @[instruction.target.type,
        `Type`(kind: TypeKind.Uint, width: 64)], ret: allocationType)
      state.called.incl(helper)
      return d & "(" & state.types.get(instruction.dest.type) & "){0}; if (" &
        (if instruction.val.type.kind == TypeKind.Int: size & " < 0 || " else: "") &
        "(uint64_t)" & size & " > SIZE_MAX) " & output &
        ".error = \"InvalidSize\"; else { " & state.types.get(allocationType) &
        " " & id & " = " & name(helper) & "(" & state.value(instruction.target) &
        ", (uint64_t)" & size & "); " & output & ".error = " & id &
        ".error; if (!" & id & ".error) { " & output & ".value.data = " &
        id & ".value; " & output & ".value.len = (size_t)" & size & "; } }"
    let regionId = name("arena_" & instruction.region)
    if regionId notin ctx.defined:
      ctx.declarations.add("foo_region " & regionId & " = {0};")
      ctx.defined.incl(regionId)
      ctx.regions.add(regionId)
    return d & "(" & state.types.get(instruction.dest.type) & "){0}; if (" &
      (if instruction.val.type.kind == TypeKind.Int: size & " < 0 || " else: "") &
      "(uint64_t)" & size & " > SIZE_MAX) " & output &
      ".error = \"InvalidSize\"; else { " & output &
      ".value.data = foo_reserve(&" & regionId &
      ", (size_t)" & size & "); if (!" & output & ".value.data) " & output &
      ".error = \"OutOfMemory\"; else " & output & ".value.len = (size_t)" & size & "; }"
  of InstrKind.Return: return ctx.returned(instruction.value)
  of InstrKind.Trace:
    return "foo_trace(" & literal(instruction.trace) & ", " &
      literal(instruction.span.file) & ", " & $instruction.span.start & ");"
  of InstrKind.Reflect:
    let typ = instruction.typeArg
    let textType = `Type`(kind: TypeKind.Slice, constant: true,
      elem: `Type`(kind: TypeKind.Uint, width: 8))
    let typeLabel = label(typ)
    let typeName = state.value(Value(kind: ValueKind.Const,
      name: quoted(typeLabel.toOpenArrayByte(0, typeLabel.high)), type: textType))
    let bare = `Type`(kind: typ.kind, elem: typ.elem, params: typ.params,
      ret: typ.ret, abi: typ.abi, attributes: typ.attributes,
      volatile: typ.volatile, constant: typ.constant, fields: typ.fields,
      fieldAttrs: typ.fieldAttrs, variants: typ.variants)
    let kindLabel = label(bare)
    let kindName = state.value(Value(kind: ValueKind.Const,
      name: quoted(kindLabel.toOpenArrayByte(0, kindLabel.high)), type: textType))
    return d & "(" & state.types.get(instruction.dest.type) & "){ ." &
      name("name") & " = " & typeName & ", ." & name("kind") & " = " &
      kindName & ", ." & name("size") & " = " &
      (if typ.kind == TypeKind.Void: "0" else: "sizeof(" & state.types.get(typ) & ")") &
      ", ." & name("alignment") & " = " &
      (if typ.kind == TypeKind.Void: "1" else: "_Alignof(" & state.types.get(typ) & ")") & " };"
  of InstrKind.Atomic:
    let memoryOrder = "memory_order_" & instruction.field
    if instruction.op == "fence": return "atomic_thread_fence(" & memoryOrder & ");"
    let operation = case instruction.op
      of "load": "load"
      of "store": "store"
      of "add": "fetch_add"
      of "swap": "exchange"
      else: raise newException(ValueError, "Unsupported atomic operation")
    return d & "atomic_" & operation & "_explicit(" & state.value(instruction.ptr) &
      (if instruction.val.type != nil: ", " & state.value(instruction.val) else: "") &
      ", " & memoryOrder & ");"
  of InstrKind.Call, InstrKind.Thread:
    if instruction.func.len > 0: state.called.incl(instruction.func)
    var target: string
    if instruction.callee.type != nil: target = state.value(instruction.callee)
    elif state.externs.hasKey(instruction.func) and
        not state.externs[instruction.func].abi.startsWith("runtime"):
      let external = state.externs[instruction.func]
      target = symbol(if external.symbol.len > 0: external.symbol else: external.name)
    else: target = state.functionName(instruction.func)
    return d & target & "(" & instruction.args.mapIt(state.value(it)).join(", ") & ");"
  of InstrKind.Add, InstrKind.Sub, InstrKind.Mul, InstrKind.Div:
    if instruction.kind == InstrKind.Add and
        instruction.dest.type.kind == TypeKind.Slice and
        instruction.dest.type.constant and instruction.dest.type.elem.width == 8:
      return d & "foo_join(" & state.value(instruction.val) & ", " &
        state.value(instruction.val2) & ");"
    if instruction.dest.type.kind == TypeKind.Vector:
      return "for (size_t k = 0; k < " & $instruction.dest.type.width &
        "; k++) " & state.value(instruction.dest) & ".lane[k] = " &
        ctx.arithmetic(instruction, state.value(instruction.val) & ".lane[k]",
          state.value(instruction.val2) & ".lane[k]", instruction.dest.type.elem) & ";"
    return d & ctx.arithmetic(instruction, state.value(instruction.val),
      state.value(instruction.val2), instruction.dest.type) & ";"
  of InstrKind.Load: return d & "*" & state.value(instruction.ptr) & ";"
  of InstrKind.Store:
    return "*" & state.value(instruction.ptr) & " = " & state.value(instruction.val) & ";"
  of InstrKind.Alloc:
    if instruction.dest.type.kind != TypeKind.Ptr:
      raise newException(ValueError, "alloc needs a pointer result")
    if instruction.op == "slot":
      let cell = "foo_cell_" & $ctx.counter
      inc ctx.counter
      ctx.declarations.add(state.types.get(instruction.dest.type.elem) & " " & cell & ";")
      return d & "&" & cell & ";"
    let allocation = "foo_alloc_" & $ctx.counter
    inc ctx.counter
    ctx.declarations.add("void *" & allocation & " = NULL;")
    ctx.allocations.add(allocation)
    return allocation & " = calloc(1, sizeof(" &
      state.types.get(instruction.dest.type.elem) & ")); if (!" & allocation &
      ") foo_panic(\"OutOfMemory\"); " & d & allocation & ";"
  of InstrKind.Panic:
    return "foo_panic(" & literal(if instruction.msg.len > 0:
      instruction.msg else: "panic") & ");"
  of InstrKind.Not: return d & "!" & state.value(instruction.val) & ";"
  of InstrKind.Convert:
    let typ = instruction.dest.type
    let source = state.value(instruction.val)
    if typ.kind == TypeKind.Optional:
      return d & "(" & state.types.get(typ) & "){ .present = true, .value = " & source & " };"
    if typ.kind == TypeKind.Fallible:
      return d & "(" & state.types.get(typ) & "){ .error = NULL, .value = " & source & " };"
    if typ.kind == TypeKind.Slice:
      return d & "(" & state.types.get(typ) & "){ .data = (" & source &
        ").data, .len = (" & source & ").len };"
    return d & "(" & state.types.get(typ) & ")" & source & ";"
  of InstrKind.Remainder:
    let left = state.value(instruction.val)
    let right = state.value(instruction.val2)
    if instruction.val.type.kind notin {TypeKind.Int, TypeKind.Uint}:
      raise newException(ValueError, "C remainder requires integers")
    return "if (!" & right & ") foo_panic(\"DivisionByZero\"); " & d &
      (if instruction.val.type.kind == TypeKind.Int:
        "(" & right & " == -1 ? 0 : " & left & " % " & right & ")"
       else: left & " % " & right) & ";"
  of InstrKind.Compare:
    let operators = {"equals": "==", "does not equal": "!=",
      "is less than": "<", "is greater than": ">", "is at least": ">=",
      "is at most": "<="}.toTable
    if not operators.hasKey(instruction.op):
      raise newException(ValueError, "Unknown comparison")
    let operation = operators[instruction.op]
    let left = state.value(instruction.val)
    let right = state.value(instruction.val2)
    if instruction.val.type.kind == TypeKind.Optional and
        operation in ["==", "!="] and instruction.val2.kind == ValueKind.Const and
        instruction.val2.name == "null":
      return d & (if operation == "==": "!" else: "") & "(" & left & ").present;"
    if operation in ["==", "!="] and instruction.val.type.kind in {
        TypeKind.Struct, TypeKind.ExternStruct, TypeKind.TaggedUnion,
        TypeKind.Optional, TypeKind.Slice}:
      return d & (if operation == "!=": "!" else: "") &
        state.equality(instruction.val.type, left, right) & ";"
    if instruction.val.type.kind == TypeKind.Vector:
      return "for (size_t lane = 0; lane < " & $instruction.val.type.width &
        "; lane++) " & state.value(instruction.dest) & ".lane[lane] = " &
        left & ".lane[lane] " & operation & " " & right & ".lane[lane];"
    if operation notin ["==", "!="] and instruction.val.type.kind in {
        TypeKind.Struct, TypeKind.ExternStruct, TypeKind.TaggedUnion,
        TypeKind.Optional, TypeKind.Slice}:
      return d & state.ordering(instruction.val.type, left, right) &
        " " & operation & " 0;"
    if instruction.val.type.kind notin {TypeKind.Int, TypeKind.Uint,
        TypeKind.Float, TypeKind.Bool, TypeKind.Ptr, TypeKind.Function}:
      raise newException(ValueError, "Aggregate comparison needs an explicit equality operation")
    return d & left & " " & operation & " " & right & ";"
  of InstrKind.Length:
    return d & (if instruction.val.type.kind == TypeKind.Slice:
      "(" & state.value(instruction.val) & ").len" else: $instruction.val.type.width) & ";"
  of InstrKind.Index:
    let sequenceValue = state.value(instruction.val)
    let index = state.value(instruction.val2)
    let sequence = instruction.val.type.kind == TypeKind.Slice
    let length = if sequence: "(" & sequenceValue & ").len" else: $instruction.val.type.width
    return "if (" & (if instruction.val2.type.kind == TypeKind.Int:
      index & " < 0 || " else: "") & "(uint64_t)" & index & " >= " & length &
      ") foo_panic(\"IndexOutOfBounds\"); " & d &
      (if instruction.op == "address": "&" else: "") & "(" & sequenceValue & ")." &
      (if sequence: "data" else: "lane") & "[" & index & "];"
  of InstrKind.Construct:
    let typ = instruction.dest.type
    if typ.kind == TypeKind.Fallible and instruction.op == "error":
      return d & "(" & state.types.get(typ) & "){ .error = " &
        state.value(instruction.args[0]) & " };"
    if typ.kind == TypeKind.TaggedUnion:
      var index = 0
      var found = -1
      for fieldName in typ.variants.keys:
        if fieldName == instruction.field: found = index
        inc index
      if found < 0: raise newException(ValueError, "Unknown tagged union field")
      return d & "(" & state.types.get(typ) & "){ .tag = " & $found &
        (if instruction.args.len > 0: ", .payload." & name(instruction.field) &
          " = " & state.value(instruction.args[0]) else: "") & " };"
    if typ.kind notin {TypeKind.Struct, TypeKind.ExternStruct}:
      raise newException(ValueError, "Unsupported aggregate construction")
    var fields: seq[string]
    var index = 0
    for fieldName in typ.fields.keys:
      fields.add("." & name(fieldName) & " = " & state.value(instruction.args[index]))
      inc index
    return d & "(" & state.types.get(typ) & "){ " & fields.join(", ") & " };"
  of InstrKind.Extract:
    let typ = if instruction.val.type.kind == TypeKind.Ptr:
      instruction.val.type.elem else: instruction.val.type
    if typ.kind == TypeKind.Fallible:
      return (if d.len > 0: d else: "(void)") & "(" &
        state.value(instruction.val) & ")." &
        (if instruction.field == "failed": "error != NULL" else: "value") & ";"
    if typ.kind == TypeKind.PackedStruct:
      raise newException(ValueError, "Packed projections need a bit extraction operation")
    let field = if typ.kind == TypeKind.TaggedUnion:
      (if instruction.field == "tag": "tag" else: "payload." & name(instruction.field))
      else: name(instruction.field)
    return d & (if instruction.op == "address": "&" else: "") & "(" &
      state.value(instruction.val) & ")" &
      (if instruction.val.type.kind == TypeKind.Ptr: "->" else: ".") & field & ";"
  of InstrKind.Try:
    let expression = state.value(instruction.expr)
    if ctx.resultType.kind != TypeKind.Fallible:
      raise newException(ValueError, "try in infallible C function '" & ctx.fn.name & "'")
    return "if (" & expression & ".error) { " & ctx.cleanup("true") &
      " return (" & ctx.returnType & "){ .error = " & expression &
      ".error }; }\n" & (if d.len > 0: d & expression & ".value;" else: "")
  of InstrKind.Catch:
    var children: seq[string]
    for child in instruction.fallback.instrs: children.add(ctx.instr(child))
    return "if (" & state.value(instruction.val) & ".error) {\n" &
      children.join("\n") & "\n" & (if d.len > 0: d else: "(void)") &
      state.value(instruction.fallback.term.value) & ";\n} else { " &
      (if d.len > 0: d else: "(void)") & state.value(instruction.val) & ".value; }"
  of InstrKind.Defer:
    let flag = "foo_defer_" & $ctx.counter
    inc ctx.counter
    ctx.declarations.add("bool " & flag & " = false;")
    ctx.cleanups.add(Cleanup(bodyBlock: instruction.fallback, flag: flag,
      onError: instruction.error))
    return flag & " = true;"
  of InstrKind.Jump: return ctx.transfer(instruction.label)
  of InstrKind.Cjump:
    return "if (" & state.value(instruction.cond) & ") { " &
      ctx.transfer(instruction.trueLabel) & " } else { " &
      ctx.transfer(instruction.falseLabel) & " }"
  of InstrKind.Phi: return ""
  of InstrKind.Splat:
    return "for (size_t k = 0; k < " & $instruction.dest.type.width &
      "; k++) " & state.value(instruction.dest) & ".lane[k] = " &
      state.value(instruction.val) & ";"
  of InstrKind.Select:
    return "for (size_t k = 0; k < " & $instruction.dest.type.width &
      "; k++) " & state.value(instruction.dest) & ".lane[k] = " &
      state.value(instruction.cond) & ".lane[k] ? " &
      state.value(instruction.val) & ".lane[k] : " &
      state.value(instruction.val2) & ".lane[k];"
  of InstrKind.Shuffle:
    var statements: seq[string]
    let width = instruction.val.type.width
    for index, lane in instruction.mask:
      if lane < 0 or lane >= width + instruction.val2.type.width:
        raise newException(ValueError, "Shuffle lane is out of bounds")
      statements.add(state.value(instruction.dest) & ".lane[" & $index & "] = " &
        (if lane < width: state.value(instruction.val)
         else: state.value(instruction.val2)) & ".lane[" &
        $(if lane < width: lane else: lane - width) & "];")
    return statements.join("\n")
  of InstrKind.Reduce:
    let output = state.value(instruction.dest)
    let lane = state.value(instruction.val) & ".lane[k]"
    let operation = if instruction.reduceOp.len > 0: instruction.reduceOp else: "Add"
    var expression: string
    if operation == "Min":
      expression = "(" & output & " < " & lane & " ? " & output & " : " & lane & ")"
    elif operation == "Max":
      expression = "(" & output & " > " & lane & " ? " & output & " : " & lane & ")"
    elif operation in ["Add", "Mul"]:
      expression = ctx.arithmetic(Instruction(kind:
        if operation == "Add": InstrKind.Add else: InstrKind.Mul),
        output, lane, instruction.dest.type)
    else:
      let operations = {"And": "&", "Or": "|", "Xor": "^"}.toTable
      if not operations.hasKey(operation):
        raise newException(ValueError, "Unknown vector reduction")
      expression = output & " " & operations[operation] & " " & lane
    return d & state.value(instruction.val) &
      ".lane[0]; for (size_t k = 1; k < " & $instruction.val.type.width &
      "; k++) " & output & " = " & expression & ";"
  of InstrKind.Embed:
    let source = if state.options.source.len > 0: state.options.source else: "main.iv"
    let path = parentDir(source) / instruction.path
    let data = readFile(path)
    let id = "foo_string_" & $state.strings.len
    state.strings.add("static const uint8_t " & id & "[] = " & literal(data) & ";")
    if instruction.dest.type.kind == TypeKind.Slice:
      return d & "(" & state.types.get(instruction.dest.type) & "){" &
        id & ", " & $data.len & "};"
    raise newException(ValueError, "Embedded resources need a text type in the C backend")
  of InstrKind.Native:
    if not state.contracts.hasKey(instruction.symbol):
      raise newException(ValueError, "Native operation has no contract")
    state.referenced.incl(instruction.symbol)
    return native(state.contracts[instruction.symbol], state.selection)
  of InstrKind.NativeZig:
    raise newException(ValueError, "native zig and Zig-style asm require the Zig backend")
  else: raise newException(ValueError, "C backend does not support IR " & $instruction.kind)

proc integers(): string =
  for width in [8, 16, 32, 64]:
    for unsigned in [false, true]:
      let typ = (if unsigned: "u" else: "") & "int" & $width & "_t"
      let suffix = (if unsigned: "u" else: "i") & $width
      let maximum = (if unsigned: "U" else: "") & "INT" & $width & "_MAX"
      let minimum = "INT" & $width & "_MIN"
      let addGuard = if unsigned: "a > " & maximum & " - b"
        else: "(b > 0 && a > " & maximum & " - b) || (b < 0 && a < " & minimum & " - b)"
      let subGuard = if unsigned: "a < b"
        else: "(b < 0 && a > " & maximum & " + b) || (b > 0 && a < " & minimum & " + b)"
      let mulGuard = if unsigned: "b && a > " & maximum & " / b"
        else: "(a > 0 ? (b > 0 ? a > " & maximum & "/b : b < " & minimum &
          "/a) : (a < 0 ? (b > 0 ? a < " & minimum & "/b : b < 0 && a < " &
          maximum & "/b) : false))"
      result.add("static " & typ & " foo_add_" & suffix & "(" & typ & " a, " &
        typ & " b) { if (" & addGuard & ") foo_panic(\"IntegerOverflow\"); return (" &
        typ & ")(a + b); }\n")
      result.add("static " & typ & " foo_sub_" & suffix & "(" & typ & " a, " &
        typ & " b) { if (" & subGuard & ") foo_panic(\"IntegerOverflow\"); return (" &
        typ & ")(a - b); }\n")
      result.add("static " & typ & " foo_mul_" & suffix & "(" & typ & " a, " &
        typ & " b) { if (" & mulGuard & ") foo_panic(\"IntegerOverflow\"); return (" &
        typ & ")(a * b); }\n")
      result.add("static " & typ & " foo_div_" & suffix & "(" & typ & " a, " &
        typ & " b) { if (!b) foo_panic(\"DivisionByZero\"); " &
        (if unsigned: "" else: "if (a == " & minimum &
          " && b == -1) foo_panic(\"IntegerOverflow\"); ") &
        "return (" & typ & ")(a / b); }\n")

proc emit*(input: Module; mode = "dev"; options = Options()):
    tuple[code: string, libraries: seq[string]] =
  var selection = Selection(target: options.target, cpu: options.cpu,
    level: options.level, mode: mode, substrate: options.substrate)
  let module = prepare(`bind`(input, selection).module)
  let state = EmitState(types: newTypes(), options: options, selection: selection,
    comparisons: initTable[string, string](), orders: initTable[string, string](),
    externs: initTable[string, Extern](),
    contracts: initTable[string, NativeContract](),
    called: initHashSet[string](), referenced: initHashSet[string](),
    storage: initHashSet[string](), exported: initHashSet[string]())
  for external in module.externs: state.externs[external.name] = external
  for contract in module.native: state.contracts[contract.id] = contract
  for item in module.storage: state.storage.incl(item.name)
  for fn in module.funcs:
    if fn.abi == "c" or (options.library and fn.public):
      state.exported.incl(fn.name)
  for declaration in module.types: discard state.types.get(declaration.type)

  for fnIndex, fn in module.funcs:
    if fn.blocks.len > 1:
      for basicBlock in fn.blocks:
        for instruction in basicBlock.instrs:
          if instruction.kind == InstrKind.Defer or
              (instruction.kind == InstrKind.Alloc and instruction.op != "slot"):
            raise newException(ValueError,
              "C backend does not yet support scoped allocation or cleanup in multi-block IR")
    for attribute in fn.attributes:
      if attribute in ["start", "naked", "interrupt"] or
          attribute.startsWith("target_feature"):
        raise newException(ValueError, "C backend cannot preserve attributes on '" &
          fn.name & "'; use the Zig backend")
    let resultType = if fn.name == "main" and fn.ret.kind == TypeKind.Void:
      `Type`(kind: TypeKind.Fallible, elem: fn.ret) else: fn.ret
    let returnType = state.types.get(resultType)
    var parameters: seq[string]
    var defined = initHashSet[string]()
    for parameter in fn.params:
      parameters.add(state.types.get(parameter.type) & " " & state.value(parameter))
      defined.incl(parameter.name)
    let signature = (if fn.name in state.exported: "FOO_EXPORT " else: "") &
      returnType & " " & state.functionName(fn.name) & "(" &
      (if parameters.len > 0: parameters.join(", ") else: "void") & ")"
    state.prototypes.add(signature & ";")
    let ctx = FunctionState(emitter: state, fn: fn, resultType: resultType,
      returnType: returnType, defined: defined, labels: initTable[string, int]())
    for index, basicBlock in fn.blocks: ctx.labels[basicBlock.label] = index
    for basicBlock in fn.blocks:
      ctx.current = basicBlock.label
      ctx.body.add(name(basicBlock.label) & ":;")
      for instruction in basicBlock.instrs: ctx.body.add(ctx.instr(instruction))
      ctx.body.add(ctx.instr(basicBlock.term))
    state.functions.add(signature & " {\n" &
      (if options.coverage.len > 0:
        "atomic_fetch_add_explicit(&foo_hits[" & $fnIndex &
        "], 1, memory_order_relaxed);\n" else: "") &
      ctx.declarations.join("\n") & "\n" & ctx.body.join("\n") & "\n}")

  var runtimeExterns: seq[Extern]
  for called in state.called:
    if state.externs.hasKey(called) and
        state.externs[called].abi.startsWith("runtime"):
      runtimeExterns.add(state.externs[called])
  let runtimeResult = runtime(runtimeExterns,
    proc(value: `Type`): string = state.types.get(value),
    proc(value: string): string = name(value))
  var seen = initTable[string, string]()
  for external in module.externs:
    if external.name notin state.called or external.abi.startsWith("runtime"): continue
    if external.abi != "c":
      raise newException(ValueError, "Unsupported C ABI '" & external.abi & "'")
    let externalName = symbol(if external.symbol.len > 0:
      external.symbol else: external.name)
    let signature = state.types.get(external.ret) & " " & externalName & "(" &
      (if external.params.len > 0:
        external.params.mapIt(state.types.get(it)).join(", ") else: "void") & ");"
    if seen.hasKey(externalName) and seen[externalName] != signature:
      raise newException(ValueError, "Conflicting C declarations for '" & externalName & "'")
    if not seen.hasKey(externalName): state.prototypes.add("extern " & signature)
    seen[externalName] = signature
  var globals: seq[string]
  for item in module.storage:
    globals.add(state.types.get(item.value.type) & " " & name(item.name) &
      " = " & state.value(item.value) & ";")
  let copy = select("copy", selection)
  var definitions: seq[string]
  for contract in module.native:
    if contract.id notin state.referenced:
      definitions.add(native(contract, selection, true))
  var coverage = ""
  if options.coverage.len > 0:
    coverage = "static _Atomic uint64_t foo_hits[" & $max(1, module.funcs.len) &
      "];\nstatic void foo_report(void) {\n  FILE *file = fopen(" &
      literal(options.coverage) &
      ", \"wb\");\n  if (!file) { fputs(\"Could not write coverage\\n\", stderr); return; }\n" &
      "  fputs(\"{\\\"version\\\":1,\\\"kind\\\":\\\"function\\\",\\\"entries\\\":[\", file);\n"
    for index, fn in module.funcs:
      let prefix = if index > 0: "," else: ""
      let metadata = prefix & $(%*{"function": fn.name, "line": fn.line})
      coverage.add("  fputs(" & literal(metadata[0 ..< metadata.high]) &
        ", file); fputs(\",\\\"hits\\\":\", file); fprintf(file, \"%llu}\", " &
        "(unsigned long long)atomic_load_explicit(&foo_hits[" & $index &
        "], memory_order_relaxed));\n")
    coverage.add("  fputs(\"]}\", file); if (fclose(file)) fputs(\"Could not write coverage\\n\", stderr);\n}\n")
  var entry: Function
  for fn in module.funcs:
    if fn.name == "main": entry = fn
  let copyDefine =
    if copy.implementation == "avx": "#define FOO_COPY_AVX 1"
    elif copy.implementation == "rep": "#define FOO_COPY_X86 1"
    elif copy.implementation == "intrinsic": "#define FOO_COPY_ARM 1"
    else: ""
  var entrypoint = ""
  if entry != nil:
    entrypoint = "int main(int argc, char **argv) {\n#ifdef FOO_SERVICE\n" &
      "foo_service_init(argc, argv);\n#else\n(void)argc; (void)argv;\n#endif\n"
    if entry.ret.kind in {TypeKind.Fallible, TypeKind.Void}:
      entrypoint.add("const char *error = " & name("main") &
        "().error; if (error) fprintf(stderr, \"%s\\n\", error);")
    else:
      entrypoint.add(name("main") & "(); const char *error = NULL;")
    if options.coverage.len > 0: entrypoint.add(" foo_report();")
    entrypoint.add(" foo_shutdown(); return error ? 1 : 0; }\n")
  result.code = "/* FOO IR -> ISO C11 */\n#include <stdint.h>\n#include <stddef.h>\n" &
    "#include <stdbool.h>\n#include <stdatomic.h>\n#include <stdlib.h>\n" &
    "#include <stdio.h>\n#include <string.h>\n#include <limits.h>\n" &
    "#if defined(_WIN32)\n#define FOO_EXPORT __declspec(dllexport)\n#else\n" &
    "#define FOO_EXPORT\n#endif\nstatic _Noreturn void foo_panic(const char *message) " &
    "{ fprintf(stderr, \"%s\\n\", message); exit(1); }\n" & memoryCode & "\n" &
    traceCode & "\n" & copyDefine & "\n" & copyCode & "\n" &
    state.types.declarations.join("\n") & "\n" & integers() & "\n" &
    state.strings.join("\n") & "\n" & globals.join("\n") & "\n" &
    state.prototypes.join("\n") & "\n" & runtimeResult.code & "\n" &
    coverage & definitions.join("\n") & "\n" & state.functions.join("\n") &
    "\n" & entrypoint
  result.libraries = runtimeResult.libraries
