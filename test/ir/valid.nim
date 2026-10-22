import std/[sequtils, strutils, tables]
import ../../src/ir/valid
import ../../src/ir/node
import ../../src/ir/kind

let term = Instruction(kind: Opcode.Return)
let fallback = Block(label: "fallback", instrs: @[Instruction(kind: Opcode.Trace)], term: Instruction(kind: Opcode.Return))
let section = Block(label: "entry", instrs: @[Instruction(kind: Opcode.Load, fallback: fallback)], term: term)
let function = Function(name: "main", ret: `Type`(kind: Shape.Void), blocks: @[section])
let module = Module(name: "demo", funcs: @[function], externs: @[])
discard seal(module)
doAssert section.params.len == 1
doAssert section.instrs[0].memory.input == "$memory0"
doAssert fallback.params.len == 1
doAssert fallback.instrs[0].memory.input == "$memory2"
let errors = validate(Module(name: "bad", funcs: @[Function(name: "empty", blocks: @[])]))
doAssert errors.anyIt("no entry block" in it.msg)

let invalidFallback = Module(funcs: @[Function(name: "invalid_fallback",
  ret: `Type`(kind: Shape.Void), blocks: @[Block(label: "entry",
    instrs: @[Instruction(kind: Opcode.Defer,
      fallback: Block(label: "cleanup", term:
        Instruction(kind: Opcode.Jump, label: "missing")))],
    term: Instruction(kind: Opcode.Return))])])
doAssert validate(invalidFallback).anyIt("Unknown fallback jump target" in it.msg)

let invalid = `Type`(kind: Shape.Int, width: 129)
doAssert validate(Module(types: @[Definition(name: "wide", `type`: invalid)])).anyIt("Integer width" in it.msg)

let corrupt = Module(storage: @[Storage(name: "counter", value: Value(kind: Flavor.Const,
  name: "300", `type`: `Type`(kind: Shape.Uint, width: 8)))])
doAssert validate(corrupt).anyIt("Invalid static initializer" in it.msg)

let jump = Instruction(kind: Opcode.Jump, label: "next", args: @[])
let target = Block(label: "next", params: @[Value(kind: Flavor.Reg, name: "input",
  `type`: `Type`(kind: Shape.Int, width: 32))], term: Instruction(kind: Opcode.Return))
let edge = Module(funcs: @[Function(name: "edge", ret: `Type`(kind: Shape.Void),
  blocks: @[Block(label: "entry", term: jump), target])])
doAssert validate(edge).anyIt("block parameters" in it.msg)

let missing = Value(kind: Flavor.Reg, name: "missing", `type`: `Type`(kind: Shape.Int, width: 32))
let use = Module(funcs: @[Function(name: "use", ret: `Type`(kind: Shape.Void),
  blocks: @[Block(label: "entry", instrs: @[Instruction(kind: Opcode.Add, val: missing)],
    term: Instruction(kind: Opcode.Return))])])
doAssert validate(use).anyIt("undefined register" in it.msg)

let bad = Module(native: @[Contract(id: "contract", stage: "@c", code: "{}",
  abi: "foo.native:1", effects: @["external"])])
doAssert validate(bad).anyIt("native binding payload" in it.msg)

let payload = """{"format":"foo.native","version":1,"parameters":["value"],"source":"return value;"}"""
let accepted = Module(
  externs: @[Extern(name: "bound", symbol: "contract", params: @[`Type`(kind: Shape.Int, width: 32)], ret: `Type`(kind: Shape.Void))],
  native: @[Contract(id: "contract", stage: "@c", code: payload,
    abi: "foo.native:1", effects: @["external"])])
doAssert validate(accepted).len == 0

let shape = `Type`(kind: Shape.Bool)
let member = `Type`(kind: Shape.Int, width: 32)
let condition = Value(kind: Flavor.Reg, name: "condition", `type`: shape)
let left = Value(kind: Flavor.Reg, name: "left_value", `type`: member)
let dominance = Module(funcs: @[Function(name: "dominance", params: @[condition], ret: `Type`(kind: Shape.Void), blocks: @[
  Block(label: "entry", term: Instruction(kind: Opcode.Cjump, cond: condition, yes: "left", no: "right")),
  Block(label: "left", instrs: @[Instruction(kind: Opcode.Add, dest: left,
    val: Value(kind: Flavor.Const, name: "1", `type`: member),
    val2: Value(kind: Flavor.Const, name: "2", `type`: member))], term: Instruction(kind: Opcode.Return)),
  Block(label: "right", instrs: @[Instruction(kind: Opcode.Add,
    dest: Value(kind: Flavor.Reg, name: "sum", `type`: member), val: left,
    val2: Value(kind: Flavor.Const, name: "1", `type`: member))], term: Instruction(kind: Opcode.Return))
])])
doAssert validate(dominance).anyIt("does not dominate" in it.msg)

let returned = Module(funcs: @[Function(name: "returning", ret: member,
  blocks: @[Block(label: "entry", term: Instruction(kind: Opcode.Return,
    value: Value(kind: Flavor.Const, name: "true", `type`: shape)))])])
doAssert validate(returned).anyIt("Return does not match" in it.msg)

let absent = Module(version: 1, funcs: @[Function(name: "memory", ret: `Type`(kind: Shape.Void),
  blocks: @[Block(label: "entry", instrs: @[Instruction(kind: Opcode.Load,
    dest: Value(kind: Flavor.Reg, name: "loaded", `type`: member),
    `ptr`: Value(kind: Flavor.Reg, name: "pointer", `type`: `Type`(kind: Shape.Ptr, elem: member)),
    effects: @["read"])], term: Instruction(kind: Opcode.Return))])])
doAssert validate(absent).anyIt("explicit effects and a memory dependency" in it.msg)

let option = `Type`(kind: Shape.Optional, elem: member)
let wrapped = Value(kind: Flavor.Reg, name: "wrapped", `type`: option)
let projected = Instruction(kind: Opcode.Extract, val: wrapped, field: "present",
  dest: Value(kind: Flavor.Reg, name: "present", `type`: `Type`(kind: Shape.Bool)))
let optionModule = Module(funcs: @[Function(name: "option", ret: `Type`(kind: Shape.Void),
  blocks: @[Block(label: "entry", instrs: @[
    Instruction(kind: Opcode.Convert, val: Value(kind: Flavor.Const, name: "7", `type`: member),
      dest: wrapped), projected], term: Instruction(kind: Opcode.Return))])])
doAssert validate(optionModule).len == 0, $validate(optionModule)
projected.dest.type = member
doAssert validate(optionModule).anyIt("Projection does not match" in it.msg)

let opened = Instruction(kind: Opcode.Region, op: "open", region: "arena")
let closed = Instruction(kind: Opcode.Region, op: "close", region: "arena")
let regionModule = Module(version: 1, regions: @[Region(id: "arena", kind: "managed")],
  funcs: @[Function(name: "region", ret: `Type`(kind: Shape.Void), blocks: @[
    Block(label: "entry", instrs: @[opened, closed],
      term: Instruction(kind: Opcode.Return))])])
discard seal(regionModule)
doAssert opened.memory.input.len > 0 and opened.memory.output == closed.memory.input
doAssert "write" in opened.effects and "write" in closed.effects
doAssert validate(regionModule).len == 0, $validate(regionModule)

let recursive = `Type`(kind: Shape.Struct, name: "Recursive")
recursive.fields["self"] = recursive
doAssert validate(Module(types: @[Definition(name: "Recursive", `type`: recursive)])).anyIt("no finite layout" in it.msg)

doAssert validate(Module(requires: "impossible")).anyIt("Unknown capability" in it.msg)

let element = `Type`(kind: Shape.Int, width: 32, attributes: @["atomic"])
let atomic = Module(funcs: @[Function(name: "atomic", ret: `Type`(kind: Shape.Void), blocks: @[
  Block(label: "entry", instrs: @[Instruction(kind: Opcode.Atomic, op: "load", field: "release",
    `ptr`: Value(kind: Flavor.Global, name: "cell", `type`: `Type`(kind: Shape.Ptr, elem: element)),
    dest: Value(kind: Flavor.Reg, name: "value", `type`: member), effects: @["synchronize"])],
    term: Instruction(kind: Opcode.Return))
])])
doAssert validate(atomic).anyIt("Invalid memory ordering" in it.msg)

let narrowing = Module(funcs: @[Function(name: "narrow", ret: `Type`(kind: Shape.Void), blocks: @[
  Block(label: "entry", instrs: @[Instruction(kind: Opcode.Convert,
    val: Value(kind: Flavor.Const, name: "1", `type`: `Type`(kind: Shape.Int, width: 64)),
    dest: Value(kind: Flavor.Reg, name: "small", `type`: `Type`(kind: Shape.Int, width: 8)))],
    term: Instruction(kind: Opcode.Return))
])])
doAssert validate(narrowing).anyIt("lossless widening" in it.msg)

let position = Module(funcs: @[Function(name: "index", ret: `Type`(kind: Shape.Void), blocks: @[
  Block(label: "entry", instrs: @[Instruction(kind: Opcode.Index,
    val: Value(kind: Flavor.Const, name: "undefined", `type`: `Type`(kind: Shape.Slice, elem: member)),
    val2: Value(kind: Flavor.Const, name: "0", `type`: member),
    dest: Value(kind: Flavor.Reg, name: "item", `type`: shape))],
    term: Instruction(kind: Opcode.Return))
])])
doAssert validate(position).anyIt("matching element result" in it.msg)
echo "IR validation parity: ok"

# Static storage uses the same exact width proof as frontend literals.
for entry in [
    (kind: Shape.Uint,width: 128,value: "340282366920938463463374607431768211455",ok: true),
    (kind: Shape.Uint,width: 128,value: "340282366920938463463374607431768211456",ok: false),
    (kind: Shape.Int,width: 128,value: "-170141183460469231731687303715884105728",ok: true),
    (kind: Shape.Int,width: 128,value: "-170141183460469231731687303715884105729",ok: false),
    (kind: Shape.Int,width: 64,value: "-9223372036854775808",ok: true),
    (kind: Shape.Uint,width: 64,value: "18446744073709551615",ok: true),
    (kind: Shape.Int,width: 1,value: "-1",ok: true),
    (kind: Shape.Int,width: 1,value: "1",ok: false)]:
  let storage=Module(storage: @[Storage(name: "boundary",value: Value(kind: Flavor.Const,name: entry.value,
    `type`: `Type`(kind: entry.kind,width: entry.width)))])
  doAssert (validate(storage).len == 0) == entry.ok

let optional=Module(storage: @[Storage(name: "present",value: Value(kind: Flavor.Const,name: "42",
  `type`: `Type`(kind: Shape.Optional,elem: member)))])
doAssert validate(optional).len == 0
optional.storage[0].value.name="2147483648"
doAssert validate(optional).anyIt("Invalid static initializer" in it.msg)

let representation=`Type`(kind: Shape.Array,elem: member,width: 2)
let instruction=Instruction(kind: Opcode.Construct,
  dest: Value(kind: Flavor.Reg,name: "array",`type`: representation),args: @[
    Value(kind: Flavor.Const,name: "1",`type`: member),Value(kind: Flavor.Const,name: "2",`type`: member)])
let unit=Module(funcs: @[Function(name: "array",ret: `Type`(kind: Shape.Void),blocks: @[
  Block(label: "entry",instrs: @[instruction],term: Instruction(kind: Opcode.Return))])])
doAssert validate(unit).len == 0
instruction.args.setLen(1)
doAssert validate(unit).anyIt("Construction does not match" in it.msg)

# A long chain of diamonds exercises cross-word dominator sets and merges.
let seed = Value(kind: Flavor.Reg, name: "denseSeed", `type`: member)
let branch = Value(kind: Flavor.Const, name: "true", `type`: `Type`(kind: Shape.Bool))
var dense = @[Block(label: "entry", instrs: @[
  Instruction(kind: Opcode.Add, dest: seed,
    val: Value(kind: Flavor.Const, name: "1", `type`: member),
    val2: Value(kind: Flavor.Const, name: "2", `type`: member))],
  term: Instruction(kind: Opcode.Jump, label: "join0"))]
for index in 0..<128:
  let suffix = $index
  dense.add(Block(label: "join" & suffix,
    term: Instruction(kind: Opcode.Cjump, cond: branch,
      yes: "left" & suffix, no: "right" & suffix)))
  for side in ["left", "right"]:
    dense.add(Block(label: side & suffix,
      term: Instruction(kind: Opcode.Jump, label: "join" & $(index + 1))))
dense.add(Block(label: "join128", term: Instruction(kind: Opcode.Return, value: seed)))
let namespace = Module(funcs: @[Function(name: "dense", ret: member, blocks: dense)])
doAssert validate(namespace).len == 0
# A definition from only one branch must not dominate the common exit.
dense[0].instrs.setLen(0)
dense[2].instrs.add(Instruction(kind: Opcode.Add, dest: seed,
  val: Value(kind: Flavor.Const, name: "1", `type`: member),
  val2: Value(kind: Flavor.Const, name: "2", `type`: member)))
doAssert validate(namespace).anyIt("does not dominate" in it.msg)

# Effect sealing generates memory types whose defining tables live for only
# one function. Deferred layout validation must keep them alive across a large
# module, including collections triggered while validating later functions.
var functions: seq[Function]
for index in 0..<2048:
  let value = Value(kind: Flavor.Reg, name: "result", `type`: member)
  functions.add(Function(name: "effect" & $index, ret: member,
    blocks: @[Block(label: "entry", instrs: @[
      Instruction(kind: Opcode.Call, `func`: "identity", dest: value,
        args: @[Value(kind: Flavor.Const, name: "42", `type`: member)])],
      term: Instruction(kind: Opcode.Return, value: value))]))
let declaration = Module(funcs: functions,
  externs: @[Extern(name: "identity", abi: "c", params: @[member], ret: member)])
discard seal(declaration)
doAssert validate(declaration).len == 0
