import std/[sequtils, strutils, tables]
import ../../src/ir/valid
import ../../src/ir/node
import ../../src/ir/kind

let term = Instruction(kind: InstrKind.Return)
let fallback = Block(label: "fallback", instrs: @[Instruction(kind: InstrKind.Trace)], term: Instruction(kind: InstrKind.Return))
let basicBlock = Block(label: "entry", instrs: @[Instruction(kind: InstrKind.Load, fallback: fallback)], term: term)
let function = Function(name: "main", ret: `Type`(kind: TypeKind.Void), blocks: @[basicBlock])
let module = Module(name: "demo", funcs: @[function], externs: @[])
discard seal(module)
doAssert basicBlock.params.len == 1
doAssert basicBlock.instrs[0].memory.input == "$memory0"
doAssert fallback.params.len == 1
doAssert fallback.instrs[0].memory.input == "$memory2"
let emptyErrors = validate(Module(name: "bad", funcs: @[Function(name: "empty", blocks: @[])]))
doAssert emptyErrors.anyIt("no entry block" in it.msg)

let invalidWidth = `Type`(kind: TypeKind.Int, width: 129)
doAssert validate(Module(types: @[TypeDecl(name: "wide", `type`: invalidWidth)])).anyIt("Integer width" in it.msg)

let badStorage = Module(storage: @[Storage(name: "counter", value: Value(kind: ValueKind.Const,
  name: "300", `type`: `Type`(kind: TypeKind.Uint, width: 8)))])
doAssert validate(badStorage).anyIt("Invalid static initializer" in it.msg)

let jump = Instruction(kind: InstrKind.Jump, label: "next", args: @[])
let target = Block(label: "next", params: @[Value(kind: ValueKind.Reg, name: "input",
  `type`: `Type`(kind: TypeKind.Int, width: 32))], term: Instruction(kind: InstrKind.Return))
let badEdge = Module(funcs: @[Function(name: "edge", ret: `Type`(kind: TypeKind.Void),
  blocks: @[Block(label: "entry", term: jump), target])])
doAssert validate(badEdge).anyIt("block parameters" in it.msg)

let missing = Value(kind: ValueKind.Reg, name: "missing", `type`: `Type`(kind: TypeKind.Int, width: 32))
let badUse = Module(funcs: @[Function(name: "use", ret: `Type`(kind: TypeKind.Void),
  blocks: @[Block(label: "entry", instrs: @[Instruction(kind: InstrKind.Add, val: missing)],
    term: Instruction(kind: InstrKind.Return))])])
doAssert validate(badUse).anyIt("undefined register" in it.msg)

let badNative = Module(native: @[NativeContract(id: "contract", stage: "@c", code: "{}",
  abi: "foo.native:1", effects: @["external"])])
doAssert validate(badNative).anyIt("native binding payload" in it.msg)

let nativePayload = """{"format":"foo.native","version":1,"parameters":["value"],"source":"return value;"}"""
let validNative = Module(
  externs: @[Extern(name: "bound", symbol: "contract", params: @[`Type`(kind: TypeKind.Int, width: 32)], ret: `Type`(kind: TypeKind.Void))],
  native: @[NativeContract(id: "contract", stage: "@c", code: nativePayload,
    abi: "foo.native:1", effects: @["external"])])
doAssert validate(validNative).len == 0

let boolType = `Type`(kind: TypeKind.Bool)
let intType = `Type`(kind: TypeKind.Int, width: 32)
let branchCondition = Value(kind: ValueKind.Reg, name: "condition", `type`: boolType)
let definedOnLeft = Value(kind: ValueKind.Reg, name: "left_value", `type`: intType)
let dominance = Module(funcs: @[Function(name: "dominance", params: @[branchCondition], ret: `Type`(kind: TypeKind.Void), blocks: @[
  Block(label: "entry", term: Instruction(kind: InstrKind.Cjump, cond: branchCondition, trueLabel: "left", falseLabel: "right")),
  Block(label: "left", instrs: @[Instruction(kind: InstrKind.Add, dest: definedOnLeft,
    val: Value(kind: ValueKind.Const, name: "1", `type`: intType),
    val2: Value(kind: ValueKind.Const, name: "2", `type`: intType))], term: Instruction(kind: InstrKind.Return)),
  Block(label: "right", instrs: @[Instruction(kind: InstrKind.Add,
    dest: Value(kind: ValueKind.Reg, name: "sum", `type`: intType), val: definedOnLeft,
    val2: Value(kind: ValueKind.Const, name: "1", `type`: intType))], term: Instruction(kind: InstrKind.Return))
])])
doAssert validate(dominance).anyIt("does not dominate" in it.msg)

let badReturn = Module(funcs: @[Function(name: "returning", ret: intType,
  blocks: @[Block(label: "entry", term: Instruction(kind: InstrKind.Return,
    value: Value(kind: ValueKind.Const, name: "true", `type`: boolType)))])])
doAssert validate(badReturn).anyIt("Return does not match" in it.msg)

let missingMemory = Module(version: 1, funcs: @[Function(name: "memory", ret: `Type`(kind: TypeKind.Void),
  blocks: @[Block(label: "entry", instrs: @[Instruction(kind: InstrKind.Load,
    dest: Value(kind: ValueKind.Reg, name: "loaded", `type`: intType),
    `ptr`: Value(kind: ValueKind.Reg, name: "pointer", `type`: `Type`(kind: TypeKind.Ptr, elem: intType)),
    effects: @["read"])], term: Instruction(kind: InstrKind.Return))])])
doAssert validate(missingMemory).anyIt("explicit effects and a memory dependency" in it.msg)

let recursive = `Type`(kind: TypeKind.Struct, name: "Recursive")
recursive.fields["self"] = recursive
doAssert validate(Module(types: @[TypeDecl(name: "Recursive", `type`: recursive)])).anyIt("no finite layout" in it.msg)

doAssert validate(Module(requires: "impossible")).anyIt("Unknown capability" in it.msg)

let atomicElement = `Type`(kind: TypeKind.Int, width: 32, attributes: @["atomic"])
let invalidAtomic = Module(funcs: @[Function(name: "atomic", ret: `Type`(kind: TypeKind.Void), blocks: @[
  Block(label: "entry", instrs: @[Instruction(kind: InstrKind.Atomic, op: "load", field: "release",
    `ptr`: Value(kind: ValueKind.Global, name: "cell", `type`: `Type`(kind: TypeKind.Ptr, elem: atomicElement)),
    dest: Value(kind: ValueKind.Reg, name: "value", `type`: intType), effects: @["synchronize"])],
    term: Instruction(kind: InstrKind.Return))
])])
doAssert validate(invalidAtomic).anyIt("Invalid memory ordering" in it.msg)

let narrowing = Module(funcs: @[Function(name: "narrow", ret: `Type`(kind: TypeKind.Void), blocks: @[
  Block(label: "entry", instrs: @[Instruction(kind: InstrKind.Convert,
    val: Value(kind: ValueKind.Const, name: "1", `type`: `Type`(kind: TypeKind.Int, width: 64)),
    dest: Value(kind: ValueKind.Reg, name: "small", `type`: `Type`(kind: TypeKind.Int, width: 8)))],
    term: Instruction(kind: InstrKind.Return))
])])
doAssert validate(narrowing).anyIt("lossless widening" in it.msg)

let invalidIndex = Module(funcs: @[Function(name: "index", ret: `Type`(kind: TypeKind.Void), blocks: @[
  Block(label: "entry", instrs: @[Instruction(kind: InstrKind.Index,
    val: Value(kind: ValueKind.Const, name: "undefined", `type`: `Type`(kind: TypeKind.Slice, elem: intType)),
    val2: Value(kind: ValueKind.Const, name: "0", `type`: intType),
    dest: Value(kind: ValueKind.Reg, name: "item", `type`: boolType))],
    term: Instruction(kind: InstrKind.Return))
])])
doAssert validate(invalidIndex).anyIt("matching element result" in it.msg)
echo "IR validation parity: ok"
