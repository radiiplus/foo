import std/[json, os, osproc, strutils]
import ../../../../src/backend/qbe/[driver, emitter]
import ../../../../src/build/options
import ../../../../src/ir/[kind, node]

let voidType = `Type`(kind: Shape.Void)
let integer = `Type`(kind: Shape.Int, width: 32)
let answer = Value(kind: Flavor.Const, name: "42", `type`: integer)
let nativeFunction = Function(name: "native_probe", abi: "c", public: true,
  attributes: @["naked", "noinline"], ret: voidType,
  blocks: @[Block(label: "entry", instrs: @[
    Instruction(kind: Opcode.Native, symbol: "probe_body")],
    term: Instruction(kind: Opcode.Return))])
let main = Function(name: "main", ret: integer,
  blocks: @[Block(label: "entry", instrs: @[
    Instruction(kind: Opcode.Call, `func`: "native_probe")],
    term: Instruction(kind: Opcode.Return, value: answer))])
let hosted = Module(funcs: @[nativeFunction, main], native: @[
  Contract(id: "probe_body", stage: "@asm", abi: "c", code: "nop\nret",
    effects: @["unknown"])])
let target = when defined(windows): "windows-x64" else: "linux-x64"
let il = emitter.emit(hosted, entry = true, target = target)
doAssert "call $native_probe(" in il
doAssert "function $native_probe(" notin il

let settings = Native(name: "native-probe", kind: "exe", target: target)
let built = driver.build(hosted, "dev", ".artifacts/qbe-native-functions", settings)
doAssert built.success, built.error
let executed = execCmdEx(quoteShell(built.artifact))
doAssert executed.exitCode == 42, executed.output
let metadata = parseFile(built.artifact & ".qbe.json")
doAssert metadata["functionAssemblySha256"].getStr().len == 64
doAssert metadata["functionAttributesSha256"].getStr().len == 64
let repeat = driver.build(hosted, "dev", ".artifacts/qbe-native-functions", settings)
doAssert repeat.success and repeat.cached, repeat.error

let feature = Function(name: "feature", abi: "c", public: true,
  attributes: @["target_feature(\"avx2\")"], ret: voidType,
  blocks: @[Block(label: "entry", term: Instruction(kind: Opcode.Return))])
let featureModule = Module(funcs: @[feature])
try:
  discard emitter.emit(featureModule, target = target)
  doAssert false, "unavailable CPU feature must be rejected"
except ValueError as error:
  doAssert "avx2" in error.msg
discard emitter.emit(featureModule, target = target, cpu = "x86-64-v3")
let featureBuild = driver.build(featureModule, "dev",
  ".artifacts/qbe-native-feature", Native(name: "feature", kind: "object",
    target: target, cpu: "x86-64-v3"))
doAssert featureBuild.success, featureBuild.error
doAssert parseFile(featureBuild.artifact & ".qbe.json")["cpu"].getStr() ==
  "x86-64-v3"

let boot = Function(name: "boot", attributes: @["naked", "start"],
  ret: voidType, blocks: @[Block(label: "entry", instrs: @[
    Instruction(kind: Opcode.Native, symbol: "boot_body")],
    term: Instruction(kind: Opcode.Return))])
let startup = Module(funcs: @[boot], native: @[
  Contract(id: "boot_body", stage: "@asm", abi: "foo:1",
    code: "mov $60, %eax\nxor %edi, %edi\nsyscall",
    effects: @["unknown"])])
let startupIl = emitter.emit(startup, target = "x64-freestanding")
doAssert "function $foo.boot(" notin startupIl
let wrongInterrupt = Module(funcs: @[Function(name: "irq",
  attributes: @["interrupt"], ret: voidType,
  blocks: @[Block(label: "entry", term: Instruction(kind: Opcode.Return))])])
try:
  discard emitter.emit(wrongInterrupt, target = "linux-x64")
  doAssert false, "machine interrupts require freestanding target"
except ValueError as error:
  doAssert "freestanding" in error.msg
let wrongErrorCode = Module(funcs: @[Function(name: "fault",
  attributes: @["interrupt_error_code"], ret: voidType,
  blocks: @[Block(label: "entry", term:
    Instruction(kind: Opcode.Return))])])
try:
  discard emitter.emit(wrongErrorCode, target = "x64-freestanding")
  doAssert false, "hardware error-code handlers require a u64 argument"
except ValueError as error:
  doAssert "handler signature" in error.msg
let wrongLevel = Module(funcs: @[Function(name: "el2",
  attributes: @["interrupt_el2"], ret: voidType,
  blocks: @[Block(label: "entry", term:
    Instruction(kind: Opcode.Return))])])
try:
  discard emitter.emit(wrongLevel, target = "x64-freestanding")
  doAssert false, "EL2 handlers require ARM64"
except ValueError as error:
  doAssert "freestanding target" in error.msg
let bootBuild = driver.build(startup, "release",
  ".artifacts/qbe-native-start", Native(name: "native-start",
    kind: "exe", target: "x64-freestanding", runtime: "none"))
doAssert bootBuild.success, bootBuild.error
doAssert ".set _start, foo.boot" in readFile(
  ".artifacts/qbe-native-start/main-linux.s")

echo "QBE native function probe: ok"
