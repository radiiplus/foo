## Typed IR to QBE IL for the currently qualified scalar and aggregate subset.
import std/[strutils, tables, sequtils, algorithm, os]
import ../../ir/[kind, node]
import ../../opt/arch as targetArch
import ./layout as targetLayout
import ./abi as bridgeAbi

proc unsupported(subject: string): ref ValueError =
  newException(ValueError, "QBE proof of concept cannot lower " & subject)

const interruptAttributes = ["interrupt", "interrupt_error_code",
  "interrupt_el2", "interrupt_el3"]

proc interruptMode(fn: node.Function): string =
  for attribute in fn.attributes:
    if attribute in interruptAttributes:
      if result.len > 0: raise unsupported("multiple interrupt modes on '" & fn.name & "'")
      result = attribute

proc codecSchema(t: node.Type; depth = 0): seq[int] =
  if depth >= 64: raise unsupported("typed JSON schema depth")
  if t == nil: return @[ord('V')]
  proc word(output: var seq[int]; value, bytes: int) =
    if value < 0 or (bytes == 2 and value > 65535) or
        (bytes == 4 and value > high(uint32).int):
      raise unsupported("typed JSON schema size")
    for index in 0..<bytes: output.add((value shr (index * 8)) and 255)
  case t.kind
  of Shape.Bool: result.add(ord('B'))
  of Shape.Void: result.add(ord('V'))
  of Shape.Int, Shape.Uint:
    if t.width notin 1..128: raise unsupported("typed JSON integer width")
    result.add(ord(if t.kind == Shape.Int: 'I' else: 'U'))
    result.word(targetLayout.measure(t).size, 1)
    result.word(t.width, 1)
  of Shape.Slice:
    if t.elem == nil: raise unsupported("typed JSON sequence element")
    if t.constant and t.elem.kind == Shape.Uint and t.elem.width == 8:
      result.add(ord('T'))
    else:
      let member = codecSchema(t.elem, depth + 1)
      let layout = targetLayout.measure(t.elem)
      result.add(ord('S'))
      result.word(layout.size, 4)
      result.word(layout.alignment, 4)
      result.word(member.len, 4)
      result.add(member)
  of Shape.Array:
    if t.elem == nil or t.width < 0: raise unsupported("typed JSON array")
    let member = codecSchema(t.elem, depth + 1)
    result.add(ord('A'))
    result.word(t.width, 4)
    result.word(targetLayout.measure(t.elem).size, 4)
    result.word(member.len, 4)
    result.add(member)
  of Shape.Optional:
    if t.elem == nil: raise unsupported("typed JSON optional element")
    let member = codecSchema(t.elem, depth + 1)
    result.add(ord('O'))
    result.word(targetLayout.measure(t).offsets[1], 4)
    result.word(member.len, 4)
    result.add(member)
  of Shape.Struct, Shape.ExternStruct:
    let offsets = targetLayout.measure(t).offsets
    result.add(ord('R'))
    result.word(t.fields.len, 2)
    var index = 0
    for name, field in t.fields:
      result.word(offsets[index], 4)
      result.word(name.len, 2)
      for character in name: result.add(ord(character))
      result.add(codecSchema(field, depth + 1))
      inc index
  of Shape.TaggedUnion:
    result.add(ord('C'))
    result.word(t.variants.len, 2)
    result.word(targetLayout.measure(t).offsets[1], 4)
    for name, variant in t.variants:
      let member = codecSchema(variant, depth + 1)
      result.word(name.len, 2)
      for character in name: result.add(ord(character))
      result.word(member.len, 4)
      result.add(member)
  of Shape.PackedStruct:
    result.add(ord('P'))
    result.word(t.fields.len, 2)
    let offsets = targetLayout.measure(t).offsets
    var index = 0
    for name, field in t.fields:
      let bits = targetLayout.packedBits(field)
      if bits notin 1..128:
        raise unsupported("typed JSON packed field width")
      let member = codecSchema(field, depth + 1)
      result.word(offsets[index], 4)
      result.word(bits, 2)
      result.word(name.len, 2)
      for character in name: result.add(ord(character))
      result.word(member.len, 4)
      result.add(member)
      inc index
  else: raise unsupported("typed JSON type " & t.label)

proc identifier(name: string): string =
  if name.len == 0 or not (name[0].isAlphaAscii or name[0] == '_'):
    raise unsupported("symbol '" & name & "'")
  for character in name:
    if not (character.isAlphaNumeric or character == '_'):
      raise unsupported("symbol '" & name & "'")
  name

proc base(t: node.Type): string =
  if t == nil: raise unsupported("an untyped value")
  if t.attributes.anyIt(not it.startsWith("align(")) and
      not (t.attributes == @["atomic"] and
        t.kind in {Shape.Int, Shape.Uint} and
        t.width in [8, 16, 32, 64]):
    raise unsupported("volatile or attributed type " & t.label)
  case t.kind
  of Shape.Int, Shape.Uint:
    if t.width notin 1..128:
      raise unsupported(t.label & " (integer width outside 1..128)")
    if t.width <= 32: "w" else: "l"
  of Shape.Bool: "w"
  of Shape.Ptr:
    if t.elem == nil or t.elem.kind notin
        {Shape.Int, Shape.Uint, Shape.Bool, Shape.Float, Shape.Ptr, Shape.Function,
         Shape.Array, Shape.Vector, Shape.Struct, Shape.ExternStruct,
         Shape.TaggedUnion, Shape.ExternUnion, Shape.PackedStruct,
         Shape.Slice, Shape.Optional, Shape.Failable, Shape.Error,
         Shape.Opaque}:
      raise unsupported("pointer element type")
    if t.elem.volatile:
      discard
    elif t.elem.attributes == @["atomic"] and
        t.elem.kind in {Shape.Int, Shape.Uint} and
        t.elem.width in [8, 16, 32, 64] and not t.elem.volatile:
      discard
    elif t.elem.kind != Shape.Opaque:
      discard base(t.elem)
    "l"
  of Shape.Array, Shape.Vector, Shape.Slice, Shape.Optional, Shape.Failable:
    if t.elem == nil or t.width < 0: raise unsupported("sequence layout")
    if t.elem.kind != Shape.Void: discard base(t.elem)
    discard targetLayout.measure(t)
    "l"
  of Shape.Struct, Shape.ExternStruct, Shape.ExternUnion:
    for field in t.fields.values:
      if field != nil: discard base(field)
    discard targetLayout.measure(t)
    "l"
  of Shape.TaggedUnion:
    for variant in t.variants.values:
      if variant != nil: discard base(variant)
    discard targetLayout.measure(t)
    "l"
  of Shape.PackedStruct:
    discard targetLayout.measure(t)
    "l"
  of Shape.Error: "l"
  of Shape.Function:
    if (t.abi notin ["", "c", "runtime.codec"] and
        t.abi notin bridgeAbi.foreignAbis) or
        t.ret == nil:
      raise unsupported("function pointer ABI")
    for parameter in t.params:
      if parameter == nil or parameter.kind notin
          {Shape.Int, Shape.Uint, Shape.Bool, Shape.Float, Shape.Ptr,
            Shape.Function, Shape.Array, Shape.Vector, Shape.Struct,
            Shape.ExternStruct, Shape.Slice, Shape.Optional, Shape.Failable}:
        raise unsupported("function pointer parameter type")
      discard base(parameter)
    if t.ret.kind != Shape.Void: discard base(t.ret)
    "l"
  of Shape.Float:
    case t.width
    of 32: "s"
    of 64: "d"
    else: raise unsupported(t.label & " (only 32- and 64-bit floats are qualified)")
  else: raise unsupported(t.label)

proc boundary(t: node.Type): string =
  if t == nil or t.kind == Shape.Void: return ""
  if t.kind in {Shape.Array, Shape.Vector, Shape.Struct, Shape.ExternStruct,
      Shape.Slice, Shape.Optional, Shape.Failable}:
    raise unsupported("aggregate C ABI")
  discard base(t)
  if t.kind == Shape.Bool: return "ub"
  if t.kind in {Shape.Int, Shape.Uint} and t.width in [8, 16]:
    return (if t.kind == Shape.Int: "s" else: "u") &
      (if t.width == 8: "b" else: "h")
  base(t)

proc canContainPointer(t: node.Type): bool =
  if t == nil: return false
  case t.kind
  of Shape.Ptr, Shape.Function, Shape.Error, Shape.Slice: true
  of Shape.Array, Shape.Vector, Shape.Optional, Shape.Failable:
    canContainPointer(t.elem)
  of Shape.Struct, Shape.ExternStruct, Shape.ExternUnion:
    for field in t.fields.values:
      if canContainPointer(field): return true
    false
  of Shape.TaggedUnion:
    for variant in t.variants.values:
      if canContainPointer(variant): return true
    false
  else: false

proc scalarLiteral(v: Value): string =
  if v.type == nil: raise unsupported("an untyped value")
  case v.kind
  of Flavor.Reg: "%" & identifier(v.name)
  of Flavor.Global: raise unsupported("global value '" & v.name & "'")
  of Flavor.Const:
    case v.type.kind
    of Shape.Bool:
      if v.name == "true": "1"
      elif v.name == "false": "0"
      else: raise unsupported("boolean constant '" & v.name & "'")
    of Shape.Ptr:
      if v.name == "null": "0"
      else: raise unsupported("pointer constant '" & v.name & "'")
    of Shape.Int, Shape.Uint:
      if v.type.width > 64:
        raise unsupported("wide integer constant needs address storage")
      let number = v.name.replace("_", "").replace("`", "")
      if number.len == 0: raise unsupported("empty integer constant")
      for index, character in number:
        if not character.isDigit and not (index == 0 and character == '-'):
          raise unsupported("integer constant '" & v.name & "'")
      if number == "-": raise unsupported("integer constant '" & v.name & "'")
      try:
        if v.type.kind == Shape.Uint:
          if number[0] == '-': raise unsupported("negative unsigned constant")
          let parsed = parseBiggestUInt(number)
          let maximum = if v.type.width == 64: uint64.high
            else: (1'u64 shl v.type.width) - 1
          if parsed > maximum:
            raise unsupported("out-of-range unsigned constant")
        else:
          let parsed = parseBiggestInt(number)
          let minimum = if v.type.width == 64: int64.low
            else: -(1'i64 shl (v.type.width - 1))
          let maximum = if v.type.width == 64: int64.high
            else: (1'i64 shl (v.type.width - 1)) - 1
          if parsed < minimum or parsed > maximum:
            raise unsupported("out-of-range signed constant")
      except ValueError:
        raise unsupported("out-of-range integer constant '" & v.name & "'")
      number
    of Shape.Float:
      if v.bits.len > 0:
        let digits = v.bits.replace("_", "")
        if digits.len != v.type.width div 4 or
            digits.anyIt(it notin HexDigits):
          raise unsupported("floating bit-pattern constant")
        try:
          let raw = parseHexInt(digits)
          return if v.type.width == 32: $cast[int32](raw.uint32)
            else: $cast[int64](raw.uint64)
        except ValueError:
          raise unsupported("floating bit-pattern constant")
      if v.name.len == 0: raise unsupported("empty floating constant")
      for character in v.name:
        if character notin {'0'..'9', '.', '-', '+', 'e', 'E'}:
          raise unsupported("floating constant '" & v.name & "'")
      base(v.type) & "_" & v.name
    else: raise unsupported("constant of type " & v.type.label)

proc wideBytes(v: Value): seq[byte] =
  if v.type == nil or v.type.kind notin {Shape.Int, Shape.Uint} or
      v.type.width notin 65..128 or v.kind != Flavor.Const:
    raise unsupported("wide integer constant")
  let spelling = v.name.replace("_", "").replace("`", "")
  if spelling.len == 0 or spelling == "-":
    raise unsupported("wide integer constant")
  let negative = spelling[0] == '-'
  if negative and v.type.kind == Shape.Uint:
    raise unsupported("negative unsigned constant")
  var limbs: array[4, uint32]
  for index in (if negative: 1 else: 0)..<spelling.len:
    if spelling[index] notin {'0'..'9'}:
      raise unsupported("wide integer constant")
    var carry = uint64(ord(spelling[index]) - ord('0'))
    for limb in mitems(limbs):
      let next = uint64(limb) * 10 + carry
      limb = uint32(next and 0xffffffff'u64)
      carry = next shr 32
    if carry != 0: raise unsupported("out-of-range wide integer constant")
  proc bit(index: int): bool =
    (limbs[index div 32] and (1'u32 shl (index mod 32))) != 0
  let top = if v.type.kind == Shape.Uint or negative:
      v.type.width - 1 else: v.type.width - 2
  for index in max(0, top + 1)..127:
    if bit(index): raise unsupported("out-of-range wide integer constant")
  if top < 0 and limbs.anyIt(it != 0):
    raise unsupported("out-of-range wide integer constant")
  if negative and bit(top):
    for index in 0..<top:
      if bit(index): raise unsupported("out-of-range wide integer constant")
  if negative:
    var carry = 1'u64
    for limb in mitems(limbs):
      let next = uint64(not limb) + carry
      limb = uint32(next and 0xffffffff'u64)
      carry = next shr 32
  for limb in limbs:
    for index in 0..3:
      result.add(byte((limb shr (index * 8)) and 255))

proc same(a, b: node.Type): bool =
  if a == nil or b == nil: return a == nil and b == nil
  if a.kind != b.kind or a.width != b.width:
    return false
  if a.name != b.name or a.constant != b.constant or a.abi != b.abi or
      a.volatile != b.volatile or a.attributes != b.attributes:
    return false
  case a.kind
  of Shape.Ptr: a.elem != nil and b.elem != nil and same(a.elem, b.elem)
  of Shape.Array, Shape.Vector, Shape.Slice, Shape.Optional, Shape.Failable:
    a.elem != nil and b.elem != nil and same(a.elem, b.elem)
  of Shape.Struct, Shape.ExternStruct, Shape.PackedStruct, Shape.ExternUnion:
    if a.fields.len != b.fields.len: return false
    var index = 0
    for name, field in a.fields:
      if name notin b.fields or targetLayout.position(b, name) != index or
          not same(field, b.fields[name]): return false
      inc index
    true
  of Shape.TaggedUnion:
    if a.variants.len != b.variants.len: return false
    for name, variant in a.variants:
      if name notin b.variants or not same(variant, b.variants[name]):
        return false
    true
  of Shape.Function:
    if a.abi != b.abi or a.params.len != b.params.len or
        not same(a.ret, b.ret): return false
    for index, parameter in a.params:
      if not same(parameter, b.params[index]): return false
    true
  else: true

proc loadOp(t: node.Type): string =
  case t.kind
  of Shape.Bool: "loadub"
  of Shape.Int, Shape.Uint:
    if t.width <= 8: (if t.kind == Shape.Int: "loadsb" else: "loadub")
    elif t.width <= 16: (if t.kind == Shape.Int: "loadsh" else: "loaduh")
    else: "load" & base(t)
  of Shape.Float: "load" & base(t)
  of Shape.Ptr, Shape.Function, Shape.Error: "loadl"
  else: raise unsupported("load of " & t.label)

proc storeOp(t: node.Type): string =
  case t.kind
  of Shape.Bool: "storeb"
  of Shape.Int, Shape.Uint:
    if t.width <= 8: "storeb"
    elif t.width <= 16: "storeh"
    else: "store" & base(t)
  of Shape.Float: "store" & base(t)
  of Shape.Ptr, Shape.Function, Shape.Error: "storel"
  else: raise unsupported("store of " & t.label)

proc comparison(i: Instruction): string =
  if not same(i.val.type, i.val2.type) or i.dest.type == nil or
      i.dest.type.kind != Shape.Bool:
    raise unsupported("comparison with incompatible types")
  let t = i.val.type
  let suffix = base(t)
  let op = case i.op
    of "equals": "eq"
    of "does not equal": "ne"
    of "is less than": "lt"
    of "is at most": "le"
    of "is greater than": "gt"
    of "is at least": "ge"
    else: raise unsupported("comparison '" & i.op & "'")
  if t.kind == Shape.Ptr and op notin ["eq", "ne"]:
    raise unsupported("ordered pointer comparison")
  if t.kind in {Shape.Int, Shape.Uint} and t.width notin [8, 16, 32, 64]:
    raise unsupported("integer comparison width")
  if t.kind in {Shape.Int, Shape.Uint} and op notin ["eq", "ne"]:
    return "c" & (if t.kind == Shape.Int: "s" else: "u") & op & suffix
  "c" & op & suffix

proc emit*(module: Module; source = "main.iv"; entry = false;
    target = ""; cpu = ""; typedCodec = false;
    inlineNarrowIntegers = false): string =
  if module == nil: raise unsupported("an empty module")
  let arm64Qbe = target in ["linux-arm64", "arm64-freestanding"]
  var functionsToEmit: seq[Function]
  var codecAdapters = initTable[string, string]()
  let callbackBridges = bridgeAbi.callbacks(module)
  var vectorHelpers = initTable[pointer, string]()
  for fn in module.funcs: functionsToEmit.add(fn)
  for ext in module.externs:
    if ext.abi != "runtime.codec" or ext.generics.len > 0 or
        ext.symbol notin ["encode", "decode", "marshal", "unmarshal"]:
      continue
    let name = "qbe_codec_adapter_" & $codecAdapters.len
    var arguments: seq[Value]
    for index, parameter in ext.params:
      arguments.add(Value(kind: Flavor.Reg, name: "argument_" & $index,
        `type`: parameter))
    let output = Value(kind: Flavor.Reg, name: "codec_result",
      `type`: ext.ret)
    codecAdapters[ext.name] = name
    functionsToEmit.add(Function(name: name, abi: "", ret: ext.ret,
      params: arguments, blocks: @[Block(label: "entry", instrs: @[
        Instruction(kind: Opcode.Call, dest: output, `func`: ext.name,
          abi: ext.abi, args: arguments)],
        term: Instruction(kind: Opcode.Return, value: output))]))
  for fn in module.funcs:
    for section in fn.blocks:
      for i in section.instrs:
        if i.kind notin {Opcode.Add, Opcode.Sub, Opcode.Mul, Opcode.Div,
            Opcode.Remainder} or i.dest.type == nil or
            i.dest.type.kind != Shape.Vector:
          continue
        let vector = i.dest.type
        if vector.elem == nil or vector.width < 1 or
            vector.elem.kind notin {Shape.Int, Shape.Uint, Shape.Float} or
            (vector.elem.kind in {Shape.Int, Shape.Uint} and
              vector.elem.width notin [32, 64]) or
            not same(vector, i.val.type) or not same(vector, i.val2.type):
          raise unsupported("elementwise vector arithmetic type")
        let helper = "qbe_vector_operation_" & $vectorHelpers.len
        if module.funcs.anyIt(it.name == helper):
          raise unsupported("reserved vector helper name")
        vectorHelpers[cast[pointer](i)] = helper
        let left = Value(kind: Flavor.Reg, name: "left", `type`: vector.elem)
        let right = Value(kind: Flavor.Reg, name: "right", `type`: vector.elem)
        let output = Value(kind: Flavor.Reg, name: "output", `type`: vector.elem)
        functionsToEmit.add(Function(name: helper, abi: "", ret: vector.elem,
          params: @[left, right], blocks: @[Block(label: "entry", instrs: @[
            Instruction(kind: i.kind, dest: output, val: left, val2: right,
              span: i.span, trace: i.trace)],
            term: Instruction(kind: Opcode.Return, value: output))]))
  var failures = initTable[string, bool]()
  var zeroSizes = initTable[int, bool]()
  var textConstants: seq[string]
  var aggregateConstants: seq[string]
  var abiDefinitions: seq[string]
  var abiNames = initTable[pointer, string]()
  var sliceNumber = 0
  proc abiBoundary(t: node.Type): string =
    if t == nil or t.kind == Shape.Void: return ""
    if "atomic" in t.attributes:
      raise unsupported("volatile or attributed type " & t.label)
    if not (t.kind in {Shape.Int, Shape.Uint} and t.width > 64) and
        t.kind notin {Shape.Array, Shape.Vector, Shape.Struct,
        Shape.ExternStruct, Shape.TaggedUnion, Shape.ExternUnion,
        Shape.PackedStruct, Shape.Slice, Shape.Optional, Shape.Failable}:
      return boundary(t)
    discard base(t)
    let identity = cast[pointer](t)
    if identity in abiNames: return abiNames[identity]
    let name = ":qbe.abi." & $abiNames.len
    abiNames[identity] = name
    let layout = targetLayout.measure(t)
    if layout.size == 0:
      raise unsupported("zero-sized aggregate C ABI")
    if layout.alignment > 16:
      raise unsupported("aggregate C ABI alignment over 16")
    var components: seq[string]
    var cursor = 0
    proc member(field: node.Type; offset: int) =
      if offset < cursor: raise unsupported("overlapping aggregate C ABI field")
      if offset > cursor: components.add("b " & $(offset - cursor))
      let spelling = if (field.kind in {Shape.Int, Shape.Uint} and
          field.width > 64) or field.kind in {Shape.Array, Shape.Vector,
          Shape.Struct, Shape.ExternStruct, Shape.TaggedUnion,
          Shape.ExternUnion, Shape.PackedStruct, Shape.Slice,
          Shape.Optional, Shape.Failable}:
          abiBoundary(field)
        elif field.kind == Shape.Bool or
            (field.kind in {Shape.Int, Shape.Uint} and field.width == 8): "b"
        elif field.kind in {Shape.Int, Shape.Uint} and field.width == 16: "h"
        else: base(field)
      components.add(spelling)
      cursor = offset + targetLayout.measure(field).size
    case t.kind
    of Shape.Int, Shape.Uint:
      if t.width <= 64: raise unsupported("wide ABI integer width")
      components.add("l")
      components.add("l")
      cursor = layout.size
    of Shape.Array, Shape.Vector:
      let stride = targetLayout.measure(t.elem).size
      for index in 0..<t.width: member(t.elem, index * stride)
    of Shape.Struct, Shape.ExternStruct:
      var index = 0
      for field in t.fields.values:
        member(field, layout.offsets[index])
        inc index
    of Shape.TaggedUnion:
      var payload = node.Type(kind: Shape.ExternUnion, fields: t.variants)
      member(node.Type(kind: Shape.Uint, width: 32), 0)
      member(payload, layout.offsets[1])
    of Shape.ExternUnion:
      var variants: seq[string]
      for field in t.fields.values:
        let spelling = if field == nil: "b"
          elif (field.kind in {Shape.Int, Shape.Uint} and
            field.width > 64) or field.kind in {Shape.Array, Shape.Vector,
            Shape.Struct, Shape.ExternStruct, Shape.TaggedUnion,
            Shape.ExternUnion, Shape.PackedStruct, Shape.Slice,
            Shape.Optional, Shape.Failable}: abiBoundary(field)
          elif field.kind == Shape.Bool or
              (field.kind in {Shape.Int, Shape.Uint} and field.width <= 8): "b"
          elif field.kind in {Shape.Int, Shape.Uint} and field.width <= 16: "h"
          else: base(field)
        variants.add("{ " & spelling & " }")
      if variants.len == 0: variants.add("{ b }")
      abiDefinitions.add("type " & name & " = align " &
        $(if arm64Qbe: min(8, layout.alignment) else: layout.alignment) &
        " { " & variants.join(" ") & " }\n")
      return name
    of Shape.PackedStruct:
      components.add("b " & $layout.size)
      cursor = layout.size
    of Shape.Slice:
      member(node.Type(kind: Shape.Ptr, elem: t.elem), layout.offsets[0])
      member(node.Type(kind: Shape.Uint, width: 64), layout.offsets[1])
    of Shape.Optional, Shape.Failable:
      member(if t.kind == Shape.Optional: node.Type(kind: Shape.Bool)
        else: node.Type(kind: Shape.Error), 0)
      member(if t.elem.kind == Shape.Void: node.Type(kind: Shape.Bool)
        else: t.elem, layout.offsets[1])
    else: discard
    if cursor < layout.size: components.add("b " & $(layout.size - cursor))
    abiDefinitions.add("type " & name & " = align " &
      $(if arm64Qbe: min(8, layout.alignment) else: layout.alignment) &
      " { " & components.join(", ") & " }\n")
    name
  proc cstring(value: string): string =
    result = "$qbe.text." & $textConstants.len
    var bytes: seq[string]
    for character in value: bytes.add($ord(character))
    bytes.add("0")
    textConstants.add("data " & result & " = { b " & bytes.join(" ") & " }\n")
  var nativeContracts = initTable[string, Contract]()
  for contract in module.native:
    if contract.id in nativeContracts:
      raise unsupported("duplicate native contract '" & contract.id & "'")
    nativeContracts[contract.id] = contract
    if contract.stage != "@asm" or contract.abi notin ["foo:1", "c"]:
      raise unsupported("native contract '" & contract.id & "'")
  var functions = initTable[string, node.Function]()
  var externs = initTable[string, Extern]()
  var storage = initTable[string, node.Type]()
  var threadStorage = initTable[string, bool]()
  for fn in functionsToEmit:
    if fn.name in functions or fn.name in externs:
      raise unsupported("duplicate function '" & fn.name & "'")
    discard identifier(fn.name)
    if (fn.abi notin ["", "c"] and
        fn.abi notin bridgeAbi.foreignAbis) or fn.generics.len > 0:
      raise unsupported("function ABI or attributes on '" & fn.name & "'")
    for attribute in fn.attributes:
      if attribute in ["noinline", "start", "naked"] or
          attribute in interruptAttributes:
        discard
      elif attribute.startsWith("target_feature(\"") and
          attribute.endsWith("\")"):
        let feature = attribute[16 ..< attribute.len - 2]
        if feature.len == 0 or feature.anyIt(not
            (it.isLowerAscii or it.isDigit or it == '_')):
          raise unsupported("invalid target feature on '" & fn.name & "'")
        let normalized = feature.replace('_', '.')
        let profile = targetArch.profile(target, cpu)
        if normalized notin profile.features:
          raise unsupported("CPU feature " & feature & " is not enabled for " &
            profile.cpu & " in '" & fn.name & "'")
      elif attribute.startsWith("borrows(") or
          attribute.startsWith("releases("):
        discard
      else:
        raise unsupported("function attribute '" & attribute &
          "' on '" & fn.name & "'")
    if "start" in fn.attributes and not target.endsWith("-freestanding"):
      raise unsupported("startup requires a freestanding target")
    let interrupt = interruptMode(fn)
    if interrupt.len > 0:
      let targetMatches = case interrupt
        of "interrupt": target in ["riscv64-freestanding",
          "arm64-freestanding", "x64-freestanding"]
        of "interrupt_error_code": target == "x64-freestanding"
        else: target == "arm64-freestanding"
      let paramsMatch = if interrupt == "interrupt_error_code":
          fn.params.len == 1 and fn.params[0].type != nil and
            fn.params[0].type.kind == Shape.Uint and
            fn.params[0].type.width == 64
        else: fn.params.len == 0
      if not targetMatches or not paramsMatch or "naked" in fn.attributes or
          "start" in fn.attributes or fn.abi != "" or
          fn.ret == nil or fn.ret.kind != Shape.Void:
        raise unsupported("interrupt mode '" & interrupt &
          "' requires its freestanding target and handler signature")
    if "naked" in fn.attributes:
      if fn.abi in bridgeAbi.foreignAbis or fn.params.len > 0 or
          fn.ret == nil or fn.ret.kind != Shape.Void or
          fn.blocks.len != 1 or fn.blocks[0].term == nil or
          fn.blocks[0].term.kind != Opcode.Return or
          fn.blocks[0].instrs.len == 0:
        raise unsupported("setup-free function signature or body '" &
          fn.name & "'")
      for instruction in fn.blocks[0].instrs:
        if instruction == nil or instruction.kind != Opcode.Native or
            instruction.args.len > 0 or instruction.symbol notin
            nativeContracts:
          raise unsupported("setup-free body may contain only direct assembly")
    elif "start" in fn.attributes and (fn.ret == nil or
        fn.ret.kind != Shape.Void or fn.params.len > 0):
      raise unsupported("startup result type")
    functions[fn.name] = fn
  for ext in module.externs:
    if ext.name in functions or ext.name in externs:
      raise unsupported("external function '" & ext.name & "'")
    discard identifier(ext.name)
    externs[ext.name] = ext

  proc functionSymbol(fn: node.Function): string =
    if interruptMode(fn).len > 0:
      "foo.qbe.interrupt." & identifier(fn.name)
    elif fn.abi == "c": identifier(fn.name)
    elif fn.abi in bridgeAbi.foreignAbis:
      bridgeAbi.internalName(identifier(fn.name))
    else: "foo." & identifier(fn.name)

  proc staticFields(v: Value): seq[string] =
    let t = v.type
    let layout = targetLayout.measure(t)
    case t.kind
    of Shape.Int, Shape.Uint, Shape.Bool, Shape.Float:
      discard base(t)
      if t.kind in {Shape.Int, Shape.Uint} and t.width > 64:
        var items: seq[string]
        for value in wideBytes(v): items.add($value)
        return @["b " & items.join(" ")]
      let spelling = if t.kind == Shape.Bool or
          (t.kind in {Shape.Int, Shape.Uint} and t.width == 8): "b"
        elif t.kind in {Shape.Int, Shape.Uint} and t.width == 16: "h"
        else: base(t)
      result.add(spelling & " " & scalarLiteral(v))
      let used = if spelling == "b": 1 elif spelling == "h": 2
        elif spelling in ["w", "s"]: 4 else: 8
      if layout.size > used: result.add("z " & $(layout.size - used))
    of Shape.Slice:
      if t.elem == nil or t.elem.kind != Shape.Uint or t.elem.width != 8:
        raise unsupported("non-byte static slice")
      let bytes = node.bytes(v.name)
      let id = $sliceNumber
      inc sliceNumber
      var elements: seq[string]
      for value in bytes: elements.add($value)
      aggregateConstants.add("data $qbe.bytes." & id & " = { " &
        (if elements.len == 0: "z 1" else: "b " & elements.join(" ")) & " }\n")
      result = @["l $qbe.bytes." & id, "l " & $bytes.len]
    of Shape.Optional, Shape.Failable:
      if t.elem == nil: raise unsupported("static optional payload")
      if t.kind == Shape.Optional and v.name == "null":
        return @["z " & $layout.size]
      let tagSize = if t.kind == Shape.Optional: 1 else: 8
      result.add(if t.kind == Shape.Optional: "b 1" else: "l 0")
      let offset = layout.offsets[1]
      if offset > tagSize: result.add("z " & $(offset - tagSize))
      let inner = Value(kind: Flavor.Const, name: v.name, bits: v.bits,
        `type`: t.elem)
      if t.elem.kind == Shape.Void:
        result.add("b 0")
      else:
        result.add(staticFields(inner))
      let used = if t.elem.kind == Shape.Void: 1
        else: targetLayout.measure(t.elem).size
      if layout.size > offset + used:
        result.add("z " & $(layout.size - offset - used))
    of Shape.Array, Shape.Vector, Shape.Struct, Shape.ExternStruct,
        Shape.TaggedUnion, Shape.ExternUnion, Shape.PackedStruct:
      if canContainPointer(t) or v.bits.len != layout.size * 2 or
          v.bits.anyIt(it notin HexDigits):
        raise unsupported("aggregate static bit pattern")
      for index in 0..<layout.size:
        result.add("b " & $parseHexInt(v.bits[index * 2 .. index * 2 + 1]))
    else: raise unsupported("static initializer for " & t.label)

  for item in module.storage:
    discard identifier(item.name)
    if item.name in storage or item.name in functions or item.name in externs:
      raise unsupported("duplicate storage symbol '" & item.name & "'")
    let value = item.value
    if value.kind != Flavor.Const or value.type == nil:
      raise unsupported("static initializer for '" & item.name & "'")
    if item.thread and (target == "windows-x64" or
        target.endsWith("-freestanding")):
      raise unsupported("thread-local storage requires target TLS setup on " & target)
    let layout = targetLayout.measure(value.type)
    if layout.alignment > 16:
      raise unsupported("static alignment over 16")
    if item.alignment < 0 or item.alignment > 2097152 or
        (item.alignment > 0 and
          (item.alignment and (item.alignment - 1)) != 0):
      raise unsupported("static alignment must be a power of two at most 2 MiB")
    if item.section.len > 0:
      if not target.endsWith("-freestanding") or item.thread or
          item.section[0] != '.' or item.section.anyIt(not
            (it.isAlphaNumeric or it in {'_', '.', '-'})):
        raise unsupported("freestanding storage section name")
      result.add("section \"" & item.section & "\" \"aw\" ")
    result.add("export " & (if item.thread: "thread " else: "") &
      "data $storage." & item.name & " = align " &
      $min(if arm64Qbe: 8 else: 16,
        max(layout.alignment, item.alignment)) &
      " { " & staticFields(value).join(", ") & " }\n")
    storage[item.name] = value.type
    threadStorage[item.name] = item.thread

  proc literal(v: Value): string =
    if v.kind == Flavor.Const and v.type != nil and
        v.type.kind in {Shape.Int, Shape.Uint} and v.type.width > 64:
      let id = $aggregateConstants.len
      var items: seq[string]
      for value in wideBytes(v): items.add($value)
      aggregateConstants.add("data $qbe.integer." & id &
        " = align " & (if arm64Qbe: "8" else: "16") &
        " { b " & items.join(" ") & " }\n")
      return "$qbe.integer." & id
    if v.kind == Flavor.Const and v.type != nil and v.type.kind == Shape.Error:
      return cstring(v.name)
    if v.kind == Flavor.Const and v.type != nil and v.type.kind == Shape.Slice:
      discard base(v.type)
      if v.type.elem.kind != Shape.Uint or v.type.elem.width != 8:
        raise unsupported("non-byte slice constant")
      let data = node.bytes(v.name)
      let id = $sliceNumber
      inc sliceNumber
      var items: seq[string]
      for value in data: items.add($value)
      aggregateConstants.add("data $qbe.bytes." & id & " = { " &
        (if items.len == 0: "z 1" else: "b " & items.join(" ")) & " }\n")
      aggregateConstants.add("data $qbe.slice." & id &
        " = align 8 { l $qbe.bytes." & id & ", l " & $data.len & " }\n")
      return "$qbe.slice." & id
    if v.kind == Flavor.Const and v.type != nil and
        v.type.kind == Shape.Optional and v.name == "null":
      let layout = targetLayout.measure(v.type)
      let name = "$qbe.optional." & $aggregateConstants.len
      aggregateConstants.add("data " & name & " = align " &
        $(if arm64Qbe: min(8, layout.alignment) else: layout.alignment) &
        " { z " & $layout.size & " }\n")
      return name
    if v.kind != Flavor.Global: return scalarLiteral(v)
    if v.type != nil and v.type.kind == Shape.Function:
      discard base(v.type)
      if v.name in functions:
        let fn = functions[v.name]
        var signature = node.Type(kind: Shape.Function, abi: fn.abi, ret: fn.ret)
        for parameter in fn.params: signature.params.add(parameter.type)
        if not same(v.type, signature):
          raise unsupported("mismatched function value '" & v.name & "'")
        return "$" & (if fn.abi in bridgeAbi.foreignAbis:
          identifier(fn.name) else: functionSymbol(fn))
      if v.name in externs:
        let ext = externs[v.name]
        if not same(v.type, node.Type(kind: Shape.Function, abi: ext.abi,
            params: ext.params, ret: ext.ret)):
          raise unsupported("mismatched external function value '" & v.name & "'")
        if ext.abi == "runtime.codec":
          if v.name notin codecAdapters:
            raise unsupported("codec function adapter '" & v.name & "'")
          return "$foo." & codecAdapters[v.name]
        return "$" & identifier(ext.symbol)
      raise unsupported("unknown function value '" & v.name & "'")
    if v.name notin storage or v.type == nil or v.type.kind != Shape.Ptr or
        not same(v.type.elem, storage[v.name]):
      raise unsupported("unknown or mismatched global value '" & v.name & "'")
    (if threadStorage[v.name]: "thread " else: "") &
      "$storage." & identifier(v.name)

  for functionIndex in 0..<functionsToEmit.len:
    var fn = functionsToEmit[functionIndex]
    if "naked" in fn.attributes: continue
    if fn.blocks.len == 0: raise unsupported("function without blocks: " & fn.name)
    var labels = initTable[string, Block]()
    var incoming = initTable[string, seq[tuple[label, bridge: string,
      args: seq[Value]]]]()
    var bridges = initTable[(string, string), string]()
    var bridgeTargets: seq[tuple[label, destination: string]]
    for section in fn.blocks:
      discard identifier(section.label)
      if section.label in labels: raise unsupported("duplicate block '" & section.label & "'")
      labels[section.label] = section
    proc edge(origin, destination: string; args: seq[Value]) =
      if destination notin labels: raise unsupported("unknown block '" & destination & "'")
      let bridge = "qbe.edge." & $bridgeTargets.len
      bridges[(origin, destination)] = bridge
      bridgeTargets.add((bridge, destination))
      incoming.mgetOrPut(destination, @[]).add((origin, bridge, args))
    for section in fn.blocks:
      if section.term == nil: raise unsupported("block without terminator")
      case section.term.kind
      of Opcode.Jump: edge(section.label, section.term.label, section.term.args)
      of Opcode.Cjump:
        if section.term.yes == section.term.no:
          raise unsupported("branch with two edges to the same block")
        edge(section.label, section.term.yes, section.term.positive)
        edge(section.label, section.term.no, section.term.negative)
      of Opcode.Return, Opcode.Panic: discard
      else: raise unsupported("terminator " & $section.term.kind)
    if incoming.getOrDefault(fn.blocks[0].label).len > 0:
      raise unsupported("branch to function entry")
    var guardNumber = 0
    var stackSlots: seq[string]
    var entryOffset = 0
    proc guard(predicate, message: string; i: Instruction): string =
      inc guardNumber
      let bad = "qbe.guard.bad." & $guardNumber
      let good = "qbe.guard.good." & $guardNumber
      failures[message] = true
      result.add("\tjnz " & predicate & ", @" & bad & ", @" & good & "\n")
      if target.endsWith("-freestanding"):
        result.add("@" & bad & "\n\thlt\n@" & good & "\n")
      else:
        result.add("@" & bad & "\n\tcall $foo_qbe_trace(l " &
          cstring(i.trace) & ", l " & cstring(i.span.file) & ", l " &
          $i.span.start & ")\n\tcall $foo_qbe_panic(l $qbe_error_" &
          message & ")\n\thlt\n@" & good & "\n")
    proc temporary(): string =
      inc guardNumber
      "%qbe.check." & $guardNumber
    proc address(pointer: string; offset: int): tuple[code, value: string] =
      if offset == 0: return ("", pointer)
      let projected = temporary()
      ("\t" & projected & " =l add " & pointer & ", " & $offset & "\n",
        projected)
    proc aggregateSlot(t: node.Type; destination: string): string =
      let layout = targetLayout.measure(t)
      if layout.alignment > 16: raise unsupported("aggregate alignment over 16")
      let size = max(1, layout.size)
      if arm64Qbe and layout.alignment > 8:
        let raw = temporary()
        let rounded = temporary()
        stackSlots.add("\t" & raw & " =l alloc8 " & $(size + 15) &
          "\n\t" & rounded & " =l add " & raw & ", 15\n\t" &
          destination & " =l and " & rounded & ", -16\n")
      else:
        let align = if layout.alignment > 8: 16
          elif layout.alignment > 4: 8 else: 4
        stackSlots.add("\t" & destination & " =l alloc" & $align &
          " " & $size & "\n")
      if layout.size > 0:
        zeroSizes[layout.size] = true
        result.add("\tblit $qbe.zero." & $layout.size & ", " &
          destination & ", " & $layout.size & "\n")
    proc storeField(t: node.Type; value: Value; destination: string): string =
      if not same(t, value.type): raise unsupported("aggregate field type")
      if (t.kind in {Shape.Int, Shape.Uint} and t.width > 64) or
          t.kind in {Shape.Array, Shape.Vector, Shape.Struct, Shape.ExternStruct,
          Shape.TaggedUnion, Shape.ExternUnion, Shape.PackedStruct,
          Shape.Slice, Shape.Optional, Shape.Failable}:
        result.add("\tblit " & literal(value) & ", " & destination &
          ", " & $targetLayout.measure(t).size & "\n")
      else:
        result.add("\t" & storeOp(t) & " " & literal(value) & ", " &
          destination & "\n")
    proc vectorElement(t: node.Type): node.Type =
      if t == nil or t.kind != Shape.Vector or t.width < 1 or t.elem == nil or
          t.elem.kind notin {Shape.Int, Shape.Uint, Shape.Float, Shape.Bool,
            Shape.Ptr}:
        raise unsupported("vector requires positive width and scalar lanes")
      discard base(t)
      t.elem
    proc laneAddress(v: Value; index: int): tuple[code, value: string] =
      address(literal(v), index * targetLayout.measure(v.type.elem).size)
    proc vectorArithmetic(i: Instruction): string =
      let element = vectorElement(i.dest.type)
      if cast[pointer](i) notin vectorHelpers:
        raise unsupported("elementwise vector arithmetic helper")
      result.add(aggregateSlot(i.dest.type, literal(i.dest)))
      for index in 0..<i.dest.type.width:
        let leftCell = laneAddress(i.val, index)
        let rightCell = laneAddress(i.val2, index)
        let outputCell = laneAddress(i.dest, index)
        let left = temporary()
        let right = temporary()
        let output = temporary()
        let typ = base(element)
        result.add(leftCell.code & rightCell.code & outputCell.code)
        result.add("\t" & left & " =" & typ & " " & loadOp(element) &
          " " & leftCell.value & "\n")
        result.add("\t" & right & " =" & typ & " " & loadOp(element) &
          " " & rightCell.value & "\n")
        result.add("\t" & output & " =" & typ & " call $foo." &
          vectorHelpers[cast[pointer](i)] & "(" & typ & " " & left &
          ", " & typ & " " & right & ")\n")
        result.add("\t" & storeOp(element) & " " & output & ", " &
          outputCell.value & "\n")
    proc integerOperands(i: Instruction): tuple[code, left, right: string] =
      if i.val.type == nil or i.val.type.kind notin {Shape.Int, Shape.Uint} or
          not same(i.val.type, i.val2.type):
        raise unsupported("integer operand types")
      result.left = literal(i.val)
      result.right = literal(i.val2)
      if inlineNarrowIntegers and i.val.type.width notin [32, 64]:
        let t = i.val.type
        let typ = base(t)
        let shift = (if t.width <= 32: 32 else: 64) - t.width
        proc canonical(value: string): tuple[code, value: string] =
          result.value = temporary()
          if t.kind == Shape.Uint:
            result.code.add("\t" & result.value & " =" & typ & " and " &
              value & ", " & $((1'u64 shl t.width) - 1) & "\n")
          else:
            let shifted = temporary()
            result.code.add("\t" & shifted & " =" & typ & " shl " &
              value & ", " & $shift & "\n\t" & result.value & " =" & typ &
              " sar " & shifted & ", " & $shift & "\n")
        let left = canonical(result.left)
        let right = canonical(result.right)
        result.code.add(left.code & right.code)
        result.left = left.value
        result.right = right.value
      elif i.val.type.width <= 32:
        let left = temporary()
        let right = temporary()
        let extension = if i.val.type.kind == Shape.Int: "extsw" else: "extuw"
        result.code.add("\t" & left & " =l " & extension & " " &
          result.left & "\n\t" & right & " =l " & extension & " " &
          result.right & "\n")
        result.left = left
        result.right = right
    proc narrowRange(t: node.Type; value: string; i: Instruction;
        widened = false): string =
      let typ = if widened: "l" else: base(t)
      let bad = temporary()
      if t.kind == Shape.Uint:
        result.add("\t" & bad & " =w cugt" & typ & " " & value &
          ", " & $((1'u64 shl t.width) - 1) & "\n")
      else:
        let low = temporary()
        let high = temporary()
        let minimum = -(1'i64 shl (t.width - 1))
        let maximum = (1'i64 shl (t.width - 1)) - 1
        result.add("\t" & low & " =w cslt" & typ & " " & value &
          ", " & $minimum & "\n\t" & high & " =w csgt" & typ &
          " " & value & ", " & $maximum & "\n\t" & bad &
          " =w or " & low & ", " & high & "\n")
      result.add(guard(bad, "IntegerOverflow", i))
    proc checkedInteger(i: Instruction): string =
      let t = i.dest.type
      if t == nil or t.kind notin {Shape.Int, Shape.Uint} or
          t.width notin 1..64 or not same(t, i.val.type) or
          not same(t, i.val2.type):
        raise unsupported("checked integer operand types")
      let operands = integerOperands(i)
      if inlineNarrowIntegers and t.width notin [32, 64]:
        let typ = base(t)
        let left = operands.left
        let right = operands.right
        let output = literal(i.dest)
        result.add(operands.code)
        if i.kind in {Opcode.Div, Opcode.Remainder}:
          let zero = temporary()
          result.add("\t" & zero & " =w ceq" & typ & " " & right &
            ", 0\n")
          result.add(guard(zero, "DivisionByZero", i))
        if i.kind == Opcode.Mul and t.width > 32:
          let product = temporary()
          let zero = temporary()
          let quotient = temporary()
          let mismatch = temporary()
          inc guardNumber
          let nonzero = "qbe.narrow.mul.nonzero." & $guardNumber
          let done = "qbe.narrow.mul.done." & $guardNumber
          result.add("\t" & product & " =l mul " & left & ", " &
            right & "\n\t" & zero & " =w ceql " & right &
            ", 0\n\tjnz " & zero & ", @" & done & ", @" &
            nonzero & "\n@" & nonzero & "\n\t" & quotient &
            " =l " & (if t.kind == Shape.Int: "div" else: "udiv") &
            " " & product & ", " & right & "\n\t" & mismatch &
            " =w cnel " & quotient & ", " & left & "\n")
          result.add(guard(mismatch, "IntegerOverflow", i))
          result.add("\tjmp @" & done & "\n@" & done & "\n")
          result.add(narrowRange(t, product, i))
          result.add("\t" & output & " =l copy " & product & "\n")
        elif i.kind == Opcode.Mul:
          let extendedLeft = temporary()
          let extendedRight = temporary()
          let product = temporary()
          let extension = if t.kind == Shape.Int: "extsw" else: "extuw"
          result.add("\t" & extendedLeft & " =l " & extension &
            " " & left & "\n\t" & extendedRight & " =l " & extension &
            " " & right & "\n\t" & product & " =l mul " &
            extendedLeft & ", " & extendedRight & "\n")
          result.add(narrowRange(t, product, i, widened = true))
          result.add("\t" & output & " =w copy " & product & "\n")
        else:
          let value = temporary()
          let operation = case i.kind
            of Opcode.Add: "add"
            of Opcode.Sub: "sub"
            of Opcode.Div: (if t.kind == Shape.Int: "div" else: "udiv")
            of Opcode.Remainder: (if t.kind == Shape.Int: "rem" else: "urem")
            else: raise unsupported("checked integer operation")
          result.add("\t" & value & " =" & typ & " " & operation &
            " " & left & ", " & right & "\n")
          if i.kind != Opcode.Remainder:
            result.add(narrowRange(t, value, i))
          result.add("\t" & output & " =" & typ & " copy " & value & "\n")
        return
      let slot = temporary()
      let status = temporary()
      let overflow = temporary()
      let zero = temporary()
      let raw = temporary()
      let operation = case i.kind
        of Opcode.Add: 0
        of Opcode.Sub: 1
        of Opcode.Mul: 2
        of Opcode.Div: 3
        of Opcode.Remainder: 4
        else: raise unsupported("checked integer operation")
      result.add(operands.code)
      stackSlots.add("\t" & slot & " =l alloc8 8\n")
      result.add("\t" & status & " =w call $foo_qbe_integer64(l " & operands.left & ", l " &
        operands.right & ", w " & $t.width & ", w " &
        (if t.kind == Shape.Int: "1" else: "0") & ", w " &
        $operation & ", l " & slot & ")\n")
      result.add("\t" & overflow & " =w ceqw " & status & ", 1\n")
      result.add(guard(overflow, "IntegerOverflow", i))
      result.add("\t" & zero & " =w ceqw " & status & ", 2\n")
      result.add(guard(zero, "DivisionByZero", i))
      result.add("\t" & raw & " =l loadl " & slot & "\n\t" &
        literal(i.dest) & " =" & base(t) & " copy " & raw & "\n")
    proc integerComparison(i: Instruction): string =
      if i.dest.type == nil or i.dest.type.kind != Shape.Bool or
          i.val.type == nil or i.val.type.kind notin {Shape.Int, Shape.Uint} or
          i.val.type.width notin 1..64:
        raise unsupported("integer comparison type")
      let operands = integerOperands(i)
      if inlineNarrowIntegers and i.val.type.width notin [32, 64]:
        let typ = base(i.val.type)
        let op = case i.op
          of "equals": "eq"
          of "does not equal": "ne"
          of "is less than": "lt"
          of "is at most": "le"
          of "is greater than": "gt"
          of "is at least": "ge"
          else: raise unsupported("integer comparison operation")
        let predicate = if op in ["eq", "ne"]: "c" & op & typ
          else: "c" & (if i.val.type.kind == Shape.Int: "s" else: "u") &
            op & typ
        return operands.code & "\t" & literal(i.dest) & " =w " &
          predicate & " " & operands.left & ", " & operands.right & "\n"
      let order = temporary()
      let predicate = case i.op
        of "equals": "ceqw"
        of "does not equal": "cnew"
        of "is less than": "csltw"
        of "is at most": "cslew"
        of "is greater than": "csgtw"
        of "is at least": "csgew"
        else: raise unsupported("integer comparison operation")
      result.add(operands.code)
      result.add("\t" & order &
        " =w call $foo_qbe_integer_compare64(l " & operands.left &
        ", l " & operands.right & ", w " & $i.val.type.width &
        ", w " & (if i.val.type.kind == Shape.Int: "1" else: "0") &
        ")\n\t" & literal(i.dest) & " =w " & predicate & " " & order &
        ", 0\n")
    proc wideInteger(i: Instruction): string =
      let t = i.dest.type
      if t == nil or t.kind notin {Shape.Int, Shape.Uint} or
          t.width notin 65..128 or not same(t, i.val.type) or
          not same(t, i.val2.type):
        raise unsupported("wide integer operand types")
      let operation = case i.kind
        of Opcode.Add: 0
        of Opcode.Sub: 1
        of Opcode.Mul: 2
        of Opcode.Div: 3
        of Opcode.Remainder: 4
        else: raise unsupported("wide integer operation")
      let status = temporary()
      let overflow = temporary()
      let zero = temporary()
      result.add(aggregateSlot(t, literal(i.dest)))
      result.add("\t" & status &
        " =w call $foo_qbe_integer128(l " & literal(i.val) &
        ", l " & literal(i.val2) & ", w " & $t.width &
        ", w " & (if t.kind == Shape.Int: "1" else: "0") &
        ", w " & $operation & ", l " & literal(i.dest) & ")\n")
      result.add("\t" & overflow & " =w ceqw " & status & ", 1\n")
      result.add(guard(overflow, "IntegerOverflow", i))
      result.add("\t" & zero & " =w ceqw " & status & ", 2\n")
      result.add(guard(zero, "DivisionByZero", i))
    proc wideComparison(i: Instruction): string =
      if i.dest.type == nil or i.dest.type.kind != Shape.Bool or
          i.val.type == nil or i.val.type.kind notin {Shape.Int, Shape.Uint} or
          i.val.type.width notin 65..128 or
          not same(i.val.type, i.val2.type):
        raise unsupported("wide comparison type")
      let predicate = case i.op
        of "equals": "ceqw"
        of "does not equal": "cnew"
        of "is less than": "csltw"
        of "is at most": "cslew"
        of "is greater than": "csgtw"
        of "is at least": "csgew"
        else: raise unsupported("wide comparison operation")
      let order = temporary()
      result.add("\t" & order &
        " =w call $foo_qbe_integer_compare128(l " & literal(i.val) &
        ", l " & literal(i.val2) & ", w " & $i.val.type.width &
        ", w " & (if i.val.type.kind == Shape.Int: "1" else: "0") &
        ")\n\t" & literal(i.dest) & " =w " & predicate & " " & order &
        ", 0\n")
    proc integerBit(i: Instruction): string =
      let t = i.dest.type
      if t == nil or t.kind notin {Shape.Int, Shape.Uint} or
          t.width notin 1..128 or not same(t, i.val.type):
        raise unsupported("bitwise operand types")
      let operation = case i.op
        of "and": 0
        of "or": 1
        of "xor": 2
        of "not": 3
        of "shl": 4
        of "lshr": 5
        of "ashr": 6
        of "set": 7
        of "clear": 8
        of "toggle": 9
        else: raise unsupported("bit operation '" & i.op & "'")
      let binary = operation in 0..2
      let shifted = operation >= 4
      if binary and not same(t, i.val2.type) or
          operation == 3 and i.val2.type != nil or
          shifted and (i.val2.type == nil or
            i.val2.type.kind notin {Shape.Int, Shape.Uint} or
            i.val2.type.width notin 1..128) or
          operation == 6 and t.kind != Shape.Int:
        raise unsupported("bitwise operand types")
      var count = "0"
      if shifted:
        if i.val2.type.width > 64:
          let highCell = address(literal(i.val2), 8)
          let high = temporary()
          let bad = temporary()
          let low = temporary()
          result.add(highCell.code & "\t" & high & " =l loadl " &
            highCell.value & "\n\t" & bad & " =w cnel " & high &
            ", 0\n")
          result.add(guard(bad, "ShiftOutOfBounds", i))
          result.add("\t" & low & " =l loadl " & literal(i.val2) & "\n")
          count = low
        elif i.val2.type.width <= 32:
          let extended = temporary()
          result.add("\t" & extended & " =l " &
            (if i.val2.type.kind == Shape.Int: "extsw" else: "extuw") &
            " " & literal(i.val2) & "\n")
          count = extended
        else:
          count = literal(i.val2)
      let signed = if t.kind == Shape.Int: "1" else: "0"
      let status = temporary()
      if t.width > 64:
        let right = if binary: literal(i.val2) else: literal(i.val)
        result.add(aggregateSlot(t, literal(i.dest)))
        result.add("\t" & status &
          " =w call $foo_qbe_integer_bit128(l " & literal(i.val) &
          ", l " & right & ", w " & $t.width & ", w " & signed &
          ", w " & $operation & ", l " & count & ", l " &
          literal(i.dest) & ")\n")
      else:
        proc extended(value: Value): tuple[code, value: string] =
          if t.width > 32: return ("", literal(value))
          result.value = temporary()
          let operation = if t.kind == Shape.Int: "extsw" else: "extuw"
          result.code.add("\t" & result.value & " =l " & operation & " " &
            literal(value) & "\n")
        let left = extended(i.val)
        let right = if binary: extended(i.val2) else: left
        let slot = temporary()
        let raw = temporary()
        result.add(left.code & (if binary: right.code else: ""))
        stackSlots.add("\t" & slot & " =l alloc8 8\n")
        result.add("\t" & status & " =w call $foo_qbe_integer_bit64(l " & left.value & ", l " &
          right.value & ", w " & $t.width & ", w " & signed &
          ", w " & $operation & ", l " & count & ", l " &
          slot & ")\n")
        let bad = temporary()
        result.add("\t" & bad & " =w cnew " & status & ", 0\n")
        result.add(guard(bad, "ShiftOutOfBounds", i))
        result.add("\t" & raw & " =l loadl " & slot & "\n\t" &
          literal(i.dest) & " =" & base(t) & " copy " & raw & "\n")
        return
      let bad = temporary()
      result.add("\t" & bad & " =w cnew " & status & ", 0\n")
      result.add(guard(bad, "ShiftOutOfBounds", i))
    proc aggregateComparison(i: Instruction): string =
      if i.dest.type == nil or i.dest.type.kind != Shape.Bool or
          not same(i.val.type, i.val2.type) or
          i.val.type.kind notin {Shape.Array, Shape.Vector, Shape.Struct,
            Shape.ExternStruct, Shape.PackedStruct, Shape.TaggedUnion}:
        raise unsupported("aggregate comparison type")
      let ordering = i.op notin ["equals", "does not equal"]
      if i.op notin ["equals", "does not equal", "is less than",
          "is at most", "is greater than", "is at least"]:
        raise unsupported("aggregate comparison operation")
      var equal = temporary()
      var less = temporary()
      var greater = temporary()
      result.add("\t" & equal & " =w copy 1\n")
      if ordering:
        result.add("\t" & less & " =w copy 0\n")
        result.add("\t" & greater & " =w copy 0\n")
      proc packedFields(t: node.Type; byteOffset, bitOffset: int): string =
        if t.kind == Shape.PackedStruct:
          let layout = targetLayout.measure(t)
          var index = 0
          for field in t.fields.values:
            result.add(packedFields(field, byteOffset,
              bitOffset + layout.offsets[index]))
            inc index
          return
        if t.kind notin {Shape.Int, Shape.Uint, Shape.Bool}:
          raise unsupported("packed comparison field " & t.label)
        let leftCell = address(literal(i.val), byteOffset)
        let rightCell = address(literal(i.val2), byteOffset)
        let relation = temporary()
        let fieldEqual = temporary()
        let nextEqual = temporary()
        result.add(leftCell.code & rightCell.code)
        result.add("\t" & relation &
          " =w call $foo_qbe_packed_compare(l " & leftCell.value &
          ", l " & rightCell.value & ", l " & $bitOffset &
          ", l " & $targetLayout.packedBits(t) & ", w " &
          (if t.kind == Shape.Int: "1" else: "0") & ")\n")
        result.add("\t" & fieldEqual & " =w ceqw " & relation & ", 0\n")
        if ordering:
          for operation in ["is less than", "is greater than"]:
            let predicate = temporary()
            let selected = temporary()
            let accumulated = temporary()
            let current = if operation == "is less than": less else: greater
            result.add("\t" & predicate & " =w " &
              (if operation == "is less than": "csltw " else: "csgtw ") &
              relation & ", 0\n")
            result.add("\t" & selected & " =w and " & equal & ", " &
              predicate & "\n")
            result.add("\t" & accumulated & " =w or " & current & ", " &
              selected & "\n")
            if operation == "is less than": less = accumulated
            else: greater = accumulated
        result.add("\t" & nextEqual & " =w and " & equal & ", " &
          fieldEqual & "\n")
        equal = nextEqual
      proc fields(t: node.Type; offset: int): string =
        case t.kind
        of Shape.Array, Shape.Vector:
          let stride = targetLayout.measure(t.elem).size
          for index in 0..<t.width:
            result.add(fields(t.elem, offset + index * stride))
        of Shape.Struct, Shape.ExternStruct:
          let layout = targetLayout.measure(t)
          var index = 0
          for field in t.fields.values:
            result.add(fields(field, offset + layout.offsets[index]))
            inc index
        of Shape.PackedStruct:
          result.add(packedFields(t, offset, 0))
        of Shape.Optional:
          if ordering or t.elem == nil or
              t.elem.kind notin {Shape.Int, Shape.Uint, Shape.Bool, Shape.Ptr} or
              (t.elem.kind in {Shape.Int, Shape.Uint} and
                t.elem.width notin [8, 16, 32, 64]):
            raise unsupported("aggregate comparison field " & t.label)
          let leftCell = address(literal(i.val), offset)
          let rightCell = address(literal(i.val2), offset)
          let leftPayload = address(leftCell.value,
            targetLayout.measure(t).offsets[1])
          let rightPayload = address(rightCell.value,
            targetLayout.measure(t).offsets[1])
          let leftPresent = temporary()
          let rightPresent = temporary()
          let samePresence = temporary()
          let absent = temporary()
          let leftValue = temporary()
          let rightValue = temporary()
          let sameValue = temporary()
          let accepted = temporary()
          let fieldEqual = temporary()
          let nextEqual = temporary()
          result.add(leftCell.code & rightCell.code & leftPayload.code &
            rightPayload.code)
          result.add("\t" & leftPresent & " =w loadub " & leftCell.value &
            "\n\t" & rightPresent & " =w loadub " & rightCell.value &
            "\n\t" & samePresence & " =w ceqw " & leftPresent & ", " &
            rightPresent & "\n\t" & absent & " =w ceqw " & leftPresent &
            ", 0\n\t" & leftValue & " =" & base(t.elem) & " " &
            loadOp(t.elem) & " " & leftPayload.value & "\n\t" &
            rightValue & " =" & base(t.elem) & " " & loadOp(t.elem) &
            " " & rightPayload.value & "\n\t" & sameValue & " =w ceq" &
            base(t.elem) & " " & leftValue & ", " & rightValue &
            "\n\t" & accepted & " =w or " & absent & ", " & sameValue &
            "\n\t" & fieldEqual & " =w and " & samePresence & ", " &
            accepted & "\n\t" & nextEqual & " =w and " & equal & ", " &
            fieldEqual & "\n")
          equal = nextEqual
        of Shape.Int, Shape.Uint, Shape.Float, Shape.Bool, Shape.Ptr:
          if ordering and t.kind == Shape.Ptr:
            raise unsupported("ordered pointer aggregate comparison")
          let leftCell = address(literal(i.val), offset)
          let rightCell = address(literal(i.val2), offset)
          if t.kind in {Shape.Int, Shape.Uint} and
              t.width notin [8, 16, 32, 64]:
            let order = temporary()
            let fieldEqual = temporary()
            let nextEqual = temporary()
            result.add(leftCell.code & rightCell.code)
            if t.width > 64:
              result.add("\t" & order &
                " =w call $foo_qbe_integer_compare128(l " &
                leftCell.value & ", l " & rightCell.value & ", w " &
                $t.width & ", w " &
                (if t.kind == Shape.Int: "1" else: "0") & ")\n")
            else:
              let left = temporary()
              let right = temporary()
              let wideLeft = temporary()
              let wideRight = temporary()
              result.add("\t" & left & " =" & base(t) & " " &
                loadOp(t) & " " & leftCell.value & "\n")
              result.add("\t" & right & " =" & base(t) & " " &
                loadOp(t) & " " & rightCell.value & "\n")
              if t.width <= 32:
                let extension = if t.kind == Shape.Int: "extsw" else: "extuw"
                result.add("\t" & wideLeft & " =l " & extension & " " &
                  left & "\n\t" & wideRight & " =l " & extension & " " &
                  right & "\n")
              else:
                result.add("\t" & wideLeft & " =l copy " & left &
                  "\n\t" & wideRight & " =l copy " & right & "\n")
              result.add("\t" & order &
                " =w call $foo_qbe_integer_compare64(l " & wideLeft &
                ", l " & wideRight & ", w " & $t.width & ", w " &
                (if t.kind == Shape.Int: "1" else: "0") & ")\n")
            result.add("\t" & fieldEqual & " =w ceqw " & order & ", 0\n")
            if ordering:
              for operation in ["is less than", "is greater than"]:
                let relation = temporary()
                let selected = temporary()
                let accumulated = temporary()
                let current = if operation == "is less than": less else: greater
                result.add("\t" & relation & " =w " &
                  (if operation == "is less than": "csltw " else: "csgtw ") &
                  order & ", 0\n")
                result.add("\t" & selected & " =w and " & equal &
                  ", " & relation & "\n")
                result.add("\t" & accumulated & " =w or " & current &
                  ", " & selected & "\n")
                if operation == "is less than": less = accumulated
                else: greater = accumulated
            result.add("\t" & nextEqual & " =w and " & equal & ", " &
              fieldEqual & "\n")
            equal = nextEqual
            return
          let left = temporary()
          let right = temporary()
          let compared = temporary()
          let nextEqual = temporary()
          let typ = base(t)
          result.add(leftCell.code & rightCell.code)
          result.add("\t" & left & " =" & typ & " " & loadOp(t) &
            " " & leftCell.value & "\n")
          result.add("\t" & right & " =" & typ & " " & loadOp(t) &
            " " & rightCell.value & "\n")
          let equalOp = comparison(Instruction(kind: Opcode.Compare,
            op: "equals", val: Value(`type`: t), val2: Value(`type`: t),
            dest: Value(`type`: node.Type(kind: Shape.Bool))))
          result.add("\t" & compared & " =w " & equalOp & " " & left &
            ", " & right & "\n")
          if ordering:
            for operation in ["is less than", "is greater than"]:
              let predicate = comparison(Instruction(kind: Opcode.Compare,
                op: operation, val: Value(`type`: t),
                val2: Value(`type`: t),
                dest: Value(`type`: node.Type(kind: Shape.Bool))))
              let relation = temporary()
              let selected = temporary()
              let accumulated = temporary()
              let current = if operation == "is less than": less else: greater
              result.add("\t" & relation & " =w " & predicate & " " &
                left & ", " & right & "\n")
              result.add("\t" & selected & " =w and " & equal & ", " &
                relation & "\n")
              result.add("\t" & accumulated & " =w or " & current & ", " &
                selected & "\n")
              if operation == "is less than": less = accumulated
              else: greater = accumulated
          result.add("\t" & nextEqual & " =w and " & equal & ", " &
            compared & "\n")
          equal = nextEqual
        else: raise unsupported("aggregate comparison field " & t.label)
      if i.val.type.kind == Shape.TaggedUnion:
        if ordering: raise unsupported("ordered choice comparison")
        let leftTag = temporary()
        let rightTag = temporary()
        let sameTag = temporary()
        let slot = temporary()
        let layout = targetLayout.measure(i.val.type)
        stackSlots.add("\t" & slot & " =l alloc4 4\n")
        inc guardNumber
        let done = "qbe.choice.done." & $guardNumber
        let dispatch = "qbe.choice.dispatch." & $guardNumber
        result.add("\tstorew 0, " & slot & "\n\t" & leftTag &
          " =w loaduw " & literal(i.val) & "\n\t" & rightTag &
          " =w loaduw " & literal(i.val2) & "\n\t" & sameTag &
          " =w ceqw " & leftTag & ", " & rightTag & "\n\tjnz " &
          sameTag & ", @" & dispatch & ", @" & done & "\n@" &
          dispatch & "\n")
        var index = 0
        for variant in i.val.type.variants.values:
          inc guardNumber
          let selected = temporary()
          let active = "qbe.choice.active." & $guardNumber
          let next = "qbe.choice.next." & $guardNumber
          result.add("\t" & selected & " =w ceqw " & leftTag & ", " &
            $index & "\n\tjnz " & selected & ", @" & active &
            ", @" & next & "\n@" & active & "\n")
          if variant == nil or variant.kind == Shape.Void:
            result.add("\tstorew 1, " & slot & "\n")
          else:
            equal = temporary()
            result.add("\t" & equal & " =w copy 1\n")
            result.add(fields(variant, layout.offsets[1]))
            result.add("\tstorew " & equal & ", " & slot & "\n")
          result.add("\tjmp @" & done & "\n@" & next & "\n")
          inc index
        let matched = temporary()
        let output = literal(i.dest)
        result.add("\tjmp @" & done & "\n@" & done & "\n\t" &
          matched & " =w loaduw " & slot & "\n\t" & output &
          " =w " & (if i.op == "equals": "copy " else: "ceqw ") &
          matched & (if i.op == "equals": "" else: ", 0") & "\n")
        return
      result.add(fields(i.val.type, 0))
      let output = literal(i.dest)
      case i.op
      of "equals": result.add("\t" & output & " =w copy " & equal & "\n")
      of "does not equal":
        result.add("\t" & output & " =w ceqw " & equal & ", 0\n")
      of "is less than": result.add("\t" & output & " =w copy " & less & "\n")
      of "is greater than":
        result.add("\t" & output & " =w copy " & greater & "\n")
      of "is at most", "is at least":
        let relation = if i.op == "is at most": less else: greater
        result.add("\t" & output & " =w or " & relation & ", " & equal & "\n")
      else: discard
    proc indexedVectorCell(source: Value; indices: Value; lane: int;
        i: Instruction): tuple[code, value: string] =
      let indexType = indices.type.elem
      if indexType.kind notin {Shape.Int, Shape.Uint} or
          indexType.width notin [32, 64]:
        raise unsupported("vector index lane type")
      let indexCell = laneAddress(indices, lane)
      let raw = temporary()
      result.code.add(indexCell.code)
      result.code.add("\t" & raw & " =" & base(indexType) & " " &
        loadOp(indexType) & " " & indexCell.value & "\n")
      let wideIndex = if indexType.width == 64: raw else:
          let extended = temporary()
          result.code.add("\t" & extended & " =l " &
            (if indexType.kind == Shape.Int: "extsw" else: "extuw") &
            " " & raw & "\n")
          extended
      let bad = temporary()
      result.code.add("\t" & bad & " =w cugel " & wideIndex & ", " &
        $source.type.width & "\n")
      result.code.add(guard(bad, "IndexOutOfBounds", i))
      let offset = temporary()
      result.code.add("\t" & offset & " =l mul " & wideIndex & ", " &
        $targetLayout.measure(source.type.elem).size & "\n")
      result.value = temporary()
      result.code.add("\t" & result.value & " =l add " & literal(source) &
        ", " & offset & "\n")
    var params: seq[string]
    for parameter in fn.params:
      params.add(abiBoundary(parameter.type) & " " & literal(parameter))
    var owned = false
    var regionSlots = initTable[string, string]()
    var regionOrder: seq[string]
    var deferred: seq[Instruction]
    var deferFlags = initTable[pointer, string]()
    var deferChildren = initTable[pointer, tuple[first, last: int]]()
    proc collectInstruction(instruction: Instruction) =
      if instruction == nil: raise unsupported("missing nested instruction")
      if instruction.kind == Opcode.Defer:
        if instruction.fallback == nil:
          raise unsupported("deferred cleanup body")
      let firstChild = deferred.len
      if instruction.fallback != nil:
        for child in instruction.fallback.instrs: collectInstruction(child)
      for section in instruction.fallbackBlocks:
        for child in section.instrs: collectInstruction(child)
      if instruction.kind == Opcode.Defer:
        deferChildren[cast[pointer](instruction)] =
          (first: firstChild, last: deferred.high)
        let flag = "%qbe.defer." & $deferred.len
        deferFlags[cast[pointer](instruction)] = flag
        deferred.add(instruction)
      if instruction.kind == Opcode.Alloc and instruction.op != "slot":
        owned = true
      if instruction.kind in {Opcode.Region, Opcode.Allocate}:
        if instruction.region.len == 0:
          raise unsupported("region identifier")
        if instruction.region notin regionSlots:
          regionSlots[instruction.region] = "%qbe.region." & $regionOrder.len
          regionOrder.add(instruction.region)
    for section in fn.blocks:
      for instruction in section.instrs: collectInstruction(instruction)
    var cleanupLimit = deferred.high
    var lowerInstruction: proc(i: Instruction): string {.closure.}
    var lowerFallback: proc(i: Instruction; expected: node.Type):
      tuple[code: string, exits: seq[tuple[label: string, value: Value]]] {.closure.}
    proc runDeferred(first, last: int; error: string): string =
      for index in countdown(last, first):
        let item = deferred[index]
        let flag = deferFlags[cast[pointer](item)]
        let active = temporary()
        result.add("\t" & active & " =w loadub " & flag & "\n")
        let predicate = if item.error:
            let combined = temporary()
            result.add("\t" & combined & " =w and " & active & ", " &
              error & "\n")
            combined
          else: active
        inc guardNumber
        let run = "qbe.cleanup.run." & $guardNumber
        let done = "qbe.cleanup.done." & $guardNumber
        result.add("\tjnz " & predicate & ", @" & run & ", @" & done &
          "\n@" & run & "\n\tstoreb 0, " & flag & "\n")
        let previousLimit = cleanupLimit
        cleanupLimit = index - 1
        let graph = lowerFallback(item, nil)
        result.add(graph.code)
        let finish = "qbe.cleanup.exit." & $guardNumber
        for exit in graph.exits:
          result.add("@" & exit.label & "\n\tjmp @" & finish & "\n")
        result.add("@" & finish & "\n")
        let children = deferChildren[cast[pointer](item)]
        if children.last >= children.first:
          result.add(runDeferred(children.first, children.last, error))
        cleanupLimit = previousLimit
        result.add("\tjmp @" & done & "\n@" & done & "\n")
    proc release(error: string): string =
      result.add(runDeferred(0, cleanupLimit, error))
      for region in regionOrder:
        result.add("\tcall $foo_qbe_free(l " & regionSlots[region] & ")\n")
      if owned: result.add("\tcall $foo_qbe_free(l %qbe.owner)\n")
    proc copyProjection(t: node.Type; destination, source: string): string =
      if (t.kind in {Shape.Int, Shape.Uint} and t.width > 64) or
          t.kind in {Shape.Array, Shape.Vector, Shape.Struct,
          Shape.ExternStruct, Shape.Slice, Shape.Optional, Shape.Failable}:
        result.add(aggregateSlot(t, destination))
        result.add("\tblit " & source & ", " & destination & ", " &
          $targetLayout.measure(t).size & "\n")
      else:
        result.add("\t" & destination & " =" & base(t) & " " &
          loadOp(t) & " " & source & "\n")
    result.add((if fn.public: "export " else: "") & "function " &
      abiBoundary(fn.ret) & " $" & functionSymbol(fn) & "(" & params.join(", ") & ") {\n")
    for section in fn.blocks:
      result.add("@" & section.label & "\n")
      if section == fn.blocks[0]: entryOffset = result.len
      if section == fn.blocks[0] and owned:
        result.add("\t%qbe.owner =l alloc8 8\n\tstorel 0, %qbe.owner\n")
      if section == fn.blocks[0]:
        for region in regionOrder:
          let slot = regionSlots[region]
          result.add("\t" & slot & " =l alloc8 8\n\tstorel 0, " & slot & "\n")
        for item in deferred:
          let flag = deferFlags[cast[pointer](item)]
          result.add("\t" & flag & " =l alloc4 1\n\tstoreb 0, " &
            flag & "\n")
      let predecessors = incoming.getOrDefault(section.label)
      for index, parameter in section.params:
        if parameter.type != nil and parameter.type.kind == Shape.Memory: continue
        if predecessors.len == 0: raise unsupported("block parameter without predecessor")
        var sources: seq[string]
        for predecessor in predecessors:
          if index >= predecessor.args.len or
              not same(parameter.type, predecessor.args[index].type):
            raise unsupported("block parameter type or arity at '" & section.label & "'")
          sources.add("@" & predecessor.bridge & " " & literal(predecessor.args[index]))
        result.add("\t" & literal(parameter) & " =" & base(parameter.type) &
          " phi " & sources.join(", ") & "\n")
      for i in section.instrs:
        if i == nil: raise unsupported("missing instruction")
        if i.kind != Opcode.Phi: continue
        if predecessors.len == 0 or i.blocks.len != predecessors.len:
          raise unsupported("phi predecessor count at '" & section.label & "'")
        var sources: seq[string]
        for predecessor in predecessors:
          var found = false
          for source in i.blocks:
            if source.label != predecessor.label: continue
            if found or not same(i.dest.type, source.value.type):
              raise unsupported("phi edge type or duplicate at '" & section.label & "'")
            sources.add("@" & predecessor.bridge & " " & literal(source.value))
            found = true
          if not found: raise unsupported("phi missing edge at '" & section.label & "'")
        result.add("\t" & literal(i.dest) & " =" & base(i.dest.type) &
          " phi " & sources.join(", ") & "\n")
      for predecessor in predecessors:
        if predecessor.args.len != section.params.len:
          raise unsupported("block argument arity at '" & section.label & "'")
      lowerFallback = proc(i: Instruction; expected: node.Type):
          tuple[code: string, exits: seq[tuple[label: string, value: Value]]] =
        if i.fallback == nil: raise unsupported("missing fallback entry")
        var sections = @[i.fallback]
        sections.add(i.fallbackBlocks)
        var local = initTable[string, Block]()
        inc guardNumber
        let prefix = "qbe.fallback." & $guardNumber & "."
        for section in sections:
          if section == nil or section.label.len == 0 or
              section.label in local:
            raise unsupported("duplicate or missing fallback block")
          discard identifier(section.label)
          local[section.label] = section
        for parameter in i.fallback.params:
          if parameter.type == nil or parameter.type.kind != Shape.Memory:
            raise unsupported("fallback entry parameter")
        var edges: seq[tuple[source, target, bridge: string]]
        var incoming = initTable[string, seq[tuple[source, bridge: string,
          args: seq[Value]]]]()
        var bridges = initTable[(string, string), string]()
        proc edge(source, target: string; args: seq[Value]) =
          if target notin local or (source, target) in bridges:
            raise unsupported("invalid fallback branch to '" & target & "'")
          let params = local[target].params.filterIt(
            it.type != nil and it.type.kind != Shape.Memory)
          let values = args.filterIt(
            it.type != nil and it.type.kind != Shape.Memory)
          if params.len != values.len:
            raise unsupported("fallback block argument arity at '" & target & "'")
          for index, parameter in params:
            if not same(parameter.type, values[index].type):
              raise unsupported("fallback block argument type at '" & target & "'")
          inc guardNumber
          let bridge = "qbe.fallback.edge." & $guardNumber
          bridges[(source, target)] = bridge
          edges.add((source, target, bridge))
          incoming.mgetOrPut(target, @[]).add((source, bridge, values))
        for section in sections:
          if section.term == nil and expected != nil:
            raise unsupported("fallback block without terminator")
          let term = if section.term == nil:
              Instruction(kind: Opcode.Return) else: section.term
          case term.kind
          of Opcode.Jump: edge(section.label, term.label, term.args)
          of Opcode.Cjump:
            if term.yes == term.no:
              raise unsupported("fallback branch with identical targets")
            edge(section.label, term.yes, term.positive)
            edge(section.label, term.no, term.negative)
          of Opcode.Return, Opcode.Panic: discard
          else: raise unsupported("fallback terminator " & $term.kind)
        result.code.add("\tjmp @" & prefix & i.fallback.label & "\n")
        for section in sections:
          result.code.add("@" & prefix & section.label & "\n")
          let predecessors = incoming.getOrDefault(section.label)
          var parameterIndex = 0
          for parameter in section.params:
            if parameter.type != nil and parameter.type.kind == Shape.Memory:
              continue
            if predecessors.len == 0:
              raise unsupported("fallback parameter without predecessor")
            var sources: seq[string]
            for predecessor in predecessors:
              sources.add("@" & predecessor.bridge & " " &
                literal(predecessor.args[parameterIndex]))
            result.code.add("\t" & literal(parameter) & " =" &
              base(parameter.type) & " phi " & sources.join(", ") & "\n")
            inc parameterIndex
          for child in section.instrs:
            if child == nil or child.attributes.len > 0:
              raise unsupported("fallback instruction")
            if child.kind != Opcode.Phi: continue
            if predecessors.len == 0 or child.blocks.len != predecessors.len:
              raise unsupported("fallback phi predecessor count")
            var sources: seq[string]
            for predecessor in predecessors:
              var found = false
              for source in child.blocks:
                if source.label != predecessor.source: continue
                if found or not same(source.value.type, child.dest.type):
                  raise unsupported("fallback phi edge type or duplicate")
                sources.add("@" & predecessor.bridge & " " & literal(source.value))
                found = true
              if not found: raise unsupported("fallback phi missing edge")
            result.code.add("\t" & literal(child.dest) & " =" &
              base(child.dest.type) & " phi " & sources.join(", ") & "\n")
          for child in section.instrs:
            if child.kind != Opcode.Phi:
              result.code.add(lowerInstruction(child))
          let term = if section.term == nil:
              Instruction(kind: Opcode.Return) else: section.term
          if term.attributes.len > 0:
            raise unsupported("fallback terminator attributes")
          case term.kind
          of Opcode.Jump:
            result.code.add("\tjmp @" &
              bridges[(section.label, term.label)] & "\n")
          of Opcode.Cjump:
            if term.cond.type == nil or term.cond.type.kind != Shape.Bool:
              raise unsupported("fallback branch condition")
            result.code.add("\tjnz " & literal(term.cond) & ", @" &
              bridges[(section.label, term.yes)] & ", @" &
              bridges[(section.label, term.no)] & "\n")
          of Opcode.Return:
            if expected == nil:
              if term.value.type != nil and term.value.type.kind != Shape.Void:
                raise unsupported("value returned from deferred cleanup")
            elif expected.kind == Shape.Void:
              if term.value.type != nil and term.value.type.kind != Shape.Void:
                raise unsupported("value returned from void fallback")
            elif not same(expected, term.value.type):
              raise unsupported("catch fallback result type")
            inc guardNumber
            let exit = "qbe.fallback.return." & $guardNumber
            result.exits.add((exit, term.value))
            result.code.add("\tjmp @" & exit & "\n")
          of Opcode.Panic:
            if target.endsWith("-freestanding"):
              result.code.add("\thlt\n")
            else:
              result.code.add("\tcall $foo_qbe_trace(l " &
                cstring(term.trace) & ", l " & cstring(term.span.file) &
                ", l " & $term.span.start & ")\n")
              result.code.add("\tcall $foo_qbe_panic(l " &
                cstring(term.msg) & ")\n\thlt\n")
          else: discard
        for edge in edges:
          result.code.add("@" & edge.bridge & "\n\tjmp @" &
            prefix & edge.target & "\n")
      lowerInstruction = proc(i: Instruction): string =
        if i == nil: raise unsupported("missing instruction")
        if i.attributes.len > 0:
          raise unsupported("instruction attributes in '" & fn.name & "'")
        case i.kind
        of Opcode.Phi: discard
        of Opcode.Splat:
          let element = vectorElement(i.dest.type)
          if not same(element, i.val.type):
            raise unsupported("vector splat element type")
          result.add(aggregateSlot(i.dest.type, literal(i.dest)))
          for index in 0..<i.dest.type.width:
            let cell = laneAddress(i.dest, index)
            result.add(cell.code)
            result.add(storeField(element, i.val, cell.value))
        of Opcode.Shuffle:
          let element = vectorElement(i.dest.type)
          discard vectorElement(i.val.type)
          discard vectorElement(i.val2.type)
          if not same(element, i.val.type.elem) or
              not same(element, i.val2.type.elem) or
              i.mask.len != i.dest.type.width:
            raise unsupported("vector shuffle types or mask width")
          result.add(aggregateSlot(i.dest.type, literal(i.dest)))
          for index, selected in i.mask:
            if selected < 0 or
                selected >= i.val.type.width + i.val2.type.width:
              raise unsupported("shuffle lane out of bounds")
            let source = if selected < i.val.type.width: i.val else: i.val2
            let sourceIndex = if selected < i.val.type.width:
                selected else: selected - i.val.type.width
            let fromCell = laneAddress(source, sourceIndex)
            let toCell = laneAddress(i.dest, index)
            let lane = temporary()
            result.add(fromCell.code & toCell.code)
            result.add("\t" & lane & " =" & base(element) & " " &
              loadOp(element) & " " & fromCell.value & "\n")
            result.add("\t" & storeOp(element) & " " & lane & ", " &
              toCell.value & "\n")
        of Opcode.Select:
          let element = vectorElement(i.dest.type)
          discard vectorElement(i.val.type)
          discard vectorElement(i.val2.type)
          let maskElement = vectorElement(i.cond.type)
          if not same(element, i.val.type.elem) or
              not same(element, i.val2.type.elem) or
              i.val.type.width != i.dest.type.width or
              i.val2.type.width != i.dest.type.width or
              i.cond.type.width != i.dest.type.width or
              maskElement.kind != Shape.Bool:
            raise unsupported("vector select operand types")
          result.add(aggregateSlot(i.dest.type, literal(i.dest)))
          for index in 0..<i.dest.type.width:
            let maskCell = laneAddress(i.cond, index)
            let trueCell = laneAddress(i.val, index)
            let falseCell = laneAddress(i.val2, index)
            let outputCell = laneAddress(i.dest, index)
            let mask = temporary()
            let yesValue = temporary()
            let noValue = temporary()
            let selected = temporary()
            let yesLabel = "qbe.select.yes." & $guardNumber
            let noLabel = "qbe.select.no." & $guardNumber
            let endLabel = "qbe.select.end." & $guardNumber
            result.add(maskCell.code & trueCell.code & falseCell.code &
              outputCell.code)
            result.add("\t" & mask & " =w loadub " & maskCell.value & "\n")
            result.add("\t" & yesValue & " =" & base(element) & " " &
              loadOp(element) & " " & trueCell.value & "\n")
            result.add("\t" & noValue & " =" & base(element) & " " &
              loadOp(element) & " " & falseCell.value & "\n")
            result.add("\tjnz " & mask & ", @" & yesLabel & ", @" &
              noLabel & "\n@" & yesLabel & "\n\tjmp @" & endLabel &
              "\n@" & noLabel & "\n\tjmp @" & endLabel & "\n@" &
              endLabel & "\n")
            result.add("\t" & selected & " =" & base(element) & " phi @" &
              yesLabel & " " & yesValue & ", @" & noLabel & " " &
              noValue & "\n")
            result.add("\t" & storeOp(element) & " " & selected & ", " &
              outputCell.value & "\n")
        of Opcode.Gather, Opcode.Scatter:
          let element = vectorElement(i.val.type)
          let indexElement = vectorElement(i.val2.type)
          discard vectorElement(i.dest.type)
          if indexElement.kind notin {Shape.Int, Shape.Uint} or
              indexElement.width notin [32, 64] or
              not same(element, i.dest.type.elem):
            raise unsupported("vector indexed operand types")
          if i.kind == Opcode.Gather:
            if i.dest.type.width != i.val2.type.width:
              raise unsupported("gather result width")
          else:
            if i.dest.type.width != i.val.type.width or i.args.len != 1 or
                i.args[0].type == nil or
                i.args[0].type.kind != Shape.Vector or
                i.args[0].type.width != i.val2.type.width or
                not same(i.args[0].type.elem, element):
              raise unsupported("scatter update vector")
          result.add(aggregateSlot(i.dest.type, literal(i.dest)))
          if i.kind == Opcode.Scatter:
            result.add("\tblit " & literal(i.val) & ", " & literal(i.dest) &
              ", " & $targetLayout.measure(i.val.type).size & "\n")
          for index in 0..<i.val2.type.width:
            let sourceCell = if i.kind == Opcode.Gather:
                let cell = indexedVectorCell(i.val, i.val2, index, i)
                result.add(cell.code)
                cell.value
              else:
                let cell = laneAddress(i.args[0], index)
                result.add(cell.code)
                cell.value
            let targetCell = if i.kind == Opcode.Gather:
                let cell = laneAddress(i.dest, index)
                result.add(cell.code)
                cell.value
              else:
                let cell = indexedVectorCell(i.dest, i.val2, index, i)
                result.add(cell.code)
                cell.value
            let value = temporary()
            result.add("\t" & value & " =" & base(element) & " " &
              loadOp(element) & " " & sourceCell & "\n")
            result.add("\t" & storeOp(element) & " " & value & ", " &
              targetCell & "\n")
        of Opcode.Reduce:
          let element = vectorElement(i.val.type)
          let operation = if i.reduction.len == 0: "Add" else: i.reduction
          if not same(element, i.dest.type) or
              element.kind notin {Shape.Int, Shape.Uint, Shape.Float} or
              operation notin ["Add", "Mul", "Min", "Max", "And", "Or", "Xor"] or
              (element.kind == Shape.Float and operation in ["And", "Or", "Xor"]) or
              (element.kind in {Shape.Int, Shape.Uint} and
                element.width notin [32, 64]):
            raise unsupported("vector reduction type or operation")
          let typ = base(element)
          let firstCell = laneAddress(i.val, 0)
          var accumulator = temporary()
          result.add(firstCell.code)
          result.add("\t" & accumulator & " =" & typ & " " &
            loadOp(element) & " " & firstCell.value & "\n")
          for index in 1..<i.val.type.width:
            let cell = laneAddress(i.val, index)
            let next = temporary()
            let output = temporary()
            result.add(cell.code)
            result.add("\t" & next & " =" & typ & " " & loadOp(element) &
              " " & cell.value & "\n")
            if operation in ["And", "Or", "Xor"]:
              result.add("\t" & output & " =" & typ & " " &
                operation.toLowerAscii() & " " & accumulator & ", " & next & "\n")
            elif operation in ["Min", "Max"]:
              let predicate = comparison(Instruction(kind: Opcode.Compare,
                op: (if operation == "Min": "is less than"
                  else: "is greater than"), val: Value(`type`: element),
                val2: Value(`type`: element),
                dest: Value(`type`: node.Type(kind: Shape.Bool))))
              let selected = temporary()
              inc guardNumber
              let yes = "qbe.reduce.yes." & $guardNumber
              let no = "qbe.reduce.no." & $guardNumber
              let done = "qbe.reduce.done." & $guardNumber
              result.add("\t" & selected & " =w " & predicate & " " &
                accumulator & ", " & next & "\n")
              result.add("\tjnz " & selected & ", @" & yes & ", @" & no &
                "\n@" & yes & "\n\tjmp @" & done & "\n@" & no &
                "\n\tjmp @" & done & "\n@" & done & "\n")
              result.add("\t" & output & " =" & typ & " phi @" & yes &
                " " & accumulator & ", @" & no & " " & next & "\n")
            elif element.kind == Shape.Float:
              result.add("\t" & output & " =" & typ & " " &
                operation.toLowerAscii() & " " & accumulator & ", " & next & "\n")
            elif operation == "Add":
              result.add("\t" & output & " =" & typ & " add " &
                accumulator & ", " & next & "\n")
              let bad = temporary()
              if element.kind == Shape.Uint:
                result.add("\t" & bad & " =w cult" & typ & " " & output &
                  ", " & accumulator & "\n")
              else:
                let a = temporary()
                let b = temporary()
                let both = temporary()
                result.add("\t" & a & " =" & typ & " xor " & accumulator &
                  ", " & output & "\n")
                result.add("\t" & b & " =" & typ & " xor " & next & ", " &
                  output & "\n")
                result.add("\t" & both & " =" & typ & " and " & a & ", " &
                  b & "\n")
                result.add("\t" & bad & " =w cslt" & typ & " " & both &
                  ", 0\n")
              result.add(guard(bad, "IntegerOverflow", i))
            elif typ == "w":
              let extension = if element.kind == Shape.Int: "extsw" else: "extuw"
              let wideA = temporary()
              let wideB = temporary()
              let product = temporary()
              let roundTrip = temporary()
              let bad = temporary()
              result.add("\t" & wideA & " =l " & extension & " " &
                accumulator & "\n")
              result.add("\t" & wideB & " =l " & extension & " " & next & "\n")
              result.add("\t" & product & " =l mul " & wideA & ", " &
                wideB & "\n")
              result.add("\t" & output & " =w copy " & product & "\n")
              result.add("\t" & roundTrip & " =l " & extension & " " &
                output & "\n")
              result.add("\t" & bad & " =w cnel " & product & ", " &
                roundTrip & "\n")
              result.add(guard(bad, "IntegerOverflow", i))
            else:
              inc guardNumber
              let zeroLabel = "qbe.reduce.zero." & $guardNumber
              let nonzeroLabel = "qbe.reduce.nonzero." & $guardNumber
              let doneLabel = "qbe.reduce.product." & $guardNumber
              let zero = temporary()
              result.add("\t" & output & " =l mul " & accumulator & ", " &
                next & "\n")
              result.add("\t" & zero & " =w ceql " & next & ", 0\n")
              result.add("\tjnz " & zero & ", @" & zeroLabel & ", @" &
                nonzeroLabel & "\n@" & zeroLabel & "\n\tjmp @" &
                doneLabel & "\n@" & nonzeroLabel & "\n")
              if element.kind == Shape.Int:
                let minimum = temporary()
                let negative = temporary()
                let special = temporary()
                result.add("\t" & minimum & " =w ceql " & accumulator &
                  ", -9223372036854775808\n")
                result.add("\t" & negative & " =w ceql " & next & ", -1\n")
                result.add("\t" & special & " =w and " & minimum & ", " &
                  negative & "\n")
                result.add(guard(special, "IntegerOverflow", i))
              let quotient = temporary()
              let bad = temporary()
              result.add("\t" & quotient & " =l " &
                (if element.kind == Shape.Int: "div" else: "udiv") & " " &
                output & ", " & next & "\n")
              result.add("\t" & bad & " =w cnel " & quotient & ", " &
                accumulator & "\n")
              result.add(guard(bad, "IntegerOverflow", i))
              result.add("\tjmp @" & doneLabel & "\n@" & doneLabel & "\n")
            accumulator = output
          result.add("\t" & literal(i.dest) & " =" & typ & " copy " &
            accumulator & "\n")
        of Opcode.Construct:
          let t = i.dest.type
          if t == nil or t.kind notin
              {Shape.Array, Shape.Vector, Shape.Struct, Shape.ExternStruct,
               Shape.TaggedUnion, Shape.ExternUnion, Shape.PackedStruct,
               Shape.Slice, Shape.Optional, Shape.Failable}:
            raise unsupported("construction type")
          discard base(t)
          let destination = literal(i.dest)
          result.add(aggregateSlot(t, destination))
          if t.kind in {Shape.Array, Shape.Vector}:
            if i.args.len != t.width: raise unsupported("sequence construction arity")
            let stride = targetLayout.measure(t.elem).size
            for index, value in i.args:
              let cell = address(destination, index * stride)
              result.add(cell.code)
              result.add(storeField(t.elem, value, cell.value))
          elif t.kind in {Shape.Struct, Shape.ExternStruct}:
            if i.args.len != t.fields.len:
              raise unsupported("record construction arity")
            let layout = targetLayout.measure(t)
            var index = 0
            for field in t.fields.values:
              let cell = address(destination, layout.offsets[index])
              result.add(cell.code)
              result.add(storeField(field, i.args[index], cell.value))
              inc index
          elif t.kind == Shape.PackedStruct:
            if i.args.len != t.fields.len:
              raise unsupported("packed construction arity")
            let offsets = targetLayout.measure(t).offsets
            var index = 0
            for field in t.fields.values:
              if not same(field, i.args[index].type):
                raise unsupported("packed construction field type")
              let width = targetLayout.packedBits(field)
              if field.kind == Shape.PackedStruct or
                  (field.kind in {Shape.Int, Shape.Uint} and width > 64):
                result.add("\tcall $foo_qbe_packed_copy(l " & destination &
                  ", l " & $offsets[index] & ", l " &
                  literal(i.args[index]) & ", l " & $width & ")\n")
              elif field.kind in {Shape.Int, Shape.Uint, Shape.Bool} and
                  width <= 64:
                let raw = if field.kind == Shape.Bool or width <= 32:
                    let extended = temporary()
                    result.add("\t" & extended & " =l extuw " &
                      literal(i.args[index]) & "\n")
                    extended
                  else: literal(i.args[index])
                result.add("\tcall $foo_qbe_packed_write(l " & destination &
                  ", l " & $offsets[index] & ", l " & $width &
                  ", l " & raw & ")\n")
              else: raise unsupported("packed field representation")
              inc index
          elif t.kind == Shape.TaggedUnion:
            if i.field notin t.variants or i.args.len > 1:
              raise unsupported("tagged union construction")
            var tag = 0
            for name in t.variants.keys:
              if name == i.field: break
              inc tag
            result.add("\tstorew " & $tag & ", " & destination & "\n")
            if i.args.len == 1:
              let payload = address(destination,
                targetLayout.measure(t).offsets[1])
              result.add(payload.code)
              result.add(storeField(t.variants[i.field], i.args[0],
                payload.value))
          elif t.kind == Shape.ExternUnion:
            if i.field notin t.fields or i.args.len != 1:
              raise unsupported("C union construction")
            result.add(storeField(t.fields[i.field], i.args[0], destination))
          elif t.kind == Shape.Slice:
            if i.op notin ["", "sequence"]:
              raise unsupported("slice construction mode")
            if i.args.len > 0:
              let backingType = node.Type(kind: Shape.Array, elem: t.elem,
                width: i.args.len)
              let backing = temporary()
              result.add(aggregateSlot(backingType, backing))
              let stride = targetLayout.measure(t.elem).size
              for index, value in i.args:
                let cell = address(backing, index * stride)
                result.add(cell.code)
                result.add(storeField(t.elem, value, cell.value))
              result.add("\tstorel " & backing & ", " & destination & "\n")
            let count = address(destination, targetLayout.measure(t).offsets[1])
            result.add(count.code)
            result.add("\tstorel " & $i.args.len & ", " & count.value & "\n")
          elif t.kind == Shape.Optional:
            if i.args.len > 1: raise unsupported("optional construction arity")
            if i.args.len == 1:
              result.add("\tstoreb 1, " & destination & "\n")
              if t.elem.kind != Shape.Void:
                let payload = address(destination,
                  targetLayout.measure(t).offsets[1])
                result.add(payload.code)
                result.add(storeField(t.elem, i.args[0], payload.value))
          else:
            if i.op != "error" or i.args.len != 1 or
                i.args[0].type == nil or i.args[0].type.kind != Shape.Error:
              raise unsupported("failable construction mode")
            result.add("\tstorel " & literal(i.args[0]) & ", " &
              destination & "\n")
        of Opcode.Embed:
          if i.dest.type == nil or i.dest.type.kind != Shape.Slice or
              i.dest.type.elem == nil or i.dest.type.elem.kind != Shape.Uint or
              i.dest.type.elem.width != 8:
            raise unsupported("embedded resource type")
          let origin = if i.span.file.len > 0: i.span.file else: source
          let path = absolutePath(i.path, parentDir(absolutePath(origin)))
          var content: seq[byte]
          for character in readFile(path): content.add(byte(character.ord))
          let constant = Value(kind: Flavor.Const, name: node.quoted(content),
            `type`: i.dest.type)
          result.add("\t" & literal(i.dest) & " =l copy " & literal(constant) & "\n")
        of Opcode.Reflect:
          if i.argument == nil or i.dest.type == nil or
              i.dest.type.kind notin {Shape.Struct, Shape.ExternStruct}:
            raise unsupported("reflection type")
          let t = i.dest.type
          let destination = literal(i.dest)
          result.add(aggregateSlot(t, destination))
          let layout = targetLayout.measure(t)
          let reflected = targetLayout.measure(i.argument)
          let bare = node.Type(kind: i.argument.kind, elem: i.argument.elem,
            width: i.argument.width)
          var index = 0
          for name, field in t.fields:
            let cell = address(destination, layout.offsets[index])
            result.add(cell.code)
            var value: Value
            if name in ["size", "alignment"]:
              if field.kind notin {Shape.Int, Shape.Uint}:
                raise unsupported("reflection numeric field")
              value = Value(kind: Flavor.Const, `type`: field,
                name: $(if name == "size": reflected.size else: reflected.alignment))
            else:
              if field.kind != Shape.Slice or field.elem == nil or
                  field.elem.kind != Shape.Uint or field.elem.width != 8:
                raise unsupported("reflection text field")
              let label = if name == "name": i.argument.label else: bare.label
              var data: seq[byte]
              for character in label: data.add(byte(character.ord))
              value = Value(kind: Flavor.Const, `type`: field,
                name: node.quoted(data))
            result.add(storeField(field, value, cell.value))
            inc index
        of Opcode.Extract:
          let source = if i.val.type != nil: i.val else: i.ptr
          if source.type == nil: raise unsupported("projection source")
          let t = if source.type.kind == Shape.Ptr: source.type.elem else: source.type
          if t == nil: raise unsupported("projection source type")
          if t.kind == Shape.PackedStruct:
            if i.field notin t.fields or i.op == "address":
              raise unsupported("packed field projection")
            let field = t.fields[i.field]
            if not same(i.dest.type, field):
              raise unsupported("packed field result type")
            let width = targetLayout.packedBits(field)
            let offset = targetLayout.measure(t).offsets[
              targetLayout.position(t, i.field)]
            if field.kind == Shape.PackedStruct:
              result.add(aggregateSlot(field, literal(i.dest)))
              result.add("\tcall $foo_qbe_packed_extract(l " &
                literal(i.dest) & ", l " & literal(source) &
                ", l " & $offset & ", l " & $width & ")\n")
              return
            if field.kind in {Shape.Int, Shape.Uint} and width > 64:
              result.add(aggregateSlot(field, literal(i.dest)))
              result.add("\tcall $foo_qbe_packed_extract_integer(l " &
                literal(i.dest) & ", l " & literal(source) &
                ", l " & $offset & ", l " & $width & ", w " &
                (if field.kind == Shape.Int: "1" else: "0") & ")\n")
              return
            if field.kind notin {Shape.Int, Shape.Uint, Shape.Bool} or
                width > 64:
              raise unsupported("packed field representation")
            let raw = temporary()
            result.add("\t" & raw &
              " =l call $foo_qbe_packed_read(l " & literal(source) &
              ", l " & $offset & ", l " & $width & ")\n")
            var value = raw
            if field.kind == Shape.Int and width < 64:
              let left = temporary()
              let signed = temporary()
              result.add("\t" & left & " =l shl " & raw & ", " &
                $(64 - width) & "\n")
              result.add("\t" & signed & " =l sar " & left & ", " &
                $(64 - width) & "\n")
              value = signed
            result.add("\t" & literal(i.dest) & " =" & base(field) &
              " copy " & value & "\n")
            return
          var field: node.Type
          var displacement = 0
          if t.kind in {Shape.Struct, Shape.ExternStruct} and i.field in t.fields:
            field = t.fields[i.field]
            displacement = targetLayout.measure(t).offsets[
              targetLayout.position(t, i.field)]
          elif t.kind == Shape.ExternUnion and i.field in t.fields:
            field = t.fields[i.field]
          elif t.kind == Shape.TaggedUnion and i.field == "tag":
            field = node.Type(kind: Shape.Uint, width: 32)
          elif t.kind == Shape.TaggedUnion and i.field in t.variants:
            field = t.variants[i.field]
            displacement = targetLayout.measure(t).offsets[1]
          elif t.kind == Shape.Optional and i.field in ["present", "value"]:
            field = if i.field == "present": node.Type(kind: Shape.Bool) else: t.elem
            if i.field == "value": displacement = targetLayout.measure(t).offsets[1]
          elif t.kind == Shape.Failable and i.field in ["failed", "value"]:
            field = if i.field == "failed": node.Type(kind: Shape.Bool) else: t.elem
            if i.field == "value": displacement = targetLayout.measure(t).offsets[1]
          else: raise unsupported("aggregate field '" & i.field & "'")
          if field.kind == Shape.Void:
            if i.op == "address" or not same(i.dest.type, field):
              raise unsupported("void field projection")
            return
          let projected = address(literal(source), displacement)
          result.add(projected.code)
          if t.kind == Shape.Failable and i.field == "failed":
            if i.dest.type == nil or i.dest.type.kind != Shape.Bool:
              raise unsupported("failable failure predicate")
            let errorPointer = temporary()
            result.add("\t" & errorPointer & " =l loadl " & projected.value & "\n")
            result.add("\t" & literal(i.dest) & " =w cnel " & errorPointer &
              ", 0\n")
            return
          if i.op == "address":
            if i.dest.type == nil or i.dest.type.kind != Shape.Ptr or
                not same(i.dest.type.elem, field):
              raise unsupported("record field address type")
            result.add("\t" & literal(i.dest) & " =l copy " & projected.value & "\n")
          elif same(i.dest.type, field):
            if (field.kind in {Shape.Int, Shape.Uint} and field.width > 64) or
                field.kind in {Shape.Array, Shape.Vector, Shape.Struct,
                Shape.ExternStruct, Shape.TaggedUnion, Shape.ExternUnion,
                Shape.PackedStruct, Shape.Slice, Shape.Optional,
                Shape.Failable}:
              result.add(aggregateSlot(field, literal(i.dest)))
              result.add("\tblit " & projected.value & ", " & literal(i.dest) &
                ", " & $targetLayout.measure(field).size & "\n")
            else:
              result.add("\t" & literal(i.dest) & " =" & base(field) & " " &
                loadOp(field) & " " & projected.value & "\n")
          else: raise unsupported("record field value type")
        of Opcode.Length:
          if i.val.type == nil or i.val.type.kind notin
              {Shape.Array, Shape.Vector, Shape.Slice} or
              i.dest.type == nil or i.dest.type.kind notin {Shape.Int, Shape.Uint}:
            raise unsupported("length type")
          if i.dest.type.width > 64:
            result.add(aggregateSlot(i.dest.type, literal(i.dest)))
            let count = if i.val.type.kind == Shape.Slice:
                let cell = address(literal(i.val),
                  targetLayout.measure(i.val.type).offsets[1])
                let loaded = temporary()
                result.add(cell.code)
                result.add("\t" & loaded & " =l loadl " & cell.value & "\n")
                loaded
              else: $i.val.type.width
            result.add("\tcall $foo_qbe_integer_extend128(l " &
              literal(i.dest) & ", l " & count & ", w 64, w 0)\n")
            return
          if i.val.type.kind == Shape.Slice:
            let count = address(literal(i.val),
              targetLayout.measure(i.val.type).offsets[1])
            result.add(count.code)
            result.add("\t" & literal(i.dest) & " =" & base(i.dest.type) &
              " " & (if base(i.dest.type) == "w": "loadw" else: "loadl") &
              " " & count.value & "\n")
          else:
            result.add("\t" & literal(i.dest) & " =" & base(i.dest.type) &
              " copy " & $i.val.type.width & "\n")
        of Opcode.Index:
          let sequence = i.val.type
          if sequence == nil or sequence.kind notin
              {Shape.Array, Shape.Vector, Shape.Slice, Shape.Ptr} or
              sequence.elem == nil or
              i.val2.type == nil or i.val2.type.kind notin {Shape.Int, Shape.Uint} or
              i.val2.type.width > 64 or
              i.op notin ["", "value", "address"]:
            raise unsupported("index operand types")
          let element = sequence.elem
          let indexType = base(i.val2.type)
          let index = if indexType == "l": literal(i.val2) else:
            let extended = temporary()
            result.add("\t" & extended & " =l " &
              (if i.val2.type.kind == Shape.Int: "extsw" else: "extuw") &
              " " & literal(i.val2) & "\n")
            extended
          if sequence.kind != Shape.Ptr:
            let count = if sequence.kind == Shape.Slice:
                let countAddress = address(literal(i.val),
                  targetLayout.measure(sequence).offsets[1])
                let loaded = temporary()
                result.add(countAddress.code)
                result.add("\t" & loaded & " =l loadl " & countAddress.value & "\n")
                loaded
              else: $sequence.width
            let bad = temporary()
            result.add("\t" & bad & " =w cugel " & index & ", " & count & "\n")
            result.add(guard(bad, "IndexOutOfBounds", i))
          let data = if sequence.kind == Shape.Slice:
              let loaded = temporary()
              result.add("\t" & loaded & " =l loadl " & literal(i.val) & "\n")
              loaded
            else: literal(i.val)
          let bytes = temporary()
          let cell = temporary()
          result.add("\t" & bytes & " =l mul " & index & ", " &
            $targetLayout.measure(element).size & "\n")
          result.add("\t" & cell & " =l add " & data & ", " & bytes & "\n")
          if i.op == "address":
            if i.dest.type == nil or i.dest.type.kind != Shape.Ptr or
                not same(i.dest.type.elem, element):
              raise unsupported("index address type")
            result.add("\t" & literal(i.dest) & " =l copy " & cell & "\n")
          elif same(i.dest.type, element):
            if (element.kind in {Shape.Int, Shape.Uint} and element.width > 64) or
                element.kind in {Shape.Array, Shape.Vector, Shape.Struct,
                Shape.ExternStruct, Shape.Slice, Shape.Optional, Shape.Failable}:
              result.add(aggregateSlot(element, literal(i.dest)))
              result.add("\tblit " & cell & ", " & literal(i.dest) &
                ", " & $targetLayout.measure(element).size & "\n")
            else:
              result.add("\t" & literal(i.dest) & " =" & base(element) & " " &
                loadOp(element) & " " & cell & "\n")
          else: raise unsupported("index value type")
        of Opcode.Bit:
          if i.dest.type != nil and i.dest.type.kind in
              {Shape.Int, Shape.Uint} and
              (i.dest.type.width notin [32, 64] or
                (i.val2.type != nil and i.val2.type.width > 64)):
            result.add(integerBit(i))
            return
          if i.dest.type == nil or i.dest.type.kind notin {Shape.Int, Shape.Uint} or
              i.dest.type.width notin [32, 64] or
              not same(i.dest.type, i.val.type) or
              (i.op == "not" and i.val2.type != nil):
            raise unsupported("bitwise operand types")
          let typ = base(i.dest.type)
          if i.op in ["and", "or", "xor"]:
            if not same(i.dest.type, i.val2.type):
              raise unsupported("bitwise operand types")
            result.add("\t" & literal(i.dest) & " =" & typ & " " & i.op &
              " " & literal(i.val) & ", " & literal(i.val2) & "\n")
          elif i.op == "not":
            result.add("\t" & literal(i.dest) & " =" & typ & " xor " &
              literal(i.val) & ", -1\n")
          elif i.op in ["shl", "lshr", "ashr", "set", "clear", "toggle"]:
            if i.val2.type == nil or i.val2.type.kind notin {Shape.Int, Shape.Uint} or
                (i.op == "ashr" and i.dest.type.kind != Shape.Int):
              raise unsupported("bit position type")
            let countType = base(i.val2.type)
            let bad = temporary()
            result.add("\t" & bad & " =w cuge" & countType & " " &
              literal(i.val2) & ", " & $i.dest.type.width & "\n")
            result.add(guard(bad, "ShiftOutOfBounds", i))
            let count = if countType == "w": literal(i.val2) else:
              let narrowed = temporary()
              result.add("\t" & narrowed & " =w copy " & literal(i.val2) & "\n")
              narrowed
            if i.op in ["set", "clear", "toggle"]:
              let mask = temporary()
              result.add("\t" & mask & " =" & typ & " shl 1, " & count & "\n")
              let operand = if i.op == "clear":
                  let inverse = temporary()
                  result.add("\t" & inverse & " =" & typ & " xor " & mask & ", -1\n")
                  inverse
                else: mask
              let operation = case i.op
                of "set": "or"
                of "clear": "and"
                else: "xor"
              result.add("\t" & literal(i.dest) & " =" & typ & " " & operation &
                " " & literal(i.val) & ", " & operand & "\n")
            else:
              let operation = case i.op
                of "lshr": "shr"
                of "ashr": "sar"
                else: "shl"
              result.add("\t" & literal(i.dest) & " =" & typ & " " & operation &
                " " & literal(i.val) & ", " & count & "\n")
          else: raise unsupported("bit operation '" & i.op & "'")
        of Opcode.Add, Opcode.Sub:
          if i.dest.type != nil and i.dest.type.kind == Shape.Vector:
            result.add(vectorArithmetic(i))
            return
          if i.dest.type != nil and i.dest.type.kind in
              {Shape.Int, Shape.Uint} and i.dest.type.width > 64:
            result.add(wideInteger(i))
            return
          if i.dest.type != nil and i.dest.type.kind in
              {Shape.Int, Shape.Uint} and i.dest.type.width notin [32, 64]:
            result.add(checkedInteger(i))
            return
          if i.kind == Opcode.Add and i.dest.type != nil and
              i.dest.type.kind == Shape.Slice:
            if not same(i.dest.type, i.val.type) or
                not same(i.dest.type, i.val2.type) or
                i.dest.type.elem == nil or
                i.dest.type.elem.kind != Shape.Uint or
                i.dest.type.elem.width != 8:
              raise unsupported("slice concatenation type")
            result.add(aggregateSlot(i.dest.type, literal(i.dest)))
            result.add("\tcall $foo_qbe_join(l " & literal(i.dest) &
              ", l " & literal(i.val) & ", l " & literal(i.val2) &
              ")\n")
            return
          if i.dest.type != nil and i.dest.type.kind == Shape.Float:
            if not same(i.dest.type, i.val.type) or
                not same(i.dest.type, i.val2.type):
              raise unsupported("mixed-type arithmetic " & $i.kind)
            result.add("\t" & literal(i.dest) & " =" & base(i.dest.type) & " " &
              (if i.kind == Opcode.Add: "add" else: "sub") & " " &
              literal(i.val) & ", " & literal(i.val2) & "\n")
          else:
            if i.dest.type == nil or i.dest.type.kind notin {Shape.Int, Shape.Uint} or
                i.dest.type.width notin [32, 64] or
                not same(i.dest.type, i.val.type) or
                not same(i.dest.type, i.val2.type):
              raise unsupported("integer arithmetic operand types")
            let typ = base(i.dest.type)
            let left = literal(i.val)
            let right = literal(i.val2)
            let output = literal(i.dest)
            let operation = if i.kind == Opcode.Add: "add" else: "sub"
            result.add("\t" & output & " =" & typ & " " & operation & " " &
              left & ", " & right & "\n")
            let bad = temporary()
            if i.dest.type.kind == Shape.Uint:
              let a = if i.kind == Opcode.Add: output else: left
              let b = if i.kind == Opcode.Add: left else: right
              result.add("\t" & bad & " =w cult" & typ & " " & a & ", " & b & "\n")
            else:
              let first = temporary()
              let second = temporary()
              let both = temporary()
              result.add("\t" & first & " =" & typ & " xor " & left & ", " &
                (if i.kind == Opcode.Add: output else: right) & "\n")
              result.add("\t" & second & " =" & typ & " xor " &
                (if i.kind == Opcode.Add: right else: left) & ", " & output & "\n")
              result.add("\t" & both & " =" & typ & " and " & first & ", " &
                second & "\n")
              result.add("\t" & bad & " =w cslt" & typ & " " & both & ", 0\n")
            result.add(guard(bad, "IntegerOverflow", i))
        of Opcode.Convert:
          let source = i.val.type
          let target = i.dest.type
          if source == nil or target == nil: raise unsupported("untyped conversion")
          if source.kind in {Shape.Int, Shape.Uint} and
              target.kind in {Shape.Int, Shape.Uint} and
              not same(source, target):
            if source.width notin 1..128 or target.width notin 1..128 or
                source.width > target.width or
                (source.kind != target.kind and not
                  (source.kind == Shape.Uint and target.kind == Shape.Int and
                   target.width > source.width)):
              raise unsupported("non-lossless integer conversion")
            if target.width > 64:
              result.add(aggregateSlot(target, literal(i.dest)))
              if source.width > 64:
                result.add("\tblit " & literal(i.val) & ", " &
                  literal(i.dest) & ", 16\n")
              else:
                let input = if source.width > 32: literal(i.val) else:
                    let extended = temporary()
                    result.add("\t" & extended & " =l " &
                      (if source.kind == Shape.Int: "extsw" else: "extuw") &
                      " " & literal(i.val) & "\n")
                    extended
                result.add("\tcall $foo_qbe_integer_extend128(l " &
                  literal(i.dest) & ", l " & input & ", w " &
                  $source.width & ", w " &
                  (if source.kind == Shape.Int: "1" else: "0") & ")\n")
              return
            let input = if source.width > 32: literal(i.val) else:
                let extended = temporary()
                result.add("\t" & extended & " =l " &
                  (if source.kind == Shape.Int: "extsw" else: "extuw") &
                  " " & literal(i.val) & "\n")
                extended
            let converted = temporary()
            result.add("\t" & converted &
              " =l call $foo_qbe_integer_extend64(l " & input &
              ", w " & $source.width & ", w " &
              (if source.kind == Shape.Int: "1" else: "0") &
              ", w " & $target.width & ")\n\t" & literal(i.dest) &
              " =" & base(target) & " copy " & converted & "\n")
            return
          if target.kind in {Shape.Optional, Shape.Failable} and
              same(source, target.elem):
            let destination = literal(i.dest)
            result.add(aggregateSlot(target, destination))
            if target.kind == Shape.Optional:
              result.add("\tstoreb 1, " & destination & "\n")
            if source.kind != Shape.Void:
              let payload = address(destination,
                targetLayout.measure(target).offsets[1])
              result.add(payload.code)
              result.add(storeField(source, i.val, payload.value))
            return
          if source.kind == Shape.Slice and target.kind == Shape.Slice and
              target.constant and same(source.elem, target.elem):
            let destination = literal(i.dest)
            result.add(aggregateSlot(target, destination))
            result.add("\tblit " & literal(i.val) & ", " & destination &
              ", " & $targetLayout.measure(target).size & "\n")
            return
          let operation = if same(source, target):
              "copy"
            elif source.kind == Shape.Function and
                target.kind == Shape.Function and
                source.abi == "runtime.codec" and target.abi.len == 0 and
                source.params.len == target.params.len and
                same(source.ret, target.ret):
              var compatible = true
              for index, parameter in source.params:
                if not same(parameter, target.params[index]): compatible = false
              if not compatible:
                raise unsupported("codec function adapter signature")
              "copy"
            elif source.kind in {Shape.Int, Shape.Uint} and
                source.width == 32 and target.kind == Shape.Float and
                target.width == 64:
              (if source.kind == Shape.Int: "swtof" else: "uwtof")
            elif source.kind == Shape.Float and source.width == 32 and
                target.kind == Shape.Float and target.width == 64:
              "exts"
            elif source.kind in {Shape.Int, Shape.Uint} and
                source.width == 32 and target.width == 64 and
                (target.kind == source.kind or
                 (source.kind == Shape.Uint and target.kind == Shape.Int)):
              (if source.kind == Shape.Int: "extsw" else: "extuw")
            else:
              raise unsupported("conversion from " & source.label & " to " & target.label)
          result.add("\t" & literal(i.dest) & " =" & base(target) &
            " " & operation & " " & literal(i.val) & "\n")
        of Opcode.Mul, Opcode.Div, Opcode.Remainder:
          if i.dest.type != nil and i.dest.type.kind == Shape.Vector:
            result.add(vectorArithmetic(i))
            return
          if i.dest.type != nil and i.dest.type.kind in
              {Shape.Int, Shape.Uint} and i.dest.type.width > 64:
            result.add(wideInteger(i))
            return
          if i.dest.type != nil and i.dest.type.kind in
              {Shape.Int, Shape.Uint} and i.dest.type.width notin [32, 64]:
            result.add(checkedInteger(i))
            return
          if i.dest.type == nil or not same(i.dest.type, i.val.type) or
              not same(i.dest.type, i.val2.type):
            raise unsupported("arithmetic operand types")
          let typ = base(i.dest.type)
          let left = literal(i.val)
          let right = literal(i.val2)
          let output = literal(i.dest)
          if i.dest.type.kind == Shape.Float:
            if i.kind == Opcode.Remainder:
              raise unsupported("floating remainder")
            result.add("\t" & output & " =" & typ & " " &
              (if i.kind == Opcode.Mul: "mul" else: "div") & " " &
              left & ", " & right & "\n")
          elif i.dest.type.kind in {Shape.Int, Shape.Uint}:
            if i.dest.type.width notin [32, 64]:
              raise unsupported("narrow checked arithmetic")
            let signed = i.dest.type.kind == Shape.Int
            if i.kind == Opcode.Mul:
              if typ == "w":
                let extended = if signed: "extsw" else: "extuw"
                let wideLeft = temporary()
                let wideRight = temporary()
                let wideProduct = temporary()
                let narrowProduct = temporary()
                let roundTrip = temporary()
                let bad = temporary()
                result.add("\t" & wideLeft & " =l " & extended & " " & left & "\n")
                result.add("\t" & wideRight & " =l " & extended & " " & right & "\n")
                result.add("\t" & wideProduct & " =l mul " & wideLeft & ", " & wideRight & "\n")
                result.add("\t" & narrowProduct & " =w copy " & wideProduct & "\n")
                result.add("\t" & roundTrip & " =l " & extended & " " & narrowProduct & "\n")
                result.add("\t" & bad & " =w cnel " & wideProduct & ", " & roundTrip & "\n")
                result.add(guard(bad, "IntegerOverflow", i))
                result.add("\t" & output & " =w copy " & narrowProduct & "\n")
              else:
                inc guardNumber
                let zeroLabel = "qbe.mul.zero." & $guardNumber
                let nonzeroLabel = "qbe.mul.nonzero." & $guardNumber
                let doneLabel = "qbe.mul.done." & $guardNumber
                let zero = temporary()
                result.add("\t" & output & " =l mul " & left & ", " & right & "\n")
                result.add("\t" & zero & " =w ceql " & right & ", 0\n")
                result.add("\tjnz " & zero & ", @" & zeroLabel & ", @" &
                  nonzeroLabel & "\n@" & zeroLabel & "\n\tjmp @" & doneLabel &
                  "\n@" & nonzeroLabel & "\n")
                if signed:
                  let atMinimum = temporary()
                  let negativeOne = temporary()
                  let special = temporary()
                  result.add("\t" & atMinimum & " =w ceql " & left &
                    ", -9223372036854775808\n")
                  result.add("\t" & negativeOne & " =w ceql " & right & ", -1\n")
                  result.add("\t" & special & " =w and " & atMinimum & ", " &
                    negativeOne & "\n")
                  result.add(guard(special, "IntegerOverflow", i))
                let quotient = temporary()
                let bad = temporary()
                result.add("\t" & quotient & " =l " &
                  (if signed: "div" else: "udiv") & " " & output & ", " &
                  right & "\n")
                result.add("\t" & bad & " =w cnel " & quotient & ", " & left & "\n")
                result.add(guard(bad, "IntegerOverflow", i))
                result.add("\tjmp @" & doneLabel & "\n@" & doneLabel & "\n")
            else:
              let zero = temporary()
              result.add("\t" & zero & " =w ceq" & typ & " " & right & ", 0\n")
              result.add(guard(zero, "DivisionByZero", i))
              var special = ""
              if signed:
                let minimum = if typ == "w": "-2147483648" else: "-9223372036854775808"
                let atMinimum = temporary()
                let negativeOne = temporary()
                special = temporary()
                result.add("\t" & atMinimum & " =w ceq" & typ & " " & left &
                  ", " & minimum & "\n")
                result.add("\t" & negativeOne & " =w ceq" & typ & " " & right &
                  ", -1\n")
                result.add("\t" & special & " =w and " & atMinimum & ", " &
                  negativeOne & "\n")
                if i.kind == Opcode.Div:
                  result.add(guard(special, "IntegerOverflow", i))
              if signed and i.kind == Opcode.Remainder:
                inc guardNumber
                let specialLabel = "qbe.rem.special." & $guardNumber
                let normalLabel = "qbe.rem.normal." & $guardNumber
                let doneLabel = "qbe.rem.done." & $guardNumber
                let ordinary = temporary()
                result.add("\tjnz " & special & ", @" & specialLabel & ", @" &
                  normalLabel & "\n@" & specialLabel & "\n\tjmp @" & doneLabel &
                  "\n@" & normalLabel & "\n\t" & ordinary & " =" & typ &
                  " rem " & left & ", " & right & "\n\tjmp @" & doneLabel &
                  "\n@" & doneLabel & "\n\t" & output & " =" & typ &
                  " phi @" & specialLabel & " 0, @" & normalLabel & " " &
                  ordinary & "\n")
              else:
                let operation = if i.kind == Opcode.Div:
                    (if signed: "div" else: "udiv")
                  else: "urem"
                result.add("\t" & output & " =" & typ & " " & operation &
                  " " & left & ", " & right & "\n")
          else:
            raise unsupported("arithmetic type " & i.dest.type.label)
        of Opcode.Compare:
          if i.val.type != nil and i.val.type.kind == Shape.Slice:
            if i.dest.type == nil or i.dest.type.kind != Shape.Bool or
                not same(i.val.type, i.val2.type) or
                i.val.type.elem == nil or
                i.val.type.elem.kind notin {Shape.Int, Shape.Uint} or
                i.val.type.elem.width notin [8, 16, 32, 64] or
                i.op notin ["equals", "does not equal", "is less than",
                  "is at most", "is greater than", "is at least"]:
              raise unsupported("sequence comparison type")
            if i.val.type.elem.kind == Shape.Uint and
                i.val.type.elem.width == 8 and
                i.op in ["equals", "does not equal"]:
              let equal = temporary()
              result.add("\t" & equal & " =w call $foo_qbe_text_equal(l " &
                literal(i.val) & ", l " & literal(i.val2) & ")\n")
              result.add("\t" & literal(i.dest) & " =w " &
                (if i.op == "equals": "copy " else: "ceqw ") & equal &
                (if i.op == "equals": "" else: ", 0") & "\n")
              return
            let compared = temporary()
            let operation = case i.op
              of "equals": "ceqw"
              of "does not equal": "cnew"
              of "is less than": "csltw"
              of "is at most": "cslew"
              of "is greater than": "csgtw"
              of "is at least": "csgew"
              else: raise unsupported("sequence comparison operation")
            result.add("\t" & compared & " =w call $foo_qbe_sequence_compare(l " &
              literal(i.val) & ", l " & literal(i.val2) & ", w " &
              $i.val.type.elem.width & ", w " &
              $(if i.val.type.elem.kind == Shape.Int: 1 else: 0) & ")\n")
            result.add("\t" & literal(i.dest) & " =w " &
              operation & " " & compared & ", 0\n")
            return
          if i.val.type != nil and i.val.type.kind in
              {Shape.Int, Shape.Uint} and i.val.type.width > 64:
            result.add(wideComparison(i))
            return
          if i.val.type != nil and i.val.type.kind in
              {Shape.Int, Shape.Uint} and i.val.type.width notin
              [8, 16, 32, 64]:
            result.add(integerComparison(i))
            return
          if i.val.type != nil and i.val.type.kind == Shape.Vector:
            let element = vectorElement(i.val.type)
            discard vectorElement(i.val2.type)
            let outputElement = vectorElement(i.dest.type)
            if not same(i.val.type, i.val2.type) or
                i.dest.type.width != i.val.type.width or
                outputElement.kind != Shape.Bool:
              raise unsupported("vector comparison operand types")
            let predicate = comparison(Instruction(kind: Opcode.Compare,
              op: i.op, val: Value(`type`: element),
              val2: Value(`type`: element),
              dest: Value(`type`: outputElement)))
            result.add(aggregateSlot(i.dest.type, literal(i.dest)))
            for index in 0..<i.dest.type.width:
              let leftCell = laneAddress(i.val, index)
              let rightCell = laneAddress(i.val2, index)
              let outputCell = laneAddress(i.dest, index)
              let left = temporary()
              let right = temporary()
              let compared = temporary()
              result.add(leftCell.code & rightCell.code & outputCell.code)
              result.add("\t" & left & " =" & base(element) & " " &
                loadOp(element) & " " & leftCell.value & "\n")
              result.add("\t" & right & " =" & base(element) & " " &
                loadOp(element) & " " & rightCell.value & "\n")
              result.add("\t" & compared & " =w " & predicate & " " &
                left & ", " & right & "\n")
              result.add("\tstoreb " & compared & ", " &
                outputCell.value & "\n")
          elif i.val.type != nil and i.val.type.kind in
              {Shape.Array, Shape.Struct, Shape.ExternStruct,
               Shape.PackedStruct, Shape.TaggedUnion}:
            result.add(aggregateComparison(i))
          elif i.val.type != nil and i.val.type.kind == Shape.Optional:
            let optional = i.val.type
            let element = optional.elem
            if i.dest.type == nil or i.dest.type.kind != Shape.Bool or
                not same(optional, i.val2.type) or
                i.op notin ["equals", "does not equal"] or element == nil or
                element.kind notin {Shape.Int, Shape.Uint, Shape.Bool, Shape.Ptr} or
                (element.kind in {Shape.Int, Shape.Uint} and
                  element.width notin 1..64):
              raise unsupported("optional comparison type")
            let leftPresent = temporary()
            let rightPresent = temporary()
            let samePresence = temporary()
            let absent = temporary()
            let leftPayload = address(literal(i.val),
              targetLayout.measure(optional).offsets[1])
            let rightPayload = address(literal(i.val2),
              targetLayout.measure(optional).offsets[1])
            let leftValue = temporary()
            let rightValue = temporary()
            let sameValue = temporary()
            let accepted = temporary()
            let equal = temporary()
            result.add("\t" & leftPresent & " =w loadub " & literal(i.val) &
              "\n\t" & rightPresent & " =w loadub " & literal(i.val2) &
              "\n\t" & samePresence & " =w ceqw " & leftPresent &
              ", " & rightPresent & "\n\t" & absent & " =w ceqw " &
              leftPresent & ", 0\n" & leftPayload.code & rightPayload.code &
              "\t" & leftValue & " =" & base(element) & " " &
              loadOp(element) & " " & leftPayload.value & "\n\t" &
              rightValue & " =" & base(element) & " " & loadOp(element) &
              " " & rightPayload.value & "\n\t" & sameValue & " =w ceq" &
              base(element) & " " & leftValue & ", " & rightValue &
              "\n\t" & accepted & " =w or " & absent & ", " & sameValue &
              "\n\t" & equal & " =w and " & samePresence & ", " &
              accepted & "\n\t" & literal(i.dest) & " =w " &
              (if i.op == "equals": "copy " else: "ceqw ") & equal &
              (if i.op == "equals": "" else: ", 0") & "\n")
          else:
            result.add("\t" & literal(i.dest) & " =w " & comparison(i) & " " &
              literal(i.val) & ", " & literal(i.val2) & "\n")
        of Opcode.Not:
          if i.dest.type == nil or i.dest.type.kind != Shape.Bool or
              i.val.type == nil or i.val.type.kind != Shape.Bool:
            raise unsupported("non-boolean not")
          discard base(i.dest.type)
          discard base(i.val.type)
          result.add("\t" & literal(i.dest) & " =w ceqw " & literal(i.val) & ", 0\n")
        of Opcode.Alloc:
          if i.dest.type == nil or i.dest.type.kind != Shape.Ptr or
              i.dest.type.elem == nil:
            raise unsupported("allocation type")
          discard base(i.dest.type)
          let layout = targetLayout.measure(i.dest.type.elem)
          if i.op == "slot":
            if layout.alignment > 16:
              raise unsupported("stack slot alignment over 16")
            if arm64Qbe and layout.alignment > 8:
              let raw = temporary()
              let rounded = temporary()
              stackSlots.add("\t" & raw & " =l alloc8 " &
                $(max(1, layout.size) + 15) & "\n\t" & rounded &
                " =l add " & raw & ", 15\n\t" & literal(i.dest) &
                " =l and " & rounded & ", -16\n")
            else:
              let alignment = if layout.alignment > 8: 16
                elif layout.alignment > 4: 8 else: 4
              stackSlots.add("\t" & literal(i.dest) & " =l alloc" &
                $alignment & " " & $max(1, layout.size) & "\n")
          else:
            if target.endsWith("-freestanding"):
              raise unsupported("freestanding heap allocation requires a target allocator")
            result.add("\t" & literal(i.dest) &
              " =l call $foo_qbe_alloc(l %qbe.owner, l " & $layout.size &
              ", l " & $max(8, layout.alignment) & ")\n")
        of Opcode.Region:
          if target.endsWith("-freestanding"):
            raise unsupported("freestanding regions require a target allocator")
          if i.op notin ["open", "close"]:
            raise unsupported("region operation '" & i.op & "'")
          result.add("\tcall $foo_qbe_free(l " & regionSlots[i.region] & ")\n")
        of Opcode.Allocate:
          if target.endsWith("-freestanding"):
            raise unsupported("freestanding arena allocation requires a target allocator")
          let t = i.dest.type
          let custom = i.target.type != nil
          if t == nil or t.kind != Shape.Failable or t.elem == nil or
              (if custom: i.target.type.kind != Shape.Ptr or
                t.elem.kind != Shape.Slice or t.elem.elem == nil or
                t.elem.elem.kind != Shape.Uint or t.elem.elem.width != 8
               else: t.elem.kind != Shape.Slice or
                t.elem.elem == nil or t.elem.elem.kind != Shape.Uint or
                t.elem.elem.width != 8) or i.val.type == nil or
              i.val.type.kind notin {Shape.Int, Shape.Uint} or
              i.val.type.width notin [32, 64]:
            raise unsupported("arena allocation type or custom allocator")
          let destination = literal(i.dest)
          result.add(aggregateSlot(t, destination))
          let count = if i.val.type.width == 64: literal(i.val) else:
              let extended = temporary()
              result.add("\t" & extended & " =l " &
                (if i.val.type.kind == Shape.Int: "extsw" else: "extuw") &
                " " & literal(i.val) & "\n")
              extended
          inc guardNumber
          let invalid = "qbe.allocate.invalid." & $guardNumber
          let reserve = "qbe.allocate.reserve." & $guardNumber
          let missing = "qbe.allocate.missing." & $guardNumber
          let success = "qbe.allocate.success." & $guardNumber
          let done = "qbe.allocate.done." & $guardNumber
          if i.val.type.kind == Shape.Int:
            let negative = temporary()
            result.add("\t" & negative & " =w csltl " & count & ", 0\n")
            result.add("\tjnz " & negative & ", @" & invalid & ", @" &
              reserve & "\n@" & invalid & "\n\tstorel " &
              cstring("InvalidSize") & ", " & destination &
              "\n\tjmp @" & done & "\n@" & reserve & "\n")
          if custom:
            result.add("\tcall $foo_qbe_memory_allocate_slice(l " & destination &
              ", l " & literal(i.target) & ", l " & count & ")\n" &
              "\tjmp @" & done & "\n@" & done & "\n")
            return
          let data = temporary()
          let failed = temporary()
          result.add("\t" & data & " =l call $foo_qbe_reserve(l " &
            regionSlots[i.region] & ", l " & count & ", l 8)\n")
          result.add("\t" & failed & " =w ceql " & data & ", 0\n")
          result.add("\tjnz " & failed & ", @" & missing & ", @" &
            success & "\n@" & missing & "\n\tstorel " &
            cstring("OutOfMemory") & ", " & destination &
            "\n\tjmp @" & done & "\n@" & success & "\n")
          let payload = address(destination, targetLayout.measure(t).offsets[1])
          let length = address(payload.value, targetLayout.measure(t.elem).offsets[1])
          result.add(payload.code & length.code)
          result.add("\tstorel " & data & ", " & payload.value &
            "\n\tstorel " & count & ", " & length.value &
            "\n\tjmp @" & done & "\n@" & done & "\n")
        of Opcode.Atomic:
          let order = case i.field
            of "relaxed": 0
            of "acquire": 1
            of "release": 2
            of "acq_rel": 3
            of "seq_cst": 4
            else: raise unsupported("atomic ordering '" & i.field & "'")
          if i.op == "fence":
            if order == 0:
              raise unsupported("relaxed atomic fence")
            result.add("\tcall $foo_qbe_atomic_fence(w " & $order & ")\n")
          else:
            if i.op notin ["load", "store", "add", "sub", "swap"] or
                i.ptr.type == nil or i.ptr.type.kind != Shape.Ptr or
                i.ptr.type.elem == nil or
                i.ptr.type.elem.kind notin {Shape.Int, Shape.Uint} or
                i.ptr.type.elem.width notin [8, 16, 32, 64] or
                i.ptr.type.elem.attributes != @["atomic"] or
                i.ptr.type.volatile or i.ptr.type.elem.volatile or
                (i.op == "load" and order in [2, 3]) or
                (i.op == "store" and order in [1, 3]):
              raise unsupported("atomic operation type or ordering")
            let element = i.ptr.type.elem
            let plain = node.Type(kind: element.kind, name: element.name,
              width: element.width)
            if i.op != "load" and not same(plain, i.val.type):
              raise unsupported("atomic input value type")
            if i.op in ["store"]:
              if i.dest.type != nil and i.dest.type.kind != Shape.Void:
                raise unsupported("atomic store result")
            elif not same(plain, i.dest.type):
              raise unsupported("atomic result value type")
            var input = ""
            if i.op != "load":
              input = if element.width == 64: literal(i.val) else:
                  let extended = temporary()
                  result.add("\t" & extended & " =l " &
                    (if element.kind == Shape.Int: "extsw" else: "extuw") &
                    " " & literal(i.val) & "\n")
                  extended
            let args = "l " & literal(i.ptr) &
              (if i.op == "load": "" else: ", l " & input) &
              ", w " & $order
            let symbol = "$foo_qbe_atomic_" & i.op & $element.width
            if i.op == "store":
              result.add("\tcall " & symbol & "(" & args & ")\n")
            else:
              let raw = temporary()
              result.add("\t" & raw & " =l call " & symbol & "(" & args & ")\n")
              if element.width == 64:
                result.add("\t" & literal(i.dest) & " =l copy " & raw & "\n")
              elif element.width == 32:
                result.add("\t" & literal(i.dest) & " =w copy " & raw & "\n")
              else:
                let narrowed = temporary()
                result.add("\t" & narrowed & " =w copy " & raw & "\n")
                if element.kind == Shape.Uint:
                  result.add("\t" & literal(i.dest) & " =w and " & narrowed &
                    ", " & $(if element.width == 8: 255 else: 65535) & "\n")
                else:
                  let shifted = temporary()
                  let displacement = 32 - element.width
                  result.add("\t" & shifted & " =w shl " & narrowed & ", " &
                    $displacement & "\n")
                  result.add("\t" & literal(i.dest) & " =w sar " & shifted &
                    ", " & $displacement & "\n")
        of Opcode.Load:
          if i.ptr.type == nil or i.ptr.type.kind != Shape.Ptr or
              i.ptr.type.elem == nil or
              "atomic" in i.ptr.type.elem.attributes or
              not same(i.dest.type, i.ptr.type.elem):
            raise unsupported("load type")
          discard base(i.ptr.type)
          let t = i.dest.type
          if (t.kind in {Shape.Int, Shape.Uint} and t.width > 64) or
              t.kind in {Shape.Array, Shape.Vector, Shape.Struct,
                Shape.ExternStruct, Shape.TaggedUnion, Shape.ExternUnion,
                Shape.PackedStruct, Shape.Slice, Shape.Optional,
                Shape.Failable}:
            result.add(aggregateSlot(t, literal(i.dest)))
            if i.ptr.type.volatile or t.volatile:
              result.add("\tcall $foo_qbe_volatile_read(l " &
                literal(i.dest) & ", l " & literal(i.ptr) & ", l " &
                $targetLayout.measure(t).size & ")\n")
            else:
              result.add("\tblit " & literal(i.ptr) & ", " &
                literal(i.dest) & ", " & $targetLayout.measure(t).size & "\n")
            return
          if i.ptr.type.volatile or t.volatile:
            if t.kind in {Shape.Array, Shape.Vector, Shape.Struct,
                Shape.ExternStruct, Shape.TaggedUnion, Shape.ExternUnion,
                Shape.PackedStruct, Shape.Slice, Shape.Optional,
                Shape.Failable}:
              result.add(aggregateSlot(t, literal(i.dest)))
              result.add("\tcall $foo_qbe_volatile_read(l " &
                literal(i.dest) & ", l " & literal(i.ptr) & ", l " &
                $targetLayout.measure(t).size & ")\n")
            else:
              let size = targetLayout.measure(t).size
              if size notin [1, 2, 4, 8]:
                raise unsupported("volatile scalar width")
              let raw = temporary()
              result.add("\t" & raw & " =l call $foo_qbe_volatile_load" &
                $(size * 8) & "(l " & literal(i.ptr) & ")\n")
              if t.kind == Shape.Float:
                if size == 4:
                  let word = temporary()
                  result.add("\t" & word & " =w copy " & raw & "\n")
                  result.add("\t" & literal(i.dest) & " =s cast " & word & "\n")
                else:
                  result.add("\t" & literal(i.dest) & " =d cast " & raw & "\n")
              elif base(t) == "w":
                let copied = temporary()
                result.add("\t" & copied & " =w copy " & raw & "\n")
                if t.kind in {Shape.Int, Shape.Uint} and t.width in [8, 16]:
                  let mask = (if t.width == 8: 255 else: 65535)
                  if t.kind == Shape.Uint:
                    result.add("\t" & literal(i.dest) & " =w and " & copied &
                      ", " & $mask & "\n")
                  else:
                    let shifted = temporary()
                    let displacement = 32 - t.width
                    result.add("\t" & shifted & " =w shl " & copied & ", " &
                      $displacement & "\n")
                    result.add("\t" & literal(i.dest) & " =w sar " & shifted &
                      ", " & $displacement & "\n")
                else:
                  result.add("\t" & literal(i.dest) & " =w copy " & copied & "\n")
              else:
                result.add("\t" & literal(i.dest) & " =l copy " & raw & "\n")
          else:
            result.add("\t" & literal(i.dest) & " =" & base(t) & " " &
              loadOp(t) & " " & literal(i.ptr) & "\n")
        of Opcode.Store:
          if i.ptr.type == nil or i.ptr.type.kind != Shape.Ptr or
              i.ptr.type.elem == nil or
              "atomic" in i.ptr.type.elem.attributes or
              not same(i.val.type, i.ptr.type.elem):
            raise unsupported("store type")
          discard base(i.ptr.type)
          let t = i.val.type
          if (t.kind in {Shape.Int, Shape.Uint} and t.width > 64) or
              t.kind in {Shape.Array, Shape.Vector, Shape.Struct,
                Shape.ExternStruct, Shape.TaggedUnion, Shape.ExternUnion,
                Shape.PackedStruct, Shape.Slice, Shape.Optional,
                Shape.Failable}:
            if i.ptr.type.volatile or t.volatile:
              result.add("\tcall $foo_qbe_volatile_write(l " &
                literal(i.ptr) & ", l " & literal(i.val) & ", l " &
                $targetLayout.measure(t).size & ")\n")
            else:
              result.add("\tblit " & literal(i.val) & ", " &
                literal(i.ptr) & ", " & $targetLayout.measure(t).size & "\n")
            return
          if i.ptr.type.volatile or t.volatile:
            if t.kind in {Shape.Array, Shape.Vector, Shape.Struct,
                Shape.ExternStruct, Shape.TaggedUnion, Shape.ExternUnion,
                Shape.PackedStruct, Shape.Slice, Shape.Optional,
                Shape.Failable}:
              result.add("\tcall $foo_qbe_volatile_write(l " &
                literal(i.ptr) & ", l " & literal(i.val) & ", l " &
                $targetLayout.measure(t).size & ")\n")
            else:
              let size = targetLayout.measure(t).size
              if size notin [1, 2, 4, 8]:
                raise unsupported("volatile scalar width")
              let raw = if t.kind == Shape.Float:
                  let bits = temporary()
                  result.add("\t" & bits & " =" &
                    (if size == 4: "w" else: "l") & " cast " &
                    literal(i.val) & "\n")
                  bits
                else: literal(i.val)
              let widened = if size < 8:
                  let extended = temporary()
                  result.add("\t" & extended & " =l extuw " & raw & "\n")
                  extended
                else: raw
              result.add("\tcall $foo_qbe_volatile_store" & $(size * 8) &
                "(l " & literal(i.ptr) & ", l " & widened & ")\n")
          else:
            result.add("\t" & storeOp(t) & " " & literal(i.val) &
              ", " & literal(i.ptr) & "\n")
        of Opcode.Call, Opcode.Thread:
          if i.abi.len > 0 and i.abi notin ["c", "runtime.testing",
              "runtime.system", "runtime.text", "runtime.table",
              "runtime.sequence", "runtime.codec", "runtime.fs",
              "runtime.io", "runtime.resource", "runtime.memory",
              "runtime.thread", "runtime.atomic"]:
            raise unsupported("call ABI '" & i.abi & "' in '" & fn.name & "'")
          var expected: seq[node.Type]
          var returned: node.Type
          var symbol: string
          if i.callee.type != nil:
            if i.callee.type.kind != Shape.Function:
              raise unsupported("non-function indirect call")
            discard base(i.callee.type)
            expected = i.callee.type.params
            returned = i.callee.type.ret
            if i.callee.type.abi in bridgeAbi.foreignAbis:
              let identity = cast[pointer](i.callee.type)
              if identity notin callbackBridges:
                raise unsupported("foreign callback adapter")
              symbol = "$" & callbackBridges[identity].name
            else:
              symbol = literal(i.callee)
          elif i.func in functions:
            if interruptMode(functions[i.func]).len > 0:
              raise unsupported("direct call to interrupt handler")
            for parameter in functions[i.func].params: expected.add(parameter.type)
            returned = functions[i.func].ret
            symbol = "$" & functionSymbol(functions[i.func])
          elif i.func in externs:
            let ext = externs[i.func]
            if ext.abi == "runtime.sequence" and ext.symbol == "create":
              if i.args.len != 0 or ext.params.len != 0 or
                  i.dest.type == nil or i.dest.type.kind != Shape.Slice or
                  not same(i.dest.type, ext.ret):
                raise unsupported("sequence.create signature")
              result.add(aggregateSlot(i.dest.type, literal(i.dest)))
              return
            if ext.abi == "runtime.memory":
              let operation = identifier(ext.symbol)
              if i.args.len != ext.params.len or
                  (if operation == "clear":
                    i.dest.type != nil or ext.ret == nil or
                      ext.ret.kind != Shape.Void
                   else: i.dest.type == nil or
                      not same(i.dest.type, ext.ret)):
                raise unsupported("memory service signature")
              for index, argument in i.args:
                if not same(argument.type, ext.params[index]):
                  raise unsupported("memory service argument type")
              proc pointer(index: int): bool =
                index < i.args.len and i.args[index].type.kind == Shape.Ptr
              proc unsigned(index: int): bool =
                index < i.args.len and i.args[index].type.kind == Shape.Uint and
                  i.args[index].type.width == 64
              let failable = i.dest.type != nil and
                i.dest.type.kind == Shape.Failable and
                i.dest.type.elem != nil and
                targetLayout.measure(i.dest.type).offsets[1] == 8
              let output = if i.dest.type == nil: "" else: literal(i.dest)
              var serviceArgs: seq[string]
              case operation
              of "system":
                if i.args.len != 0 or i.dest.type.kind != Shape.Ptr:
                  raise unsupported("memory.system signature")
              of "arena":
                if i.args.len != 0 or not failable or
                    i.dest.type.elem.kind != Shape.Ptr:
                  raise unsupported("memory.arena signature")
              of "allocate", "reserve":
                if not pointer(0) or not unsigned(1) or
                    (if operation == "reserve":
                      i.args.len != 3 or not unsigned(2)
                    else: i.args.len != 2) or not failable or
                    i.dest.type.elem.kind != Shape.Ptr:
                  raise unsupported("memory allocation signature")
              of "expand", "view", "bytes":
                if i.args.len != 3 or not pointer(0) or not pointer(1) or
                    not unsigned(2) or not failable or
                    (if operation == "expand":
                      i.dest.type.elem.kind != Shape.Ptr
                     else: i.dest.type.elem.kind != Shape.Slice or
                      i.dest.type.elem.elem == nil or
                      i.dest.type.elem.elem.kind != Shape.Uint or
                      i.dest.type.elem.elem.width != 8):
                  raise unsupported("memory view signature")
              of "copy":
                if i.args.len != 3 or not pointer(0) or not pointer(1) or
                    i.args[2].type.kind != Shape.Slice or not failable or
                    i.dest.type.elem.kind != Shape.Void:
                  raise unsupported("memory.copy signature")
              of "transfer":
                if i.args.len != 2 or i.args[0].type.kind != Shape.Slice or
                    i.args[1].type.kind != Shape.Slice or not failable or
                    i.dest.type.elem.kind != Shape.Void:
                  raise unsupported("memory.transfer signature")
              of "clear", "compare":
                if i.args.len != (if operation == "clear": 1 else: 2) or
                    i.args[0].type.kind != Shape.Slice or
                    (i.args.len == 2 and i.args[1].type.kind != Shape.Slice) or
                    (if operation == "clear": i.dest.type != nil
                     else: i.dest.type.kind != Shape.Int or
                       i.dest.type.width != 64):
                  raise unsupported("memory sequence signature")
              of "aligned":
                if i.args.len != 2 or not pointer(0) or not unsigned(1) or
                    i.dest.type.kind != Shape.Bool:
                  raise unsupported("memory.aligned signature")
              of "release":
                if i.args.len != 2 or not pointer(0) or not pointer(1) or
                    not failable or i.dest.type.elem.kind != Shape.Void:
                  raise unsupported("memory.release signature")
              of "close":
                if i.args.len != 1 or not pointer(0) or not failable or
                    i.dest.type.elem.kind != Shape.Void:
                  raise unsupported("memory.close signature")
              of "reinterpret":
                if i.args.len != 3 or not pointer(0) or not pointer(1) or
                    not unsigned(2) or not failable or
                    i.dest.type.elem.kind != Shape.Ptr or
                    i.dest.type.elem.elem == nil or
                    canContainPointer(i.dest.type.elem.elem):
                  raise unsupported("memory.reinterpret signature")
              of "identical":
                if i.args.len != 2 or not pointer(0) or not pointer(1) or
                    i.dest.type.kind != Shape.Bool:
                  raise unsupported("memory.identical signature")
              else: raise unsupported("memory operation '" & operation & "'")
              if failable:
                result.add(aggregateSlot(i.dest.type, output))
                serviceArgs.add("l " & output)
              for argument in i.args:
                serviceArgs.add("l " & literal(argument))
              if operation == "reinterpret":
                let layout = targetLayout.measure(i.dest.type.elem.elem)
                serviceArgs.add("l " & $layout.size)
                serviceArgs.add("l " & $layout.alignment)
              result.add("\t" &
                (if failable or operation == "clear": "" else: output & " =" &
                  (if i.dest.type.kind in {Shape.Ptr, Shape.Int}: "l " else: "w ")) &
                "call $foo_qbe_memory_" & operation & "(" &
                serviceArgs.join(", ") & ")\n")
              return
            if ext.abi in ["runtime.fs", "runtime.io"]:
              let operation = identifier(ext.symbol)
              proc textArgument(t: node.Type): bool =
                t != nil and t.kind == Shape.Slice and t.constant and
                  t.elem != nil and t.elem.kind == Shape.Uint and
                  t.elem.width == 8
              if ext.abi == "runtime.io" and operation in
                  ["input", "output", "report"]:
                if ext.params.len != 0 or i.args.len != 0 or
                    ext.ret == nil or ext.ret.kind != Shape.Ptr or
                    i.dest.type == nil or not same(i.dest.type, ext.ret):
                  raise unsupported("standard stream signature")
                result.add("\t" & literal(i.dest) &
                  " =l call $foo_qbe_io_" & operation & "()\n")
                return
              let signature = if ext.abi == "runtime.fs":
                  case operation
                  of "exists", "read", "remove":
                    ext.params.len == 1 and textArgument(ext.params[0])
                  of "write", "open":
                    ext.params.len == 2 and textArgument(ext.params[0]) and
                      textArgument(ext.params[1])
                  else: false
                else:
                  case operation
                  of "read", "write":
                    ext.params.len == 2 and ext.params[0].kind == Shape.Ptr and
                      (if operation == "read":
                        ext.params[1].kind == Shape.Uint and
                          ext.params[1].width == 64
                      else: textArgument(ext.params[1]))
                  of "close", "line":
                    ext.params.len == 1 and ext.params[0].kind == Shape.Ptr
                  else: false
              if (ext.abi == "runtime.fs" and operation notin
                  ["exists", "read", "write", "remove", "open"]) or
                  (ext.abi == "runtime.io" and operation notin
                  ["read", "write", "line", "close"]) or not signature or i.dest.type == nil or
                  i.dest.type.kind != Shape.Failable or
                  i.dest.type.elem == nil or
                  not same(i.dest.type, ext.ret) or
                  i.args.len != ext.params.len or
                  targetLayout.measure(i.dest.type).offsets[1] != 8:
                raise unsupported("hosted file service signature")
              let payload = i.dest.type.elem
              let expectedPayload =
                if ext.abi == "runtime.io":
                  if operation in ["read", "line"]: textArgument(payload)
                  else: payload.kind == Shape.Void
                else:
                  case operation
                  of "exists": payload.kind == Shape.Bool
                  of "read": textArgument(payload)
                  of "open": payload.kind == Shape.Ptr
                  else: payload.kind == Shape.Void
              if not expectedPayload:
                raise unsupported("hosted file service result")
              var serviceArgs = @["l " & literal(i.dest)]
              for index, argument in i.args:
                if not same(argument.type, ext.params[index]) or
                    argument.type.kind notin {Shape.Slice, Shape.Ptr,
                      Shape.Int, Shape.Uint}:
                  raise unsupported("hosted file service argument")
                serviceArgs.add("l " & literal(argument))
              result.add(aggregateSlot(i.dest.type, literal(i.dest)))
              result.add("\tcall $foo_qbe_" & ext.abi[8 .. ^1] & "_" &
                operation & "(" & serviceArgs.join(", ") & ")\n")
              return
            if ext.abi == "runtime.resource" and
                (ext.symbol != "files" or ext.params.len != 0 or
                ext.ret == nil or ext.ret.kind != Shape.Uint or
                ext.ret.width != 64):
              raise unsupported("hosted resource service")
            if ext.abi == "runtime.atomic":
              let operation = identifier(ext.symbol)
              if operation notin ["create", "release", "load", "store",
                  "add", "deduct", "swap", "replace", "compare"] or
                  i.args.len != ext.params.len or ext.ret == nil or
                  (operation == "release" and ext.ret.kind != Shape.Void) or
                  (operation != "release" and
                    (i.dest.type == nil or
                     i.dest.type.kind != Shape.Failable or
                     not same(i.dest.type, ext.ret))):
                raise unsupported("atomic service signature")
              for index, argument in i.args:
                if not same(argument.type, ext.params[index]):
                  raise unsupported("atomic service argument type")
              let arity = case operation
                of "create", "release": 1
                of "load": 2
                of "store", "add", "deduct", "swap": 3
                of "replace": 4
                of "compare": 5
                else: 0
              if i.args.len != arity or
                  (if operation == "create":
                    i.args[0].type.kind != Shape.Uint or
                      i.args[0].type.width != 64 or
                      i.dest.type.elem.kind != Shape.Ptr
                   else: i.args[0].type.kind != Shape.Ptr) or
                  (operation notin ["create", "release"] and
                    i.args[^1].type.kind != Shape.Slice):
                raise unsupported("atomic service argument layout")
              if operation == "release":
                result.add("\tcall $foo_qbe_atomic_release(l " &
                  literal(i.args[0]) & ")\n")
              else:
                let payload = i.dest.type.elem
                if payload == nil or
                    (if operation == "create": payload.kind != Shape.Ptr
                     elif operation == "store": payload.kind != Shape.Void
                     elif operation in ["replace", "compare"]:
                       payload.kind != Shape.Bool
                     else: payload.kind != Shape.Uint or
                       payload.width != 64):
                  raise unsupported("atomic service result layout")
                let output = literal(i.dest)
                result.add(aggregateSlot(i.dest.type, output))
                var serviceArgs = @["l " & output]
                for argument in i.args:
                  serviceArgs.add("l " & literal(argument))
                result.add("\tcall $foo_qbe_atomic_" & operation &
                  "_out(" & serviceArgs.join(", ") & ")\n")
              return
            if ext.abi == "runtime.codec":
              let operation = identifier(ext.symbol)
              if operation notin ["encode", "decode", "marshal", "unmarshal"] or
                  i.dest.type == nil or i.dest.type.kind != Shape.Failable or
                  not same(i.dest.type, ext.ret) or i.args.len != 1 or
                  ext.params.len != 1 or
                  not same(i.args[0].type, ext.params[0]):
                raise unsupported("typed JSON call signature")
              let output = literal(i.dest)
              let encoding = operation in ["encode", "marshal"]
              let shape = if encoding: i.args[0].type else: i.dest.type.elem
              let descriptor = codecSchema(shape)
              let label = "$qbe.codec." & $aggregateConstants.len
              aggregateConstants.add("data " & label & " = { b " &
                descriptor.mapIt($it).join(" ") & " }\n")
              result.add(aggregateSlot(i.dest.type, output))
              if encoding:
                if i.dest.type.elem.kind != Shape.Slice or
                    i.dest.type.elem.elem == nil or
                    i.dest.type.elem.elem.kind != Shape.Uint or
                    i.dest.type.elem.elem.width != 8:
                  raise unsupported("typed JSON encode result")
              elif i.args[0].type.kind != Shape.Slice or
                  i.args[0].type.elem == nil or
                  i.args[0].type.elem.kind != Shape.Uint or
                  i.args[0].type.elem.width != 8:
                raise unsupported("typed JSON decode source")
              var names: seq[string]
              var fields: seq[node.Type]
              if typedCodec and target in ["windows-x64", "linux-x64"] and
                  shape.kind in {Shape.Struct, Shape.ExternStruct}:
                for name, field in shape.fields:
                  names.add(name)
                  fields.add(field)
              var direct = names.len == 2 and fields[0].kind == Shape.Uint and
                fields[0].width == 64 and fields[1].kind == Shape.Bool
              if direct:
                for name in names:
                  if name.len == 0: direct = false
                  for character in name:
                    if ord(character) < 32 or ord(character) > 126 or
                        character in {'"', '\\'}:
                      direct = false
                if names[0].len + names[1].len > 478: direct = false
              if direct:
                let prefix = "{\"" & names[0] & "\":"
                let middle = ",\"" & names[1] & "\":"
                let plan = "$qbe.codec.plan." & $aggregateConstants.len
                let offsets = targetLayout.measure(shape).offsets
                aggregateConstants.add("data " & plan & " = align 8 { l " &
                  cstring(prefix) & ", l " & $prefix.len & ", l " &
                  cstring(middle) & ", l " & $middle.len & ", l " &
                  label & ", l " & $descriptor.len & ", l " &
                  $offsets[0] & ", l " & $offsets[1] & ", l " &
                  $targetLayout.measure(i.dest.type).offsets[1] & ", l " &
                  (if operation == "marshal": "1" else: "0") & " }\n")
                if encoding:
                  let pointer = literal(i.args[0])
                  let numberAddress = address(pointer, offsets[0])
                  let number = temporary()
                  let activeAddress = address(pointer, offsets[1])
                  let active = temporary()
                  result.add(numberAddress.code)
                  result.add("\t" & number & " =l loadl " &
                    numberAddress.value & "\n")
                  result.add(activeAddress.code)
                  result.add("\t" & active & " =w loadub " &
                    activeAddress.value & "\n")
                  result.add("\tcall $foo_qbe_codec_encode_u64_bool(l " &
                    output & ", l " & number & ", w " & active & ", l " &
                    plan & ")\n")
                else:
                  result.add("\tcall $foo_qbe_codec_decode_u64_bool(l " &
                    output & ", l " & literal(i.args[0]) & ", l " & plan &
                    ")\n")
                return
              if encoding:
                let input = temporary()
                result.add(aggregateSlot(i.args[0].type, input))
                result.add(storeField(i.args[0].type, i.args[0], input))
                result.add("\tcall $foo_qbe_codec_encode(l " & output &
                  ", l " & input & ", l " & label & ", l " &
                  $descriptor.len & ", w " &
                  (if operation == "marshal": "1" else: "0") & ")\n")
              else:
                result.add("\tcall $foo_qbe_codec_decode(l " & output &
                  ", l " & literal(i.args[0]) & ", l " & label &
                  ", l " & $descriptor.len & ", l " &
                  $targetLayout.measure(i.dest.type).offsets[1] & ")\n")
              return
            if ext.abi == "runtime.sequence" and
                ext.symbol in ["sized", "copy", "release"]:
              if i.dest.type == nil or i.dest.type.kind != Shape.Failable or
                  not same(i.dest.type, ext.ret) or i.args.len != 1 or
                  ext.params.len != 1 or
                  not same(i.args[0].type, ext.params[0]):
                raise unsupported("sequence call signature")
              let output = literal(i.dest)
              result.add(aggregateSlot(i.dest.type, output))
              if ext.symbol == "sized":
                if i.args[0].type.kind != Shape.Uint or
                    i.args[0].type.width != 64 or
                    i.dest.type.elem.kind != Shape.Slice:
                  raise unsupported("sequence.sized signature")
                result.add("\tcall $foo_qbe_sequence_sized(l " & output &
                  ", l " & literal(i.args[0]) & ", l " &
                  $targetLayout.measure(i.dest.type.elem.elem).size & ", l " &
                  $targetLayout.measure(i.dest.type.elem.elem).alignment & ")\n")
              elif ext.symbol == "copy":
                if i.args[0].type.kind != Shape.Slice or
                    i.dest.type.elem.kind != Shape.Slice or
                    not same(i.args[0].type, i.dest.type.elem) or
                    canContainPointer(i.args[0].type.elem):
                  raise unsupported("sequence.copy ownership signature")
                result.add("\tcall $foo_qbe_sequence_copy(l " & output &
                  ", l " & literal(i.args[0]) & ", l " &
                  $targetLayout.measure(i.args[0].type.elem).size & ", l " &
                  $targetLayout.measure(i.args[0].type.elem).alignment & ")\n")
              else:
                if i.args[0].type.kind != Shape.Slice or
                    i.dest.type.elem.kind != Shape.Void:
                  raise unsupported("sequence.release signature")
                result.add("\tcall $foo_qbe_sequence_release(l " & output &
                  ", l " & literal(i.args[0]) & ", l " &
                  $targetLayout.measure(i.args[0].type.elem).size & ")\n")
              return
            if ext.abi == "runtime.table":
              let operation = identifier(ext.symbol)
              if i.dest.type == nil or i.dest.type.kind != Shape.Failable or
                  not same(i.dest.type, ext.ret) or
                  i.args.len != ext.params.len:
                raise unsupported("table call signature")
              for index, argument in i.args:
                if not same(argument.type, ext.params[index]):
                  raise unsupported("table call argument type")
              let output = literal(i.dest)
              result.add(aggregateSlot(i.dest.type, output))
              case operation
              of "create":
                if i.args.len != 0 or i.dest.type.elem.kind != Shape.Ptr:
                  raise unsupported("table.create signature")
                result.add("\tcall $foo_qbe_table_create(l " & output & ")\n")
              of "put":
                if i.args.len != 3 or i.args[1].type.kind != Shape.Slice or
                    i.dest.type.elem.kind != Shape.Void:
                  raise unsupported("table.put signature")
                let valueSlot = temporary()
                result.add(aggregateSlot(i.args[2].type, valueSlot))
                result.add(storeField(i.args[2].type, i.args[2], valueSlot))
                result.add("\tcall $foo_qbe_table_put(l " & output &
                  ", l " & literal(i.args[0]) & ", l " & literal(i.args[1]) &
                  ", l " & valueSlot & ", l " &
                  $targetLayout.measure(i.args[2].type).size & ")\n")
              of "get":
                if i.args.len != 2 or i.args[1].type.kind != Shape.Slice:
                  raise unsupported("table.get signature")
                result.add("\tcall $foo_qbe_table_get(l " & output &
                  ", l " & literal(i.args[0]) & ", l " & literal(i.args[1]) &
                  ", l " & $targetLayout.measure(i.dest.type.elem).size &
                  ", l " & $targetLayout.measure(i.dest.type).offsets[1] & ")\n")
              of "contains", "remove":
                if i.args.len != 2 or i.args[1].type.kind != Shape.Slice or
                    i.dest.type.elem.kind != Shape.Bool:
                  raise unsupported("table." & operation & " signature")
                result.add("\tcall $foo_qbe_table_query(l " & output &
                  ", l " & literal(i.args[0]) & ", l " & literal(i.args[1]) &
                  ", w " & (if operation == "contains": "0" else: "1") & ")\n")
              of "length", "close":
                if i.args.len != 1:
                  raise unsupported("table." & operation & " signature")
                result.add("\tcall $foo_qbe_table_" & operation & "(l " &
                  output & ", l " & literal(i.args[0]) & ")\n")
              else: raise unsupported("table operation '" & operation & "'")
              return
            let testing = ext.abi == "runtime.testing" and
              ext.symbol in ["expect", "number", "positive", "real", "point"]
            let system = ext.abi == "runtime.system" and
              ext.symbol == "cores" and ext.params.len == 0 and
              ext.ret != nil and ext.ret.kind == Shape.Failable and
              ext.ret.elem != nil and ext.ret.elem.kind == Shape.Uint and
              ext.ret.elem.width == 32
            let textService = ext.abi == "runtime.text" and
              ext.symbol in ["concatenate", "find", "release"] and
              ext.params.len == (if ext.symbol == "release": 1 else: 2) and
              ext.ret != nil and ext.ret.kind in {Shape.Failable, Shape.Optional}
            let resource = ext.abi == "runtime.resource" and
              ext.symbol == "files" and ext.params.len == 0 and
              ext.ret != nil and ext.ret.kind == Shape.Uint and
              ext.ret.width == 64
            let threading = ext.abi == "runtime.thread"
            if (ext.generics.len > 0 and not threading) or
                (ext.abi != "c" and ext.abi notin bridgeAbi.foreignAbis and
                  not testing and not system and not textService and
                  not resource and
                  not threading):
              raise unsupported("external function '" & ext.name & "'")
            expected = ext.params
            returned = ext.ret
            if threading:
              let operation = identifier(ext.symbol)
              if operation notin ["spawn", "wait", "mutex", "lock",
                  "unlock", "condition", "signal", "pause", "close"]:
                raise unsupported("thread runtime operation '" & operation & "'")
              var name = operation
              if operation == "close":
                if i.args.len != 1 or i.args[0].type == nil or
                    i.args[0].type.kind != Shape.Ptr or
                    i.args[0].type.elem == nil or
                    i.args[0].type.elem.kind != Shape.Opaque:
                  raise unsupported("thread close resource")
                let opaqueName = i.args[0].type.elem.name
                var resource = ""
                for kind in ["thread", "guard", "event"]:
                  if opaqueName == kind or opaqueName.endsWith("_" & kind):
                    resource = kind
                if resource.len == 0:
                  raise unsupported("thread close resource '" &
                    i.args[0].type.elem.label & "'")
                name = "close_" & resource
              symbol = "$foo_qbe_thread_" & name & "_out"
            elif ext.abi in bridgeAbi.foreignAbis:
              symbol = "$" & bridgeAbi.bridgeName(identifier(ext.name))
            else:
              symbol = if system: "$foo_qbe_system_cores"
                elif resource: "$foo_qbe_resource_files"
                elif textService: "$foo_qbe_text_" & identifier(ext.symbol)
                elif testing:
                  (if ext.symbol == "expect": "$foo_qbe_expect"
                   else: "$foo_qbe_test_" & identifier(ext.symbol))
                else: "$" & identifier(ext.symbol)
          else: raise unsupported("unbound call '" & i.func & "'")
          if expected.len != i.args.len: raise unsupported("call arity for '" & i.func & "'")
          for index, arg in i.args:
            if not same(arg.type, expected[index]):
              raise unsupported("call argument type for '" & i.func & "'")
          if i.abi == "runtime.system":
            if returned == nil or returned.kind != Shape.Failable or
                i.dest.type == nil or not same(i.dest.type, returned):
              raise unsupported("system call result for '" & i.func & "'")
            result.add(aggregateSlot(returned, literal(i.dest)))
            result.add("\tcall " & symbol & "(l " & literal(i.dest) & ")\n")
            return
          if i.abi == "runtime.text":
            if returned == nil or returned.kind notin {Shape.Failable,
                Shape.Optional} or i.dest.type == nil or
                not same(i.dest.type, returned):
              raise unsupported("text call result for '" & i.func & "'")
            result.add(aggregateSlot(returned, literal(i.dest)))
            var textArgs: seq[string] = @["l " & literal(i.dest)]
            for arg in i.args: textArgs.add("l " & literal(arg))
            result.add("\tcall " & symbol & "(" & textArgs.join(", ") & ")\n")
            return
          if i.abi == "runtime.thread":
            if returned == nil or returned.kind != Shape.Failable or
                i.dest.type == nil or not same(i.dest.type, returned):
              raise unsupported("thread call result for '" & i.func & "'")
            result.add(aggregateSlot(returned, literal(i.dest)))
            var threadArgs: seq[string] = @["l " & literal(i.dest)]
            for arg in i.args:
              threadArgs.add("l " & literal(arg))
            result.add("\tcall " & symbol & "(" & threadArgs.join(", ") & ")\n")
            return
          var args: seq[string]
          for index, arg in i.args:
            args.add((if i.abi == "runtime.testing" and
                arg.type.kind == Shape.Optional: "l" else:
                abiBoundary(arg.type)) & " " & literal(arg))
          if i.callee.type != nil and
              i.callee.type.abi in bridgeAbi.foreignAbis:
            args.insert("l " & literal(i.callee), 0)
          if returned == nil or returned.kind == Shape.Void:
            if i.dest.type != nil and i.dest.type.kind != Shape.Void:
              raise unsupported("void call result")
            result.add("\tcall " & symbol & "(" & args.join(", ") & ")\n")
          else:
            if not same(i.dest.type, returned):
              raise unsupported("call result type for '" & i.func & "'")
            result.add("\t" & literal(i.dest) & " =" & abiBoundary(returned) &
              " call " & symbol & "(" & args.join(", ") & ")\n")
        of Opcode.Trace:
          result.add("\tcall $foo_qbe_trace(l " & cstring(i.trace) &
            ", l " & cstring(i.span.file) & ", l " & $i.span.start & ")\n")
        of Opcode.Defer:
          result.add("\tstoreb 1, " & deferFlags[cast[pointer](i)] & "\n")
        of Opcode.Try, Opcode.Catch:
          let source = if i.kind == Opcode.Try: i.expr else: i.val
          if source.type == nil or source.type.kind notin
              {Shape.Failable, Shape.Error} or
              (i.kind == Opcode.Catch and source.type.kind != Shape.Failable):
            raise unsupported("try/catch operand type")
          if i.kind == Opcode.Catch and i.dest.type != nil and
              i.dest.type.kind in {Shape.Array, Shape.Vector, Shape.Struct,
                Shape.ExternStruct, Shape.TaggedUnion, Shape.ExternUnion,
                Shape.PackedStruct, Shape.Slice, Shape.Optional,
                Shape.Failable} or
              (i.kind == Opcode.Catch and i.dest.type != nil and
                i.dest.type.kind in {Shape.Int, Shape.Uint} and
                i.dest.type.width > 64):
            result.add(aggregateSlot(i.dest.type, literal(i.dest)))
          let errorValue = if source.type.kind == Shape.Error: literal(source) else:
              let loaded = temporary()
              result.add("\t" & loaded & " =l loadl " & literal(source) & "\n")
              loaded
          let failed = temporary()
          result.add("\t" & failed & " =w cnel " & errorValue & ", 0\n")
          inc guardNumber
          let bad = "qbe.issue.bad." & $guardNumber
          let good = "qbe.issue.good." & $guardNumber
          let done = "qbe.issue.done." & $guardNumber
          let fallbackDone = "qbe.issue.fallback." & $guardNumber
          result.add("\tjnz " & failed & ", @" & bad & ", @" & good &
            "\n@" & bad & "\n")
          if i.kind == Opcode.Try:
            if not target.endsWith("-freestanding"):
              result.add("\tcall $foo_qbe_trace(l " & cstring(i.trace) &
                ", l " & cstring(i.span.file) & ", l " & $i.span.start & ")\n")
            if fn.ret != nil and fn.ret.kind == Shape.Failable:
              let failure = temporary()
              result.add(aggregateSlot(fn.ret, failure))
              result.add("\tstorel " & errorValue & ", " & failure & "\n")
              result.add(release("1"))
              result.add("\tret " & failure & "\n")
            elif fn.ret == nil or fn.ret.kind == Shape.Void:
              result.add(release("1"))
              if not target.endsWith("-freestanding"):
                result.add("\tcall $foo_qbe_panic(l " & errorValue & ")\n")
              result.add("\thlt\n")
            else: raise unsupported("try requires failable function result")
            result.add("@" & good & "\n")
            if i.dest.type != nil and i.dest.type.kind != Shape.Void:
              if source.type.kind != Shape.Failable or
                  not same(i.dest.type, source.type.elem):
                raise unsupported("try result type")
              let payload = address(literal(source),
                targetLayout.measure(source.type).offsets[1])
              result.add(payload.code)
              result.add(copyProjection(i.dest.type, literal(i.dest),
                payload.value))
          else:
            if i.fallback == nil or i.dest.type == nil or
                not same(i.dest.type, source.type.elem):
              raise unsupported("catch fallback body or result type")
            let graph = lowerFallback(i, i.dest.type)
            let aggregate = i.dest.type.kind in {Shape.Array, Shape.Vector,
              Shape.Struct, Shape.ExternStruct, Shape.TaggedUnion,
              Shape.ExternUnion, Shape.PackedStruct, Shape.Slice,
              Shape.Optional, Shape.Failable} or
              (i.dest.type.kind in {Shape.Int, Shape.Uint} and
                i.dest.type.width > 64)
            result.add(graph.code)
            for exit in graph.exits:
              result.add("@" & exit.label & "\n")
              if aggregate:
                result.add("\tblit " & literal(exit.value) & ", " &
                  literal(i.dest) & ", " &
                  $targetLayout.measure(i.dest.type).size & "\n")
              result.add("\tjmp @" & fallbackDone & "\n")
            result.add("@" & fallbackDone & "\n")
            var fallbackValue = ""
            if not aggregate and i.dest.type.kind != Shape.Void and
                graph.exits.len > 0:
              fallbackValue = temporary()
              var sources: seq[string]
              for exit in graph.exits:
                sources.add("@" & exit.label & " " & literal(exit.value))
              result.add("\t" & fallbackValue & " =" & base(i.dest.type) &
                " phi " & sources.join(", ") & "\n")
            if not target.endsWith("-freestanding"):
              result.add("\tcall $foo_qbe_trace_reset()\n")
            result.add("\tjmp @" & done & "\n@" & good & "\n")
            if i.dest.type.kind == Shape.Void:
              result.add("\tjmp @" & done & "\n@" & done & "\n")
              return
            let payload = address(literal(source),
              targetLayout.measure(source.type).offsets[1])
            result.add(payload.code)
            if aggregate:
              result.add("\tblit " & payload.value & ", " & literal(i.dest) &
                ", " & $targetLayout.measure(i.dest.type).size & "\n")
              result.add("\tjmp @" & done & "\n@" & done & "\n")
            else:
              let success = temporary()
              result.add("\t" & success & " =" & base(i.dest.type) & " " &
                loadOp(i.dest.type) & " " & payload.value & "\n")
              result.add("\tjmp @" & done & "\n@" & done & "\n")
              if graph.exits.len > 0:
                result.add("\t" & literal(i.dest) & " =" & base(i.dest.type) &
                  " phi @" & fallbackDone & " " & fallbackValue &
                  ", @" & good & " " & success & "\n")
              else:
                result.add("\t" & literal(i.dest) & " =" & base(i.dest.type) &
                  " copy " & success & "\n")
        of Opcode.Native:
          if i.op == "machine:align":
            if i.args.len != 2 or i.args[0].type == nil or
                i.args[0].type.kind != Shape.Ptr or
                i.args[0].type.elem == nil or
                i.args[0].type.elem.kind notin {Shape.Ptr, Shape.Slice} or
                i.args[1].type == nil or
                i.args[1].type.kind != Shape.Uint or
                i.args[1].type.width notin [32, 64]:
              raise unsupported("machine alignment operands")
            let alignment = if i.args[1].type.width == 64:
                literal(i.args[1])
              else:
                let extended = temporary()
                result.add("\t" & extended & " =l extuw " &
                  literal(i.args[1]) & "\n")
                extended
            let raw = temporary()
            let zero = temporary()
            let previous = temporary()
            let irregular = temporary()
            let displacement = temporary()
            let nonzero = temporary()
            let malformed = temporary()
            let invalid = temporary()
            result.add("\t" & raw & " =l loadl " & literal(i.args[0]) & "\n")
            result.add("\t" & zero & " =w ceql " & alignment & ", 0\n")
            result.add("\t" & previous & " =l sub " & alignment & ", 1\n")
            result.add("\t" & irregular & " =l and " & alignment &
              ", " & previous & "\n")
            result.add("\t" & displacement & " =l and " & raw & ", " &
              previous & "\n")
            result.add("\t" & nonzero & " =w cnel " & irregular & ", 0\n")
            result.add("\t" & malformed & " =w cnel " & displacement & ", 0\n")
            let power = temporary()
            result.add("\t" & power & " =w or " & zero & ", " & nonzero & "\n")
            result.add("\t" & invalid & " =w or " & power & ", " &
              malformed & "\n")
            result.add(guard(invalid, "InvalidAlignment", i))
          elif i.op == "machine:system":
            if target notin ["linux-x64", "linux-arm64", "linux-riscv64"] or
                i.args.len notin 1..7 or i.dest.type == nil or
                i.dest.type.kind != Shape.Int or i.dest.type.width != 64:
              raise unsupported("direct Linux system call target or result")
            var args: seq[string]
            for argument in i.args:
              if argument.type == nil or argument.type.kind notin
                  {Shape.Int, Shape.Uint, Shape.Ptr} or
                  (argument.type.kind in {Shape.Int, Shape.Uint} and
                    argument.type.width != 64):
                raise unsupported("direct Linux system call operand")
              args.add("l " & literal(argument))
            while args.len < 7: args.add("l 0")
            result.add("\t" & literal(i.dest) &
              " =l call $foo_qbe_syscall6(" & args.join(", ") & ")\n")
          else: raise unsupported("native operation '" & i.op & "'")
        else: raise unsupported("instruction " & $i.kind)
      for i in section.instrs:
        try:
          result.add(lowerInstruction(i))
        except ValueError as error:
          raise newException(ValueError, "QBE lowering " & fn.name & "/" &
            section.label & "/" & $i.kind & ": " & error.msg)
      let term = section.term
      if term.attributes.len > 0:
        raise unsupported("terminator attributes in '" & fn.name & "'")
      case term.kind
      of Opcode.Jump:
        result.add("\tjmp @" & bridges[(section.label, term.label)] & "\n")
      of Opcode.Cjump:
        if term.cond.type == nil or term.cond.type.kind != Shape.Bool:
          raise unsupported("non-boolean branch condition")
        result.add("\tjnz " & literal(term.cond) & ", @" &
          bridges[(section.label, term.yes)] & ", @" &
          bridges[(section.label, term.no)] & "\n")
      of Opcode.Return:
        let implicitSuccess = fn.ret != nil and
          fn.ret.kind == Shape.Failable and fn.ret.elem != nil and
          fn.ret.elem.kind == Shape.Void and term.value.type == nil
        let wrappedSuccess = fn.ret != nil and
          fn.ret.kind == Shape.Failable and fn.ret.elem != nil and
          term.value.type != nil and same(fn.ret.elem, term.value.type)
        if (owned or regionOrder.len > 0) and canContainPointer(fn.ret) and
            not implicitSuccess:
          raise unsupported("return of a value that may escape owned memory")
        var returnValue = if term.value.type == nil: "" else: literal(term.value)
        if wrappedSuccess:
          returnValue = temporary()
          result.add(aggregateSlot(fn.ret, returnValue))
          if fn.ret.elem.kind != Shape.Void:
            let payload = address(returnValue,
              targetLayout.measure(fn.ret).offsets[1])
            result.add(payload.code)
            result.add(storeField(fn.ret.elem, term.value, payload.value))
        let failed = if fn.ret != nil and fn.ret.kind == Shape.Failable and
            not implicitSuccess and not wrappedSuccess:
            let error = temporary()
            let predicate = temporary()
            result.add("\t" & error & " =l loadl " & literal(term.value) & "\n")
            result.add("\t" & predicate & " =w cnel " & error & ", 0\n")
            predicate
          else: "0"
        if implicitSuccess:
          let success = temporary()
          result.add(aggregateSlot(fn.ret, success))
          result.add(release("0"))
          result.add("\tret " & success & "\n")
        elif fn.ret == nil or fn.ret.kind == Shape.Void:
          if term.value.type != nil and term.value.type.kind != Shape.Void:
            raise unsupported("value returned from void function")
          result.add(release(failed))
          result.add("\tret\n")
        else:
          if not wrappedSuccess and not same(fn.ret, term.value.type):
            raise unsupported("return type for '" & fn.name & "': expected " &
              fn.ret.label & ", got " &
              (if term.value.type == nil: "nothing" else: term.value.type.label))
          result.add(release(failed))
          result.add("\tret " & returnValue & "\n")
      of Opcode.Panic:
        result.add("\tcall $foo_qbe_trace(l " & cstring(term.trace) &
          ", l " & cstring(term.span.file) & ", l " & $term.span.start & ")\n")
        result.add("\tcall $foo_qbe_panic(l " & cstring(term.msg) & ")\n\thlt\n")
      else: discard
    for bridge in bridgeTargets:
      result.add("@" & bridge.label & "\n\tjmp @" & bridge.destination & "\n")
    result.add("}\n")
    result.insert(stackSlots.join(""), entryOffset)
  if entry:
    if "main" notin functions: raise unsupported("application entry function 'main'")
    let main = functions["main"]
    let failableVoid = main.ret != nil and main.ret.kind == Shape.Failable and
      main.ret.elem != nil and main.ret.elem.kind == Shape.Void
    if main.abi != "" or main.params.len > 0 or main.ret == nil or
        (main.ret.kind notin {Shape.Void, Shape.Int, Shape.Uint} and
          not failableVoid) or
        (main.ret.kind in {Shape.Int, Shape.Uint} and
          main.ret.width notin [32, 64]):
      raise unsupported("application entry signature")
    result.add("export function w $main() {\n@start\n")
    if failableVoid:
      result.add("\t%qbe.outcome =" & abiBoundary(main.ret) &
        " call $foo.main()\n" &
        "\t%qbe.issue =l loadl %qbe.outcome\n" &
        "\t%qbe.failed =w cnel %qbe.issue, 0\n" &
        "\tjnz %qbe.failed, @qbe.entry.bad, @qbe.entry.ok\n" &
        "@qbe.entry.bad\n\tcall $foo_qbe_panic(l %qbe.issue)\n\thlt\n" &
        "@qbe.entry.ok\n\tret 0\n")
    elif main.ret.kind == Shape.Void:
      result.add("\tcall $foo.main()\n\tret 0\n")
    elif main.ret.width == 32:
      result.add("\t%qbe.status =w call $foo.main()\n\tret %qbe.status\n")
    else:
      result.add("\t%qbe.result =l call $foo.main()\n" &
        "\t%qbe.status =w copy %qbe.result\n\tret %qbe.status\n")
    result.add("}\n")
  for message in ["IntegerOverflow", "ShiftOutOfBounds", "DivisionByZero",
      "IndexOutOfBounds", "InvalidAlignment"]:
    if message in failures:
      result.add("data $qbe_error_" & message & " = { b \"" & message &
        "\", b 0 }\n")
  for item in textConstants: result.add(item)
  for item in aggregateConstants: result.add(item)
  for size in toSeq(zeroSizes.keys).sorted():
    result.add("data $qbe.zero." & $size & " = { z " & $size & " }\n")
  result = abiDefinitions.join("") & result
