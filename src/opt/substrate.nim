import std/tables
import std/strutils
import ../ir/node
import ../ir/kind
import ../ir/monomorph
import ./arch
import ./engine as specialization

type
  Bindings* = object
    substrate*: string
    clobbers*: seq[string]

  Selection* = object
    backend*: string
    target*: string
    cpu*: string
    level*: string
    mode*: string
    native*: Bindings
    substrate*: string

  Decision* = object
    operation*: string
    stage*: string
    implementation*: string
    reason*: string

const levels* = ["base", "system", "machine", "hardware"]

proc index(value: string): int =
  for index, level in levels:
    if value == level: return index
  0

proc select*(operation: string; options: Selection): Decision =
  let arch = architecture(options.target)
  let cpu = profile(options.target, options.cpu)
  let backend = if options.backend.len > 0: options.backend else: "qbe"
  if backend != "qbe":
    raise newException(ValueError, "Unknown backend '" & backend & "'")
  let context = specialization.Context(backend: backend,
    target: options.target, cpu: cpu.cpu, mode: options.mode,
    capability: options.level, portable: options.substrate == "c")
  proc decide(contract: string;
      candidates: openArray[specialization.Candidate]): Decision =
    let selected = specialization.choose(operation, contract, context,
      candidates)
    Decision(operation: operation, stage: selected.stage,
      implementation: selected.implementation, reason: selected.reason)
  if operation == "copy":
    return decide("overlap-safe byte transfer", [
      specialization.candidate("portable", "@c", "overlap-safe byte transfer",
        "portable memmove preserves overlapping copies", 0,
        fallback = true, backends = @["qbe"])
    ])
  if operation == "atomic": return decide("ordered atomic operation", [
    specialization.candidate("c11", "@c", "ordered atomic operation",
      "C11 atomics preserve the requested memory ordering", 0,
      fallback = true)])
  if operation == "vectorize":
    return decide("ordered decimal lanes", [
      specialization.candidate("scalar", "@foo", "ordered decimal lanes",
        "the original checked loop preserves every input and failure", 0,
        fallback = true),
      specialization.candidate("simd", "@runtime", "ordered decimal lanes",
        "runtime guards permit independent decimal lanes", 20,
        compatible = arch == "x86_64", targets = @["windows"],
        backends = @["qbe"], modes = @["release"], evidenced = false)
    ])
  if operation == "table":
    return decide("text-keyed mutable table", [
      specialization.candidate("open-addressing", "@runtime",
        "text-keyed mutable table",
        "open addressing keeps text-key lookup contiguous and avoids one allocation per entry", 0,
        fallback = true)])
  if operation == "sequence-transform":
    return decide("ordered sequence transformation", [
      specialization.candidate("single-allocation", "@runtime",
        "ordered sequence transformation",
        "the result reserves once and is compacted once after the transform", 0,
        fallback = true)])
  if operation == "task":
    return decide("scoped task execution", [
      specialization.candidate("threaded", "@runtime", "scoped task execution",
        "native threads provide the evidenced portable scoped fallback", 0,
        fallback = true),
      specialization.candidate("kqueue", "@runtime", "scoped task execution",
        "Apple and BSD event-backed task execution", 20,
        targets = @["macos", "darwin", "bsd"],
        evidenced = false)
    ])
  raise newException(ValueError, "No substrate for operation '" & operation & "'")

proc `bind`*(input: Module; options: Selection): tuple[module: Module, decisions: seq[Decision]] =
  result.module = copy(input)
  result.module.stage = "@c"
  if result.module.target.len == 0: result.module.target = initTable[string, string]()
  result.module.target["triple"] = if options.target.len > 0: options.target else: architecture()
  var foreign = initTable[string, Extern]()
  for declaration in result.module.externs: foreign[declaration.name] = declaration
  let level = if options.level.len > 0: options.level else: "base"
  for fn in result.module.funcs:
    for section in fn.blocks:
      var instructions = section.instrs
      instructions.add(section.term)
      for instruction in instructions:
        if instruction == nil: continue
        if "machine" in instruction.effects and index(level) < index("machine"):
          raise newException(ValueError, "This program requires \"machine\" capability. Set requires to machine in the project manifest")
        var operation = ""
        if instruction.kind == Opcode.Atomic: operation = "atomic"
        elif instruction.`func`.len > 0 and instruction.`func` in foreign:
          let declaration = foreign[instruction.`func`]
          if declaration.abi == "runtime.atomic": operation = "atomic"
          elif declaration.abi == "runtime.cpu" and declaration.symbol == "vectorize": operation = "vectorize"
          elif declaration.abi in ["runtime", "runtime.task"]: operation = "task"
          elif declaration.abi == "runtime.table": operation = "table"
          elif declaration.abi == "runtime.sequence" and declaration.symbol in ["sized", "compact"]: operation = "sequence-transform"
          elif declaration.abi == "runtime.memory" and (declaration.symbol == "copy" or declaration.symbol == "transfer"): operation = "copy"
        if operation.len > 0:
          var seen = false
          for decision in result.decisions:
            if decision.operation == operation: seen = true
          if not seen: result.decisions.add(select(operation, options))
  for contract in result.module.native.mitems:
    let stage = if contract.stage == "@foo": (if options.native.substrate.len > 0: options.native.substrate else: "c") else: contract.stage[1 .. ^1]
    let required = if stage == "asm" or contract.abi.startsWith("machine:"): "machine" else: "system"
    if index(level) < index(required): raise newException(ValueError, "Native block requires \"" & required & "\" capability. Set requires to " & required & " in the project manifest")
    contract.stage = if stage == "asm": "@asm" else: "@c"
    result.decisions.add(Decision(operation: contract.id, stage: contract.stage,
      implementation: stage, reason: "the native contract explicitly selected this substrate"))

proc native*(contract: Contract; options: Selection; global = false): string =
  if contract.stage == "@c": return if global: contract.code else: "{\n" & contract.code & "\n}"
  if contract.stage != "@asm": raise newException(ValueError, "Native contract is not bound")
  contract.code
