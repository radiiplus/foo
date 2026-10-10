import std/[strutils, tables]
import ../ir/[kind, node]

type Builder = object
  next: uint32
  capabilities, entries, modes, decorations: seq[uint32]
  types, globals, body: seq[uint32]
  values: Table[string, uint32]
  buffers: Table[string, uint32]
  bufferTypes: Table[string, uint32]
  shared: Table[string, uint32]
  constants: Table[string, uint32]
  interfaces: seq[uint32]
  voidType, uintType, floatType, vectorType: uint32
  floatPointer, uintPointer, sharedPointer: uint32
  zero, workgroup, device, subgroup, barrierSemantics, atomicSemantics: uint32
  subgroupNeeded, ballotNeeded: bool

proc emit(section: var seq[uint32]; opcode: uint32; operands: varargs[uint32]) =
  section.add((uint32(operands.len + 1) shl 16) or opcode)
  for operand in operands: section.add(operand)

proc id(builder: var Builder): uint32 =
  result = builder.next
  inc builder.next

proc literal(value: string): seq[uint32] =
  let length = (value.len + 4) div 4
  result = newSeq[uint32](length)
  for index, letter in value:
    result[index div 4] = result[index div 4] or
      (uint32(ord(letter)) shl ((index mod 4) * 8))

proc constant(builder: var Builder; kind, bits: uint32): uint32 =
  let key = $kind & ":" & $bits
  if builder.constants.hasKey(key): return builder.constants[key]
  result = builder.id()
  builder.types.emit(43, kind, result, bits)
  builder.constants[key] = result

proc number(builder: var Builder; item: Value): uint32 =
  if item.kind == ValueKind.Reg and builder.values.hasKey(item.name):
    return builder.values[item.name]
  if item.kind == ValueKind.Const and item.`type` != nil:
    if item.`type`.kind == TypeKind.Float and item.`type`.width == 32:
      return builder.constant(builder.floatType,
        cast[uint32](float32(parseFloat(item.name))))
    if item.`type`.kind in {TypeKind.Int, TypeKind.Uint}:
      return builder.constant(builder.uintType,
        uint32(parseBiggestUInt(item.name)))
  raise newException(ValueError, "unsupported SPIR-V kernel value")

proc destination(builder: var Builder; item: Value): uint32 =
  if item.kind != ValueKind.Reg or item.name.len == 0 or
      builder.values.hasKey(item.name):
    raise newException(ValueError, "repeated SPIR-V kernel result")
  result = builder.id()
  builder.values[item.name] = result

proc builtin(builder: var Builder; decoration: uint32;
             scalar = false): uint32 =
  let pointer = builder.id()
  builder.types.emit(32, pointer, 1,
    if scalar: builder.uintType else: builder.vectorType)
  result = builder.id()
  builder.globals.emit(59, pointer, result, 1)
  builder.decorations.emit(71, result, 11, decoration)
  builder.interfaces.add(result)

proc compile*(function: Function): string =
  var builder = Builder(next: 1,
    values: initTable[string, uint32](),
    buffers: initTable[string, uint32](),
    bufferTypes: initTable[string, uint32](),
    shared: initTable[string, uint32](),
    constants: initTable[string, uint32]())
  builder.capabilities.emit(17, 1)
  builder.voidType = builder.id()
  builder.types.emit(19, builder.voidType)
  builder.uintType = builder.id()
  builder.types.emit(21, builder.uintType, 32, 0)
  builder.floatType = builder.id()
  builder.types.emit(22, builder.floatType, 32)
  builder.vectorType = builder.id()
  builder.types.emit(23, builder.vectorType, builder.uintType, 3)
  let functionType = builder.id()
  builder.types.emit(33, functionType, builder.voidType)
  builder.floatPointer = builder.id()
  builder.types.emit(32, builder.floatPointer, 12, builder.floatType)
  builder.uintPointer = builder.id()
  builder.types.emit(32, builder.uintPointer, 12, builder.uintType)
  builder.sharedPointer = builder.id()
  builder.types.emit(32, builder.sharedPointer, 4, builder.floatType)
  builder.zero = builder.constant(builder.uintType, 0)
  builder.workgroup = builder.constant(builder.uintType, 2)
  builder.device = builder.constant(builder.uintType, 1)
  builder.subgroup = builder.constant(builder.uintType, 3)
  builder.barrierSemantics = builder.constant(builder.uintType, 0x148)
  builder.atomicSemantics = builder.constant(builder.uintType, 0x48)
  for index, parameter in function.params:
    let kind = parameter.`type`.elem
    if parameter.`type`.kind != TypeKind.Slice or kind == nil or
        (kind.kind != TypeKind.Float and kind.kind != TypeKind.Uint) or
        kind.width != 32:
      raise newException(ValueError, "SPIR-V kernel needs 32-bit sequences")
    let element = if kind.kind == TypeKind.Float:
      builder.floatType else: builder.uintType
    let array = builder.id()
    builder.types.emit(29, array, element)
    builder.decorations.emit(71, array, 6, 4)
    let structure = builder.id()
    builder.types.emit(30, structure, array)
    builder.decorations.emit(71, structure, 2)
    builder.decorations.emit(72, structure, 0, 35, 0)
    let pointer = builder.id()
    builder.types.emit(32, pointer, 12, structure)
    let variable = builder.id()
    builder.globals.emit(59, pointer, variable, 12)
    builder.decorations.emit(71, variable, 34, 0)
    builder.decorations.emit(71, variable, 33, uint32(index))
    builder.interfaces.add(variable)
    builder.buffers[parameter.name] = variable
    builder.bufferTypes[parameter.name] = element
    builder.values[parameter.name] = variable
  let global = builder.builtin(28)
  let local = builder.builtin(27)
  let group = builder.builtin(26)
  let groups = builder.builtin(24)
  let lane = builder.builtin(41, true)
  let subgroup = builder.builtin(40, true)
  let width = builder.builtin(36, true)
  let entry = builder.id()
  let label = builder.id()
  var sizes: array[3, uint32]
  for index in 0 .. 2:
    sizes[index] = builder.id()
    builder.types.emit(50, builder.uintType, sizes[index], 1)
    builder.decorations.emit(71, sizes[index], 1, uint32(index))
  builder.body.emit(54, builder.voidType, entry, 0, functionType)
  builder.body.emit(248, label)
  var addresses = initTable[string, uint32]()
  for instruction in function.blocks[0].instrs:
    case instruction.kind
    of InstrKind.Call:
      if instruction.abi != "runtime.gpu":
        raise newException(ValueError, "SPIR-V kernel contains a host call")
      case instruction.symbol
      of "index", "local", "group":
        let vector = builder.id()
        let source = case instruction.symbol
          of "index": global
          of "local": local
          else: group
        builder.body.emit(61, builder.vectorType, vector, source)
        let first = builder.id()
        let second = builder.id()
        let third = builder.id()
        builder.body.emit(81, builder.uintType, first, vector, 0)
        builder.body.emit(81, builder.uintType, second, vector, 1)
        builder.body.emit(81, builder.uintType, third, vector, 2)
        var horizontal, vertical: uint32
        if instruction.symbol == "local":
          horizontal = sizes[0]
          vertical = sizes[1]
        else:
          let extent = builder.id()
          builder.body.emit(61, builder.vectorType, extent, groups)
          horizontal = builder.id()
          vertical = builder.id()
          builder.body.emit(81, builder.uintType, horizontal, extent, 0)
          builder.body.emit(81, builder.uintType, vertical, extent, 1)
          if instruction.symbol == "index":
            let x = builder.id()
            let y = builder.id()
            builder.body.emit(132, builder.uintType, x, horizontal, sizes[0])
            builder.body.emit(132, builder.uintType, y, vertical, sizes[1])
            horizontal = x
            vertical = y
        let row = builder.id()
        let plane = builder.id()
        let depth = builder.id()
        let total = builder.id()
        let target = builder.destination(instruction.dest)
        builder.body.emit(132, builder.uintType, row, second, horizontal)
        builder.body.emit(132, builder.uintType, plane, horizontal, vertical)
        builder.body.emit(132, builder.uintType, depth, third, plane)
        builder.body.emit(128, builder.uintType, total, first, row)
        builder.body.emit(128, builder.uintType, target, total, depth)
      of "lane", "subgroup", "width":
        builder.subgroupNeeded = true
        let source = case instruction.symbol
          of "lane": lane
          of "subgroup": subgroup
          else: width
        let target = builder.destination(instruction.dest)
        builder.body.emit(61, builder.uintType, target, source)
      of "broadcast":
        builder.subgroupNeeded = true
        builder.ballotNeeded = true
        let target = builder.destination(instruction.dest)
        builder.body.emit(338, builder.floatType, target,
          builder.subgroup, builder.number(instruction.args[0]))
      of "barrier":
        builder.body.emit(224, builder.workgroup, builder.workgroup,
          builder.barrierSemantics)
      of "shared":
        let size = uint32(parseBiggestUInt(instruction.args[0].name))
        let length = builder.constant(builder.uintType, size)
        let array = builder.id()
        builder.types.emit(28, array, builder.floatType, length)
        let pointer = builder.id()
        builder.types.emit(32, pointer, 4, array)
        let variable = builder.id()
        builder.globals.emit(59, pointer, variable, 4)
        builder.values[instruction.dest.name] = variable
        builder.shared[instruction.dest.name] = variable
      of "atomic":
        let pointer = builder.id()
        builder.body.emit(65, builder.uintPointer, pointer,
          builder.number(instruction.args[0]), builder.zero,
          builder.number(instruction.args[1]))
        let target = builder.destination(instruction.dest)
        builder.body.emit(234, builder.uintType, target, pointer,
          builder.device, builder.atomicSemantics,
          builder.number(instruction.args[2]))
      else:
        raise newException(ValueError,
          "SPIR-V kernel intrinsic is not yet supported: " & instruction.symbol)
    of InstrKind.Index:
      let isShared = builder.shared.hasKey(instruction.val.name)
      let element = if isShared: builder.floatType
        else: builder.bufferTypes[instruction.val.name]
      let pointerType = if isShared: builder.sharedPointer
        elif element == builder.uintType: builder.uintPointer
        else: builder.floatPointer
      let pointer = builder.id()
      if isShared:
        builder.body.emit(65, pointerType, pointer,
          builder.number(instruction.val), builder.number(instruction.val2))
      else:
        builder.body.emit(65, pointerType, pointer,
          builder.number(instruction.val), builder.zero,
          builder.number(instruction.val2))
      if instruction.op == "address":
        builder.values[instruction.dest.name] = pointer
        addresses[instruction.dest.name] = pointer
      else:
        let target = builder.destination(instruction.dest)
        builder.body.emit(61, element, target, pointer)
    of InstrKind.Add, InstrKind.Sub, InstrKind.Mul, InstrKind.Div:
      let target = builder.destination(instruction.dest)
      let opcode = case instruction.kind
        of InstrKind.Add: 129'u32
        of InstrKind.Sub: 131'u32
        of InstrKind.Mul: 133'u32
        else: 136'u32
      builder.body.emit(opcode, builder.floatType, target,
        builder.number(instruction.val), builder.number(instruction.val2))
    of InstrKind.Store:
      if not addresses.hasKey(instruction.ptr.name):
        raise newException(ValueError, "SPIR-V kernel store has no address")
      builder.body.emit(62, addresses[instruction.ptr.name],
        builder.number(instruction.val))
    else:
      raise newException(ValueError, "unsupported SPIR-V kernel instruction")
  builder.body.emit(253)
  builder.body.emit(56)
  if builder.subgroupNeeded: builder.capabilities.emit(17, 61)
  if builder.ballotNeeded: builder.capabilities.emit(17, 64)
  let named = literal("main")
  builder.entries.add((uint32(3 + named.len + builder.interfaces.len) shl 16) or 15)
  builder.entries.add(5)
  builder.entries.add(entry)
  builder.entries.add(named)
  builder.entries.add(builder.interfaces)
  builder.modes.emit(331, entry, 38, sizes[0], sizes[1], sizes[2])
  var words = @[0x07230203'u32, 0x00010300'u32, 0'u32,
    builder.next, 0'u32]
  words.add(builder.capabilities)
  words.add(@[0x0003000e'u32, 0'u32, 1'u32])
  words.add(builder.entries)
  words.add(builder.modes)
  words.add(builder.decorations)
  words.add(builder.types)
  words.add(builder.globals)
  words.add(builder.body)
  for word in words:
    for shift in [0, 8, 16, 24]:
      result.add(char((word shr shift) and 0xff))
