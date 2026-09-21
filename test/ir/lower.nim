import std/[sequtils, strutils, tables]
import ../../src/ast/node as ast
import ../../src/diag/span
import ../../src/ir/[kind, lower, monomorph, node, valid]

let position = Span(start: 0, `end`: 1, line: 1, col: 1)
proc name(value: string): ast.Name = ast.Name(tag: "name", span: position, text: value)
let function = ast.Function(tag: "function", span: position, name: name("main"),
  returnType: ast.Primitive(tag: "primitive", span: position, name: "integer"),
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
doAssert module.funcs[0].blocks[0].term.kind == InstrKind.Return
doAssert module.funcs[0].blocks[0].term.value.name == "tmp_1"
doAssert module.funcs[0].blocks[0].instrs.len == 1
doAssert module.funcs[0].blocks[0].instrs[0].kind == InstrKind.Add
doAssert module.funcs[0].blocks[0].instrs[0].val.name == "40"
doAssert module.funcs[0].blocks[0].instrs[0].val2.name == "2"

let increment = ast.Function(tag: "function", span: position, name: name("increment"),
  params: @[ast.Parameter(tag: "parameter", span: position, name: name("value"),
    `type`: ast.Primitive(tag: "primitive", name: "integer"))],
  returnType: ast.Primitive(tag: "primitive", name: "integer"),
  body: ast.Block(tag: "block", stmts: @[
    ast.Statement(ast.Give(tag: "give", value: ast.Binary(tag: "binary", op: "plus",
      left: name("value"), right: ast.Integer(tag: "integer", value: "1"))))
  ]))
let caller = ast.Function(tag: "function", span: position, name: name("caller"),
  returnType: ast.Primitive(tag: "primitive", name: "integer"),
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
doAssert calls.funcs[1].blocks[0].instrs.anyIt(it.kind == InstrKind.Call and it.func == "increment")
doAssert calls.funcs[1].blocks[0].instrs.countIt(it.kind == InstrKind.Load) == 2
doAssert calls.funcs[1].blocks[0].instrs.countIt(it.kind == InstrKind.Store) == 2

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
let loweredMachine = lower(program)
doAssert loweredMachine.funcs[0].blocks[0].instrs.anyIt(it.kind == InstrKind.Atomic and it.op == "add")
doAssert loweredMachine.funcs[0].blocks[0].instrs.anyIt("synchronize" in it.effects)
let machineErrors = validate(loweredMachine)
doAssert machineErrors.len == 0, machineErrors.mapIt(it.msg).join("\n")

let choose = ast.Function(tag: "function", span: position, name: name("choose"),
  params: @[ast.Parameter(tag: "parameter", name: name("flag"),
    `type`: ast.Primitive(tag: "primitive", name: "boolean"))],
  returnType: ast.Primitive(tag: "primitive", name: "integer"),
  body: ast.Block(tag: "block", stmts: @[
    ast.Statement(ast.`When`(tag: "when", cond: name("flag"),
      `then`: ast.Block(tag: "block", stmts: @[ast.Statement(ast.Give(tag: "give",
        value: ast.Integer(tag: "integer", value: "1")))]),
      `else`: ast.Block(tag: "block", stmts: @[ast.Statement(ast.Give(tag: "give",
        value: ast.Integer(tag: "integer", value: "2")))])))
  ]))
program.units[0].body.stmts = @[ast.Statement(choose)]
let loweredChoose = lower(program)
doAssert loweredChoose.funcs[0].blocks[0].term.kind == InstrKind.Cjump
doAssert loweredChoose.funcs[0].blocks.countIt(it.term.kind == InstrKind.Return) == 2
let chooseErrors = validate(loweredChoose)
doAssert chooseErrors.len == 0, chooseErrors.mapIt(it.msg).join("\n")

let loopFunction = ast.Function(tag: "function", span: position, name: name("count"),
  returnType: ast.Primitive(tag: "primitive", name: "integer"),
  body: ast.Block(tag: "block", stmts: @[
    ast.Statement(ast.Mutable(tag: "mutable", name: name("index"),
      value: ast.Integer(tag: "integer", value: "0"))),
    ast.Statement(ast.`While`(tag: "while",
      cond: ast.Binary(tag: "binary", op: "is less than", left: name("index"),
        right: ast.Integer(tag: "integer", value: "3")),
      body: ast.Block(tag: "block", stmts: @[
        ast.Statement(ast.AdvanceStatement(tag: "advance", target: name("index")))
      ]))),
    ast.Statement(ast.Give(tag: "give", value: name("index")))
  ]))
program.units[0].body.stmts = @[ast.Statement(loopFunction)]
let loweredLoop = lower(program)
doAssert loweredLoop.funcs[0].blocks.anyIt(it.term.kind == InstrKind.Cjump)
doAssert loweredLoop.funcs[0].blocks.countIt(it.term.kind == InstrKind.Jump) >= 2
let loopErrors = validate(loweredLoop)
doAssert loopErrors.len == 0, loopErrors.mapIt(it.msg).join("\n")

let sum = ast.Function(tag: "function", span: position, name: name("sum"),
  params: @[ast.Parameter(tag: "parameter", name: name("items"),
    `type`: ast.Sequence(tag: "sequence", elem: ast.Primitive(tag: "primitive", name: "integer")))],
  returnType: ast.Primitive(tag: "primitive", name: "integer"),
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
let loweredFor = lower(program)
var hasLength, hasIndex = false
for basicBlock in loweredFor.funcs[0].blocks:
  for instruction in basicBlock.instrs:
    if instruction.kind == InstrKind.Length: hasLength = true
    if instruction.kind == InstrKind.Index: hasIndex = true
doAssert hasLength
doAssert hasIndex
let forErrors = validate(loweredFor)
doAssert forErrors.len == 0, forErrors.mapIt(it.msg).join("\n")

let classify = ast.Function(tag: "function", span: position, name: name("classify"),
  params: @[ast.Parameter(tag: "parameter", name: name("value"),
    `type`: ast.Primitive(tag: "primitive", name: "integer"))],
  returnType: ast.Primitive(tag: "primitive", name: "integer"),
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
let loweredMatch = lower(program)
doAssert loweredMatch.funcs[0].blocks.countIt(it.term.kind == InstrKind.Cjump) == 2
let matchErrors = validate(loweredMatch)
doAssert matchErrors.len == 0, matchErrors.mapIt(it.msg).join("\n")

let mark = ast.ExternFunction(tag: "extern-function", span: position, name: name("mark"),
  abi: "c", params: @[ast.Parameter(tag: "parameter", name: name("value"),
    `type`: ast.Primitive(tag: "primitive", name: "integer"))],
  returnType: ast.Primitive(tag: "primitive", name: "nothing"))
let cleaned = ast.Function(tag: "function", span: position, name: name("cleaned"),
  body: ast.Block(tag: "block", stmts: @[
    ast.Statement(ast.`Defer`(tag: "defer", body: ast.Block(tag: "block", stmts: @[
      ast.Statement(ast.Action(tag: "action", name: name("mark"),
        args: @[ast.Expression(ast.Integer(tag: "integer", value: "1"))]))
    ]))),
    ast.Statement(ast.Give(tag: "give"))
  ]))
program.units[0].body.stmts = @[ast.Statement(mark), ast.Statement(cleaned)]
let loweredCleanup = lower(program)
doAssert loweredCleanup.funcs[0].blocks[0].instrs.anyIt(it.kind == InstrKind.Call and it.func == "mark")
let cleanupErrors = validate(loweredCleanup)
doAssert cleanupErrors.len == 0, cleanupErrors.mapIt(it.msg).join("\n")

let identity = ast.Function(tag: "function", span: position, name: name("identity"),
  typeParams: @[ast.TypeParam(tag: "type-param", name: name("T"))],
  params: @[ast.Parameter(tag: "parameter", name: name("value"),
    `type`: ast.Named(tag: "named", name: name("T")))],
  returnType: ast.Named(tag: "named", name: name("T")),
  body: ast.Block(tag: "block", stmts: @[
    ast.Statement(ast.Give(tag: "give", value: name("value")))
  ]))
let genericCaller = ast.Function(tag: "function", span: position, name: name("genericCaller"),
  returnType: ast.Primitive(tag: "primitive", name: "integer"),
  body: ast.Block(tag: "block", stmts: @[
    ast.Statement(ast.Give(tag: "give", value: ast.Call(tag: "call", callee: name("identity"),
      types: @[ast.`Type`(ast.Primitive(tag: "primitive", name: "integer"))],
      args: @[ast.Expression(ast.Integer(tag: "integer", value: "7"))])))
  ]))
program.units[0].body.stmts = @[ast.Statement(identity), ast.Statement(genericCaller)]
let loweredGeneric = lower(program)
let genericCall = loweredGeneric.funcs[1].blocks[0].instrs.filterIt(it.kind == InstrKind.Call)[0]
doAssert genericCall.typeArgs.len == 1
doAssert genericCall.typeArgs[0].kind == TypeKind.Int
let specialized = monomorphize(loweredGeneric)
let genericErrors = validate(specialized)
doAssert genericErrors.len == 0, genericErrors.mapIt(it.msg).join("\n")

let fallibleText = ast.Error(tag: "error", elem: ast.Primitive(tag: "primitive", name: "text"))
let fetch = ast.ExternFunction(tag: "extern-function", span: position, name: name("fetch"),
  abi: "c", params: @[], returnType: fallibleText)
let recover = ast.Function(tag: "function", span: position, name: name("recover"),
  returnType: ast.Primitive(tag: "primitive", name: "text"),
  body: ast.Block(tag: "block", stmts: @[
    ast.Statement(ast.Give(tag: "give", value: ast.Binary(tag: "binary", op: "catch",
      left: ast.Call(tag: "call", callee: name("fetch"), args: @[]),
      right: ast.Text(tag: "text", value: "fallback"))))
  ]))
program.units[0].body.stmts = @[ast.Statement(fetch), ast.Statement(recover)]
let loweredCatch = lower(program)
let catchErrors = validate(loweredCatch)
doAssert catchErrors.len == 0, catchErrors.mapIt(it.msg).join("\n")
var catchPhis: seq[Instruction]
for basicBlock in loweredCatch.funcs[0].blocks:
  catchPhis.add(basicBlock.instrs.filterIt(it.kind == InstrKind.Phi))
let catchPhi = catchPhis[0]
doAssert catchPhi.blocks.len == 2
doAssert catchPhi.blocks[0].label.startsWith("catch_")

let absent = ast.Function(tag: "function", span: position, name: name("absent"),
  returnType: ast.Optional(tag: "optional",
    elem: ast.Primitive(tag: "primitive", name: "unsigned", width: "64")),
  body: ast.Block(tag: "block", stmts: @[
    ast.Statement(ast.Give(tag: "give", value: ast.Nothing(tag: "nothing")))
  ]))
program.units[0].body.stmts = @[ast.Statement(absent)]
let loweredAbsent = lower(program)
let absentValue = loweredAbsent.funcs[0].blocks[0].term.value
doAssert absentValue.name == "null"
doAssert absentValue.type.kind == TypeKind.Optional

echo "IR lower parity: ok"
