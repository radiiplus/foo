import std/tables
import std/strutils
import ../ir/node
import ../ir/kind
import ../ir/monomorph
import ../opt/arch
import ../opt/engine as specialization

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
    reason*: string

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
    if backend == "zig":
      return decide("overlap-safe byte transfer", [
        specialization.candidate("word", "@zig", "overlap-safe byte transfer",
          "word-sized overlap-safe blocks for the portable fallback", 0,
          fallback = true),
        specialization.candidate("block-16", "@zig", "overlap-safe byte transfer",
          "16-byte overlap-safe blocks for the selected AArch64 release target", 20,
          compatible = options.mode == "release" and arch == "aarch64"),
        specialization.candidate("block-32", "@zig", "overlap-safe byte transfer",
          "32-byte overlap-safe blocks for the selected AVX2 release target", 30,
          compatible = options.mode == "release" and arch == "x86_64" and
            "avx2" in cpu.features)
      ])
    return decide("overlap-safe byte transfer", [
      specialization.candidate("portable", "@c", "overlap-safe byte transfer",
        "portable memmove preserves exact overlap semantics", 0,
        fallback = true),
      specialization.candidate("intrinsic", "@c", "overlap-safe byte transfer",
        "compiler memmove intrinsic for the selected AArch64 release target", 10,
        compatible = options.substrate != "c" and options.mode == "release" and
          arch == "aarch64"),
      specialization.candidate("rep", "@asm", "overlap-safe byte transfer",
        "rep movsb for non-overlapping bulk copies, with memmove for overlap and other sizes", 20,
        compatible = options.substrate != "c" and options.mode == "release" and
          machine and arch == "x86_64"),
      specialization.candidate("avx", "@c", "overlap-safe byte transfer",
        "AVX2 head and tail vectors for medium copies, with memmove outside the measured range", 30,
        compatible = options.substrate != "c" and options.mode == "release" and
          arch == "x86_64" and "avx2" in cpu.features)
    ])
  if operation == "atomic": return decide("ordered atomic operation", [
    specialization.candidate("c11", "@c", "ordered atomic operation",
      "C11 atomics preserve the requested memory ordering", 0,
      fallback = true)])
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
      specialization.candidate("epoll", "@runtime", "scoped task execution",
        "Linux event-backed task execution", 20,
        backends = @["c"], targets = @["linux"]),
      specialization.candidate("kqueue", "@runtime", "scoped task execution",
        "Apple and BSD event-backed task execution", 20,
        targets = @["macos", "darwin", "bsd"],
        evidenced = false),
      specialization.candidate("iocp", "@runtime", "scoped task execution",
        "Windows event-backed task execution", 20,
        backends = @["c"], targets = @["windows", "win32"])
    ])
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
    if levelIndex(level) < levelIndex(required): raise newException(ValueError, "Native block requires \"" & required & "\" capability. Install with: foo toolchain install " & required)
    contract.stage = if stage == "asm": "@asm" else: "@c"
    result.decisions.add(Decision(operation: contract.id, stage: contract.stage,
      implementation: stage, reason: "the native contract explicitly selected this substrate"))

proc native*(contract: NativeContract; options: Selection; global = false): string =
  if contract.stage == "@c": return if global: contract.code else: "{\n" & contract.code & "\n}"
  if contract.stage != "@asm": raise newException(ValueError, "Native contract is not bound")
  contract.code
