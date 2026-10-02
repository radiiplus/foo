import std/[os, strutils]
import ../../../src/backend/c/driver
import ../../../src/ir/node
import ../../../src/ir/kind
import ../../../src/build/options
import ../../../src/toolchain/manager

let voidType = `Type`(kind: TypeKind.Void)
let unsignedType = `Type`(kind: TypeKind.Uint, width: 64)
let countType = `Type`(kind: TypeKind.Uint, width: 32)
let boot = Function(name: "boot", params: @[], ret: voidType,
  attributes: @["start"], blocks: @[
  Block(label: "entry", instrs: @[
    Instruction(kind: InstrKind.Call,
      dest: Value(kind: ValueKind.Reg, name: "bits", `type`: countType),
      `func`: "count", abi: "runtime.arch", args: @[
        Value(kind: ValueKind.Const, name: "255", `type`: unsignedType)])],
    term: Instruction(kind: InstrKind.Return))])
let naked = Function(name: "spin", params: @[], ret: voidType,
  attributes: @["naked"], blocks: @[
  Block(label: "entry", instrs: @[], term: Instruction(kind: InstrKind.Return))])
let interrupt = Function(name: "irq", params: @[], ret: voidType,
  attributes: @["interrupt"], blocks: @[
  Block(label: "entry", instrs: @[], term: Instruction(kind: InstrKind.Return))])
let count = Extern(name: "count", symbol: "count", abi: "runtime.arch",
  params: @[unsignedType], ret: countType)
let module = Module(name: "bare", funcs: @[boot, naked, interrupt],
  externs: @[count])
let output = ".artifacts" / ("test-cross-" & getEnv("FOOTESTID", "local"))
let compiler = install().path
let zigCache = output & "-zigcache"
createDir(zigCache)
putEnv("ZIG_GLOBAL_CACHE_DIR", zigCache)
putEnv("ZIG_LOCAL_CACHE_DIR", zigCache / "local")

for platform in [
    (name: "arm", target: "aarch64-freestanding-none", machine: 183),
    (name: "riscv", target: "riscv64-freestanding-none", machine: 243)]:
  let result = build(module, "release", output & "-" & platform.name,
    Native(name: platform.name, target: platform.target, runtime: "none",
      compiler: compiler, compile: true))
  doAssert result.success, result.error
  let bytes = readFile(result.artifact)
  doAssert bytes[0 .. 3] == "\x7fELF"
  doAssert ord(bytes[18]) + ord(bytes[19]) * 256 == platform.machine

echo "C cross-target parity: ok"
