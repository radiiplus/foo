import std/[sequtils, strutils, tables]
import ../../src/ast/node as ast
import ../../src/diag/span
import ../../src/ir/[kind, lower, monomorph, node, valid]
import ../../src/backend/qbe/emitter as qbeEmitter
import ../../src/diag/engine
import ../../src/lex/lexer
import ../../src/ast/parser
import ../../src/types/checker as checking

let position = Span(start: 0, `end`: 1, line: 1, col: 1, file: "lower.iv")
proc name(value: string): ast.Name = ast.Name(tag: "name", span: position, text: value)
let function = ast.Function(tag: "function", span: position, name: name("main"),
  returns: ast.Primitive(tag: "primitive", span: position, name: "integer"),
  body: ast.Block(tag: "block", span: position, stmts: @[
    ast.Statement(ast.Give(tag: "give", span: position,
      value: ast.Binary(tag: "binary", span: position, op: "plus",
        left: ast.Integer(tag: "integer", span: position, value: "40"),
        right: ast.Integer(tag: "integer", span: position, value: "2"))))
  ]))
let program = ast.Program(tag: "program", span: position, units: @[
  ast.Unit(tag: "unit", span: position, name: name("sample"),
    body: ast.Block(tag: "block", span: position, stmts: @[ast.Statement(function)]))
])
let module = lower(program)
doAssert module.version == 1
doAssert module.stage == "@foo"
doAssert module.funcs.len == 1
doAssert module.funcs[0].blocks[0].term.kind == Opcode.Return
doAssert module.funcs[0].blocks[0].term.value.name == "tmp_1"
doAssert module.funcs[0].blocks[0].instrs.len == 1
doAssert module.funcs[0].blocks[0].instrs[0].kind == Opcode.Add
doAssert module.funcs[0].blocks[0].instrs[0].val.name == "40"
doAssert module.funcs[0].blocks[0].instrs[0].val2.name == "2"
doAssert module.funcs[0].blocks[0].instrs[0].span.file == "lower.iv"
doAssert module.funcs[0].blocks[0].instrs[0].span.start == 0
doAssert module.funcs[0].blocks[0].instrs[0].span.`end` == 1
doAssert module.funcs[0].blocks[0].term.span.file == "lower.iv"

let increment = ast.Function(tag: "function", span: position, name: name("increment"),
  params: @[ast.Parameter(tag: "parameter", span: position, name: name("value"),
    `type`: ast.Primitive(tag: "primitive", name: "integer"))],
  returns: ast.Primitive(tag: "primitive", name: "integer"),
  body: ast.Block(tag: "block", stmts: @[
    ast.Statement(ast.Give(tag: "give", value: ast.Binary(tag: "binary", op: "plus",
      left: name("value"), right: ast.Integer(tag: "integer", value: "1"))))
  ]))
let caller = ast.Function(tag: "function", span: position, name: name("caller"),
  returns: ast.Primitive(tag: "primitive", name: "integer"),
  body: ast.Block(tag: "block", stmts: @[
    ast.Statement(ast.Mutable(tag: "mutable", name: name("current"),
      value: ast.Integer(tag: "integer", value: "40"))),
    ast.Statement(ast.Assignment(tag: "assignment", target: name("current"),
      value: ast.Call(tag: "call", callee: name("increment"), args: @[ast.Expression(name("current"))]))),
    ast.Statement(ast.Give(tag: "give", value: name("current")))
  ]))
program.units[0].body.stmts = @[ast.Statement(increment), ast.Statement(caller)]
let calls = lower(program)
doAssert calls.funcs.len == 2
doAssert calls.funcs[1].blocks[0].instrs.anyIt(it.kind == Opcode.Call and it.func == "increment")
doAssert calls.funcs[1].blocks[0].instrs.countIt(it.kind == Opcode.Load) == 2
doAssert calls.funcs[1].blocks[0].instrs.countIt(it.kind == Opcode.Store) == 2

let machine = ast.Function(tag: "function", span: position, name: name("machine"),
  body: ast.Block(tag: "block", stmts: @[
    ast.Statement(ast.Mutable(tag: "mutable", name: name("counter"),
      `type`: ast.Primitive(tag: "primitive", name: "unsigned", width: "64"),
      value: ast.Integer(tag: "integer", value: "0"))),
    ast.Statement(ast.Machine(tag: "machine", operation: "atomic", target: name("counter"),
      value: ast.Integer(tag: "integer", value: "1"))),
    ast.Statement(ast.Give(tag: "give"))
  ]))
program.units[0].body.stmts = @[ast.Statement(machine)]
let hardware = lower(program)
doAssert hardware.funcs[0].blocks[0].instrs.anyIt(it.kind == Opcode.Atomic and it.op == "add")
doAssert hardware.funcs[0].blocks[0].instrs.anyIt("synchronize" in it.effects)
let assembly = validate(hardware)
doAssert assembly.len == 0, assembly.mapIt(it.msg).join("\n")

let choose = ast.Function(tag: "function", span: position, name: name("choose"),
  params: @[ast.Parameter(tag: "parameter", name: name("flag"),
    `type`: ast.Primitive(tag: "primitive", name: "boolean"))],
  returns: ast.Primitive(tag: "primitive", name: "integer"),
  body: ast.Block(tag: "block", stmts: @[
    ast.Statement(ast.`When`(tag: "when", cond: name("flag"),
      `then`: ast.Block(tag: "block", stmts: @[ast.Statement(ast.Give(tag: "give",
        value: ast.Integer(tag: "integer", value: "1")))]),
      `else`: ast.Block(tag: "block", stmts: @[ast.Statement(ast.Give(tag: "give",
        value: ast.Integer(tag: "integer", value: "2")))])))
  ]))
program.units[0].body.stmts = @[ast.Statement(choose)]
let choice = lower(program)
doAssert choice.funcs[0].blocks[0].term.kind == Opcode.Cjump
doAssert choice.funcs[0].blocks.countIt(it.term.kind == Opcode.Return) == 2
let selection = validate(choice)
doAssert selection.len == 0, selection.mapIt(it.msg).join("\n")

let routine = ast.Function(tag: "function", span: position, name: name("count"),
  returns: ast.Primitive(tag: "primitive", name: "integer"),
  body: ast.Block(tag: "block", stmts: @[
    ast.Statement(ast.Mutable(tag: "mutable", name: name("index"),
      value: ast.Integer(tag: "integer", value: "0"))),
    ast.Statement(ast.`While`(tag: "while",
      cond: ast.Binary(tag: "binary", op: "is less than", left: name("index"),
        right: ast.Integer(tag: "integer", value: "3")),
      body: ast.Block(tag: "block", stmts: @[
        ast.Statement(ast.Assignment(tag: "assignment", target: name("index"),
          value: ast.Binary(tag: "binary", op: "plus", left: name("index"),
            right: ast.Integer(tag: "integer", value: "1"))))
      ]))),
    ast.Statement(ast.Give(tag: "give", value: name("index")))
  ]))
program.units[0].body.stmts = @[ast.Statement(routine)]
let repetition = lower(program)
doAssert repetition.funcs[0].blocks.anyIt(it.term.kind == Opcode.Cjump)
doAssert repetition.funcs[0].blocks.countIt(it.term.kind == Opcode.Jump) >= 2
let loop = validate(repetition)
doAssert loop.len == 0, loop.mapIt(it.msg).join("\n")

let sum = ast.Function(tag: "function", span: position, name: name("sum"),
  params: @[ast.Parameter(tag: "parameter", name: name("items"),
    `type`: ast.Sequence(tag: "sequence", elem: ast.Primitive(tag: "primitive", name: "integer")))],
  returns: ast.Primitive(tag: "primitive", name: "integer"),
  body: ast.Block(tag: "block", stmts: @[
    ast.Statement(ast.Mutable(tag: "mutable", name: name("total"),
      value: ast.Integer(tag: "integer", value: "0"))),
    ast.Statement(ast.`For`(tag: "for", `bind`: name("item"), iter: name("items"),
      body: ast.Block(tag: "block", stmts: @[
        ast.Statement(ast.Assignment(tag: "assignment", target: name("total"),
          value: ast.Binary(tag: "binary", op: "plus", left: name("total"), right: name("item"))))
      ]))),
    ast.Statement(ast.Give(tag: "give", value: name("total")))
  ]))
program.units[0].body.stmts = @[ast.Statement(sum)]
let iterative = lower(program)
var length, hasIndex = false
for section in iterative.funcs[0].blocks:
  for instruction in section.instrs:
    if instruction.kind == Opcode.Length: length = true
    if instruction.kind == Opcode.Index: hasIndex = true
doAssert length
doAssert hasIndex
let iteration = validate(iterative)
doAssert iteration.len == 0, iteration.mapIt(it.msg).join("\n")

let classify = ast.Function(tag: "function", span: position, name: name("classify"),
  params: @[ast.Parameter(tag: "parameter", name: name("value"),
    `type`: ast.Primitive(tag: "primitive", name: "integer"))],
  returns: ast.Primitive(tag: "primitive", name: "integer"),
  body: ast.Block(tag: "block", stmts: @[
    ast.Statement(ast.Match(tag: "match", scrutinee: name("value"), cases: @[
      ast.`Case`(tag: "case", pattern: ast.Pattern(ast.Integer(tag: "integer", value: "1")),
        body: ast.Block(tag: "block", stmts: @[ast.Statement(ast.Give(tag: "give",
          value: ast.Integer(tag: "integer", value: "10")))])),
      ast.`Case`(tag: "case", pattern: ast.Wildcard(tag: "wildcard"),
        body: ast.Block(tag: "block", stmts: @[ast.Statement(ast.Give(tag: "give",
          value: ast.Integer(tag: "integer", value: "20"))) ]))
    ]))
  ]))
program.units[0].body.stmts = @[ast.Statement(classify)]
let match = lower(program)
doAssert match.funcs[0].blocks.countIt(it.term.kind == Opcode.Cjump) == 2
let matching = validate(match)
doAssert matching.len == 0, matching.mapIt(it.msg).join("\n")

let mark = ast.External(tag: "extern-function", span: position, name: name("mark"),
  abi: "c", symbol: "mark", params: @[ast.Parameter(tag: "parameter", name: name("value"),
    `type`: ast.Primitive(tag: "primitive", name: "integer"))],
  returns: ast.Primitive(tag: "primitive", name: "nothing"))
let cleaned = ast.Function(tag: "function", span: position, name: name("cleaned"),
  body: ast.Block(tag: "block", stmts: @[
    ast.Statement(ast.`Defer`(tag: "defer", body: ast.Block(tag: "block", stmts: @[
      ast.Statement(ast.Action(tag: "action", name: name("mark"),
        args: @[ast.Expression(ast.Integer(tag: "integer", value: "1"))]))
    ]))),
    ast.Statement(ast.Give(tag: "give"))
  ]))
program.units[0].body.stmts = @[ast.Statement(mark), ast.Statement(cleaned)]
let teardown = lower(program)
doAssert teardown.funcs[0].blocks[0].instrs.anyIt(it.kind == Opcode.Call and it.func == "mark")
let cleanup = validate(teardown)
doAssert cleanup.len == 0, cleanup.mapIt(it.msg).join("\n")

let nestedCleanup = ast.Function(tag: "function", span: position,
  name: name("nestedCleanup"), body: ast.Block(tag: "block", stmts: @[
    ast.Statement(ast.`Defer`(tag: "defer", body: ast.Block(tag: "block",
      stmts: @[ast.Statement(ast.Action(tag: "action", name: name("mark"),
        args: @[ast.Expression(ast.Integer(tag: "integer", value: "1"))]))]))),
    ast.Statement(ast.`Defer`(tag: "defer", body: ast.Block(tag: "block",
      stmts: @[
        ast.Statement(ast.`Defer`(tag: "defer", body: ast.Block(tag: "block",
          stmts: @[ast.Statement(ast.Action(tag: "action", name: name("mark"),
            args: @[ast.Expression(ast.Integer(tag: "integer", value: "2"))]))]))),
        ast.Statement(ast.Action(tag: "action", name: name("mark"),
          args: @[ast.Expression(ast.Integer(tag: "integer", value: "3"))]))]))),
    ast.Statement(ast.Give(tag: "give"))]))
program.units[0].body.stmts = @[ast.Statement(mark), ast.Statement(nestedCleanup)]
let nested = lower(program)
let nestedErrors = validate(nested)
doAssert nestedErrors.len == 0, nestedErrors.mapIt(it.msg).join("\n")
var cleanupOrder: seq[string]
for section in nested.funcs[0].blocks:
  for instruction in section.instrs:
    if instruction.kind == Opcode.Call and instruction.func == "mark":
      cleanupOrder.add(instruction.args[0].name)
doAssert cleanupOrder == @["3", "2", "1"], $cleanupOrder
doAssert qbeEmitter.emit(nested).count("call $mark") == 3

let failedResult = ast.Error(tag: "error",
  elem: ast.Primitive(tag: "primitive", name: "integer"))
let fail = ast.External(tag: "extern-function", span: position,
  name: name("fail"), abi: "c", symbol: "fail", returns: failedResult)
let cleanupFailure = ast.Function(tag: "function", span: position,
  name: name("cleanupFailure"), returns: failedResult,
  body: ast.Block(tag: "block", stmts: @[
    ast.Statement(ast.`Defer`(tag: "defer", body: ast.Block(tag: "block",
      stmts: @[ast.Statement(ast.Action(tag: "action", name: name("mark"),
        args: @[ast.Expression(ast.Integer(tag: "integer", value: "1"))]))]))),
    ast.Statement(ast.`Defer`(tag: "defer", body: ast.Block(tag: "block",
      stmts: @[
        ast.Statement(ast.`Defer`(tag: "defer", body: ast.Block(tag: "block",
          stmts: @[ast.Statement(ast.Action(tag: "action", name: name("mark"),
            args: @[ast.Expression(ast.Integer(tag: "integer", value: "2"))]))]))),
        ast.Statement(ast.Action(tag: "action", value: ast.Unary(tag: "unary",
          op: "try", operand: ast.Call(tag: "call", callee: name("fail")))))]))),
    ast.Statement(ast.Give(tag: "give", value: ast.Call(tag: "call",
      callee: name("fail"))))]))
program.units[0].body.stmts = @[
  ast.Statement(mark), ast.Statement(fail), ast.Statement(cleanupFailure)]
let propagatedCleanup = lower(program)
let propagatedErrors = validate(propagatedCleanup)
doAssert propagatedErrors.len == 0,
  propagatedErrors.mapIt(it.msg).join("\n")
doAssert propagatedCleanup.funcs[0].blocks.len < 100
doAssert "call $mark" in qbeEmitter.emit(propagatedCleanup)

let identity = ast.Function(tag: "function", span: position, name: name("identity"),
  generics: @[ast.Generic(tag: "type-param", name: name("T"))],
  params: @[ast.Parameter(tag: "parameter", name: name("value"),
    `type`: ast.Named(tag: "named", name: name("T")))],
  returns: ast.Named(tag: "named", name: name("T")),
  body: ast.Block(tag: "block", stmts: @[
    ast.Statement(ast.Give(tag: "give", value: name("value")))
  ]))
let generic = ast.Function(tag: "function", span: position, name: name("genericCaller"),
  returns: ast.Primitive(tag: "primitive", name: "integer"),
  body: ast.Block(tag: "block", stmts: @[
    ast.Statement(ast.Give(tag: "give", value: ast.Call(tag: "call", callee: name("identity"),
      types: @[ast.`Type`(ast.Primitive(tag: "primitive", name: "integer"))],
      args: @[ast.Expression(ast.Integer(tag: "integer", value: "7"))])))
  ]))
program.units[0].body.stmts = @[ast.Statement(identity), ast.Statement(generic)]
let instantiation = lower(program)
let call = instantiation.funcs[1].blocks[0].instrs.filterIt(it.kind == Opcode.Call)[0]
doAssert call.arguments.len == 1
doAssert call.arguments[0].kind == Shape.Int
let specialized = monomorphize(instantiation)
let constraints = validate(specialized)
doAssert constraints.len == 0, constraints.mapIt(it.msg).join("\n")

let content = ast.Error(tag: "error", elem: ast.Primitive(tag: "primitive", name: "text"))
let fetch = ast.External(tag: "extern-function", span: position, name: name("fetch"),
  abi: "c", params: @[], returns: content)
let recover = ast.Function(tag: "function", span: position, name: name("recover"),
  returns: ast.Primitive(tag: "primitive", name: "text"),
  body: ast.Block(tag: "block", stmts: @[
    ast.Statement(ast.Give(tag: "give", value: ast.Binary(tag: "binary", op: "catch",
      left: ast.Call(tag: "call", callee: name("fetch"), args: @[]),
      right: ast.Text(tag: "text", value: "fallback"))))
  ]))
program.units[0].body.stmts = @[ast.Statement(fetch), ast.Statement(recover)]
let catch = lower(program)
let errors = validate(catch)
doAssert errors.len == 0, errors.mapIt(it.msg).join("\n")
var phis: seq[Instruction]
for section in catch.funcs[0].blocks:
  phis.add(section.instrs.filterIt(it.kind == Opcode.Phi))
let phi = phis[0]
doAssert phi.blocks.len == 2
doAssert phi.blocks[0].label.startsWith("catch_")

let absent = ast.Function(tag: "function", span: position, name: name("absent"),
  returns: ast.Optional(tag: "optional",
    elem: ast.Primitive(tag: "primitive", name: "unsigned", width: "64")),
  body: ast.Block(tag: "block", stmts: @[
    ast.Statement(ast.Give(tag: "give", value: ast.Null(tag: "null")))
  ]))
program.units[0].body.stmts = @[ast.Statement(absent)]
let lowered = lower(program)
let operand = lowered.funcs[0].blocks[0].term.value
doAssert operand.name == "null"
doAssert operand.type.kind == Shape.Optional

# Inline reflection needs the actual checker-provided record, rather than an
# opaque fallback. Test the full shared parse/check/lower boundary.
let input = "function width giving unsigned { give reflect[unsigned 128].size. }"
let diagnostics = engine()
diagnostics.source(input,"reflection.iv")
let introspection = parser(lexer(input,diagnostics).lex(),diagnostics).parse()
let reflection = checking.checker(diagnostics)
reflection.check(introspection)
doAssert not diagnostics.failed
let unit = lower(introspection,reflection.types)
doAssert validate(unit).len == 0
doAssert unit.funcs[0].blocks[0].instrs.anyIt(it.kind == Opcode.Reflect and it.dest.type.kind == Shape.Struct)

echo "IR lower parity: ok"
