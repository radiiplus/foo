import std/strutils
import ../../../src/backend/zig/emitter
import ../../../src/ir/node
import ../../../src/ir/kind

let function = Function(name: "main", ret: `Type`(kind: TypeKind.Void), params: @[], blocks: @[])
let module = Module(name: "demo", funcs: @[function], externs: @[])
let generated = emit(module, "dev")
doAssert generated.code.contains("FOO IR v1 -> Zig")
doAssert generated.code.contains("fn main")
doAssert not generated.code.contains("shim.init")
doAssert not generated.code.contains("shim.deinit")
let ioModule = Module(name: "io", funcs: @[
  Function(name: "main", ret: `Type`(kind: TypeKind.Void), blocks: @[
    Block(label: "entry", instrs: @[
      Instruction(kind: InstrKind.Call, `func`: "output", abi: "runtime.io")],
      term: Instruction(kind: InstrKind.Return))])], externs: @[
  Extern(name: "output", abi: "runtime.io", ret: `Type`(kind: TypeKind.Void))])
let ioCode = emit(ioModule, "dev").code
doAssert ioCode.contains("defer @import(\"service.zig\").deinit();")
doAssert not ioCode.contains("service.zig\").init(")
doAssert typeStr(`Type`(kind: TypeKind.Optional, elem: `Type`(kind: TypeKind.Uint, width: 32))) == "?u32"
let covered = emit(module, "dev", EmitOptions(coverage: "coverage.json"))
doAssert covered.code.contains("var coverage")
doAssert covered.code.contains("defer report()")
try:
  discard emit(module, "dev", EmitOptions(coverage: "coverage.json", runtime: "none"))
  doAssert false
except ValueError:
  discard
let assembly = Module(name: "assembly", funcs: @[
  Function(name: "boot", attributes: @["start", "naked"],
    ret: `Type`(kind: TypeKind.Void), blocks: @[
      Block(label: "entry", instrs: @[
        Instruction(kind: InstrKind.Native, symbol: "bootasm")],
        term: Instruction(kind: InstrKind.Return))])], native: @[
  NativeContract(id: "bootasm", stage: "@asm", code: "\"nop\"",
    abi: "foo:1", effects: @["unknown"])])
doAssert emit(assembly, "release",
  EmitOptions(runtime: "none", target: "aarch64-freestanding-none")).code.contains(
    "asm volatile (\"nop\");")
let loop = Module(name: "loop", funcs: @[
  Function(name: "main", ret: `Type`(kind: TypeKind.Void), blocks: @[
    Block(label: "head", term: Instruction(kind: InstrKind.Cjump,
      cond: Value(kind: ValueKind.Const, name: "true", `type`: `Type`(kind: TypeKind.Bool)),
      trueLabel: "body", falseLabel: "done")),
    Block(label: "body", term: Instruction(kind: InstrKind.Jump, label: "head")),
    Block(label: "done", term: Instruction(kind: InstrKind.Return))])])
let plain = emit(loop, "release").code
doAssert plain.contains("loop: while (true)")
doAssert plain.contains("break :loop;")
loop.funcs[0].blocks[1].instrs.add(Instruction(kind: InstrKind.Phi,
  dest: Value(kind: ValueKind.Reg, name: "value", `type`: `Type`(kind: TypeKind.Uint, width: 64)),
  blocks: @[(label: "head", value: Value(kind: ValueKind.Const, name: "1",
    `type`: `Type`(kind: TypeKind.Uint, width: 64)))]))
doAssert not emit(loop, "release").code.contains("loop: while (true)")

echo "Zig emitter parity: ok"
