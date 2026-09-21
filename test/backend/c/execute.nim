import std/[os, strutils]
import ../../../src/backend/c/driver
import ../../../src/build/options
import ../../../src/ir/[kind, node]

let boolean = `Type`(kind: TypeKind.Bool)
let unsigned = `Type`(kind: TypeKind.Uint, width: 64)
let nothing = `Type`(kind: TypeKind.Void)
let flag = Value(kind: ValueKind.Reg, name: "flag", `type`: boolean)
let selected = Value(kind: ValueKind.Reg, name: "selected", `type`: unsigned)
let choose = Function(name: "choose", params: @[flag], ret: unsigned, blocks: @[
  Block(label: "entry", term: Instruction(kind: InstrKind.Cjump, cond: flag,
    trueLabel: "yes", falseLabel: "no")),
  Block(label: "yes", term: Instruction(kind: InstrKind.Jump, label: "join")),
  Block(label: "no", term: Instruction(kind: InstrKind.Jump, label: "join")),
  Block(label: "join", instrs: @[
    Instruction(kind: InstrKind.Phi, dest: selected, blocks: @[
      (label: "yes", value: Value(kind: ValueKind.Const, name: "42", `type`: unsigned)),
      (label: "no", value: Value(kind: ValueKind.Const, name: "7", `type`: unsigned))
    ])
  ], term: Instruction(kind: InstrKind.Return, value: selected))
])
let answer = Value(kind: ValueKind.Reg, name: "answer", `type`: unsigned)
let valid = Value(kind: ValueKind.Reg, name: "valid", `type`: boolean)
let main = Function(name: "main", ret: nothing, blocks: @[
  Block(label: "entry", instrs: @[
    Instruction(kind: InstrKind.Call, dest: answer, `func`: "choose", args: @[
      Value(kind: ValueKind.Const, name: "true", `type`: boolean)]),
    Instruction(kind: InstrKind.Compare, dest: valid, op: "equals", val: answer,
      val2: Value(kind: ValueKind.Const, name: "42", `type`: unsigned))
  ], term: Instruction(kind: InstrKind.Cjump, cond: valid,
    trueLabel: "done", falseLabel: "failed")),
  Block(label: "failed", term: Instruction(kind: InstrKind.Panic,
    msg: "ControlFlowFailure")),
  Block(label: "done", term: Instruction(kind: InstrKind.Return))
])
let module = Module(name: "control", funcs: @[choose, main])
let output = ".artifacts" / "test-c-execute"
if dirExists(output): removeDir(output)
let built = build(module, "dev", output,
  Native(name: "control", compile: true, compiler: "clang", run: true))
doAssert built.success, built.error
doAssert fileExists(built.artifact)
doAssert built.output.len == 0
echo "C executable CFG and Phi parity: ok"
