import std/[os, tables, strutils]
import ../../../src/backend/qbe/emitter
import ../../../src/ir/[kind, node]

let boolean = `Type`(kind: Shape.Bool)
let u3 = `Type`(kind: Shape.Uint, width: 3)
let i17 = `Type`(kind: Shape.Int, width: 17)
let u64 = `Type`(kind: Shape.Uint, width: 64)
let u128 = `Type`(kind: Shape.Uint, width: 128)
let i65 = `Type`(kind: Shape.Int, width: 65)

proc constant(t: `Type`; number: string): Value =
  Value(kind: Flavor.Const, `type`: t, name: number)

proc reg(t: `Type`; name: string): Value =
  Value(kind: Flavor.Reg, `type`: t, name: name)

proc arithmetic(name: string; t: `Type`; op: Opcode;
    left, right, expected: string): Function =
  let value = reg(t, "value")
  let matched = reg(boolean, "matched")
  Function(name: name, public: true, abi: "c", ret: boolean, blocks: @[
    Block(label: "entry", instrs: @[
      Instruction(kind: op, dest: value,
        val: constant(t, left), val2: constant(t, right)),
      Instruction(kind: Opcode.Compare, op: "equals", dest: matched,
        val: value, val2: constant(t, expected))],
      term: Instruction(kind: Opcode.Return, value: matched))])

let narrowAdd = arithmetic("qbe_u3_add", u3, Opcode.Add, "2", "3", "5")
let narrowDiv = arithmetic("qbe_i17_div", i17, Opcode.Div,
  "-60000", "3", "-20000")
let wideAdd = arithmetic("qbe_u128_add", u128, Opcode.Add,
  "18446744073709551615", "1", "18446744073709551616")
let wideMul = arithmetic("qbe_u128_mul", u128, Opcode.Mul,
  "18446744073709551616", "3", "55340232221128654848")
let wideDiv = arithmetic("qbe_u128_div", u128, Opcode.Div,
  "18446744073709551616", "2", "9223372036854775808")
let signedAdd = arithmetic("qbe_i65_add", i65, Opcode.Add,
  "-18446744073709551616", "1", "-18446744073709551615")

proc bitTest(name: string; t, countType: `Type`; operation,
    left, right, expected: string): Function =
  let value = reg(t, "value")
  let matched = reg(boolean, "matched")
  Function(name: name, public: true, abi: "c", ret: boolean, blocks: @[
    Block(label: "entry", instrs: @[
      Instruction(kind: Opcode.Bit, op: operation, dest: value,
        val: constant(t, left), val2: constant(countType, right)),
      Instruction(kind: Opcode.Compare, op: "equals", dest: matched,
        val: value, val2: constant(t, expected))],
      term: Instruction(kind: Opcode.Return, value: matched))])

let narrowShift = bitTest("qbe_u3_shift", u3, u3, "shl", "1", "1", "2")
let signedShift = bitTest("qbe_i17_shift", i17, i17, "ashr", "-4", "1", "-2")
let wideBit = bitTest("qbe_u128_set", u128, u64, "set",
  "18446744073709551616", "1", "18446744073709551618")

let packed = `Type`(kind: Shape.PackedStruct,
  fields: toOrderedTable({"low": u3, "large": i65}))
let first = reg(packed, "first")
let second = reg(packed, "second")
let ordered = reg(boolean, "ordered")
let packedCompare = Function(name: "qbe_packed_order", public: true,
  abi: "c", ret: boolean, blocks: @[Block(label: "entry", instrs: @[
    Instruction(kind: Opcode.Construct, dest: first,
      args: @[constant(u3, "2"), constant(i65, "-2")]),
    Instruction(kind: Opcode.Construct, dest: second,
      args: @[constant(u3, "2"), constant(i65, "1")]),
    Instruction(kind: Opcode.Compare, op: "is less than", dest: ordered,
      val: first, val2: second)],
    term: Instruction(kind: Opcode.Return, value: ordered))])

let i32 = `Type`(kind: Shape.Int, width: 32)
let cleanupCell = Value(kind: Flavor.Global, name: "cleanup_cell",
  `type`: `Type`(kind: Shape.Ptr, elem: i32))
let cleanupValue = reg(i32, "cleanup_value")
let deferred = Function(name: "qbe_defer_arithmetic", public: true,
  abi: "c", ret: boolean, blocks: @[Block(label: "entry", instrs: @[
    Instruction(kind: Opcode.Defer, fallback: Block(label: "cleanup",
      instrs: @[
        Instruction(kind: Opcode.Add, dest: cleanupValue,
          val: constant(i32, "20"), val2: constant(i32, "22")),
        Instruction(kind: Opcode.Store, `ptr`: cleanupCell,
          val: cleanupValue)]))],
    term: Instruction(kind: Opcode.Return, value:
      Value(kind: Flavor.Const, `type`: boolean, name: "true")))])

let nestedDeferred = Function(name: "qbe_nested_defer", public: true,
  abi: "c", ret: boolean, blocks: @[Block(label: "entry", instrs: @[
    Instruction(kind: Opcode.Defer, fallback: Block(label: "outer_cleanup",
      instrs: @[
        Instruction(kind: Opcode.Defer, fallback: Block(
          label: "inner_cleanup", instrs: @[
            Instruction(kind: Opcode.Store, `ptr`: cleanupCell,
              val: constant(i32, "2"))])),
        Instruction(kind: Opcode.Store, `ptr`: cleanupCell,
          val: constant(i32, "3"))]))],
    term: Instruction(kind: Opcode.Return, value:
      Value(kind: Flavor.Const, `type`: boolean, name: "true")))])

let failable = `Type`(kind: Shape.Failable, elem: i32)
let failingCleanup = reg(failable, "failing_cleanup")
let successfulResult = reg(failable, "successful_result")
let cleanupTryValue = reg(i32, "cleanup_try_value")
let deferredTry = Function(name: "qbe_defer_try", public: true,
  abi: "c", ret: failable, blocks: @[Block(label: "entry", instrs: @[
    Instruction(kind: Opcode.Defer, fallback: Block(label: "early_cleanup",
      instrs: @[Instruction(kind: Opcode.Store, `ptr`: cleanupCell,
        val: constant(i32, "7"))])),
    Instruction(kind: Opcode.Defer, fallback: Block(label: "late_cleanup",
      instrs: @[
        Instruction(kind: Opcode.Try, dest: cleanupTryValue,
          expr: failingCleanup),
        Instruction(kind: Opcode.Store, `ptr`: cleanupCell,
          val: constant(i32, "99"))])),
    Instruction(kind: Opcode.Construct, op: "error", dest: failingCleanup,
      args: @[Value(kind: Flavor.Const, name: "CleanupFailure",
        `type`: `Type`(kind: Shape.Error))]),
    Instruction(kind: Opcode.Convert, dest: successfulResult,
      val: constant(i32, "42"))],
    term: Instruction(kind: Opcode.Return, value: successfulResult))])
let failure = reg(failable, "failure")
let fallbackValue = reg(i32, "fallback_value")
let caught = reg(i32, "caught")
let catchMatched = reg(boolean, "catch_matched")
let catchArithmetic = Function(name: "qbe_catch_arithmetic", public: true,
  abi: "c", ret: boolean, blocks: @[Block(label: "entry", instrs: @[
    Instruction(kind: Opcode.Construct, op: "error", dest: failure,
      args: @[Value(kind: Flavor.Const, name: "ExpectedError",
        `type`: `Type`(kind: Shape.Error))]),
    Instruction(kind: Opcode.Catch, dest: caught, val: failure,
      fallback: Block(label: "fallback", instrs: @[
        Instruction(kind: Opcode.Add, dest: fallbackValue,
          val: constant(i32, "20"), val2: constant(i32, "22"))],
        term: Instruction(kind: Opcode.Return, value: fallbackValue))),
    Instruction(kind: Opcode.Compare, op: "equals", dest: catchMatched,
      val: caught, val2: constant(i32, "42"))],
    term: Instruction(kind: Opcode.Return, value: catchMatched))])

let loopCounter = reg(i32, "loop_counter")
let nextCounter = reg(i32, "next_counter")
let continueLoop = reg(boolean, "continue_loop")
let deferredGraph = Function(name: "qbe_defer_graph", public: true,
  abi: "c", ret: boolean, blocks: @[Block(label: "entry", instrs: @[
    Instruction(kind: Opcode.Defer,
      fallback: Block(label: "cleanup_entry", term:
        Instruction(kind: Opcode.Jump, label: "cleanup_loop",
          args: @[constant(i32, "0")])),
      fallbackBlocks: @[
        Block(label: "cleanup_loop", params: @[loopCounter], instrs: @[
          Instruction(kind: Opcode.Compare, op: "is less than",
            dest: continueLoop, val: loopCounter,
            val2: constant(i32, "3"))],
          term: Instruction(kind: Opcode.Cjump, cond: continueLoop,
            yes: "cleanup_body", no: "cleanup_end")),
        Block(label: "cleanup_body", instrs: @[
          Instruction(kind: Opcode.Add, dest: nextCounter,
            val: loopCounter, val2: constant(i32, "1")),
          Instruction(kind: Opcode.Store, `ptr`: cleanupCell,
            val: nextCounter)],
          term: Instruction(kind: Opcode.Jump, label: "cleanup_loop",
            args: @[nextCounter])),
        Block(label: "cleanup_end", term:
          Instruction(kind: Opcode.Return))])],
    term: Instruction(kind: Opcode.Return,
      value: constant(boolean, "true")))])

let graphCaught = reg(i32, "graph_caught")
let graphMatched = reg(boolean, "graph_matched")
let catchGraph = Function(name: "qbe_catch_graph", public: true,
  abi: "c", ret: boolean, blocks: @[Block(label: "entry", instrs: @[
    Instruction(kind: Opcode.Construct, op: "error", dest: failure,
      args: @[Value(kind: Flavor.Const, name: "ExpectedError",
        `type`: `Type`(kind: Shape.Error))]),
    Instruction(kind: Opcode.Catch, dest: graphCaught, val: failure,
      fallback: Block(label: "graph_entry", term:
        Instruction(kind: Opcode.Cjump, cond: constant(boolean, "false"),
          yes: "graph_wrong", no: "graph_right")),
      fallbackBlocks: @[
        Block(label: "graph_wrong", term:
          Instruction(kind: Opcode.Return, value: constant(i32, "40"))),
        Block(label: "graph_right", term:
          Instruction(kind: Opcode.Return, value: constant(i32, "42")))]),
    Instruction(kind: Opcode.Compare, op: "equals", dest: graphMatched,
      val: graphCaught, val2: constant(i32, "42"))],
    term: Instruction(kind: Opcode.Return, value: graphMatched))])

let module = Module(funcs: @[narrowAdd, narrowDiv, wideAdd, wideMul,
  wideDiv, signedAdd, narrowShift, signedShift, wideBit,
  packedCompare, deferred, nestedDeferred, deferredTry, catchArithmetic,
  deferredGraph, catchGraph],
  storage: @[Storage(name: "cleanup_cell", public: true,
    value: constant(i32, "0"))])
let il = emit(module, target = "windows-x64")
doAssert "foo_qbe_integer64" in il
doAssert "foo_qbe_integer128" in il
doAssert "foo_qbe_integer_bit64" in il
doAssert "foo_qbe_integer_bit128" in il
doAssert "foo_qbe_packed_compare" in il
doAssert "qbe.cleanup.run." in il
doAssert "qbe_defer_try" in il
doAssert "qbe_nested_defer" in il
doAssert "qbe.issue.bad." in il
doAssert "qbe.fallback.edge." in il
let output = getEnv("FOO_QBE_INTEGER_OUTPUT")
if output.len > 0: writeFile(output, il)
echo "QBE integer probe: ok"
