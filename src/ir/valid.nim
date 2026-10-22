import std/[json, sets, strutils, tables, sequtils]
import ./node
import ./kind
import ../types/coerce as conversion
import ../types/type as semantic

type Type = node.Type

type Failure* = object
  msg*: string

proc memory(name: string): Value = Value(kind: Flavor.Reg, name: name, `type`: `Type`(kind: Shape.Memory))

proc seal(section: Block; serial: var int) =
  let initial = memory("$memory" & $serial); inc serial
  var params: seq[Value]
  for parameter in section.params:
    if parameter.`type`.kind != Shape.Memory: params.add(parameter)
  params.add(initial)
  section.params = params
  var current = initial
  for instruction in section.instrs:
    if instruction.effects.len > 0 or instruction.kind in {Opcode.Alloc, Opcode.Allocate,
        Opcode.Load, Opcode.Store, Opcode.Call, Opcode.Try, Opcode.Trace,
        Opcode.Native, Opcode.Atomic, Opcode.Thread, Opcode.Region,
        Opcode.Defer, Opcode.Catch, Opcode.Index, Opcode.Gather, Opcode.Scatter} or
        (instruction.kind == Opcode.Bit and instruction.op in
          ["shl", "lshr", "ashr", "set", "clear", "toggle"]):
      if instruction.effects.len == 0:
        instruction.effects = case instruction.kind
          of Opcode.Alloc: @["allocate"]
          of Opcode.Allocate: @["allocate", "write"]
          of Opcode.Region: @["allocate", "write"]
          of Opcode.Load, Opcode.Index: @["read"]
          of Opcode.Gather, Opcode.Scatter, Opcode.Bit: @["check"]
          of Opcode.Store: @["write"]
          of Opcode.Call: @["external"]
          of Opcode.Try, Opcode.Trace: @["trace"]
          of Opcode.Native: @["unknown"]
          of Opcode.Atomic, Opcode.Thread: @["synchronize"]
          of Opcode.Defer: @["cleanup"]
          of Opcode.Catch: @["branch"]
          else: @["unknown"]
      let next = memory("$memory" & $serial); inc serial
      instruction.memory = Memory(input: current.name, output: next.name)
      current = next
    if instruction.fallback != nil: seal(instruction.fallback, serial)
    for section in instruction.fallbackBlocks: seal(section, serial)
  if section.term != nil:
    section.term.memory = Memory(input: current.name)
    if section.term.kind == Opcode.Jump:
      section.term.args = section.term.args.filterIt(it.`type`.kind != Shape.Memory)
      section.term.args.add(current)
    elif section.term.kind == Opcode.Cjump:
      section.term.positive = section.term.positive.filterIt(it.`type`.kind != Shape.Memory)
      section.term.negative = section.term.negative.filterIt(it.`type`.kind != Shape.Memory)
      section.term.positive.add(current); section.term.negative.add(current)

proc seal*(module: Module): Module =
  for function in module.funcs:
    var serial = 0
    for section in function.blocks: seal(section, serial)
  module

proc validate*(module: Module): seq[Failure] =
  let errors = new(seq[Failure])
  template fail(message: string) = errors[].add(Failure(msg: message))
  if module.version != 0 and module.version != 1: fail("Unsupported IR version")
  if module.stage.len > 0 and module.stage notin ["@foo", "@c", "@asm"]: fail("Unknown substrate stage")
  if module.stage.len > 0 and module.stage != "@foo" and module.target.len == 0: fail("A substrate needs a resolved target")
  if module.requires.len > 0 and module.requires notin ["base", "system", "machine", "hardware"]:
    fail("Unknown capability requirement")
  for item in module.storage:
    if item.alignment < 0 or item.alignment > 2097152 or
        (item.alignment > 0 and
          (item.alignment and (item.alignment - 1)) != 0):
      fail("Storage alignment must be a power of two at most 2 MiB: " &
        item.name)
    if item.section.len > 0 and (item.section[0] != '.' or
        item.section.anyIt(not (it.isAlphaNumeric or it in {'_', '.', '-'}))):
      fail("Invalid storage section name: " & item.name)
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

  # Validation may inspect temporary inferred types. Retain the objects until
  # the deferred finite-layout check; a set of raw addresses is not a GC root.
  var checked = initTable[pointer, `Type`]()
  proc typed(value: `Type`) =
    if value == nil: fail("Unknown or missing IR type"); return
    let identity = cast[pointer](value)
    if identity in checked: return
    checked[identity] = value
    case value.kind
    of Shape.Int, Shape.Uint:
      if value.width != 0 and (value.width < 1 or value.width > 128): fail("Integer width must be between 1 and 128")
    of Shape.Float:
      if value.width notin [0, 32, 64]: fail("Floating width must be 32 or 64")
    of Shape.Array, Shape.Vector:
      if value.width < 1: fail("Array and vector types need a positive length")
      if value.elem == nil: fail("Container type needs an element type")
    of Shape.Ptr, Shape.Slice, Shape.Optional, Shape.Failable:
      if value.elem == nil: fail("Container type needs an element type")
    of Shape.Function:
      if value.ret == nil: fail("Function type needs parameters and a result")
    else: discard
    if value.elem != nil: typed(value.elem)
    for parameter in value.params: typed(parameter)
    if value.ret != nil: typed(value.ret)
    for field in value.fields.values: typed(field)
    for variant in value.variants.values:
      if variant != nil: typed(variant)

  for declaration in module.types: typed(declaration.`type`)
  var globals = initTable[string, `Type`]()
  var signatures = initTable[string, tuple[params: seq[`Type`], ret: `Type`]]()
  proc constant(value: Value): bool =
    if value.type == nil: return false
    case value.type.kind
    of Shape.Int, Shape.Uint:
      # Use the frontend's exact decimal range proof, including widths >64.
      conversion.coercion(semantic.Type(kind:"literal",value:value.name),
        semantic.Type(kind:"primitive",name:(if value.type.kind == Shape.Int: "integer" else:"unsigned"),
          width:(if value.type.width > 0: value.type.width else:32))).ok
    of Shape.Float:
      if value.bits.len == 0: discard parseFloat(value.name)
      true
    of Shape.Bool: value.name in ["true", "false"]
    of Shape.Slice:
      discard bytes(value.name)
      true
    of Shape.Optional, Shape.Failable:
      if value.type.kind == Shape.Optional and value.name == "null": return true
      var inner = value; inner.type = value.type.elem
      constant(inner)
    of Shape.Array, Shape.Vector, Shape.Struct, Shape.ExternStruct,
        Shape.TaggedUnion, Shape.ExternUnion, Shape.PackedStruct:
      value.bits.len > 0 and value.bits.len mod 2 == 0 and
        value.bits.allIt(it in {'0'..'9', 'a'..'f'})
    of Shape.Void: value.name in ["void", "{}"]
    else: false
  for item in module.storage:
    if globals.hasKey(item.name) or module.funcs.anyIt(it.name == item.name) or module.externs.anyIt(it.name == item.name):
      fail("Duplicate storage symbol '" & item.name & "'")
    typed(item.value.`type`)
    if item.value.kind != Flavor.Const or item.value.name == "undefined":
      fail("Static storage needs a defined compile-time initializer")
    else:
      try:
        if not constant(item.value): fail("Invalid static initializer for '" & item.name & "'")
      except CatchableError: fail("Invalid static initializer for '" & item.name & "'")
    globals[item.name] = item.value.`type`

  for external in module.externs:
    if signatures.hasKey(external.name) or globals.hasKey(external.name): fail("Duplicate function @" & external.name)
    for parameter in external.params: typed(parameter)
    typed(external.ret)
    signatures[external.name] = (external.params, external.ret)
  for function in module.funcs:
    if signatures.hasKey(function.name) or globals.hasKey(function.name): fail("Duplicate function @" & function.name)
    for parameter in function.params: typed(parameter.`type`)
    typed(function.ret)
    signatures[function.name] = (function.params.mapIt(it.`type`), function.ret)

  proc compatible(value: Value; target: `Type`): bool =
    same(value.`type`, target) or
      (target != nil and target.kind == Shape.Failable and same(value.`type`, target.elem)) or
      (target != nil and target.kind == Shape.Optional and
        (same(value.`type`, target.elem) or (value.`type` != nil and value.`type`.kind == Shape.Void)))

  proc values(instruction: Instruction): seq[Value] =
    if instruction == nil: return
    for value in @[instruction.val, instruction.val2, instruction.`ptr`, instruction.target,
        instruction.callee, instruction.cond, instruction.value, instruction.expr] &
        instruction.args & instruction.positive & instruction.negative:
      if value.`type` != nil: result.add(value)

  let terminators = {Opcode.Return, Opcode.Jump, Opcode.Cjump, Opcode.Panic}
  let effectful = {Opcode.Load, Opcode.Store, Opcode.Call, Opcode.Alloc,
    Opcode.Allocate, Opcode.Try, Opcode.Trace, Opcode.Native,
    Opcode.Atomic, Opcode.Thread, Opcode.Region,
    Opcode.Index, Opcode.Defer, Opcode.Catch, Opcode.Gather, Opcode.Scatter}

  for function in module.funcs:
    let symbol = function.name
    let returned = function.ret
    if function.blocks.len == 0:
      fail("Function @" & function.name & " has no entry block")
      continue
    proc checkFallback(instruction: Instruction)
    proc checkFallback(instruction: Instruction) =
      if instruction == nil: return
      if instruction.fallback == nil:
        if instruction.fallbackBlocks.len > 0 or
            instruction.kind in {Opcode.Catch, Opcode.Defer}:
          fail("Fallback graph needs an entry block")
        return
      if instruction.kind notin {Opcode.Catch, Opcode.Defer}: return
      var sections = @[instruction.fallback]
      sections.add(instruction.fallbackBlocks)
      var local = initTable[string, Block]()
      var predecessors = initTable[string, HashSet[string]]()
      for section in sections:
        if section == nil or section.label.len == 0:
          fail("Fallback graph has an unnamed block")
          continue
        if local.hasKey(section.label):
          fail("Duplicate fallback block " & section.label)
        local[section.label] = section
        predecessors[section.label] = initHashSet[string]()
      proc branch(source, target: string; args: seq[Value]) =
        if not local.hasKey(target):
          fail("Unknown fallback jump target " & target)
          return
        predecessors[target].incl(source)
        let params = local[target].params
        if params.len != args.len:
          fail("Fallback edge to " & target & " does not match block parameters")
        else:
          for index, parameter in params:
            if not same(parameter.type, args[index].type):
              fail("Fallback edge to " & target & " changes parameter type")
      for section in sections:
        if section == nil: continue
        for child in section.instrs: checkFallback(child)
        let term = section.term
        if term == nil:
          if instruction.kind == Opcode.Catch or
              section != instruction.fallback:
            fail("Fallback block " & section.label & " lacks a terminator")
          continue
        case term.kind
        of Opcode.Jump: branch(section.label, term.label, term.args)
        of Opcode.Cjump:
          if term.cond.type == nil or term.cond.type.kind != Shape.Bool or
              term.yes == term.no:
            fail("Invalid fallback branch in " & section.label)
          branch(section.label, term.yes, term.positive)
          branch(section.label, term.no, term.negative)
        of Opcode.Return:
          if instruction.kind == Opcode.Catch:
            if instruction.dest.type == nil or
                (instruction.dest.type.kind != Shape.Void and
                  not same(instruction.dest.type, term.value.type)) or
                (instruction.dest.type.kind == Shape.Void and
                  term.value.type != nil and term.value.type.kind != Shape.Void):
              fail("Catch fallback return type does not match result")
          elif term.value.type != nil and term.value.type.kind != Shape.Void:
            fail("Deferred cleanup cannot return a value")
        of Opcode.Panic: discard
        else: fail("Invalid fallback terminator in " & section.label)
      for section in sections:
        if section == nil or not predecessors.hasKey(section.label): continue
        for child in section.instrs:
          if child == nil or child.kind != Opcode.Phi: continue
          var labels = initHashSet[string]()
          for edge in child.blocks:
            labels.incl(edge.label)
            if child.dest.type == nil or
                not same(child.dest.type, edge.value.type):
              fail("Fallback phi changes type in " & section.label)
          if labels.len != child.blocks.len or
              labels != predecessors[section.label]:
            fail("Fallback phi must cover each predecessor in " & section.label)
    for section in function.blocks:
      for instruction in section.instrs: checkFallback(instruction)
    var blocks = initTable[string, Block]()
    var predecessors = initTable[string, HashSet[string]]()
    var definitions = initTable[string, tuple[owner: string, index: int, typ: `Type`]]()

    proc define(value: Value; owner: string; index: int) =
      typed(value.`type`)
      if value.kind != Flavor.Reg:
        fail("Instruction results and parameters must be registers")
      elif definitions.hasKey(value.name):
        fail("Redefinition of register %" & value.name)
      else:
        definitions[value.name] = (owner, index, value.`type`)

    for parameter in function.params: define(parameter, "", -1)
    for section in function.blocks:
      if blocks.hasKey(section.label): fail("Duplicate block " & section.label)
      blocks[section.label] = section
      predecessors[section.label] = initHashSet[string]()
      for parameter in section.params: define(parameter, section.label, -1)
      for index, instruction in section.instrs:
        if instruction == nil: continue
        if instruction.dest.`type` != nil: define(instruction.dest, section.label, index)
        if instruction.memory.output.len > 0:
          define(Value(kind: Flavor.Reg, name: instruction.memory.output,
            `type`: `Type`(kind: Shape.Memory)), section.label, index)

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
          if parameter.`type`.kind == Shape.Memory and
              (index >= args.len or args[index].name != term.memory.input):
            fail("Edge to " & target & " loses its memory dependency")

    for section in function.blocks:
      let term = section.term
      if term == nil or term.kind notin terminators:
        fail("Block " & section.label & " lacks a valid terminator")
        continue
      if term.kind == Opcode.Jump:
        edge(section.label, term.label, term.args, term)
      elif term.kind == Opcode.Cjump:
        edge(section.label, term.yes, term.positive, term)
        edge(section.label, term.no, term.negative, term)

    let entry = function.blocks[0].label
    var reachable = initHashSet[string]()
    var queue = @[entry]
    while queue.len > 0:
      let label = queue.pop()
      if label in reachable or not blocks.hasKey(label): continue
      reachable.incl(label)
      let term = blocks[label].term
      if term != nil and term.kind == Opcode.Jump: queue.add(term.label)
      elif term != nil and term.kind == Opcode.Cjump:
        queue.add(term.yes); queue.add(term.no)

    # Dense block IDs make intersection proportional to words, not repeated
    # string hashing/copying for each candidate dominator. Keep the same fixed
    # point and unreachable-block semantics as the set formulation.
    var ids = initTable[string,int]()
    for index, section in function.blocks: ids[section.label] = index
    let words = (function.blocks.len + 63) div 64
    var reachability = newSeq[uint64](words)
    for label in reachable:
      let id = ids[label]
      reachability[id div 64] = reachability[id div 64] or (1'u64 shl (id mod 64))
    var dominators = newSeq[seq[uint64]](function.blocks.len)
    for index, section in function.blocks:
      dominators[index] = newSeq[uint64](words)
      if section.label == entry or section.label notin reachable:
        dominators[index][index div 64] = 1'u64 shl (index mod 64)
      else:
        for word in 0..<words: dominators[index][word] = reachability[word]
    var changed = true
    while changed:
      changed = false
      for index, section in function.blocks:
        if section.label == entry or section.label notin reachable: continue
        let incoming = predecessors[section.label].toSeq.filterIt(it in reachable)
        var next = newSeq[uint64](words)
        if incoming.len > 0:
          for word in 0..<words:
            next[word] = dominators[ids[incoming[0]]][word]
            for predecessor in incoming:
              next[word] = next[word] and dominators[ids[predecessor]][word]
        next[index div 64] = next[index div 64] or (1'u64 shl (index mod 64))
        if next != dominators[index]:
          dominators[index] = next
          changed = true
    proc dominates(definition, owner: string): bool =
      let id = ids[definition]
      (dominators[ids[owner]][id div 64] and (1'u64 shl (id mod 64))) != 0

    proc use(value: Value; owner: string; index: int) =
      typed(value.`type`)
      if value.kind == Flavor.Global:
        if globals.hasKey(value.name):
          if value.`type`.kind != Shape.Ptr or not same(value.`type`.elem, globals[value.name]):
            fail("Storage symbol '" & value.name & "' has the wrong pointer type")
        elif not signatures.hasKey(value.name) or value.`type`.kind != Shape.Function or
            not same(value.`type`.ret, signatures[value.name].ret) or
            value.`type`.params.len != signatures[value.name].params.len:
          fail("Unknown or mistyped global symbol '" & value.name & "'")
        else:
          for parameterIndex, parameter in signatures[value.name].params:
            if not same(parameter, value.`type`.params[parameterIndex]):
              fail("Unknown or mistyped global symbol '" & value.name & "'")
        return
      if value.kind != Flavor.Reg: return
      if not definitions.hasKey(value.name):
        fail("Use of undefined register %" & value.name)
        return
      let definition = definitions[value.name]
      if not same(definition.typ, value.`type`): fail("Register %" & value.name & " changes type")
      if (definition.owner == owner and definition.index >= index) or
          (definition.owner.len > 0 and definition.owner != owner and not dominates(definition.owner,owner)):
        fail("Definition of %" & value.name & " does not dominate its use in " & owner)

    proc inspect(instruction: Instruction; owner: string; index: int) =
      if instruction == nil: return
      if module.version == 1 and (instruction.kind in effectful or
          (instruction.kind == Opcode.Bit and instruction.op in
            ["shl", "lshr", "ashr", "set", "clear", "toggle"])) and
          (instruction.memory.input.len == 0 or instruction.memory.output.len == 0 or instruction.effects.len == 0):
        fail("Effectful operation needs explicit effects and a memory dependency")
      if instruction.panic.len > 0 and not blocks.hasKey(instruction.panic):
        fail("Unknown panic successor '" & instruction.panic & "'")
      if instruction.trace.len > 0 and instruction.trace notin traces:
        fail("Unknown trace slot '" & instruction.trace & "'")
      if instruction.trace.len > 0:
        for trace in module.traces:
          if trace.id == instruction.trace and trace.`function` != symbol:
            fail("Trace slot '" & instruction.trace & "' belongs to another function")
      if instruction.kind == Opcode.Trace and (instruction.trace.len == 0 or "trace" notin instruction.effects):
        fail("Trace append needs a trace slot and trace effect")
      if instruction.kind == Opcode.Thread and
          (instruction.func.len == 0 or not signatures.hasKey(instruction.func) or "synchronize" notin instruction.effects):
        fail("Thread operation needs a declared runtime contract and synchronization edge")
      if module.version == 1 and instruction.region.len > 0 and instruction.region notin regions:
        fail("Unknown arena '" & instruction.region & "'")
      if instruction.kind == Opcode.Native and not instruction.op.startsWith("machine:") and
          (instruction.symbol.len == 0 or instruction.symbol notin native):
        fail("Native operation needs a declared contract")

      if instruction.kind == Opcode.Atomic:
        let operation = instruction.op
        let ordering = instruction.field
        let orders = ["relaxed", "acquire", "release", "acq_rel", "seq_cst"]
        if operation notin ["load", "store", "add", "sub", "swap", "fence"] or ordering notin orders:
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
          if pointer == nil or pointer.kind != Shape.Ptr or element == nil or
              element.kind notin {Shape.Int, Shape.Uint} or
              (if element.width > 0: element.width else: 32) notin [8, 16, 32, 64] or
              "atomic" notin element.attributes:
            fail("Atomic operation needs a pointer to atomic integer storage")
          elif operation != "load":
            let plain = `Type`(kind: element.kind, name: element.name, elem: element.elem,
              width: element.width, fields: element.fields, annotations: element.annotations,
              variants: element.variants, params: element.params, ret: element.ret,
              abi: element.abi, volatile: element.volatile, constant: element.constant)
            if instruction.val.`type` == nil or not same(instruction.val.`type`, plain):
              fail("Atomic value does not match its storage")
          if element != nil and operation != "store":
            let plain = `Type`(kind: element.kind, name: element.name, elem: element.elem,
              width: element.width, fields: element.fields, annotations: element.annotations,
              variants: element.variants, params: element.params, ret: element.ret,
              abi: element.abi, volatile: element.volatile, constant: element.constant)
            if instruction.dest.`type` == nil or not same(instruction.dest.`type`, plain):
              fail("Atomic result does not match its storage")
        if operation in ["store", "fence"] and instruction.dest.`type` != nil:
          fail("Atomic store/fence has no result")
      if instruction.kind == Opcode.Allocate:
        if instruction.region.len == 0 or instruction.dest.`type` == nil or
            instruction.dest.`type`.kind != Shape.Failable or instruction.dest.`type`.elem == nil or
            instruction.dest.`type`.elem.kind != Shape.Slice or instruction.val.`type` == nil:
          fail("Arena allocation needs a size, region and failable sequence result")
        elif instruction.val.`type`.kind notin {Shape.Int, Shape.Uint}:
          fail("Allocation size must be an integer")
        elif (if instruction.val.`type`.width > 0: instruction.val.`type`.width else: 32) > 64:
          fail("Allocation size exceeds the 64-bit runtime ABI")
        if instruction.target.`type` != nil and
            (instruction.target.`type`.kind != Shape.Ptr or
             instruction.target.`type`.elem == nil or
             instruction.target.`type`.elem.kind != Shape.Opaque):
          fail("Explicit allocation needs a pointer to an opaque allocator")
      if instruction.kind == Opcode.Region and
          (instruction.region.len == 0 or instruction.op notin ["open", "close"]):
        fail("Region operations must open or close an identified arena")
      if instruction.kind == Opcode.Bit:
        let target = instruction.dest.`type`
        let left = instruction.val.`type`
        let right = instruction.val2.`type`
        let unary = instruction.op == "not"
        if instruction.op notin ["shl", "lshr", "ashr", "and", "or", "xor",
            "not", "set", "clear", "toggle"]:
          fail("Unknown bit operation '" & instruction.op & "'")
        if target == nil or target.kind notin {Shape.Int, Shape.Uint} or
            left == nil or not same(target, left):
          fail("Bit operation needs matching signed or unsigned integer operands and result")
        if unary:
          if right != nil: fail("Bit complement takes one operand")
        elif right == nil or right.kind notin {Shape.Int, Shape.Uint} or
            (instruction.op in ["and", "or", "xor"] and not same(target, right)):
          fail("Bit operation needs a matching value or integer count")
        if instruction.op == "ashr" and target != nil and target.kind != Shape.Int:
          fail("Arithmetic right shift needs a signed integer")
      if instruction.kind == Opcode.Convert:
        let source = instruction.val.`type`
        let target = instruction.dest.`type`
        proc numeric(value: `Type`): bool = value != nil and value.kind in {Shape.Int, Shape.Uint, Shape.Float}
        proc bits(value: `Type`): int =
          if value.width > 0: value.width elif value.kind == Shape.Float: 64 else: 32
        let widened = source != nil and target != nil and numeric(source) and numeric(target) and
          (if source.kind == target.kind: bits(source) <= bits(target)
           elif source.kind == Shape.Uint and target.kind == Shape.Int: bits(source) < bits(target)
           elif source.kind != Shape.Float and target.kind == Shape.Float:
             bits(source) - (if source.kind == Shape.Int: 1 else: 0) <= (if bits(target) == 32: 24 else: 53)
           else: false)
        let lifted = source != nil and target != nil and target.kind in {Shape.Optional, Shape.Failable} and same(source, target.elem)
        let view = source != nil and target != nil and source.kind == Shape.Slice and
          target.kind == Shape.Slice and target.constant and same(source.elem, target.elem)
        var codecAdapter = source != nil and target != nil and
          source.kind == Shape.Function and target.kind == Shape.Function and
          source.abi == "runtime.codec" and target.abi.len == 0 and
          source.params.len == target.params.len and same(source.ret, target.ret)
        if codecAdapter:
          for index, parameter in source.params:
            if not same(parameter, target.params[index]): codecAdapter = false
        if not widened and not lifted and not view and not codecAdapter and
            not same(source, target):
          fail("Conversion from " & label(source) & " to " & label(target) &
            " is not a lossless widening or wrapper injection")
      if instruction.kind == Opcode.Index:
        let source = instruction.val.`type`
        let destination = instruction.dest.`type`
        let actual = if instruction.op == "address" and destination != nil: destination.elem else: destination
        if source == nil or source.elem == nil or instruction.val2.`type` == nil or destination == nil or
            not same(actual, source.elem):
          fail("Index needs a sequence, index and matching element result")
      if instruction.kind == Opcode.Length:
        if instruction.val.`type` == nil or instruction.val.`type`.kind notin {Shape.Slice, Shape.Array, Shape.Vector} or
            instruction.dest.`type` == nil or instruction.dest.`type`.kind notin {Shape.Int, Shape.Uint}:
          fail("Length needs a sequence and integer result")
      if instruction.kind == Opcode.Construct:
        let target = instruction.dest.`type`
        var fields: seq[`Type`]
        var found = false
        if target != nil and target.kind == Shape.Failable and instruction.op == "error":
          fields = @[`Type`(kind: Shape.Error)]; found = true
        elif target != nil and target.kind == Shape.Slice and instruction.op == "sequence":
          found = true
          for _ in instruction.args: fields.add(target.elem)
        elif target != nil and target.kind in {Shape.Array, Shape.Vector}:
          found = true
          for _ in 0 ..< target.width: fields.add(target.elem)
        elif target != nil and target.kind == Shape.TaggedUnion and target.variants.hasKey(instruction.field):
          found = true
          if target.variants[instruction.field] != nil: fields.add(target.variants[instruction.field])
        elif target != nil and target.kind in {Shape.Struct, Shape.PackedStruct, Shape.ExternStruct, Shape.ExternUnion}:
          found = true
          for field in target.fields.values: fields.add(field)
        if not found or fields.len != instruction.args.len:
          fail("Construction does not match its declared fields or variant")
        else:
          for position, field in fields:
            if not same(field, instruction.args[position].`type`):
              fail("Construction does not match its declared fields or variant")
      if instruction.kind in {Opcode.Splat, Opcode.Shuffle, Opcode.Select, Opcode.Gather, Opcode.Scatter}:
        let target = instruction.dest.`type`
        let source = instruction.val.`type`
        let second = instruction.val2.`type`
        proc vector(typ: `Type`): bool = typ != nil and typ.kind == Shape.Vector and
          typ.width > 0 and typ.elem != nil and typ.elem.kind in {Shape.Int,Shape.Uint,Shape.Float,Shape.Bool,Shape.Ptr}
        if not vector(target):
          fail("Vector operation needs a positive width and scalar lanes")
        elif instruction.kind == Opcode.Splat:
          if not same(source,target.elem): fail("Vector splat needs a matching scalar")
        elif not vector(source) or not same(source.elem,target.elem):
          fail("Vector operand and result lanes must match")
        elif instruction.kind == Opcode.Shuffle:
          if not vector(second) or not same(second.elem,source.elem) or instruction.mask.len != target.width or
              instruction.mask.anyIt(it < 0 or it >= source.width + second.width):
            fail("Vector shuffle needs matching lanes and an in-range mask for every result lane")
        elif instruction.kind == Opcode.Select:
          let mask = instruction.cond.`type`
          if not same(source,target) or not same(second,target) or not vector(mask) or
              mask.elem.kind != Shape.Bool or mask.width != target.width:
            fail("Vector select needs equal operands and a matching boolean mask")
        else:
          if not vector(second) or second.elem.kind notin {Shape.Int,Shape.Uint}:
            fail("Vector indexing needs integer lanes")
          elif instruction.kind == Opcode.Gather and target.width != second.width:
            fail("Vector gather result must match the index count")
          elif instruction.kind == Opcode.Scatter and (not same(target,source) or instruction.args.len != 1 or
              not vector(instruction.args[0].`type`) or instruction.args[0].`type`.width != second.width or
              not same(instruction.args[0].`type`.elem,source.elem)):
            fail("Vector scatter needs one matching update per index and preserves its source width")
          if module.version == 1 and "check" notin instruction.effects:
            fail("Checked vector indexing must retain its failure effect")
      if instruction.kind == Opcode.Extract:
        let original = instruction.val.`type`
        let source = if original != nil and original.kind == Shape.Ptr: original.elem else: original
        var projected: `Type`
        if source != nil and source.kind == Shape.Optional:
          if instruction.field == "present": projected = `Type`(kind: Shape.Bool)
          elif instruction.field == "value": projected = source.elem
        elif source != nil and source.kind == Shape.Failable:
          if instruction.field == "failed": projected = `Type`(kind: Shape.Bool)
          elif instruction.field == "value": projected = source.elem
        elif source != nil and source.kind == Shape.TaggedUnion:
          if instruction.field == "tag": projected = `Type`(kind: Shape.Uint, width: 32)
          elif source.variants.hasKey(instruction.field): projected = source.variants[instruction.field]
        elif source != nil and source.fields.hasKey(instruction.field):
          projected = source.fields[instruction.field]
        let destination = instruction.dest.`type`
        let actual = if instruction.op == "address" and destination != nil: destination.elem else: destination
        if projected == nil or not same(projected, actual):
          fail("Projection does not match its source layout")

      for value in values(instruction): use(value, owner, index)
      if instruction.kind == Opcode.Phi:
        var labels = initHashSet[string]()
        for incoming in instruction.blocks: labels.incl(incoming.label)
        if labels.len != instruction.blocks.len or labels != predecessors[owner]:
          fail("Phi in " & owner & " must cover each predecessor exactly once")
        for incoming in instruction.blocks:
          use(incoming.value, incoming.label, high(int))
          if instruction.dest.`type` != nil and not same(incoming.value.`type`, instruction.dest.`type`):
            fail("Phi in " & owner & " has inconsistent incoming types")
      if instruction.kind in {Opcode.Add, Opcode.Sub, Opcode.Mul, Opcode.Div, Opcode.Remainder}:
        if instruction.dest.`type` == nil or instruction.val.`type` == nil or instruction.val2.`type` == nil or
            not same(instruction.dest.`type`, instruction.val.`type`) or not same(instruction.val.`type`, instruction.val2.`type`):
          fail("Arithmetic operands and result must have equal types")
        elif instruction.dest.`type`.kind notin {Shape.Int, Shape.Uint, Shape.Float, Shape.Vector} and
            not (instruction.kind == Opcode.Add and instruction.dest.`type`.kind == Shape.Slice and instruction.dest.`type`.constant):
          fail("Arithmetic requires numeric operands")
        elif instruction.dest.`type`.kind == Shape.Vector and
            (instruction.dest.`type`.width < 1 or instruction.dest.`type`.elem == nil or
             instruction.dest.`type`.elem.kind notin {Shape.Int, Shape.Uint, Shape.Float}):
          fail("Vector arithmetic requires positive width and numeric lanes")
      if instruction.kind == Opcode.Reduce:
        let source = instruction.val.`type`
        let target = instruction.dest.`type`
        let operation = if instruction.reduction.len == 0: "Add" else: instruction.reduction
        if source == nil or source.kind != Shape.Vector or source.width < 1 or
            source.elem == nil or target == nil or not same(source.elem, target) or
            target.kind notin {Shape.Int, Shape.Uint, Shape.Float}:
          fail("Vector reduction requires positive width and matching numeric lanes")
        elif operation notin ["Add", "Mul", "Min", "Max", "And", "Or", "Xor"] or
            (operation in ["And", "Or", "Xor"] and target.kind == Shape.Float):
          fail("Vector reduction operation is incompatible with its lane type")
      if instruction.kind == Opcode.Compare:
        let expected = if instruction.val.`type` != nil and instruction.val.`type`.kind == Shape.Vector:
          `Type`(kind: Shape.Vector, width: instruction.val.`type`.width, elem: `Type`(kind: Shape.Bool))
        else: `Type`(kind: Shape.Bool)
        if instruction.val.`type` == nil or instruction.val2.`type` == nil or instruction.dest.`type` == nil or
            not same(instruction.val.`type`, instruction.val2.`type`) or not same(instruction.dest.`type`, expected):
          fail("Comparison needs equal operand types and a Boolean result")
      if instruction.kind == Opcode.Not and
          (instruction.val.`type` == nil or instruction.val.`type`.kind != Shape.Bool or
           instruction.dest.`type` == nil or instruction.dest.`type`.kind != Shape.Bool):
        fail("Negation needs a Boolean operand and result")
      if instruction.kind in {Opcode.Call, Opcode.Thread}:
        var signature: tuple[params: seq[`Type`], ret: `Type`]
        var found = false
        if instruction.callee.`type` != nil and instruction.callee.`type`.kind == Shape.Function:
          signature = (instruction.callee.`type`.params, instruction.callee.`type`.ret); found = true
        elif instruction.func.len > 0 and signatures.hasKey(instruction.func):
          signature = signatures[instruction.func]; found = true
        if not found: fail("Unknown call target " & (if instruction.func.len > 0: instruction.func else: "<indirect>"))
        else:
          if instruction.args.len != signature.params.len: fail("Call argument count does not match its signature")
          for argumentIndex, argument in instruction.args:
            if argumentIndex < signature.params.len and not compatible(argument, signature.params[argumentIndex]):
              fail("Call " & instruction.func & " argument " & $(argumentIndex + 1) &
                " has the wrong type: " & argument.`type`.label & " instead of " &
                signature.params[argumentIndex].label & " at " & instruction.span.file &
                ":" & $instruction.span.start)
          if instruction.dest.`type` != nil and not same(instruction.dest.`type`, signature.ret):
            fail("Call result does not match its signature")
      if instruction.kind == Opcode.Cjump and
          (instruction.cond.`type` == nil or instruction.cond.`type`.kind != Shape.Bool):
        fail("Conditional branch needs a Boolean")
      if instruction.kind == Opcode.Return:
        if instruction.value.`type` != nil:
          if not compatible(instruction.value, returned): fail("Return does not match @" & symbol & "'s result")
        elif returned.kind != Shape.Void and not (returned.kind == Shape.Failable and returned.elem != nil and returned.elem.kind == Shape.Void):
          fail("Return does not match @" & symbol & "'s result")
      if instruction.kind == Opcode.Load and
          (instruction.`ptr`.`type` == nil or instruction.`ptr`.`type`.kind != Shape.Ptr or
           instruction.`ptr`.`type`.elem == nil or instruction.dest.`type` == nil or
           not same(instruction.`ptr`.`type`.elem, instruction.dest.`type`)):
        fail("Load result does not match pointer element")
      if instruction.kind == Opcode.Store and
          (instruction.`ptr`.`type` == nil or instruction.`ptr`.`type`.kind != Shape.Ptr or
           instruction.`ptr`.`type`.constant or instruction.`ptr`.`type`.elem == nil or
           instruction.val.`type` == nil or not compatible(instruction.val, instruction.`ptr`.`type`.elem)):
        fail("Store value does not match writable pointer element")
      if instruction.kind == Opcode.Alloc and
          (instruction.region.len == 0 or instruction.dest.`type` == nil or instruction.dest.`type`.kind != Shape.Ptr):
        fail("Allocation needs a region and pointer result")
      if instruction.kind == Opcode.Try and
          (instruction.expr.`type` == nil or instruction.expr.`type`.kind notin {Shape.Failable, Shape.Error}):
        fail("Try requires a failable operand")

    for section in function.blocks:
      var memory = ""
      for parameter in section.params:
        if parameter.`type`.kind == Shape.Memory: memory = parameter.name
      for index, instruction in section.instrs:
        if instruction == nil: continue
        if instruction.memory.input.len > 0 or instruction.memory.output.len > 0:
          if instruction.memory.input != memory or instruction.memory.output.len == 0:
            fail("Broken memory dependency in " & section.label)
          memory = instruction.memory.output
        elif memory.len > 0 and instruction.effects.len > 0:
          fail("Effectful instruction in " & section.label & " has no memory dependency")
        if instruction.kind in terminators: fail("Instruction " & $instruction.kind & " must be a terminator")
        inspect(instruction, section.label, index)
      if section.term != nil:
        inspect(section.term, section.label, section.instrs.len)
        if memory.len > 0 and section.term.memory.input != memory:
          fail("Terminator in " & section.label & " loses its memory dependency")

  proc finite(value: `Type`; active: var HashSet[pointer]): bool =
    if value == nil or value.kind in {Shape.Ptr, Shape.Slice, Shape.Function, Shape.Opaque}: return true
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
  for value in checked.values:
    var active = initHashSet[pointer]()
    if not finite(value, active):
      fail("A type contains itself by value and has no finite layout")
      break
  result = errors[]
