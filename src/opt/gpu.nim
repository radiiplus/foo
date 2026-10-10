import std/[sequtils, sets, strutils, tables]
import ../ir/[kind, node]
import ./spirv

proc decimal(value: `Type`): bool =
  value != nil and value.kind == TypeKind.Float and value.width == 32

proc unsigned(value: `Type`): bool =
  value != nil and value.kind == TypeKind.Uint and value.width == 32

proc slice(value: `Type`): bool =
  value != nil and value.kind == TypeKind.Slice and value.elem.decimal()

proc counter(value: `Type`): bool =
  value != nil and value.kind == TypeKind.Slice and value.elem.unsigned()

type Kernel = object
  code: string
  limit: uint64
  requirements: uint64
  localBytes: uint64

proc fail(function: Function; detail: string) {.noreturn.} =
  raise newException(ValueError,
    "GPU kernel '" & function.name & "': " & detail)

proc validate(function: Function): Kernel =
  if function.public or function.typeParams.len > 0 or function.ret == nil or
      function.ret.kind != TypeKind.Void or function.params.len == 0:
    function.fail("requires a private, concrete function returning nothing")
  var slices = initHashSet[string]()
  var writable = initHashSet[string]()
  var outputs = initHashSet[string]()
  var counters = initHashSet[string]()
  var shared = initTable[string, uint64]()
  for parameter in function.params:
    if not parameter.`type`.slice() and not parameter.`type`.counter():
      function.fail("parameters must be decimal 32 or unsigned 32 sequences")
    if parameter.`type`.slice(): slices.incl(parameter.name)
    else: counters.incl(parameter.name)
    if not parameter.`type`.constant and not parameter.`type`.elem.constant:
      writable.incl(parameter.name)
      outputs.incl(parameter.name)
  if outputs.len == 0: function.fail("requires a writable output sequence")
  if function.blocks.len == 0: function.fail("requires a body")
  let body = function.blocks[0]
  if body.term == nil or body.term.kind != InstrKind.Return or
      (body.term.value.`type` != nil and
        body.term.value.`type`.kind != TypeKind.Void):
    function.fail("requires straight-line work and no result")
  var indices = initHashSet[string]()
  var localIndices = initHashSet[string]()
  var addresses = initTable[string, string]()
  var traps = initHashSet[string]()
  var wroteOutput = false
  for instruction in body.instrs:
    case instruction.kind
    of InstrKind.Call:
      if instruction.abi != "runtime.gpu":
        function.fail("can only call GPU intrinsics")
      case instruction.symbol
      of "barrier":
        if instruction.args.len != 0 or instruction.dest.name.len > 0 or
            instruction.dest.`type` != nil:
          function.fail("gpu.barrier cannot produce a value")
      of "shared":
        if instruction.args.len != 1 or
            instruction.args[0].kind != ValueKind.Const or
            not instruction.dest.`type`.slice():
          function.fail("gpu.shared needs a constant decimal 32 size")
        var size: uint64
        try:
          size = parseBiggestUInt(instruction.args[0].name)
        except ValueError:
          function.fail("gpu.shared needs a positive constant size")
        if size == 0 or size > uint64(high(int)) or
            size > (high(uint64) - result.localBytes) div 4:
          function.fail("gpu.shared size is out of range")
        if instruction.dest.name in slices:
          function.fail("has an invalid or repeated result")
        shared[instruction.dest.name] = size
        slices.incl(instruction.dest.name)
        writable.incl(instruction.dest.name)
        result.limit = if result.limit == 0: size else: min(result.limit, size)
        result.localBytes += size * 4
        result.requirements = result.requirements or 1
      of "atomic":
        if instruction.args.len != 3 or
            instruction.args[0].kind != ValueKind.Reg or
            instruction.args[0].name notin counters or
            instruction.args[0].name notin writable or
            not instruction.dest.`type`.unsigned() or
            not instruction.args[2].`type`.unsigned():
          function.fail("gpu.atomic needs a writable unsigned 32 sequence")
        let position = instruction.args[1]
        if position.kind == ValueKind.Const:
          if position.name != "0":
            function.fail("gpu.atomic constant index must be zero")
        elif position.kind != ValueKind.Reg or position.name notin indices:
          function.fail("gpu.atomic needs a GPU index or constant")
        result.requirements = result.requirements or 2
      of "broadcast":
        if instruction.args.len != 1 or
            not instruction.args[0].`type`.decimal() or
            not instruction.dest.`type`.decimal():
          function.fail("gpu.broadcast needs a decimal 32 value")
        result.requirements = result.requirements or 4
      of "index", "local", "group", "lane", "subgroup", "width":
        if instruction.args.len != 0 or instruction.dest.`type` == nil or
            instruction.dest.`type`.kind != TypeKind.Uint:
          function.fail("can only call GPU intrinsics")
        if instruction.symbol in ["index", "local", "group"]:
          indices.incl(instruction.dest.name)
        if instruction.symbol == "local":
          localIndices.incl(instruction.dest.name)
        if instruction.symbol in ["lane", "subgroup", "width"]:
          result.requirements = result.requirements or 4
      else:
        function.fail("can only call GPU intrinsics")
    of InstrKind.Index:
      if instruction.val.kind != ValueKind.Reg or
          (instruction.val.name notin slices and
            instruction.val.name notin counters):
        function.fail("can only index numeric parameters or shared storage")
      if shared.hasKey(instruction.val.name):
        let position = instruction.val2
        if position.kind == ValueKind.Const:
          var offset: uint64
          try:
            offset = parseBiggestUInt(position.name)
          except ValueError:
            function.fail("shared storage index must be nonnegative")
          if offset >= shared[instruction.val.name]:
            function.fail("shared storage index is out of bounds")
        elif position.kind != ValueKind.Reg or
            position.name notin localIndices:
          function.fail("shared storage needs a local ID or constant index")
      elif instruction.val2.kind != ValueKind.Reg or
          instruction.val2.name notin indices:
        function.fail("global storage needs a GPU index")
      if instruction.op == "address":
        if instruction.val.name notin writable:
          function.fail("cannot write a constant input")
        addresses[instruction.dest.name] = instruction.val.name
      elif (instruction.val.name in counters and
          not instruction.dest.`type`.unsigned()) or
          (instruction.val.name notin counters and
            not instruction.dest.`type`.decimal()):
        function.fail("indexed reads must match the parameter element type")
      if instruction.panic.len > 0: traps.incl(instruction.panic)
    of InstrKind.Add, InstrKind.Sub, InstrKind.Mul, InstrKind.Div:
      if not instruction.dest.`type`.decimal() or
          instruction.panic.len > 0:
        function.fail("arithmetic must use decimal 32")
    of InstrKind.Store:
      if instruction.ptr.kind != ValueKind.Reg or
          not addresses.hasKey(instruction.ptr.name) or
          ((addresses[instruction.ptr.name] in counters and
            not instruction.val.`type`.unsigned()) or
            (addresses[instruction.ptr.name] notin counters and
              not instruction.val.`type`.decimal())):
        function.fail("stores must match the output element type")
      if addresses[instruction.ptr.name] in outputs: wroteOutput = true
    else:
      function.fail("contains unsupported control flow or effects")
  if not wroteOutput: function.fail("must write an output sequence")
  for index in 1 ..< function.blocks.len:
    let basicBlock = function.blocks[index]
    if basicBlock.label notin traps or basicBlock.instrs.len > 0 or
        basicBlock.term == nil or basicBlock.term.kind != InstrKind.Panic:
      function.fail("contains unsupported control flow")

proc apply*(module: Module): int =
  var kernels = initTable[string, Kernel]()
  for function in module.funcs:
    if function.abi != "gpu": continue
    if kernels.hasKey(function.name): function.fail("is declared more than once")
    var kernel = function.validate()
    kernel.code = spirv.compile(function)
    kernels[function.name] = kernel
  var prepare, generated: Extern
  var names = initHashSet[string]()
  for function in module.funcs: names.incl(function.name)
  for external in module.externs:
    names.incl(external.name)
    if external.abi == "runtime.gpu" and external.symbol == "prepare":
      prepare = external
  var serial = 0
  var name = "prepared"
  while name in names:
    inc serial
    name = "prepared" & $serial
  for function in module.funcs:
    if function.abi == "gpu": continue
    template reject(item: Value) =
      if item.kind == ValueKind.Global and item.name in kernels:
        function.fail("cannot use a GPU kernel as a host function value")
    for basicBlock in function.blocks:
      for instruction in basicBlock.instrs & @[basicBlock.term]:
        if instruction == nil: continue
        for item in [instruction.target, instruction.ptr, instruction.val,
            instruction.val2, instruction.callee, instruction.cond,
            instruction.value, instruction.expr]:
          reject(item)
        for item in instruction.args: reject(item)
        if instruction.kind != InstrKind.Call: continue
        if instruction.func in kernels:
          function.fail("cannot call a GPU kernel on the host")
        if instruction.abi == "runtime.gpu" and
            instruction.symbol in ["index", "local", "group", "barrier",
              "shared", "atomic", "lane", "subgroup", "width",
              "broadcast"]:
          function.fail("GPU intrinsics are only available in a GPU kernel")
        if instruction.abi != "runtime.gpu" or
            instruction.symbol != "prepare": continue
        if prepare.name.len == 0 or instruction.args.len != 2 or
            instruction.args[1].kind != ValueKind.Const:
          function.fail("gpu.prepare needs a constant kernel name")
        let data = bytes(instruction.args[1].name)
        var entry = ""
        for item in data: entry.add(char(item))
        if not kernels.hasKey(entry):
          function.fail("gpu.prepare names no FOO GPU kernel '" & entry & "'")
        let kernel = module.funcs.filterIt(it.name == entry)[0]
        let code = kernels[entry]
        let signature = repeat('4', kernel.params.len)
        let textType = `Type`(kind: TypeKind.Slice, constant: true,
          elem: `Type`(kind: TypeKind.Uint, width: 8))
        if generated.name.len == 0:
          generated = Extern(name: name, symbol: "prepared",
            abi: "runtime.gpu", ret: prepare.ret,
            params: @[prepare.params[0], textType, textType, textType,
              `Type`(kind: TypeKind.Uint, width: 64),
              `Type`(kind: TypeKind.Uint, width: 64),
              `Type`(kind: TypeKind.Uint, width: 64)])
          module.externs.add(generated)
        instruction.func = generated.name
        instruction.symbol = "prepared"
        instruction.args = @[instruction.args[0],
          Value(kind: ValueKind.Const,
            name: quoted(code.code.toOpenArrayByte(0, code.code.high)),
            `type`: textType), instruction.args[1],
          Value(kind: ValueKind.Const,
            name: quoted(signature.toOpenArrayByte(0, signature.high)),
            `type`: textType),
          Value(kind: ValueKind.Const, name: $code.limit,
            `type`: `Type`(kind: TypeKind.Uint, width: 64)),
          Value(kind: ValueKind.Const, name: $code.requirements,
            `type`: `Type`(kind: TypeKind.Uint, width: 64)),
          Value(kind: ValueKind.Const, name: $code.localBytes,
            `type`: `Type`(kind: TypeKind.Uint, width: 64))]
        inc result
