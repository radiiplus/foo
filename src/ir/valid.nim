import std/[json, sets, strutils, tables, sequtils]
import ./node
import ./kind

type ValidationError* = object
  msg*: string

proc memoryValue(name: string): Value = Value(kind: ValueKind.Reg, name: name, `type`: `Type`(kind: TypeKind.Memory))

proc sealBlock(basicBlock: Block; serial: var int) =
  let initial = memoryValue("$memory" & $serial); inc serial
  var params: seq[Value]
  for parameter in basicBlock.params:
    if parameter.`type`.kind != TypeKind.Memory: params.add(parameter)
  params.add(initial)
  basicBlock.params = params
  var current = initial
  for instruction in basicBlock.instrs:
    if instruction.effects.len > 0 or instruction.kind in {InstrKind.Alloc, InstrKind.Allocate,
        InstrKind.Load, InstrKind.Store, InstrKind.Call, InstrKind.Try, InstrKind.Trace,
        InstrKind.Native, InstrKind.NativeZig, InstrKind.Atomic, InstrKind.Thread,
        InstrKind.Defer, InstrKind.Catch, InstrKind.Index}:
      if instruction.effects.len == 0:
        instruction.effects = case instruction.kind
          of InstrKind.Alloc: @["allocate"]
          of InstrKind.Allocate: @["allocate", "write"]
          of InstrKind.Load, InstrKind.Index: @["read"]
          of InstrKind.Store: @["write"]
          of InstrKind.Call: @["external"]
          of InstrKind.Try, InstrKind.Trace: @["trace"]
          of InstrKind.Native, InstrKind.NativeZig: @["unknown"]
          of InstrKind.Atomic, InstrKind.Thread: @["synchronize"]
          of InstrKind.Defer: @["cleanup"]
          of InstrKind.Catch: @["branch"]
          else: @["unknown"]
      let next = memoryValue("$memory" & $serial); inc serial
      instruction.memory = Memory(input: current.name, output: next.name)
      current = next
    if instruction.fallback != nil: sealBlock(instruction.fallback, serial)
  if basicBlock.term != nil:
    basicBlock.term.memory = Memory(input: current.name)
    if basicBlock.term.kind == InstrKind.Jump:
      basicBlock.term.args = basicBlock.term.args.filterIt(it.`type`.kind != TypeKind.Memory)
      basicBlock.term.args.add(current)
    elif basicBlock.term.kind == InstrKind.Cjump:
      basicBlock.term.trueArgs = basicBlock.term.trueArgs.filterIt(it.`type`.kind != TypeKind.Memory)
      basicBlock.term.falseArgs = basicBlock.term.falseArgs.filterIt(it.`type`.kind != TypeKind.Memory)
      basicBlock.term.trueArgs.add(current); basicBlock.term.falseArgs.add(current)

proc seal*(module: Module): Module =
  for function in module.funcs:
    var serial = 0
    for basicBlock in function.blocks: sealBlock(basicBlock, serial)
  module

proc validate*(module: Module): seq[ValidationError] =
  let errors = new(seq[ValidationError])
  template fail(message: string) = errors[].add(ValidationError(msg: message))
  if module.version != 0 and module.version != 1: fail("Unsupported IR version")
  if module.stage.len > 0 and module.stage notin ["@foo", "@c", "@asm"]: fail("Unknown substrate stage")
  if module.stage.len > 0 and module.stage != "@foo" and module.target.len == 0: fail("A substrate needs a resolved target")
  if module.requires.len > 0 and module.requires notin ["base", "system", "machine", "hardware"]:
    fail("Unknown capability requirement")
  var regions = initHashSet[string]()
  for region in module.regions:
    if region.id in regions: fail("Duplicate region '" & region.id & "'")
    regions.incl(region.id)
  for region in module.regions:
    if region.parent.len > 0 and region.parent notin regions: fail("Unknown parent region '" & region.parent & "'")
    var seen = initHashSet[string]()
    var parent = region.parent
    while parent.len > 0 and parent in regions:
      if parent in seen:
        fail("Circular parent region '" & parent & "'")
        break
      seen.incl(parent)
      for candidate in module.regions:
        if candidate.id == parent:
          parent = candidate.parent
          break
  for region in module.regions:
    if region.kind notin ["scope", "managed", "static"]: fail("Unknown region kind '" & region.kind & "'")
  var traces = initHashSet[string]()
  for trace in module.traces:
    if trace.id in traces: fail("Duplicate trace '" & trace.id & "'")
    traces.incl(trace.id)
  var native = initHashSet[string]()
  for contract in module.native:
    if contract.id in native: fail("Duplicate native contract '" & contract.id & "'")
    native.incl(contract.id)
    if contract.stage notin ["@foo", "@c", "@asm"]: fail("Invalid substrate for '" & contract.id & "'")
    if contract.code.len == 0 or contract.abi.len == 0 or contract.effects.len == 0: fail("Native contract '" & contract.id & "' needs a payload, ABI and explicit effects")
    if contract.abi == "foo.native:1":
      try:
        let payload = parseJson(contract.code)
        var valid = payload.kind == JObject and payload.getOrDefault("format").getStr() == "foo.native" and
          payload.getOrDefault("version").getInt() == 1 and payload.getOrDefault("source").kind == JString and
          payload.getOrDefault("parameters").kind == JArray
        if valid:
          for key, _ in payload:
            if key notin ["format", "version", "parameters", "source"]: valid = false
          var names = initHashSet[string]()
          for item in payload["parameters"]:
            if item.kind != JString: valid = false; continue
            let name = item.getStr()
            if name.len == 0 or not (name[0].isAlphaAscii or name[0] == '_') or name.anyIt(not (it.isAlphaNumeric or it == '_')) or name in names:
              valid = false
            names.incl(name)
          var matched = false
          for external in module.externs:
            if external.symbol == contract.id:
              matched = true
              if external.params.len != names.len: valid = false
          if not matched: valid = false
        if not valid: fail("Invalid native binding payload")
      except CatchableError: fail("Invalid native binding payload")

  proc same(left, right: `Type`; depth = 0): bool =
    if left == nil or right == nil: return left == right
    if depth > 128: return false
    if left.kind != right.kind or left.name != right.name or left.width != right.width or
        left.constant != right.constant or left.volatile != right.volatile or left.abi != right.abi or left.attributes != right.attributes:
      return false
    if not same(left.elem, right.elem, depth + 1): return false
    if left.params.len != right.params.len or left.fields.len != right.fields.len or left.variants.len != right.variants.len: return false
    for index in 0 ..< left.params.len:
      if not same(left.params[index], right.params[index], depth + 1): return false
    for name, value in left.fields:
      if not right.fields.hasKey(name) or not same(value, right.fields[name], depth + 1): return false
    for name, value in left.variants:
      if not right.variants.hasKey(name) or not same(value, right.variants[name], depth + 1): return false
    true

  var checkedTypes = initHashSet[pointer]()
  proc checkType(value: `Type`) =
    if value == nil: fail("Unknown or missing IR type"); return
    let identity = cast[pointer](value)
    if identity in checkedTypes: return
    checkedTypes.incl(identity)
    case value.kind
    of TypeKind.Int, TypeKind.Uint:
      if value.width != 0 and (value.width < 1 or value.width > 128): fail("Integer width must be between 1 and 128")
    of TypeKind.Float:
      if value.width notin [0, 32, 64]: fail("Floating width must be 32 or 64")
    of TypeKind.Array, TypeKind.Vector:
      if value.width < 1: fail("Array and vector types need a positive length")
      if value.elem == nil: fail("Container type needs an element type")
    of TypeKind.Ptr, TypeKind.Slice, TypeKind.Optional, TypeKind.Fallible:
      if value.elem == nil: fail("Container type needs an element type")
    of TypeKind.Function:
      if value.ret == nil: fail("Function type needs parameters and a result")
    else: discard
    if value.elem != nil: checkType(value.elem)
    for parameter in value.params: checkType(parameter)
    if value.ret != nil: checkType(value.ret)
    for field in value.fields.values: checkType(field)
    for variant in value.variants.values:
      if variant != nil: checkType(variant)

  for declaration in module.types: checkType(declaration.`type`)
  var globals = initTable[string, `Type`]()
  var signatures = initTable[string, tuple[params: seq[`Type`], ret: `Type`]]()
  for item in module.storage:
    if globals.hasKey(item.name) or module.funcs.anyIt(it.name == item.name) or module.externs.anyIt(it.name == item.name):
      fail("Duplicate storage symbol '" & item.name & "'")
    checkType(item.value.`type`)
    if item.value.kind != ValueKind.Const or item.value.name == "undefined":
      fail("Static storage needs a defined compile-time initializer")
    else:
      try:
        case item.value.`type`.kind
        of TypeKind.Int, TypeKind.Uint:
          let number = parseBiggestInt(item.value.name.replace("_", ""))
          let width = if item.value.`type`.width > 0: item.value.`type`.width else: 32
          let minimum = if item.value.`type`.kind == TypeKind.Uint: 0'i64 else: -(1'i64 shl min(width - 1, 62))
          let maximum = if item.value.`type`.kind == TypeKind.Uint: (if width >= 63: high(int64) else: (1'i64 shl width) - 1) else: (if width >= 63: high(int64) else: (1'i64 shl (width - 1)) - 1)
          if number < minimum or number > maximum: fail("Invalid static initializer for '" & item.name & "'")
        of TypeKind.Float:
          if item.value.bits.len == 0: discard parseFloat(item.value.name)
        of TypeKind.Bool:
          if item.value.name notin ["true", "false"]: fail("Invalid static initializer for '" & item.name & "'")
        of TypeKind.Slice: discard bytes(item.value.name)
        of TypeKind.Optional:
          if item.value.name != "null": fail("Invalid static initializer for '" & item.name & "'")
        else: fail("Invalid static initializer for '" & item.name & "'")
      except CatchableError: fail("Invalid static initializer for '" & item.name & "'")
    globals[item.name] = item.value.`type`

  for external in module.externs:
    if signatures.hasKey(external.name) or globals.hasKey(external.name): fail("Duplicate function @" & external.name)
    for parameter in external.params: checkType(parameter)
    checkType(external.ret)
    signatures[external.name] = (external.params, external.ret)
  for function in module.funcs:
    if signatures.hasKey(function.name) or globals.hasKey(function.name): fail("Duplicate function @" & function.name)
    for parameter in function.params: checkType(parameter.`type`)
    checkType(function.ret)
    signatures[function.name] = (function.params.mapIt(it.`type`), function.ret)

  proc compatible(value: Value; target: `Type`): bool =
    same(value.`type`, target) or
      (target != nil and target.kind == TypeKind.Fallible and same(value.`type`, target.elem)) or
      (target != nil and target.kind == TypeKind.Optional and
        (same(value.`type`, target.elem) or (value.`type` != nil and value.`type`.kind == TypeKind.Void)))

  proc values(instruction: Instruction): seq[Value] =
    if instruction == nil: return
    for value in @[instruction.val, instruction.val2, instruction.`ptr`, instruction.target,
        instruction.callee, instruction.cond, instruction.value, instruction.expr] &
        instruction.args & instruction.trueArgs & instruction.falseArgs:
      if value.`type` != nil: result.add(value)

  let terminators = {InstrKind.Return, InstrKind.Jump, InstrKind.Cjump, InstrKind.Panic}
  let effectful = {InstrKind.Load, InstrKind.Store, InstrKind.Call, InstrKind.Alloc,
    InstrKind.Allocate, InstrKind.Try, InstrKind.Trace, InstrKind.Native,
    InstrKind.NativeZig, InstrKind.Atomic, InstrKind.Thread, InstrKind.Region,
    InstrKind.Index, InstrKind.Defer, InstrKind.Catch}

  for function in module.funcs:
    let functionName = function.name
    let functionResult = function.ret
    if function.blocks.len == 0:
      fail("Function @" & function.name & " has no entry block")
      continue
    var blocks = initTable[string, Block]()
    var predecessors = initTable[string, HashSet[string]]()
    var definitions = initTable[string, tuple[owner: string, index: int, typ: `Type`]]()

    proc define(value: Value; owner: string; index: int) =
      checkType(value.`type`)
      if value.kind != ValueKind.Reg:
        fail("Instruction results and parameters must be registers")
      elif definitions.hasKey(value.name):
        fail("Redefinition of register %" & value.name)
      else:
        definitions[value.name] = (owner, index, value.`type`)

    for parameter in function.params: define(parameter, "", -1)
    for basicBlock in function.blocks:
      if blocks.hasKey(basicBlock.label): fail("Duplicate block " & basicBlock.label)
      blocks[basicBlock.label] = basicBlock
      predecessors[basicBlock.label] = initHashSet[string]()
      for parameter in basicBlock.params: define(parameter, basicBlock.label, -1)
      for index, instruction in basicBlock.instrs:
        if instruction == nil: continue
        if instruction.dest.`type` != nil: define(instruction.dest, basicBlock.label, index)
        if instruction.memory.output.len > 0:
          define(Value(kind: ValueKind.Reg, name: instruction.memory.output,
            `type`: `Type`(kind: TypeKind.Memory)), basicBlock.label, index)

    proc edge(source, target: string; args: seq[Value]; term: Instruction) =
      if target.len == 0 or not blocks.hasKey(target):
        fail("Unknown jump target " & (if target.len == 0: "<missing>" else: target))
        return
      predecessors[target].incl(source)
      let params = blocks[target].params
      var matches = args.len == params.len
      if matches:
        for index, argument in args:
          if not same(argument.`type`, params[index].`type`): matches = false
      if not matches: fail("Edge to " & target & " does not match its block parameters")
      if module.version == 1:
        for index, parameter in params:
          if parameter.`type`.kind == TypeKind.Memory and
              (index >= args.len or args[index].name != term.memory.input):
            fail("Edge to " & target & " loses its memory dependency")

    for basicBlock in function.blocks:
      let term = basicBlock.term
      if term == nil or term.kind notin terminators:
        fail("Block " & basicBlock.label & " lacks a valid terminator")
        continue
      if term.kind == InstrKind.Jump:
        edge(basicBlock.label, term.label, term.args, term)
      elif term.kind == InstrKind.Cjump:
        edge(basicBlock.label, term.trueLabel, term.trueArgs, term)
        edge(basicBlock.label, term.falseLabel, term.falseArgs, term)

    let entry = function.blocks[0].label
    var reachable = initHashSet[string]()
    var queue = @[entry]
    while queue.len > 0:
      let label = queue.pop()
      if label in reachable or not blocks.hasKey(label): continue
      reachable.incl(label)
      let term = blocks[label].term
      if term != nil and term.kind == InstrKind.Jump: queue.add(term.label)
      elif term != nil and term.kind == InstrKind.Cjump:
        queue.add(term.trueLabel); queue.add(term.falseLabel)

    var dominators = initTable[string, HashSet[string]]()
    for basicBlock in function.blocks:
      if basicBlock.label == entry or basicBlock.label notin reachable:
        dominators[basicBlock.label] = toHashSet([basicBlock.label])
      else:
        dominators[basicBlock.label] = reachable
    var changed = true
    while changed:
      changed = false
      for basicBlock in function.blocks:
        if basicBlock.label == entry or basicBlock.label notin reachable: continue
        let incoming = predecessors[basicBlock.label].toSeq.filterIt(it in reachable)
        var next = initHashSet[string]()
        if incoming.len > 0:
          for candidate in dominators[incoming[0]]:
            if incoming.allIt(candidate in dominators[it]): next.incl(candidate)
        next.incl(basicBlock.label)
        if next != dominators[basicBlock.label]:
          dominators[basicBlock.label] = next
          changed = true

    proc use(value: Value; owner: string; index: int) =
      checkType(value.`type`)
      if value.kind == ValueKind.Global:
        if globals.hasKey(value.name):
          if value.`type`.kind != TypeKind.Ptr or not same(value.`type`.elem, globals[value.name]):
            fail("Storage symbol '" & value.name & "' has the wrong pointer type")
        elif not signatures.hasKey(value.name) or value.`type`.kind != TypeKind.Function or
            not same(value.`type`.ret, signatures[value.name].ret) or
            value.`type`.params.len != signatures[value.name].params.len:
          fail("Unknown or mistyped global symbol '" & value.name & "'")
        else:
          for parameterIndex, parameter in signatures[value.name].params:
            if not same(parameter, value.`type`.params[parameterIndex]):
              fail("Unknown or mistyped global symbol '" & value.name & "'")
        return
      if value.kind != ValueKind.Reg: return
      if not definitions.hasKey(value.name):
        fail("Use of undefined register %" & value.name)
        return
      let definition = definitions[value.name]
      if not same(definition.typ, value.`type`): fail("Register %" & value.name & " changes type")
      if (definition.owner == owner and definition.index >= index) or
          (definition.owner.len > 0 and definition.owner != owner and definition.owner notin dominators[owner]):
        fail("Definition of %" & value.name & " does not dominate its use in " & owner)

    proc inspect(instruction: Instruction; owner: string; index: int) =
      if instruction == nil: return
      if module.version == 1 and instruction.kind in effectful and
          (instruction.memory.input.len == 0 or instruction.memory.output.len == 0 or instruction.effects.len == 0):
        fail("Effectful operation needs explicit effects and a memory dependency")
      if instruction.panic.len > 0 and not blocks.hasKey(instruction.panic):
        fail("Unknown panic successor '" & instruction.panic & "'")
      if instruction.trace.len > 0 and instruction.trace notin traces:
        fail("Unknown trace slot '" & instruction.trace & "'")
      if instruction.trace.len > 0:
        for trace in module.traces:
          if trace.id == instruction.trace and trace.`function` != functionName:
            fail("Trace slot '" & instruction.trace & "' belongs to another function")
      if instruction.kind == InstrKind.Trace and (instruction.trace.len == 0 or "trace" notin instruction.effects):
        fail("Trace append needs a trace slot and trace effect")
      if instruction.kind == InstrKind.Thread and
          (instruction.func.len == 0 or not signatures.hasKey(instruction.func) or "synchronize" notin instruction.effects):
        fail("Thread operation needs a declared runtime contract and synchronization edge")
      if module.version == 1 and instruction.region.len > 0 and instruction.region notin regions:
        fail("Unknown arena '" & instruction.region & "'")
      if instruction.kind == InstrKind.Native and not instruction.op.startsWith("machine:") and
          (instruction.symbol.len == 0 or instruction.symbol notin native):
        fail("Native operation needs a declared contract")

      if instruction.kind == InstrKind.Atomic:
        let operation = instruction.op
        let ordering = instruction.field
        let orders = ["relaxed", "acquire", "release", "acq_rel", "seq_cst"]
        if operation notin ["load", "store", "add", "swap", "fence"] or ordering notin orders:
          fail("Atomic operation needs an operation and explicit memory ordering")
        if "synchronize" notin instruction.effects:
          fail("Atomic operation must preserve its synchronization edge")
        if (operation == "load" and ordering in ["release", "acq_rel"]) or
            (operation == "store" and ordering in ["acquire", "acq_rel"]) or
            (operation == "fence" and ordering == "relaxed"):
          fail("Invalid memory ordering for atomic operation")
        if operation != "fence":
          let pointer = instruction.`ptr`.`type`
          let element = if pointer != nil: pointer.elem else: nil
          if pointer == nil or pointer.kind != TypeKind.Ptr or element == nil or
              element.kind notin {TypeKind.Int, TypeKind.Uint} or
              (if element.width > 0: element.width else: 32) notin [8, 16, 32, 64] or
              "atomic" notin element.attributes:
            fail("Atomic operation needs a pointer to atomic integer storage")
          elif operation != "load":
            let plain = `Type`(kind: element.kind, name: element.name, elem: element.elem,
              width: element.width, fields: element.fields, fieldAttrs: element.fieldAttrs,
              variants: element.variants, params: element.params, ret: element.ret,
              abi: element.abi, volatile: element.volatile, constant: element.constant)
            if instruction.val.`type` == nil or not same(instruction.val.`type`, plain):
              fail("Atomic value does not match its storage")
          if element != nil and operation != "store":
            let plain = `Type`(kind: element.kind, name: element.name, elem: element.elem,
              width: element.width, fields: element.fields, fieldAttrs: element.fieldAttrs,
              variants: element.variants, params: element.params, ret: element.ret,
              abi: element.abi, volatile: element.volatile, constant: element.constant)
            if instruction.dest.`type` == nil or not same(instruction.dest.`type`, plain):
              fail("Atomic result does not match its storage")
        if operation in ["store", "fence"] and instruction.dest.`type` != nil:
          fail("Atomic store/fence has no result")
      if instruction.kind == InstrKind.Allocate:
        if instruction.region.len == 0 or instruction.dest.`type` == nil or
            instruction.dest.`type`.kind != TypeKind.Fallible or instruction.dest.`type`.elem == nil or
            instruction.dest.`type`.elem.kind != TypeKind.Slice or instruction.val.`type` == nil:
          fail("Arena allocation needs a size, region and fallible sequence result")
        elif instruction.val.`type`.kind notin {TypeKind.Int, TypeKind.Uint}:
          fail("Allocation size must be an integer")
      if instruction.kind == InstrKind.Region and
          (instruction.region.len == 0 or instruction.op notin ["open", "close"]):
        fail("Region operations must open or close an identified arena")
      if instruction.kind == InstrKind.Convert:
        let source = instruction.val.`type`
        let target = instruction.dest.`type`
        proc numeric(value: `Type`): bool = value != nil and value.kind in {TypeKind.Int, TypeKind.Uint, TypeKind.Float}
        proc bits(value: `Type`): int =
          if value.width > 0: value.width elif value.kind == TypeKind.Float: 64 else: 32
        let widened = source != nil and target != nil and numeric(source) and numeric(target) and
          (if source.kind == target.kind: bits(source) <= bits(target)
           elif source.kind == TypeKind.Uint and target.kind == TypeKind.Int: bits(source) < bits(target)
           elif source.kind != TypeKind.Float and target.kind == TypeKind.Float:
             bits(source) - (if source.kind == TypeKind.Int: 1 else: 0) <= (if bits(target) == 32: 24 else: 53)
           else: false)
        let lifted = source != nil and target != nil and target.kind in {TypeKind.Optional, TypeKind.Fallible} and same(source, target.elem)
        let view = source != nil and target != nil and source.kind == TypeKind.Slice and
          target.kind == TypeKind.Slice and target.constant and same(source.elem, target.elem)
        if not widened and not lifted and not view and not same(source, target):
          fail("Conversion is not a lossless widening or wrapper injection")
      if instruction.kind == InstrKind.Index:
        let source = instruction.val.`type`
        let destination = instruction.dest.`type`
        let actual = if instruction.op == "address" and destination != nil: destination.elem else: destination
        if source == nil or source.elem == nil or instruction.val2.`type` == nil or destination == nil or
            not same(actual, source.elem):
          fail("Index needs a sequence, index and matching element result")
      if instruction.kind == InstrKind.Length:
        if instruction.val.`type` == nil or instruction.val.`type`.kind notin {TypeKind.Slice, TypeKind.Array, TypeKind.Vector} or
            instruction.dest.`type` == nil or instruction.dest.`type`.kind notin {TypeKind.Int, TypeKind.Uint}:
          fail("Length needs a sequence and integer result")
      if instruction.kind == InstrKind.Construct:
        let target = instruction.dest.`type`
        var fields: seq[`Type`]
        var found = false
        if target != nil and target.kind == TypeKind.Fallible and instruction.op == "error":
          fields = @[`Type`(kind: TypeKind.Error)]; found = true
        elif target != nil and target.kind == TypeKind.TaggedUnion and target.variants.hasKey(instruction.field):
          found = true
          if target.variants[instruction.field] != nil: fields.add(target.variants[instruction.field])
        elif target != nil and target.kind in {TypeKind.Struct, TypeKind.PackedStruct, TypeKind.ExternStruct, TypeKind.ExternUnion}:
          found = true
          for field in target.fields.values: fields.add(field)
        if not found or fields.len != instruction.args.len:
          fail("Construction does not match its declared fields or variant")
        else:
          for fieldIndex, field in fields:
            if not same(field, instruction.args[fieldIndex].`type`):
              fail("Construction does not match its declared fields or variant")
      if instruction.kind == InstrKind.Extract:
        let original = instruction.val.`type`
        let source = if original != nil and original.kind == TypeKind.Ptr: original.elem else: original
        var projected: `Type`
        if source != nil and source.kind == TypeKind.Fallible:
          if instruction.field == "failed": projected = `Type`(kind: TypeKind.Bool)
          elif instruction.field == "value": projected = source.elem
        elif source != nil and source.kind == TypeKind.TaggedUnion:
          if instruction.field == "tag": projected = `Type`(kind: TypeKind.Uint, width: 32)
          elif source.variants.hasKey(instruction.field): projected = source.variants[instruction.field]
        elif source != nil and source.fields.hasKey(instruction.field):
          projected = source.fields[instruction.field]
        let destination = instruction.dest.`type`
        let actual = if instruction.op == "address" and destination != nil: destination.elem else: destination
        if projected == nil or not same(projected, actual):
          fail("Projection does not match its source layout")

      for value in values(instruction): use(value, owner, index)
      if instruction.kind == InstrKind.Phi:
        var labels = initHashSet[string]()
        for incoming in instruction.blocks: labels.incl(incoming.label)
        if labels.len != instruction.blocks.len or labels != predecessors[owner]:
          fail("Phi in " & owner & " must cover each predecessor exactly once")
        for incoming in instruction.blocks:
          use(incoming.value, incoming.label, high(int))
          if instruction.dest.`type` != nil and not same(incoming.value.`type`, instruction.dest.`type`):
            fail("Phi in " & owner & " has inconsistent incoming types")
      if instruction.kind in {InstrKind.Add, InstrKind.Sub, InstrKind.Mul, InstrKind.Div, InstrKind.Remainder}:
        if instruction.dest.`type` == nil or instruction.val.`type` == nil or instruction.val2.`type` == nil or
            not same(instruction.dest.`type`, instruction.val.`type`) or not same(instruction.val.`type`, instruction.val2.`type`):
          fail("Arithmetic operands and result must have equal types")
        elif instruction.dest.`type`.kind notin {TypeKind.Int, TypeKind.Uint, TypeKind.Float, TypeKind.Vector} and
            not (instruction.kind == InstrKind.Add and instruction.dest.`type`.kind == TypeKind.Slice and instruction.dest.`type`.constant):
          fail("Arithmetic requires numeric operands")
      if instruction.kind == InstrKind.Compare:
        let expected = if instruction.val.`type` != nil and instruction.val.`type`.kind == TypeKind.Vector:
          `Type`(kind: TypeKind.Vector, width: instruction.val.`type`.width, elem: `Type`(kind: TypeKind.Bool))
        else: `Type`(kind: TypeKind.Bool)
        if instruction.val.`type` == nil or instruction.val2.`type` == nil or instruction.dest.`type` == nil or
            not same(instruction.val.`type`, instruction.val2.`type`) or not same(instruction.dest.`type`, expected):
          fail("Comparison needs equal operand types and a Boolean result")
      if instruction.kind == InstrKind.Not and
          (instruction.val.`type` == nil or instruction.val.`type`.kind != TypeKind.Bool or
           instruction.dest.`type` == nil or instruction.dest.`type`.kind != TypeKind.Bool):
        fail("Negation needs a Boolean operand and result")
      if instruction.kind in {InstrKind.Call, InstrKind.Thread}:
        var signature: tuple[params: seq[`Type`], ret: `Type`]
        var found = false
        if instruction.callee.`type` != nil and instruction.callee.`type`.kind == TypeKind.Function:
          signature = (instruction.callee.`type`.params, instruction.callee.`type`.ret); found = true
        elif instruction.func.len > 0 and signatures.hasKey(instruction.func):
          signature = signatures[instruction.func]; found = true
        if not found: fail("Unknown call target " & (if instruction.func.len > 0: instruction.func else: "<indirect>"))
        else:
          if instruction.args.len != signature.params.len: fail("Call argument count does not match its signature")
          for argumentIndex, argument in instruction.args:
            if argumentIndex < signature.params.len and not compatible(argument, signature.params[argumentIndex]):
              fail("Call argument " & $(argumentIndex + 1) & " has the wrong type")
          if instruction.dest.`type` != nil and not same(instruction.dest.`type`, signature.ret):
            fail("Call result does not match its signature")
      if instruction.kind == InstrKind.Cjump and
          (instruction.cond.`type` == nil or instruction.cond.`type`.kind != TypeKind.Bool):
        fail("Conditional branch needs a Boolean")
      if instruction.kind == InstrKind.Return:
        if instruction.value.`type` != nil:
          if not compatible(instruction.value, functionResult): fail("Return does not match @" & functionName & "'s result")
        elif functionResult.kind != TypeKind.Void and not (functionResult.kind == TypeKind.Fallible and functionResult.elem != nil and functionResult.elem.kind == TypeKind.Void):
          fail("Return does not match @" & functionName & "'s result")
      if instruction.kind == InstrKind.Load and
          (instruction.`ptr`.`type` == nil or instruction.`ptr`.`type`.kind != TypeKind.Ptr or
           instruction.`ptr`.`type`.elem == nil or instruction.dest.`type` == nil or
           not same(instruction.`ptr`.`type`.elem, instruction.dest.`type`)):
        fail("Load result does not match pointer element")
      if instruction.kind == InstrKind.Store and
          (instruction.`ptr`.`type` == nil or instruction.`ptr`.`type`.kind != TypeKind.Ptr or
           instruction.`ptr`.`type`.constant or instruction.`ptr`.`type`.elem == nil or
           instruction.val.`type` == nil or not compatible(instruction.val, instruction.`ptr`.`type`.elem)):
        fail("Store value does not match writable pointer element")
      if instruction.kind == InstrKind.Alloc and
          (instruction.region.len == 0 or instruction.dest.`type` == nil or instruction.dest.`type`.kind != TypeKind.Ptr):
        fail("Allocation needs a region and pointer result")
      if instruction.kind == InstrKind.Try and
          (instruction.expr.`type` == nil or instruction.expr.`type`.kind notin {TypeKind.Fallible, TypeKind.Error}):
        fail("Try requires a fallible operand")

    for basicBlock in function.blocks:
      var memory = ""
      for parameter in basicBlock.params:
        if parameter.`type`.kind == TypeKind.Memory: memory = parameter.name
      for index, instruction in basicBlock.instrs:
        if instruction == nil: continue
        if instruction.memory.input.len > 0 or instruction.memory.output.len > 0:
          if instruction.memory.input != memory or instruction.memory.output.len == 0:
            fail("Broken memory dependency in " & basicBlock.label)
          memory = instruction.memory.output
        elif memory.len > 0 and instruction.effects.len > 0:
          fail("Effectful instruction in " & basicBlock.label & " has no memory dependency")
        if instruction.kind in terminators: fail("Instruction " & $instruction.kind & " must be a terminator")
        inspect(instruction, basicBlock.label, index)
      if basicBlock.term != nil:
        inspect(basicBlock.term, basicBlock.label, basicBlock.instrs.len)
        if memory.len > 0 and basicBlock.term.memory.input != memory:
          fail("Terminator in " & basicBlock.label & " loses its memory dependency")

  proc finite(value: `Type`; active: var HashSet[pointer]): bool =
    if value == nil or value.kind in {TypeKind.Ptr, TypeKind.Slice, TypeKind.Function, TypeKind.Opaque}: return true
    let identity = cast[pointer](value)
    if identity in active: return false
    active.incl(identity)
    result = value.elem == nil or finite(value.elem, active)
    if result:
      for field in value.fields.values:
        if not finite(field, active): result = false; break
    if result:
      for variant in value.variants.values:
        if variant != nil and not finite(variant, active): result = false; break
    active.excl(identity)
  for identity in checkedTypes:
    let value = cast[`Type`](identity)
    var active = initHashSet[pointer]()
    if not finite(value, active):
      fail("A type contains itself by value and has no finite layout")
      break
  result = errors[]
