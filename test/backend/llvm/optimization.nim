import std/[os, osproc, strutils, json]
import ../../../src/ir/[node, kind, monomorph, reach]
import ../../../src/backend/llvm/[emitter, driver]
import ../../../src/build/options

let integer = `Type`(kind: TypeKind.Int, width: 32)
proc reg(name: string; t = integer): Value =
  Value(kind: ValueKind.Reg, name: name, `type`: t)
proc number(n: int): Value =
  Value(kind: ValueKind.Const, name: $n, `type`: integer)
let helper = Function(name: "identity", params: @[reg("argument")], ret: integer,
  blocks: @[Block(label: "entry", term: Instruction(kind: InstrKind.Return,
    value: reg("argument")))])
let entry = Function(name: "main", ret: integer,
  blocks: @[Block(label: "entry", instrs: @[
    Instruction(kind: InstrKind.Call, dest: reg("answer"), `func`: "identity", args: @[number(42)])],
    term: Instruction(kind: InstrKind.Return, value: reg("answer")))])
let input = Module(name: "optimization", funcs: @[helper, entry])
let raw = emit(input, "x86_64-pc-windows-msvc", "")
doAssert raw.contains("noinline memory(none)")
doAssert raw.contains("call i32 @\"foo.identity\"")
doAssert not raw.contains("noalias") and not raw.contains("nonnull")
let optimized = optimize(input, OptimizeOptions(inline: true, backend: "llvm", mode: "release"))
doAssert optimized.inlined == 1
doAssert input.funcs[1].blocks[0].instrs.len == 1 # shared optimizer clones
let lowered = emit(reach(optimized.module), "x86_64-pc-windows-msvc", "")
doAssert not lowered.contains("foo.identity")
doAssert lowered.contains("ret i32 42")

# Equivalent private functions share only after the shared proof succeeds.
let equivalent = cloneModule(input)
let duplicate = cloneModule(input).funcs[0]
duplicate.name = "duplicate"
equivalent.funcs.add(duplicate)
doAssert optimize(equivalent, OptimizeOptions(inline: true, backend: "llvm")).functions == 1

# Public/attributed functions do not receive the private pure proof or inlining.
helper.public = true
doAssert not pureFunction(helper)
doAssert optimize(input, OptimizeOptions(inline: true, backend: "llvm")).inlined == 0
helper.public = false
helper.attributes = @["noinline"]
doAssert not pureFunction(helper)
doAssert optimize(input, OptimizeOptions(inline: true, backend: "llvm")).inlined == 0
helper.attributes = @[]

# Same-type conversion elimination requires the full effect/failure proof.
let conversion = Instruction(kind: InstrKind.Convert, dest: reg("converted"), val: number(42))
let conversions = Module(funcs: @[Function(name: "main", ret: integer, blocks: @[
  Block(label: "entry", instrs: @[conversion], term: Instruction(kind: InstrKind.Return, value: reg("converted")))])])
doAssert optimize(conversions).boundaries == 1
conversion.effects = @["io"]
doAssert optimize(conversions).boundaries == 0
conversion.effects = @[]
conversion.panic = "failure"
doAssert optimize(conversions).boundaries == 0

# Volatile accesses survive both FOO slot promotion and LLVM lowering.
let pointer = `Type`(kind: TypeKind.Ptr, elem: integer, volatile: true)
let slot = reg("slot", pointer)
let memory = Function(name: "main", ret: integer, blocks: @[Block(label: "entry", instrs: @[
  Instruction(kind: InstrKind.Alloc, op: "slot", dest: slot),
  Instruction(kind: InstrKind.Store, `ptr`: slot, val: number(42)),
  Instruction(kind: InstrKind.Load, `ptr`: slot, dest: reg("loaded"))],
  term: Instruction(kind: InstrKind.Return, value: reg("loaded")))])
let volatileModule = optimize(Module(funcs: @[memory]), OptimizeOptions(backend: "llvm"))
doAssert volatileModule.allocations == 0
let volatileIR = emit(volatileModule.module, "x86_64-pc-windows-msvc", "")
doAssert volatileIR.contains("store volatile") and volatileIR.contains("load volatile")
doAssert not volatileIR.contains("memory(none)")
doAssert volatileIR.contains("align 1")
let observable = cloneModule(Module(funcs: @[memory]))
observable.funcs[0].blocks[0].instrs[0].dest.type.volatile = false
observable.funcs[0].blocks[0].instrs[1].effects = @["io"]
doAssert optimize(observable).allocations == 0

when defined(windows):
  let root = absolutePath(".artifacts/llvm-optimization-" & getEnv("FOOTESTID", "local"))
  for mode in ["dev", "release"]:
    let built = build(input, mode, root / mode, Native(name: "proof", compile: true))
    doAssert built.success, built.error
    doAssert execCmdEx(quoteShell(built.artifact)).exitCode == 42
    let metadata = parseFile(root / mode / "llvm.json")
    doAssert metadata.hasKey("semanticPolicy") and metadata.hasKey("semanticDecisions")
    doAssert metadata["vectorization"].getStr().startsWith("disabled")
    doAssert readFile(root / mode / "verified.ll").contains("noinline")
  # Overflow remains observable even when its arithmetic result is unused.
  let checked = Module(funcs: @[Function(name: "main", ret: integer, blocks: @[
    Block(label: "entry", instrs: @[Instruction(kind: InstrKind.Add,
      dest: reg("unused"), val: number(2147483647), val2: number(1), panic: "overflow")],
      term: Instruction(kind: InstrKind.Return, value: number(42))),
    Block(label: "overflow", term: Instruction(kind: InstrKind.Panic))])])
  let checkedOptimized = optimize(checked, OptimizeOptions(inline: true, backend: "llvm"))
  doAssert checkedOptimized.dead == 0
  doAssert not pureFunction(checkedOptimized.module.funcs[0])
  let failed = build(checkedOptimized.module, "release", root / "overflow", Native(name: "proof"))
  doAssert failed.success, failed.error
  doAssert readFile(root / "overflow" / "verified.ll").contains("call void @llvm.trap()")
  let built = build(optimized.module, "release", root / "semantic", Native(name: "proof", compile: true))
  doAssert built.success, built.error
  doAssert execCmdEx(quoteShell(built.artifact)).exitCode == 42
  let volatileBuild = build(volatileModule.module, "release", root / "volatile", Native(name: "proof", compile: true))
  doAssert volatileBuild.success, volatileBuild.error
  doAssert readFile(root / "volatile" / "verified.ll").contains("load volatile")
echo "LLVM evidence-gated optimization: ok"
