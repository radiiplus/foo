import std/tables
import std/algorithm
import std/strutils
import ../ir/node
import ../ir/kind
import ../ir/monomorph
import ../opt/arch

type
  NativeSelection* = object
    substrate*: string
    clobbers*: seq[string]

  Selection* = object
    backend*: string
    target*: string
    cpu*: string
    level*: string
    mode*: string
    native*: NativeSelection
    substrate*: string

  Decision* = object
    operation*: string
    stage*: string
    implementation*: string

const levels* = ["base", "system", "machine", "hardware"]

proc levelIndex(value: string): int =
  for index, level in levels:
    if value == level: return index
  0

proc select*(operation: string; options: Selection): Decision =
  let arch = architecture(options.target)
  let cpu = profile(options.target, options.cpu)
  let backend = if options.backend.len > 0: options.backend else: "c"
  let machine = levelIndex(if options.level.len > 0: options.level else: "base") >= levelIndex("machine")
  if operation == "copy":
    if backend == "zig":
      if options.mode == "release" and arch == "x86_64" and "avx2" in cpu.features:
        return Decision(operation: operation, stage: "@zig", implementation: "block-32")
      if options.mode == "release" and arch == "aarch64":
        return Decision(operation: operation, stage: "@zig", implementation: "block-16")
      return Decision(operation: operation, stage: "@zig", implementation: "word")
    if options.substrate != "c" and options.mode == "release" and arch == "x86_64" and "avx2" in cpu.features:
      return Decision(operation: operation, stage: "@c", implementation: "avx")
    if options.substrate != "c" and options.mode == "release" and machine and arch == "x86_64":
      return Decision(operation: operation, stage: "@asm", implementation: "rep")
    if options.substrate != "c" and options.mode == "release" and arch == "aarch64":
      return Decision(operation: operation, stage: "@c", implementation: "intrinsic")
    return Decision(operation: operation, stage: "@c", implementation: "portable")
  if operation == "atomic": return Decision(operation: operation, stage: "@c", implementation: "c11")
  if operation == "hashmap":
    return Decision(operation: operation, stage: "@runtime", implementation: "open-addressing")
  if operation == "sequence-transform":
    return Decision(operation: operation, stage: "@runtime", implementation: "single-allocation")
  if operation == "task":
    let target = options.target.toLowerAscii()
    let implementation =
      if "windows" in target or "win32" in target: "iocp"
      elif "macos" in target or "darwin" in target or "bsd" in target: "kqueue"
      elif "linux" in target: "epoll"
      else: "threaded"
    return Decision(operation: operation, stage: "@runtime", implementation: implementation)
  raise newException(ValueError, "No substrate for operation '" & operation & "'")

proc `bind`*(input: Module; options: Selection): tuple[module: Module, decisions: seq[Decision]] =
  result.module = cloneModule(input)
  result.module.stage = "@c"
  if result.module.target.len == 0: result.module.target = initTable[string, string]()
  result.module.target["triple"] = if options.target.len > 0: options.target else: architecture()
  var foreign = initTable[string, Extern]()
  for declaration in result.module.externs: foreign[declaration.name] = declaration
  let level = if options.level.len > 0: options.level else: "base"
  for fn in result.module.funcs:
    for basicBlock in fn.blocks:
      var instructions = basicBlock.instrs
      instructions.add(basicBlock.term)
      for instruction in instructions:
        if instruction == nil: continue
        if "machine" in instruction.effects and levelIndex(level) < levelIndex("machine"):
          raise newException(ValueError, "This program requires \"machine\" capability. Set requires to machine and run: foo toolchain install machine")
        var operation = ""
        if instruction.kind == InstrKind.Atomic: operation = "atomic"
        elif instruction.`func`.len > 0 and instruction.`func` in foreign:
          let declaration = foreign[instruction.`func`]
          if declaration.abi == "runtime.atomic": operation = "atomic"
          elif declaration.abi in ["runtime", "runtime.task"]: operation = "task"
          elif declaration.abi == "runtime.hashmap": operation = "hashmap"
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
    if levelIndex(level) < levelIndex(required): raise newException(ValueError, "Native block requires \"" & required & "\" capability. Install with: foo toolchain install " & required)
    contract.stage = if stage == "asm": "@asm" else: "@c"
    result.decisions.add(Decision(operation: contract.id, stage: contract.stage, implementation: stage))

proc native*(contract: NativeContract; options: Selection; global = false): string =
  if contract.stage == "@c": return if global: contract.code else: "{\n" & contract.code & "\n}"
  if contract.stage != "@asm": raise newException(ValueError, "Native contract is not bound")
  contract.code
